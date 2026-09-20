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
