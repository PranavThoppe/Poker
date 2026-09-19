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
