# WebSocket multiplayer migration plan

## Decision and scope

Replace Classic Poker's **2-second HTTPS `room-state` polling** with a
**room-scoped WebSocket** game server, while keeping the existing
server-authoritative TypeScript poker engine and command contract.

This is a **transport change**, not a rewrite of game rules or authority.
Practice-vs-CPU remains entirely local on the Swift `PokerEngine`.

Supabase can stay for profiles / lifetime stats during the transition, or be
dropped later once the game server owns persistence. Do **not** make clients
peer-to-peer over WebSockets, and do **not** push private decks or other
players' hole cards to every seat.

Related prior decision: `docs/Server-Authoritative-Poker-Migration-Plan.md`
explicitly deferred Realtime as an optional follow-up that would replace only
the polling transport. This plan is that follow-up, implemented on a dedicated
game server (EC2 / App Runner / ECS) rather than Supabase Realtime.

## Current state (before this change)

```text
iMessage client
  │
  ├─ create-room / join-room / game-command  →  HTTPS POST game-api
  └─ room-state poll every ~2s               →  HTTPS POST game-api
        │
        ▼
  Supabase Edge Function (game-api)
        ├─ validates seat / command
        ├─ applies poker-engine.ts
        └─ commit_game_transition → Postgres game_rooms
        │
        ▼
  returns sanitized public_state + viewer hole cards
```

Authority is already correct: clients never submit a `GameState`. The pain
point at scale is polling latency, Edge Function cold/warm cost, and coupling
multiplayer sync to Supabase Functions instead of a long-lived process that can
own timers and push updates.

## Target architecture

Three layers used by most multiplayer games:

| Layer | Job | Today | After |
| --- | --- | --- | --- |
| 1. Transport | Connect clients; deliver messages | HTTPS POST + 2s poll | One `wss://` connection per device; server pushes state |
| 2. Room / session | Route players into a table | `game_rooms` row + Edge Function | In-memory `Room` keyed by `roomId` |
| 3. Authority | Validate + mutate game state | TS `PokerEngine` + commit RPC | Same engine, called from WS handlers |

### Target request flow

```text
iOS client (device ID)
  │
  ├─ wss://game.example.com  (persistent)
  │     hello / create_room / join_room / command / ping
  ▼
Game server (Node/Bun on EC2 or App Runner)
  ├─ Map<roomId, Room>
  │     ├─ roster of socket ↔ playerId
  │     ├─ public_state + private_state (deck, hole cards)
  │     └─ deadlines / auto-fold timers in-process
  ├─ validates caller against room roster
  ├─ applies the same TypeScript poker engine
  └─ optional persist / flush → Postgres (or SQLite)
  ▼
pushes viewer-scoped room_state on each socket
  (public board + only that seat's hole cards)
```

Canonical pattern: **room-as-process**. Clients never talk to each other; they
only send commands to the room and receive sanitized snapshots.

## Message protocol

Keep wire shapes close to the existing `GameCommand` / `room-state` contract so
`GameStore` merge logic stays intact.

### Client → server

| Type | Purpose |
| --- | --- |
| `hello` | `deviceId`, optional `roomId` for reconnect |
| `create_room` | Create table; return `roomId` for iMessage bubble URL |
| `join_room` | Seat player into existing room |
| `command` | Same command union as today (`bet`, `setReady`, `leaveRoom`, …) plus `actionID`, `expectedVersion`, `expectedHandID` |
| `ping` | Keepalive while the iMessage extension is backgrounded |

### Server → client

| Type | Purpose |
| --- | --- |
| `room_state` | Viewer-sanitized public snapshot + this player's hole cards + `server_version` |
| `acked` | Idempotent receipt for an `actionID` |
| `error` | Stale version, illegal action, not a member, rate limit |
| `deadline` | Optional timer tick / auto-fold notice |

### Invariants (do not relax)

- Server never trusts a client-authored `GameState`.
- Only the viewing player's hole cards are sent on that socket.
- Optimistic concurrency: `expectedVersion` (+ `expectedHandID` where used).
- Idempotent `actionID` receipts so retries / reconnects do not double-apply.
- Reject and log: unknown rooms, non-members, illegal turns, oversized payloads.

Example command envelope:

```json
{
  "type": "command",
  "roomId": "…",
  "playerId": "…",
  "actionID": "…",
  "expectedVersion": 42,
  "expectedHandID": "…",
  "command": { "kind": "bet", "action": "raise", "amount": 120 }
}
```

Example pushed state:

```json
{
  "type": "room_state",
  "server_version": 43,
  "public_state": { },
  "heroHoleCards": [ … ]
}
```

## AWS hosting (student credits)

Poker tables are low bandwidth. Prefer process uptime and sticky rooms over
fancy matchmaking.

| Option | Fit | When to use |
| --- | --- | --- |
| EC2 (`t3` / `t4g.micro` or `small`) | Simplest mental model | Learning / first deploy: one Node process, `wss` on 443 |
| App Runner / ECS Fargate | Less ops than raw EC2 | Deploy-from-image without SSH babysitting |
| API Gateway WebSocket + Lambda | Serverless fan-out | Avoid for turn-based poker with timers (cold starts + connection state in DynamoDB) |
| GameLift / FlexMatch | Matchmaking at scale | Overkill until thousands of concurrent tables |

### Practical EC2 starter

1. One Ubuntu or Amazon Linux box, Node 20+, process manager (`systemd` or `pm2`).
2. WebSocket library: `ws`, or Socket.IO if you want rooms/reconnect helpers.
3. Terminate TLS with Caddy or nginx + Let's Encrypt so iOS can use `wss://`.
4. Security group: 443 inbound only; SSH locked to your IP.
5. Persist rooms to Postgres (RDS free tier or existing Supabase Postgres) so a
   restart can restore waiting rooms; active hand state can live in memory with
   periodic flush.

One small VM is enough for hundreds of concurrent 2–9 player turn-based tables.
Split across instances only when needed, using sticky routing (`roomId` →
instance) via Redis pub/sub or a room registry.

## Migration steps for this repo

| Step | Change | Leave alone |
| ---: | --- | --- |
| 1 | Extract `poker-engine` + `contracts` into a standalone Node package runnable outside Deno Edge | Swift `PokerEngine` (practice mode) |
| 2 | Add `GameServer`: `Map<roomId, Room>`; WS join + command handlers calling the same engine | Command shapes / `actionID` / `expectedVersion` |
| 3 | Replace `SupabaseSync` poller with a `WebSocketSync` that merges pushed `room_state` | `GameStore.submit` merge path |
| 4 | Point create/join at HTTP bootstrap or first WS messages | iMessage bubble URL encoding session id |
| 5 | Optional: keep Supabase for profiles / lifetime wins only | Or move those reads to the same EC2 API later |

### Likely file impact (when implemented)

| Area | Files |
| --- | --- |
| New server | e.g. `server/` Node package: WS entry, room map, reused engine/contracts |
| Client networking | `Networking/SupabaseSync.swift` → `WebSocketSync` (or dual behind `GameSyncing`) |
| Client commands | `Networking/GameCommandClient.swift` — WS send path alongside or instead of Edge Function |
| Store | `Store/GameStore.swift` — keep submit/merge; swap sync implementation |
| Docs / tests | This plan; update `Multiplayer-ManualTest.md` for reconnect / push latency |

Do not rewrite practice-vs-CPU or the local Swift engine as part of this work.

## What not to do

- Do not peer-connect iMessage clients to each other.
- Do not broadcast full `private_state` (deck / all hole cards).
- Do not remove version checks and `actionID` receipts because “WebSocket is
  reliable” — reconnect and duplicate delivery still happen.
- Do not start with API Gateway WebSocket + Lambda for the authoritative room
  process.
- Do not rip out Supabase on day one; prove the WS room server first, then
  shrink Supabase to stats-only or remove it.

## Suggested first spike

1. Stand up a Node process with `create_room` / `join_room` / `command` +
   broadcast using the existing TS engine.
2. Exercise it with `wscat` (or a tiny Swift `URLSessionWebSocketTask` harness).
3. Implement `WebSocketSync` behind `GameSyncing` so Classic mode can flip
   transports without rewriting `GameStore`.
4. Only then wire production TLS + EC2/App Runner and cut Classic off polling.

## Success criteria

- Acting player sees their own accepted state immediately on the command ack /
  pushed `room_state` (no 2s wait).
- Non-acting players receive pushed updates without polling.
- Illegal / stale / non-member commands are rejected with the same semantics as
  `game-api` today.
- Reconnect with the same `deviceId` + `roomId` restores the seat and resumes
  viewer-scoped state.
- Practice-vs-CPU is unchanged.
- Creator quitting / backgrounding the iMessage extension does not stall the
  table (server owns timers and authority).
