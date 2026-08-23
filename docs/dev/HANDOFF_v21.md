# HANDOFF v21 — the follow-up tickets

The build order is done; this round works the tickets it spawned. Grows as
they land.

## 1. What moved

- **#138 — the carrier is marked.** A gold CARRYING billboard over the
  thief's head (server-built, world-distance, always-on-top), and every
  robbed victim's compass gains a red **!** tracking the carrier until the
  chase ends — pushed on the ThiefMark remote, backed by the derived
  `thievesOf` ledger. The mark outranks disclosure: being robbed is the
  event.

- **#145 — the tower's surfaces.** A banner strip under the compass, alive
  only mid-run: floor, instruction, countdown (secondsLeft, counted down
  locally), the day's modifier, your best today. The spire door gained the
  deck preview sign — today's composition and its twist — repainted at the
  day turn.
- **#146 (the buildable half) — the daily modifier.** One per day beside the
  deck: STEADY, SWIFT (+25% mob speed, asserted to still lose to a sprint),
  TOUGH (×1.4 health), BOUNTIFUL (+1 minute per floor through recordClear).
  Scales enter through mintNPC's options; access gating and the
  across-days curve stay open pending live data.

## 2. What only Studio can tell you

1. **The chase, watched.** Rob with a second account: the sack billboard
   should read from across a band; the victim's strip should show the !
   tracking the runner; banking or dying should clear both within a beat.
2. **Billboard collisions.** The carry mark shares headspace with display
   names; check they do not overlap into mush at close range.
3. **A climb with the banner.** Run a timed floor: the countdown should tick
   without stutter between the 1s server pushes; the banner should drop the
   moment the run ends; SWIFT day should feel faster without feeling unfair.
4. **The deck sign.** Readable at the door, and the abbreviations (WAVE TIME
   SURV BOSS) should parse without a legend.
