# Classic Poker Multiplayer — Manual Test Checklist

Run a Debug build on two devices or simulators with different device IDs. Use Device A to create the game and Device B to join from the iMessage bubble.

## Setup and room

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Device A sends a Classic Poker bubble. | A room opens with A in the waiting room. |
| 2 | Device B taps the bubble. | The same room opens with both players listed once. |
| 3 | Device A edits the starting stack and small blind, then saves. | Both devices show the same stack and blind values; all Ready states clear. |
| 4 | Device B attempts to edit settings. | Settings are read-only for Device B. |
| 5 | Both players tap Ready. | Ready state matches on both devices. |
| 6 | Device A starts the game. | Both devices enter play with matching dealer, configured blinds, pot, active player, and stacks. |
| 7 | Inspect private cards. | Each device sees only its own two cards. |

## Betting and streets

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Call, check, raise, and fold across one or more hands. | Both devices agree on the active player, bets, stacks, pot, folds, and board after every action. |
| 2 | Close pre-flop, flop, and turn. | The next street is dealt with the correct board-card count (3, then 1, then 1). |
| 3 | Let the final player on a street fold. | A folded player never receives another turn. |
| 4 | Reach the river with multiple players. | Each eligible player gets a river turn before showdown. |

## Showdown and next hand

| # | Step | Expected result |
|---|------|-----------------|
| 1 | End a hand by folds. | The pot is awarded once and both devices enter the hand summary. |
| 2 | Reach showdown. | Hands reveal in order and both devices show the same winner and final stacks. |
| 3 | Do not tap Continue as the winner. | The host safely advances after the fallback delay. |
| 4 | Ready up after a summary. | The host sees Next Hand only when every eligible player is ready. |
| 5 | Finish or reset a game. | Both devices return to the same waiting or final state. |

## Recovery checks

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Background one device during a hand, then return. | It re-syncs and retains only its own hole cards. |
| 2 | Close and reopen a bubble mid-hand. | The host can restore its cards and complete the hand; the guest re-fetches its own cards. |
| 3 | Leave a table briefly with no active player. | The host resolves or recovers the stalled hand without losing the pot. |
# Server-authoritative checks

Before the existing visual checklist, verify the following against a staging
project: creator background/force-quit does not prevent a seated player from
submitting a legal command; retrying one exact action ID returns the same
receipt; a stale version refreshes without changing chips; a non-member and a
request for another player's cards are denied; and direct PostgREST reads or
writes of `game_rooms`/`player_hole_cards` fail with the publishable key.
