import type { GameCommand, JsonObject } from "./contracts.ts";

export interface Card { rank: string; suit: string }
export interface PokerRuntime { remainingDeck: Card[]; holeCardsByPlayer: Record<string, Card[]> }
export interface Transition { publicState: JsonObject; privateState: JsonObject; deadlineAt: string | null }
type P = Record<string, any>;
type S = JsonObject & Record<string, any>;

const SB=5;
const SHOW=10;
const SUMMARY=14;
const suits=["♥","♦","♣","♠"];
const ranks=["2","3","4","5","6","7","8","9","10","J","Q","K","A"];

const cp=<T>(x:T):T=>structuredClone(x);
const n=(x:any,d=0)=>Number.isSafeInteger(x)?x:d;
const on=(x:any)=>x===true;
const ps=(s:S):P[]=>(s.players??=[]);
const fail=(x:string):never=>{throw new Error(x)};
const br=(s:S)=>Math.max(n(s.smallBlind,SB),1)*2;
const getPlayer=(s:S,id:string):P=>{
  const p=ps(s).find(x=>x.id===id);
  if(p)return p;
  return fail("not_room_member");
};
const getPlayerIndex=(s:S,id:string):number=>{
  const i=ps(s).findIndex(x=>x.id===id);
  if(i>=0)return i;
  return fail("not_room_member");
};
const rt=(x:JsonObject):PokerRuntime=>({
  remainingDeck:Array.isArray(x.remainingDeck)?x.remainingDeck as unknown as Card[]:[],
  holeCardsByPlayer:x.holeCardsByPlayer&&typeof x.holeCardsByPlayer==="object"&&!Array.isArray(x.holeCardsByPlayer)?x.holeCardsByPlayer as unknown as Record<string,Card[]>:{}
});

const eligible=(p:P)=>!on(p.isEliminated)&&!on(p.isSittingOut)&&n(p.stack)>0;
const inHand=(p:P)=>!on(p.isEliminated)&&!on(p.isFolded);
const live=(p:P)=>eligible(p)&&!on(p.isFolded);

const value=(c:Card)=>ranks.indexOf(c.rank)+2;
const handNames=["High Card","Pair","2 Pairs","3 of a Kind","Straight","Flush","Full House","4 of a Kind","Straight Flush","Royal Flush"];

/** Server entropy only; no request may provide cards, deck order, or a seed. */
export function cryptoDeck():Card[]{
  const deck=suits.flatMap(s=>ranks.map(rank=>({rank,suit:s})));
  
  // Fisher-Yates shuffle with cryptographic randomness
  for(let i=deck.length-1;i;i--){
    let randomValue:number;
    const limit=Math.floor(4294967296/(i+1))*(i+1);
    
    // Rejection sampling to avoid modulo bias
    do{
      randomValue=crypto.getRandomValues(new Uint32Array(1))[0];
    }while(randomValue>=limit);
    
    const j=randomValue%(i+1);
    [deck[i],deck[j]]=[deck[j],deck[i]];
  }
  
  return deck;
}

/** Pure test hook. It is deliberately not used by the HTTP dispatcher. */
export function applyCommandWithDeck(a:JsonObject,b:JsonObject,id:string,c:GameCommand,deck:Card[]):Transition{
  return go(a,b,id,c,()=>cp(deck));
}

export function applyCommand(a:JsonObject,b:JsonObject,id:string,c:GameCommand):Transition{
  return go(a,b,id,c,cryptoDeck);
}
function go(pub:JsonObject,priv:JsonObject,id:string,c:GameCommand,f:()=>Card[]):Transition{
  const s=cp(pub)as S;
  const r=rt(cp(priv)as JsonObject);
  const p=getPlayer(s,id);
  switch(c.kind){
    case"setReady":
      if(!["waiting","handSummary"].includes(s.phase)||!eligible(p))fail("actor_ineligible");
      p.isReady=c.ready;
      break;
    case"startGame":
      start(s,r,id,f);
      break;
    case"bet":
      action(s,r,id,c.betKind,c.amount);
      break;
    case"showCards":
      show(s,r,id);
      break;
    case"advanceSummary":
      if(s.phase!=="showdown"||s.pendingRevealPlayerID)fail("reveal_incomplete");
      finish(s);
      break;
    case"startNextHand":
      next(s,r,id,f);
      break;
    case"setSittingOut":
      sit(s,r,id,c.sittingOut);
      break;
    case"updateSettings":
      settings(s,id,c.startingStack,c.smallBlind);
      break;
    case"raiseBlinds":
      if(s.phase!=="handSummary"||s.hostID&&s.hostID!==id||!Number.isSafeInteger(c.smallBlind)||c.smallBlind<=n(s.smallBlind,SB))fail("illegal_blind_change");
      s.smallBlind=c.smallBlind;
      s.blindIncreaseAnnouncement={id:crypto.randomUUID(),smallBlind:c.smallBlind};
      break;
    case"endGame":
      end(s,id,c.reason);
      break;
    case"resetRoom":
      reset(s,r,id);
      break;
  }
  ui(s);
  return{publicState:s,privateState:r as unknown as JsonObject,deadlineAt:deadline(s)};
}
/** Function callers invoke this before reads and commands. */
export function applyExpiredDeadline(pub:JsonObject,priv:JsonObject,at:string|null,now=new Date()):Transition|null{
  const time=at?Date.parse(at):NaN;
  if(!Number.isFinite(time)||time>now.getTime())return null;
  
  const s=cp(pub)as S;
  const r=rt(cp(priv)as JsonObject);
  
  if(s.phase!=="showdown")return null;
  
  if(s.pendingRevealPlayerID){
    show(s,r,s.pendingRevealPlayerID);
  }
  else{
    finish(s);
  }
  
  ui(s);
  return{publicState:s,privateState:r as unknown as JsonObject,deadlineAt:deadline(s)};
}
function dealer(s:S){
  return Math.max(0,ps(s).findIndex(p=>on(p.isDealer)));
}

function scan(s:S,from:number,fn:(p:P)=>boolean,inc=false){
  const offset=inc?0:1;
  for(let o=offset;o<ps(s).length;o++){
    const i=(from+o)%ps(s).length;
    if(fn(ps(s)[i]))return i;
  }
  return null;
}
function settings(s:S,id:string,stack:number,smallBlind:number){
  const isHost=!s.hostID||s.hostID===id;
  const validStack=Number.isSafeInteger(stack)&&stack>=100&&stack<=100000;
  const validSmallBlind=Number.isSafeInteger(smallBlind)&&smallBlind>=1&&smallBlind<=5000;
  const validRatio=stack>=smallBlind*40;
  
  if(s.phase!=="waiting"||!isHost||!validStack||!validSmallBlind||!validRatio){
    fail("illegal_settings_change");
  }
  
  s.startingStack=stack;
  s.smallBlind=smallBlind;
  ps(s).forEach(p=>{
    p.stack=stack;
    p.isReady=false;
  });
}
function blinds(s:S):[number,number]|null{
  const eligiblePlayers=ps(s).filter(eligible);
  const dealerIndex=dealer(s);
  
  if(eligiblePlayers.length<2)return null;
  
  const smallBlindIndex=eligiblePlayers.length===2?dealerIndex:scan(s,dealerIndex,eligible);
  const bigBlindIndex=smallBlindIndex===null?null:scan(s,smallBlindIndex,eligible);
  
  return smallBlindIndex===null||bigBlindIndex===null?null:[smallBlindIndex,bigBlindIndex];
}
function post(s:S,i:number,x:number){
  const player=ps(s)[i];
  const chipsToBet=Math.min(Math.max(0,x),n(player.stack));
  
  if(!chipsToBet)return;
  
  player.stack=n(player.stack)-chipsToBet;
  player.currentBet=n(player.currentBet)+chipsToBet;
  s.pot=n(s.pot)+chipsToBet;
  
  const contributions=s.contributions??={};
  contributions[player.id]=n(contributions[player.id])+chipsToBet;
  
  s.streetBetLevel=Math.max(n(s.streetBetLevel),n(player.currentBet));
}
function mark(s:S,id:string){
  const actedList=s.actedThisStreet??=[];
  if(!actedList.includes(id))actedList.push(id);
}

function allin(s:S){
  ps(s)
    .filter(p=>inHand(p)&&n(p.stack)===0)
    .forEach(p=>mark(s,p.id));
}
function clear(s:S){
  ps(s).forEach(p=>p.currentBet=0);
  s.streetBetLevel=0;
  s.actedThisStreet=[];
  s.activePlayerID=null;
}
function first(s:S,pre:boolean){
  const blindPositions=blinds(s);
  const eligiblePlayerCount=ps(s).filter(eligible).length;
  const dealerIndex=dealer(s);
  
  let startIndex;
  if(pre&&blindPositions){
    // Pre-flop: start after big blind (or after small blind in heads-up)
    const bigBlindIndex=blindPositions[1];
    startIndex=eligiblePlayerCount===2?blindPositions[0]:(bigBlindIndex+1)%ps(s).length;
  }
  else{
    // Post-flop: start after dealer
    startIndex=(dealerIndex+1)%ps(s).length;
  }
  
  const firstLivePlayerIndex=scan(s,startIndex,live,true);
  s.activePlayerID=firstLivePlayerIndex===null?null:ps(s)[firstLivePlayerIndex].id;
}
function rotate(s:S){
  const oldDealerIndex=ps(s).findIndex(p=>on(p.isDealer));
  
  if(oldDealerIndex>=0){
    ps(s)[oldDealerIndex].isDealer=false;
    const nextDealerIndex=scan(s,oldDealerIndex,eligible);
    if(nextDealerIndex!==null)ps(s)[nextDealerIndex].isDealer=true;
  }
  else{
    const firstEligibleIndex=ps(s).findIndex(eligible);
    if(firstEligibleIndex>=0)ps(s)[firstEligibleIndex].isDealer=true;
  }
}
function start(s:S,r:PokerRuntime,id:string,f:()=>Card[]){
  if(!["waiting","handSummary"].includes(s.phase))fail("illegal_phase");
  if(s.hostID&&s.hostID!==id)fail("not_host");
  
  const eligiblePlayers=ps(s).filter(eligible);
  if(!eligiblePlayers.length||!eligiblePlayers.every(p=>on(p.isReady)))fail("not_all_ready");
  if(eligiblePlayers.length<2&&ps(s).some(p=>on(p.isSittingOut)))fail("insufficient_players");
  
  // Initialize player state for new hand
  ps(s).forEach(p=>{
    p.isFolded=false;
    p.currentBet=0;
    const stats=(s.handStats??={})[p.id]??={handsWon:0,handsPlayed:0,biggestPot:0};
    if(eligible(p)){
      stats.handsPlayed=n(stats.handsPlayed)+1;
    }
  });
  
  // Initialize hand state
  s.board=[null,null,null,null,null];
  s.handID=crypto.randomUUID();
  s.pot=0;
  s.streetBetLevel=0;
  s.lastRaiseSize=br(s);
  s.actedThisStreet=[];
  s.contributions={};
  s.handResult=null;
  s.lastAggressorID=null;
  s.pendingRevealPlayerID=null;
  s.bettingRound="preFlop";
  s.phase="playing";
  
  rotate(s);
  
  // Deal cards
  r.remainingDeck=f();
  r.holeCardsByPlayer={};
  ps(s).filter(eligible).forEach(p=>{
    const card1=draw(r);
    const card2=draw(r);
    r.holeCardsByPlayer[p.id]=[card1,card2].filter(Boolean)as Card[];
  });
  
  // Post blinds
  const blindPositions=blinds(s);
  if(blindPositions){
    const smallBlindIndex=blindPositions[0];
    const bigBlindIndex=blindPositions[1];
    const smallBlindAmount=Math.min(n(s.smallBlind,SB),n(ps(s)[smallBlindIndex].stack));
    const bigBlindAmount=Math.min(br(s),n(ps(s)[bigBlindIndex].stack));
    post(s,smallBlindIndex,smallBlindAmount);
    post(s,bigBlindIndex,bigBlindAmount);
    allin(s);
  }
  
  first(s,true);
  
  // If no active player (all all-in), resolve immediately
  if(!s.activePlayerID)resolve(s,r);
}
function draw(r:PokerRuntime){
  return r.remainingDeck.shift()??null;
}

function round(s:S){
  return s.bettingRound;
}
function cap(s:S,id:string){
  const me=getPlayer(s,id);
  const myTotalChips=n(me.currentBet)+n(me.stack);
  
  const otherPlayerChips=ps(s)
    .filter(p=>p.id!==id&&!on(p.isFolded)&&!on(p.isEliminated))
    .map(p=>n(p.currentBet)+n(p.stack));
  
  return otherPlayerChips.length?Math.min(myTotalChips,Math.max(...otherPlayerChips)):myTotalChips;
}
function done(s:S){
  const playersInHand=ps(s).filter(inHand);
  const eligiblePlayers=ps(s).filter(eligible);
  
  // Hand is over if only one player left or only one player not eliminated
  if(playersInHand.length<=1||eligiblePlayers.length===1)return true;
  
  const liveActors=playersInHand.filter(live);
  const actedSet=new Set(s.actedThisStreet??[]);
  const currentBetLevel=n(s.streetBetLevel);
  
  // Betting round is complete if no live players or all have acted and matched the bet
  return !liveActors.length||liveActors.every(p=>n(p.currentBet)>=currentBetLevel&&actedSet.has(p.id));
}
function doFold(player:P){
  player.isFolded=true;
}

function doCheck(player:P,currentBetLevel:number){
  if(n(player.currentBet)!==currentBetLevel)fail("illegal_check");
}

function doCall(s:S,playerIndex:number,player:P,currentBetLevel:number,amount:number|undefined){
  const playerCurrentBet=n(player.currentBet);
  const amountOwed=Math.min(currentBetLevel-playerCurrentBet,n(player.stack));
  if(currentBetLevel<=playerCurrentBet||amountOwed<=0||!Number.isSafeInteger(amount)||amount!<amountOwed)fail("illegal_call");
  post(s,playerIndex,amountOwed);
}

function minRaiseSize(s:S):number{
  return Math.max(n(s.lastRaiseSize,br(s)),br(s));
}

function minRaiseTo(s:S):number{
  return n(s.streetBetLevel)+minRaiseSize(s);
}

function doRaise(s:S,playerIndex:number,id:string,player:P,currentBetLevel:number,amount:number|undefined){
  const playerCurrentBet=n(player.currentBet);
  const raiseTo=amount!;
  const maxRaise=cap(s,id);
  if(!Number.isSafeInteger(raiseTo)||raiseTo<=currentBetLevel||raiseTo>maxRaise)fail("illegal_raise");
  
  const additionalChipsNeeded=raiseTo-playerCurrentBet;
  const minRaise=minRaiseTo(s);
  const allInAmount=playerCurrentBet+n(player.stack);
  
  if(additionalChipsNeeded<=0||additionalChipsNeeded>n(player.stack))fail("illegal_raise");
  if(raiseTo<minRaise&&raiseTo!==allInAmount)fail("illegal_raise");
  
  post(s,playerIndex,additionalChipsNeeded);
  
  // Track raise size and aggressor if this is a full raise (not just all-in short)
  const raiseSize=raiseTo-currentBetLevel;
  const minSize=minRaiseSize(s);
  if(raiseSize>=minSize){
    s.lastRaiseSize=raiseSize;
    s.lastAggressorID=id;
    // Clear acted list - everyone needs to act again after a raise
    s.actedThisStreet=[id];
    allin(s);
  }
}

function action(s:S,r:PokerRuntime,id:string,k:string,amount?:number){
  if(s.phase!=="playing"||s.activePlayerID!==id)fail("not_your_turn");
  
  const playerIndex=getPlayerIndex(s,id);
  const player=ps(s)[playerIndex];
  const currentBetLevel=n(s.streetBetLevel);
  
  if(!live(player))fail("actor_ineligible");
  
  if(k==="fold"){
    doFold(player);
  }
  else if(k==="check"){
    doCheck(player,currentBetLevel);
  }
  else if(k==="call"){
    doCall(s,playerIndex,player,currentBetLevel,amount);
  }
  else if(k==="raise"){
    doRaise(s,playerIndex,id,player,currentBetLevel,amount);
  }
  else{
    fail("illegal_bet");
  }
  
  mark(s,id);
  
  // Check if hand is over (only one player left in hand)
  const playersInHand=ps(s).filter(inHand);
  const eligiblePlayers=ps(s).filter(p=>!on(p.isEliminated)&&!on(p.isSittingOut));
  if(playersInHand.length===1&&eligiblePlayers.length>1){
    award(s,r,false);
    return;
  }
  
  // Check if betting round is complete
  if(done(s)){
    resolve(s,r);
  }
  else{
    // Move to next active player
    const nextPlayerIndex=scan(s,playerIndex,live);
    s.activePlayerID=nextPlayerIndex===null?null:ps(s)[nextPlayerIndex].id;
    if(!s.activePlayerID&&!ps(s).some(live))resolve(s,r);
  }
}
function resolve(s:S,r:PokerRuntime){
  const currentRound=round(s);
  
  if(currentRound==="river"){
    uncalled(s);
    award(s,r,true);
    return;
  }
  
  uncalled(s);
  clear(s);
  allin(s);
  
  // Burn a card
  draw(r);
  
  // Deal community cards based on current round
  if(currentRound==="preFlop"){
    s.board.splice(0,3,draw(r),draw(r),draw(r));
    s.bettingRound="flop";
  }
  else if(currentRound==="flop"){
    s.board[3]=draw(r);
    s.bettingRound="turn";
  }
  else{
    s.board[4]=draw(r);
    s.bettingRound="river";
  }
  
  first(s,false);
  
  // If no live players remain, continue to next street
  if(!ps(s).some(live))resolve(s,r);
}
function uncalled(s:S){
  const contributions=s.contributions??={};
  // Sort contributors by amount descending to find the largest
  const sortedContributors=Object.entries(contributions)
    .filter(([,v])=>n(v)>0)
    .sort((x,y)=>n(y[1])-n(x[1]));
  
  if(sortedContributors.length<2)return;
  
  // Invariant: uncalled bet is only returned to the single largest contributor
  const largestContribution=n(sortedContributors[0][1]);
  const secondLargestContribution=n(sortedContributors[1][1]);
  const uncalledAmount=largestContribution-secondLargestContribution;
  const largestContributorId=sortedContributors[0][0];
  const player=ps(s).find(p=>p.id===largestContributorId);
  
  if(!uncalledAmount||!player)return;
  
  // Return the uncalled portion to the player
  player.stack=n(player.stack)+uncalledAmount;
  player.currentBet=Math.max(0,n(player.currentBet)-uncalledAmount);
  s.pot=Math.max(0,n(s.pot)-uncalledAmount);
  contributions[player.id]=n(contributions[player.id])-uncalledAmount;
}
function cmp(a:number[],b:number[]){for(let i=0;i<Math.max(a.length,b.length);i++)if((a[i]??0)!==(b[i]??0))return(a[i]??0)>(b[i]??0)?1:-1;return 0}
function five(cs:Card[]){const v=cs.map(value).sort((a,b)=>b-a),m=new Map<number,number>();v.forEach(x=>m.set(x,(m.get(x)??0)+1));const g=[...m.entries()].sort((a,b)=>b[1]-a[1]||b[0]-a[0]),u=[...new Set(v)].sort((a,b)=>b-a),flush=cs.length===5&&new Set(cs.map(x=>x.suit)).size===1;let st=0;if(cs.length===5){if([14,5,4,3,2].every(x=>u.includes(x)))st=5;else for(let i=0;i<=u.length-5;i++)if(u[i]-u[i+4]===4){st=u[i];break}}if(flush&&st)return[st===14&&v.includes(10)?9:8,st];const q=g.find(x=>x[1]===4);if(q)return[7,q[0],v.find(x=>x!==q[0])??0];const t=g.find(x=>x[1]===3),p=g.find(x=>x[1]===2&&x[0]!==t?.[0]);if(t&&p)return[6,t[0],p[0]];if(flush)return[5,...v];if(st)return[4,st];if(t)return[3,t[0],...v.filter(x=>x!==t[0])];const pairs=g.filter(x=>x[1]===2);if(pairs.length>1)return[2,pairs[0][0],pairs[1][0],v.find(x=>x!==pairs[0][0]&&x!==pairs[1][0])??0];if(pairs[0])return[1,pairs[0][0],...v.filter(x=>x!==pairs[0][0])];return[0,...v]}
function* combos5(cards:Card[]):Generator<Card[]>{if(cards.length<=5){yield cards;return}for(let a=0;a<cards.length-4;a++)for(let b=a+1;b<cards.length-3;b++)for(let d=b+1;d<cards.length-2;d++)for(let e=d+1;e<cards.length-1;e++)for(let f=e+1;f<cards.length;f++)yield[cards[a],cards[b],cards[d],cards[e],cards[f]]}
function score(c:Card[]){let best=[0];for(const combo of combos5(c)){const x=five(combo);if(cmp(x,best)>0)best=x}return best}
function layers(s:S){
  const contributions=s.contributions??={};
  
  // Get unique contribution levels, sorted ascending
  const contributionLevels=[...new Set(Object.values(contributions).map(x=>n(x)).filter(x=>x>0))]
    .sort((a,b)=>a-b);
  
  const pots:any[]=[];
  let previousLevel=0;
  
  for(const currentLevel of contributionLevels){
    // Find all players who contributed at or above this level
    const contributorIds=Object.keys(contributions).filter(id=>n(contributions[id])>=currentLevel);
    
    // Find eligible players (still in hand)
    const eligibleIds=contributorIds.filter(id=>{
      const player=ps(s).find(x=>x.id===id);
      return player&&inHand(player);
    });
    
    // Calculate pot size for this layer
    const layerSize=(currentLevel-previousLevel)*contributorIds.length;
    previousLevel=currentLevel;
    
    if(!layerSize)continue;
    
    // Check if we can merge with previous pot (same eligible players)
    const lastPot=pots.at(-1);
    const canMergeWithPrevious=lastPot
      &&lastPot.eligibleIDs.length===eligibleIds.length
      &&lastPot.eligibleIDs.every((z:string)=>eligibleIds.includes(z));
    
    if(canMergeWithPrevious){
      lastPot.amount+=layerSize;
    }
    else{
      pots.push({
        amount:layerSize,
        eligibleIDs:eligibleIds,
        winnerIDs:[],
        shares:{},
        isSidePot:pots.length>0
      });
    }
  }
  
  return pots;
}
function clockwise(s:S,ids:string[]){
  const targetPlayerIds=new Set(ids);
  const out:string[]=[];
  const dealerIndex=dealer(s);
  
  // Reuse scan's traversal pattern: walk clockwise from dealer+1 collecting all matches
  for(let o=1;o<ps(s).length+1;o++){
    const i=(dealerIndex+o)%ps(s).length;
    if(targetPlayerIds.has(ps(s)[i].id))out.push(ps(s)[i].id);
  }
  
  return out;
}
function credit(s:S,x:Record<string,number>){
  for(const[id,chipAmount]of Object.entries(x)){
    const player=ps(s).find(p=>p.id===id);
    if(player)player.stack=n(player.stack)+chipAmount;
    
    const stats=(s.handStats??={})[id]??={handsWon:0,handsPlayed:0,biggestPot:0};
    stats.handsWon=n(stats.handsWon)+1;
    stats.biggestPot=Math.max(n(stats.biggestPot),chipAmount);
  }
}

function applyPayouts(s:S){
  if(s.handResult&&!s.handResult.payoutsApplied){
    credit(s,s.handResult.payouts);
    s.handResult.payoutsApplied=true;
    s.pot=0;
  }
}

function bust(s:S){
  ps(s).forEach(p=>{
    if(n(p.stack)<=0){
      p.stack=0;
      p.isEliminated=true;
    }
  });
}
function award(s:S,r:PokerRuntime,showdown:boolean){
  uncalled(s);
  
  const totalPayout:Record<string,number>={};
  const awardedPots:any[]=[];
  
  for(const pot of layers(s)){
    // Find eligible players who are still in the hand
    let eligiblePlayerIds:string[]=pot.eligibleIDs.filter((id:string)=>{
      const player=ps(s).find(x=>x.id===id);
      return player&&inHand(player);
    });
    
    // Fallback: if no eligible players in hand, use all players in hand
    if(!eligiblePlayerIds.length){
      eligiblePlayerIds=ps(s).filter(inHand).map(p=>p.id);
    }
    
    if(!eligiblePlayerIds.length)continue;
    
    let winnerIds:string[]=eligiblePlayerIds;
    
    // For showdown, determine winners by hand strength
    if(showdown&&eligiblePlayerIds.length>1){
      let bestHand:number[]|null=null;
      winnerIds=[];
      
      for(const playerId of eligiblePlayerIds){
        const holeCards=r.holeCardsByPlayer[playerId]??[];
        const communityCards=s.board.filter(Boolean);
        const handScore=score([...holeCards,...communityCards]);
        
        if(!bestHand||cmp(handScore,bestHand)>0){
          bestHand=handScore;
          winnerIds=[playerId];
        }
        else if(cmp(handScore,bestHand)===0){
          winnerIds.push(playerId);
        }
      }
    }
    
    // Split pot among winners
    const shares:Record<string,number>={};
    const sharePerWinner=Math.floor(pot.amount/winnerIds.length);
    winnerIds.forEach(id=>shares[id]=sharePerWinner);
    
    // Distribute remainder chips in clockwise order from dealer
    let remainderChips=pot.amount%winnerIds.length;
    const clockwiseWinners=clockwise(s,winnerIds);
    for(const winnerId of clockwiseWinners){
      if(!remainderChips)break;
      shares[winnerId]++;
      remainderChips--;
    }
    
    // Accumulate payouts
    for(const[playerId,chipAmount]of Object.entries(shares)){
      totalPayout[playerId]=(totalPayout[playerId]??0)+chipAmount;
    }
    
    awardedPots.push({...pot,winnerIDs:winnerIds,shares:shares});
  }
  
  // For showdown, defer payout and transition to showdown phase
  if(showdown){
    s.handResult={
      pots:awardedPots,
      payouts:totalPayout,
      reveals:[],
      wentToShowdown:true,
      payoutsApplied:false
    };
    clear(s);
    s.phase="showdown";
    begin(s);
    return;
  }
  
  // For non-showdown (fold), apply payouts immediately
  s.handResult={
    pots:awardedPots,
    payouts:totalPayout,
    reveals:[],
    wentToShowdown:false,
    payoutsApplied:false
  };
  applyPayouts(s);
  clear(s);
  bust(s);
  summaryState(s);
}
function revealOrder(s:S){
  const playersInHandIds=ps(s).filter(inHand).map(p=>p.id);
  const starterId=typeof s.lastAggressorID==="string"&&playersInHandIds.includes(s.lastAggressorID)
    ?s.lastAggressorID
    :clockwise(s,playersInHandIds)[0];
  
  const starterIndex=getPlayerIndex(s,starterId);
  
  const allPlayers=ps(s);
  const playersFromStarter=[...allPlayers.slice(starterIndex),...allPlayers.slice(0,starterIndex)];
  
  return playersFromStarter
    .filter(p=>playersInHandIds.includes(p.id))
    .map(p=>p.id);
}
function begin(s:S){
  const alreadyShownPlayers=new Set((s.handResult.reveals??[]).map((x:any)=>x.playerID));
  const revealOrdering=revealOrder(s);
  const nextPlayerToReveal=revealOrdering.find(id=>!alreadyShownPlayers.has(id))??null;
  
  s.pendingRevealPlayerID=nextPlayerToReveal;
  s.activePlayerID=nextPlayerToReveal;
}
function bestCards(c:Card[],want:number[]){for(const combo of combos5(c)){if(cmp(five(combo),want)===0)return combo}return c.slice(0,5)}
function show(s:S,r:PokerRuntime,id:string){
  if(s.phase!=="showdown"||s.pendingRevealPlayerID!==id)fail("not_your_reveal");
  
  const holeCards=r.holeCardsByPlayer[id];
  if(!holeCards?.length)fail("missing_hole_cards");
  
  const allCards=[...holeCards,...s.board.filter(Boolean)];
  const handScore=score(allCards);
  const bestFiveCards=bestCards(allCards,handScore);
  
  s.handResult.reveals.push({
    playerID:id,
    holeCards:holeCards,
    rank:handNames[handScore[0]],
    bestFive:bestFiveCards
  });
  
  begin(s);
}
function summaryState(s:S){
  s.completedHandCount=n(s.completedHandCount)+1;
  ps(s).forEach(p=>p.isReady=false);
  
  s.endStats=ps(s).map(p=>{
    const playerStats=(s.handStats??{})[p.id]??{};
    const isWinner=(s.handResult?.pots??[]).some((pot:any)=>pot.winnerIDs.includes(p.id));
    
    return{
      id:p.id,
      name:p.name,
      avatarIndex:n(p.avatarIndex),
      handsWon:n(playerStats.handsWon),
      handsPlayed:n(playerStats.handsPlayed),
      biggestPot:n(playerStats.biggestPot),
      finalStack:n(p.stack),
      isWinner:isWinner
    };
  }).sort((a:any,b:any)=>b.finalStack-a.finalStack);
  
  s.phase="handSummary";
  s.activePlayerID=null;
  s.pendingRevealPlayerID=null;
}
function finish(s:S){
  // Apply deferred payouts from showdown
  applyPayouts(s);
  
  bust(s);
  summaryState(s);
}
function next(s:S,r:PokerRuntime,id:string,f:()=>Card[]){
  if(s.phase!=="handSummary")fail("illegal_phase");
  if(s.hostID&&s.hostID!==id)fail("not_host");
  
  // Check if game should end (only one player with chips remaining)
  const playersWithChips=ps(s).filter(p=>!on(p.isEliminated)&&n(p.stack)>0);
  if(playersWithChips.length<=1){
    end(s,id,"autoLastStanding");
    return;
  }
  
  // Check if all eligible players are ready
  const eligiblePlayers=ps(s).filter(eligible);
  const allReady=eligiblePlayers.every(p=>on(p.isReady));
  
  if(eligiblePlayers.length<2||!allReady)fail("not_all_ready");
  
  start(s,r,id,f);
}
function sit(s:S,r:PokerRuntime,id:string,v:boolean){
  const player=getPlayer(s,id);
  
  if(on(player.isEliminated))fail("actor_ineligible");
  
  const currentPhase=s.phase;
  if(!v&&!['waiting','handSummary'].includes(currentPhase))fail("illegal_phase");
  
  // If sitting out during active hand, fold the player
  if(v&&currentPhase==="playing"&&!on(player.isFolded)){
    if(s.activePlayerID===id){
      action(s,r,id,"fold");
    }
    else{
      player.isFolded=true;
      const livePlayers=ps(s).filter(live);
      if(livePlayers.length===1)award(s,r,false);
    }
  }
  
  player.isSittingOut=v;
  player.isReady=false;
}
function end(s:S,id:string,reason:string){
  if(s.phase!=="handSummary"||s.hostID&&s.hostID!==id)fail("illegal_phase");
  
  const playersNotEliminated=ps(s).filter(p=>!on(p.isEliminated)&&n(p.stack)>0);
  const maxStack=Math.max(0,...playersNotEliminated.map(p=>n(p.stack)));
  const topPlayers=playersNotEliminated.filter(p=>n(p.stack)===maxStack);
  
  // Check for tie situation on manual finish
  if(reason==="manualFinish"&&topPlayers.length>1&&n(s.manualFinishTieAttempts)===0){
    s.manualFinishTieAttempts=1;
    fail("manual_finish_tied");
  }
  
  const winnerId=reason==="manualFinishTieForfeit"?null:(topPlayers.length===1?topPlayers[0].id:null);
  
  s.endStats=ps(s).map(p=>{
    const stats=(s.handStats??{})[p.id]??{};
    return{
      id:p.id,
      name:p.name,
      avatarIndex:n(p.avatarIndex),
      handsWon:n(stats.handsWon),
      handsPlayed:n(stats.handsPlayed),
      biggestPot:n(stats.biggestPot),
      finalStack:n(p.stack),
      isWinner:p.id===winnerId
    };
  }).sort((a:any,b:any)=>b.finalStack-a.finalStack);
  
  s.phase="ended";
  s.activePlayerID=null;
}
function reset(s:S,r:PokerRuntime,id:string){
  if(s.phase!=="ended")fail("illegal_phase");
  
  const actor=getPlayer(s,id);
  if(on(actor.isSittingOut))fail("actor_ineligible");
  
  const startingStack=Math.max(n(s.startingStack,500),1);
  
  // Remove sitting out players and reset remaining players
  s.players=ps(s).filter(p=>!on(p.isSittingOut));
  ps(s).forEach(p=>{
    p.stack=startingStack;
    p.isReady=false;
    p.isDealer=false;
    p.isFolded=false;
    p.isEliminated=false;
    p.isSittingOut=false;
    p.currentBet=0;
  });
  
  // Reset game state
  s.phase="waiting";
  s.handID=null;
  s.board=[null,null,null,null,null];
  s.pot=0;
  s.bettingRound="preFlop";
  s.activePlayerID=null;
  s.pendingRevealPlayerID=null;
  s.handResult=null;
  s.contributions={};
  s.handStats={};
  s.endStats=[];
  s.completedHandCount=0;
  s.manualFinishTieAttempts=0;
  s.streetBetLevel=0;
  s.lastRaiseSize=br(s);
  s.actedThisStreet=[];
  s.lastAggressorID=null;
  s.blindIncreaseAnnouncement=null;
  
  r.remainingDeck=[];
  r.holeCardsByPlayer={};
}
function ui(s:S){
  const hero=ps(s).find(p=>p.id===s.heroID);
  s.callAmount=hero?Math.max(0,n(s.streetBetLevel)-n(hero.currentBet)):0;
  
  const minRaiseAmount=minRaiseTo(s);
  s.raiseAmount=hero?Math.min(minRaiseAmount,cap(s,hero.id)):minRaiseAmount;
}

function deadline(s:S){
  if(s.phase!=="showdown")return null;
  
  const secondsToWait=s.pendingRevealPlayerID?SHOW:SUMMARY;
  const futureTime=Date.now()+1000*secondsToWait;
  return new Date(futureTime).toISOString();
}
