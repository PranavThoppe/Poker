# Classic Poker lifetime win credits

Classic Poker lifetime wins are credited by the server when it commits the room's first transition to the ended phase. The winner does not need to keep the extension open or tap Done; other players' actions cannot award a win on their behalf.

## Credit rules

The PostgreSQL `commit_game_transition` transaction derives the credit from the final state produced by the server poker engine. It credits only when:

- The room changes from a non-ended phase to ended and is Classic Poker.
- At least two human players are in the final room state.
- At least one hand was completed.
- Exactly one player is marked as the winner in `endStats`.
- The winner has a profile row.

The transaction inserts `(game_id, player_id)` into `game_win_credits` and increments `profiles.lifetime_wins` atomically. The ledger primary key prevents duplicate credits. Ties and no-winner endings are not credited. A missing profile skips the credit instead of preventing the game from ending.

The old client-callable `credit_game_win` RPC is revoked. Clients reconcile their local display count from `profiles.lifetime_wins` when they receive the ended room state and when the profile service starts. Done remains a navigation action.

## Deployment

Apply `supabase/migrations/20261002000000_authoritative_game_win_credits.sql` to Supabase before releasing the client build. The migration updates the transactional room commit function, ensures the profile counter and idempotency ledger exist, and removes direct client access to the legacy credit RPC and ledger. It does not inspect or credit games that ended before the migration is applied.

If a game ends before its winner has a profile row, it will not create a ledger entry or increment the counter. Existing `game_win_credits` rows are retained and are not counted again.

## Acceptance scenarios

- The winner exits before Done is tapped: the server still records one win.
- Another player taps Done or a client retries a command: no additional win is recorded.
- Repeated/duplicate end commands: the room commit receipt and credit ledger prevent a second increment.
- A tie or zero-winner ending: no credit is recorded.
- The winning player reopens the extension: profile reconciliation updates the displayed lifetime count.
