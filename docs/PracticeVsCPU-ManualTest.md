# Practice vs CPU — Manual Test Checklist

Run in **Debug** on device or simulator. Filter the Xcode console with **`[Game]`** to trace lifecycle, hero actions, hand boundaries, player counts, pot, and `activePlayerID`.

## Setup

1. Open the iMessage extension (expanded view).
2. On game selection, choose **Practice vs CPU** (not Classic Poker).
3. Tap **Play** — you should land in the waiting room locally (no bubble sent).
4. Tap **Ready**, then **Start**.

**Expected `[Game]` at start**

- `startGame` snapshot: `players=5 (human=1 bot=4)`, `phase=playing`, blinds posted (`pot` > 0).
- If a bot acts first: `bot … → …` lines before your turn.

## During play

| # | Step | Pass? | Notes / `[Game]` signals |
|---|------|-------|-------------------------|
| 1 | Hero turn | ☐ | `active=` matches your player id; action bar enabled. |
| 2 | Bot turns | ☐ | While `active` is a bot id, action bar disabled; ~0.4s later `bot … → check/call/fold/raise`. |
| 3 | Hero check | ☐ | `hero … → check` then updated `pot` / `street`. |
| 4 | Hero call | ☐ | `hero … → call(…)` when facing a bet. |
| 5 | Hero fold | ☐ | `hero … → fold`; hand may end or continue with fewer actors. |
| 6 | Street advance | ☐ | After betting closes: `hand complete` → `next hand` or street change in snapshot (`street=Flop/Turn/River`). |
| 7 | Bot fold-out | ☐ | All bots fold; pot awarded without showdown; `hand complete` → `next hand`. |
| 8 | Showdown | ☐ | Play to river with callers; winner resolved; stats/pot update in snapshots. |
| 9 | Elimination | ☐ | Play until one player holds all chips; `hand complete` → `endGame`. |
| 10 | EndGameView | ☐ | `phase playing → ended`; stats list, winner highlighted; **Final** shows every player’s chip count (not `—`). |
| 10b | Manual Finish game | ☐ | More options → Finish game (test): chip leader marked winner; all **Final** values populated. |
| 10c | BB option on limp | ☐ | Limp to BB preflop: `[Game]` shows BB check/raise before `street=Flop`. |
| 11 | Play Again | ☐ | Returns to waiting room; bots stripped (`human=1 bot=0` until next Start). |
| 12 | Second session | ☐ | Ready → Start again: `players=5 (human=1 bot=4)` re-seeded; full hand cycle works. |

## Regression — Classic Poker (unchanged)

| # | Step | Pass? |
|---|------|-------|
| C1 | Classic → Send to Chat → solo Ready → Start | ☐ | Solo flow still works; no bot seeding (`bot=0`). |
| C2 | `[Game]` on solo check-through | ☐ | Hero checks through streets; `endGame` without bot lines. |

## Console quick reference

| Log prefix / event | Meaning |
|--------------------|---------|
| `startGame` | Game started from waiting room (bots seeded in practice mode). |
| `phase … → …` | `waiting` / `playing` / `ended` transition. |
| `hero … → …` | Hero check, call, fold, or raise. |
| `bot … → …` | Bot action after scheduler delay. |
| `hand complete` | Betting round finished (`active=nil`). `pot=0` means chips paid to winner (see `lastPot` / `winner` / `stacks=` on same line). |
| `pot awarded …` | Pot moved from table to winner’s stack. |
| `next hand` | New hand dealt (eliminations pending). |
| `endGame` | Session over; navigating to EndGameView. |
| `resetToWaiting` | Play Again / back to lobby. |

## Sign-off

- **Build:** Debug  
- **Device / sim:** _______________  
- **Date:** _______________  
- **All practice rows (1–12):** ☐ Pass ☐ Fail  
- **Classic regression (C1–C2):** ☐ Pass ☐ Fail  
