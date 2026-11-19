# Server-authoritative Classic Poker migration plan

## Decision and scope

Move **Classic Poker** authority from the creator's iMessage extension to a
Supabase Edge Function. The function becomes the only code allowed to create a
room, join a player, mutate a hand, deal cards, settle pots, or reset a room.
Practice-vs-CPU remains entirely local and keeps the Swift `PokerEngine`.

This plan deliberately does **not** add Supabase Realtime. Clients will call an
Edge Function for an action and receive their own updated state in that HTTP
response. Non-acting clients will continue to poll, but will poll a read-only
`room-state` Function endpoint instead of reading tables directly. That removes
host dependence now; Realtime can later replace only the polling transport.

The word `host` will be removed from authorization and game-flow logic. The
existing `game_rooms.host_id` can remain temporarily as immutable *creator
metadata* for backward compatibility and diagnostics; it must never select who
can deal, resolve, or advance the game.

## Target request flow

```text
iOS client (existing device ID + project publishable/anon key)
  │
  ├─ create-room / join-room / room-state / game-command
  │       (Edge Function; request validation and audit logging)
  ▼
game-api Edge Function
  ├─ validates the caller's claimed seat against the room roster
  ├─ loads the private runtime fields from the room row
  ├─ applies the TypeScript poker engine
  └─ invokes one atomic Postgres commit RPC
          ├─ optimistic version check + row lock
          ├─ public and private snapshots → game_rooms
          └─ bounded command receipts/security telemetry → game_rooms
  ▼
returns sanitized public state + only this caller's two cards
```

The client never submits a `GameState` and never writes `game_rooms`, private
cards, or a deck. It sends only a command plus its `actionID`, expected room
version, and expected hand ID. An action such as `raise(120)` is validated from
the server's current state, not from the value shown in the client UI.

## Trust model and malicious-request monitoring

Classic Poker currently uses `UIDevice.identifierForVendor` as
`ProfileService.deviceID` and has no money or other high-value asset at stake.
This migration preserves that lightweight model: the Edge Function receives the
claimed device/player ID and checks that it is a member of the requested room.
It is a product-level guardrail, not cryptographic proof of identity.

Because callers can be curious or malicious, the Function must record rejected
or suspicious game-table requests in the room's bounded
`recent_security_events` JSON column. Record a generated request ID, timestamp,
operation, room ID, claimed player ID, rejection reason, sanitized command
metadata, HTTP status, user agent, and a salted one-way hash of the forwarded IP
address. Do not persist hole cards, full state snapshots, authorization headers,
or raw IP addresses.

The Function should reject and log: malformed bodies; unknown rooms or players;
commands from a player who is not a room member; stale versions/hand IDs;
illegal turn/phase/bet actions; attempts to request another player's private
cards; oversized payloads; and rate-limit violations. Apply per-IP-hash and
per-room/player limits (for example, 30 requests/minute) and log repeated
rejections as `high` severity. Keep events for 30 days, then prune them with a
scheduled cleanup job. This gives us evidence of abuse without adding an
account/authentication migration now.

Important limitation: without Auth, a request that copies a real player's public
device ID and otherwise looks legal is indistinguishable from that player. The
event table can detect and retain evidence of invalid or anomalous traffic, but
it cannot prove or reliably flag valid-looking impersonation. If that becomes a
problem, Anonymous Auth is the smallest upgrade path because it binds a private
JWT subject to the room seat.

## Current Supabase scaffold

The Supabase project has been initialized and linked to project ref
`vyysmjvojjrwqjvobvfn`. The generated Function entry point is
`supabase/functions/game-api/index.ts`, and the generated migration is
`supabase/migrations/20260919055800_server_poker.sql`. Use that existing
migration for this work; do not create a third migration merely to match an
older filename in this document.

`server_poker` is the intended migration name for this migration. It was
created as part of the Supabase setup and is the only migration that should be
used for the server-authoritative poker schema.

JWT verification is already configured in `supabase/config.toml` for
`game-api`:

```toml
[functions.game-api]
verify_jwt = false
```

This disables Supabase's platform JWT check, which is required because the
current iMessage app does not obtain a Supabase Auth user JWT. It does **not**
make the Function anonymously callable when the generated handler continues to
use `withSupabase({ auth: ["publishable", "secret"] }, ...)`: callers must
still provide a valid `apikey` header containing the project publishable key
(or, for trusted internal callers, a secret key). The Function must later add
the room-roster, request-validation, and rate-limit controls described below;
the publishable key is client identification, not player authentication.

## File impact: 16 files total, with zero new database tables

This count includes the plan itself and assumes the recommended secure design.
It does not require deleting any existing source file in the first release.

| Change | Count | Files |
| --- | ---: | --- |
| Modify existing | 9 | `MessagesViewController.swift`, `Models/PokerModels.swift`, `Networking/SupabaseClient.swift`, `Networking/GameSyncing.swift`, `Networking/SupabaseSync.swift`, `Store/GameStore.swift`, `Store/GameLog.swift`, `docs/Supabase-Database-Inventory.md`, `docs/Multiplayer-ManualTest.md` |
| Add | 4 | this plan, `Networking/GameCommandClient.swift`, `supabase/functions/_shared/contracts.ts`, `supabase/functions/_shared/poker-engine.ts` |
| Already scaffolded; modify | 3 | `supabase/config.toml`, `supabase/functions/game-api/index.ts`, `supabase/migrations/20260919055800_server_poker.sql` |
| Delete | 0 | Keep the legacy private-card code and old `host_id` column during rollout; remove them only after the cutover is proven. |

### Existing files to modify

| File | Add/change | Remove/stop using |
| --- | --- | --- |
| `MessagesViewController.swift` | Await `createRoom` before inserting the bubble and await `joinRoom` when opening it. | Assigning `isHost = true/false`; local `joinGame` as the room-creation mechanism. |
| `Models/PokerModels.swift` | Codable command/request/response models: command kind, `actionID`, expected version, expected hand ID, public snapshot, and viewer cards. Keep wire-compatible public `GameState`. | `hostID` as an authority signal; it becomes creator metadata only. |
| `Networking/SupabaseClient.swift` | Typed Function invocation using the existing publishable/anon key; retain generic REST only for non-game features. Surface HTTP status/error payloads rather than reducing every failure to `badServerResponse`. | Direct game-table GET/POST/DELETE calls. |
| `Networking/GameSyncing.swift` | Redefine the protocol as read-only room observation (poll/start/stop), or retain its name temporarily with `publish` removed. Keep `MockSync` for previews/practice. | The client-side `publish(state:)` contract. |
| `Networking/SupabaseSync.swift` | Poll `game-api` with `operation: room-state`; decode the returned public state and current viewer cards. | Direct `game_rooms` writes, host/deck recovery, direct `player_hole_cards` reads/writes, and `fetchGameRoom`. |
| `Store/GameStore.swift` | Route every Classic mutation through one async `submit(command:)`; immediately merge accepted server response; use polling only for remote changes. Keep local engine calls only under `.practiceVsCPU`. Add in-flight command/UI-error state and retry only with the same `actionID`. | Classic `isHost` gates, `publishCurrentState`, host pending-state resolution, host hole-card recovery, host watchdog actions, host showdown fallback, and roster-merging writes. |
| `Store/GameLog.swift` | Record `actor`/command result/version instead of `host`/`guest`; keep local diagnostic logging. | `device_role` as an authority claim and client-generated authoritative transition logs. |
| `docs/Supabase-Database-Inventory.md` | Document the new private/runtime, command-receipt, and security-telemetry columns on `game_rooms`; mark `game_intents` and `player_hole_cards` as legacy during rollout. | The statement that an on-device host claims `game_intents`. |
| `docs/Multiplayer-ManualTest.md` | Replace host recovery cases with creator-backgrounded/deleted-session continuity, duplicate-request, stale-version, and unauthorized-player cases. | “Host safely advances” expectations. |

### New files to add

| File | Purpose |
| --- | --- |
| `Networking/GameCommandClient.swift` | One typed client for the `game-api` Function; generates/accepts idempotency IDs and maps responses/errors into Swift models. |
| `supabase/functions/_shared/contracts.ts` | Request/response schemas, command discriminated union, public-state sanitizer, and JSON wire types shared by Function entry points. Use runtime validation (for example Zod) before acting on requests. |
| `supabase/functions/_shared/poker-engine.ts` | Server TypeScript port of the Classic-relevant Swift engine: deck creation, dealing, legal action application, pot logic, showdown, summary/reset. No HTTP or database code. |
| `docs/Server-Authoritative-Poker-Migration-Plan.md` | This decision record and operational checklist. |

### Already scaffolded files to modify

| File | Purpose |
| --- | --- |
| `supabase/config.toml` | Retain the existing `[functions.game-api]` setting `verify_jwt = false`; the Function accepts project publishable/secret API keys, not user JWTs. |
| `supabase/functions/game-api/index.ts` | Replace generated greeting with the `create-room`, `join-room`, `room-state`, and `game-command` dispatcher. Retain publishable-key validation and reserve the secret-key path for trusted internal use. |
| `supabase/migrations/20260919055800_server_poker.sql` | Schema, RLS/grant lock-down, atomic commit RPC, and safe migration/backfill checks described below. |

## Commands that the Function owns

Use a single `game-command` request shape after create/join. The command union
should cover every existing Classic mutation:

| Command | Replaces current local behavior |
| --- | --- |
| `setReady { ready }` | `toggleReady()` |
| `startGame` | host-only `startGame()` |
| `bet { kind: fold/check/call/raise, amount? }` | `check/call/raise/fold` |
| `showCards` | `showCards()` including timeout-triggered reveal |
| `advanceSummary` | `advanceToHandSummary()` and abandoned-winner fallback |
| `startNextHand` | host-only `continueAfterHandSummary()` |
| `setSittingOut { sittingOut }` | `sitOutLocalPlayer()` and rejoin state mutation |
| `raiseBlinds { smallBlind }` | `raiseSmallBlind(to:)` |
| `endGame { reason }` | `requestManualEndGame` / `endGame` |
| `resetRoom` | `resetToWaiting()` |

The server validates actor eligibility, phase, player turn, expected version,
hand ID, legal wager size, ready state, and eligible player count. The server
also runs automatic transitions immediately: streets, all-ins, fold-outs,
showdown timeout/reveal, payout, and next summary. No backgrounded phone is
needed to complete them.

For timers, store a server `deadline_at` in the runtime state. Each
`room-state` or command call first processes expired deadlines. Add a scheduled
Function/cron in a later reliability phase if a game must advance while nobody
has the iMessage extension open.

## Database design and migration SQL

Put the following in the new timestamped migration after first checking the
live column types and existing policies. It adds server-only fields to the
existing `game_rooms` row; it creates **no new tables**. Direct mobile access to
that table is revoked, so private fields never leave the Edge Function.

```sql
-- Preconditions to run manually before applying the migration:
-- game_rooms.id must be UUID (or adjust every UUID reference below).
-- Keep a backup/export of game_rooms and player_hole_cards.

alter table public.game_rooms
  add column if not exists server_version bigint not null default 0,
  add column if not exists private_state jsonb,
  add column if not exists deadline_at timestamptz,
  add column if not exists recent_command_receipts jsonb not null default '[]'::jsonb,
  add column if not exists security_summary jsonb not null default
    '{"total":0,"high":0,"last_seen_at":null}'::jsonb,
  add column if not exists recent_security_events jsonb not null default '[]'::jsonb;

-- `private_state` contains the remaining deck and all hole cards. The Function
-- is the only game writer/reader. Its service role bypasses RLS; mobile roles
-- receive no game-table privileges.
alter table public.game_rooms enable row level security;
alter table public.player_hole_cards enable row level security;

revoke all on public.game_rooms, public.player_hole_cards from anon, authenticated;

-- The final migration defines public.commit_game_transition(...), a
-- SECURITY DEFINER function with SET search_path = '' and no grants to anon or
-- authenticated. It must: lock game_rooms FOR UPDATE; search the bounded
-- `recent_command_receipts` JSON array for a duplicate action_id; require the
-- supplied expected version; update public/private state in one transaction;
-- retain only the most recent 100 receipts; and return the committed response.
-- Only the Edge Function's privileged client may call it.
```

The full `commit_game_transition` signature should receive JSON values rather
than try to run the poker engine in PL/pgSQL:

```sql
commit_game_transition(
  p_room_id uuid,
  p_actor_device_id text,
  p_action_id uuid,
  p_expected_version bigint,
  p_public_state jsonb,
  p_private_state jsonb,
  p_deadline_at timestamptz,
  p_response jsonb,
  p_security_update jsonb
) returns jsonb
```

It is an optimistic-concurrency commit: two Functions may compute from version
17, but only one transaction can write version 18. The loser gets a structured
`stale_state` response, refreshes state, and never replays its action under a
new ID without user confirmation. A repeated request with the *same* action ID
returns the original receipt, preventing duplicate bets on transport retry. The
Function keeps the most recent 100 receipts in `game_rooms.recent_command_receipts`.
If an ancient retry falls outside that window, its stale expected version still
rejects it rather than replaying the command.

Do not use `game_intents` for this synchronous design. It is a legacy queue and
is not needed when the Function returns a committed response. Leave it and
`player_hole_cards` in place through the release, deny all client access, and
drop them only after a defined rollback period and verified data retention plan.

`recent_security_events` is also a bounded JSON array on the room row (keep the
latest 100 redacted events); `security_summary` carries total/high-severity
counters and the latest timestamp. This makes suspicious activity visible from
the existing `game_rooms` record without a new audit table. It is intentionally
diagnostic, not a permanent or cross-room analytics log.

## Edge Function implementation details

1. The Supabase CLI layout has already been created and linked to the existing
   project:

   ```sh
   supabase init
   supabase link --project-ref vyysmjvojjrwqjvobvfn
   # Existing migration: 20260919055800_server_poker.sql
   # Existing Function:  game-api
   ```

2. `game-api` is already configured with `verify_jwt = false` in
   `supabase/config.toml`, because the app deliberately has no Supabase Auth
   session. The generated
   `withSupabase` wrapper must remain configured to accept only `publishable`
   and `secret` API-key modes, so the Function requires an `apikey` header even
   though it does not require an `Authorization: Bearer <user JWT>` header.
   Reject/log malformed or abusive requests inside the Function. This setting is
   appropriate only for this low-stakes game; it is not a substitute for user
   authentication.

3. Port the Swift engine mechanically, then prove parity with fixtures before
   exposing the Function. Use deterministic deck input/seed in tests. Fixtures
   must include heads-up blinds, multiway pots, short all-in calls, side pots,
   fold-out, all-in streets, split pots, each showdown reveal step, sit-out,
   rejoin, blind increase, reset, and end-game tie handling.

4. The Function checks the claimed device/player ID against the room roster and
   records every authorization or validation failure in the room's bounded
   security telemetry.
   It must hash the forwarded IP with a Function-held salt before storage, cap
   request size, apply rate limits, and never log cards or whole snapshots. Its
   elevated server database client is confined to the Function. Do not ship a
   secret/service-role key in the iOS extension.

5. `create-room` writes the initial public/private snapshots and creator seat.
   `join-room` atomically creates or refreshes only the caller's player record;
   it cannot overwrite the roster or any game field.
   `room-state` returns the sanitized public snapshot plus private cards only
   for the claimed member after the membership check.

6. Deploy and test in a staging Supabase project first:

   ```sh
   supabase db push
   supabase functions deploy game-api
   ```

   Use the Dashboard Function logs plus a request/correlation ID equal to the
   action ID. Keep database credentials in Supabase-managed Function secrets;
   never add a service key to `SupabaseConstants.swift`.

## Client migration sequence

1. Add Function models/client and a feature flag such as
   `serverAuthoritativeClassicEnabled`. Keep old rooms readable while the flag
   is off.
2. Implement Function create/join/state polling, then switch room entry points
   to those APIs. This proves roster checks, private-card scoping, rate
   limiting, and security-event visibility before gameplay changes.
3. Switch commands one group at a time: lobby/ready, betting, street and
   showdown, summary/next hand, then sit-out/reset/end-game. During each group,
   disable the equivalent local Classic mutation rather than allowing two
   writers.
4. After all command paths are server-owned, remove Classic host watchdogs and
   card restore/retry writes. Keep visual-only board flips and SwiftUI state
   updates locally.
5. Apply direct-table RLS revocation in staging, then production. Confirm that
   the iOS app has no successful direct game-table GET/POST/DELETE calls.
6. After one release/rollback window, remove the legacy `game_intents` and
   `player_hole_cards` paths in a separate migration. Do not combine that
   deletion with the authority cutover.

## Acceptance and rollout checks

- Creator can background, force-quit, or lose connectivity; another seated
  player can complete a legal hand, including street changes and showdown.
- Two devices send commands against the same state; exactly one accepted
  version is produced and neither chips nor cards are duplicated.
- Retrying the exact HTTPS request returns the stored result and never repeats
  a bet, payout, ready toggle, or hand start.
- A stale hand/version returns a recoverable error and triggers a state refresh.
- Direct public-key calls to game tables are denied; direct attempts to request
  another member's cards are denied; Function responses never contain another
  player's unrevealed cards or remaining deck.
- A new install and a reopened extension restore the same device identity; a
  player can only act for their claimed roster seat under the current trust
  model.
- Invalid, stale, oversized, and rate-limited requests receive no game data and
  create appropriately redacted room-security telemetry entries.
- Existing practice mode and its verification suite remain unchanged.
- Before production, run the revised two-device manual checklist plus a
  deterministic server-engine fixture suite and inspect Function/database logs
  by action ID.

## Follow-up: Realtime remains optional

With this plan, the acting player sees a command result immediately and no
particular device is required. Observers still poll. Adding Supabase Realtime
later only changes `SupabaseSync` delivery from polling `room-state` to a push
notification that triggers the same viewer-scoped state fetch; it does not
change authority, the database schema, or the command protocol.
