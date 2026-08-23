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

## 2. What only Studio can tell you

1. **The chase, watched.** Rob with a second account: the sack billboard
   should read from across a band; the victim's strip should show the !
   tracking the runner; banking or dying should clear both within a beat.
2. **Billboard collisions.** The carry mark shares headspace with display
   names; check they do not overlap into mush at close range.
