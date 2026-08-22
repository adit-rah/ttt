# HANDOFF v13 — the plot grows outward

design:D-02, via #88. The second storey retires whole — FloorService,
Config.Floors, the staged raise, the truss, per-storey lighting, the
ground-plus-upper pair, kinds Floor and Line, floor_spec's 18 specs and some
720 lines of verifier — and land replaces it as the growth axis: ten
expansions, five a side, each narrower than the last, bought alternating by
price alone, with the walls, roof and lights following the ground outward.

The curve was rebuilt around it and holds every band: 59-minute build inside
the 60-minute credit cap, first rebirth at minute 50 with six rungs unbought,
side tracks at 34%, BaseCost still deriving to 120M. The simulation's printed
curve shows the land buys strictly alternating, and a check asserts it.

## 1. What moved where

| was | is |
| --- | --- |
| `Config.Floors` + `FloorService` (724 lines) | `Config.LandLButtons`/`LandRButtons` + `tycoon/Land.lua` (ensureLand on the refreshButtons beat) |
| `Structure.Storeys`, `ground.clear` derived from the deck | `Structure.WallHeight = 20.4`, the shipped number verbatim |
| `buildStoreyWalls(model, storeyId)` | `buildWallRing(model)`, reading `landState()` |
| `eachStoreyRing` | `withWallRing` |
| `refreshStoreyLights` | `refreshCeilingLights`, column count derived from width |
| `ButtonUnlock = { floor2 = "roof" }` | `{}` — mechanism and fixpoint stay for #125 |
| ring pitch = centre width | ring pitch = `PlotMaxWidth` (land is acquired, never reserved) |

## 2. What only Studio can tell you

The reconciler needs a model and a plot CFrame, so nothing about it executes
in the harness — `ensureLand` bails on stub plots by design, and every line
below is unverified until someone stands in Studio and looks.

1. **ensureLand on a real plot.** Buy landL1: the slab appears, the west wall
   moves out, the front and back walls gain a span, the roof widens, the
   fixtures re-emit. Then release and re-claim: the ground replays from the
   save.
2. **The side-wall move under a standing player.** Buying landL2 destroys the
   west wall's courses at the old extent and re-emits them further out.
   Someone standing in that wall's line should be pushed, not wedged.
3. **A gate tween across a land purchase.** Stand in the gateway while buying
   land: rebuildWallRing spares `Gate_*` parts by name, so the tween should
   continue — confirm GateService's cached state survives, since the leaf
   specs' closed/open CFrames did not move.
4. **The lopsided read.** Buy three west lots and one east: legal, expensive,
   and how it looks from the arena is a product question nobody has seen
   answered.
5. **The ring at radius ~750.** Ten maxed-pitch plots put the walk from the
   arena rim at up to 880 studs. It is inside the (grown) baseplate and the
   sign distances were raised to match; whether it is bearable on foot is
   #101's whole reason to exist.
6. **The land pedestals at (±16, 30).** The floor-furniture pair checks pass;
   whether two pedestals in the open middle read as "buy ground here" is a
   Studio question.

## 3. Mock claims this round leans on

- `Config`'s land helpers are pure arithmetic, so `land_spec` runs the real
  functions. land_spec's centre-span pin caught a real defect before the
  round ended: the first wall split sat on the raw ground joint instead of
  the wall's inset edge.
- What the harness cannot claim: CFrame arithmetic, so `ensureLand`,
  `buildSlab`, `gateLeafSpecs` and every builder stay Studio-only, as the
  shell's builders always have.

## 4. Seams left deliberately open

- **A land strip delivers ground and walls only.** Machines, sub-belts and
  the one-upgrade-per-dropper rule are #109; the strips arrive empty and the
  flat-run guard tolerates the land rungs because they interleave with income
  rungs on the simulated curve.
- **#124 keys wall damage by course names.** buildWallRing's span split at
  land boundaries is the panel seam: each expansion's frontage is its own
  solid span, so a panel id can name an expansion.
- **The world did not grow with the ring.** BaseplateSize covers it, but the
  arena, leash and wave arithmetic still describe the old distances — #89
  owns the real world, and the walk-limit note names it.
