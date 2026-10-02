# Waiting Room Leave and Sit-Out Rejoin — Two-PR Plan

## Confirmed behavior and diagnosis

The waiting-room X currently calls `sitOutLocalPlayer()` and closes the extension. The server accepts `setSittingOut(true)` during `.waiting`, so the player remains in the roster marked sitting out. `WaitingRoomView` hides **Ready Up** for that player, leaving them stuck when they reopen.

The intended behavior is: **before the first hand, X leaves the room and removes the player's avatar row; after the game has started, X means sit out.** A player who leaves before the game starts can reopen the bubble and join the waiting room normally.

The work is split so PR 1 fixes the reported waiting-room bug, while PR 2 separately repairs rejoining after a player sits out during a game.

## PR 1 — Leave the waiting room

### Scope

Add a server-authoritative `leaveRoom` command, use it for X during `.waiting`, and retain current sit-out behavior for later phases.

### Changes

1. Add `leaveRoom` to the Swift command enum/encoder and the server command contract/parser.
2. In `RootView`, when phase is `.waiting`, submit `leaveRoom`. Close the extension only after success. In `.playing`, `.showdown`, and `.handSummary`, keep the existing sit-out flow.
3. In the server engine, allow leave only in `.waiting`, require the caller to be a room member, remove that player's roster entry, and clear any private cards keyed to that player. Make `setSittingOut(true)` illegal in `.waiting`.
4. Add `leaveRoom` to `REBASE_KINDS`, but permit rebasing only while phase is `.waiting`. A stale version caused by another player's ready change can then be retried against current state. If the game starts before the leave commits, reject it as `illegal_phase`.
5. **Host departure:** update `state.hostID` atomically with roster removal. If players remain, transfer gameplay authority to the first remaining roster entry. `game_rooms.host_id` is creator metadata and remains unchanged; server game-flow authorization uses the current `hostID` in public state. If no players remain, keep the empty room so the existing bubble can still be used to join again.
6. **Empty-room and legacy recovery:** on `join-room`, if the room has no current host in its roster, make the joining player current host. If the joining player already exists in a `.waiting` room with stale `isSittingOut = true`, clear that flag and readiness. A removed player joins through the existing absent-player path as a fresh, unready player.
7. **Idempotent retries:** the game-api currently checks membership before its receipt fast path, so a successful leave retried after removal returns 403. Look up the receipt before membership validation, and return it only when both `action_id` and `actor_device_id` match the request. The client must reuse the same `actionID` for every retry; `submit` already supports this. Also treat `not_room_member` as leave success on the client as a safe fallback when a retry uses a new action ID or its receipt has expired.
8. **Stale/error UI behavior:** `submit` currently treats a stale command as success except for `startGame`. For `leaveRoom`, exhaust the server retries, refresh state, and report failure instead of closing. If refreshed phase is no longer `.waiting` (including server `illegal_phase`), show the existing sit-out confirmation and let the player choose whether to sit out rather than silently closing.
9. Add server coverage for guest leave, host handoff, last-player leave/rejoin, repeat leave with the same action ID, receipt ownership, stale rebase, and rejection after game start. Update multiplayer manual scenarios.

### PR 1 acceptance scenarios

- Host leaves a waiting room: their row disappears, another seated player becomes host, and that room can still start.
- Guest leaves a waiting room: their row disappears for everyone; reopening adds them as unready and they can Ready Up.
- Last player leaves: room remains joinable; the next joiner becomes host.
- A leave retried with its original action ID after the player was removed returns the original viewer-scoped success response, not 403.
- A matching action ID from a different actor never returns the prior actor's response or private cards.
- A ready change racing with leave does not cause an unnecessary stale failure; a start racing with leave causes leave rejection and offers the sit-out choice.
- `setSittingOut(true)` in `.waiting` is rejected; after the game starts, existing sit-out/fold behavior is unchanged.
- An existing player marked sitting out in a legacy waiting-room state is recovered as active and unready on join.

## PR 2 — Rejoin after sitting out during a game

### Scope

Make **Ready Up** the explicit, server-authoritative action that reactivates a sitting-out player for the next hand. Reopening the bubble alone does not rejoin them. This PR is independent of waiting-room leave.

### Changes

1. In the server engine's `setReady` handler, allow only `.waiting` and `.handSummary`. When `ready == true` and the player is sitting out, non-eliminated, and has chips, clear `isSittingOut` and set `isReady = true` in the same command. Validate eligibility after this reactivation.
2. `setReady(false)` must only clear readiness; it must not reactivate a sitting-out player. Keep `setSittingOut(false)` limited to safe boundary phases and preserve its unready behavior if that command remains supported.
3. Remove the client reopen-triggered mutation and local rejoin scheduling (`requestRejoinAfterReopening()`, `reconcileLocalParticipation()` rejoin behavior, and `pendingRejoinHandID`) so reopening does not change participation. Do not optimistically clear sitting-out state.
4. Show **Ready Up** only in `.waiting` or `.handSummary` for a sitting-out player who can rejoin. Consider labeling it **Rejoin & Ready** while sitting out. Do not show Ready Up during `.playing` or `.showdown`.
5. Reuse the normal `setReady(true)` submission and idempotent retry path. On failure, retain the server's sitting-out state and report an actionable error rather than diverging locally.
6. Preserve spectator privacy during `.playing` and `.showdown`: no old/current hole cards, private-card fetch, betting, reveal, or continue actions while sitting out.

### PR 2 acceptance scenarios

- Reopening at `.waiting` or `.handSummary` leaves a sitting-out player sitting out and unready until they tap Ready Up.
- Tapping Ready Up at either safe boundary clears `isSittingOut` and sets `isReady` atomically on the server; the player is eligible for the next hand only after this command.
- A player reopening during `.playing` or `.showdown` remains a spectator, and no Ready Up button appears until `.handSummary`.
- `setReady(true)` during `.playing` or `.showdown` is rejected; `setReady(false)` never clears sitting-out status.
- Host and guest rejoin transitions persist across remote refreshes and reconnects.
- Failed/stale ready commands do not leave local state active while the server still marks the player sitting out; retrying the same action ID is safe.
- Spectator presentation and private-card protections remain intact.

## Assessment of the proposed split

The split is sound: waiting-room removal and in-game rejoin have different semantics and can be reviewed independently. The suggested receipt-before-membership fix is necessary because this endpoint currently performs those checks in the opposite order. Actor-scoping the receipt is essential because its response is viewer-specific and may contain hole cards.

Including `leaveRoom` in rebasing is also appropriate with a waiting-only phase guard. The client stale-result special case matters: otherwise a leave that still fails after the server's bounded retries could close the extension despite no confirmed removal.

Keeping empty rooms is a reasonable choice for this design: `join-room` already creates a missing player's roster entry, and it avoids adding a deletion operation and race. The host handoff must update `public_state.hostID`; the database `host_id` is the immutable creator field. Finally, recovery of stale waiting-room sit-out records belongs in PR 1 because those users are already stranded by the bug being fixed.

## Main implementation touchpoints

- PR 1: `Views/RootView.swift`, `Store/GameStore.swift`, `Networking/GameCommandClient.swift`, `Models/PokerModels.swift`, `supabase/functions/_shared/contracts.ts`, `supabase/functions/_shared/poker-engine.ts`, `supabase/functions/_shared/poker-engine_test.ts`, `supabase/functions/game-api/index.ts`, and multiplayer manual documentation.
- PR 2: `Store/GameStore.swift`, `Views/Screens/WaitingRoom/WaitingRoomView.swift`, `supabase/functions/_shared/poker-engine.ts`, `supabase/functions/_shared/poker-engine_test.ts`, and multiplayer/sit-out manual scenarios. `MessagesViewController.swift` should no longer trigger an automatic rejoin on reopen.
- Keep `docs/ClassicPoker-SitOut.md` aligned with the final distinction: waiting-room X leaves/removes; post-start X sits out.
