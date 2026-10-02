# Classic Poker Multiplayer — Manual Test Checklist

Run a Debug build on two devices or simulators with different device IDs. Use Device A to create the game and Device B to join from the iMessage bubble.

## Setup and room

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Device A sends a Classic Poker bubble. | A room opens with A in the waiting room. |
| 2 | Device B taps the bubble. | The same room opens with both players listed once. |
| 3 | Device A edits the starting stack and small blind, then saves. | Both devices show the same values; all Ready states clear and both show the green settings confirmation. |
| 4 | Device B edits different valid settings, then saves. | Both devices sync the new values, clear Ready, and show the same green confirmation. |
| 5 | Both players tap Ready. | Ready state matches on both devices. |
| 6 | Device A starts the game. | Both devices enter play with matching dealer, configured blinds, pot, active player, and stacks. |
| 7 | Device B tries to start the game before A does. | Start Game remains available only to the host. |
| 8 | Inspect private cards. | Each device sees only its own two cards. |

Race two valid settings saves from A and B as closely together as possible. One save should win; the other device refreshes and closes its settings popover without a conflict message. Both devices converge on the winner's values and show the winner's green confirmation.

## Waiting-room leave

| # | Step | Expected result |
|---|------|-----------------|
| 1 | With A and B in `.waiting`, B taps X and confirms Leave. | B's row disappears on both devices and the extension closes. Reopening the bubble adds B once as unready, with Ready Up available. |
| 2 | With A and B in `.waiting`, A taps X and confirms Leave. | A's row disappears, B becomes current host, and B can start after the remaining players are ready. |
| 3 | In a room with only A, A leaves and reopens the bubble. | The room remains joinable and A returns as host. |
| 4 | Race a guest leave with another player's Ready change. | Leave retries against current waiting state and removes the guest. |
| 5 | Race a guest leave with Start Game. | If start wins, leave is rejected; the guest is offered the existing Sit Out choice and the row remains. |
| 6 | Reopen a legacy waiting room where the joining player is marked Sitting Out. | Join clears Sitting Out and Ready; Ready Up is available. |

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
| 4 | Open the bubble on a device whose player ID is absent while the room is `.playing` or `.showdown`. | It joins as folded and sitting out, sees public state only, and can tap **Rejoin & Ready** at the next hand summary. |
| 5 | Force a transient join failure, then choose **Retry** in the connection alert. | The extension retries joining the same room and opens when the join succeeds. |

## Three or more players

Run a Debug build on three (or more) devices or simulators with different device IDs. Use Device A as host; Devices B and C join from the same iMessage bubble.

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Device A sends a Classic Poker bubble; B and C join. | All three devices show the same roster with each player listed once. |
| 2 | All players Ready; Device A starts. | Matching dealer, blinds, pot, active player, and stacks; each device sees only its own hole cards. |
| 3 | Play through a full hand with three or more in. | Turn order skips folded players only; every device agrees on bets, pot, board, and active player after each action. |
| 4 | Reach showdown with multiple survivors. | Hands reveal in order; all devices show the same winner(s) and final stacks. |
| 5 | Ready up and deal the next hand. | Host sees Next Hand only when every eligible (non–sitting-out) player is ready; dealer and blinds advance correctly among eligible seats. |

## Sit out (3+ players)

Exercise sit-out with at least three seated players so the table can keep playing after one leaves.
Waiting-room X removes the player from the roster; the sit-out cases below apply only after the first hand starts.

| # | Step | Expected result |
|---|------|-----------------|
| 1 | Mid-hand, Device C taps X → confirms **Sit Out**. | C folds once (if still in the hand), is labeled Sitting Out / spectating, and no further action is requested from C. Play continues for A and B. |
| 2 | Finish the hand with C sitting out. | Pot is awarded normally among eligible players; C stays on the roster with stack, name, avatar, and stats intact. |
| 3 | A and B Ready Up for the next hand. | Ready requirements ignore C; Next Hand deals only to eligible players (no hole cards for C). |
| 4 | While a hand is live, Device C reopens the bubble. | C sees public state only (board, pot, stacks); no hole cards, betting, fold, reveal, Continue, or Ready Up. Label shows sitting out / spectating. |
| 5 | Let that hand reach hand summary. | C remains sitting out and unready; **Rejoin & Ready** appears. A/B continue without corruption of stacks or dealer order. |
| 6 | At hand summary (or waiting), Device C sits out again, then Device B sits out. | With fewer than two eligible players, the table pauses after the hand: no one-player deal and no game-over solely from sit-outs. |
| 7 | Device B taps **Rejoin & Ready**; Device A is ready. | B becomes active and ready in one server transition; table resumes and deals to eligible players only. |
| 8 | Repeat a sit-out / rejoin as host (A) and as a guest (B or C). | Both flows preserve roster, stacks, pot, and shared phase on every device. |
| 9 | Reopen as C while a hand is live, then tap X / close and reopen without Ready Up at summary. | C remains sitting out throughout; no Ready Up appears mid-hand, and reopening never reactivates C automatically. |
| 10 | As a sitting-out player at a safe boundary, send/tap a readiness cancel (`setReady(false)`). | Readiness clears and sitting-out status remains true. |

# Server-authoritative checks

Before the existing visual checklist, verify the following against a staging
project: creator background/force-quit does not prevent a seated player from
submitting a legal command; retrying one exact action ID returns the same
receipt after leave; a reused action ID from another actor never returns that
receipt; a stale version refreshes without changing chips; a non-member and a
request for another player's cards are denied; and direct PostgREST reads or
writes of `game_rooms`/`player_hole_cards` fail with the publishable key. Also
confirm `setSittingOut(true)` is rejected in `.waiting`.
