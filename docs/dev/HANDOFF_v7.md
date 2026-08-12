# Tung Tung Tycoon — Handoff v7

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v6.md` on the walls, the second floor, the cabinets and
the verifier's pass count. v6 is still right about the generator, session
locking, analytics and the shared boss. v3 is still the only correct account of
**procedural animation** — read its §2 before you touch `SwingAnim.lua`.

**New, and read this before anything else: the landmine lists have moved.**
`docs/dev/INVARIANTS.md` is the live contract now — every load-bearing rule in
the project, grouped by subsystem, with **what enforces it named on every
line**. It supersedes, for current truth, the §-sections that used to carry them
(`HANDOFF.md` §5, `v2` §5, `v3` §2, `v4` §2, `v5` §2, `v6` §2 and §G2). Those
sections remain the historical record of *why* a round decided something. And
`docs/dev/ARCHITECTURE.md` is the module map; `CLAUDE.md` at the root is the
operating manual. An agent no longer has to read six documents in reverse order
to find out what it must not break.

Seven pull requests, all stacked. §2 is the part to read before you change
anything.

**This round's brief was `TODO.md`, four items — and the first thing it found was
that item 3 was a symptom, not a feature request.**

---

## 1. What changed

| PR | What |
| --- | --- |
| #54 | **the client had been dead at boot since #50**, and the lint that would have caught it |
| #55 | `CLAUDE.md`, `ARCHITECTURE.md`, `INVARIANTS.md`, and the `Config.<path>` sweep v6 asked for |
| #56 | `Tycoon.lua`'s 2552 lines become twelve files, and a lint keeps the aggregator honest |
| #57 | the walls close, get windows, and get gates that open on approach |
| #58 | the second floor spans the plot and the armoury moves onto it |
| #59 | one status card: the balance, and how far you are from the next thing |
| #60 | this document |

### #54 — the client had been dead since #50

`src/client/SessionUI.lua:35` evaluated `local UI = Config.UI` in a file whose
`local Config = Req("Config")` had been deleted by `2c9cb7e` (#50) — the
flag-graduation hunk took the require out along with a `compact` local and left
**both reads of `compact`** behind. `Req` re-raises a failed require, and
`Main.client.lua:11` requires `SessionUI` **before** `HUD.start()` on line 15.

So the LocalScript died before one pixel was drawn. No Tung balance, no NEXT
UPGRADE panel, no toasts, no rebirth button, no hitmarker. **Every symptom in
`TODO.md` item 3 was that one line** — including "this used to be a feature but a
developer dropped it", which is why the brief asked for archaeology. There was
none to do: `buildNextPanel`, `cheapestAvailable` and the "N to go" line are all
still in `HUD.lua`, and `git log -S"nextDetail" --all` returns the commit that
*added* the feature and no commit that removed it.

**Nine green passes said otherwise, and one of them was the culprit.**
`tools/verify.py:31` dropped the entire `Unknown global` diagnostic class as
Roblox noise — and `luau-analyze` had reported this defect, once per read, in as
many words. The filter now **names the 40 Roblox globals** instead, and anything
else that reads as a global is an undeclared identifier that fails the build.
Over 22k lines that list has exactly two offenders, and both are this bug.

Two escape hatches closed while they were open: `CombatClient` parented the
hitmarker straight to the `ScreenGui`, outside the `UIScale` *and* the safe area —
the exact failure the one-ScreenGui lint exists to prevent, reached without
making a second ScreenGui because `HUD.screenGui()` handed out the way past the
layers. The accessor is gone. And `UI.SessionPanel.CompactHeight` was the height
the deleted `compact` local selected: unreachable since #50, now deleted and
asserted absent.

### #55 — the documents, and the tenth pass

The token tax was real and measurable: six handoff documents to learn the
invariants, and a `README.md` file tree that named 18 of 31 source files.

`INVARIANTS.md` is the live contract, and the **enforcement marker is the
point**. As it stands after the round: `[assert]` 101, `[nothing]` **70**,
`[spec]` 37, `[lint]` 9, plus a handful of `[runtime]`.
The markers were verified by grepping the tools rather than from memory, and
several things the handoffs imply are checked turned out not to be —
`TrackInfo.power.keepOnRebirth`, the mezzanine's refinery mechanism, the boss
damage ledger, and "no factory button carries an explicit `requires`". §10
collects the 62 into a backlog grouped by *the cheapest thing that would catch
each one*, so a future round can take a row instead of a chapter.

The tenth pass is v6 §G4's top unclaimed item: every `Config.<path>` read in
`src/` must name a key that exists. It resolves 21 aliases including the two-deep
ones and correctly refuses to treat scalar binds as table prefixes, which is what
takes it from a handful of references to 539.

### #56 — twelve files, and the new way to fail silently

`src/server/Tycoon.lua` split along the seams its own banners already marked.
`Req.find` has always walked one level of folder nesting — *"so folders can be
used for organisation"* — and nothing had used it.

The split is **proved behaviour-identical**: the old file and the concatenated
new ones, with module scaffolding stripped, are 2,243 non-blank lines each, the
same multiset, byte for byte; and the spec suite reports the same counts before
and after, down to the `modules executed:` line.

Two tooling constraints were falsified rather than assumed. `pack.py` globbed one
level deep, so with the old glob the packed server build **loses 121 KB, contains
no `__MODULES["Tycoon"]` at all, and compiles clean** — every pass green and the
no-Rojo install dead at boot.

And the split created a new way to fail silently, so it got a pass of its own:
the aggregator's `Req("Belt")` lines are *code*, not imports. Delete one and a
dozen methods stop existing with every other pass green, because the name that
goes missing is a method on a table rather than a local, and a file nobody
requires compiles fine.

### #57 — the walls, and the gap that was bigger than the doorways

The walls were five boxes at a local literal `h = 13` while the roof's underside
was `RoofY = 20`. **Every plot in the game had a seven-stud open band all the way
round it**, and not one of the 2309 config checks looked at wall height,
thickness, or what the openings were — because none of those numbers was in
Config. The two deliberate openings had no doors and there were no windows
anywhere in the game.

There is one structural line now: a storey's ceiling is the floor above it, and
the ground storey's clear height is *derived* from the mezzanine deck's underside.
That also deletes the roof's shrink rule rather than extending it — the roof sits
on the top storey that exists, so there is no half-roof state to model.

Spans are a list rather than arithmetic in a loop: `Config.wallSegments` returns
the solid runs and the openings, the builder emits exactly what it is handed, the
verifier sums it and a spec exercises it against inputs the shipped config does
not contain.

### #59 — one card, and the client boots headless

The cash panel and the NEXT UPGRADE panel are one `StatusCard`: the balance
largest and first, what multiplies it on one line under it, a rule, then the next
purchase with its price, **a progress fill** and the remainder. The fill and the
number are driven off the same lerped balance from the same `RenderStepped`, so
the card cannot contradict itself while the money is counting up — which is the
moment it is read most closely.

Not one Y is typed in `HUD.lua`: eighteen values are derived in `Config.UI`, each
row's Y accumulated from the row above it, so a row that changes height moves the
rows under it, the card, the session panel's Y and the column's bottom, and the
verifier re-checks the fit against all four.

**Two more shipped defects fell out of the new assertions**, neither of them what
anyone went looking for. The `NEXT UPGRADE` heading was 12 design px — 7.4
physical px at `MinScale`, under both floors `Config.UI` itself declares. And the
INVITE button was a `72x26` literal: 16 physical px tall at `MinScale`, on the one
control in the game meant to be pressed by a child.

`src/client` had never executed headless, which is the other half of why the boot
defect shipped: **a lint catches an undeclared identifier; it does not catch a
module that raises for any other reason.** The most valuable spec in the new `hud`
family is the one that compares `HUD.cheapestAvailable` against
`Tycoon:pointAt`'s ranking at every step of the build. `HUD.lua` says of those two
copies that keeping them identical "is not a plan, it is a hope" — and nothing had
ever checked the hope.

### #58 — a storey, not a mezzanine

The deck covered the back 60 studs of a 140-deep plot, and both cabinets stood on
the ground floor — even though `TrackUnlock` has gated both on `floor2` for two
rounds, so the mezzanine was already what opened them.

`Config.Floors[1]` describes its contents as **named zones** now, which is item
1's fourth bullet. And **the `line` zone is the old deck rectangle to the stud**,
with `floorBeltPath` derived from the zone rather than the deck: that is what let
the deck grow to span the plot without moving a single belt leg, machine, hopper
or drop-budget number.

Where the stairwell goes took three attempts, and both failures are written into
Config beside it — the aisle at `x = GateCentre` is the most contested strip on
the storey, losing first to the mezzanine belt's *base* (0.1 studs) and then to
the machine row of its return leg.

---

## 2. Invariants

**They are in `docs/dev/INVARIANTS.md` now, not here.** That is the round's
biggest single change to how this repo is worked in, and duplicating them into
this document would recreate exactly the problem it solves. §3 gained a "building
shell" section and had its second-floor section re-authored; §9 gained the two new
lints.

What belongs *here* is the argument, because it is this round's theme.

### The theme: a thing that reads as checked and is not

v6 §G3 named this class and counted four instances in one round. **This round
found eight**, and it is no longer reasonable to treat them as incidents:

1. **The dead client**, invisible because a noise filter swallowed the diagnostic
   that named it.
2. **`UI.SessionPanel.CompactHeight`** — a layout no state could select, sitting
   in Config being asserted about.
3. **`deckAt.Z + deckHalfZ + 2 > deckAt.Z + deckHalfZ`** — an assertion that
   could not fail, in the mezzanine block.
4. **`Config.shellPartCount` under-counting by 13%** — it modelled the wall spec
   rather than what the builder emits, so the part budget was asserted under the
   truth. A budget that passes right up until it matters.
5. **`ladder.at`** — a number the verifier measured while the builder derived its
   own, so *every* ladder clearance check was holding a phantom box against
   furniture it was nowhere near.
6. **`Config.floorTopY` falling back to 0** for an unknown id, which would have
   put the whole armoury back on the ground floor with every check still passing,
   because `0 == 0`.
7. **The tycoon aggregator's require list**, enforced by nothing: delete a line
   and a dozen methods vanish, green.
8. **A clearance assertion written this round that measured the machine's far
   edge**, giving it five studs of phantom slack — and so passing on the exact
   geometry it had been written to catch.
9. **A text size and a touch target under the floors `Config.UI` itself
   declares** — a 12px heading and a 26px button — sitting in a file where no
   assertion could see them, beside a `MinTextPx` and a `MinTouchPx` that were
   being asserted about everything else.
10. **A spec suite that reported 155 specs when the tree had 142**, from an agent
    that believed it had finished. The gap was found by running the suite rather
    than by reading the report, which is the same lesson one layer up: **a
    completion report is a claim, and the tool is the authority.**
11. **Two branches of the next-purchase ranking that cannot change the answer**,
    and so a spec over them that passed whatever they did. The track gate only
    hides the two cabinets while `mezzanine` is unowned — and `mezzanine` is a
    *factory* rung, so it outranks anything the gate could hide; the price
    tie-break only applies within one track, and a track is a chain, so exactly
    one rung is ever available. Both were found the honest way: by mutating them
    and watching the spec stay green. `hud_spec.lua` now gates the *power* track
    and ties two `TrackRank` values, so each branch lands somewhere it decides.

    This one is worth more than its size. It is not a defect in the game — the two
    rankings agree at every state anyone could reach. It is **two
    hand-maintained copies of a branch that can drift forever with the game
    looking fine**, which is what `HUD.lua`'s "not a plan, it is a hope" comment
    was worried about, and neither the comment nor a naive spec could see it.

Number 8 is the instructive one. It was written *in this round*, by someone who
had read the other seven, and it was caught only because the convention is to
break every assertion you add. **That convention is not optional and it is not
about being thorough. It is the only thing that distinguishes a check from a
comment with a `check()` around it.**

### What follows from that

- **A fix without an assertion is half a fix.** Every defect above is now watched
  by something that has been seen to fire.
- **When two things must agree, derive them from one.** #5 and #6 are both two
  sources for one number. `Config.floorLadderAt`, `floorLandingAt`,
  `wallSegments` and `roofUnderside` exist so the builder and the verifier cannot
  disagree.
- **A silent fallback to the safe-looking value is the most expensive kind of
  bug this project has.** `powerFactor = 1`, `floorTopY = 0`, `unlocks` caching a
  pure function. Prefer raising: `Style.distance(tier)` set that precedent and
  `floorTopY` now follows it.

---

## 3. The verifier and the harness

**Eleven passes**, up from nine — and the count is now stated identically in
four places, because it has been wrong in three of them at once (README said
five, the docstring seven, v6 §G3 eight, `main()` ran nine).

| # | pass | new? |
| --- | --- | --- |
| 1 | syntax | |
| 2 | analysis — **the Roblox globals are named** | rewritten |
| 3 | style ownership | |
| 4 | prototype flags | |
| 5 | **config paths** — every `Config.<path>` leaf exists | **new** |
| 6 | **mixin folders** — the aggregator requires every file | **new** |
| 7 | ui geometry | |
| 8 | one screengui | |
| 9 | config integrity | |
| 10 | runtime specs | |
| 11 | packed build | |

Config checks: **2309 → 2781**. Specs: **108 in 12 families → 149 in 15**, and
checks in them **603 → 3264**. Three new spec families: `structure`, `floor`,
`hud`.

**The client executes outside Roblox for the first time.** `modules executed:`
now reads `Config Analytics DataService SessionService Net Tycoon Economy UiKit
HUD CombatClient UpgradeUI SessionUI Util SocialService`. `Main.client.lua` is in
there too — the one entry script the harness loads as a module, because requiring
it is what makes the boot ORDER covered rather than transcribed into a spec that
would not notice a reordering. `NPCService`, `PlotService`, `UpgradeService`,
`VaultService`, `FloorService` and `GateService` are still out.

**Its limits have not moved, and one of them got sharper.** `verify_config.lua`
still reads `src/shared/Config.lua` and nothing else, and its `Vector3` is still
a bare table with no arithmetic. The `Config.<path>` lint is scoped to `src/`
deliberately: `verify_config.lua` *reads keys it expects to be absent*
(`check(UI.SessionPanel.CompactHeight == nil, …)` is one), so covering the
verifier would mean teaching the lint the difference between a dangling read and
an asserted absence. That is the next inch, and §10 of `INVARIANTS.md` says so.

---

## 4. What is still open

- **Rebirths 4 through 12 still collapse to one-to-three-minute loops.** Untouched
  by this round, and still the strongest candidate for a next round's item 1. The
  lever is scaling prices by `profile.rebirths` in `Tycoon:tryPurchase`; no value
  of `BaseCost` or `CostGrowth` fixes it, and that was swept for.
- **`mezz_dropper1` is still 0.002% of endgame income.** The floor now has a
  *reason* to exist all game — the armoury is on it — but its own production line
  still stops mattering by minute twenty. A second mezzanine dropper priced into
  the mid-game is still unwritten.
- **`NPCService` and `PlotService` still cannot be specced**, and the client is
  only partly in (see §5). Widening `SERVER_MODULES` further is real work.
- **62 `[nothing]` invariants**, itemised in `INVARIANTS.md` §10 by the cheapest
  enforcement that would close each. That list is the most actionable backlog
  this repo has ever had.
- **Raider pathfinding is still naive `MoveTo`.**
- **No icon, no thumbnails, no trailer.** Still 100% of acquisition.
- **`GateService` is outside the harness**, so the gate tick loop is `[nothing]`.
  The geometry it moves is asserted; the moving is not.
- Three remotes are declared and never fired (`Purchased`, `Sfx`, `FloorState`)
  and `PlotAssigned` has no client listener.
- **Six residual gaps in the client harness**, each named with its mechanism in
  `mock/gui.lua`'s header and in `ARCHITECTURE.md` §7. Two of them are deliberate
  and should stay that way: no tween advances, because a tween mock that jumps to
  its goal would make the toasts and both modals *look* tested; and no rectangle
  is ever resolved, because fit and overlap are `verify_config.lua`'s job and it
  can see the whole column at once.
- **Two builder literals the verifier cannot derive** are mirrored in
  `verify_config.lua` and declared as couplings rather than read: the cabinet's
  trim/anchor/billboard offsets in `Props.lua`, and the belt base's
  `BeltWidth + 1.2` in `Belt.lua`. The second is load-bearing — it is what the
  stairwell's first position failed against — and both want to be Config keys, the
  way `Structure.Trim` became one when `shellPartCount` needed to count it.
- **Nothing sweeps floor furniture against the vault shell.** Added for the truss
  and the hatch because Config's comment claims that clearance; the general case
  is still uncovered.

---

## 5. What only Studio can tell you

The round changed what a plot *is* — an enclosed two-storey building instead of an
open slab with a half-roof — so this list is longer than usual and the first item
is the one that could sink the rest.

1. **THE GROUND FLOOR IS NOW INDOORS.** `FloorService`'s header argued for a
   back-half deck because *"Roblox has no good answer for a ceiling: opaque snaps
   the camera to head height, transparent lets it pop through"*. `TODO.md` asked
   for a full-span floor anyway, and it is built. The mitigations are real —
   20.4 studs of headroom, PopperCam sits under it, and the walls are glazed at
   `Transparency` 0.45 so light and camera both pass — but **this is the check to
   do first, and the levers if it plays badly are, cheapest first: more glass, a
   taller ground storey, or a light well over the aisle.**
2. **The gates opening on approach.** 5 Hz distance tick, tweened leaves. Watch
   for a gate that opens late as you walk into it, and for the yard door, whose
   leaf slides outboard over the yard slab.
3. **The stairwell.** Climbable up *and* down; you step off onto the deck through
   the gap in the guard rather than into the void; and coming down you enter the
   truss rather than walking round the hole. It is in the deck's front-left
   quarter — does that read as "the way up" from the gateway?
4. **The armoury upstairs at minute six.** Both cabinets now arrive on a floor you
   have to climb to. Does the storey read as somewhere to go, or does the ground
   floor read as emptier for having lost them?
5. **The deck's edges are coplanar with the wall ring's inner faces.** That is
   what "spans the plot" means, and coplanar faces are exactly what every other
   surface height in this game is offset to avoid. Look for z-fighting along the
   base of each wall.
6. **The roof columns pass through the deck.** Deliberate — a column through a
   floor reads as a column — but it wants an eye.
7. **The part budget in practice.** 124 parts of shell per plot, 1240 across ten,
   against ~10 before. Asserted against a budget of 200; watch frame time on a
   full server, which is the thing no arithmetic here can reach.
8. **A drop crossing an upgrader on an UNATTENDED plot** — unanswered since v5.
   Stand on a neighbour's plot or force `PhysicsSteppingMethod = Fixed60`.
9. **Belt speed with `power3` and `belt1`** — `(28 + 9) × 1.68 = 62.2`. This is
   the **fourth** handoff to ask. `!give power3` + `!give belt1`. It was asked
   twice and answered zero times before #35 found the real answer was 37.
10. **The status card on a real phone.** The column ends at y=542 of a 720 design
    frame, and the card is held to `ReferenceHeight` rather than to a declared
    shortest supported viewport — because at 320px landscape the *session panel*
    alone overruns, and failing the build on an invented minimum would be worse
    than not asserting one. **Whether sub-446px-tall landscape screens are
    supported is a product decision nobody has made**, and it is the one number
    that would turn this into an assertion.
11. **Two servers racing one profile.** Everything in #45 rests on two claims
    about `UpdateAsync` that only Roblox can settle.

---

## 6. Conventions

Unchanged from v6 §6 and §G6, plus three.

- **New: the enforcement marker is part of the invariant.** When you add one to
  `INVARIANTS.md`, name what would fail — and if the answer is "nothing", add it
  to §10 in the same edit. The gap between a documented invariant and an enforced
  one is where #35 lived for two rounds and where six of this round's eleven
  finds lived.
- **New: when two things must agree about a number, derive both from one.** Not
  "keep them in sync" — there is no such thing. `ladder.at` versus a builder's
  own derivation is the whole lesson.
- **New: prefer raising to falling back.** A function that returns the
  safe-looking value for a bad input hides the bug and passes the check.
  `Style.distance` and now `Config.floorTopY` both error on an id they do not
  know.
- **New: run the tool, do not read the report.** Work was fanned out to
  subagents this round, and one reported a spec count the tree did not have.
  Nothing bad shipped because the numbers were checked — but the check is the
  point, and it applies to a colleague's summary exactly as it applies to a
  comment claiming an invariant holds.
