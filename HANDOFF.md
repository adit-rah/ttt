# Tung Tung Tycoon — Handoff

**Repo:** `github.com/adit-rah/ttt` · **Branch:** `main`
**State:** playable end to end. Claim a plot → buy droppers → watch Tung guys ride the
conveyor through upgraders into your vault → fight raid waves with a bat → rebirth.
**Size:** ~5,200 lines of Luau across 17 files, plus ~640 lines of Python/Luau tooling.

This note is written for whoever picks up the next chunk of work. Sections 4 and 5 are
the ones worth reading before you touch anything — they're the landmines we already
stepped on.

---

## 1. Commit history so far

| Commit | What |
| --- | --- |
| `14d4ed0` | base game — full tycoon, combat, waves, persistence |
| `5666b4e` | `.gitignore` + CI running the verifier |
| `f4e2351` | fix z-fighting; plots scale to player cap; clear the claim pad |
| `e1178ba` | plots much closer; claim beacon; respawn on your own plot |
| `0a6ee24` | belt moved to the plot border; heights lowered; arena pruned; plain Tools |
| *(pending)* | seamless conveyor — nothing solid near the belt |

---

## 2. Running it

**Rojo:** `rojo serve`, connect from the Studio plugin. `default.project.json` maps
`src/shared` → `ReplicatedStorage.TungShared`, `src/server` → `ServerScriptService.TungServer`,
`src/client` → `StarterPlayer.StarterPlayerScripts.TungClient`, and sets Lighting.

**No Rojo:** `python3 tools/pack.py`, then paste `build/PasteInto_ServerScriptService.server.lua`
into a `Script` in ServerScriptService and `build/PasteInto_StarterPlayerScripts.client.lua`
into a `LocalScript` in StarterPlayerScripts.

**Studio settings that matter:**
- *Security → Studio Access to API Services* — on, or saving is memory-only (the game
  still runs, it just won't persist).
- *MaxPlayers* — the plot count follows it, clamped to 6–24. Default 50 → 24 plots.

---

## 3. Where things live

| File | Lines | Own it when you're changing… |
| --- | --- | --- |
| `shared/Config.lua` | 462 | **every tunable number.** Prices, variants, layout, waves, combat |
| `shared/TungModels.lua` | 543 | the procedural Sahur models: character, drop, NPC rig, bat |
| `shared/Fx.lua` | 315 | particles, lights, sounds, floating text, bursts |
| `shared/Util.lua` | 143 | number formatting, welding, small helpers |
| `shared/Net.lua` | 77 | RemoteEvent declarations |
| `shared/Req.lua` | 93 | module locator (see §5, do not restructure casually) |
| `server/Tycoon.lua` | 1263 | **the tycoon itself** — belt, machines, buttons, drops, rebirth |
| `server/MapBuilder.lua` | 276 | world, arena, lighting, plot pads |
| `server/CombatService.lua` | 375 | bats, swings, damage, knockback, PvP zoning |
| `server/NPCService.lua` | 315 | raid waves and raider AI |
| `server/PlotService.lua` | 200 | claiming, releasing, respawn placement |
| `server/Economy.lua` | 183 | the only place cash is created or spent |
| `server/DataService.lua` | 206 | DataStore load/save |
| `server/Main.server.lua` | 87 | boot order |
| `client/HUD.lua` | 505 | cash, next-upgrade hint, toasts, wave banner, rebirth modal |
| `client/CombatClient.lua` | 110 | hitmarkers, camera shake, knockback application |
| `client/Main.client.lua` | 13 | client entry |

`Tycoon.lua` is the contention hotspot — if two tracks both need it, split by function,
not by line range.

---

## 4. Run the verifier before you commit

```bash
python3 tools/verify.py        # needs luau, luau-compile, luau-analyze on PATH
```

Four passes: syntax on all 17 files, static analysis, **2,746 config assertions**, and a
rebuild of the packed output. CI runs the same thing on push and PR, and also fails if
`build/` is stale.

The config pass is not just schema checking. It **simulates the economy purchase by
purchase** and **models belt occupancy**, and it fails the build on:

- a first dropper you can't afford from `StartingCash` (the game would deadlock)
- any single purchase costing more than 15 minutes of grind
- a total build outside 45–150 minutes
- belt occupancy over 75%, or more drops in flight than `MaxDropsPerPlot`
- machines spaced closer than their own footprint
- buy buttons or the belt too tall to step over
- plots overlapping at *any* player count from 6 to 24
- two horizontal world surfaces sharing a Y

It prints the progression curve as a bar chart. Current numbers: 88 min full build, first
rebirth at ~98 min, belt 54% full at peak.

**This catches in one second what otherwise takes an hour of grinding to notice.** If you
retune anything, run it first.

---

## 5. Invariants — the landmine list

Every one of these is a bug we already shipped and fixed. They are all easy to
reintroduce and most fail *silently*.

**World geometry**
- **Every horizontal surface needs its own Y.** Ground, arena floor and plot pads all sat
  at exactly `y=0` and the surfaces tore as the camera moved. See `World.GroundTopY` /
  `ArenaFloorTopY` / `PlotSurfaceY`. Plot-local `y=0` is the *top of the pad*, not the ground.
- **Derive tile size from tile spacing.** The old ring path used a fixed 26-stud width on
  21.3-stud spacing, so every tile overlapped its neighbour and z-fought.
- **`Lighting.Technology` is not script-writable at runtime.** It's set in the Rojo project
  file; the runtime assignment is wrapped in `pcall` so a paste-in install doesn't die on boot.

**The conveyor**
- **Nothing collidable may sit near the belt except the running surface.** Drops are driven
  by a `LinearVelocity` in Plane mode, which pins lateral velocity to zero — they cannot
  drift off. Rails were never load-bearing, and because each leg drew them full-length they
  crossed the *other* leg's path. Trim, end cap, turn trigger, dropper arm, spout, nozzle
  and upgrader beam are all `CanCollide = false`. Keep it that way.
- **Overhead parts need real headroom** over the tallest variant (infinity, 2.23 studs on
  the belt). Minimum clearance is currently 0.7 studs.
- **The vault must sit downstream of the collector sensor.** There's a runtime `assert` in
  `buildCollector`; if the shell overlaps the run-off it walls the belt off and nothing can
  ever be collected.
- **`PivotTo` overwrites the PrimaryPart's rotation.** Bake the upright orientation into the
  target CFrame or every drop spawns lying on its side.
- **Belt speed does not affect income** (income is `dropValue / dropRate`), only latency and
  density. Raising it to fix crowding is free.

**Combat**
- **Knockback on players must be applied client-side.** The victim's own client owns their
  character's physics, so a server `ApplyImpulse` is discarded on the next replication tick.
  Server→client via the `Knockback` remote; NPCs are server-owned so they're impulsed directly.
- **Camera shake must bind after `Enum.RenderPriority.Camera`.** On `RenderStepped` it runs
  before the camera module and gets overwritten every frame.
- **The bat swings via `Tool.Grip`, never an animation.** Grip is the offset of the built-in
  RightGrip weld, so tweening it moves the bat inside the hand and leaves the rig alone.
  *(Roblox's default `Animate` script still raises the arm for any equipped tool — that's the
  hold pose, not our swing. Removing it means overriding the character's `toolnone` animation.)*

**Economy & data**
- **`StartingCash` must cover the cheapest requirement-free button.** With no dropper there
  is no income, so a fresh player could never buy their first one. Asserted by the verifier.
- **Rebirth payout compounds** (`MultiplierPerRebirth ^ rebirths`). A linear bonus against a
  geometric cost curve dead-ends the prestige loop after two or three.
- **`DataService` refuses to save a profile whose load failed.** Better to lose a session than
  overwrite a real save with a default one. Don't "fix" this.

**Roblox API traps**
- **`FindFirstChild` is not recursive.** The plot totem silently never updated for this reason.
- **A per-plot `SpawnLocation` joins the random-spawn pool** and would send other players to
  your factory. Respawn placement is a reposition on `CharacterAdded` instead.
- **`Util.abbreviate` trims trailing zeros only past a decimal point.** Trimming
  unconditionally turned `320` into `32`, so 320K rendered as 32K.

**Project structure**
- **The `Req` bootstrap line must stay byte-identical** in every module:
  ```lua
  local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
  ```
  `tools/pack.py` pattern-matches it to flatten the tree for the no-Rojo build. Import
  siblings with `Req("Name")`.

---

## 6. Adding content

The tycoon is data-driven. **You should never edit `Tycoon.lua` to add a dropper.** Add a
row to `Config.Buttons` and a distance to `Config.Layout.DropperDist`:

```lua
{
    id = "dropper11", name = "Hyper Tung", price = 20000000000,
    kind = "Dropper", slot = 11, variant = "infinity", requires = "dropper10",
    dropValue = 1000000, dropRate = 1.0,
    blurb = "tung beyond tung.",
},
```

The button, machine, drop loop, save key, unlock dependency and HUD hint all follow.

| `kind` | needs | builds |
| --- | --- | --- |
| `Dropper` | `slot`, `variant`, `dropValue`, `dropRate` | machine + spout + drop loop on belt leg 1 |
| `Upgrader` | `slot`, `variant`, `multiplier` | scanner over belt leg 2 |
| `Belt` | `speedBonus` | speeds up the conveyor |
| `Structure` | `structure` (`walls`/`roof`) | plot buildout |
| `Gear` | `grants` (a `Config.Bats` id) | anvil + weapon upgrade |

New `kind` → add an entry to `Tycoon.INSTALLERS`. New visual variant → add to
`Config.Variants`; the `fx` key selects a recipe in `Fx.lua`.

**Design note worth revisiting:** every button `requires` the previous one, so the chain is
strictly linear and **exactly one buy button is visible at a time**. That's a deliberate
guided-progression choice, but branching the tree (e.g. droppers and upgraders as parallel
lines) is a real design option and would change how the plot reads.

---

## 7. Suggested parallel tracks

Split to minimise file contention. Each track owns its files; coordinate before touching
someone else's.

### Track A — Audio *(the biggest quality win available)*
**Owns:** `shared/Fx.lua`
Sounds are the weakest part of the build. Roblox can't synthesise audio at runtime, so a
zero-upload game gets engine defaults — currently a pitched `electronicpingshort.wav` for
the "tung" and `impact_water.mp3` for hits. They work and they sound like it.
Everything routes through `Fx.tung()` and `Fx.impact()`, so it's a two-line swap once real
samples are uploaded; per-variant pitch variation is already wired up.
**Also:** swing whoosh, vault payout sting, wave-incoming siren, rebirth stinger.

### Track B — Combat depth
**Owns:** `server/CombatService.lua`, `server/NPCService.lua`
- Raider AI is naive `Humanoid:MoveTo` with a jump-if-stuck hack. It will path badly around
  plot walls. `PathfindingService` is the obvious upgrade.
- Boss telegraphs, wind-up animations, an actual boss moveset.
- Ragdoll on death (currently Motor6Ds are just disabled and the model flops).
- More bat tiers, block/parry, a dodge roll.

### Track C — Economy & progression
**Owns:** `shared/Config.lua` *(balance sections only)*
- More dropper/upgrader tiers past `dropper10`.
- Rebirth perks beyond the flat multiplier (permanent unlocks, cosmetics).
- Offline earnings — `profile.playtime` is already tracked and unused.
- **Run `tools/verify.py` after every change**; it will tell you immediately if the curve breaks.

### Track D — UI/UX
**Owns:** `client/HUD.lua`, `client/CombatClient.lua`
- Per-plot stats panel (income/sec, owned count, time to next purchase).
- Upgrade preview on the buy button before you can afford it.
- Mobile layout pass — the HUD is desktop-first and untested on phone.
- Leaderboard, KO feed, wave progress bar.

### Track E — World & art
**Owns:** `server/MapBuilder.lua`, `shared/TungModels.lua`
- The arena was pruned hard for MVP; it's now floor + plinth + statue + sign. Rebuild it
  with intent rather than restoring the old decoration.
- Plot visual themes tied to rebirth count.
- Model polish: the Sahur silhouette is deliberately simple and could carry a lot more
  character.

### Track F — Infrastructure & persistence
**Owns:** `server/DataService.lua`, `server/PlotService.lua`
- **No session locking.** Two servers can load the same profile and the last save wins.
  This is the most serious known gap. ProfileStore or an equivalent lock is the fix.
- Analytics on the progression funnel.
- Anti-exploit review — the server is authoritative everywhere, but nobody has tried to
  break it.

---

## 8. Known gaps and risks

- **DataStore session locking is missing** (Track F). Highest-severity item on this list.
- **Sounds are placeholders** (Track A).
- **NPC pathfinding is naive** — raiders will snag on plot walls once walls are bought.
- **No runtime tests.** The verifier covers config and static analysis; nothing exercises
  the actual game loop. A headless smoke test would be valuable and nobody has scoped it.
- **Part budget at full scale is untested.** Worst case is 24 plots × 70 drops × 2 parts ≈
  3,400 moving parts, plus machines. It has not been load-tested with a full server.
- **Assets:** every model, face and UI element is generated in code — no toolbox
  dependencies. The only non-original references are three engine particle textures, two
  engine sounds and Roblox's built-in fonts, all `rbxasset://` (they can't be moderated away).

---

## 9. Conventions

- **Verifier before commit.** CI enforces it, along with `build/` being regenerated
  (`python3 tools/pack.py`) whenever `src/` changes.
- **`src/` is the source of truth.** `build/` is generated output that happens to be
  committed, because it's the deliverable for the no-Rojo install path.
- **Commit messages explain the *why*,** especially for anything in §5 — those fixes look
  arbitrary without the reason attached.
- **Config over code.** If a change can be a `Config.lua` edit, make it one.
