export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export type BetKind = "fold" | "check" | "call" | "raise";
export type GameCommand =
  | { kind: "setReady"; ready: boolean }
  | { kind: "startGame" }
  | { kind: "bet"; betKind: BetKind; amount?: number }
  | { kind: "showCards" }
  | { kind: "advanceSummary" }
  | { kind: "startNextHand" }
  | { kind: "setSittingOut"; sittingOut: boolean }
  | { kind: "updateSettings"; startingStack: number; smallBlind: number }
  | { kind: "raiseBlinds"; smallBlind: number }
  | { kind: "endGame"; reason: string }
  | { kind: "resetRoom" };

export interface RequestBody {
  operation: "create-room" | "join-room" | "room-state" | "game-command";
  roomID?: string;
  playerID?: string;
  playerName?: string;
  avatarIndex?: number;
  actionID?: string;
  expectedVersion?: number;
  expectedHandID?: string | null;
  command?: GameCommand;
}

const operations = new Set(["create-room", "join-room", "room-state", "game-command"]);
const commandKinds = new Set(["setReady", "startGame", "bet", "showCards", "advanceSummary", "startNextHand", "setSittingOut", "updateSettings", "raiseBlinds", "endGame", "resetRoom"]);

export function parseRequest(value: unknown): RequestBody | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (typeof body.operation !== "string" || !operations.has(body.operation)) return null;
  if (body.roomID !== undefined && (typeof body.roomID !== "string" || body.roomID.length > 64)) return null;
  if (body.playerID !== undefined && (typeof body.playerID !== "string" || body.playerID.length > 256)) return null;
  if (body.playerName !== undefined && (typeof body.playerName !== "string" || body.playerName.length > 48)) return null;
  if (body.operation === "game-command") {
    if (typeof body.actionID !== "string" || !UUID.test(body.actionID) || !Number.isSafeInteger(body.expectedVersion)) return null;
    if (!body.command || typeof body.command !== "object" || Array.isArray(body.command) || !commandKinds.has((body.command as {kind?: unknown}).kind as string)) return null;
    const command = body.command as Record<string, unknown>;
    if (command.kind === "setReady" && typeof command.ready !== "boolean") return null;
    if (command.kind === "setSittingOut" && typeof command.sittingOut !== "boolean") return null;
    if (command.kind === "updateSettings") {
      const stack = command.startingStack, smallBlind = command.smallBlind;
      if (typeof stack !== "number" || !Number.isSafeInteger(stack) || stack < 100 || stack > 100_000
        || typeof smallBlind !== "number" || !Number.isSafeInteger(smallBlind) || smallBlind < 1 || smallBlind > 5_000
        || stack < smallBlind * 40) return null;
    }
    if (command.kind === "raiseBlinds" && (!Number.isSafeInteger(command.smallBlind) || (command.smallBlind as number) <= 0)) return null;
    if (command.kind === "bet") {
      if (!["fold", "check", "call", "raise"].includes(command.betKind as string)) return null;
      if (command.amount !== undefined && (!Number.isSafeInteger(command.amount) || (command.amount as number) < 0)) return null;
    }
    if (command.kind === "endGame" && typeof command.reason !== "string") return null;
  }
  return body as unknown as RequestBody;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Removes runtime deck/all-player cards and injects only the viewer's cards. */
export function viewerState(publicState: JsonObject, privateState: JsonObject | null, playerID: string): JsonObject {
  const result = structuredClone(publicState) as JsonObject;
  // Swift's synthesized GameState decoder requires its non-optional runtime
  // properties even when their Swift declarations have defaults. Send harmless
  // empty values here: never the deck or another player's cards.
  result.remainingDeck = [];
  result.holeCardsByPlayer = {};
  result.handStats ??= {};
  result.streetBetLevel ??= 0;
  result.lastRaiseSize ??= 10;
  result.actedThisStreet ??= [];
  result.endStats ??= [];
  const cards = privateState?.holeCardsByPlayer;
  result.heroID = playerID;
  result.heroHoleCards = cards && typeof cards === "object" && !Array.isArray(cards)
    ? ((cards as JsonObject)[playerID] as Json[] | undefined) ?? [] : [];
  // These values depend on the viewing player. They cannot be calculated on
  // the shared room state, which deliberately has no heroID.
  const players = Array.isArray(result.players) ? result.players as JsonObject[] : [];
  const hero = players.find(player => player.id === playerID);
  const integer = (value: Json | undefined, fallback = 0) => typeof value === "number" && Number.isSafeInteger(value) ? value : fallback;
  const currentBet = integer(hero?.currentBet), streetBet = integer(result.streetBetLevel);
  const smallBlind = Math.max(1, integer(result.smallBlind, 5));
  const minimumRaise = streetBet + Math.max(integer(result.lastRaiseSize, smallBlind * 2), smallBlind * 2);
  const heroTotal = currentBet + integer(hero?.stack);
  const opponentTotals = players
    .filter(player => player.id !== playerID && player.isFolded !== true && player.isEliminated !== true)
    .map(player => integer(player.currentBet) + integer(player.stack));
  const maximumRaise = opponentTotals.length ? Math.min(heroTotal, Math.max(...opponentTotals)) : heroTotal;
  result.callAmount = Math.max(0, streetBet - currentBet);
  result.raiseAmount = Math.min(minimumRaise, maximumRaise);
  return result;
}

export function error(code: string, status = 400, message?: string) {
  return { status, body: { ok: false, error: { code, message } } };
}
