# Tung Tung Tycoon — Handoff v2

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF.md`. That document is still right about the base game,
but everything it says about combat, plot geometry and the audio situation is
now out of date. Sections 3 and 5 here are the ones to read before you touch
anything.

---

## 1. What changed

Six stacked pull requests, each based on the one before it. **Merge them in
order** — rebasing one means rebasing everything above it.

| PR | Branch | What |
| --- | --- | --- |
| #1 | `plots-fewer-bigger` | fewer, bigger, further-apart plots |
| #2 | `combat-swings` | swings that move the character; damage on the strike frame |
| #3 | `plot-ergonomics` | ghost previews, three-state buttons, wayfinding |
| #4 | `depth-backlog` | `IDEAS.md` — the researched feature backlog |
| #5 | `prototypes` | six prototypes, all flag-gated off |
| #6 | `handoff-v2` | this document |

### #1 — Fewer, bigger, further-apart plots

Twenty-four small plots on two rings read as one continuous industrial estate.
You could not tell where your factory ended and your neighbour's began, and the
second ring put a third of the server behind a wall of other people's roofs.

|  | before | after |
| --- | --- | --- |
| plots | 6–24 | 4–10 |
| plot size | 88 × 104 | 120 × 140 |
| gap between plots | 20 | 44 |
| belt run | 142 studs | 204 studs |
| belt speed | 22 | 28 |

`plotPlacements` now solves for the radius that puts exactly `PlotGap` studs of
grass between neighbouring plot *edges*, clamped up to `MinPlotRadius`. The old
formula divided circumference by pitch — that is an arc, and neighbouring plot
centres are a **chord** apart, so it overstated the gap and under-spaced small
rings.

The belt is absolute, not proportional, so a bigger plot would otherwise just
have added empty margin. Leg 1 went 62 → 90 studs, leg 2 70 → 102. That is 45%
more time in flight, which would have put 74 drops on a belt capped at 70 and
silently eaten income — hence the speed bump. Belt speed doesn't affect income
(income is `dropValue / dropRate`), only latency and density, so raising it is
free.

Everything placed by absolute plot-local coordinate moved into `Config.Layout`,
where it scales with the plot and can be checked: the misc button column, the
rebirth pad, the claim pad, the owner spawn, the front-wall gateway.

> ⚠️ **Set the place's MaxPlayers to 10** in Game Settings. It is not
> scriptable, so nothing in code can enforce it; `PlotService` just leaves late
> joiners plotless until someone disconnects.

### #2 — Swings that move the character

The old swing tweened `Tool.Grip`, which is the offset of the engine's
RightGrip weld — so it rotated the bat inside a motionless hand. And the hitbox
was evaluated on the frame the swing *started*, a whole animation before the bat
visibly reached anything.

`SwingAnim.lua` drives the rig instead. Four swings cycle through the combo
(diagonal, backhand, sweep, overhead slam finisher). Damage lands on the strike
frame, sampled twice because one instantaneous box misses anyone a few frames
early or late. Raiders got the same treatment from the other side: they raise
the bat, hold, chop, and stand rooted through all of it — and the hit only lands
if you are still in range when it does, because otherwise the telegraph is a
lie.

A review pass found five real defects in that work before it shipped, including
that the raider telegraph was animating an invisible rig. They are fixed, and
the ones worth remembering are in §5.

### #3 — The plot reads as a plan you are filling in

Buy buttons have three states, not two: **available** (lit, touchable, the
cheapest wearing a Highlight and a light column), **preview** — the next three
steps, dimmed and inert, with a translucent ghost of the machine standing where
it will go — and **hidden**. Both obvious designs fail: showing everything gives
the plot no focal point, showing only the next one hides the shape of the build.

Labels carry four lines, and the effect line is measured rather than written:
`incomePerSecond` takes an optional "pretend I also own this" id and the button
quotes the delta. A price alone is a cost with no stated benefit, and for an
upgrader the benefit is not even guessable — *x1.85 of an unknown number is not
information*.

### #4 — `IDEAS.md`

A researched backlog rather than a wish list, with the evidence attached so you
can disagree with the reasoning instead of guessing at it. Read it before
planning anything. Its top finding is that **rebirth is the weakest system in
the game** — it grants one number where every well-regarded tycoon grants four
things at once — and its second is that **the build is 88 minutes against a
genre benchmark of 30–60**.

### #5 — Prototypes

See §6.

---

## 2. Running it

Unchanged: `rojo serve`, or `python3 tools/pack.py` and paste the two generated
files. Studio Access to API Services on, or saving is memory-only.

**MaxPlayers should now be 10, not 50.**

---

## 3. Run the verifier before you commit

```bash
python3 tools/verify.py        # needs luau, luau-compile, luau-analyze on PATH
```

`brew install luau` gets all three on macOS.

Four passes: syntax on every file, static analysis, **720 config assertions**,
and a rebuild of the packed output. CI runs the same thing and also fails if
`build/` is stale.

The count moved from 2,746 to 720 because the plot-overlap suite is O(n²) over
the supported player range and that range shrank from 6–24 to 4–10. **Coverage
went up.** This pass added assertions for: swing timing and input-to-damage
latency, raider telegraph length and worst-case time-to-kill, floor furniture
staying inside the plot, misc buttons not stacking on the buy-button rows, the
vault not pushing through the front wall, the gateway opening onto the aisle the
owner spawns on, real chord clearance between neighbouring plots, and the whole
prototype config surface.

**Three of those caught real shipped bugs while being written.** That is the
argument for adding one whenever you fix something geometric.

---

## 4. Where things live

| File | Own it when you're changing… |
| --- | --- |
| `shared/Config.lua` | **every tunable number**, plus the whole prototype surface |
| `shared/SwingAnim.lua` | melee swing choreography — procedural, client-side |
| `shared/TungModels.lua` | the procedural models: character, drop, NPC rig, bat |
| `shared/Fx.lua` | particles, lights, sounds, floating text |
| `shared/Sound.lua` | *(prototype)* pooled engine-asset audio |
| `shared/Utilities.lua` | *(prototype)* shared upgrade/utility maths |
| `shared/Util.lua`, `Net.lua`, `Req.lua` | helpers, remotes, module locator |
| `server/Tycoon.lua` | **the tycoon** — belt paths, machines, buttons, ghosts, drops |
| `server/MapBuilder.lua` | world, arena, lighting, plot pads |
| `server/CombatService.lua` | bats, swings, damage, knockback, PvP zoning |
| `server/NPCService.lua` | raid waves, raider AI, the attack telegraph |
| `server/PlotService.lua` | claiming, releasing, respawn placement |
| `server/Economy.lua` | the only place cash is created or spent |
| `server/DataService.lua` | DataStore load/save |
| `server/FloorService.lua` | *(prototype)* the second floor |
| `server/UpgradeService.lua` | *(prototype)* player upgrades, utility slot |
| `server/SessionService.lua` | *(prototype)* offline, daily, playtime, boost |
| `client/HUD.lua` | cash, next-upgrade hint, toasts, wave banner, rebirth modal |
| `client/CombatClient.lua` | hitmarkers, camera shake, knockback, swing prediction |

`Tycoon.lua` is still the contention hotspot. If two tracks both need it, split
by function, not by line range — that worked cleanly for this pass.

---

## 5. Invariants — the landmine list

Everything in `HANDOFF.md` §5 still applies **except** the bat-swing entry,
which is now wrong. These are the additions. Every one is a bug that was shipped
and fixed, and most fail *silently*.

### Procedural animation

- **Write `Motor6D.Transform`, not `C0`, on player characters.** `Transform` is
  the channel the Animator writes into every frame, so setting it replaces the
  playing animation's contribution and leaves the rest pose alone. Writing `C0`
  fights the default `Animate` script and permanently deforms the rig.
- **Bind after `Enum.RenderPriority.Character`.** That is where the engine
  applies character animation; anything written before it is overwritten in the
  same frame. Same class of bug as the camera shake, one stage earlier.
- **Express poses in torso space and conjugate per joint:**
  `Transform = C0.Rotation:Inverse() * Q * C0.Rotation`. R6 and R15 bake
  completely different rotations into their shoulder `C0`s, so a raw joint-space
  angle that raises an R15 arm forwards swings an R6 arm out *sideways*.
- **R6's `RootJoint` is not R15's `Waist`.** Every R6 limb joint hangs off the
  Torso, so a rotation at the root carries the arms, legs and head with it — the
  character bodily leans, feet swinging, instead of twisting at the middle. The
  torso channel is yaw-only and damped on R6 for exactly this reason.
- **`Motor6D.Transform` does not replicate.** Every client draws every swing
  locally: the attacker predicts theirs from `Tool.Activated` (which fires
  client-side too, so it costs no remote) and everyone else plays it from the
  `SwingFx` broadcast. Do not "fix" this by moving it server-side; there is
  nothing to move.
- **The raider rig is entirely invisible.** Every part built by `rigPart` is
  `Transparency = 1` — the R6 rig exists only so `Humanoid`, `MoveTo` and damage
  work. The guy you see is the `Visual` model. Animating
  `Torso["Right Shoulder"]` rotates a stick nobody can see; the visible right arm
  hangs off a Motor6D named `TungArm`, and that is the joint to drive.

### Combat

- **Damage lands on the strike frame, not the click.** `Combat.SwingStrikeAt` is
  the delay, and the verifier caps the resulting latency at 250 ms per bat.
- **`hitscan` must walk up to the model that owns a Humanoid**, not stop at the
  first `Model` ancestor. A raider's visible body is a sub-model of the rig and
  its arm is a sub-model of that.
- **Absolute damage caps must not be scaled by the boss multiplier.**
  `Waves.MaxDamage` carried the comment *"never let a raider 2-shot"* while the
  cap itself was multiplied by `BossDamageMultiplier`, so a late boss hit for 61
  and killed a full-health player in two swings.
- **A deferred strike must re-check the attacker, not just the character.**
  `canDamage` lets anyone hit an NPC without looking at the attacker at all, so
  a departed player's scheduled swing still landed.

### World geometry

- **Plot spacing on a ring is a chord, not an arc:** `2r·sin(π/n)`, not
  `2πr/n`. The arc formula overstates the gap between neighbours.
- **Non-square pads need both halves.** The pad's edge strips were positioned at
  `PlotSize.X / 2` on all four sides; on a 120 × 140 pad the front and back
  strips floated 8 studs inside the border they were meant to draw.
- **Carry a belt leg's outboard side, don't infer it.** "Take the perpendicular
  pointing away from the plot origin" holds only while every leg hugs an outer
  edge, and inverts for any leg whose midpoint sits near the centre — which is
  exactly what an upper floor's return leg does.
- **`Highlight` is capped at 255 per client and disabled instances still occupy
  a slot.** Delete them, don't disable them. There is one per plot, reparented.

### Tooling

- **`Vector3` in `tools/verify_config.lua` is a stub with no arithmetic.** Any
  Config code that calls `.Magnitude`, `.Unit`, or does Vector3 maths *at require
  time* crashes the verifier. Store them as data only.
- **A new profile field is invisible until it is in `DataService` twice** — once
  in `defaultProfile()` (reconcile only copies keys that exist there, and only
  when the types match) and again in the explicit `save()` payload. A field
  defaulting to `nil` is not even iterated by `pairs`, so it is silently
  discarded on every load; default to `""` or `{}` instead.
- **`Players.MaxPlayers` is not scriptable.** The plot count follows it, but
  nothing in code can set it. It is a Studio setting and it is on you.

---

## 6. The prototypes

All in `Config.Prototypes`, all defaulting to `false`. A build with every flag
off is byte-for-byte the game that ships today, and the verifier asserts they
are all off so nobody can leave one on by accident.

| Flag | What it turns on |
| --- | --- |
| `Floors` | a second storey with its own dropper → belt → vault loop |
| `PlayerUpgrades` | walkspeed / magnet / payout / auto-collect shop |
| `Utilities` | a second slot holding a verb rather than a stat |
| `RebirthPerks` | rebirth grants four things instead of one number |
| `Offline` | offline earnings and the welcome-back panel |
| `Sessions` | daily streak, playtime ladder, boost cooldown |
| `Sound` | the engine-asset sound layer |

### What is genuinely done

**The belt is a polyline.** `Config.BeltPaths` is a list of points; `buildBelt`
emits one run per leg and one turn sensor per corner; `onTurn` advances N→N+1.
Drops carry a `Path` attribute alongside `Leg` so one floor's corner sensor
ignores another floor's drops. With one path configured this is byte-identical
to the old L, including the deliberate corner overlap that stops the two runs
meeting at a hairline seam. **This is useful on its own, flag or no flag** — it
is the enabler for every multi-line idea in `IDEAS.md` P2.

**Floor 2** is an open mezzanine over the back half of the plot, offset rather
than stacked, unlocking on the last button of the ground floor in the same
currency. Teleport pads sweep their volume with `GetPartBoundsInBox` and move
every Humanoid they find.

**The utility slot is a keybind, not a Tool.** Roblox equips one Tool at a time,
so a Tool would mean putting the bat away to freeze a pack of raiders — exactly
the moment you need it. Freeze roots raiders by anchoring the assembly, because
`NPCService` rewrites `WalkSpeed` every Heartbeat and an external
`WalkSpeed = 0` survives less than a frame.

**Offline earnings** derive income server-side from persisted plot state, never
from a stored or client-supplied number, and use `os.time()` rather than
`tick()`. Nothing is auto-credited: the claim is the reward, and the panel says
whether the cap clipped you and names the upgrade that would have prevented it.

**Sound was never actually blocked.** `rbxasset://sounds/*` ships inside the
Roblox client — no upload, no moderation, and it cannot be taken down. The old
handoff's Track A was wrong about this. `Sound.lua` pools and round-robins a
fixed number of instances per sample instead of allocating per drop.

### What is not done — read this before you turn a flag on

- **None of it has run in Roblox.** Each track verified its logic against
  stubbed harnesses and its geometry against AABB sweeps. **No UI has ever been
  rendered**; sizing, wrapping and scroll behaviour are unproven.
- **The mezzanine's income is invisible to `incomePerSecond()`**, which walks
  `Config.ButtonById`. The vault sign under-reports once the floor is running.
- **The rebirth capacity bump is computed but not consumed.** The TODO names its
  consumer exactly: the `MaxDropsPerPlot` guard in `Tycoon:spawnDrop`.
- **`magnet` and `autocollect` have no consumer either.** They are readable
  state with TODOs naming the collector loop that should read them.
- **`decoy` is a stub.** Making it real means changing `NPCService.nearestPlayer`,
  which only scans `Players:GetPlayers()`.
- **The offline cap upgrade is persisted but nothing sells it.** It belongs in
  the upgrade shop.
- **Rebirth grants land up to a second late**, because `Tycoon:rebirth()` was off
  limits to the track and rebirths are detected by polling instead.
- **The deck is a ceiling over the ground floor's back half.** The shipped roof
  already covers that area so it is not a regression, but it is the camera
  problem `IDEAS.md` warns about, inherited rather than introduced.
- **Drop budget under two floors is untested.** `MaxDropsPerPlot = 70` is per
  plot and the ground floor already peaks at 58 — and the mezzanine unlocks
  exactly at that peak.

---

## 7. What is still open

- **DataStore session locking is still missing.** Two servers can load the same
  profile and the last save wins. Untouched by this pass, and still the
  highest-severity item in the repo. It also blocks trading, which is why
  `IDEAS.md` puts trading in P3.
- **The price curve is still 88 minutes** against a 30–60 minute genre
  benchmark. `IDEAS.md` P0 #2 has the formula, and the verifier already prints
  the curve, so this is a Config edit and a re-run.
- **No runtime tests.** The verifier covers config and static analysis. Nothing
  exercises the actual game loop, and none of the swing animation has ever run
  in Studio — the maths is derived and reviewed, not observed. A headless smoke
  test is the highest-leverage thing nobody has scoped.
- **Part budget at full scale is untested.** Ghost previews and floor chevrons
  both added parts per plot. Worst case is now 10 plots × 70 drops × 2 parts,
  plus machines, ghosts, chevrons and — with the flag on — a second floor.
- **Raider pathfinding is still naive** `Humanoid:MoveTo` with a jump-if-stuck
  hack. It will snag on plot walls. `PathfindingService` is the obvious upgrade.

---

## 8. Conventions

Unchanged from v1, plus one:

- **Verifier before commit.** CI enforces it, along with `build/` being
  regenerated (`python3 tools/pack.py`) whenever `src/` changes.
- **`src/` is the source of truth.** `build/` is generated output that happens to
  be committed, because it's the deliverable for the no-Rojo install path.
- **Commit messages explain the *why*,** especially for anything in §5 — those
  fixes look arbitrary without the reason attached.
- **Config over code.** If a change can be a `Config.lua` edit, make it one.
- **When you fix something geometric, add the assertion.** Three of the bugs
  fixed in this pass were found by writing the check, not by playing the game.
