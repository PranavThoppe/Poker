# Classic Poker Multiplayer — Manual Test Checklist

Run a **Debug** build on two devices or simulators with different device IDs. Use **Device A** to create the game and **Device B** to join from the iMessage bubble.

Logs must use stable player IDs only. Do not include display names or private hole cards.

**Supabase setup:** run [`docs/supabase-debug-log.sql`](supabase-debug-log.sql) and [`docs/supabase-hole-cards-hand-id.sql`](supabase-hole-cards-hand-id.sql) in the Supabase SQL editor before testing. Events append to `game_rooms.debug_log` (newest 1,000 kept). Inspect with:

```sql
SELECT id, jsonb_array_length(debug_log) AS events, debug_log
FROM game_rooms
WHERE id = '<game-uuid>';
```

Poll requests exclude `debug_log` so the 2-second sync loop does not download the full history.

## Poker terms used in logs

Betting **streets**, in order:

1. `preFlop` — two private cards are dealt; no community cards.
2. `flop` — three community cards are dealt.
3. `turn` — the fourth community card is dealt.
4. `river` — the fifth community card is dealt.
5. `showdown` — remaining hands are compared and the pot is awarded.

Possible **hand ranks**, weakest to strongest:

1. `highCard`
2. `pair`
3. `twoPair`
4. `threeOfAKind`
5. `straight`
6. `flush`
7. `fullHouse`
8. `fourOfAKind`
9. `straightFlush`
10. `royalFlush`

`straight` is a hand rank. `river` is a betting street. They must not be logged as the same kind of event.

## Bounded turn model

Each player turn produces exactly one accepted betting action:

- `fold`
- `check`
- `call`
- `raise`

Turn progression:

1. A `fold`, `check`, or `call` normally passes the turn to the next eligible player.
2. A `raise` increases the amount to match and reopens action for every remaining eligible player.
3. The street ends only after every remaining player has acted and matched the current bet, or has no chips left.
4. If only one player remains, the hand ends immediately without advancing to another street.
5. If multiple players remain after the river closes, the hand advances to showdown.

For `N` active players and `R` raises on one street, use this conservative action bound:

`maximum actions on the street <= N × (R + 1)`

Examples with five active players:

- No raises: at most 5 actions on the street.
- One raise: at most 10 actions.
- Two raises: at most 15 actions.
- A check-through hand across all four streets: at most 20 actions.
- One raise on every street: normally no more than 40 actions.

There is no strict bound on the number of hands in a session because chips can move back and forth. The debug array should therefore retain a rolling maximum of **1,000 events per game**, while event sequence numbers continue increasing.

## Complete log event vocabulary

Every event includes:

- `event`
- `timestamp`
- `sequence`
- `game_id`
- `device_id`
- `device_role`: `host` or `guest`
- `player_id` when the event concerns a player
- `hand_number`
- `street`
- `pot`

### Room and session

- `roomCreated`
- `roomOpened`
- `playerJoined`
- `readyChanged`
- `gameStarted`
- `phaseChanged`
- `gameEnded`
- `gameReset`

### Hand setup

- `handStarted`
- `dealerAssigned`
- `holeCardsDealt`
- `holeCardsStored`
- `holeCardsFetched`
- `smallBlindPosted`
- `bigBlindPosted`
- `turnStarted`

`holeCardsDealt`, `holeCardsStored`, and `holeCardsFetched` record only `card_count`, never card values.

### Accepted player actions

- `playerFolded`
- `playerChecked`
- `playerCalled`
- `playerRaised`

Action fields:

- `amount`: chips moved by this action.
- `bet_after`: the player's total bet on the current street.
- `stack_after`: the player's remaining stack.
- `bet_to_match`: current highest street bet after the action.

### Rejected player actions

- `actionRejected`

Possible `reason` values:

- `wrongPhase`
- `notPlayersTurn`
- `playerFolded`
- `playerEliminated`
- `checkFacingBet`
- `callNotRequired`
- `callTooSmall`
- `raiseNotHigher`
- `raiseExceedsStack`

### Turn and street progression

- `turnAdvanced`
- `bettingReopened`
- `bettingRoundCompleted`
- `streetAdvanced`
- `communityCardsDealt`

These are also emitted by the host when it deals a street after merging a peer's closing
action, not only by the device that acted. A street that changes with no accompanying
`streetAdvanced` is a bug in the log, not evidence of a skipped street.

`streetAdvanced` possibilities:

- `preFlop` → `flop`
- `flop` → `turn`
- `turn` → `river`
- `river` → `showdown`

Every street between `preFlop` and `river` inclusive gets its own betting round. `river` →
`showdown` may only follow a closed river betting round, or a street where no remaining
player had chips left to bet.

`communityCardsDealt` records `card_count`:

- Flop: `3`
- Turn: `1`
- River: `1`

### Hand result

- `showdownStarted`
- `cardsShown`
- `showdownAutoShown`
- `showdownAdvancedByWinner`
- `showdownAutoAdvanced`
- `handRankEvaluated`
- `potAwarded`
- `splitPot`
- `handWonByFold`
- `handWonAtShowdown`
- `playerEliminated`
- `handCompleted`
- `handFinalizeBlocked`
- `handSummaryOpened`
- `nextHandStarted`

`handFinalizeBlocked` means a device tried to close a hand that had awarded no pot. It is
never expected during normal play: it marks a hand that could not be resolved, and the
table is left live for recovery instead of being abandoned into the summary screen.

`handRankEvaluated` uses one of the ten hand-rank values listed above. It may record the rank for each showdown contender, but it must not record private cards.

### Multiplayer synchronization

- `statePublishStarted`
- `statePublishSucceeded`
- `statePublishFailed`
- `remoteStateReceived`
- `remoteStateIgnored`
- `remoteStateMerged`
- `localPlayerRestored`
- `holeCardsStoreFailed`
- `holeCardsFetchEmpty`
- `holeCardsFetchFailed`
- `showdownDeferredToHost`
- `showdownResolvedByHost`
- `guestContinueBlocked`
- `subscriptionStarted`
- `subscriptionStopped`

Do not log unchanged two-second poll ticks. Log only a changed state, ignored stale state, or failure.

## Setup and room test

| # | Step | Pass? | Expected result / event |
|---|------|-------|-------------------------|
| 1 | Device A chooses Classic Poker and sends a bubble | ☐ | One room is created; `roomCreated`, `playerJoined`, `subscriptionStarted`. |
| 2 | Device B taps the bubble | ☐ | The same `game_id` opens; `roomOpened`, `playerJoined`, `remoteStateMerged`. |
| 3 | Both devices inspect the waiting room | ☐ | Both show the same two player IDs exactly once. |
| 4 | Device A toggles Ready | ☐ | Both devices show A ready; `readyChanged`. |
| 5 | Device B toggles Ready | ☐ | Both devices show B ready; `readyChanged`. |
| 6 | Start the game | ☐ | `gameStarted`, then `handStarted`; both enter `playing`. |
| 7 | Compare public state | ☐ | Dealer, blinds, pot, street, active player, and stacks match on both devices. |
| 8 | Check private state | ☐ | Each device sees exactly two of its own cards and no opponent cards. |

## Betting and street test

Repeat hands as needed to cover every action.

| # | Step | Pass? | Expected result / event |
|---|------|-------|-------------------------|
| 1 | Verify initial street | ☐ | Street is `preFlop`; `smallBlindPosted`, `bigBlindPosted`, `turnStarted`. |
| 2 | Active player calls | ☐ | `playerCalled`; pot and stack change equally on both devices. |
| 3 | Active player checks when no bet is owed | ☐ | `playerChecked`; pot does not change. |
| 4 | Active player raises | ☐ | `playerRaised`, `bettingReopened`; every remaining eligible player receives another turn before the street closes. |
| 5 | A player folds | ☐ | `playerFolded`; that player receives no more turns during the hand. |
| 6 | Complete pre-flop betting | ☐ | `bettingRoundCompleted`, `streetAdvanced` to `flop`, `communityCardsDealt` with count 3. |
| 7 | Complete flop betting | ☐ | `streetAdvanced` to `turn`, `communityCardsDealt` with count 1. |
| 8 | Complete turn betting | ☐ | `streetAdvanced` to `river`, `communityCardsDealt` with count 1. |
| 9 | Complete river betting with multiple players | ☐ | `showdownStarted`; no additional player turn is started. |
| 10 | Compare after every action | ☐ | Both devices agree on active player, street, board, pot, bets, folds, and stacks. |
| 11 | Check the opener on every street after the flop | ☐ | `turnStarted` names the first live seat left of the button, never the seat that closed the previous street. |
| 12 | Let the last player to act fold and close a street | ☐ | The next street deals and `turnStarted` names a player who has not folded; the folded player receives no turn. |
| 13 | Reach the river with chips behind on both sides | ☐ | Each remaining player gets a river turn before `showdownStarted`; the river is never dealt in the same step as the showdown. |

## Hand result test

| # | Step | Pass? | Expected result / event |
|---|------|-------|-------------------------|
| 1 | End a hand by all other players folding | ☐ | `handWonByFold`, `potAwarded`, `handCompleted`; no showdown event. |
| 2 | Reach showdown with at least two players | ☐ | `handRankEvaluated` for each contender, then `handWonAtShowdown`. |
| 3 | Inspect the winner | ☐ | The complete pot is added once; both devices show the same winner and stack. |
| 4 | Inspect the table after the last hand is shown | ☐ | The winner sees Continue with no countdown; every other device waits on the winner's name. |
| 5 | Winner taps Continue | ☐ | `showdownAdvancedByWinner`; both devices leave `showdown` together. |
| 6 | Winner never taps Continue | ☐ | Host silent safety advances after ~14s (`showdownAutoAdvanced`); table still moves on. |
| 7 | Inspect hand summary | ☐ | Both devices enter `handSummary` with matching statistics; no badge appears beside players who have not readied, and the Ready Up button shows `0/N` for the active players. |
| 8 | One player taps Ready Up | ☐ | Both devices show that player as **Ready** with no badge on the others, and the ready count on the button rises by one. |
| 9 | Every active player readies up | ☐ | The host sees **Next Hand** only after all non-eliminated players with chips are ready. |
| 10 | Host taps Next Hand | ☐ | `nextHandStarted`; dealer rotates and new private cards are available. |
| 11 | Reduce a stack to zero | ☐ | `playerEliminated`; that player shows **Out**, is not required to ready, and receives no future turns or cards. |
| 12 | Leave one player with chips | ☐ | `gameEnded`; both devices show the same final stacks and winner ID. |

## Synchronization and recovery test

| # | Step | Pass? | Expected result / event |
|---|------|-------|-------------------------|
| 1 | Perform one action on Device A | ☐ | A publishes once; B receives and merges the change once. |
| 2 | Perform one action on Device B | ☐ | B publishes once; A receives and merges the change once. |
| 3 | Wait without acting for ten seconds | ☐ | No unchanged poll events are appended. |
| 4 | Background the guest, act on host, then reopen guest | ☐ | Guest catches up to the latest state without overwriting it. |
| 5 | Disconnect the guest, act on host, then reconnect | ☐ | Fetch/publish failures are logged and the guest eventually merges current state. |
| 6 | Let the guest make the final river action | ☐ | `showdownDeferredToHost`, followed by `showdownResolvedByHost`; pot awarded once. |
| 7 | Start another hand | ☐ | Old hole cards are not displayed; each active player fetches exactly two new cards; eliminated players see no private cards. |
| 8 | Reopen the same bubble | ☐ | The existing room opens; no duplicate player and no fresh room are created. |
| 9 | Third player joins, then host starts | ☐ | All three names appear on the host waiting screen before Start; each device gets `holeCardsFetched`. |

## Sign-off

- **Build:** Debug
- **Device A:** _______________
- **Device B:** _______________
- **Date:** _______________
- **Room setup:** ☐ Pass ☐ Fail
- **Betting and streets:** ☐ Pass ☐ Fail
- **Hand results:** ☐ Pass ☐ Fail
- **Synchronization:** ☐ Pass ☐ Fail
