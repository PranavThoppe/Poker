# Classic Poker Multiplayer — Manual Test Checklist

Run a Debug build on two devices or simulators with different device IDs. Use Device A to create the game and Device B to join from the iMessage bubble.

## Setup and room

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Device A sends a Classic Poker bubble. | A room opens with A in the waiting room. |
| 2 | Device B taps the bubble. | The same room opens with both players listed once. |
| 3 | Both players tap Ready. | Ready state matches on both devices. |
| 4 | Device A starts the game. | Both devices enter play with matching dealer, blinds, pot, active player, and stacks. |
| 5 | Inspect private cards. | Each device sees only its own two cards. |

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
