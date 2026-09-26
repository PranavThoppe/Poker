# Shared waiting-room settings with green confirmation

## Summary

Allow every seated player to edit the pre-game starting stack and opening blinds while the room is waiting. Keep `Start Game` host-only. Add a green waiting-room confirmation matching the existing post-hand blind-change style, without changing that post-hand feature.

## Key changes

- Remove the host-only restriction only from the waiting-room `updateSettings` command:
  - Client enables **Edit** for any Classic Poker player while the phase is `.waiting`.
  - Server continues to require a room member, valid stack/blind values, and waiting phase, but no longer requires host identity.
  - Host-only `startGame` authorization and UI remain unchanged.

- Add an optional synced `LobbySettingsAnnouncement` to `GameState` with a UUID plus the accepted starting stack and small blind.
  - The server sets it only when either effective pre-game value actually changes.
  - It remains separate from `BlindIncreaseAnnouncement`; no post-hand blind-raise behavior or copy changes.

- Reuse the existing green confirmation-pill visual treatment in `WaitingRoomView`.
  - Show it to every connected player, including the person who saved.
  - Copy: `Settings updated: 1,000 chips · 10/20`
  - Display it for the same 2.5-second lifetime and with the same motion/accessibility behavior as the current blind-modification confirmation.
  - Treat the initial room snapshot as a baseline, so reopening an existing room does not show an old settings-update popup.

- Make the waiting-room Save action wait for server acceptance before closing the popover.
  - On a stale save, refresh the room and close the popover without a separate conflict message; the accepted settings-update popup communicates the result.
  - Do not automatically retry a stale settings command.
  - Disable Save when the entered values equal the current effective values, preventing an unnecessary Ready reset.

## Test plan

- Server tests verify any seated non-host can update valid waiting-room settings; non-members, invalid values, and non-waiting phases remain rejected.
- Verify an accepted changed setting resets all stacks and Ready states and emits the lobby announcement.
- Verify an unchanged settings submission does not emit an announcement or reset readiness.
- Update the multiplayer manual test: both host and guest can edit settings; each accepted change syncs values, clears Ready, and shows the same green confirmation on both devices; Start remains available only to the host.
- Manually race two saves from different devices: one wins, the other refreshes and closes; all clients converge on the winner’s values and show its green popup.

## Assumptions

- The popup intentionally contains values only—no editor name and no “Ready reset” text.
- “Shared” means all seated room members may edit only before the first hand; it does not apply to the post-hand blind-increase control.
