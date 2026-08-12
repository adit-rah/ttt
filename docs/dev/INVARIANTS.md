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
**belt speed does not affect income** (income is `dropValue / dropRate`), only latency and
density — raising it to fix crowding is free. And **build length, not `BaseCost`, is the
rebirth lever**: sweeping `BaseCost` across a 20× price cut moves the first rebirth about
twelve minutes, because `upgrader6` and `dropper10` multiply income ~17× between them.

- **`StartingCash` must cover the cheapest requirement-free button.** With no dropper there
  is no income, so a fresh player could never buy their first one and the tycoon deadlocks.
  `[assert]` "StartingCash (%d) cannot afford the first factory button".
- **...and no side track's first rung may be affordable at spawn**, or a new player buys a
  bat instead of a dropper and strands themselves. `[assert]` "a new player could buy it
  instead of their first dropper and strand themselves".
- **The full build stays inside 45–150 minutes and no single purchase costs more than 15
  minutes of grind at the income you have when you reach it.** `[assert]` "full build takes
  %.0f min", "%s costs %.1f min of grind".
- **The 60-minute credit cap is its own check, separate from the build-length band.** One is
  an opinion someone may widen; the other is a platform fact — Roblox's playtime signal
  counts at most 60 minutes per user per day — that has to keep refusing when they do.
  `[assert]`
- **The first rebirth lands between minute 25 and 50, measured from when the pad first
  becomes affordable mid-build**, with at least two spine rungs still unbought so the
  session ends on a choice rather than on being finished. This replaced
  `BaseCost / endgameIncome`, which measured the price and called it pacing. `[assert]`
- **`Config.Rebirth.BaseCost` is DERIVED and must not be hand-set again.** `Config` assigns
  it from `Config.rebirthBaseCost()` once the spine exists (`PriceRung` = the 4th most
  expensive spine price), which is what guarantees rungs above it are still unbought when
  the pad lights. `[assert]` bounds the result: "the rebirth pad costs %.3g, less than the
  eighth-most-expensive spine rung".
- **Rebirth payout compounds** (`MultiplierPerRebirth ^ rebirths`). A linear bonus against a
  geometric cost curve dead-ends the prestige loop after two or three. `[assert]`
  "MultiplierPerRebirth must be > 1" plus the rebirth cost-ratio check.
- **The generator must multiply belt speed by exactly the factor it multiplies drop rate
  by.** In-flight drops are `peakRate × length / speed` and the two cancel; scale the
  droppers alone and a plot already at 88% of `MaxDropsPerPlot` goes over and `spawnDrop`
  silently discards the income you just bought. `[assert]` per tier, "power tier %s puts
  %.0f drops in flight against %.0f ungoverned".
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
- **Plot spacing on a ring is a chord, not an arc:** `2r·sin(π/n)`, not `2πr/n`. Checked
  pairwise at every supported player count rather than by formula, plus the inner ring
  against the arena and a 420-stud walk limit, because the ring is clamped to
  `MinPlotRadius` at low counts and the tightest case is not this server's. `[assert]`
  "%d plots: ring %d plots %d and %d are only %.0f studs apart".
- **`Players.MaxPlayers` is not scriptable.** The plot count follows it and nothing in code
  can set it — it is a Studio setting and it is on you. `[assert]` covers the derivation
  (`plotCountFor` clamps to `MinPlots`/`MaxPlots` and tracks `MaxPlayers` in range), not the
  setting.
- **`Lighting.Technology` is not script-writable at runtime.** It is set in the Rojo project
  file and the runtime assignment is wrapped in `pcall` so a paste-in install does not die
  on boot. `[nothing]`

### The belt

- **Nothing collidable may sit near the belt except the running surface.** Drops are driven
  by a `LinearVelocity` in Plane mode, which pins lateral velocity to zero, so they cannot
  drift off and rails were never load-bearing. Trim, end cap, turn trigger, dropper arm,
  spout, nozzle and upgrader beam are all `CanCollide = false`. `[nothing]`
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
  the same split, for the same reason, as the mezzanine's invisible guard behind its visible
  railing. `[nothing]`
- **`MACHINE_MASSES` is shared with `buildGhost`, and masses named `*Trigger` are filtered
  out of ghosts.** This is the ONE exception to "the ghost is built from the same
  description as the real machine", and it is named rather than being a quiet special case.
  `[nothing]`
- **A corner sensor is widened downstream, so its leading face stays put.** An early trigger
  is harmless at an upgrader or a collector; at a corner it cuts the corner. `[nothing]`
- **The belt has to physically fit the drops it carries**: ≤75% occupancy per belt, and total
  drops in flight summed across *every* floor within `MaxDropsPerPlot`, because `spawnDrop`'s
  counter is per plot. Over the cap it silently eats the income you just bought. `[assert]`
  "the plot carries %.0f drops at peak across %d belts".
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

### The second floor

- **A belt machine is either SLOTTED or PINNED, never both.** `slot` indexes
  `Layout.DropperDist`/`UpgraderDist`, which describe the ground floor's two legs and nothing
  else; anything on another floor names `path` plus `legIndex` and `legDistance`. `[assert]`
  "%s carries both a slot and a path".
- **A button carries `path` as an ID, not an index.** `pathIndex` is assigned at runtime by
  `addBeltPath`; Config cannot know it. `[assert]` "%s names belt path %q, which is not in
  Config.BeltPaths".
- **Every belt path is registered at plot construction, including floors nobody has bought.**
  A path is pure maths and registering one builds nothing — but buy buttons are built once, on
  first claim, and a button on the mezzanine needs its path to exist to know its own height.
  `[nothing]`
- **THE MEZZANINE FEEDS THE SAME REFINERY.** Upgraders are physical scanners on the ground
  floor's leg 2, so an upstairs drop crosses none of them; `Tycoon:onCollect` multiplies a
  drop from a path with no upgraders of its own by the plot's stack. Without that the floor
  is an additive term against a multiplicative curve — 17% of plot income on purchase, 0.02%
  by the end. `refineryMultiplierFor` already returns 1 for a path with its own upgraders.
  `[nothing]` for the mechanism; the income share it produces is asserted below.
- **The floor is EARLY BUT NOT FIRST**, and v5's "the floor is the halfway mark" is
  superseded. It is the purchase straight after `walls`, around minute six: anchored to
  `walls` *by name* plus a 6–20% band, with a 10-minute deadline because it gates three
  ladders (itself, weapons, armour) — the question stopped being "inside the session" and
  became "with a session left after it". `[assert]` three checks, each naming its own defect.
- **The floor's income share is measured at the moment of purchase**, so the band moved when
  its position did: 25–45% against three owned droppers, not 10–30% against seven.
  `mezz_dropper1.dropValue` is 12 for this reason and not 1400 — at 1400 the upstairs line
  would be 98% of plot income the second you bought it. `[assert]`
- **There is no `Floors.pads` table.** The ladder is a `TrussPart` at `Layout.GateCentre`, in
  front of the deck's front edge, and **the deck's front guard is built in two pieces with a
  gap over it** — a guard that closes the whole front edge is a ladder to nowhere, and there
  is nothing to see. `[assert]` ladder in front of the footprint, within stepping distance of
  the edge, railing gap over the ladder and wider than it, positive overshoot.
- **The ladder is floor furniture** and is checked as a BOX against every pedestal, pad and
  cabinet — its predecessor, the ground teleport pad, was the one piece of floor furniture
  nothing checked and it interpenetrated the armour cabinet's slot-2 pedestal by 3×1 studs.
  9×9 against 5×5 cannot be seen by a centre-distance rule. `[assert]`
- **`Config.floorBeltPath` states the collector's x** rather than deriving it from a piece of
  furniture (it used to read `pads.up.X - padClearance`), and the hopper must clear where the
  ladder lands you. `[assert]`
- **The deck's belt stays on the deck** — legs, the machine row outboard of each leg, and the
  buy-button row inboard of it. This is the check that caught `side = 10`, which needed 11.5.
  `[assert]`
- **The deck sits flush to the wall, clears the roof columns, and the shortened roof stops
  short of it; its pillars stand among the ground floor's machines** and must clear every
  dropper and upgrader slot — they miss the upgrader row today only because no
  `UpgraderDist` slot happens to land at z = −16, which is a coincidence, not a reason.
  `[assert]`
- **The roof is rebuilt when the floor lands.** It shrinks itself when the deck is up, which
  used to key off a prototype flag and so was the same answer for everyone forever; roof is
  minute 28 and floor is minute 6, so without the rebuild every player gets a half-roof.
  `[nothing]`

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
- **The yard's door can only be in the back-right corner.** The back edge of the plot IS the
  dropper row and the left side is the upgrader alley. `DoorFrom` is still 46 and the wall
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
- **Nothing goes in `self.cabinetSigns` that is not a cabinet.** `updateCabinetSigns`
  rewrites every entry with `"%s CABINET • %d/%d"`, which is why the yard's sign read
  "POWER CABINET • 0/4". `[nothing]`

### Walls, pads and floor furniture

- **Everything placed by absolute plot-local coordinate is checked inside the plot**, buy
  buttons and empty side-track slots included — the empty slots are where the next tier
  lands, and finding out then is finding out too late. `[assert]`
- **Floor furniture is checked against every other piece, against the rebirth/claim/spawn
  pads, and against both belt buy-button rows** — from both sources (the hand-placed
  `Layout.MiscButtons` column and the derived side-track columns) in one list, so a cabinet
  pedestal colliding with a misc pedestal is caught. Overlapping pedestals shipped once and
  stayed invisible only because the unlock chain hid one before the other appeared.
  `[assert]`
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
  order, so table order IS dependency order.** Restating it is what hid the fork:
  `dropper8` required `upgrader4` while `floor2 → mezz_dropper1` hung off `upgrader4` too, so
  the mezzanine was a dead-end branch you could skip entirely. The root count cannot see a
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
  cannot name a button on its own track (that is a chain link), must name a *factory* button
  (a side track gating a side track can deadlock), and the factory itself cannot be gated.
  `[assert]` four checks.
- **The cabinet gate is STICKY and derived**: owning any rung of a track counts as having it
  open. Rebirth wipes the factory — and so `floor2` — while keeping weapons and armour, so
  without that clause your first rebirth deletes both cabinets and leaves the shelf displays
  and the granted bat standing. `[nothing]`
- **Every button must be reachable, every bat and armour tier must be granted by exactly one
  button, and armour tier 1 must grant nothing** (it is the bare humanoid you spawn as, which
  is what keeps the raider-damage assertions honest). `[assert]`
- **Adding content is a Config edit, never a `Tycoon.lua` edit.** A row in a track table plus
  a distance gets you the button, machine, drop loop, save key, unlock dependency and HUD
  hint; a new `kind` needs a `Tycoon.INSTALLERS` entry and a new visual variant a
  `Config.Variants` row. `[assert]` `KNOWN_KINDS` mirrors the installers, and an unknown
  variant or structure fails the build.
- **A `Floor` button must be named by exactly one `Config.Floors` entry and must have a
  `Layout.MiscButtons` position**, or it charges and builds nothing, or gets built at the plot
  origin on the belt. `[assert]`
- **A buy button honours its own height.** `buttonBaseCF` is the single conversion —
  `buildButtons` used to build at `self:at(pos.X, 0, pos.Z)`, discarding a Y that
  `buttonPosition` had already worked out, and the conversion existed twice with both copies
  dropping it. That one zero is why nothing purchasable could stand on the mezzanine.
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
- **`WarningTime` is load-bearing and is not a pacing dial.** It is how long you have to get
  home: `WarningTime × Combat.WalkSpeed >= World.MinPlotRadius`. Shortening it is the obvious
  way to close the gap between waves and it is the wrong one — shorten `RestTime`. `[assert]`,
  and the failure message says so.
- **Dead air is 20–45 s measured from your clear, and `Waves.Interval` is gone.** Waves are
  paced by `RestTime` from the previous clear, not by a wall clock — the old fixed timer let
  two or three waves legally coexist and announced one wave's leftovers as the next. The
  CLEARED banner must not still be up when the next warning replaces it. `[assert]`
- **`MaxWaveTime` is a deadlock breaker and must not be able to fire during the spawn drip it
  backstops.** `StragglerGrace` must be positive for the same reason. `[assert]`
- **The leash is measured from the raider's HOME PATCH, and the number it has to clear is the
  plot EDGE**, which is `MinPlotRadius − PlotSize.Z/2`, not the radius the centre suggests.
  Checked across the supported player range because the ring clamps at low counts. `[assert]`
  "raiders could be dragged onto someone's factory".
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
- **Card-scale geometry belongs to `Config.UI`.** A 470×330 card written as a literal in
  `src/client` is a number the verifier cannot see, cannot scale-check and cannot fit against
  the panel next to it — which is how the upgrade shop came to sit on top of the NEXT UPGRADE
  panel with one of the two numbers in `HUD.lua` and the other in `UpgradeUI.lua`. `[lint]`
  `verify.py` "ui geometry", plus `[assert]` the shop/column overlap at the reference height.
- **A `UIScale` transforms its whole subtree**, so a shade at `fromScale(1,1)` inside a 0.62
  layer dims 62% of the screen and leaves a bright border. Both layers are sized
  `fromScale(1/scale)` to cancel exactly that. `[nothing]`
- **Do not re-apply the top inset.** `IgnoreGuiInset = false` already pushes the ScreenGui
  below the topbar; subtracting `GetGuiInset()` again is the classic double-inset bug.
  `[nothing]`
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
- The mezzanine's refinery multiplier: the income-share band is asserted, the mechanism that
  produces it is not.
- Non-square pad edge strips reading both `PlotSize` halves.
- A hand-typed `requires` on a factory row — the loader derives the chain, and nothing refuses
  a restatement, which is exactly how the mezzanine became a dead-end branch.

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
- The roof rebuild when the floor lands.
- The multiplier hook being an O(1) read on `Economy.add`.
- `Util.abbreviate`'s trailing-zero rule — three lines, and it shipped wrong once.

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
