import "jsr:@supabase/functions-js@^2/edge-runtime.d.ts";
import { withSupabase } from "npm:@supabase/server@^1";
import { applyCommand, applyExpiredDeadline } from "../_shared/poker-engine.ts";
import { error, parseRequest, UUID, viewerState, type JsonObject, type RequestBody } from "../_shared/contracts.ts";

const limit = 16 * 1024, windowMs = 60_000, perMinute = 30, hits = new Map<string, [number, number]>();
const salt = Deno.env.get("GAME_API_IP_HASH_SALT") ?? "local-development-only";
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "cache-control": "no-store" } });
class ApiError extends Error { constructor(readonly code: string, readonly status = 400) { super(code); } }
const swiftCase = (v: unknown) => typeof v === "string" ? v : v && typeof v === "object" && !Array.isArray(v) ? Object.keys(v)[0] ?? "" : "";
const member = (room: any, id: string) => Array.isArray(room.public_state?.players) && room.public_state.players.some((p: any) => p.id === id);
async function ip(req: Request) { const raw = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "missing"; const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}:${raw}`)); return Array.from(new Uint8Array(d), b => b.toString(16).padStart(2, "0")).join(""); }
async function audit(admin: any, roomID: string | undefined, body: Partial<RequestBody>, req: Request, reason: string, status: number) {
  if (!roomID || !UUID.test(roomID)) return;
  const { data: room } = await admin.from("game_rooms").select("recent_security_events,security_summary").eq("id", roomID).maybeSingle(); if (!room) return;
  const high = status === 403 || status === 429 || reason.includes("stale"); const at = new Date().toISOString();
  const event = { request_id: crypto.randomUUID(), at, operation: body.operation ?? "invalid", room_id: roomID, claimed_player_id: body.playerID ?? null, reason, status, severity: high ? "high" : "normal", command: body.command ? { kind: body.command.kind } : null, user_agent: req.headers.get("user-agent")?.slice(0, 256) ?? "", ip_hash: await ip(req) };
  const old = room.security_summary ?? {}; await admin.from("game_rooms").update({ recent_security_events: [...(room.recent_security_events ?? []), event].slice(-100), security_summary: { total: Number(old.total ?? 0) + 1, high: Number(old.high ?? 0) + (high ? 1 : 0), last_seen_at: at } }).eq("id", roomID);
}
function initial(id: string, player: string, name: string, avatar: number): JsonObject { return { gameID: id, hostID: player, gameMode: "classicPoker", phase: { waiting: {} }, stateVersion: 0, players: [{ id: player, name, stack: 500, isReady: false, isDealer: false, isEliminated: false, isSittingOut: false, currentBet: 0, avatarIndex: avatar, isBot: false }], board: [null, null, null, null, null], pot: 0, bettingRound: { preFlop: {} }, activePlayerID: null, heroHoleCards: [], endStats: [], holeCardsByPlayer: {}, remainingDeck: [], handStats: {}, streetBetLevel: 0, lastRaiseSize: 10, actedThisStreet: [], callAmount: 0, raiseAmount: 0, completedHandCount: 0, manualFinishTieAttempts: 0 }; }

// `ctx` is supplied by @supabase/server; keeping it structural avoids coupling
// this Function to a private package-exported context type.
export default { fetch: withSupabase({ auth: ["publishable", "secret"] }, async (req: Request, ctx: any) => {
  let partial: Partial<RequestBody> = {};
  try {
    if (req.method !== "POST") throw new ApiError("method_not_allowed", 405);
    if (Number(req.headers.get("content-length") ?? 0) > limit) throw new ApiError("payload_too_large", 413);
    const text = await req.text(); if (new TextEncoder().encode(text).byteLength > limit) throw new ApiError("payload_too_large", 413);
    const raw = JSON.parse(text); partial = raw && typeof raw === "object" ? raw as Partial<RequestBody> : {};
    const body = parseRequest(raw); if (!body) throw new ApiError("malformed_body");
    const key = `${await ip(req)}:${body.roomID ?? "new"}:${body.playerID ?? ""}`, now = Date.now(), old = hits.get(key) ?? [0, now + windowMs];
    if (old[1] <= now) { old[0] = 0; old[1] = now + windowMs; } if (++old[0] > perMinute) throw new ApiError("rate_limited", 429); hits.set(key, old);
    if (body.operation === "create-room") {
      if (!body.roomID || !body.playerID || !UUID.test(body.roomID)) throw new ApiError("invalid_room_or_player");
      const state = initial(body.roomID, body.playerID, body.playerName?.trim() || "Player", Math.max(0, Math.floor(body.avatarIndex ?? 0)));
      const { error: e } = await ctx.supabaseAdmin.from("game_rooms").insert({ id: body.roomID, host_id: body.playerID, game_mode: "classicPoker", phase: "waiting", public_state: state, private_state: { remainingDeck: [], holeCardsByPlayer: {} }, server_version: 0 });
      if (e?.code === "23505") {
        // The first response may have been lost while the Function was waking.
        // Treat a retry by the same creator as success, never as a second room.
        const { data: existing } = await ctx.supabaseAdmin.from("game_rooms").select("*").eq("id", body.roomID).maybeSingle();
        if (existing?.host_id === body.playerID) return json({ ok: true, serverVersion: existing.server_version, deadlineAt: existing.deadline_at, state: viewerState(existing.public_state, existing.private_state, body.playerID) });
        throw new ApiError("room_exists", 409);
      }
      if (e) throw new ApiError(`room_create_${e.code ?? "failed"}`, 500);
      return json({ ok: true, serverVersion: 0, state: viewerState(state, { remainingDeck: [], holeCardsByPlayer: {} }, body.playerID) }, 201);
    }
    if (!body.roomID || !body.playerID || !UUID.test(body.roomID)) throw new ApiError("invalid_room_or_player");
    const { data: room } = await ctx.supabaseAdmin.from("game_rooms").select("*").eq("id", body.roomID).maybeSingle(); if (!room) throw new ApiError("room_not_found", 404);
    if (body.operation === "join-room") {
      const state = structuredClone(room.public_state), players = Array.isArray(state.players) ? state.players : [], p = players.find((x: any) => x.id === body.playerID);
      if (p) { p.name = body.playerName?.trim() || p.name; p.avatarIndex = Math.max(0, Math.floor(body.avatarIndex ?? p.avatarIndex ?? 0)); }
      else { if (!["waiting", "handSummary"].includes(swiftCase(state.phase))) throw new ApiError("room_not_joinable", 409); players.push({ id: body.playerID, name: body.playerName?.trim() || "Player", stack: 500, isReady: false, isDealer: false, isFolded: false, isEliminated: false, isSittingOut: false, currentBet: 0, avatarIndex: Math.max(0, Math.floor(body.avatarIndex ?? 0)), isBot: false }); }
      state.players = players; const { error: e } = await ctx.supabaseAdmin.from("game_rooms").update({ public_state: state }).eq("id", room.id); if (e) throw new ApiError("join_failed", 500);
      return json({ ok: true, serverVersion: room.server_version, state: viewerState(state, room.private_state, body.playerID) });
    }
    if (!member(room, body.playerID)) throw new ApiError("not_room_member", 403);
    // Deadline processing is an authoritative transition too. Persist it before
    // serving a snapshot or evaluating a player command so a sleeping client
    // cannot leave a reveal/payout stalled indefinitely.
    const expired = applyExpiredDeadline(room.public_state, room.private_state ?? { remainingDeck: [], holeCardsByPlayer: {} }, room.deadline_at);
    if (expired) {
      expired.publicState.stateVersion = Number(room.server_version) + 1;
      const automaticReceipt = { state: viewerState(expired.publicState, expired.privateState, body.playerID), deadlineAt: expired.deadlineAt };
      const { data: automatic, error: automaticError } = await ctx.supabaseAdmin.rpc("commit_game_transition", { p_room_id: body.roomID, p_actor_device_id: body.playerID, p_action_id: crypto.randomUUID(), p_expected_version: room.server_version, p_public_state: expired.publicState, p_private_state: expired.privateState, p_deadline_at: expired.deadlineAt, p_response: automaticReceipt, p_security_update: null });
      if (automaticError || !automatic?.ok) throw new ApiError("deadline_commit_failed", 500);
      if (body.operation === "room-state") return json(automatic);
      // The command was composed against the pre-timeout version. Its caller must
      // merge this snapshot and intentionally submit again.
      throw new ApiError("stale_state", 409);
    }
    if (body.operation === "room-state") return json({ ok: true, serverVersion: room.server_version, deadlineAt: room.deadline_at, state: viewerState(room.public_state, room.private_state, body.playerID) });
    if (!body.command || !body.actionID || body.expectedVersion === undefined || !UUID.test(body.actionID)) throw new ApiError("malformed_command");
    // Fast-path receipts before stale checks. This mirrors the RPC's ordering and
    // is necessary when a dropped response is retried after later room changes.
    const prior = Array.isArray(room.recent_command_receipts)
      ? room.recent_command_receipts.find((x: any) => x?.action_id === body.actionID) : null;
    if (prior?.response) return json(prior.response);
    if (Number(body.expectedVersion) !== Number(room.server_version)) throw new ApiError("stale_state", 409);
    // Swift JSONEncoder serializes UUID values in uppercase while
    // crypto.randomUUID() uses lowercase. UUID matching is case-insensitive.
    const roomHandID = typeof room.public_state?.handID === "string" ? room.public_state.handID.toLowerCase() : null;
    const expectedHandID = typeof body.expectedHandID === "string" ? body.expectedHandID.toLowerCase() : null;
    if (roomHandID !== expectedHandID) throw new ApiError("stale_hand", 409);
    let t; try { t = applyCommand(room.public_state, room.private_state ?? { remainingDeck: [], holeCardsByPlayer: {} }, body.playerID, body.command); } catch (e) { throw new ApiError(e instanceof Error ? e.message : "illegal_command", 409); }
    t.publicState.stateVersion = Number(room.server_version) + 1; const receipt = { state: viewerState(t.publicState, t.privateState, body.playerID), deadlineAt: t.deadlineAt };
    const { data, error: e } = await ctx.supabaseAdmin.rpc("commit_game_transition", { p_room_id: body.roomID, p_actor_device_id: body.playerID, p_action_id: body.actionID, p_expected_version: body.expectedVersion, p_public_state: t.publicState, p_private_state: t.privateState, p_deadline_at: t.deadlineAt, p_response: receipt, p_security_update: null });
    if (e) throw new ApiError("commit_failed", 500); if (!data?.ok) throw new ApiError(data?.error?.code ?? "commit_rejected", data?.error?.code === "stale_state" ? 409 : 400); return json(data);
  } catch (e) { const x = e instanceof ApiError ? e : new ApiError(e instanceof SyntaxError ? "malformed_body" : "internal_error", 400); await audit(ctx.supabaseAdmin, partial.roomID, partial, req, x.code, x.status); return json(error(x.code, x.status).body, x.status); }
}) };
