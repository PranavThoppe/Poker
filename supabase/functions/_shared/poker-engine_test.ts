import { applyCommandWithDeck } from "./poker-engine.ts";
import { viewerState, type JsonObject } from "./contracts.ts";

const cards = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
  .flatMap((rank) => ["♠", "♥", "♦", "♣"].map((suit) => ({ rank, suit })));
const player = (id: string, stack = 500) => ({
  id, name: id, stack, isReady: true, isDealer: false, isFolded: false,
  isEliminated: false, isSittingOut: false, currentBet: 0,
});
const room = (): JsonObject => ({
  hostID: "a", phase: { waiting: {} }, players: [player("a"), player("b")],
  board: [null, null, null, null, null], pot: 0, bettingRound: { preFlop: {} },
  activePlayerID: null, completedHandCount: 0,
});

Deno.test("waiting-room leave removes the player and hands host authority to the next seat", () => {
  const result = applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: { a: cards.slice(0, 2), b: cards.slice(2, 4) } },
    "a", { kind: "leaveRoom" }, cards);
  const next = result.publicState as Record<string, unknown>;
  const seats = next.players as Array<Record<string, unknown>>;
  if (seats.length !== 1 || seats[0].id !== "b" || next.hostID !== "b") throw new Error("host leave did not remove and hand off");
  if ("a" in (result.privateState.holeCardsByPlayer as Record<string, unknown>)) throw new Error("leaver private cards retained");
});

Deno.test("last player can leave and waiting sit-out is rejected", () => {
  const state = room();
  state.players = [player("a")];
  const result = applyCommandWithDeck(state, { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "leaveRoom" }, cards);
  if ((result.publicState.players as unknown[]).length !== 0 || result.publicState.hostID !== null) throw new Error("empty room not preserved");
  try {
    applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "setSittingOut", sittingOut: true }, cards);
    throw new Error("waiting sit-out accepted");
  } catch (error) {
    if (error instanceof Error && error.message === "waiting sit-out accepted") throw error;
    if (!(error instanceof Error) || error.message !== "illegal_phase") throw error;
  }
});

Deno.test("leave is rejected after the game starts", () => {
  const state = room();
  state.phase = { playing: {} };
  try {
    applyCommandWithDeck(state, { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "leaveRoom" }, cards);
    throw new Error("in-game leave accepted");
  } catch (error) {
    if (error instanceof Error && error.message === "in-game leave accepted") throw error;
    if (!(error instanceof Error) || error.message !== "illegal_phase") throw error;
  }
});

Deno.test("heads-up deal posts button small blind and hides opponent cards", () => {
  const result = applyCommandWithDeck(
    room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "startGame" }, cards,
  );
  const state = result.publicState as Record<string, unknown>;
  const seats = state.players as Array<Record<string, unknown>>;
  if (state.activePlayerID !== "a" || state.pot !== 15) throw new Error("wrong heads-up opening");
  if (seats[0].stack !== 495 || seats[1].stack !== 490) throw new Error("wrong blinds");
  const view = viewerState(result.publicState, result.privateState, "a") as Record<string, unknown>;
  if (JSON.stringify(view.heroHoleCards) !== JSON.stringify(cards.slice(0, 2))) throw new Error("missing hero cards");
  if (JSON.stringify(view).includes(JSON.stringify(cards.slice(2, 4)))) throw new Error("opponent cards leaked");
  if (JSON.stringify(view.remainingDeck) !== "[]" || JSON.stringify(view.holeCardsByPlayer) !== "{}") {
    throw new Error("runtime leaked");
  }
});

Deno.test("wrong actor cannot act", () => {
  const dealt = applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "startGame" }, cards);
  let rejected = false;
  try { applyCommandWithDeck(dealt.publicState, dealt.privateState, "b", { kind: "bet", betKind: "check" }, cards); }
  catch (error) { rejected = error instanceof Error && error.message === "not_your_turn"; }
  if (!rejected) throw new Error("out-of-turn action accepted");
});

Deno.test("any seated player updates waiting-room settings and resets readiness", () => {
  const state = room();
  const result = applyCommandWithDeck(
    state, { remainingDeck: [], holeCardsByPlayer: {} }, "b",
    { kind: "updateSettings", startingStack: 1_000, smallBlind: 10 }, cards,
  );
  const next = result.publicState as Record<string, unknown>;
  const seats = next.players as Array<Record<string, unknown>>;
  if (next.startingStack !== 1_000 || next.smallBlind !== 10) throw new Error("settings not saved");
  if (seats.some((seat) => seat.stack !== 1_000 || seat.isReady !== false)) {
    throw new Error("settings did not reset player stacks and readiness");
  }
  const announcement = next.lobbySettingsAnnouncement as Record<string, unknown>;
  if (announcement.startingStack !== 1_000 || announcement.smallBlind !== 10 || typeof announcement.id !== "string") {
    throw new Error("accepted settings change did not announce its values");
  }
  if (JSON.stringify(next.phase) !== JSON.stringify({ waiting: {} })) {
    throw new Error("server transition did not preserve Swift's waiting phase format");
  }
});

Deno.test("configured one-chip small blind is used when the game starts", () => {
  const state = room();
  state.smallBlind = 1;
  state.startingStack = 100;
  const result = applyCommandWithDeck(
    state, { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "startGame" }, cards,
  );
  const next = result.publicState as Record<string, unknown>;
  const seats = next.players as Array<Record<string, unknown>>;
  if (next.pot !== 3 || seats[0].stack !== 499 || seats[1].stack !== 498) {
    throw new Error("configured blinds were not posted");
  }
});

Deno.test("invalid settings and non-members are rejected", () => {
  const invalid = (actor: string, command: { kind: "updateSettings"; startingStack: number; smallBlind: number }) => {
    try {
      applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, actor, command, cards);
      return false;
    } catch (error) {
      return error instanceof Error && ["illegal_settings_change", "not_room_member"].includes(error.message);
    }
  };
  if (!invalid("a", { kind: "updateSettings", startingStack: 100, smallBlind: 5 })) {
    throw new Error("underfunded settings update accepted");
  }
  if (!invalid("outsider", { kind: "updateSettings", startingStack: 1_000, smallBlind: 10 })) {
    throw new Error("non-member settings update accepted");
  }
  const live = room();
  live.phase = { handSummary: {} };
  try {
    applyCommandWithDeck(live, { remainingDeck: [], holeCardsByPlayer: {} }, "b",
      { kind: "updateSettings", startingStack: 1_000, smallBlind: 10 }, cards);
    throw new Error("non-waiting settings update accepted");
  } catch (error) {
    if (error instanceof Error && error.message === "non-waiting settings update accepted") throw error;
  }
});

Deno.test("unchanged settings preserve readiness and do not emit an announcement", () => {
  const state = room();
  const result = applyCommandWithDeck(state, { remainingDeck: [], holeCardsByPlayer: {} }, "b",
    { kind: "updateSettings", startingStack: 500, smallBlind: 5 }, cards);
  const next = result.publicState as Record<string, unknown>;
  const seats = next.players as Array<Record<string, unknown>>;
  if (seats.some((seat) => seat.isReady !== true)) throw new Error("unchanged settings reset readiness");
  if (next.lobbySettingsAnnouncement !== undefined && next.lobbySettingsAnnouncement !== null) {
    throw new Error("unchanged settings emitted an announcement");
  }
});

Deno.test("any active player can reset an ended room into a fresh waiting-room rematch", () => {
  const state = room();
  state.phase = { ended: {} };
  state.startingStack = 1_000;
  state.smallBlind = 10;
  state.board = [cards[0], cards[1], cards[2], cards[3], cards[4]];
  state.pot = 75;
  state.handID = "old-hand";
  state.activePlayerID = "a";
  state.completedHandCount = 8;
  state.manualFinishTieAttempts = 1;
  state.handStats = { a: { handsWon: 3 }, b: { handsWon: 2 } };
  state.endStats = [{ id: "a" }];
  const seats = state.players as Array<Record<string, unknown>>;
  seats[0].stack = 0;
  seats[0].isEliminated = true;
  seats[0].isDealer = true;
  seats[0].isFolded = true;
  seats[0].isReady = true;
  seats[0].currentBet = 20;
  seats[1].stack = 925;
  seats[1].isReady = true;

  const result = applyCommandWithDeck(
    state, { remainingDeck: cards.slice(), holeCardsByPlayer: { a: cards.slice(0, 2) } }, "b", { kind: "resetRoom" }, cards,
  );
  const next = result.publicState as Record<string, unknown>;
  const nextSeats = next.players as Array<Record<string, unknown>>;
  if (JSON.stringify(next.phase) !== JSON.stringify({ waiting: {} }) || next.smallBlind !== 10 || next.startingStack !== 1_000) {
    throw new Error("reset did not preserve the configured lobby settings");
  }
  if (nextSeats.some((seat) => seat.stack !== 1_000 || seat.isReady || seat.isDealer || seat.isFolded || seat.isEliminated || seat.currentBet !== 0)) {
    throw new Error("reset did not restore player seats for a fresh match");
  }
  if (next.handID !== null || next.pot !== 0 || (next.board as unknown[]).some(Boolean) || next.completedHandCount !== 0
    || next.manualFinishTieAttempts !== 0 || Object.keys(next.handStats as object).length || (next.endStats as unknown[]).length) {
    throw new Error("reset retained previous-match state");
  }
  const runtime = result.privateState as Record<string, unknown>;
  if ((runtime.remainingDeck as unknown[]).length || Object.keys(runtime.holeCardsByPlayer as object).length) {
    throw new Error("reset retained private cards");
  }
});

Deno.test("reset removes sitting-out seats and rejects reset before a game ends", () => {
  const state = room();
  state.phase = { ended: {} };
  const seats = state.players as Array<Record<string, unknown>>;
  seats[1].isSittingOut = true;
  const result = applyCommandWithDeck(state, { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "resetRoom" }, cards);
  const nextSeats = (result.publicState as Record<string, unknown>).players as Array<Record<string, unknown>>;
  if (nextSeats.length !== 1 || nextSeats[0].id !== "a") throw new Error("sitting-out seat was retained");

  let rejected = false;
  try { applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "resetRoom" }, cards); }
  catch (error) { rejected = error instanceof Error && error.message === "illegal_phase"; }
  if (!rejected) throw new Error("reset was accepted before game end");
});

// --- All-in regression tests -------------------------------------------------
type Seat = Record<string, unknown>;
function allInTable(stacks: number[]) {
  const ids = ["a", "b", "c"].slice(0, stacks.length);
  let pub: JsonObject = {
    hostID: "a", phase: { waiting: {} }, players: ids.map((id, i) => player(id, stacks[i])),
    board: [null, null, null, null, null], pot: 0, bettingRound: { preFlop: {} },
    activePlayerID: null, completedHandCount: 0,
  };
  let priv: JsonObject = { remainingDeck: [], holeCardsByPlayer: {} };
  const total = () => (pub.players as Seat[]).reduce((t, p) => t + (p.stack as number), 0) + (pub.pot as number);
  const send = (id: string | null, command: Parameters<typeof applyCommandWithDeck>[3]) => {
    const who = id ?? (pub.activePlayerID as string);
    const result = applyCommandWithDeck(pub, priv, who, command, cards);
    pub = result.publicState; priv = result.privateState;
    if (pub.handResult && (pub.handResult as Record<string, unknown>).payoutsApplied) return;
    if (total() !== stacks.reduce((a, b) => a + b, 0)) throw new Error(`chips not conserved: ${total()}`);
  };
  const seat = (id: string) => (pub.players as Seat[]).find((p) => p.id === id)!;
  const round = () => Object.keys(pub.bettingRound as object)[0];
  const phase = () => Object.keys(pub.phase as object)[0];
  return { send, seat, round, phase, get active() { return pub.activePlayerID as string | null; }, get pub() { return pub; } };
}

Deno.test("heads-up shove waits for the opponent instead of closing the street", () => {
  const t = allInTable([500, 500]);
  t.send("a", { kind: "startGame" });
  t.send(null, { kind: "bet", betKind: "raise", amount: 500 });
  if (t.round() !== "preFlop" || t.active !== "b") throw new Error(`shove closed early: ${t.round()} active=${t.active}`);
  if (t.seat("a").stack !== 0) throw new Error("shover stack should be 0");
  t.send(null, { kind: "bet", betKind: "call", amount: 490 });
  if (t.phase() !== "showdown") throw new Error(`call should run out the board, got ${t.phase()}`);
});

Deno.test("heads-up shove can be folded to", () => {
  const t = allInTable([500, 500]);
  t.send("a", { kind: "startGame" });
  t.send(null, { kind: "bet", betKind: "raise", amount: 500 });
  t.send(null, { kind: "bet", betKind: "fold" });
  if (t.phase() !== "handSummary") throw new Error(`expected handSummary, got ${t.phase()}`);
  if (t.seat("a").stack !== 510) throw new Error(`shover should win 510, has ${t.seat("a").stack}`);
});

Deno.test("covering player is not prompted after a short all-in call", () => {
  const t = allInTable([500, 200]);
  t.send("a", { kind: "startGame" });
  t.send(null, { kind: "bet", betKind: "raise", amount: 200 });
  t.send(null, { kind: "bet", betKind: "call", amount: 195 });
  if (t.phase() !== "showdown") throw new Error(`should run out to showdown, got ${t.phase()} active=${t.active}`);
});

Deno.test("third player still answers a shove after a short stack calls all-in", () => {
  const t = allInTable([500, 100, 500]);
  t.send("a", { kind: "startGame" });
  t.send(null, { kind: "bet", betKind: "raise", amount: 500 });
  t.send(null, { kind: "bet", betKind: "call", amount: 500 });
  if (t.round() !== "preFlop" || t.active !== "c") throw new Error(`c must respond to the shove: ${t.round()} active=${t.active}`);
  t.send(null, { kind: "bet", betKind: "call", amount: 490 });
  if (t.phase() !== "showdown") throw new Error(`expected showdown, got ${t.phase()}`);
});

Deno.test("a repeated Show from an already-revealed player is a harmless no-op", () => {
  const start = applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "startGame" }, cards);
  let pub = start.publicState, priv = start.privateState;
  const step = (id: string, command: Parameters<typeof applyCommandWithDeck>[3]) => {
    const r = applyCommandWithDeck(pub, priv, id, command, cards); pub = r.publicState; priv = r.privateState;
  };
  step("a", { kind: "bet", betKind: "raise", amount: 500 });
  step("b", { kind: "bet", betKind: "call", amount: 490 });
  const first = (pub.pendingRevealPlayerID as string);
  step(first, { kind: "showCards" });
  const count = ((pub.handResult as Record<string, unknown>).reveals as unknown[]).length;
  step(first, { kind: "showCards" });
  if (((pub.handResult as Record<string, unknown>).reveals as unknown[]).length !== count) throw new Error("duplicate reveal recorded");
});
