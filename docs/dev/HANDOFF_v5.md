# Tung Tung Tycoon — Handoff v5

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v4.md` on the second floor, the cabinets, world text and
the verifier. v4 is still right about progression tracks, raider AI and the
persistence landmines. v3 is still the only correct account of **procedural
animation** — read its §2 before you touch `SwingAnim.lua`. `HANDOFF.md` (v1) is
still right about the base game.

Ten pull requests landed, all of them stacked. §2 is the part to read before you
change anything.

**Nothing in this round has run in Roblox.** That sentence has now appeared in
three consecutive handoffs and it is more load-bearing here than it was in
either of the others, because this round moved geometry, changed what a plot
looks like in its first minute, and altered how the raid reads for twenty
minutes of the early game. §5 is the list.

---

## 1. What changed

| PR | What |
| --- | --- |
| #23 | one font, one outline, four named view distances — and a lint that keeps it |
| #24 | the buy button's two voices; `AlwaysOnTop` off |
| #25 | bigger raids, sooner |
| #26 | the raid banner became a sign over the arena statue |
| #27 | buy buttons honour their own height |
| #28 | the mezzanine became data the verifier can see |
| #29 | **the second floor became a purchase, at the halfway mark** |
| #30 | the cabinets arrive with it |
| #31 | the belt's triggers got thick enough for the belt's speed |
| #32 | the generator yard — a fourth track |

### #23–#24, #26 — the plot stopped shouting

Three fonts, six outline settings and eleven view distances between 90 studs and
1200 — none chosen against each other, because there was never a place where two
of them were visible at once. There is now: `Config.Style` holds the numbers and
`src/shared/Style.lua` turns them into instances.

**The lint is the part that matters.** `tools/verify.py` gained a fifth pass that
fails the build if `Enum.Font`, a `TextStrokeTransparency` assignment or a
`MaxDistance` assignment appears anywhere in `src/` outside `Style.lua`. The
state it replaced is exactly what happens without one, and no convention written
in a document would have stopped the fifteenth label picking a twelfth distance.

Statue faces defaulted to `MaxDistance = 0`, which in `SurfaceGui` means *never
stop drawing* rather than *no distance*. The arena statue and every raider
inherited it.

The buy button's locked state now differs from its buyable one on **five axes**,
not just colour — colour being the first thing lost to a bright sky or a neon
variant behind the label, and it had been carrying the whole distinction.

### #25 — waves

First raid at 30s, next 30s after your clear, 6 raiders climbing by 4 to 40.
`RestTime` moved, **not `WarningTime`** — see §2. `MaxChasers` is still 8, so a
bigger wave is more reinforcements rather than more raiders hitting you at once,
and that is now asserted rather than commented.

### #27–#30 — the second floor

`Tycoon:buildButtons` built every pedestal at `self:at(pos.X, 0, pos.Z)`,
discarding a Y that `buttonPosition` had already worked out correctly. That one
zero is why nothing purchasable could ever stand on the mezzanine. The
conversion existed **twice** and both copies dropped it; there is one
`buttonBaseCF` now.

The floor is a purchase at minute 41 rather than a free reward at minute 80, and
its dropper is an ordinary Config button standing on it rather than something
`FloorService` synthesised outside the button system. The cabinets arrive with
it.

### #31–#32 — the belt, and the yard behind it

The upgrader's scanner was **one stud** thick. At the shipped top belt speed of
37 that is 27ms, against the 33ms step Roblox demotes an unattended assembly to
— and an unattended plot is the common case on a ten-player server. A drop could
already pass through an upgrader between two physics frames and pay out
unrefined.

The generator is a fourth track that multiplies dropper rate and belt speed by
the same factor. See §2 for why that pairing is not decoration.

---

## 2. Invariants — the landmine list

Additions to v1 §5, v2 §5 and v4 §2. Everything there still applies.

### World text

- **Nothing outside `Style.lua` names a font, an outline or a view distance**,
  and `tools/verify.py` fails the build if anything does. If you need a new view
  distance, add a named tier to `Config.Style.Distance` — do not write a number
  at a call site, because that is precisely how the eleven happened.
- **Two things draw through walls and only two**: damage numbers, and enemy
  nameplates. The nameplates are Roblox's own and are drawn on top whatever we
  ask. Everything else obeys geometry.
- **`Style.Button.lift` is what makes that safe.** With `AlwaysOnTop` off, a buy
  button's label has to clear the machinery by standing above it. The verifier
  asserts the billboard's bottom edge against `Layout.MachineTopY`, which is
  derived from the same `BeltY` the dropper's arm is built from. Raise the arm
  and forget the label and the build fails.
- **`SurfaceGui.MaxDistance = 0` means "always render".** It is not a sensible
  default and it is not "no limit specified".

### The belt

- **A trigger on the belt has to survive a 30 Hz physics step.**
  `Config.Layout.TriggerThickness` is 5 for that reason, and the verifier
  asserts `thickness / maxBeltSpeed >= 2 × (1/30)`. `maxBeltSpeed` includes the
  generator's top factor, so it is 74 and the dwell is 68ms — two steps, and
  that is the whole margin. **Anything that raises belt speed or lowers trigger
  thickness needs to look at this number.**
- **The upgrader's visible plate and its trigger are different parts.** `Scanner`
  is 1 stud and `CanTouch = false`; `ScanTrigger` is 5 studs, invisible, and
  carries the `Touched`. Same split, same reason, as the mezzanine's invisible
  guard behind its visible railing.
- **`MACHINE_MASSES` is shared with `buildGhost`.** Masses named `*Trigger` are
  filtered out of ghosts, because a ghost is a silhouette and a 5-stud invisible
  slab is not part of one. This is the ONE exception to "the ghost is built from
  the same description as the real machine", and it is named rather than being a
  quiet special case.
- **The corner sensor was widened AND shifted downstream** so its leading face
  stayed put. An early trigger is harmless at an upgrader or a collector; at a
  corner it cuts the corner.

### The second floor

- **A belt machine is either SLOTTED or PINNED, never both.** `slot` indexes
  `Layout.DropperDist`/`UpgraderDist`, which describe the ground floor's two legs
  and nothing else. Anything on another floor names `path` plus `legIndex` and
  `legDistance`.
- **A button carries `path` as an ID, not an index.** `pathIndex` is assigned at
  runtime by `addBeltPath`; Config cannot know it.
- **Every belt path is registered at plot construction**, including floors nobody
  has bought. A path is pure maths and registering one builds nothing — but buy
  buttons are built once, on first claim, and a button on the mezzanine needs its
  path to exist to know its own height.
- **THE MEZZANINE FEEDS THE SAME REFINERY.** Upgraders are physical scanners on
  the ground floor's leg 2, so an upstairs drop crosses none of them.
  `Tycoon:onCollect` multiplies a drop from a path with no upgraders of its own
  by the plot's stack. Without that the floor is an additive term against a
  multiplicative curve: 17% of plot income the minute you buy it, 4% one button
  later, **0.02% by the end of the build**. If you ever give the mezzanine its
  own upgraders, `refineryMultiplierFor` returns 1 for it automatically — that
  branch already exists.
- **The roof is rebuilt when the floor lands.** It shrinks itself when the deck
  is up, which used to key off a prototype flag and so was the same answer for
  everyone forever. Roof is minute 28 and floor is minute 41; without the rebuild
  every player gets a half-roof for thirteen minutes.
- **`padDown` and `padUp` are no longer co-located, and cannot be.** The ground
  end used to overlap the armour cabinet's slot-2 pedestal by 3×1 studs, and
  there is no clean 9×9 anywhere on that side of the plot: the weapons and
  armour columns at x = 30 and 44 on a 14-stud pitch cap the best achievable
  clearance at exactly zero. It moved to the aisle side.
- **The pads are in the verifier's floor-furniture list as BOXES**, not points.
  9×9 against 5×5 cannot be seen by a centre-distance rule.

### Tracks

- **`Config.TrackInfo` is the only place a per-track fact lives.** Before this
  round they were spread across five tables in three files and one existed
  twice. A missing row fails differently in each and none of them fail loudly —
  the rebirth one **fails open**. If you add a fifth track, the verifier tells
  you what is missing.
- **`Config.TrackRank` is derived from `TrackOrder`.** There used to be two
  hand-maintained copies, one in `Tycoon` and one in `HUD`, with a comment on
  the HUD copy warning they had to match. Keeping two copies identical is not a
  plan.
- **A track-level gate is not a `requires`.** The loader derives requirements
  within a track and the verifier asserts none crosses one. `Config.TrackUnlock`
  is a separate concept for exactly that reason.
- **The cabinet gate is STICKY and derived**: owning any rung of a track counts
  as having it open. Rebirth wipes the factory — and so `floor2` — while keeping
  weapons and armour, so without that clause your first rebirth deletes both
  cabinets and leaves the shelf displays and the granted bat standing.
- **Power does not survive a rebirth**, and that is deliberate. It multiplies
  exactly what a rebirth resets; keeping it would stack ×2 on
  `MultiplierPerRebirth` 2.25 for an effective 4.5× first prestige and make the
  asserted cost ratio a lie about real pacing.

### The generator

- **It must multiply belt speed by exactly the factor it multiplies drop rate
  by.** In-flight drops are `peakRate × length / speed`; the two cancel. Scale
  the droppers alone and a plot already at 88% of `MaxDropsPerPlot` goes over,
  and `spawnDrop` starts silently discarding the income you just bought.
  Asserted per tier.
- **Belt speed is DERIVED from two inputs, never accumulated.** `beltBonus` is
  additive and `powerFactor` is multiplicative and `refreshBeltSpeed` recomputes
  the product. `+=` on the product is safe only while `install()` guards on
  `owned` — and `assign()` replays a save by installing every owned button in
  `order`, which would land on `1.19 × 1.42 × 1.68 × 2.00`.
- **Never write `def.dropRate`.** `Config.ButtonById` tables are shared by every
  plot on the server. `Tycoon:dropInterval` divides at read time, which also
  means a generator bought mid-run is picked up on every dropper's next drop
  with no loop restart.
- **The yard's door can only be in the back-right corner.** The back edge of the
  plot IS the dropper row (x = −42.5 to 43.5) and the left side is the upgrader
  alley. It is cut at wall-build time, not at generator-purchase time, or anyone
  who buys walls first is sealed out permanently.
- **The yard is not in `Layout.Tracks`.** That table is things standing on the
  plot floor: the verifier runs `inPlot` over every slot of every entry, and
  `ensureCabinets` builds a display case for each.

---

## 3. The verifier

1146 checks at v4, **1706 now.**

New families: world-text tiers and their relationship to the map, buy-button
voice, wave part budget and clear time, belt-path assertions covering the
mezzanine, deck-versus-roof and pillar-versus-machine clearance, plot-wide drop
budget across every floor, trigger dwell, floor pacing measured in minutes,
track gates, per-track metadata completeness, the power ladder, yard geometry,
world packing including yards, and the rate/speed coupling.

The economy simulation now walks **two interleaved ladders** — factory and
power, buying whichever next rung is cheaper — because a track that multiplies
income cannot be priced by a model that assumes purchases do not change the
curve they are measured against.

Current output: 34 buttons (21 factory / 5 weapons / 4 armour / 4 power), full
build **67 minutes**, floor at 41 (62%), endgame 8.4e7/sec, first rebirth +10
min.

**Every new assertion family in this round was checked against the defect it
exists for** — the shipped 1-stud trigger, the old `padDown`, the old belt
margins, the deck at roof height, a rate-only generator, an uneven power ladder,
a track gated on itself. If you add one, do that; an assertion nobody has seen
fail is a guess with a `check()` around it.

**Its limits have not moved.** It sees `src/shared/Config.lua` and nothing else,
`Vector3` is a bare table with no arithmetic, and it cannot reach frame
ordering, AI behaviour, or anything about how a thing looks.

### Two things it now prints rather than asserts

Both are real problems this round could not fix without doing something it was
told not to:

```
solo clear:   65s with Eclipse Sahur Bat, 476s with Sahur Bat (deadline 300s)
weapons cabinet:  opens at 41 min with 4 of 5 rungs already affordable
```

The first is what gating the cabinets costs — see §5. The second is its inverse:
a gated cabinet can no longer be scenery you stare at, but it can arrive as a
vending machine. The check that would catch it fails today, and fixing it means
retuning cabinet prices, which was explicitly out of scope. It becomes an
assertion in the round that retunes the curve.

---

## 4. What is still open

- **DataStore session locking is still missing.** Untouched again, still the
  highest-severity item in the repo, still gates trading.
- **The price curve moved without being retuned.** 79.8 → 85 minutes with the
  floor, then → **67** because the generator doubles endgame income. That is
  most of what GROWTH-TODO item 1 asks for, arriving as a side effect. But the
  floor stayed at minute 41 while everything around it got faster, so it went
  from 49% of the build to **62%** — four points inside the asserted ceiling.
  Anyone touching either number should look at both.
- **Raider pathfinding is still naive `MoveTo`.**
- **Still no runtime tests**, and a headless smoke test remains the
  highest-leverage unowned item in the repo.
- **Part budget at full scale is still untested**, and this round raised it: 40
  raiders is 1320 parts against a documented 1600 budget, plus a yard and four
  generators per plot.

---

## 5. What only Studio can tell you

This is the section to act on. The round's brief said it plainly: *"none of this
is checkable by the verifier — it covers numbers, not how anything looks or
feels."* The last two rounds shipped three changes that passed every check and
still had to be judged by eye, and one of them was reverted on sight.

**Two of these need a populated server, not a solo playtest.**

1. **A label twelve studs up.** The buy-button billboard was raised to clear the
   machinery once it stopped drawing through walls. Does it read as a sign *over*
   the machine or as one floating away from it? If it floats, the fallback is
   keeping `AlwaysOnTop` for the available state only — that still deletes the
   wall of x-raying grey labels, which is what the brief was complaining about.
2. **A drop crossing an upgrader on an UNATTENDED plot.** Stand on a neighbour's
   plot or force `Workspace.PhysicsSteppingMethod = Fixed60`. This is not
   reproducible while you stand there watching it, which is the entire point.
3. **A 40-raider wave on a full server.** Watch frame time, not correctness.
4. **The early game with no weapons cabinet.** The suite prints that a saturated
   wave takes 476s against a 300s deadline with the starting bat, so waves stop
   being clearable from about wave 9 (~19 minutes) until the floor opens at 41.
   `killReward` pays per kill rather than per clear, so partial clears still pay
   and a timed-out wave announces itself — it is degraded, not broken. But for
   twenty minutes the raid is something you survive rather than something you
   win. **If it plays badly, the cheapest lever is
   `Config.TrackUnlock.weapons`**: pointing the weapons track at an earlier
   factory button is one line and keeps every visual gain.
5. **The deck.** Flush to the back wall, clearing the roof columns by 1.6 studs.
   Walk its edges looking for a gap the guard misses.
6. **The teleport pads, which no longer line up.** `padDown` moved 54 studs, so
   you do not land where you left. Judge whether that still reads as a lift or
   now reads as a teleport.
7. **The refinery decision.** Buy `upgrader5` after the floor and check the vault
   sign moves by exactly what the button quoted. That is the test of whether the
   mezzanine's income is wired right and no assertion can make it.
8. **A save with `power3` and `belt1`.** Belt should be `(28+9)×1.68 = 62.2`,
   not `28×1.68+9 = 56` and not `78.1`. This is the install-replay trap.
9. **The yard doorway with walls AND roof bought.** The back-right roof column
   stands in it and narrows the clear span to 8.8 studs. Passable; it might read
   as an obstruction.
10. **Drops at the corners at 74 studs/s**, which is the failure the arithmetic
    cannot see.

---

## 6. Conventions

Unchanged from v4, plus two.

- **Verifier before commit**, `build/` regenerated, `src/` is the source of
  truth, commit messages explain the *why*, config over code.
- **When you fix something geometric, add the assertion.**
- **When the verifier structurally cannot catch it, write it down here instead.**
- *Moving geometry into Config makes it checkable, not correct.*
- **New: falsify every assertion you add.** Break the thing it watches and
  confirm it fires with the message you wrote. Every family in this round was
  checked that way, and two of them found real bugs while being checked — the
  belt margins and the pillar clearance. An assertion nobody has seen fail is a
  guess with a `check()` around it.
- **New: when a rule is enforceable by a lint, write the lint.** The style
  ownership pass exists because "pick one font and use it everywhere" is exactly
  the kind of convention that decays silently, and a document saying so had
  already failed to prevent it once.
