# Supabase database inventory

## Scope and confidence

This is a code-based inventory, not a live Dashboard export. The app connects to
the project through its public REST API, but this workspace has no direct
Supabase Dashboard or service-role access. Confirm the exact live names,
columns, row counts, RLS policies, and migrations in Supabase before removing
anything.

The client code and checked-in SQL identify these five active tables:

1. `profiles`
2. `game_rooms`
3. `player_hole_cards`
4. `game_intents`
5. `game_win_credits`

> **Naming check:** the app uses `player_hole_cards`, not
> `profile_hole_cards`, and uses `game_intents`, not `intents`. If the Dashboard
> shows the latter names, they are either older/unused tables or the app will
> not be reading them. Do not rename or drop either version until this is
> verified.

## Classification

| Table | Status | Why it exists | What breaks if removed |
| --- | --- | --- | --- |
| `profiles` | Essential | Stores the device profile: `id`, `display_name`, `avatar_index`, and `lifetime_wins`. It is created/updated during onboarding. | Onboarding sync fails; lifetime-win sync and the win-credit foreign key fail. |
| `game_rooms` | Essential | The current multiplayer-room snapshot: host, game mode, phase, public game state, update time, and version. | Multiplayer join, polling, and state synchronization stop working. |
| `player_hole_cards` | Essential for multiplayer | Stores each player's private cards separately from the public room state, scoped by `room_id`, `player_id`, and `hand_id`. | Players cannot reliably receive/recover their hole cards; private cards would have to be moved into public state, which is unsafe. |
| `game_intents` | Essential for host-authoritative multiplayer | A queue for player actions (`ready`, bets, folds, reset, etc.) which the host claims and resolves. | Guests cannot submit gameplay actions for the host to process. |
| `game_win_credits` | Supporting / optional feature | Idempotency ledger for lifetime-win counting: one row per `(game_id, player_id)`. | The lifetime-wins display can double-count on retries unless this feature and its RPC are removed or redesigned. Core poker gameplay still works. |

## Recommended organization

Keep the four multiplayer tables. Keep `game_win_credits` if the lifetime-win
number on the game-selection screen is a product feature; it is good data
integrity design, not clutter. If lifetime wins are not needed, remove the
feature deliberately as a small unit: the table, `credit_game_win` RPC,
`profiles.lifetime_wins`, and the client-side win-stat service/UI.

The important cleanup is likely **not** consolidation. These tables have
different privacy, lifecycle, and access patterns:

- `game_rooms` contains only public state and is overwritten throughout a game.
- `player_hole_cards` contains secret state and is deleted before each new deal.
- `game_intents` is a short-lived work queue; its resolved history should be
  pruned on a schedule.
- `game_win_credits` is a durable audit/idempotency ledger and should be kept
  while lifetime wins are supported.

Suggested maintenance policy:

| Table | Retention suggestion |
| --- | --- |
| `game_rooms` | Delete abandoned and completed rooms after a defined window (for example 7–30 days), unless game history is a feature. |
| `player_hole_cards` | Delete rows with their parent room; continue deleting a room's rows before every new deal. |
| `game_intents` | Delete resolved/rejected/superseded intents after 7–30 days. Keep pending/claimed rows until safely resolved or expired. |
| `game_win_credits` | Retain while the lifetime-wins counter exists, because it prevents duplicate credits. |
| `profiles` | Retain while device profiles are supported; define an account/data-deletion path before adding more profile data. |

## Showing names next to profile IDs

Do not add a copied display-name column to every table: profile names can change,
and copied values become stale. Instead, run
[`supabase-profile-display-name-views.sql`](supabase-profile-display-name-views.sql).
It creates four read-only views which show the current profile name beside the
stored ID:

| View | Extra display column |
| --- | --- |
| `game_rooms_with_host_name` | `host_display_name` |
| `player_hole_cards_with_profile_name` | `player_display_name` |
| `game_intents_with_profile_name` | `player_display_name` |
| `game_win_credits_with_profile_name` | `player_display_name` |

Open those views in the Supabase Table Editor when inspecting data. The base
tables remain normalized and unchanged.

## Schema improvements worth considering

1. Make `game_rooms.id` the parent key for dependent game tables and add foreign
   keys (with `ON DELETE CASCADE`) where the existing live schema permits it.
   The checked-in SQL currently only proves a foreign key from
   `game_win_credits.player_id` to `profiles.id`.
2. Ensure `player_hole_cards` has a unique key matching its upsert behavior,
   ideally `(room_id, player_id)` (or `(room_id, player_id, hand_id)` if old
   hands are retained rather than deleted).
3. Keep the existing `game_intents (room_id, status, created_at)` index. Add
   indexes only after checking query plans and actual data volume.
4. Review RLS separately for public room state, private hole cards, and RPCs.
   A public `game_rooms` policy must never make hole-card data readable.
5. Use a scheduled cleanup job rather than manual deletion for transient room
   and intent rows.

## Safe live-schema check

Run this read-only query in the Supabase SQL editor to compare the Dashboard to
this document:

```sql
select table_name
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE'
order by table_name;
```

If it returns both `profile_hole_cards` and `player_hole_cards`, first check
which has recent rows and which is referenced by your deployed app/migrations.
Only then plan a migration and remove the obsolete table.
