# Expansion brief

`IDEAS.md` asks *what should the game contain*. `GROWTH.md` asks *why does
anyone click, stay, or come back*. This document is narrower than either: it is
the next block of work, specified.

**It is a different kind of document from its two siblings, and that matters.**
Those are researched — every claim has a source and the weak ones are labelled.
This one is a **design brief**. The direction is the owner's and is not argued
for here. What is argued for is the constraints: the arithmetic each idea has to
survive, the assertions it will have to move, and the specific ways it can go
wrong. Where a number appears it was computed against the repo at the time of
writing, not remembered — but the *shape* of the work is a decision, not a
finding.

Difficulty follows `IDEAS.md`: **S** = a few hours · **M** = about a day ·
**L** = multi-day.

Written against `HANDOFF_v4.md`. Two defects named there —
`buildButtons` discarding `pos.Y`, and the `padDown`/armour-pedestal overlap —
are prerequisites for §3 and §4 rather than separate work.

---

## The six findings that should shape this

**1. You cannot have "in front of other labels" and "hidden by walls" at the same
time.** `AlwaysOnTop` is the only lever Roblox gives a `BillboardGui` and it does
both at once. So the requirement that lit buttons read clearly *and* stop showing
through walls cannot be solved with depth at all — the hierarchy has to come from
**contrast**, and the X-ray fix is turning `AlwaysOnTop` off where it is on.

Currently on: the buy-button billboard (`Tycoon.lua:945`) and the next-buy
`Highlight` (`DepthMode = AlwaysOnTop`, `Tycoon.lua:1249`). Ten other billboards
already default to off. Two stay on deliberately: `Fx.floatingText` (damage
numbers should read through everything) and Roblox humanoid nameplates, which are
engine-enforced and cannot be occluded at all — during a wave you have up to 26
of those X-raying regardless of anything done here.

**2. Preview buttons are not actually dimmed.** `refreshButtons` changes colours
and nothing else. The panel keeps `BackgroundTransparency = 0.2` and
`LightInfluence = 0` in every state, so a locked button is exactly as bright as a
buyable one and differs only in hue. That is the whole "too intrusive" complaint,
and it is four properties.

**3. The belt has 1.21× of headroom.** Peak spawn is 7.94 drops/sec against a
7.29 s transit: **57.8 drops in flight against a `MaxDropsPerPlot` of 70.** Any
mechanic that only speeds up droppers hits the cap at +21%, and past that the cap
silently eats the income the player just paid for — which is precisely the
failure the assertion exists to prevent.

**4. Floor 2 unlocking on the last button is the wrong end of the build** — but
the opposite error is the documented number-one complaint in the genre.
`IDEAS.md` §15 quotes it: *"I dislike that you buy floor 2 before you even get
close to finishing floor 1."* The halfway mark threads both. On the measured
curve that is `upgrader4` at 38.4 minutes of a 79.8-minute build.

**5. Wave size and wave pressure are different dials.** `MaxChasers = 8` caps how
many raiders can engage one player at once. A bigger wave is therefore
*reinforcements*, not more simultaneous pressure — which is why "make the waves
larger" does not undo the anti-swarm work from #17. It is worth knowing this
before someone reads the two asks as contradictory.

**6. World text has no shared vocabulary.** Across 13 billboards: three fonts
(`FredokaOne` ×9, `GothamBold` ×3, `GothamMedium` ×1), seven different
`TextStrokeTransparency` values with only three labels setting a stroke *colour*,
`MaxDistance` spanning 90 to 1200 with no shared constant, and two different
panel treatments (corner radius 10 / stroke 2.5 on buy buttons, 12 / 3 on the
plot totem). `TungModels.paintFace` defaults `MaxDistance` to `0`, which means
unlimited — every statue's face in every plot renders at any range.

---

## 1. Legibility and layering · S

Nothing depends on this and everything looks better after it. Do it first.

### The contrast ladder

Three states, currently distinguished by hue alone. They should be distinguished
by **weight**, so the plot reads correctly in peripheral vision:

| | panel | stroke | light | text |
| --- | --- | --- | --- | --- |
| available | opaque | full | on | bright |
| preview | mostly transparent | thin or none | off | dim |
| hidden | not parented | — | — | — |

Concretely, `refreshButtons` should be mutating `BackgroundTransparency`,
`UIStroke.Transparency`, `UIStroke.Thickness` and `LightInfluence` alongside the
colours it already changes. A preview panel at `BackgroundTransparency ≈ 0.75`
with a hairline stroke and `LightInfluence = 1` recedes into the plot instead of
competing with the button in front of it.

The billboard is also a fixed `UDim2.fromScale(16, 9)` in every state. Previews
being physically smaller is the cheapest legibility win available and costs one
property.

### The X-ray audit

Turn `AlwaysOnTop` off on the buy-button billboard and switch the beacon
`Highlight` to `HighlightDepthMode.Occluded` — note `UpgradeService`'s freeze
Highlight already uses `Occluded`, so this makes the two consistent rather than
inventing a convention.

The comment on the current `AlwaysOnTop = true` is not wrong about the problem it
solved — *"without this the label for the button you are walking towards
disappears behind the dropper next to it"* — so expect to move the billboard's
`StudsOffsetWorldSpace` up a little to clear the machinery it now hides behind.
That is the trade, and it is the right one: hiding behind a wall you are on the
wrong side of is correct, hiding behind a machine two feet away is not.

### The shared vocabulary

One decision each, applied everywhere:

- **Fonts.** `FredokaOne` for names and headlines, `GothamBold` for numbers and
  secondary lines. Drop `GothamMedium`.
- **Stroke.** One `TextStrokeTransparency` and one `TextStrokeColor3`, as a
  shared constant. Seven values across thirteen billboards is not a design.
- **`MaxDistance` bands** by purpose rather than per-site: *interact* (you need
  to be close — machine nameplates, shelf plates), *locate* (you are looking for
  it — buy buttons, cabinet signs, pads), *landmark* (visible across the map —
  plot totem, claim sign, arena title). Three constants replacing eleven numbers.
- **`paintFace` gets a real default.** `0` means unlimited; drops already pass
  140 explicitly. Statues should too.

### Also worth folding in

The three background literals in `HUD.renderWave` (`(48,18,18)` twice,
`(18,40,26)`) sit inline while the text colours were deliberately promoted into
`PALETTE`. Finish that job. And the buy-button "available" branch re-states three
`Color3.fromRGB` literals that already exist at build time a few hundred lines
up — hoist them.

---

## 2. Wave pacing, and the banner moves into the world · S

### Pacing

| key | now | to | why |
| --- | --- | --- | --- |
| `FirstWaveDelay` | 60 | **30** | first raid inside the first minute |
| `RestTime` | 20 | **18** | raiders *land* 30 s after a clear, warning included |
| `WarningTime` | 12 | **12** | **do not touch** — see finding in `HANDOFF_v4.md` §2 |
| `BaseCount` | 4 | **6** | |
| `CountPerWave` | 2 | **4** | reaches the cap at wave 10 instead of 12 |
| `MaxCount` | 26 | **40** | |

At `MaxCount = 40` a full wave arrives as 10 clusters over **10.2 s** — still
inside `RestTime`, still nowhere near `MaxWaveTime`, and the existing assertion
that a wave must finish arriving before the rest is over continues to hold.

The cost is parts: **840 bat parts at cap against 546 today**, before machines,
drops and cabinets. Part budget at full scale is already an untested open item,
so this is the change most likely to be the thing that finally proves it needs
attention.

### The banner

Today it is a 420×62 `ScreenGui` panel pinned top-centre of everyone's screen.
It should be a sign over the arena statue: in the world, ignorable, and pointing
at the place the raid actually happens.

The arena already has the pattern — a `TitleAnchor` at `(0, 34, 0)` carrying a
`BillboardGui` at `MaxDistance = 900`, which is comfortably visible from the plot
ring at 210–265 studs. A second anchor below it, or a third line on the existing
one, is the whole change on the world side.

Keep from the current implementation, because all three were deliberate:

- the countdown ticks client-side off the `RenderStepped` connection that already
  runs the cash counter — the server sends `seconds` once per phase, so a ticking
  timer costs no extra remote traffic;
- visibility derives from state any newer packet overwrites, rather than from a
  `task.delay` that a new wave can arrive inside;
- the `resting` phase is broadcast, because 18 seconds of dead air with nothing
  on screen is most of what made the old gap feel long.

Simple and unintrusive means: one line, big, `FredokaOne`, no panel behind it, no
stroke competing with the arena title above it.

---

## 3. Floor 2, for real · L

This is the prize, and it is genuinely multi-day. `FloorService.lua` already
exists at 406 lines and builds a deck, rails, posts, a belt, a collector, one
dropper and a teleport pad pair — all of it flag-gated off and **none of it ever
executed in Roblox**.

Order matters here; the first two items block everything after them.

**1. `Tycoon:buildButtons` must stop discarding `pos.Y`.** It builds every button
at `self:at(pos.X, 0, pos.Z)` while `buttonPosition` already returns the correct
height for a belt machine on any path. One line. Until it changes, no purchasable
content can stand on the mezzanine and the floor can never be more than scenery
with a free dropper on it.

**2. Floors has to graduate out of `Config.Prototypes`.** `check(on == false)`
asserts every prototype flag ships off, so `Floors = true` fails the build. This
is the contract working as intended — a prototype you cannot turn off is not a
prototype — and graduating means moving the config out of the prototype block,
not special-casing the loop.

**3. Floor 2 needs a real buy button.** Today `FloorService.sync` grants the
whole floor free the instant `dropper10` is owned. It should be a purchase like
everything else, and it should sit at `upgrader4` — factory step 14 of 19, 38.4
minutes into a 79.8-minute build. That means changing the assertion that
currently requires the unlock to be in the last two factory steps; the intent
(*don't open floor 2 before real progress*) survives as "in the back 40%".

**4. `incomePerSecond` has to see the floor.** It walks `Config.ButtonById` and
tests `self.owned`, and the mezzanine dropper is `floor_mezzanine` — never in
that table, never in `owned`, because `FloorService` bypasses `Tycoon:install`
entirely. Three things under-report the moment the floor runs: the plot totem,
the vault sign, and — subtly — every **upgrader** buy button's effect line, since
an upgrader's quoted delta is a multiple of a total that is missing a term.

**5. `onOwnedChanged` becomes a list.** It is a single slot with a comment saying
*"make it a list the day there are two."* That day is this one.

**6. The drop budget is plot-wide and the verifier only models one floor.**
`MaxDropsPerPlot = 70` against a ground-floor peak of 57.8 leaves room for
roughly one more dropper, and the mezzanine wants its own. Either the model grows
to cover every path, or the cap does, or the floor's dropper is deliberately slow.
Pick one on purpose rather than discovering it.

**7. The geometry is tighter than it looks.** The deck's back edge sits flush
against the back wall's inner face, and the roof columns clear its underside by
**0.4 studs**. The roof installer already shortens itself when the Floors flag is
on, which is the kind of coupling that breaks quietly when either side moves.

**8. Fold the two `SHOULD MOVE TO CONFIG` blocks in.** All of `FloorService`'s
geometry constants, and the dropper spec, currently live as file-locals because
`Config.Floors` had no key for them.

**9. Put the mezzanine's belt path where the verifier can see it.**
`FloorService.deckPath()` builds a path in code, so no belt-path assertion has
ever run against it — not that its legs stay on the deck, not that its collector
clears the pad, not its outboard signs. And add `padUp`/`padDown` to the
floor-furniture list, which is what turns the known 3×1 stud pad/pedestal overlap
from a thing somebody finds in Studio into a build failure.

---

## 4. The cabinets become a floor-2 reward · M

Depends on §3.

The weapons and armour cabinets currently stand on the plot from the moment it is
claimed: two 13-stud display cases and nine pedestals, for a system the player
cannot use and has no context for. They should appear when floor 2 does.

**Mechanism: a track-level gate**, e.g.
`Config.TrackUnlock = { weapons = "floor2", armor = "floor2" }`, read by
`refreshButtons` and by `buildCabinets`. Deliberately **not** a per-button
`requires` — #12 asserts that no requirement crosses a track, and that assertion
is worth keeping. A precondition on a whole track is a different thing from a
link inside a chain, and modelling it as the latter would either break the
assertion or force a special case into it.

Build the cabinets lazily, the way `ensureButtons` already defers button
construction to first claim. They are in `self.props` and survive rebirth, so the
gate needs to be checked on unlock rather than only at construction.

**State the cost plainly:** combat is un-upgradeable for the first ~38 minutes.
That is a real consequence of the ask, and it is the reason floor 2 moves to the
halfway mark rather than staying at the end — at `dropper10` it would have been
80 minutes, which is most of a full build fought with the starter bat and no
armour.

---

## 5. The generator yard · M

A bought extension beyond the plot's back edge (`z < -70`), behind belt leg 1,
outside the wall ring. It speeds up production and costs Tung to upgrade.

### The mechanic, and why it has to be coupled

Each tier multiplies the drop rate **and the belt speed by the same factor.**

Belt speed does not affect income — income is `dropValue / dropRate` — it affects
only density and latency. So raising it alongside the drop rate is free, and it
is what keeps the belt from jamming:

| tier | rate | belt | in flight | vs cap 70 |
| --- | --- | --- | --- | --- |
| none | ×1.0 | 28 | 57.8 | ok |
| I | ×1.2 | 34 | 57.8 | ok |
| II | ×1.4 | 39 | 57.8 | ok |
| III | ×1.6 | 45 | 57.8 | ok |
| IV | ×1.8 | 50 | 57.8 | ok |

In-flight count stays **exactly flat** while income scales with the rate.
Without the coupling, ×1.4 alone is 81 drops in flight against a cap of 70 and
the cap eats the difference silently.

This is also the thematically honest version: a generator powers the line, so the
line runs faster — belt included.

### Geometry

Extending backwards is much cheaper than extending sideways. The ring radius
solves from `PlotSize.X + PlotGap`, so **X growth re-solves the ring for every
plot count** and re-runs every packing assertion. Z growth only touches the
radial ring-to-ring clearance and the arena/baseplate checks, and at 10 plots the
farthest plot edge is 335 studs against a `MAX_WALK` of 420 from the arena rim —
so there is real room behind the plot.

The catch is that **nothing at an absolute plot-local coordinate scales with the
plot.** The verifier already warns about this for floor furniture; a yard that
changes `PlotSize.Z` moves the pad edge out from under the belt, the walls, the
totem, the cabinets and the floor deck all at once. Adding a *separate* yard slab
beyond the pad, rather than growing `PlotSize`, avoids the entire class — at the
cost of a second surface height to keep off the existing ones.

---

## 6. What this expansion costs

- **Parts.** 40-raider waves take bat parts from ~546 to ~840. Floor 2 adds a
  deck, four posts, a rail ring, a belt, a collector, a dropper and two pads per
  plot. The generator adds a yard. Part budget at full scale was already untested
  and this is three separate pushes on it.
- **`MaxDropsPerPlot`.** One number shared by a ground floor at 57.8, a
  mezzanine that wants its own dropper, and a generator that multiplies the rate.
  Two of the three sections above both want that headroom.
- **Assertions that have to move:** the Floors unlock `trackOrder` check (§3.3),
  the prototype-flags loop (§3.2), belt throughput to model every path (§3.6),
  the new pad-vs-furniture cross-check (§3.9), and whatever the yard does to plot
  packing (§5).
- **Nothing here is verifiable by the verifier.** Legibility, floor layout and
  generator feel are all Studio work, and this repo's last two rounds produced
  three separate changes that passed every check and still had to be judged by
  eye.

---

## Where this is thin

- **The whole document is a brief, not research.** Its siblings cite sources;
  this one cites the repo. Where it says a thing will feel better, that is a
  design opinion with arithmetic attached, not a finding.
- **The wave sizes are a guess with a part count.** `MaxCount = 40` satisfies
  every existing assertion and reaches the cap two waves earlier. Whether 40
  raiders is *fun* against a chaser cap of 8 is untested and unmodelled — the
  anti-swarm reasoning says it should read as reinforcements, and that reasoning
  has never run in Roblox.
- **The generator tiers are shaped, not tuned.** ×1.2 through ×1.8 keeps the belt
  flat and that is the only property checked. Prices, tier count and how it
  interacts with the upgrader stack are open.
- **Floor 2's income model is unresolved.** §3.4 says `incomePerSecond` must see
  the floor; it does not say whether a mezzanine dropper should be a `Config`
  button (which fixes the income gap for free but needs a slot table for an upper
  floor) or stay a `FloorService` construction with a registration hook. That is
  the first real design decision of §3 and it is deliberately left open.
- **"Not too visually intrusive" is not measurable.** §1 turns it into four
  properties and a contrast ladder, which is the best available proxy. Whether
  the result reads as intended is a Studio judgement.
