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
  if ("remainingDeck" in view || "holeCardsByPlayer" in view) throw new Error("runtime leaked");
});

Deno.test("wrong actor cannot act", () => {
  const dealt = applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, "a", { kind: "startGame" }, cards);
  let rejected = false;
  try { applyCommandWithDeck(dealt.publicState, dealt.privateState, "b", { kind: "bet", betKind: "check" }, cards); }
  catch (error) { rejected = error instanceof Error && error.message === "not_your_turn"; }
  if (!rejected) throw new Error("out-of-turn action accepted");
});

Deno.test("host updates waiting-room settings for every player and resets readiness", () => {
  const state = room();
  const result = applyCommandWithDeck(
    state, { remainingDeck: [], holeCardsByPlayer: {} }, "a",
    { kind: "updateSettings", startingStack: 1_000, smallBlind: 10 }, cards,
  );
  const next = result.publicState as Record<string, unknown>;
  const seats = next.players as Array<Record<string, unknown>>;
  if (next.startingStack !== 1_000 || next.smallBlind !== 10) throw new Error("settings not saved");
  if (seats.some((seat) => seat.stack !== 1_000 || seat.isReady !== false)) {
    throw new Error("settings did not reset player stacks and readiness");
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

Deno.test("only the host can update valid waiting-room settings", () => {
  const invalid = (actor: string, command: { kind: "updateSettings"; startingStack: number; smallBlind: number }) => {
    try {
      applyCommandWithDeck(room(), { remainingDeck: [], holeCardsByPlayer: {} }, actor, command, cards);
      return false;
    } catch (error) {
      return error instanceof Error && error.message === "illegal_settings_change";
    }
  };
  if (!invalid("b", { kind: "updateSettings", startingStack: 1_000, smallBlind: 10 })) {
    throw new Error("guest settings update accepted");
  }
  if (!invalid("a", { kind: "updateSettings", startingStack: 100, smallBlind: 5 })) {
    throw new Error("underfunded settings update accepted");
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
