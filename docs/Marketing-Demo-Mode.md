# Marketing Demo Mode

## Purpose

Create a presentation-only mode alongside the existing CPU option. It should let us record a complete, polished poker-night story from the simulator without relying on real multiplayer timing, real opponents, or unpredictable card outcomes.

This is not a new game type and must never be available to normal players in a released build. Gate it behind `#if DEBUG` (or an equivalent internal-only build flag).

## Entry Point

Add a **Marketing Demo** item beneath/near **Play vs CPU** in the development build. Entering it launches a scripted session with a resettable timeline.

Suggested controls, kept discreet so they can be cropped or hidden in the final edit:

- Restart demo
- Previous beat / Next beat
- Play / pause timeline
- Optional speed: 1x and 2x

## Recording Storyboard

The session should be designed as separate clean beats. Each beat needs to look complete on screen long enough to record independently; the editor can then cut them together.

| Beat | Target duration | What appears | Recording goal |
| --- | ---: | --- | --- |
| 1. Invite sent | 2–3 sec | Poker Night conversation with the interactive poker message just sent | Establish that the game starts from iMessage |
| 2. Waiting room fills | 4–6 sec | Mock players join one at a time, then become ready | Show the group gathering without real networking |
| 3. Game starts | 2 sec | Everyone-ready state transitions cleanly to the table | Give the edit a natural transition |
| 4. Key hand | 6–10 sec | Deal, a small sequence of believable actions, pot growth, and a clear decision | Show the app is a real playable game |
| 5. Blinds increase | 2–3 sec | Game Settings changes minimum blinds; table receives a concise “Blinds increased” state | Add rising stakes/tension |
| 6. Hand resolves | 3–5 sec | Showdown, winning hand, pot/chips awarded, and winner highlight | Deliver a satisfying payoff |
| 7. End state | 2 sec | Clean final table/winner state | Optional bridge into the external message-to-logo AI transition |

## Mock Players

Use fixed identities so every capture is consistent. They should look like plausible people in a Poker Night group, with distinct colors/avatars if the product supports them.

Suggested roster:

- You — host
- Maya — joins first, immediately ready
- Jordan — joins second, ready after a short beat
- Chris — joins last, briefly “thinking,” then ready

The demo should use names and avatars that are safe to show publicly; no contacts, account data, or real profile photos.

## Scripted Table State

All game events are deterministic. Starting/restarting the demo must always produce the same cards, order, actions, chip amounts, and winner.

Recommended hand characteristics:

- Four seated players and only the local player’s hole cards fully visible.
- A compact action sequence: call → raise → call(s), rather than a long realistic hand.
- Community cards that create an immediately readable showdown.
- A winner that is visually clear from the cards and the pot award.
- A pot and chip movement large enough to read in a phone recording.

Avoid hands that require poker expertise to understand. The viewer should understand “big hand, winner” at a glance.

## Visual Requirements

- No spinners, empty seats, debug labels, test data warnings, or loading delays in the recordable area.
- Use realistic timestamps, chip counts, and turn delays, but keep the entire loop brisk.
- Give each important state at least 1.5–2 seconds of stillness before automatically advancing.
- Make player joins, ready states, deal, blinds increase, winner highlight, and pot award visibly animated where the existing UI supports it.
- Keep the final screen free of modal overlays so it is easy to cut into the logo animation.
- Respect Reduce Motion when it is enabled; the manual beat controls must still make every state capturable.

## Game Settings Beat

The video needs the new minimum-blinds setting to be recognizable, not merely toggled.

1. Open **Game Settings**.
2. Show the minimum blinds value changing (for example, 10/20 to 25/50).
3. Close settings.
4. Present a brief table-level confirmation such as “Blinds increased: 25 / 50.”
5. Continue to the decisive hand.

If settings currently apply only to future hands, have the confirmation appear at the start of the next scripted hand. Do not misrepresent the game rules for the video.

## Implementation Shape

- Model the demo as a small list of named scripted states/events, not timers spread throughout production views.
- Inject a demo data source/state controller into the existing waiting-room and table UI where possible.
- Keep all demo fixtures in a dedicated `Demo` or `MarketingDemo` namespace/folder.
- Prefer the real UI and real view models with deterministic fixture data; only fake networking and game progression.
- Provide explicit transition functions for every beat so recording can be repeated without waiting for animations or timers.
- Ensure the regular CPU and multiplayer paths are unchanged.

## Acceptance Checklist

- [ ] Demo entry point exists only in development/internal builds.
- [ ] A recorder can restart and capture each beat independently.
- [ ] Waiting room visibly goes from invite to four joined/ready players without networking.
- [ ] The game table displays a deterministic, believable hand.
- [ ] The minimum-blinds change is visible in both Settings and the table state.
- [ ] The hand ends with an unmistakable winner and pot award.
- [ ] Replaying the demo produces identical visuals and outcomes.
- [ ] CPU and multiplayer behavior remain unaffected.

## Edit Plan (outside the app)

Record the iMessage invitation, waiting room, table hand, blinds increase, and final winner as separate clean takes. Assemble those captures in the editor, then use the final winner/table frame as the outgoing shot for the AI-generated message-bubble-to-logo transition.
