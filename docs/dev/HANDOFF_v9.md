# HANDOFF v9 — the ground floor becomes a place, and the storey becomes a room

PRs #64–#70, all stacked. The brief was `TODO.md`'s five items and they turned
out to be one change: **the ground floor stops being a corridor you pass
through on the way to the mezzanine, and the mezzanine stops being a furnished
machine you buy.**

This ran in parallel with the round `HANDOFF_v8.md` covers, which is the HUD's
layout and nothing else. The two touch no common file, and v8 stays the live
word on the status card.

Read `ARCHITECTURE.md` for the module map and `INVARIANTS.md` for what must not
break. This file is why this round did what it did, and what it did not prove.

---

## 1. What changed

### #64 — the armoury comes downstairs

Both cabinets are on the ground floor, in one file down the right-hand side,
and `Config.TrackUnlock` gates them on `dropper3` instead of on `floor2`.

**This reverses #58, deliberately.** #58's own Studio list asked "does the
ground floor read as emptier for having lost them?" — `TODO.md` item 2 is the
answer. The move itself is one absent key: `Config.floorTopY` has documented
`floor = nil` as "the ground floor, and a legitimate answer" since #58, and
`floor_spec` already carried a spec for the path precisely because nothing
shipped exercised it.

**The rebirth pad moved**, from (42, 40) to (24, 0). Nine pedestals plus four
studs of case overhang at each end is 120 studs of display case looking for a
straight run, and the pad's 14-stud spacing rule forbade any pedestal between
z 26 and z 54 — room for one slot above it and eight below, and eight below
runs off the back of the plot.

**`cabinetX = 48`, not hard against the wall at 54.** Two solids stand at
x = ±54 for the full height of the ground storey and neither can move: the
roof's columns and the mezzanine deck's own posts. A 4-deep case centred at 54
interpenetrates both, and widening `pillar.insetSide` walks the *left* pair
into belt leg 2's base.

**`Layout.CabinetSlotSpacing = 12` is a new constant** because one number was
doing two jobs. `MiscButtonSpacing = 14` is about the misc *column* — five
unrelated purchases in a line down an open floor. A cabinet column is nine pads
that are deliberately one object. Nine at 14 need 112 studs; the clear band is
101.5. The pair check takes the stricter of the two rules.

**Nine checks deleted, twelve written.** #58's "a cabinet on a floor above the
plot" block was unreachable with `layout.floor` nil for every shipped track.
What replaced it covers the same class on the floor the cases are actually on,
and both halves are gaps that predate the move: nothing had ever compared floor
furniture against the mezzanine's **deck posts** (which arrive under a cabinet
that has stood there for half an hour) or against the **yard doorway**.

### #65 — the shell is three rungs

`walls` → `gates` → `windows`. The wall arrives **solid and closed**, bays
included, and glazing restyles it: the alternative gives you a purchase called
"Plot Walls" that does not keep a raider out. Two consequences — the part count
does not move between the three rungs, so `shellPartCount` and the whole
`PartBudget` argument are unchanged; and an unglazed plot is a windowless shed
rather than a colander.

**Nothing is ever rebuilt.** `FloorService`'s header already argues against
re-emitting a ring to add to it (it would destroy gate leaves `GateService` may
be mid-tween on). `gates` and `windows` build into the *existing* ring's model,
found by `Tycoon:eachStoreyRing` through `factoryFolders` — so a rebirth takes
the glass down with the wall.

**The spine column moved from x = 8 to x = 0**, because it grew from four
pedestals to six and the last one landed 10 studs from `OwnerSpawnAt`.

### #66 — the mezzanine arrives barren

`floor2` buys the deck, its guards, the wall ring and the ladder. A new
`kind = "Line"` row, `mezz_line`, buys the conveyor and the hopper, and its own
buy pad stands **upstairs** — a barren room with nothing to press is a room you
climb once.

`Config.floorLineBuilt` is sticky, and it is the migration: a profile saved
before this split owns `mezz_dropper1` and no `mezz_line`, and without the
clause that plot gets a dropper installed onto a path with no conveyor under
it. Same trick as `Config.trackUnlocked`, no persisted field, no migration step.

**The coincidence in `floorBuiltFor` is gone in both directions.** Its own
comment warned that the armoury's nine pads were correct only because
`TrackUnlock` happened to name the same button that built the deck. #64 broke
that; this broke the other half. A pad on the deck waits for the deck; a pad on
the *belt* waits for the belt.

**The income-share check was measuring a machine you do not own.** It read
`defRow.at <= row.at` against the *deck's* purchase and then counted every
dropper pinned to the floor's path regardless of when it was bought. Harmless
while the two were one purchase; a straight lie afterwards. It measures at the
line's purchase now.

### #67 — the storey lands two thirds in

The order `TODO.md` item 3 asked for, and the ladder re-priced to carry it.

**The floor moved for the first time for a reason that is about the floor.**
#36 said so in its own words — "the deciding fact is not about the floor at
all" — because `TrackUnlock` gated both cabinets on it. #64 moved that gate, so
every argument that pinned the floor to minute six left with the cabinets.

**After the roof, which fixes a defect nobody had named.** `FloorService`
stands the upper storey's own wall ring up and nothing else ever roofs it. On
the shipped ladder the floor was minute 6 and the roof minute 27, so every plot
in the game spent twenty-one minutes wearing upper walls open to the sky.

**Almost every price moved, and the credit cap is why.** Roblox credits 60
minutes per user per experience per day; `MAX_TOTAL_MINUTES = 150` is not the
binding constraint, that one is. A reorder that kept the shipped prices lands
at 61 minutes and fails. The ladder is re-derived at a flat 2.0–2.4 minutes per
rung, with the opener (50/75/250/500/1500) untouched.

`Rebirth.PriceRung` 4 → 6, because the spine grew by two at the top and every
rank below shifted with it.

**`at <= 10` was deleted rather than retuned.** Its stated reason was "it gates
both cabinets", and that is now false. A check whose argument is false is worse
than no check: the next person reads the message, believes it, and reasons from
it.

**And the check this round owed.** `INVARIANTS.md`'s oldest `[nothing]` entry
was "a hand-typed `requires` on a factory row — the loader derives the chain and
nothing refuses a restatement, which is exactly how the mezzanine became a
dead-end branch". Six rows moved in this PR. It is written as *the chain is
exactly the table order*, because the loader has filled the field in by the time
the verifier runs.

### #68 — light, and time

`Lighting.Ambient` is `(0,0,0)` and the deck spans wall face to wall face, so
from the minute the storey lands the ground floor has no sky. `HANDOFF_v7` §5
listed this first. Twelve `SurfaceLight` fixtures per storey, on the **Bottom**
face: every light here runs `Shadows = false` (at 240 lights across ten plots
it has to), and **a Roblox light with shadows off ignores occluders entirely** —
a `PointLight` under the deck would shine straight through the slab and light
the floor above it.

**The coverage assertion chose the grid, not me.** 2×4 at an inset of 30 was
the first guess and it fails: the darkest floor sample lands 46.8 studs from
its nearest fixture against a range of 55. The binding point is not a corner —
it is the middle of the back wall, which two columns leave 47 studs from either
of them.

The storey now takes **5.2 seconds** to arrive, staged by *wrapping* the
builders rather than teaching five of them about animation. **The pieces
descend**: a slab rising from y = 0 sweeps through every player on the ground
floor, and Roblox's answer to an anchored part moving through a character is to
eject or wedge them. A rebuild is not a purchase — release, rebirth and
re-claim build in one frame as before.

Two of these checks failed on the table written before they were run (stage
gaps, and the stated total). Both were real.

### #69 — guard walls that do not repeat the deleted rails

There were rails once and they were deleted: each leg's ran its *full* length,
and because every leg's surface overruns its bend by half a belt width, leg 2's
inboard rail crossed leg 1's path and vice versa. A rail is now **a run on one
leg set back from both of that leg's ends**, and the assertion states it
directly — a leg's rail box may not overlap any *other* leg's running surface.
Setting `corner` to 0 reproduces the shipped bug in the shipped words.

**Not collidable**, and that is a decision: drops ride a `LinearVelocity` in
Plane mode with lateral velocity pinned to zero, so a solid rail catches
nothing that would otherwise escape and could only catch things that should not
have been caught.

`Config.beltHalfWidth` replaces a **mirrored literal** — `width + 1.2` in
`Belt.lua` and `BELT_BASE_PROUD = 1.2` in the verifier, named by `HANDOFF_v7`
as one of two builder literals wanting to become Config keys. Because it now
carries the rails too, every clearance check in the file measures against the
belt's real reach for free.

---

## 2. The numbers

| | v7 | v8 |
| --- | --- | --- |
| config checks | 2,809 | **3,214** |
| specs / families | 153 / 15 | **158 / 15** |
| spec checks | 3,289 | **3,323** |
| buttons | 34 (factory 21) | **37 (factory 24)** |
| full build | 50 min | **53 min** |
| credit-cap headroom | 10 min | **7 min** |
| longest single wait | 2.9 min | **2.4 min** |
| first rebirth | min 43, 4 rungs left | **min 42, 6 rungs left** |
| cabinets open | 6 min | **3 min** |
| the floor | min 6 (13%) | **deck min 35 (67%), line min 50** |
| the floor's income share | 34% at the deck | **35% at the line** |
| shell parts / plot | 124 | **148** of a 200 budget |
| ceiling fixtures | 0 | **24** over two storeys |
| furniture plan pairs | 238 | **377** |
| analytics combinations | 2,340 | **2,520** of 8,000 |

---

## 3. What only Studio can tell you

**This list is meant to be answered, not appended to.** Two rounds asked the
same question about belt speed and got no answer; the third found the shipped
number was a third value neither had guessed.

1. **Is the ground floor actually lit?** Twenty-four `SurfaceLight`s at
   brightness 2 and range 55 against a black `Ambient` is a guess. The knobs,
   cheapest first: `brightness`, `rows`, then `Config.World`'s ambient off
   black. **This is the check to do first** — it is what item 1 was about.
2. **Does light leak through the deck?** `Face = Bottom` should make it
   impossible, but "a SurfaceLight does not illuminate behind its own face" is a
   claim about the renderer, not about the code.
3. **240 lights across ten plots.** Only ~24 are ever inside the box you stand
   in, but Roblox's per-frame light budget is not documented and every plot is
   visible from the arena.
4. **Does 5.2 seconds read as construction or as lag?** A stopwatch question,
   and it has to be answered twice — once on a desktop and once on a phone.
5. **The descending slabs.** Pieces arrive from sixteen studs up with collision
   off and switch it on when they land. Does a player standing under the landing
   spot get pushed, or does the slab settle around them? The fallback is to fade
   in place with no motion.
6. **Do the guard rails read as guards when you can walk through them?** And
   does the stud of air between kick plate and top rail actually leave the drops
   visible — that is arithmetic against a 0.62-scale model whose real silhouette
   nothing here has measured. Watch a full belt for thirty seconds.
7. **Is the armoury aisle walkable?** Two cases and nine pedestals now run
   z −40..66 down the right-hand side. The verifier says every gap is legal;
   only walking it says whether it is pleasant.
8. **Does the rebirth pad still read as the rebirth pad** in the middle of the
   open floor rather than in the front-right corner?
9. **Does a barren mezzanine work?** It is bought at minute 35 and its line at
   minute 50, so it is an empty room with a ladder for fifteen minutes. That is
   what item 4 asked for. If it reads as a bill for scenery, the lever is
   shortening the gap — not re-furnishing the deck.
10. **Do gates still slide** after being hung by a separate purchase from the
    wall they hang on?

**Carried forward, still unanswered from v7:** the deck's edges are coplanar
with the wall ring's inner faces (z-fight risk); the roof's columns pass through
the deck deliberately; and the shell's part budget at full scale — now 1,480
parts across ten plots, up from 1,240.

**Answered this round:** v7's "does the ground floor read as emptier for having
lost the cabinets?" — the owner's answer was to bring them back, which is what
#64 does.

---

## 4. Open, and known

- **`FloorService` is outside `SERVER_MODULES`.** #66's four-transition sync and
  #68's entire staging mechanism execute nowhere but Roblox. Only the Config
  derivations and `floorBuiltFor` are spec-covered. Widening `SERVER_MODULES` is
  real work and belongs in its own PR — it is the single biggest coverage gap
  this round leaves.
- **`glazeStorey` and `hangGateLeaves` touch BaseParts**, and the harness mock
  has none. The three shell purchases are proved in Config and in
  `hasStructure`; that the builder restyles the right parts is Studio-only.
- **`milestone` is at 37 of a `MaxFieldValues` of 40.** It is every button plus
  `"none"`, so it grows by one for every button anyone adds of any kind. Three
  more and the build fails on an analytics limit with a message about facets.
- **The drop budget is at 65 of 70** across two belts, up from 61. A second
  mezzanine dropper needs `BeltSpeed` raised first.
- **The mezzanine's `landing` zone holds a stairwell and one buy pad.** It is
  116 × 76 studs of deliberately empty deck. That is what item 4 asked for; it
  is also the largest unused area on the plot.
- **`GateService` still looks for leaves in `tycoon.machines`,** and the upper
  storey's ring is not there. No upper-storey opening exists, so nothing is
  unhooked — the day one is declared, that lookup has to widen. Unchanged from
  v7, and #65 did not make it worse: the leaves go into the ring's own model.

---

## 5. If you are picking this up

Run `python3 tools/verify.py` and **read the report, not the exit code**. It
prints the whole progression curve, the shell part count against budget, the
lighting coverage, the floor's two positions and its income share, the first
rebirth and the credit-cap line. Every number in §2 came from it.

The two things this round would tell you if it could only tell you two:

**An assertion whose stated reason has become false is worse than no
assertion.** `at <= 10` said "it gates both cabinets" for a floor that gates
nothing. It was deleted, not retuned.

**Falsify it or it is a guess.** The yard-door check in #64 was written as
`boxBoxGap(...) >= 0` and passed with a cabinet parked squarely across the
doorway — `boxBoxGap` saturates at zero, so that expression is true for every
pair of boxes that has ever existed. Nothing but breaking it on purpose would
have found that.
