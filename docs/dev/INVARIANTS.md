# Tung Tung Tycoon — Invariants

**This is the live contract.** It is the deduplicated, current landmine list: what you must
not break, grouped by subsystem, with the thing that enforces it named on every line.

It **supersedes, for current truth, the §-sections that used to carry this list**:
`HANDOFF.md` §5, `HANDOFF_v2.md` §5, `HANDOFF_v3.md` §2, `HANDOFF_v4.md` §2,
`HANDOFF_v5.md` §2, and `HANDOFF_v6.md` §2 and §G2. Reading six documents in reverse
order to resolve supersessions by hand was the largest token tax in the repo; this file
is the answer to it.

**The handoffs remain the historical record** and are still the place to go for *why a
round decided something*, what it measured, and what it left open. Nothing here replaces
their §1 (what changed), §4 (what is open) or §5/§G5 (what only Studio can tell you).
Two v1 entries are deliberately not carried forward because the geometry they were about
no longer exists — the 72-tile ring path and its "derive tile size from spacing" rule
were deleted as decoration.

### The enforcement marker is the point of this file

`HANDOFF_v6.md` §6: *"an invariant in a document is not enforcement, and the gap between
the two is where #35 lived for two rounds."* So every entry names what would fail:

| marker | means |
| --- | --- |
| `[assert]` | a `check()` in `tools/verify_config.lua` — runs on every `verify.py` |
| `[lint]` | a pass in `tools/verify.py` over the source text |
| `[spec]` | a runtime spec in `tools/testing/specs/`, executed by `tools/test.py` |
| `[runtime]` | a Lua `assert` in `src/` — real, but only when the game actually runs (several are `RunService:IsStudio()`-gated) |
| `[nothing]` | documented only. **These are §10, and they are the backlog.** |

**The rule for adding to this file: if you add an invariant here and nothing enforces it,
you add it to §10 in the same edit.** A wrong `[assert]` is worse than an honest
`[nothing]`, because "reads as checked and is not" is the failure this project keeps
having — four instances in one round (the generator, the `PathTopY` dead key, two vault
assertions that could not fail, and a harness API nothing assigned). Verify the marker by
grepping the tool, not by remembering.

---

## 1. Persistence & saves

- **One server at a time may write a profile, and the lock lives INSIDE the profile
  record.** Roblox has no cross-key transaction, so the only way to make "only the holder
  may write" atomic is for the check and the write to be the same `UpdateAsync` call.
  `[spec]` `lock_spec.lua` — 17 specs, mutation-tested against 15 deliberately broken
  `DataService` versions.
- **`DataService` refuses to save a profile whose load failed.** Better to lose a session
  than to overwrite a real save with a default one. Do not "fix" this. `[spec]`
  `lock_spec.lua` "a failed read still never writes".
- **The lock is `stored.__lock` and it never reaches the profile.** `reconcile()` iterates
  the keys of the fresh *default*, so an extra key in the stored blob is structurally
  invisible, and `save()` builds an explicit payload so it cannot leak back — which is why
  the lock needed no `PROFILE_VERSION` bump and no migration. `[spec]` `lock_spec.lua`
  "the lock never reaches the profile, and dead keys never accumulate".
- **The `UpdateAsync` transform can run more than once.** Assign the outcome, never
  accumulate it, and sample `os.time()` *inside* the transform rather than before the call.
  `[spec]` `lock_spec.lua` "a re-run transform produces exactly what a single run does",
  "the heartbeat is stamped inside the transform, not before the call".
- **`SERVER_ID` falls back to the stable string `"studio"`, not a random id**, so a Studio
  restart re-acquires its own leftover lock instead of waiting out the stale window —
  `BindToClose` early-returns in Studio, so nothing releases it. `[spec]` `lock_spec.lua`
  "a server walks back into its own lock, however old".
- **The five `Config.Persistence` numbers are a related system, not five dials.** The stale
  window must outlast a drain plus the whole acquire window or two servers write at once;
  the acquire window must outlast a soft shutdown or every teleport off a draining server
  kicks its players. `[assert]` "a lock goes stale in %ds but a full handover takes up to
  %ds", "a joining server gives up on a held lock after %ds".
- **A contended load can now take ~32 seconds**, against milliseconds before. Anything
  assuming a profile is present shortly after join is weaker than it looks; this already
  found one live bug in the admin commands. `[nothing]`
- **A new persisted field needs BOTH `DataService` edits** — the key in `defaultProfile()`
  *and* the key in the explicit `save()` payload. With only the first it defaults
  correctly, works all session, and is gone at next login; a field defaulting to `nil` is
  not even iterated by `pairs`, so default to `0`, `""` or `{}`. `[nothing]` as a general
  rule — individual fields are pinned (`firstBuySeconds` in `analytics_spec.lua`,
  `offlineCapLevel` in `offline_spec.lua`, `claimedPlaytime` in `playtime_spec.lua`).
- **A sparse numeric-keyed table does not round-trip through the DataStore.** JSON turns
  `{[3] = true}` into a string key, which silently re-opened the playtime ladder on every
  load; it is a `bit32` mask for that reason. `[spec]` `playtime_spec.lua` "a rejoin does
  not re-open a claimed rung, and the claim is on the save".
- **Never cache a pure function in the save.** `profile.unlocks` could only go stale, and
  had — it recorded `"mezzanine"` forever after the mezzanine became a buy button. `[nothing]`
- **`profile.batTier` is an INDEX, not an id.** Inserting a tier renumbers everything above
  it, so a save reading `3` quietly means a weaker bat — an in-range value no clamp can
  catch. `PROFILE_VERSION` and `LEGACY_BAT_TIERS` exist for exactly this, and the remap runs
  **before** the clamp. `[spec]` `lock_spec.lua` "the v1 batTier remap still fires through
  the locking load path".
- **Never rename a button id.** `reconcile` prunes `owned` ids it cannot find in Config, so
  a rename silently un-buys that purchase for every existing player. `batforge`/`batforge2`
  kept their ids through the whole track split for this reason. `[nothing]`
- **A weapon or armour button is the RECORD of a granted tier and must never disagree with
  the tier itself.** `grantBat` is monotonic, so a pre-split save would light rungs it
  already holds and charge 60,000 Tung for nothing; `reconcile` backfills ownership for any
  `Gear`/`Armor` button whose tier is already reached. `[nothing]`

## 2. Economy & pacing

Two standing facts that are not invariants but stop people reaching for the wrong lever:
**the belt does not carry income** — income is `Config.incomeRate` paid on a timer
(design:D-02), so belt speed, drop spawn rate and the visual budget are picture levers, and
raising any of them to fix crowding is free. And **build length, not `BaseCost`, is the
rebirth lever**: sweeping `BaseCost` across a 20× price cut moves the first rebirth about
twelve minutes, because `upgrader6` and `dropper10` multiply income ~17× between them.

- **`Config.incomeRate` is THE income model and its three readers are wrappers.**
  `Tycoon:incomePerSecond` adds the live multiplier stack, `SessionService.incomePerSecondFor`
  adds the saved rebirth term, the verifier's progression simulation reads it raw. A fourth
  copy of the arithmetic is the defect class behind #35. `[spec]` `income_spec.lua` pins both
  wrappers to the model.
- **One income loop per plot, and its liveness test is owner identity.**
  `Tycoon:startIncomeLoop` re-derives the rate from `owned` every tick and pays
  `rate × IncomeTickSeconds` through `Economy.add`; release nils the owner and kills it,
  rebirth keeps the owner so the same loop reads the wiped `owned` fresh, and `assign`
  refuses an owned plot so a second loop cannot start. `[spec]` `income_spec.lua` "release
  kills the loop; rebirth leaves it reading the wiped plot", and the tick spec fires on a
  double payment.
- **THE STORAGE CAP IS MINUTES, NOT A NUMBER** (#98): the unit holds `CapMinutes` of the
  plot's own income (rebirth term included), clamped at `Economy.add` — the one door money
  comes in through, so the tick, the offline grant and every session reward meet the same
  ceiling and nothing is a second bank. Earnings above it are LOST; the offline grant is
  deliberately not exempt. A broken unit collapses to `BrokenCapFloor`, which is what gives
  the repair loop stakes. `[assert]` KPI 1 at every step of the simulated buy order (the
  cap never blocks the climb), the CapMinutes bind bounds, and the floors; `[spec]` the
  clamp, the broken collapse, and the grant clip — each falsified. KPI 3 (raid exposure) is
  #94's, measured against this same number.
- **`IncomeTickSeconds` sits between Economy's 0.1 s replication drain and 5 s.** Under the
  drain the coalescer batches nothing; past 5 s the counter reads as stuck. `[assert]`

- **`StartingCash` must cover the cheapest requirement-free button.** With no dropper there
  is no income, so a fresh player could never buy their first one and the tycoon deadlocks.
  `[assert]` "StartingCash (%d) cannot afford the first factory button".
- **...and no side track's first rung may be affordable at spawn**, or a new player buys a
  bat instead of a dropper and strands themselves. `[assert]` "a new player could buy it
  instead of their first dropper and strand themselves".
- **THE ARC IS A WEEK, AND THE WEEK IS WALKED** (#90): sittings of 30 minutes, offline
  gaps paying the mirror's discounted rate through the storage cap's door, the rebirth pad
  taken when it is the cheapest move that still leaves a climb. The bands: frontier on day
  5–9, two or three rebirths, the first on day 2–3, and no purchase taking more than two
  sittings of pure saving — the "never a wall inside a sitting" rule with the multiplier
  the player actually has. `[assert]`, each falsified.
- **One life still has a FLOOR**: at least 60 minutes of rebirth-zero grind, or there is no
  week in the ladder. Its old ceilings are gone on purpose — the tail is post-rebirth
  content, sized for multiplied income, and "too grindy at rebirth zero" is the design
  working. `[assert]`
- **The 60-minute credit cap binds each day's sitting**, a platform fact (Roblox credits at
  most 60 minutes per user per day); the week models 30-minute sittings and asserts they
  fit. `[assert]`
- **At the moment the pad is first affordable, at least two rungs remain unbought** so the
  session ends on a choice rather than on being finished. `[assert]`
- **`Config.Rebirth.BaseCost` is DERIVED and must not be hand-set again.** `Config` assigns
  it from `Config.rebirthBaseCost()` once the spine exists (`PriceRung` = the 4th most
  expensive spine price), which is what guarantees rungs above it are still unbought when
  the pad lights. `[assert]` bounds the result: "the rebirth pad costs %.3g, less than the
  eighth-most-expensive spine rung".
- **Rebirth payout compounds** (`MultiplierPerRebirth ^ rebirths`). A linear bonus against a
  geometric cost curve dead-ends the prestige loop after two or three. `[assert]`
  "MultiplierPerRebirth must be > 1" plus the rebirth cost-ratio check.
- **The live plot pays PER COLLECTED TUNG** (design:D-02, via #180): a drop stamps its
  dropper's raw value at spawn and `onCollect` pays it through `Config.dropPayout` — every
  owned upgrader times the generator, the FULL stack whichever side's arches it crossed —
  and the live multiplier stack. `Config.incomeRate` stays the quote, the offline mirror
  and the pacing model, because it is the drops' long-run average, and a spec pins the
  identity: payout over rate summed across owned droppers equals the rate exactly. Live
  pay is lumpy (one transit late) and LOSSY on purpose — a launched, jammed, capped or
  reaped tung is income that never arrives, which is what makes the belt fixes and the
  drop budget load-bearing for the economy. `[spec]` `income_spec.lua`: the payout, the
  once-only Collected claim, the owner guard, and the identity.
- **`self.powerFactor` must be ASSIGNED, from `Config.powerFactor(owns)` — derived, never
  accumulated.** This is #35: the field was initialised to 1, reset to 1, and assigned
  nowhere, so the belt and every dropper ran at stock speed for two rounds while the HUD
  quoted the full multiplier. `assign()` replays a save by installing every owned rung in
  `order`, so a `*=` lands on `1.19 × 1.42 × 1.68 × 2.00 = 5.67`. `[spec]`
  `generator_spec.lua` (5 specs) and `[runtime]` `Tycoon:refreshBeltSpeed` recomputes from
  `owned` in Studio and fires on 37, 56 and 78.1 alike.
- **Three things read the power factor and they reach it by two different routes.**
  `incomePerSecond` calls `Config.powerFactor(has)` directly; `refreshBeltSpeed` and
  `dropInterval` read the cached field. That asymmetry is exactly why #35 was invisible, so
  if you touch either route check both still agree. `[spec]` `generator_spec.lua` "the
  plot's quoted income and its production agree about power".
- **Never write `def.dropRate`.** `Config.ButtonById` tables are shared by every plot on the
  server; `Tycoon:dropInterval` divides at read time, which also means a generator bought
  mid-run is picked up on every dropper's next drop with no loop restart. `[spec]`
  `generator_spec.lua` "power1 divides the drop interval by its factor" (a mutation
  compounds and the spec fires) — but nothing checks the general rule.
- **Power does not survive a rebirth, and that is deliberate.** It multiplies exactly what a
  rebirth resets, so keeping it would stack ×2 on `MultiplierPerRebirth` 2.25 for an
  effective 4.5× first prestige and make the asserted cost ratio a lie about real pacing.
  `[nothing]` — only `TrackInfo.factory.keepOnRebirth == false` is asserted; power's row is
  checked for presence, not value.
- **A side track is paced by PRICE alone, so it is measured as detour**: minutes of your
  current income a tier costs, capped at 4 per tier and 35% of the build in total. `[assert]`
  "that is a wall, not a detour".
- **A cabinet must not open with most of its rungs already affordable.** A ladder you can
  empty in one pass is a vending machine, not a track — which is what a minute-41 floor gate
  produced (4 of 5 rungs affordable on opening). `[assert]`
- **The offline cap ladder is monotonic in both hours and price, and a full vault is worth at
  least two hours of live play**, or the exit hook is a lie told in gold. `[assert]`
  "Offline cap tier %d does not extend the one before it", "a full offline vault is worth
  %.1f hours of live play".
- **The Vault Timer rungs and the playtime rungs are priced against the factory curve**, not
  in the abstract — the same detour model the cabinets use. `[assert]`
- **The boost must be shorter than its cooldown, must pay more than not pressing it, and the
  weekend must pay more than a Tuesday.** `[assert]` plus `[spec]` `boost_spec.lua`,
  `weekend_spec.lua` (a boost on a Saturday is ×4, not ×3).
- **A full friend bonus must not out-earn a prestige**, or the cheapest route to the top of
  the curve is a group chat. `[assert]` "the social lever must not out-earn a prestige".

## 3. The plot and its geometry

### World & plot placement

- **Every horizontal surface needs its own Y.** Coplanar faces tear as the camera moves. The
  check iterates `World` key *names* — it used to be a literal map containing
  `PathTopY = Config.World.PathTopY`, a key that does not exist, so the entry was `nil`,
  `pairs()` never visited it, and the check covered three surfaces while appearing to cover
  four (with `YardTopY` missing beside it). `[assert]` "World.%s and World.%s are both at
  y=%s — coplanar faces will z-fight".
- **Plot-local `y = 0` is the top of the pad, not the ground**, and the pad must sit above
  the ground plane. `[assert]` "plot pads must sit above the ground plane".
- **The plot belt sits at ONE fixed radius — `Config.beltRadius()` — for every player
  count** (#89): the full server's chord (`2r·sin(π/MaxPlots)`, not the arc) fits the maxed
  footprint plus the gap, and a smaller server spreads on the same circle instead of
  contracting inward — the mob bands, the spawn and every plot-safety line are static
  distances that a shrinking belt would walk homes into. `MaxPlots` is the radius's
  dominant term: 8 seats puts the belt at ~585, and every seat past that costs every
  player a longer world. The spawn stands BEYOND the belt at a mid-gap bearing, laterally
  clear of every plot at every count. `[assert]` every placement equals the belt, the
  pairwise spacing, and the spawn's ring and lateral clearances.
- **`Players.MaxPlayers` is not scriptable.** The plot count follows it and nothing in code
  can set it — it is a Studio setting and it is on you. `[assert]` covers the derivation
  (`plotCountFor` clamps to `MinPlots`/`MaxPlots` and tracks `MaxPlayers` in range), not the
  setting.
- **`Lighting.Technology` is not script-writable at runtime.** It is set in the Rojo project
  file and the runtime assignment is wrapped in `pcall` so a paste-in install does not die
  on boot. `[nothing]`
- **THE PLOT IS OPEN-AIR: the world lights it, and the torches warm it** (#162). The roof,
  the ceiling batten grid and `Fx.ceilingLight` are gone with the roof purchase; the plot's
  own light is the wall torches — a shadowless `PointLight` per flame (`Fx.torchLight`),
  with `Range` held under Roblox's silent clamp at 60 and `brightness` positive. A torch
  bracket hangs ABOVE the machine line, so the plan clearances between the wall and the
  machine rows stay the machines' own. `[assert]` all three; how it reads at night is
  Studio's. `[nothing]` for the look.

### The belt

- **Nothing collidable may sit near the belt except the running surface.** Drops are driven
  by a `LinearVelocity` in Plane mode, which pins lateral velocity to zero, so they cannot
  drift off and rails were never load-bearing. End cap, turn trigger, dropper arm, spout,
  nozzle, upgrader beam and both guard rails are all `CanCollide = false`. `[nothing]`
- **A GUARD RAIL IS A RUN ON ONE LEG, SET BACK FROM BOTH OF THAT LEG'S ENDS.** The rails
  that shipped once ran each leg's FULL length, and every leg's surface deliberately
  overruns its bend by half a belt width — so leg 2's inboard rail crossed leg 1's path and
  vice versa: two solid walls across the conveyor plus an 11x11 block on the bend, which is
  what the drops were piling up against. `Layout.BeltGuard.corner` is the whole of the fix.
  `[assert]` a leg's rail box may not overlap any OTHER leg's running surface, corner
  overrun included; setting `corner` to 0 reproduces the original defect verbatim.
- **`Config.beltHalfWidth()` is the only statement of how far the belt reaches.** It was
  `width + 1.2` in `Belt.lua` and a mirrored `BELT_BASE_PROUD = 1.2` in the verifier, and
  the two agreeing was luck — that coupling once put a guard 0.1 studs inside the belt base
  while every check reported a stud of daylight. It carries the
  rails too, so every clearance check measures the real object. `[assert]`
- **Overhead parts need real headroom over the tallest variant standing on the belt**
  (infinity, 2.23 studs; current minimum clearance 0.7). `[nothing]`
- **Machines must be spaced at least their own footprint apart along a leg**, and every
  slot's distance must land on its leg. `[assert]` "%s[%d] is only %.1f studs from its
  neighbour; machines are %.1f deep and would overlap".
- **You step over a buy button, you do not jump onto it** — `ButtonHeight` ≤ 2 and
  `BeltY` ≤ 2.5. `[assert]`
- **A trigger on the belt has to survive a 30 Hz physics step.** Roblox demotes an unattended
  assembly to 30 Hz and an unattended plot is the common case on a ten-player server, so
  `TriggerThickness / maxBeltSpeed >= 2 × (1/30)` — and `maxBeltSpeed` includes the
  generator's top factor. Anything that raises belt speed or lowers trigger thickness has to
  look at this number. `[assert]` "a drop crosses a %.1f-stud trigger in %.0f ms".
- **The upgrader's visible plate and its trigger are different parts.** `Scanner` is 1 stud
  with `CanTouch = false`; `ScanTrigger` is 5 studs, invisible, and carries the `Touched` —
  an invisible catcher behind a visible face. `[nothing]`
- **`MACHINE_MASSES` is shared with `buildGhost`, and masses named `*Trigger` are filtered
  out of ghosts.** This is the ONE exception to "the ghost is built from the same
  description as the real machine", and it is named rather than being a quiet special case.
  `[nothing]`
- **A corner sensor is widened downstream, so its leading face stays put.** An early trigger
  is harmless at an upgrader or a collector; at a corner it cuts the corner. `[nothing]`
- **The belt has to physically fit the drops it carries**: ≤75% occupancy per belt, and total
  drops in flight summed across *every* floor within `MaxDropsPerPlot`, because `spawnDrop`'s
  counter is per plot. Drops carry the money (#180), so the cost of a violation stopped
  being the picture: over occupancy the line jams, and over the budget spawnDrop refuses —
  income that never arrives. `[assert]` "the plot carries %.0f drops at
  peak across %d belts".
- **A dropper cannot be sped past 0.2 s even at top power**, or it floods physics. `[assert]`
- **A belt path is a polyline that states its own height and carries one outboard side per
  leg.** "Take the perpendicular pointing away from the plot origin" holds only while every
  leg hugs an outer edge and inverts for a leg whose midpoint sits near the centre — which is
  exactly what an upper floor's return leg does. `[assert]` "BeltPaths.%s leg %d has outboard
  %s; it must be 1 or -1", "BeltPaths.%s has no y; a path that does not state its height gets
  built at 0"; `[runtime]` "a belt path needs at least two points".
- **`PivotTo` overwrites the PrimaryPart's rotation.** Bake the upright orientation into the
  target CFrame or every drop spawns lying on its side. `[nothing]`

### The vault

- **The vault must sit downstream of the collector sensor.** A solid body overlapping the
  run-off walls the belt off and nothing can ever be collected. `[runtime]`
  `Tycoon:buildCollector` "Collector body overlaps the belt run-off on path %q"; `[assert]`
  the config half — the collector clears the belt end by 8 studs and the shell still fits
  behind the front wall.
- **The vault's furniture is the most crowded six studs on the plot, and all of it is in
  `Layout.Vault`.** The fill gauge is bounded by the body's DEPTH (it lies on a lateral face
  of an 18×10 box, so the pane's horizontal extent is 10, not 18), must straddle its face
  rather than float off or sink behind it, the detail board must clear the headline board,
  and the statue stands on the sign rather than in front of the number. Two of these
  assertions originally could not fail — one measured the wrong axis, the other had an
  unsatisfiable bound. `[assert]`

### Land (#88)

- **Land ownership is a prefix of each side's chain, and everything derives from it.**
  `Config.landCounts(owned)` is the whole state; `Tycoon:landState()` re-derives it on
  every call and caches nothing (#35's rule). `[spec]` `land_spec.lua`.
- **ensureLand runs on the refreshButtons beat and reconciles the world to `owned`.**
  Purchase, release, rebirth and re-claim all reach that beat, which is why land has no
  service and no listener — the FloorService it replaces existed to catch exactly those
  four events. `[nothing]` for the beat wiring itself; the derivations it applies are
  asserted below.
- **The ring re-emits courses and never touches a leaf.** rebuildWallRing destroys
  everything in the ring except `Gate_*` parts and re-emits from `Config.wallSegments` at
  the current land state. Safe because openings cannot move: every opening lives on the
  CENTRE span, `[assert]` per land state ("an opening on an expansion span is an opening a
  land purchase would rebuild"), and the centre's spans are byte-identical at every land
  state, `[spec]` `land_spec.lua` — the spec that caught the split sitting on the raw
  ground joint instead of the wall's inset edge.
- **The strips tile outward with no gap, mirror by pair, and shrink outward.** `[assert]`
  the land data family; `[spec]` `land_spec.lua`.
- **The alternation is pricing, and the simulation demonstrates it.** Within a pair the
  east lot costs a shade more than the west; between pairs the step is 3x plus; and the
  greedy simulation's land purchases are asserted to run L1 R1 L2 R2... A lopsided base
  stays legal and expensive. `[assert]`
- **The shell's cost follows the land.** The front and back walls split a run per owned
  boundary, so `shellPartCount(left, right)` is asserted against `PartBudget` at all eleven
  alternating states plus a lopsided pair — fully grown is where the budget binds, and the
  verifier's `shell parts:` report line is the number to read. `[assert]`
- **The ring pitch reserves the MAXED footprint.** Land is acquired rather than reserved,
  so two fully-grown neighbours are the case the world must hold; the pairwise chord check
  needs `PlotMaxWidth`, the walk limit is 880 with #89/#101 named as the owners of the
  real answer, and the plot/world sign distances follow the packing. `[assert]`
- **Land survives rebirth; the machines standing on it reset** (design:D-03 — rebirth
  raises the ceiling and the ground is the ceiling; a surviving refiner would multiply the
  next build from minute zero, the generator's argument one track over).
  `Config.keptOnRebirth` is the ONE derivation both of rebirth's polarities read, carrying
  the land carve-out by kind. `[assert]` the track flag; `[spec]` `land_spec.lua` the
  carve-out, falsified by removing it.
- **A strip's sub-belt is registered at construction and BUILT with the strip** (#109). The
  path is data in `Config.BeltPaths` so the occupancy, dwell and budget checks see all
  eleven; the surfaces and plain collector live in the strip's own model so teardown takes
  the conveyor with it. Machine rows pin to the strip whose land row precedes them on the
  chain — `[assert]`, falsified by mis-pinning one to the neighbouring strip.

### Siege (#124)

- **Authority is `tycoon.structureHealth`; the parts are a picture.** Keys are
  `wall_<side>` and `gate_<opening>` — stable across every land state while course names
  shift, which is what lets a dent persist without a rename forgiving it. Assigned from
  `Config.wallMaxHealth`/`gateMaxHealth` (level = expansions + 1), never accumulated.
  `[spec]` `siege_spec.lua`.
- **applySiegeState runs at the end of every buildWallRing.** The refreshButtons beat
  rebuilds the ring, and without this call every beat would resurrect a wall the raiders
  earned. A broken wall keeps its sill course as the charred stump the repair prompt
  stands on; a broken gate loses its leaves, which `GateService.resolve` already
  nil-skips. `[nothing]` for the wiring; `[spec]` for the state machine it applies.
- **A broken defence absorbs nothing, and the return value says so.** #94 counts wasted
  swings by it. `[spec]` falsified by removing the guard.
- **Damage comes through one door, `Tycoon.siegeStrike`,** wired to CombatService's
  structure observer from `Main.server` — registering inside CombatService would put a
  require of `Tycoon` into a module `Tycoon` requires. One hit per key per swing, with the
  dedup table owned by the CALLER because a swing strikes twice; the plot's own owner is
  refused; no PvP-zone rule exists to consult since #89; the player-protection
  damage caps do not apply to structures. `[spec]` the dedup and the immunity.
- **Dents persist as FRACTIONS of full health,** in `profile.structure`, both
  `defaultProfile()` and the save payload — so the same dent survives the max moving when
  the plot buys land. `[spec]` the round trip, falsified by dropping the payload field.
- **The health numbers are held to their states**, on two axes now (#162): monotone in
  land level AND in masonry tier, the wall out-lasting its own gate over the whole
  level x tier grid, no bat one-shotting a level-1 wooden gate, every bat breaking a
  maxed stone gate inside 90 seconds (the check that bounds `GatePerTier` at ~96), the
  repair hold inside `Waves.WarningTime`. The siren-vs-breach model stays tier 0: the
  wooden gate is the fastest breach, so covering it covers every tier. `[assert]`, each
  falsified.
- **`siegeMaxHealth` reads BOTH axes** — `siegeLevel()` from the land and
  `masonryTiers()` from the owned tiers — and dents persist as fractions, so a standing
  dent scales onto the new max when either axis moves. `[spec]` `siege_spec.lua`.
- **Mob siege is live** (#89): a plot wave's slotted raiders press the gate through
  `damageStructure` and the storage through `damageStorage`, at `MobDamageScale` (half a
  player's weight — the breach floors are asserted against it). The old entry here said
  this path was dark; the reminder did its job.

### The building shell

- **A wall accounts for its whole extent, and `Config.wallSegments` is what says so.** The
  walls were five boxes emitted at a local literal `h = 13` under a roof whose underside was
  20, so every plot had a **seven-stud open band all the way round** and not one of the 2309
  checks looked at wall height. The builder now emits exactly the spans that function returns.
  `[assert]` "a wall that does not account for its whole extent is exactly the seven-stud band
  of daylight that shipped round every plot"; `[spec]` `structure_spec.lua`.
- **`Config.Structure.WallHeight` is the one structural line.** The wall's top, the trim
  line and the buy-button label ceiling all derive from it; it keeps the shipped 20.4
  verbatim from the storey system it replaced (#88). `[assert]`, `[spec]`.
- **A solid run is three courses — sill, body, head — and the split is siege machinery,
  not decoration** (#162). The sill survives a break as the repair stump; `Body`, `Head`,
  `Lintel` and `Buttress` are the breakable prefixes. `Config.Structure.Course` holds the
  split lines, and the head course keeps at least 2 studs. `[assert]` the course fit;
  `[spec]` `structure_spec.lua` and `siege_spec.lua`'s name-to-key table.
- **The buttresses are CORNER-ANCHORED and break the parapet line** (#162). A post at
  each end of every wall's extent — the ring's corners — with the span between divided
  at the pitch nearest `Buttress.spacing`, and any post landing in an opening (plus
  jamb) dropped: the gateway gets flanked, and the yard door, cut flush to the back
  wall's end, swallows that corner's post. Height sits in
  `(WallHeight, WallHeight + overshoot]` — over the wall is the castle read, and the
  band is what keeps "slightly taller" slight. `[assert]` the anchors by value, every
  post in-extent and out of openings, the height band; `[spec]` the part-count model
  re-derives the counts from the same arithmetic as a second opinion.
- **Every torch bracket stands INSIDE a solid run, clearance intact** (#162), placed
  by `torchPositions` walking `wallSegments` per solid run. `[assert]` per side, per
  post, counted.
- **A torch rides its wall down.** Torches carry no siege key — dressing, never targets —
  so `applySiegeState` has an explicit branch parsing a torch's side from its name and
  destroying it when `wall_<side>` is broken; repair rebuilds the ring and the torches
  with it. `[spec]` `siege_spec.lua`. The buttresses need no branch: `Buttress` is a
  breakable prefix, so a swing on a post lands on its wall and a break fells it.
- **The gate-trap inequality reads the ring's NEAREST point to the arena, which is a
  buttress face** — `WallThickness / 2 + Buttress.proud` past the plot edge. `[assert]`
- **A gate leaf hangs on the face `opening.face` names, and that is not cosmetic.** The yard
  door is flush to the end of the back wall, so its single leaf can only slide inward along
  x — and the inside of the back wall IS the dropper row. An inboard leaf swept 0.1 studs
  **through dropper slot 1** on the shipped numbers. It hangs outboard, over the yard's own
  slab. `[assert]` "an inboard leaf sweeps %.2f..%.2f studs off the %s wall's centre plane, and
  the machine row on belt leg %d starts %.2f studs off it".
- **A lone leaf slides toward the LONGER adjacent run**, and the run it slides into must be at
  least one leaf long or it travels out past the end of the building. Do not assert "both
  neighbours" — the yard door has a run on one side only. `[assert]`, `[spec]`.
- **Gates are driven by a distance test on a fixed tick, never by `Touched`/`TouchEnded`.** One
  server-wide loop over claimed plots, one test per opening. A character resting on a trigger
  bounces off its own physics jitter, which is what cost the deleted teleport pads a cooldown,
  an arrival lock and a `TouchEnded` sweep. `[nothing]` — `GateService` is outside
  `SERVER_MODULES`.
- **`Config.shellPartCount` must count what the BUILDER emits, not what the wall spec
  implies.** Its first version left out per-side parts and asserted the budget 13% under
  the truth — 59 against 68 actually built. Trim is a Config key for that reason rather
  than derived in the builder. `[assert]` against `Structure.PartBudget`, printed in the
  report; `[spec]` against an independent model.
- **A gate answers to its OWNER's proximity, nobody else's** (#89). Any-humanoid triggering
  would hand a PvP raider a free entrance (gutting #124's break-in verb) and open your
  door for the plot wave standing at it; NPCs never open anything — `GateService` sweeps
  `Players` only. A plot-wave raider shut inside is not trapped wrongly: it was let in or
  it broke in, and its leash is sized to the plot. `[nothing]` beyond the sweep's shape.

### The yard

- **`Yard.Slots`, `FirstX` and `Spacing` do not exist, and a `Power` button must carry no
  `slot`.** A per-rung slot is how the yard grew four generators and four buy pads on a plot
  that had bought none of them. `[assert]` "%s carries a yard slot".
- **The four power rungs stand on ONE pedestal position, and `TrackInfo.power.preview = 0` is
  what makes that safe.** At 1 a dimmed preview pad is built *inside* the lit one; at 2 you
  get the three-pad yard back. `[assert]`
- **The yard is behind the plot, not on it, and is off-centre — so width alone no longer says
  it fits.** A 28-stud slab is narrower than the plot and can still hang over its edge,
  eating the ring gap the packing checks solved for without changing `Size.X`. `[assert]`
  front face behind the plot's back edge, span inside the plot's width, plus yard-to-yard
  corner clearance and ground-plane containment at every player count.
- **The doorway is checked as a SPAN, not a point.** A 28-stud corner chunk can sit entirely
  clear of the door it is reached through and you would step out of the back wall onto grass;
  the old 108-stud yard could not miss. `[assert]` "you would step out of the back wall onto
  grass".
- **The yard's door can only be in the back-right corner.** The back edge carries the
  upgrader rows and the vault (#162), and the span past the east back leg's corner is the
  one stretch of back wall with no machine behind it. `DoorFrom` is still 46 and the wall
  spec is unchanged — the yard moved to the door, not the door to the yard. `[assert]` for
  the position (the door must not open onto a machine, and must be ≥8 studs wide).
- **The door is cut at wall-build time, not at generator-purchase time**, or anyone who buys
  walls first is sealed out permanently. `[nothing]`
- **The yard is not in `Layout.Tracks`.** That table is things standing on the plot floor:
  the verifier runs `inPlot` over every slot of every entry and `ensureCabinets` builds a
  display case for each. `[assert]` by consequence — a yard added there fails `inPlot`,
  because the yard is deliberately outside the plot.
- **`ensureYard` is idempotent and re-run from `refreshButtons`**, exactly like
  `ensureCabinets`, because `release()` does `props:ClearAllChildren()`. The old
  `buildYard()` ran once from the constructor, so the first owner to leave took the slab with
  them for the rest of the server's life and every later owner bought generators that stood
  in mid-air. `[nothing]`
- **The generator is derived from `owned`, not built by the installer, and must not be
  written to `self.objects[id].machine`** — four button entries would share one model handle
  and `release()` destroys through one of them. `[nothing]`

### Walls, pads and floor furniture

- **Everything placed by absolute plot-local coordinate is checked inside the plot**, buy
  buttons included. `[assert]`
- **Floor furniture is checked against every other piece, against the rebirth/claim/spawn
  pads, and against both belt buy-button rows** in one list. Overlapping pedestals shipped
  once and stayed invisible only because the unlock chain hid one before the other
  appeared. The side-track columns left the list with the cabinets (#108). `[assert]`
- **The front gateway opens onto the aisle the owner spawns on**, is at least 12 studs wide,
  and stays clear of the belt/vault side of the plot. `[assert]`
- **Non-square pads need both halves.** The pad's edge strips were positioned at
  `PlotSize.X / 2` on all four sides, so on a 120×140 pad the front and back strips floated
  8 studs inside the border they were meant to draw. `[nothing]`
- **`Highlight` is capped at 255 per client and disabled instances still occupy a slot.**
  Delete them, do not disable them. There is one per plot, reparented. `[nothing]`
- **A per-plot `SpawnLocation` joins the random-spawn pool** and would send other players to
  your factory. Respawn placement is a reposition on `CharacterAdded` instead. `[nothing]`
- **`FindFirstChild` is not recursive.** The plot totem silently never updated for this
  reason. `[nothing]`

## 4. Buttons & tracks

- **A track is a CHAIN: exactly one requirement-free root.** Zero roots means a cycle, two
  means the ladder forked and the buy-button frontier lights both branches at once.
  `[assert]` "the %s track has %d requirement-free roots".
- **No factory button carries an explicit `requires`; the loader derives the chain from table
  order, so table order IS dependency order.** Restating it is what once hid a fork that made
  the second storey a dead-end branch you could skip entirely. The root count cannot see a
  fork *below* the root. `[nothing]` — moving a row is now the new way to get this wrong, and
  nothing refuses a hand-typed `requires`.
- **Prices climb within a track, requirements point at earlier indices, and no requirement
  crosses a track.** A weapons tier costing less than the dropper beside it is the whole
  point of the split; one stray cross-track link re-couples the chain and nothing else in the
  game notices — the button simply never lights up. `[assert]`
- **Merging the track tables factory-first is load-bearing.** It leaves every factory button
  with the `order` it had, which is what lets `Tycoon:assign` replay installs by sorting on
  `order`. `[assert]` "TrackOrder no longer starts with the factory".
- **`Config.TrackInfo` is the only place a per-track fact lives, and every row must be
  complete.** They used to be spread across five tables in three files with one duplicated; a
  missing row fails differently in each and none fail loudly — the rebirth one **fails open**.
  `[assert]` "track %q has no TrackInfo entry".
- **`Config.TrackRank` is derived from `TrackOrder`.** There were two hand-maintained copies,
  one in `Tycoon` and one in `HUD`, with a comment warning they had to match. `[assert]`
  "TrackRank disagrees with TrackOrder for %q".
- **A track-level gate is not a `requires`.** `Config.TrackUnlock` is a separate concept: it
  cannot name a button on its own track (that is a chain link), must name a button on a
  **spine** track (a detour gating a ladder can deadlock it, because nothing guarantees a
  detour is ever taken), and the factory itself cannot be gated. `[assert]` four checks. The
  middle rule read "must name a *factory* button" until the shell became a second spine
  track — "factory" was the only vocabulary that property had while the factory was the only
  ladder everyone walks, and the old form refused a perfectly safe gate on `walls` with a
  message calling structure a side track.
- **The per-purchase gate is GONE** (#125). `Config.ButtonUnlock` and `buttonUnlocked`
  shipped one entry ever — the mezzanine waiting on the roof — and retired with the storey
  system; a mechanism nothing uses is a mechanism that silently rots. The next cross-ladder
  precondition re-earns the machinery with its own reason. The fixpoint below stays.
- **The purchase surface is THREE CATEGORIES over seven chains** (#125): conveyor,
  generator, plot, with the cabinets labelled their own way until #108 moves them off the
  plot. `TrackInfo.category` is the field; pads and the HUD card count by
  `categoryOrder`/`CategoryCount`, and the conveyor sits at rank 1 — which is what "its
  label sits highest" means to a card and a beacon that rank by (TrackRank, price).
  `[assert]` category names, coverage and rank; `[spec]` the ordinals tile each category.
- **Reachability must count the GATES, not just the chains.** `[assert]` a fixpoint from an
  empty save over `requires` ∪ `TrackUnlock`. It was built when a per-purchase gate could
  close a loop the naive walk missed; that mechanism is gone (#125) and the fixpoint stays,
  because it is the only check that would notice the NEXT gate shape closing a loop.
- **The cabinet gate is STICKY and derived**: owning any rung of a track counts as having it
  open. Rebirth wipes the factory — and so the gate button — while keeping weapons and
  armour, so without that clause your first rebirth deletes both cabinets and leaves the
  shelf displays and the granted bat standing. `[nothing]`
- **The cabinet gate is `dropper3`.** It was the second storey's button for two rounds and
  that was only ever a proxy for where the cases stood. `[assert]` the gate opens inside the
  opening minutes.
- **A cabinet column is not a misc column, and `Layout.CabinetSlotSpacing` says so.** One
  constant policed both, which is one constant doing two jobs: the misc column is five
  unrelated purchases in a line down an open floor, and a cabinet column is nine pads that
  are deliberately one object in front of one case. The pair check takes the STRICTER of the
  two. `[assert]`
- **No row may restate the chain the loader derives.** The oldest `[nothing]` in this file,
  and it had a shipped defect behind it: every row used to restate its own requirement, and
  the restating hid a fork that made the second storey a branch you could skip entirely. Now
  `[assert]` — the chain must be exactly the table order, checked as "requires equals the row
  above" because the loader has filled the field in by the time the verifier runs.
- **THE SHELL IS SIX PURCHASES ON A TRACK OF ITS OWN, IN ONE ORDER.**
  `walls` -> `gates` -> the four masonry tiers, gated as a whole on `dropper1` (#162 took
  `windows` and `roof` off the ladder; old saves shed the ids through
  `DataService.reconcile`'s prune). The ordering is derived from table order and nothing
  else stated it. The wall arrives SOLID and stays opaque for life, because a purchase
  called "Plot Walls" that does not keep a raider out is not walls. `[assert]` the order —
  gates hang on the ring, each tier needs the one below it — and that every declared gate
  leaf is paid for by a `gates` button. The order check scans `Config.Buttons` on the
  GLOBAL `order` key rather than one track's `trackOrder`, so it survives the shell moving
  again.
- **A masonry tier is a RESTYLE of the standing ring, and the part count must not move.**
  `applyMasonry` walks the courses, lintels and buttresses setting Material/Color from
  `Config.Structure.Tiers` — the glazing mechanism generalised — and the trim, torches
  and gate leaves keep their timber. The Tiers list and the tier buttons must name the
  same structures in purchase order, because `masonryTiers` counts the list against
  `owned`. `[assert]` both directions and the order; `[spec]` the restyle adds no parts
  and touches only the wall's own prefixes.
- **The shell is PARALLEL to the factory, and that is the point of the track.** Its rows
  were rungs of the factory chain, which is a strict chain — purchases that drop, refine
  and multiply nothing sat on the one ladder the player measures themselves by.
  `MAX_FLAT_RUN` was written to guard that hazard rather than remove it. `[assert]` no
  `Structure` row remains on the factory track.
- **Land purchases RESET the flat-run guard** (#162). A land strip earns nothing when it
  is bought, but it is the ground its own dropper stands on one purchase later, and land
  pacing is owned by the alternation family and the week walk. Counting it made the
  guard's verdict depend on what sat beside the land rows in the merged curve: the
  back-to-back `landL5`/`landR5` pair reads as 67 flat minutes. `[assert]` — take `Land`
  out of `RESETS_FLAT_RUN` and that pair is what fires.
- **The shell and the land are paced as SPINE, not as detours.** The detour model prices a
  track against a curve it does not change and assumes you can decline it; the plot's own
  growth is neither. Measured as detours the build once read 46 minutes against a
  `MIN_TOTAL_MINUTES` of 45 — the purchases did not stop happening, the verifier just
  stopped counting them. `[assert]` via `paced`, which the spine simulation and
  `spinePricesDescending` both read instead of naming tracks by hand.
- **The shell does NOT survive a rebirth, and that is forced rather than chosen.**
  `rebirth()` clears `self.machines` unconditionally and the wall ring lives there, not in
  the `self.props` folder the `keepOnRebirth` exemption is about. Set it true and the ring is
  destroyed while `owned.walls` survives, so `refreshButtons` hides the pad for a building
  that is not standing and the plot has no shell for the rest of that owner's session.
  `[assert]` `keepOnRebirth == (furniture == "cabinet" or furniture == "land")` for every
  track — land survives because ensureLand rebuilds it from `owned` — which also retires
  the old `[nothing]` about only the factory's value being checked. A runtime spec runs the
  real rebirth and confirms the track's ids clear while a weapons tier survives.
- **`gates` ADDS to the ring that is standing; it never rebuilds it.** A rebuild would
  destroy the gate leaves `GateService` may be mid-tween on and re-emit dozens of parts
  that have not changed. The leaves live in the ring's own model, so a rebirth takes them
  down with the wall — and when a land purchase re-emits the ring's COURSES,
  `rebuildWallRing` spares every `Gate_*` part by name for the same reason. `[nothing]`
- **Every button must be reachable, every bat and armour tier must be granted by exactly one
  button, and armour tier 1 must grant nothing** (it is the bare humanoid you spawn as, which
  is what keeps the raider-damage assertions honest). `[assert]`
- **Adding content is a Config edit, never a `Tycoon.lua` edit.** A row in a track table plus
  a distance gets you the button, machine, drop loop, save key, unlock dependency and HUD
  hint; a new `kind` needs a `Tycoon.INSTALLERS` entry and a new visual variant a
  `Config.Variants` row. `[assert]` `KNOWN_KINDS` mirrors the installers, and an unknown
  variant or structure fails the build.
- **A buy button honours its own height.** `buttonBaseCF` is the single conversion —
  `buildButtons` used to build at `self:at(pos.X, 0, pos.Z)`, discarding a Y that
  `buttonPosition` had already worked out, and the conversion existed twice with both copies
  dropping it. That one zero once kept anything purchasable off the second storey.
  `[assert]` the config half (a path states its height; the ground floor runs at y=0);
  `[runtime]` the instance half — a Studio-only self-test in `buildButtons` comparing the
  built pad against `buttonPosition`.

## 5. Combat, waves & raider AI

- **Damage lands on the strike frame, not on the click.** `Combat.SwingStrikeAt` is the delay,
  input-to-damage latency is capped at 250 ms per bat, and the hitbox is sampled twice because
  one instantaneous box misses anyone a few frames early or late. `[assert]` plus `[runtime]`
  `SwingAnim.lua` asserts the pose table has exactly `Config.Combat.SwingSteps` entries.
- **Absolute damage caps must not be scaled by the boss multiplier.** `Waves.MaxDamage`
  carried the comment *"never let a raider 2-shot"* while the cap itself was multiplied by the
  boss multiplier, so a late boss hit for 61 and killed a full-health player in two swings.
  `[assert]` "two of those kill an unarmoured player".
- **The unarmoured player is the measuring stick, and must stay it.** Armour raises MaxHealth,
  so the damage checks read `Armor.Tiers[1].health` (asserted equal to `BaseHealth`). Do NOT
  repoint them at the armoured maximum — that silently weakens the promise. `[assert]`
- **Armour grants MaxHealth only.** Flat damage reduction is worse: the health bar renders a
  MaxHealth gain for free, the default `Health` script regenerates a percentage so regen
  scales along, and effective HP under both stats is `health / (1 - dr)` — two variables
  multiplying into the one assertion that guarantees a boss cannot burst you down. One
  monotone stat keeps that assertion one line of arithmetic. `[nothing]`
- **`WarningTime` is load-bearing and is not a pacing dial.** Since #89 the raid comes to
  YOUR plot, so the promise inverts: `WarningTime` plus the gate's minimum time-to-breach
  covers the run home from the world's centre at a sprint, across every reachable pairing
  of expansions and rebirths — and a bare plot's storage holds long enough to sprint back
  from the mid band. Shortening the warning, cheapening the gate or raising
  `MobDamageScale` all land on the same assertions. `[assert]`, each falsified.
- **Dead air is 20–45 s measured from your clear, and `Waves.Interval` is gone.** Waves are
  paced by `RestTime` from the previous clear, not by a wall clock — the old fixed timer let
  two or three waves legally coexist and announced one wave's leftovers as the next. The
  CLEARED banner must not still be up when the next warning replaces it. `[assert]`
- **`MaxWaveTime` is a deadlock breaker and must not be able to fire during the spawn drip it
  backstops.** `StragglerGrace` must be positive for the same reason. `[assert]`
- **The leash is measured from the NPC's HOME PATCH, and the number it has to clear is the
  plot EDGE** — `beltRadius() − PlotSize.Z/2`. Two populations answer to it: central-wave
  raiders (home spread + leash + reach) and band roamers (outermost band edge + leash +
  reach). Plot-wave raiders are the deliberate exception; their promise is the breach
  floor. `[assert]` "raiders could be dragged onto someone's factory", both forms.
- **Raiders must be slower than a player, and the de-aggro band wide enough to survive
  strafing.** With no speed gap you can never break contact and the de-aggro rule is
  decoration; a narrow band yo-yos on the leash line. `[assert]`
- **`MaxChasers` is bounded by the approach ring, not chosen.** A 6.5-stud ring has
  circumference 40.8 and a raider is ~4.5 studs wide, so nine fit shoulder to shoulder — tune
  `ApproachStandoff` down and the cap silently becomes a queue. A bigger wave must be more
  reinforcements, not more raiders hitting you at once. `[assert]`
- **The wind-up is the only warning a player gets**, so `AttackWindUp >= 0.3` (below reaction
  time the telegraph is a lie) and `AttackRange < 14` (or raiders hit you from off-screen).
  `[assert]`
- **The telegraph pose block runs regardless of AI state.** Gating it on `chase` freezes a
  raider mid-swing with its bat overhead the instant it de-aggros. `[nothing]`
- **The AI state machine is skipped entirely while a swing is in flight**, so a de-aggro on
  the same frame as an impact cannot cancel the range re-check that makes walking out of a
  telegraph work — the hit only lands if you are still in range when it does. `[nothing]`
- **`humanoid.WalkSpeed` must keep being written EVERY frame**, and hard-zeroed while rooted.
  `UpgradeService`'s freeze verb anchors the assembly *specifically because* that write
  exists, so moving it into a repath branch breaks a documented contract in another file.
  Per-state speed scales **multiply** the captured `entry.walkSpeed`; they never replace it,
  or every raider loses the jitter `buildNPC` gave it. `[nothing]`
- **The AI state is `entry.ai`, not `entry.phase`.** That name is already the waddle's sine
  phase, and reusing it desyncs the walk cycle every time a raider changes its mind.
  `[nothing]`
- **The chaser count is recomputed from scratch each snapshot.** A decrement that has to
  happen on de-aggro, on death, on target death *and* on leash is one that eventually does not
  happen in one of them — and the failure mode is a player nothing will attack. `[nothing]`
- **`hitscan` must walk up to the model that owns a Humanoid**, not stop at the first `Model`
  ancestor: a raider's visible body is a sub-model of the rig and its arm a sub-model of that.
  `[nothing]`
- **A deferred strike must re-check the attacker, not just the character.** `canDamage` lets
  anyone hit an NPC without looking at the attacker, so a departed player's scheduled swing
  still landed. `[nothing]`
- **Knockback on players must be applied client-side.** The victim's own client owns their
  character's physics, so a server `ApplyImpulse` is discarded on the next replication tick —
  server→client via the `Knockback` remote. NPCs are server-owned and are impulsed directly.
  `[nothing]`
- **Camera shake must bind after `Enum.RenderPriority.Camera`.** On `RenderStepped` it runs
  before the camera module and is overwritten every frame. (This works only because the
  default camera module genuinely is a `BindToRenderStep` binding — see §6 for why the same
  reasoning fails for the Animator.) `[nothing]`
- **At one eligible player the boss split is algebraically the identity.** A solo server gets
  byte-for-byte the old boss with no branch anywhere in the code, which is the only reason it
  can be trusted to stay true. `[assert]` plus `[spec]` `boss_spec.lua` "a one-player server
  gets exactly the boss it had before".
- **The pot is neither leaked nor minted at any player count**, evenly split or lopsided —
  the floor share and the damage share are different fractions and only their sum is one. The
  pot must grow slower than the health (or the boss pays for standing near it) but not so much
  slower that arriving ninth is a punishment. `[assert]` plus `[spec]` `boss_spec.lua`.
- **Boss scaling is sampled once at `beginWave` and never re-read.** If it tracked live player
  count, someone leaving would change the boss's max health under a bar twelve people are
  watching. `[nothing]` — `NPCService` cannot be specced.
- **The damage ledger takes `before - humanoid.Health`, not `amount`.** A 10k overkill on a 2k
  boss would otherwise buy 80% of the pot. `[nothing]`
- **`forceEnd` settles the boss ledger pro-rata before zeroing healths.** "No reward for a
  wave nobody finished" is right for raiders and wrong for a shared boss — twelve people
  fighting for five minutes would have got nothing. `[nothing]`
- **The boss stays where everyone is walking**: a tighter leash than a raider's, a fixed
  bearing by the dais that clears the plinth and the arena wall, a home patch inside its own
  leash — and one player on the *starting* bat must still be able to finish a boss scaled for a
  full server inside `MaxWaveTime`. That last check is what actually binds
  `BossMaxHealthFactor`. `[assert]`

### Movement (#101)

- **Sprint is one bit up a remote, and the server writes the speed.** A client's own
  `WalkSpeed` write does not replicate, and the remote payload is coerced to a boolean so
  nothing a client sends can pick a number. Two states only: `Combat.WalkSpeed` and
  `Movement.SprintSpeed`. `[spec]` `movement_spec.lua`, falsified on a truthy payload.
- **The dash is client physics, server cadence.** The impulse fires on the approval echo —
  the client owns its assembly — and `MovementService.tryDash`/`dashReady` are the ledger
  any combat system reads when it must trust dash timing (#94's escape arithmetic).
  `[spec]` the cooldown, exact at the boundary.
- **The numbers sit inside lines other systems stand on**: SprintSpeed over walking and at
  most 32 (the wall-clip line the PlayerUpgrades ladder is held to), raiders slower than a
  sprinting defender, one dash under half a plot's depth, cooldown over duration. The siren
  guarantee keeps its conservative WALKING form — sprint only strengthens the defender's
  run home. `[assert]`, each falsified.
- **Touch controls sit above the LEFT reserve** — movement on the movement thumb; the
  bottom-right stack belongs to the action buttons — and are never built without touch.
  `[nothing]` beyond the reserve inset; placement is a Studio item.

### Raiding (#94)

- **The safe amount is unreachable by construction.** `RaidService.overflowOf`
  subtracts `SafeFraction x cap` before anything is computed, and both takings —
  the break spill and the kill-steal — are sized from the remainder. No code
  path reads a victim's cash without the subtraction. `[spec]` `raid_spec.lua`,
  falsified by deleting the subtraction: five specs fired.
- **Spoils are CARRIED.** A break pays into the raider's hands; the money enters
  their bank only through `bankCarry`, which goes through `Economy.add` and is
  clamped by the raider's own cap. A death drops the carry and each source's
  share goes home (their cap clamps the return too). `[spec]`
- **The storage body reaches the swing door through `siegeStrike` alone.**
  `VaultBase` resolves to the reserved key `"storage"` inside the strike loop;
  `siegeKeyForPart` never returns it, so the wall machinery — maxes, repair
  prompts, saved fractions — cannot meet the key. `[spec]` falsified by routing
  it through `damageStructure`.
- **The break observer fires on the transition only, with an attacker.** A
  broken unit absorbs nothing, so a camp-and-rebreak must go through the
  victim's repair; the camping ledger decays what it pays anyway. `[assert]`
  the verifier's raid family holds every Config.Raid number to its KPI, each
  falsified.
- **Banking is the heartbeat in `start()`** — standing-on-your-own-plot is
  CFrame arithmetic the harness does not claim. `[nothing]` the rectangle test
  itself; Studio owns it, HANDOFF_v17 names it.

### Helping (#123)

- **`HelpService.credit` is the one door kindness comes through.** Raid defence
  (RaidService's death path) and visitor repair (`Tycoon.repairObserver`, wired
  in Main.server) land there today; parties (#102) and wave co-combat join the
  same door later. The weight — 1 plus `GapWeightPerRebirth` per rebirth of
  lead, capped — scales the reputation AND the helper's boost minutes, and only
  a lead counts: helping up or across pays the base. `[spec]` `help_spec.lua`,
  falsified on `math.abs`.
- **Repair is open to anyone, and the breaker is the one exclusion.** A repair
  only ever helps the plot, so the guard moved off the owner; `lastBreaker` /
  `storageBreaker` remember who broke a thing so break-and-repair cannot farm
  credit. `[spec]` in siege_spec and storage_spec, falsified by dropping the
  exclusion.
- **One pair, one credit per `PairCooldownSeconds`,** and the cooldown outlasts
  the boost one credit grants, so a tame pair cannot hold a boost forever —
  which is the entire abuse story, by design. `[assert]` + `[spec]`, both
  falsified.
- **`profile.reputation` lives in BOTH `defaultProfile()` and the save
  payload,** with a round-trip spec. `[spec]`
- The boost is the named Economy multiplier hook `"help"` — an O(1) expiry
  read, the SessionService shape. `[spec]` through `Economy.multiplier`.

### The open world (#89)

- **Three populations, one AI, one damage curve.** Band roamers, the central wave and plot
  sieges all go through `mintNPC` — one stat arithmetic (`BaseHealth × HealthGrowth^(level−1)`,
  damage capped absolute), one tick loop, one leash/aggro machine. A new population is a new
  minting site, never a new AI. `[nothing]` structural; the numbers are asserted per family.
- **Danger falls walking OUTWARD.** Bands are contiguous annuli from the centre; each is
  asserted weaker than the one inside it, and the central wave's milling ground sits inside
  the innermost. `[assert]`, falsified.
- **The spawn is outside every band's notice** — further out than the outermost band plus
  aggro plus wander — and short of the belt. A fresh player cannot spawn aggroed. `[assert]`
- **The world's NPC part ceiling sums the real worst case**: the central wave's cap, every
  band's population and `MaxConcurrent` sieges, all alive at once, against
  `Mobs.MaxWorldNPCParts`. A plot-wave count or band population is exactly the number
  someone raises without pricing it. `[assert]`, falsified through `MaxConcurrent`.
- **A plot wave is scaled by the PLOT, never the server**: `Config.plotWaveLevel(expansions,
  rebirths)`. The server-lifetime climb survives only in the central wave, which is opt-in
  by geography. `[assert]` the level cap keeps every plot raider under the damage ceilings.
- **PvP is legal everywhere, and there is no zone code to re-grow.** The economic guards
  (death costs nothing, kill-steal bounded, safe cap fraction, camping decay) are the
  protection, and they are asserted in the #94 family. `[nothing]` — this entry is the
  record that the deletion was on purpose.

### The party (#102)

- **`sameParty` is the one predicate, and it is an identity check** — every member maps to
  the same shared table. Combat (`setAllyCheck`), the plot's structures (`Tycoon.allyCheck`),
  the raid ledger and the gates all consult it; none holds a copy. `[spec]` `party_spec.lua`.
- **The boundary is total**: partymates cannot damage each other, cannot raid each other's
  plots (break OR kill-steal), and open each other's gates. `[spec]` the raid half, falsified
  by dropping the guard; the combat and gate halves are hook wirings on the Studio list.
- **A party of one is nobody's party.** Leave dissolves below two, or the last member keeps
  the bonus and the boundary forever. `[spec]`, falsified.
- **The bonus composes and the STACK is bounded**: friends × party × help ≤ 2×, asserted —
  each factor looks harmless alone. `[assert]`, falsified at 2.96×.
- **Forming a party is a kindness both ways** through `HelpService.credit`, so #123's gap
  weighting pays the veteran who parties with a new player. `[spec]`

### Recall (#103)

- **Stolen Tung walks home.** A raid carry blocks the cast outright — the chase (#94's
  anti-grief spine) must never end in a blink. `[spec]`, falsified by dropping the block.
- **The stillness is the anti-escape**: the cast eats at least two raider swing cycles,
  drifting past `CancelMoveStuds` (held under `AttackRange`) or losing any health cancels,
  and the cooldown outlasts the cast. `[assert]`, each falsified; the watch loop itself is a
  character concern and a Studio item.
- **One direction.** Recall comes home; going out is the walk. `[nothing]` — the record
  that the asymmetry is on purpose.

### The tower (#95)

- **The day deals the deck.** `Config.towerFloors(daySeed)` is deterministic, every
  archetype appears, the boss holds the top floor — walked across twenty seeds. `[assert]`
  + `[spec]`, falsified by dropping the boss pin.
- **A floor pays MINUTES of the climber's own income**, through the capped door, on the
  spot — which makes "fighting beats waiting" one line of arithmetic
  (`FloorRewardMinutes × 60 > FloorNominalSeconds`) that holds at every progression stage,
  and makes a wipe keep what it cleared. `[assert]`, falsified.
- **The daily reset is arithmetic**: `profile.tower` stores `{day, best}`, `bestFloor`
  compares the stored day on read, and yesterday reads as zero with no job anywhere.
  Both profile homes, round-trip specced. `[spec]`, falsified on the comparison.
- **Every tower body goes through `NPCService.spawn`** — the one minting site — and the
  world part ceiling includes `MaxConcurrentRuns` at their worst. `[assert]`, falsified
  through `MaxConcurrentRuns`.
- The run driver (platforms, wipes, timers) is a workspace concern. `[nothing]` beyond
  the ledger split; HANDOFF_v18 carries the Studio list.

### Disclosure (#96)

- **The high-water only rises.** `profile.disclosed` is written once per surface and
  nothing drains it: a rebirth wipes `owned` and forgives no disclosure, and a returning
  player is never re-onboarded. Both profile homes, round-trip specced. `[spec]`, falsified
  by making reconcile clear un-earned rows — the rebirth spec fired.
- **The client decides nothing.** The server pushes the whole set; every gated panel asks
  `HUD.disclosed(id)` at render and re-renders on push. The undisclosed state is pinned in
  hud_spec (an invitable account with no `social` row shows nothing). `[spec]`
- **Gameplay gates read the same field as the pixels.** The plot siege waits for
  `profile.disclosed.siege`, so the gate and the interface cannot disagree — a raid siren
  in the first minute is the overload the system exists to prevent. `[spec]` on the water;
  the NPCService read is a Studio item.
- **The sixty-second screen is the always-on set, and it is held to three rows** —
  the verifier prints it on every run and fails a fourth. A dangling `after` is a surface
  that never arrives, also asserted. `[assert]`, each falsified.
- **The help card lists only what is unlocked**, so it structurally cannot become a
  manual; help lines are capped at 160 chars. `[assert]`

### The shop (#108)

- **The catalog is the same `Config.Buttons` rows.** Same ids, same prices, same chains —
  the tuned week walk spends through them UNCHANGED, which is what let the storefront move
  without touching the curve. A shop track is `furniture = "shop"`, keeps
  `keepOnRebirth = true`, builds no pedestal and no ghost, and never takes the beacon.
  `[assert]` the restated `keepOnRebirth == (furniture == "shop" or "land")` equivalence.
- **Every refusal is server-side and in order**: shop wares only, the disclosure gate, the
  plot milestone (`trackUnlocked`, dropper3), the chain, the price. `[spec]`
  `shop_spec.lua`, the disclosure and chain guards falsified.
- **A sale lands as the same monotonic grant a cabinet install did** — `profile.owned[id]`
  plus `grantBat`/`grantArmor` — and the plot's `owned` mirror is kept in step so the
  frontier arithmetic and the rejoin replay agree. The shop chain is asserted to CLIMB the
  tier it grants. `[assert]` + `[spec]`.
- **The measured-effect line survives the move**: every shop row prints what the pads
  printed ("34 dmg • 14% crit", the armour's health). `[nothing]` — it is presentation;
  the Studio list owns reading it.

### Objectives and hints (#97)

- **Progress is a baseline, never a counter.** The day's first beat snapshots the live
  profile stats; progress is live minus snapshot, so nothing observes kills or purchases
  and yesterday's grind counts for nothing. `[spec]` `objective_spec.lua`, falsified by
  zeroing the baseline.
- **A crossing pays once**, in minutes of the player's own income through the capped door,
  and the DONE flag persists in `profile.objectives` (both homes, round-tripped). `[spec]`
- **The richest possible day is bounded**: the top `PerDay` rewards in the pool sum under
  `MaxDayMinutes`, asserted — the streak and the offline grant are why players log in, and
  this stays a nudge by arithmetic. `[assert]`, falsified at 27 minutes.
- **The draw is the tower's seeded deal**: deterministic, distinct, the same three on
  every server that day. `[spec]` over thirty seeds.
- **Hints read persisted stats only** (kills, reputation, rebirths), answer in ladder
  order, and run out — a player past every milestone is not nagged. `[spec]` + `[assert]`
  on the stat names.

### The guide (#100)

- **The guide is purely informational, and its mouth is a hook.** `Tycoon.guideSpeaker`
  is wired in Main.server to the hint machinery (`ObjectiveService.hintFor`), so the
  mixin never learns what an objective is and the guide says more over time for free —
  the hint ladder runs out, the fallback line stays. `[nothing]` beyond the wiring shape;
  the hint selection itself is `[spec]`'d in objective_spec.
- **It answers ANY player**, visitor included — a visitor hears the guide's flavour with
  their own hint, which is a kindness surface. `[nothing]`
- **`Layout.GuideAt` is checked furniture**: inside the plot, clear of the buy-button
  rows and the belt, like every other placed thing. `[assert]`, falsified off-plot.
- Props-parented and idempotent by name on the refreshButtons beat, so it leaves with
  the tenancy and survives every rebuild. `[nothing]`

### The tier tag (#106)

- **The tier is public and CLOSE-RANGE.** The totem tag carries the rank beside the
  owner's name at the sign's existing "plot" draw distance — never across the map, so
  raiders cannot shop for targets from a distance they never travel. `[nothing]` for the
  distance (it rides the Style distance class); the ladder itself is `[assert]`ed.
- **The ladder climbs strictly from zero**: a fresh player has a rank, thresholds rise,
  names are unique, and a huge rebirth count wears the top rank. `[assert]`, each
  falsified.
- One writer: `updateSign` on the 3-second repaint, which also catches the profile
  lagging a rebirth by a beat. `[nothing]`

### The rebirth moment (#107)

- **Every line on the card is DERIVED.** Rank and motto off `Config.tierRow`, the
  multiplier off Economy, the keeps off the kept set and the gear tiers — a new tier row
  cannot ship with a stale list because no list exists to go stale. `[assert]` tierRow
  and tierName agree at every count; mottos present and one-line.
- **The card shows what was lost too**: one honest line — a promotion that hides its
  cost reads as a trick. `[nothing]` — the record that the line is deliberate.
- **Dismissible AND self-dismissing** (14s): never a hard modal. `[nothing]`; the feel is
  a Studio item.

### Wayfinding (#104)

- **The compass costs ZERO remotes.** Every target position is client-readable — the
  plot from the PlotAssigned index through `Config.plotPlacements`, the tower and the
  core from Config, partymates from replication. A server push here would be a copy of
  something the client already holds. `[nothing]` — the record that the absence is the
  design.
- **A strip, never a map, for now.** The map is the largest surface this game could put
  on a phone and waits for its own ticket; the strip re-anchors to the top-centre, which
  no other dock claims. `[nothing]`; the one-ScreenGui pass covers the layer.
- **The buy-pad beacon stays separate** — plot-local wayfinding answering one question.
  The issue's open closes as "stays". `[nothing]`
- Behind-you markers pin to the edges and DIM rather than vanish — a marker that
  disappears reads as a target that despawned. `[nothing]`; Studio owns the feel.

### The leaderboard and the frontier (#105)

- **The frontier means ALL of it**: every `Config.Buttons` id owned, at the rebirth cap.
  Anything looser tells a player they finished a game they did not. `[spec]`
  `frontier_spec.lua`.
- **The moment fires once per account** and the stamp survives the save — the stamp IS
  the telemetry, because the players who run out of game are the ones worth talking to.
  `[spec]`, falsified by dropping the once-guard.
- **Rank only.** No currency, no sink, no permanent boost on the frontier surface —
  decisions for after watching who arrives. `[nothing]` — the record that the absence is
  deliberate.
- **The board is a world object** by the spawn, repainted on a slow beat; frontier
  players wear a ★ on it. `[nothing]`; Studio owns the read.

### Method resolution (the ensureCabinets lesson)

- **A method call on the class table is a dynamic lookup, and deleting the method does
  not break the build** — it breaks the first runtime that reaches the call. #108 deleted
  `ensureCabinets`; the constructor kept calling it; `Tycoon.new` threw; everything after
  `PlotService.build` in the boot — claim hooks, PlayerAdded, autoAssign — was dead on
  main with a green build. The harness never runs the real constructor and the
  undeclared-global pass cannot see a method name. `[lint]` the tycoon method-resolution
  pass in verify.py: every `self:name(` in the mixin folder and every `tycoon:name(` in
  src/server must resolve to a `function Tycoon:name` definition. Falsified with the
  actual bug.
- **The boot has a blast door**: every service start below the plot loop is pcall'd with
  a loud warn, so one optional service's throw can never again kill claiming. The world,
  data, economy and plots stay unwrapped — if those fail, the server is correctly dead.
  `[nothing]` beyond the wrapper's shape.

### The carrier mark (#138)

- **The thieves ledger is derived, never maintained**: `RaidService.thievesOf(victim)`
  walks the live carries' sources, so it cannot drift from the money — a banked or
  dropped carry empties it by construction. The compass mark and the victim pushes both
  stand on it. `[spec]`, falsified by keeping the carry record on bank.
- **The carrier is marked server-side** — a billboard every player can see, because the
  chase only happens if the server can see who to chase. The attribute stays the machine
  seam; the billboard is the eyes. `[nothing]` for the look; Studio owns it.
- **The thief mark outranks disclosure** on the victim's compass — being robbed is itself
  the event, the party-invite exception's shape. `[nothing]` — the record that the
  exception is deliberate.

### Tower surfaces and the daily modifier (#145, #146)

- **"Today's tower" is a sentence: the deck plus its twist.** One modifier per UTC day,
  dealt by the same seed machinery as the deck, deterministic by spec. The spire sign
  prints both, repainted when the day turns. `[spec]` + `[assert]` on the deal.
- **Modifier scales are bounded against the lines other systems stand on**: a SWIFT
  raider still loses to a sprinting player, TOUGH stays under ×1.6, BOUNTIFUL's bonus
  stays under the base floor reward — past that the modifier IS the reward. `[assert]`,
  falsified at ×1.8 walk.
- **The banner's countdown is `secondsLeft`, never a deadline** — the client's clock is
  not the server's, and a deadline would drift by exactly their skew. The client counts
  down locally between pushes. `[nothing]` beyond the packet shape.
- The scales enter through `mintNPC`'s options — the one minting site grew two numbers,
  never a second AI. `[nothing]` structural.

## 6. Procedural animation

`HANDOFF_v3.md` §2 is the long form and is still worth reading before you touch
`SwingAnim.lua`. **Everything in this section is `[nothing]` and cannot be otherwise:** the
verifier checks data against data, and none of this is expressible as a config assertion.
Both animation bugs sailed through it *and* through a careful review that caught five other
defects in the same file.

- **Write `Motor6D.Transform`, not `C0`.** `Transform` is the channel the Animator writes
  every frame, so it composes with the playing animation, leaves the rest pose alone and needs
  no restore step. `C0` is also becoming read-only on character joints under the Avatar Joint
  Upgrade. `[nothing]`
- **Write on `RunService.PreSimulation`, and nowhere else.** A frame runs
  `PreRender → render → PreAnimation → [Animator writes joint transforms] → PreSimulation →
  [transforms applied to parts]`. `PreRender` — and therefore `BindToRenderStep` — is
  structurally too early and is discarded with no error and no log line; `PostSimulation` is
  too late. `[nothing]`
- **`Enum.RenderPriority` has no engine meaning.** It only sequences `BindToRenderStep`
  callbacks against each other; `Character = 300` does not mark where characters are animated,
  and reading it that way is what produced the bug. `[nothing]`
- **Do not "modernise" `PreSimulation` to `Stepped`.** `PreSimulation` passes `(deltaTime)`;
  `Stepped` passes `(timeSinceStart, deltaTime)`. Swap them and every animation finishes on
  its first frame — invisible again, for a new reason. `[nothing]`
- **Decide whether your poses are ABSOLUTE or OFFSETS, and never mix.** Absolute poses are
  blended toward with `current:Lerp(target, weight)`; offsets are stacked with
  `offset * current`. Stacking absolute poses adds whatever is already playing to every pose
  you authored — the Animator's tool-hold has already raised the right arm ~90° forward, which
  is how the wind-up ended up behind the character's back. `[nothing]`
- **Blending beats stacking for anything that owns a limb**, and recovery lerps toward the
  *tool-hold*, not toward `REST` (the bind pose), or the arm is hauled to the hip and snaps
  back. At weight 0 a lerp is exactly the Animator's pose, so a swing starts and ends without
  a pop. `[nothing]`
- **Remember what you wrote.** The Animator resets `Transform` before every `PreSimulation`
  *except* when it is throttled (`Animator.EvaluationThrottled`, for distant characters) or
  when no track is playing. In those frames it is still your last write, so an unguarded blend
  creeps toward the target every frame and an unguarded multiply compounds into a windmill.
  `[nothing]`
- **Look joints up by name and accept `AnimationConstraint` as well as `Motor6D`.** R15
  characters are migrating to the former under the Avatar Joint Upgrade; an upgraded character
  has no `Motor6D`s at all, so any `IsA("Motor6D")` filter silently finds nothing. `[nothing]`
- **Express poses in torso space and conjugate per joint:**
  `Transform = C0.Rotation:Inverse() * Q * C0.Rotation`. R6 and R15 bake completely different
  rotations into their shoulder `C0`s, so a raw joint-space angle that raises an R15 arm
  forwards swings an R6 arm out sideways. `[nothing]`
- **R6's `RootJoint` is not R15's `Waist`.** Every R6 limb hangs off the Torso, so a rotation
  at the root carries the arms, legs and head with it — the character bodily leans instead of
  twisting at the middle. The torso channel is yaw-only and damped on R6 for that reason.
  `[nothing]`
- **The coordinate frame:** a character faces −Z, up is +Y, +X is its own right, both arms
  hang along −Y, and `CFrame.Angles(x, y, z)` composes as `Rx·Ry·Rz`. Pitch 0 is straight
  down, 90 forward, 180 straight up, **>180 is up and behind — where a wind-up lives**. Two
  traps: **the off-arm's roll is not mirrored** (both arms rotate in the same torso space, so
  a two-handed pose needs the left arm's roll *positive*, reaching across), and **torso pitch
  + leans BACK**, so load a slam with positive pitch and land it with negative. `[nothing]`
- **`Motor6D.Transform` does not replicate.** Every client draws every swing locally: the
  attacker predicts theirs from `Tool.Activated` (which fires client-side, so it costs no
  remote) and everyone else plays it from the `SwingFx` broadcast. Do not "fix" this by moving
  it server-side; there is nothing to move. `[nothing]`
- **The raider rig is entirely invisible.** Every part built by `rigPart` is
  `Transparency = 1` — the R6 rig exists only so `Humanoid`, `MoveTo` and damage work. The guy
  you see is the `Visual` model, and its right arm hangs off a Motor6D named `TungArm`;
  animating `Torso["Right Shoulder"]` rotates a stick nobody can see. `[nothing]`
- **Check poses numerically, not by eye.** Evaluate `Rx·Ry·Rz` against `(0,-1,0)` and read off
  the direction. Every pose fault above would have been caught in seconds this way. `[nothing]`

## 7. World text, screen UI & assets

- **Nothing outside `Style.lua` names a font, an outline or a view distance**, and the build
  fails if anything does. Before the lint there were three fonts, six outline settings and
  eleven view distances between 90 and 1200 studs, none chosen against each other; a
  convention in a document had already failed to prevent that once. New distance ⇒ add a
  named tier to `Config.Style.Distance`. `[lint]` `verify.py` "style ownership".
- **`SurfaceGui.MaxDistance = 0` means "always render".** It is not "no limit specified", and
  statue faces plus every raider inherited it. `[lint]` (any `MaxDistance` assignment must go
  through `Style`), plus `[assert]` every named tier is a positive number, tiers are ordered,
  and the tier count matches the names — an unnamed tier is a number nobody chose.
- **The named tiers have to cover the map they are read at**: the world tier reaches the
  farthest plot edge, the plot tier the plot diagonal, and the raid sign draws far enough to be
  read from the plots it is warning. `[assert]`
- **Two things draw through walls and only two**: damage numbers, and enemy nameplates (which
  are Roblox's own and are drawn on top whatever we ask). Everything else obeys geometry.
  `[nothing]`
- **`Style.Button.lift` is what makes `AlwaysOnTop` off safe.** With it off, a buy button's
  label has to clear the machinery by standing above it, so the billboard's bottom edge — and
  the smaller locked variant's — is asserted against `Layout.MachineTopY`, which derives from
  the same `BeltY` the dropper's arm is built from. Raise the arm and forget the label and the
  build fails. `[assert]`
- **The locked buy-button state differs from the buyable one on five axes, not just colour**,
  and gives up drawing FIRST. Colour is the first thing lost to a bright sky or a neon variant
  behind the label, and it had been carrying the whole distinction. `[assert]` scale, panel
  alpha, stroke, text alpha, distance.
- **The raid sign clears the arena wall and does not overlap the arena title.** `[assert]`
- **There is exactly one `ScreenGui`.** One ScreenGui means one `Root` means one `UIScale`, so
  a new panel cannot bypass mobile scaling by accident — and that failure is silent, on a
  phone, looking fine on the machine it was written on. `[lint]` `verify.py` "one screengui".
- **The client is guaranteed at least 1280×720 of DESIGN space at every aspect ratio**, because
  the scale divides by `min(vx/1280, vy/720)`. That is what makes every existing
  `UDim2.fromOffset` literal correct by construction. `[assert]` the `UI.MinScale`/`MaxScale`/
  reference-frame relationships, the physical-pixel floors for touch targets and small print,
  and that every modal fits the reference frame with margins.
- **Colour in `src/client` is a role, and roles live in `Config.UI.Role`.** A builder names
  `surface` or `onAction`; it never names `panel` and never writes a `Color3`. Two tables —
  `Palette` for what the colours are, `Role` for what each is for — so retheming is an edit to
  Config and to nothing in `src/client`. `UiKit.PALETTE` was three copies merged into one, and
  merging them fixed the values while leaving nothing to stop a fourth: twenty-six raw `Color3`
  calls had grown back across seven files, including the three that made `MovementClient`'s
  touch buttons the only off-palette controls in the game. `[lint]` `verify.py` "ui colour".
- **Every role names a palette key that exists, and every palette key is named by some role.**
  The first half is `Style.Font.head` — five call sites reading a field never defined, rendering
  in the wrong face for two rounds — closed for colour before it can happen. The second half is
  what stops an orphan colour sitting in the table for the next person to pick because it is
  there. `[assert]` both directions, plus a `UiKit` load-time `error()` on the first.
- **Contrast is measured against what the player SEES, not against the swatch.** A label prints
  on the card composited at `UI.PanelAlpha` over whatever is behind it, and the worst case
  behind a card is a bright sky; measuring against the flat panel colour overstates every ratio
  in the game by about a third. Body copy on a card clears 4.5:1, a stat line 3.0:1, and the
  currency colour 4.5:1 because the balance is the largest type in the game. `[assert]`
- **A fill and the ink on it are one decision, and the pairing is derived from the names.**
  Role `x` is printed on in role `onX` wherever both exist, held to 3.0:1 — WCAG's large-text
  case, which is what a bold button label at 15 px and up is. Nobody maintains a list of pairs,
  so nobody can forget to add one. This is the check that would have caught the shop assigning
  a disabled background and leaving the label at ink. `[assert]`
- **The signals are told apart by hue, not by luminance.** `Config.UI.Signal` names the roles a
  player has to distinguish at a glance — affordable, danger, a raid — and every pair is held to
  a Manhattan distance of 40 across the three channels. A contrast ratio is the wrong test here:
  two colours of the same luminance and different hue pass it and are still one colour with two
  meanings on a phone. The wood scale is deliberately outside this set, because a surface and
  the ink on it are meant to be close in hue. `[assert]`
- **A dead control and a live one that is merely not the one you want must not render alike.**
  `disabled` cannot be pressed; `neutral` is LEAVE PLOT beside REBIRTH and CANCEL beside DO IT.
  They shared a palette key for exactly as long as it took the assertion to be written. `[assert]`
- **Card-scale geometry belongs to `Config.UI`.** A 470×330 card written as a literal in
  `src/client` is a number the verifier cannot see, cannot scale-check and cannot fit against
  the panel next to it — which is how the upgrade shop came to sit on top of the NEXT UPGRADE
  panel with one of the two numbers in `HUD.lua` and the other in `UpgradeUI.lua`. `[lint]`
  `verify.py` "ui geometry", plus `[assert]` the shop/column overlap at the reference height.
- **The status card's rows are named heights and every Y is accumulated from them**, in
  `Config.lua`'s derivation block — as are the session panel's rows and `ColumnBottom` below it.
  Neither `HUD.lua` nor `SessionUI.lua` types a Y or a text size at all. `[assert]` the card's
  `Height` against the `ContentHeight` its rows add up to (the two are independent numbers on
  purpose: a `Height` derived from the sum would fit by construction and catch nothing), its
  `Width` against `ColumnWidth`, and the column against `ReferenceHeight` with margins.
- **Every top-level region is docked to a named corner, and no call site spells one out.**
  `UiKit.dock` owns the four corners; the anchor, the inset and the list alignment are one
  decision, because a frame anchored `(1,0)` and positioned from the left edge is off the side
  of the screen and a right-hand column aligned Left grows away from its own edge. Five call
  sites across three files each wrote their own before it existed. `[nothing]` — the corners
  are named, but nothing stops a new panel setting `Position` by hand.
- **The left column is a `UIListLayout` and neither panel knows where it starts.** The status
  card and the session panel are `LayoutOrder` 1 and 2 inside `HUD.column()`. They were placed
  by two files reading `Config.UI.StatusCard.Y` and `Config.UI.SessionPanel.Y` separately —
  which is precisely the disagreement `Config.UI`'s own column comment says that table exists
  to catch, sitting one edit away the whole time. Both Ys are deleted. `[assert]`
  `ColumnBottom` — a list layout will lay a panel out past the bottom of the screen as happily
  as two hand-typed Ys would — plus `[spec]` that the panel lands in the column.
- **The session panel's `TallHeight` is the panel with its WHOLE optional tail showing.** It
  shipped at 258, the ONE-optional-row height, while `layoutTail()` could build 310 with the
  Vault Timer and a pending offline grant both up — every returning player who has not maxed
  the vault. `ColumnBottom` was measured against the number the code had already left behind,
  so the column fitted by luck. Both heights derive from `OptionalRows` now. `[spec]` — the
  count is asserted against the list `SessionUI` actually stacks, in `hud_spec.lua`, because
  that list is in `src/client` and `verify_config.lua` cannot see it.
- **`layoutTail()` is the only thing that sizes the session panel.** `render()` set a height too
  and then called it, which overwrote the value two lines later; a write nothing can observe is
  a write nobody checks, and the losing one was the wrong one for two rounds. `[spec]`
- **Every text size on the card clears `MinTextPx`, and the balance is strictly the largest of
  them.** The NEXT UPGRADE heading shipped at 12 design px — 7.4 physical px at `MinScale`,
  under both floors `Config.UI` declares — because it was a literal in a builder and nothing
  could read it. The balance being biggest is the card's whole thesis: it is the number the game
  is about. `[assert]` six sizes against the floor, five against the balance.
- **So does every text size on the session panel, on the rail and in both modals.** Three of the
  session panel's shipped at the same 12, for the same reason: literals in a builder. The modal
  sizes are walked by name rather than listed, because the two cards carry different rows and a
  hand-written list stops covering the row somebody adds next. `[assert]`
- **The progress bar is a gauge, not a control**, and is bounded from both sides: at least 3
  physical px at `MinScale` so the fill is readable, and under `MinTouchPx` so it does not read
  as something that answers a press. `[assert]`
- **There is nothing on the status card to press.** It carries the balance, what multiplies it
  and the next purchase; it is read at a glance and a surface read at a glance should not also
  be a control. The INVITE pill that used to sit on its friend row is a rail item now.
  `[spec]` — and deliberately not `[assert]`: `Config` holds numbers and cannot see a
  `TextButton`, and the obvious proxy ("no row is a touch target's height") is false on its
  face, because the balance row is 46 px tall to hold 38 px of text. That proxy was written and
  it failed against the shipped config the first time it ran.
- **Every touch target comes from the `UI.Button` ladder, and a rail item is held to
  `MinTouchPx` on both axes.** INVITE shipped as a 72×26 literal — 16 physical px at
  `MinScale`, under half the floor this file declares, on the one control whose job is to be
  pressed by a child. A rail item is a square rather than a row, so it is not on the ladder and
  is checked directly: a 56-wide button 20 tall is as unhittable as a 20-wide one. `[assert]`
- **Both bottom corners belong to the engine.** On touch, Roblox draws the movement thumbstick
  bottom-left and the jump button bottom-right, on a layer above ours, and no API returns
  either rectangle. The action stack was anchored `(1,1)` at the margin — 200×112 in exactly
  the jump button's corner — so for four out of five players REBIRTH and JUMP were the same
  pixels. `Config.UI.TouchReserve.Bottom` is the declared clearance. `[assert]` the stack
  against the reserve, and the reserve against two primary buttons: a reserve smaller than our
  own biggest control is a number that reads as a decision and is not.
- **The right edge is a column too, and its three surfaces clear each other.** Rail, then the
  toast list, then the action stack. `[assert]` toasts below the rail and above the actions —
  which is only meaningful because **`HUD.toast` destroys cards past `UI.Toast.MaxCards`**: a
  `UIListLayout` does not clip and does not stop, so before that a burst of toasts drew straight
  through whatever was under them and `ListHeight` described nothing.
- **The bar, the balance and the "N to go" all read `displayedCash`**, the lerped value, not
  `state.cash`. The counter takes ~0.2s to arrive after a payout; anything on the card computed
  from the packet is at the destination while the number above it is still climbing, so the card
  contradicts itself at the one moment it is being read closely. `[nothing]`
- **A `UIScale` transforms its whole subtree**, so a shade at `fromScale(1,1)` inside a 0.62
  layer dims 62% of the screen and leaves a bright border. Both layers are sized
  `fromScale(1/scale)` to cancel exactly that. `[nothing]`
- **Do not re-apply the top inset.** `IgnoreGuiInset = false` already pushes the ScreenGui
  below the topbar; subtracting `GetGuiInset()` again is the classic double-inset bug.
  `[nothing]`
- **`GuiService.TopbarInset` is not a safe area and nothing reads it.** It is the strip left
  over for CUSTOM topbar buttons, so its `Min.X` sits past Roblox's own menu and chat buttons —
  165 px on an ordinary desktop. Read as "the only reading of the side safe area available to a
  LocalScript" and applied as a full-height gutter, it pushed the whole left column 191 px into
  the screen on every device, to clear an obstruction inside a strip `IgnoreGuiInset = false`
  had already put the entire layer below. The side gutter comes from `GetGuiInset().topLeft.X`,
  which is 0 on a desktop and the display cutout on a phone. `[spec]` — `hud_spec.lua` builds
  two clients whose topbars differ only in `Min.X` and asserts their left padding is equal.
- **`Util.abbreviate` trims trailing zeros only past a decimal point.** Trimming
  unconditionally turned `320` into `32`, so 320K rendered as 32K. `[nothing]`
- **Every model, face and UI element is generated in code, and every referenced asset is an
  engine asset.** `rbxasset://sounds/*` ships inside the Roblox client — no upload, no
  moderation, and it cannot be taken down; an `rbxassetid://` in `Config.Sound.Library` is an
  upload, and an upload is a thing that can be moderated away. `[assert]` "only engine assets,
  never uploads", plus a ceiling on the sound pools (~400 live Sounds is where A/V desync
  starts).

## 8. Growth surfaces

- **Never put a continuous value in an analytics custom field.** Three fields per event,
  string values only, each field a CLOSED set — Roblox drops a numeric field value and logs
  the event anyway, and an open set spends a fresh combination per new value. Every one of
  these limits fails *silently*: no raise, no warn, just a chart weeks later that is wrong in
  a way that looks like data. The schema sits in `Config.Analytics` precisely so it is
  checkable. `[assert]` the analytics family, plus `[spec]` `analytics_spec.lua` "an event
  reaches AnalyticsService with three STRING fields", "a value outside its declared set is
  snapped back into it".
- **8,000 field-value combinations is a shared, experience-wide budget, summed across events**
  — not maxed per event. This is the check a well-meaning "let's also break it down by button"
  fails, and it is the only warning anyone gets. `[assert]` plus `[spec]`
  "the schema spends 2,340 of the experience's 8,000 combinations".
- **Event names are `lower_snake_case`, every event's `value` says what it measures, every
  declared field is carried by some event, and derived value sets must match the ladder they
  are derived from.** Roblox groups by exact name, so a stray capital becomes a second chart
  nobody looks at; a hand-edited derived set logs purchases under a facet that no longer names
  them. Both fallbacks (`none`, `unknown`) must exist — a session that bought nothing is the
  most important row on `session_end`. `[assert]`
- **Every button is a SKU**, against `MaxEconomySkus`, and a purchase logs exactly one economy
  event. `[assert]` plus `[spec]`.
- **`returned` reads `lastSeen` BEFORE `SessionService` stamps over it**, so `Analytics.onPlayer`
  must run before `SessionService` for that player. `[spec]` `analytics_spec.lua` "running
  Analytics.onPlayer AFTER SessionService destroys the whole `returned` signal".
- **Offline earnings derive income server-side from persisted plot state, never from a stored
  or client-supplied number, and use `os.time()` rather than `tick()`.** Nothing is
  auto-credited: the claim is the reward, and the panel says whether the cap clipped you and
  names the upgrade that would have prevented it. `[spec]` `offline_spec.lua` — a backwards
  clock pays nothing, an empty factory pays nothing, income is droppers × upgraders × power ×
  rebirth term by term, and the cap the payout uses is the one you bought.
- **The friend bonus does not bank while you are logged out**, by the same mechanism that
  excludes the boost: a bonus for being in a server with friends must not pay while you are in
  no server. `[spec]` `social_spec.lua` "the bonus never reaches offline earnings",
  `offline_spec.lua`/`vault_spec.lua` "an active boost does NOT reach the offline rate".
- **A failed `IsFriendsWith` caches nothing.** Caching a web failure as `false` silently
  deletes the bonus for the rest of the session. `[spec]` `social_spec.lua` "a failed
  IsFriendsWith is retried and is NEVER cached as false".
- **A friend joining or leaving recounts EVERYONE, not just the mover**, and both toast,
  because an unexplained income change reads as a bug. `[spec]` `social_spec.lua`.
- **The friend hook STACKS with the session hook rather than replacing it.** `[spec]`
  `social_spec.lua`.
- **The multiplier hook runs on every `Economy.add`** — up to ~10/sec/plot at endgame — so it
  must be an O(1) table read, never a web call. `[nothing]`
- **An untrusted remote that can be spammed will be:** `RequestInvite` is rate limited.
  `[spec]` `social_spec.lua`.
- **Day buckets are UTC, and the streak survives a missed evening and a New Year.** A second
  claim in the same bucket pays nothing; a three-bucket gap survives and a four-bucket gap
  resets to one; day seven pays its rung plus the milestone and day eight wraps. `[spec]`
  `streak_spec.lua` plus `[assert]` a 7-day loop with each day better than the last.
- **The playtime ladder accrues on ACTIVITY and resets daily rather than per session.** It was
  a rejoin farm because `claimedPlaytime` was per-session and never persisted. `[spec]`
  `playtime_spec.lua` plus `[assert]` increasing rungs, the first taking longer than no time
  at all.
- **The weekend is UTC and stacks multiplicatively rather than replacing.** `WeekendDays` keys
  are `os.date` wdays (1 = Sunday), values must be literally `true` because the lookup tests
  `== true`, and a weekend is neither never nor always. `[assert]` plus `[spec]`
  `weekend_spec.lua` "a boost on a Saturday is x4, not x3 and not x2".
- **The vault gauge clamps at both ends, and a grant bigger than the cap is still one full
  column.** `[spec]` `vault_spec.lua`.
## 9. Tooling & the harness

`tools/verify.py` runs **eleven** passes: syntax and static analysis over `src/` *and*
`tools/testing/`, style ownership, prototype flags, config paths, mixin folders, ui geometry,
one screengui, the config suite, the runtime specs, and the packed build. Its boundaries have not moved:
`verify_config.lua` sees `src/shared/Config.lua` and nothing else, and it cannot reach frame
ordering, AI behaviour, or how anything looks. `NPCService` and `PlotService` still cannot be
specced — they need `Touched` and a physics step.

- **`Vector3` in `tools/verify_config.lua` is a stub with no arithmetic.** Any Config code
  that calls `.Magnitude`, `.Unit` or does Vector3 maths *at require time* crashes the
  verifier; the harness carries its own `sub`/`len`/`boxPointGap`. Store them as data only.
  `[nothing]`
- **A graduated feature's flag is DELETED, not set `false`.** "Every flag must be false" leaves
  exactly one legal way to ship: remove it. The sharp edge is that every `if not P.Whatever`
  guard left behind reads `nil`, so the guard fires FOREVER — which is how `VaultService.start()`
  returned before wiring anything and the vault gauge was dead on main with a green build.
  `[lint]` `verify.py` "prototype flags" (every flag read is a flag that exists), plus
  `[assert]` every flag ships `false` *and* a deleted name re-added as `false` is caught.
- **`Config.Admin` is not a `Config.Prototypes` flag and must not become one.** A prototype
  flag is one you cannot turn on, because the verifier asserts they all ship `false`.
  `[assert]`
- **The `Req` bootstrap line must stay byte-identical in every module.** `tools/pack.py`
  pattern-matches it to flatten the tree for the no-Rojo build, and `tools/test.py` is a
  **second consumer of the same regex** — so a packer regression surfaces as a failing spec
  rather than as a `build/` nobody reads. `[spec]` partial: only the twelve modules the harness
  loads. A mismatch elsewhere still packs a build that compiles and dies at runtime.
- **A module's FILENAME STEM is its global name, so no two `.lua` files under one side's
  source roots may share one.** `Req` resolves a name and not a path — it searches
  `TungShared`, then the side's root, then one level of folder nesting, and takes the first
  hit — and the packed build flattens the whole tree into `__MODULES[stem]`. So a second
  `Belt.lua` in another folder does not collide loudly: it silently overwrites the first in
  the paste build and shadows it under Rojo, and both halves still compile. `[lint]`
  `tools/pack.py`'s `build()` refuses a duplicate stem and prints both paths.
- **`build/` is generated output that is committed, because it is the deliverable for the
  no-Rojo install path; `src/` is the source of truth.** `[lint]` `verify.py` regenerates
  `build/` and syntax-checks the packed output as its last pass, and CI fails on a dirty
  `git diff -- build/`.
- **A mock is a claim about Roblox that only Roblox can settle.** That `UpdateAsync` re-runs
  its transform on conflict, that a `nil` return aborts the write, that `IsFriendsWith` throws
  rather than returning `false` on a web failure — all assumptions, and everything in the
  session lock rests on the first two. Where the game depends on one, name it in the round's
  "what only Studio can tell you". `[nothing]`
- **The DataStore mock deep-copies on every read and write.** A mock that stores by reference
  makes every save/load spec a tautology that passes forever. `[spec]` `smoke_spec.lua` "the
  DataStore mock deep-copies, so a save is a real snapshot".
- **`Players.MaxPlayers` must be a number in the harness.** `Config.plotCountFor()` reads it at
  module load inside a `pcall`; leave it nil and the specs run against different plot geometry
  than the verifier, with no error anywhere. `[spec]` `smoke_spec.lua`.
- **The default clock epoch is a Thursday, deliberately, and `os.date` delegates to the real
  implementation with an explicit timestamp** rather than reimplementing the civil calendar —
  which is what keeps `wday` correct for the weekend multiplier. A weekend default would
  silently double every income assertion in the suite. `[spec]` `smoke_spec.lua` "the clock
  drives os.time, and os.date reads the fake epoch", `weekend_spec.lua` "Monday does not".
- **`_G` is readonly under the `luau` CLI**, so harness globals are assigned directly.
  `[nothing]`
- **All of `src/client` executes under the harness, and `CLIENT_MODULES` is exhaustive by
  lint.** `client_sources()` fails the run if a file in `src/client` is missing from the list,
  and `client_manifest()` generates the list into the bundle so the boot smoke covers a new
  panel the moment it is listed rather than when somebody remembers to edit a spec. Before
  this, no client module had ever executed anywhere but Roblox — which is half of why
  `SessionUI.lua` shipped raising at require time with a green CI. `[lint]` + `[spec]`
  `hud_spec.lua`.
- **`Main.client.lua` is in `CLIENT_MODULES` even though it is an entry script.** `pack.py`
  treats a `.client` stem as an entry point, but the harness can hand it a `Req` like any
  other module — and requiring it is what makes the client's boot ORDER covered rather than
  transcribed into a spec that would not notice a reordering. `[spec]`
- **Two branches of the next-purchase ranking cannot change the answer with today's Config,
  and are specced somewhere they can.** The track gates hide whole ladders the factory
  outranks, and the price tie-break only applies within one track — a chain, so exactly one
  rung is ever available. Two hand-maintained copies of a branch that cannot change the
  answer can drift forever with the game looking fine. `hud_spec.lua` gates the POWER track
  and ties two `TrackRank` values to put each branch somewhere it decides. `[spec]`
- **The pass list in `verify.py`'s docstring must stay in step with `main()`.** It has said
  five, seven and eight while `main()` ran nine, and a pass count nobody can trust is a pass
  somebody can quietly delete. `[nothing]`
- **A mixin folder's aggregator must require every file in it.** `src/server/tycoon/` is one
  class across twelve files; the aggregator's `Req("Belt")` lines are code, not imports, and
  deleting one removes a dozen methods with every pass still green — the undeclared-global
  pass cannot see it, because the name that goes missing is a method on a table. `[lint]`
  pass 6, "is in the folder but Tycoon.lua does not require it".

---

## 10. Backlog — invariants nothing enforces

Every `[nothing]` above, collected. Grouped by the cheapest thing that would catch it, so a
round can take a row rather than a subsystem.

> **Closed in the same PR as this document:** `HANDOFF_v6.md` §G4's top unclaimed item — a
> pass sweeping for `Config.<path>` where the leaf does not exist. It is pass 5 of
> `tools/verify.py` now, it resolves the 21 aliases, and it was falsified against the real
> `PathTopY` dead key. Its scope is `src/` only, deliberately: `tools/verify_config.lua`
> *reads* keys it expects to be absent (`check(UI.SessionPanel.CompactHeight == nil, …)` is
> one), so covering the verifier would mean teaching the lint the difference between a
> dangling read and an asserted absence. That is the next inch, not this one.

**A lint over `src/` would catch these** (text-level, cheap, the pattern already exists four
times in `verify.py`):

- Nothing collidable near the belt except the running surface — a lint could require the
  `CanCollide = false` on the named decoration parts, or invert it: flag a new part built near
  a belt leg without it.
- The `Req` bootstrap line, for the files the harness does not load (today's coverage is
  partial and reads as complete).
- `Motor6D.Transform` written anywhere other than a `PreSimulation` connection; any
  `BindToRenderStep` in an animation file; `Enum.RenderPriority` read as though it had engine
  meaning. Three greps, and each one is a shipped bug.
- A second `Config.Prototypes`-shaped cache of a pure function in the profile (the `unlocks`
  class of defect).

**A config assertion would catch these** (data already in `Config`, or one field away):

- Overhead clearance over the tallest drop variant on the belt.
- `TrackInfo.power.keepOnRebirth == false` — only the factory's row has its *value* asserted.
- Non-square pad edge strips reading both `PlotSize` halves.
- ~~A hand-typed `requires` on a factory row~~ — **CLOSED in round 8.** The check is
  "the chain is exactly the table order", written as `requires` equals the row above,
  because the loader has filled the field in by the time the verifier runs. Round 8 moved
  six rows and added three, which is what finally made it worth the twenty lines.

**A runtime spec would catch these** (the module already executes under the harness):

- The general form of "a new persisted field needs both `DataService` edits" — today three
  individual fields are pinned by three unrelated specs. A spec that round-trips
  `defaultProfile()` key by key would close the class.
- Never renaming a button id, and the `Gear`/`Armor` ownership backfill in `reconcile`.
- Never writing `def.dropRate` (the shared-table mutation), as its own assertion rather than
  as a side effect of the drop-interval spec.
- `ensureYard`/`ensureCabinets` idempotence across a `release()`; the generator not being
  written into `self.objects[id].machine`; `cabinetSigns` holding only cabinets.
- The sticky, derived cabinet gate surviving a rebirth.
- The multiplier hook being an O(1) read on `Economy.add`.
- `Util.abbreviate`'s trailing-zero rule — three lines, and it shipped wrong once.
- **The status card's progress bar following `displayedCash` rather than `state.cash`.** The
  fill, the balance and the "N to go" are three reads of one lerped number in `renderNext`, and
  nothing stops the next edit reaching for `state.cash` in any of them — at which point the card
  disagrees with itself for a fifth of a second after every payout, which is a bug you can only
  see in motion. Needs `src/client` inside the harness: `HUD.lua` is outside `SERVER_MODULES`
  and wants a `ScreenGui`, a `UIScale` and a `RenderStepped` before it will load at all.

**Blocked until `NPCService` can be specced** (needs `Touched` and a physics step; widening
`SERVER_MODULES` is its own PR):

- The boss ledger taking `before - humanoid.Health`, and `forceEnd` settling pro-rata.
- Boss scaling sampled once at `beginWave`.
- Every raider-AI rule: the telegraph running regardless of state, the state machine skipped
  mid-swing, the every-frame `WalkSpeed` write, `entry.ai` vs `entry.phase`, the recomputed
  chaser count.
- `hitscan` walking up to the Humanoid's owner; a deferred strike re-checking the attacker.

**Only Roblox can settle these** — they are `[nothing]` by construction, and the honest move
is to keep them in the handoffs' Studio lists rather than to pretend a check exists:

- Client-side knockback; camera shake binding after `RenderPriority.Camera`; `PivotTo`
  overwriting the PrimaryPart's rotation.
- Every entry in §6 that is about what the Animator does to a property we also write, or which
  way a character is facing.
- `Highlight`'s 255-per-client cap; a per-plot `SpawnLocation` joining the random-spawn pool;
  `FindFirstChild` not being recursive; `Lighting.Technology` not being script-writable;
  `Players.MaxPlayers` not being scriptable.
- `UIScale` subtree cancellation and the double-inset bug; the two things allowed to draw
  through walls.
- The ~32-second contended load, and every assumption that a profile is present shortly after
  join.
- The mock claims themselves: `UpdateAsync` re-running its transform, a `nil` return aborting
  the write, `IsFriendsWith` throwing rather than returning `false`.
