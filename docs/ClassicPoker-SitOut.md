# Classic Poker — Sitting Out Implementation Specification

## Purpose and scope

Extend Classic Poker multiplayer with a temporary **Sitting Out** state. A seated player can leave active participation without being removed from the room: their seat, stack, identity, and accumulated statistics remain part of the shared game. Other eligible players can continue playing, and the seated player can return at a safe hand boundary.

This document specifies the feature only. It does not authorize production-code changes by itself.

## UX contract

Classic uses the existing CPU-mode small, high, circular **X** treatment. At a completed Classic game it uses the existing **Done** action and visual treatment.

### X action in Classic

Tapping X during an unfinished Classic game presents a confirmation:

| Element | Required copy / behavior |
|---|---|
| Title | `Sit out?` |
| Message | `Other players can continue. You can rejoin before a later hand.` |
| Cancel action | `Stay` |
| Confirm action | Destructive `Sit Out` |

Confirming **Sit Out** does not eliminate the player, delete their record, or end the shared game. Their player entry remains in the shared `players` roster with its stack, name, avatar, and accumulated statistics intact.

At a completed Classic game, **Done** only closes the extension and stops that device's local multiplayer subscription/tasks. It must not mutate the shared game.

### Sitting out during a hand

If the player confirms while a hand is live, their hand folds immediately and exactly once, then their persisted sitting-out state is set. The fold must advance normal play as appropriate, so the player cannot block turn progression.

Sitting-out players are excluded from:

- readiness requirements;
- dealing eligibility;
- blinds and dealer/turn-order eligibility for the hand;
- hole-card distribution;
- actionable turn order; and
- end-game survivor/winner calculations.

They remain in the roster for identity, stack, statistics, history, and table presentation.

### Minimum active-player rule

The engine must distinguish a player who is eliminated from a player who is temporarily sitting out.

If fewer than two players are both non-eliminated and not sitting out, the table pauses in its post-hand state. It must neither deal a one-player hand nor declare the game over solely because other seated players are sitting out. The table may resume after another seated, non-eliminated player rejoins and is ready for a subsequent hand.

### Reopening and rejoining

A player who had been sitting out may reopen the game. The timing determines when they become active:

| Shared phase when reopened | Required behavior |
|---|---|
| `.playing` or `.showdown` | Keep the player sitting out for the entire current hand. Present the game as a spectator: shared board, public player states, pot, and progression are visible, but no private hole cards are fetched or displayed. They cannot bet, fold, reveal, continue, or Ready Up. |
| `.handSummary` | Reactivate immediately with `isReady = false`; show **Ready Up** for the next hand. |
| `.waiting` | Reactivate immediately with `isReady = false`; show **Ready Up**. |

For a mid-hand spectator, automatically reactivate the player when the game reaches `.handSummary`, setting `isReady = false`. Rejoining always requires an explicit **Ready Up** before the next hand. A player eliminated by normal poker play remains eliminated; sitting out is not a path to re-enter after elimination.

The presentation must clearly label the local hero as a spectator/sitting out while that status applies. The UI must not expose actions that are invalid for that state.

## Persistence and model changes

Add a persisted `isSittingOut` field to the player model.

- Decode older room/player payloads compatibly: a missing value defaults to `false`.
- Preserve the field in local/remote merges, host roster refreshes, synced public state, and game logging.
- Retain all existing player data while sitting out, including stack, name, avatar, stats, seat/dealer context, and elimination status.
- A disconnected/reopened client must resolve its local player against the shared roster rather than constructing a replacement player that loses sitting-out state.

## Store and engine contract

Provide store-level operations for the following responsibilities:

| Operation | Requirements |
|---|---|
| Sit out local player | Persist `isSittingOut = true`; if the hand is live and the local player is participating, perform the immediate fold first/atomically with the transition so only one fold is recorded. |
| Request rejoin after reopening | Resolve the local player and determine whether reactivation is safe now or must wait for the current hand summary. |
| Activate returning player | At `.waiting` or `.handSummary`, set `isSittingOut = false` and `isReady = false`; never activate them into the current live hand. |
| Close local Classic session | Stop the local multiplayer subscription and related local tasks without writing a game-ending or roster-changing mutation. |

Update the eligibility helpers or equivalent central engine/store predicates. They must independently express at least:

- eligible for the current hand;
- required to Ready Up;
- enough eligible players to deal;
- an active/true session winner.

These rules cannot treat `isEliminated` and `isSittingOut` as interchangeable. Sitting out excludes a player from a hand but does not make them an eliminated survivor candidate or cause the session to end.

When determining blinds, dealer progression, turn order, and dealing, use the eligible-for-this-hand predicate. Ensure host next-hand handling refreshes the latest remote/shared roster before calculating eligibility or dealing, so a guest's most recent sit-out or rejoin mutation is honored.

The remote synchronization path must preserve transitions made by either host or guest. In particular, do not overwrite a newer `isSittingOut` value during host roster refresh, public-state synchronization, or conflict/merge handling.

## Private information and spectator safety

While a sitting-out player is spectating a live hand:

- Do not deal that player hole cards.
- Do not fetch, retry fetching, cache as active, or restore their prior private hole cards.
- Do not render private cards, including stale cards from a preceding hand.
- Continue rendering only the shared/public state required to spectate.

Private-card fetch and retry logic must explicitly recognize the spectator/sitting-out hero state, including after reconnect and remote state merges. Public hand progression continues normally for eligible players.

## State transitions

```text
active seated player
  └─ confirms Sit Out ──► sitting out
                            ├─ live hand: fold immediately, then spectate through summary
                            ├─ waiting/summary reopening: reactivate now, unready
                            └─ live reopening: remain spectator; reactivate at summary, unready

sitting out + fewer than 2 active eligible players
  └─ post-hand pause ──► another player rejoins + becomes ready ──► next hand may deal
```

## Acceptance scenarios

| Scenario | Expected result |
|---|---|
| Guest sits out at hand summary | Guest stays seated with all data intact. The remaining active players can Ready Up and play subsequent hands without the guest. |
| Guest sits out on their turn | The guest hand folds once, no further action is requested from them, and play advances normally. |
| Guest reopens mid-hand | Guest sees public game state only, no hole cards or actionable controls. At hand summary, they reactivate unready and then receive Ready Up. |
| Guest reopens at hand summary | Guest reactivates immediately, remains unready, and can use Ready Up. |
| Only one active player remains | The table pauses after the current hand; it neither deals a one-player hand nor ends solely due to sitting-out players. It resumes only after another seated player rejoins and is ready. |
| Host and guest sit out/rejoin | Both flows preserve stacks, dealer order, pots, roster data, and shared state without corruption. |
| Existing CPU X / Leave / Done behavior | Remains unchanged. Classic alone maps its unfinished-game X confirmation to Sit Out; completed Classic Done remains local-only. |

## Verification notes

Test host and guest independently, including state changes made immediately before the host attempts to start/deal a new hand. Exercise reconnect/reopen flows in every listed phase, and inspect logs/synced state to confirm `isSittingOut` survives every merge and that no private-card retry occurs for a spectator.
