# ARCHITECTURE

The module map. Every file in `src/`, what it owns, who requires it, and the
four ownership boundaries the code actually obeys.

Read this instead of grepping `Req(` calls. `README.md` §"Layout of the code"
names all 42 files in one line each and points here; it carries no dependency
information, and this file is where that lives.

- **What must not break** → `INVARIANTS.md`
- **How each rule was arrived at** → the `HANDOFF_*.md` chain
- **Where to change what** → §6 below, and `../../CLAUDE.md`

---

## 1. The shape

Three source roots, each mapped by `default.project.json` to one Roblox
container:

| Source root | Roblox location | Rojo folder | Files |
| --- | --- | --- | --- |
| `src/shared` | `ReplicatedStorage` | `TungShared` | 10 |
| `src/server` | `ServerScriptService` | `TungServer` | 15, plus `tycoon/` (12) |
| `src/client` | `StarterPlayer.StarterPlayerScripts` | `TungClient` | 6 |

`src/server/tycoon/` is the only nested folder, and it is nested because `Req`
allows exactly one level (`Req.lua:54-62`): `Req("Tycoon")` resolves to
`tycoon/Tycoon.lua` and every sibling in that folder is reachable by name from
anywhere. Two consequences worth knowing before adding a second folder:
`tools/pack.py` collects with `rglob`, and **a module's filename stem is its
global name** — the packed build is one flat `__MODULES[stem]` namespace, so two
files with the same stem in different folders would shadow each other. `pack.py`
fails the build on that, naming both paths.

`default.project.json` also sets Lighting, `Workspace.FilteringEnabled` and
`SoundService.RespectFilteringEnabled`. There is no `.rbxm` anywhere: the entire
world, every model and every UI element is built from code at runtime
(`MapBuilder`, `TungModels`, `Tycoon`, `HUD`).

### Two build paths

1. **Rojo** — `rojo serve` / `rojo build` against `default.project.json`. The
   normal development path.
2. **`tools/pack.py`** — flattens the tree into two paste-in scripts for people
   without Rojo:
   - `build/PasteInto_ServerScriptService.server.lua` (a `Script`), built from
     `[src/shared, src/server]`
   - `build/PasteInto_StarterPlayerScripts.client.lua` (a `LocalScript`), built
     from `[src/shared, src/client]`

   **`src/shared` is compiled into BOTH.** That is why `UiKit.lua` lives in
   `src/client` and not `src/shared` — read its header (`src/client/UiKit.lua:1-25`):
   `Req` searches `TungShared` then `TungClient`, so `Req("UiKit")` resolves
   from the client root anyway, and putting it in `shared` would hand the server
   a vocabulary for screen UI it must never draw. `Analytics.lua` is in
   `src/server` for the mirror-image reason (`src/server/Analytics.lua:4-11`):
   `AnalyticsService` is server-only and fails *silently* on the client, so a
   shared module would let a `LocalScript` send nothing, forever, with no
   symptom.

### The import convention

Every module — client, server and shared alike — opens with exactly this line:

```lua
local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
```

**It must stay byte-identical.** `tools/pack.py:26-30` pattern-matches it with a
regex (`pack.BOOTSTRAP`) and rewrites it to `local Req = __Req`, a lookup into
the flattened module table. `tools/test.py` imports `pack` and reuses *the same
regex object* (`tools/test.py:41`, `tools/test.py:104`) so that "if anyone
changes the canonical import line, the packer and the harness must break
together rather than one of them silently drifting". Reformat that line and both
the paste build and the entire spec suite stop seeing imports.

`src/shared/Req.lua` itself is a ~90-line locator: search order
`TungShared` → (`TungServer` if server, `TungClient` if client), one level of
folder nesting allowed, results cached, and it **re-raises** a failed require
with the module name (`Req.lua:82-84`). That re-raise is load-bearing: a module
that throws at load takes down whatever required it, which is how a deleted
`Req("Config")` in `SessionUI.lua` killed the whole client at boot in #50 (see
`tools/verify.py`'s `ROBLOX_GLOBALS` comment).

---

## 2. Every module in `src/`

"Required by" is the exact set of modules that call `Req("X")` in live code
(comments and docstrings excluded). Entry scripts are `Main.server` /
`Main.client`.

### `src/shared` — replicated to everyone, in BOTH paste builds

| Path | Responsibility | Required by | Must not |
| --- | --- | --- | --- |
| `Req.lua` | Module locator. Position-independent imports; caches; re-raises load failures. | *(the bootstrap line, not `Req()`)* | — |
| `Config.lua` | **Every tunable number**, all geometry, all button/track/wave/analytics data, plus derived lookups (`ButtonById`, `Tracks`, `TrackRank`, `powerFactor`) and the shell's geometry functions (`storey`, `wallExtent`, `wallSegments`, `wallBays`, `roofUnderside`, `shellPartCount`). 2,810 lines. | 26 modules — everything except `Util`, `Net`, `Req`, `Main.client` | require anything (it is the graph root); hold anything that is not data or a pure derivation — `tools/verify_config.lua` executes this file against stubs and nothing else |
| `Util.lua` | Number abbreviation, welding, `platformFrom`, misc helpers. No Roblox services. | 15 modules | — |
| `Net.lua` | Declares `Net.NAMES` and hands out RemoteEvents; server creates them eagerly, client waits. | 14 modules | require anything (it is the other graph root) |
| `Style.lua` | The only place `Config.Style` becomes instances. Every label in the world and on screen. | `FloorService`, `Fx`, `HUD`, `MapBuilder`, `SessionUI`, `TungModels`, `Tycoon`, `UiKit`, `UpgradeUI` | — |
| `Sound.lua` | The whole audio layer, on `rbxasset://sounds/*`. Fixed pools per name; one SoundGroup. Gated on `Config.Prototypes.Sound`. | `Fx`, `SessionUI` | `Instance.new("Sound")` per event (≈400 live Sounds is where A/V desync starts) |
| `Fx.lua` | Particle / light / sound recipes, on built-in engine textures. | `CombatService`, `NPCService`, `TungModels`, `Tycoon`, `UpgradeService` | reference an uploaded asset |
| `TungModels.lua` | Procedural Sahur models: character, drop, NPC rig, weapon, statue. Faces along `-Z`. | `CombatService`, `MapBuilder`, `NPCService`, `Tycoon` | reference an uploaded asset |
| `ShopMath.lua` | Price curves and lookups for `Config.PlayerUpgrades` and `Config.Utilities`. Pure maths, wire-safe. Was `Utilities.lua`; renamed because it sat one letter from `Util.lua` and neither name said what it did. | `UpgradeService`, `UpgradeUI` | create Instances or touch remotes — it runs on both sides and the server treats its own result as authority |
| `SwingAnim.lua` | Procedural melee swings written into `Motor6D.Transform` on `RunService.PreSimulation`. | `CombatClient` **only** | use `BindToRenderStep`/`PreRender` (that was a silent no-op for the whole first version) or write `C0` |

**Oddity:** `SwingAnim` has exactly one requirer and it is a client module, yet
it lives in `shared` and is therefore compiled into the server paste build too.
The `UiKit` argument applies to it; nothing depends on it not being moved.

### `src/server`

| Path | Responsibility | Required by | Must not |
| --- | --- | --- | --- |
| `Main.server.lua` | Boot order. Requires 16 modules, then 6 numbered phases. | *(entry `Script`)* | reorder §5's numbered comments without reading them — three of them are bug fixes |
| `DataService.lua` | DataStore persistence: session locking (`stored.__lock`, inside the record), retries, autosave, shutdown flush, in-memory fallback. | `AdminService`, `Analytics`, `CombatService`, `Economy`, `NPCService`, `SessionService`, `Tycoon`, `UpgradeService`, `VaultService`, `Main.server` | put the lock in a second key (no cross-key transaction); add a `PROFILE_VERSION` bump for `__lock` — `reconcile()` iterates a fresh DEFAULT's keys so `__` fields are structurally invisible |
| `Economy.lua` | The single place cash is created, spent and replicated. Owns `profile.cash` and the `Stats` remote. | `AdminService`, `CombatService`, `NPCService`, `PlotService`, `SessionService`, `SocialService`, `Tycoon`, `UpgradeService`, `Main.server` | require `SocialService`, `SessionService` or `UpgradeService` — they register through `Economy.setMultiplierHook(name, fn)` precisely so this arrow never reverses |
| `Analytics.lua` | The seven events, one choke point (`Analytics.emit`), schema from `Config.Analytics`. | `SessionService`, `Tycoon`, `Main.server` | live in `src/shared`; log an economy event per collected drop (≈10/sec/player) |
| `MapBuilder.lua` | The whole world at runtime: arena, plot pads, ring layout, lighting. | `Tycoon`, `Main.server` | — |
| `tycoon/` | **One plot**, as twelve modules over one class table — see the sub-table below. `Req("Tycoon")` resolves to `tycoon/Tycoon.lua`, the aggregator, and that is the whole public surface. | `FloorService`, `GateService`, `PlotService`, `VaultService` | require `SessionService`, `PlotService` or any service that requires it; grow a hard-coded content case — add a `Config.Buttons` row instead (§4) |
| `PlotService.lua` | Owns the `Tycoon` instances and who stands on what: claim pads, `autoAssign`, release with offline grace, `teleportToPlot`, the `RequestRebirth`/`RequestReset` remotes, and a 3s signage refresh. | `AdminService`, `Main.server` | — |
| `CombatService.lua` | Bats, swings, damage, knockback, PvP zoning (arena-only), armour. The **only** `TakeDamage` call in the repo. | `NPCService`, `Tycoon`, `UpgradeService`, `Main.server` | learn what a raid is — `NPCService` registers a damage-ledger observer, same shape as the Economy hook |
| `NPCService.lua` | The Sahur Raid: wave state machine, raider AI, the boss, the `WaveState` remote. One tick loop for all NPCs. | `AdminService`, `Main.server` | spawn a thread per NPC |
| `SessionService.lua` | Offline earnings, the four session loops (daily streak, playtime ladder, boost, weekend), the vault projection, rebirth grants. | `VaultService`, `Main.server` | require `Tycoon` or `PlotService` — it derives income from a **saved profile** so an absent player can be paid with no plot to ask; use `tick()` or `os.date("%j")` for anything persisted |
| `SocialService.lua` | Friends in this server and what they are worth. Pairwise `IsFriendsWith`, cached; `SocialState` remote; `RequestInvite` cooldown. | `Main.server` | use `GetFriendsAsync` (unbounded pagination for ≤9 known ids); cache a failed web call as `false` |
| `FloorService.lua` | The second storey, whole: a deck that **spans the plot** in pieces around `Floors[1].hatch`, the railing round that stairwell, a `TrussPart` ladder standing **inside** it, the floor's own belt + collector, **and the upper storey's walls** (`buildStoreyWalls(model, "upper")`) with `refreshRoof` on top. Driven off `Tycoon:onOwnedChanged`. | `Main.server` | build from the `Floor` installer — the deck outlives the purchase (release, rebirth, re-claim never go through `install()`); build the slab as one box, or list its pieces by hand instead of deriving them from the deck and hatch rectangles |
| `GateService.lua` | The doors in the shell's openings: opens a `Config.Structure.Openings` entry's leaves when a humanoid is inside `Gate.triggerRadius`, closes them when none is. **One** `Gate.tickRate` loop for the whole server, over `Tycoon.all()`. | `Main.server` | use `Touched`/`TouchEnded` (a character resting on a trigger bounces off its own physics jitter — that is what cost the deleted teleport pads a cooldown, an arrival lock and a sweep); run a loop per plot; hold a leaf reference across ticks without checking `Parent`; learn what a raider is (leash 124 vs a plot edge at 140) |
| `VaultService.lua` | The number on the side of the vault: capacity/banked/fraction gauge, the collect prompt and its drain animation. Driven off `onOwnedChanged` plus a slow beat. | `Main.server` | send a net message — it has **zero**; parts and BillboardGuis replicate on their own and the claim is a `ProximityPrompt` |
| `UpgradeService.lua` | **Prototype.** Player upgrade shop + the utility keybind slot. Both flags off ⇒ every entry point returns on line 1. | `Main.server` | make the utility a second `Tool` (only one Tool equips at a time) |
| `AdminService.lua` | Chat commands (`!give`, `!wave`, `!clear`, `$`) for testing what the verifier cannot see. Authorised per-player: Studio, place owner, or allowlist. | `Main.server` | take a shortcut — `!give` goes through `Tycoon:install`, cash through `Economy`; trust `game.CreatorId` before checking `CreatorType` |

#### `src/server/tycoon/` — one plot, twelve modules, one table

It was one 2,552-line file with ten requires. The split is **mechanical**: the
methods all hang off one shared table through `Tycoon.__index`, so `Class.lua`
builds the bare table and every other file attaches methods to it and returns it.
Nothing about how a plot behaves changed — the 108 specs and 603 checks are
identical either side of the move.

| Path | Owns | Lines | Requires in the folder |
| --- | --- | --- | --- |
| `Tycoon.lua` | The aggregator, and the `kind` contract. Requires `Class`, requires every mixin **for its side effect**, re-exports `Tycoon.part`. | 59 | `Class`, `Parts`, all nine mixins |
| `Class.lua` | The `Tycoon` table and `__index`, `INSTANCES`/`Tycoon.all()`, the shared `COLORS` / `MISC_SPOTS` / `MIN_PART`, `Tycoon.new`, `at`, `ownerSpawnCFrame`, the `onOwnedChanged` list, `ensureButtons`, `registerFactoryFolder`, `setFactoryVisible`. | 227 | **none** |
| `Parts.lua` | `newPart` (every Part on a plot) and `MACHINE_MASSES` + `buildMasses` (the one description a ghost and a real machine share). | 116 | `Class` |
| `Belt.lua` | The conveyor: `resolvePath`, leg maths, running surfaces, corner sensors, flow markers, `refreshBeltSpeed`, `dropInterval`. | 430 | `Class`, `Parts` |
| `Vault.lua` | The collector, the fill gauge (`setVaultGauge`) and `onCollect` — where a drop becomes money. | 287 | `Class`, `Parts` |
| `Props.lua` | Claim rig, rebirth pad, cabinets and their signs, the yard, `refreshGenerator`. | 346 | `Class`, `Parts` |
| `Buttons.lua` | Button positions, `buildButtons`, ghosts, the two label voices, `refreshButtons`, `pointAt`. | 517 | `Class`, `Parts` |
| `Purchase.lua` | `playerFromHit`, `tryPurchase`, `install`. | 119 | `Class` |
| `Installers.lua` | `Tycoon.INSTALLERS` (all eight kinds), the dropper machine, the drop loop, shelf displays, and **the building shell**: `buildStoreyWalls` (one storey's courses, window bays, trim and interior strip), `gateLeafSpecs` (the leaf geometry `GateService` also reads), `buildRoofModel` / `refreshRoof`. | 629 | `Class`, `Parts` |
| `Drops.lua` | `spawnDrop`, `clearDrops`, and the per-plot drop budget. | 110 | `Class` |
| `Income.lua` | `incomePerSecond`, `refineryMultiplierFor`, `effectLine`, `updateSign`. | 162 | `Class` |
| `Ownership.lua` | `assign`, `release`, `rebirth`. | 194 | `Class` |

Three rules hold this together, and the first two are not stylistic:

1. **A mixin requires `Class` (and `Parts`), never a sibling and never
   `Tycoon.lua`.** `Req` detects a cycle at **runtime** (`Req.lua:70-73`), not at
   build time, so a cycle here fails the boot in Studio and passes every pass of
   `verify.py`.
2. **The aggregator's requires are load-bearing.** Deleting one silently removes
   a dozen methods from the class; the first symptom is a `nil` call inside
   `Tycoon.new`, and pass 2 cannot see it because the name that went missing is a
   method on a table rather than a local.
3. `COLORS`, `MISC_SPOTS` and `MIN_PART` hang off the class table because a
   file-local cannot be read from the file next door. They are read by the
   mixins, never written.

### `src/client` — presentation only

| Path | Responsibility | Required by | Must not |
| --- | --- | --- | --- |
| `Main.client.lua` | Entry point. Starts the four panels, then fires `ClientHello` once. | *(entry `LocalScript`)* | — |
| `UiKit.lua` | The panel vocabulary: `PALETTE`, `corner`, `stroke`, `panel`, `text`, `button`, `scaleFor`, `safeInsets`. | `HUD`, `SessionUI`, `UpgradeUI` | move to `src/shared` (it would ship to the server build) |
| `HUD.lua` | All on-screen furniture **and the only `ScreenGui` in the game**, carrying `Root` (UIScale + safe-area padding) and `Overlay` (UIScale, no padding, for modals). The persistent furniture is one status card (balance, multiplier, friend bonus, next purchase + progress bar), the toast column, the action stack and the raid billboard. | `CombatClient`, `SessionUI`, `UpgradeUI` (lazily, `UpgradeUI.lua:422`), `Main.client` | — |
| `CombatClient.lua` | Local feel only: hitmarkers, camera shake, knockback application, swing playback. | `Main.client` | decide damage; parent UI straight to the `ScreenGui` (that is outside the UIScale *and* the safe area) |
| `UpgradeUI.lua` | **Prototype.** Shop panel + utility chip. Draws the last `UpgradeState`. | `Main.client` | decide what you own, what a level costs, or whether a utility is off cooldown |
| `SessionUI.lua` | Welcome-back modal, daily/playtime claims, boost button, Vault Timer row. | `Main.client` | send a level or a price — the Vault Timer sends `{ kind = "capUpgrade" }` and the server owns which rung is next |

Any client module: **build a second `ScreenGui`** (use `HUD.root()` /
`HUD.overlay()`), **name a font, outline or view distance** (go through
`Style`), or **write a card-scale size as a literal** (name it in `Config.UI`).
All three are lint-enforced — see §7.

---

## 3. Dependency direction

The layering that actually holds:

```
                     Req.lua          (the bootstrap; not a graph node)
                        |
        +---------------+----------------+
        |                                |
     Config.lua                       Net.lua        <- the two roots: zero requires
        |                                |
  shared leaves: Util  Style  Sound -> Fx -> TungModels  ShopMath  SwingAnim
        |
  DataService  ->  Economy  ->  { CombatService, SocialService, Analytics }
        |              ^                  |
        |              |                  v
        |          (hooks, not requires)  NPCService     UpgradeService
        |
        +----------------> tycoon/  (Config Style Util Fx TungModels
                             ^         Economy DataService CombatService
                             |         MapBuilder Analytics  = 10, across
                             |         twelve files; Req("Tycoon") is the
                             |         aggregator, Class is the only node
                             |         inside the folder anything requires)
        +--------------------+--------------------+
        |                    |                    |
   PlotService     FloorService  GateService  VaultService -> SessionService
        ^                                                        ^
        |                    Main.server.lua                      |
        +---------------------------+-----------------------------+

  client:  Config/Net/Util/Style/Sound/ShopMath/SwingAnim
              -> UiKit -> HUD -> { CombatClient, UpgradeUI, SessionUI }
              -> Main.client
```

**`Tycoon` is the hinge.** It requires the same ten modules it always did —
`Config`, `Style`, `Util`, `Fx`, `TungModels`, `Economy`, `DataService`,
`CombatService`, `MapBuilder`, `Analytics` — now spread over the twelve files of
`src/server/tycoon/`, each requiring only what it uses; and it is required *back*
by the four services that drive it: `PlotService`, `FloorService`,
`GateService`, `VaultService`. There is no cycle, because none of those four is
required by anything `Tycoon` requires. `Req` would `error("circular dependency")` if one
appeared (`Req.lua:70-73`), and both `pack.py` and `test.py` reproduce that guard.

**Inside the folder the graph is a star, not a chain.** `Class.lua` requires no
sibling; every mixin requires `Class` (and `Parts` when it builds parts); the
aggregator requires all of them. That shape is what makes the cycle guard
irrelevant here — and it has to be maintained by hand, because `Req` raises on a
cycle at **runtime**, so a mixin that required `Tycoon` back would fail the boot
in Studio while passing every pass of `verify.py`.

### The oddities, named

1. **Inversion by hook, twice.** `Economy` must not know about the things that
   multiply cash, so `SessionService`, `SocialService` and `UpgradeService`
   register through `Economy.setMultiplierHook(name, fn)`
   (`Economy.lua:32`) — keyed, so two prototypes stack instead of
   overwriting. Same shape in `CombatService`'s damage observer
   (`CombatService.lua:33-39`), which lets `NPCService` keep a boss damage
   ledger without `CombatService` learning what a raid is.
2. **`VaultService` exists only to keep the arrows straight.** It needs
   `Tycoon` (to draw a gauge on a plot) *and* `SessionService` (to read the
   projection). Neither may require the other, so a leaf requiring both is the
   shape. `FloorService` is the same pattern one dependency lighter. See
   `VaultService.lua:31-36`.
3. **The income model exists twice, deliberately.**
   `Tycoon:incomePerSecond()` (`tycoon/Income.lua:39`) reads a live plot;
   `SessionService.incomePerSecondFor(profile)` (`SessionService.lua:169`)
   mirrors it from a saved profile, because an offline player has no `Tycoon` to
   ask. The mirror deliberately **excludes** the session multipliers and (for
   free, via the same exclusion) the friend bonus. Change one and check the
   other.
4. **`Config` is required by 26 of 30 modules.** The four that do not are
   `Util`, `Net`, `Req` and `Main.client`. Treat `Config` as ambient.
5. **`Economy` requires `DataService` late** (`Economy.lua:13`, after the
   `Players` service) — cosmetic in Rojo, but the position is load-bearing in
   nothing; do not read meaning into it.
6. **Three declared remotes are dead**: `Purchased`, `Sfx` and `FloorState` are
   in `Net.NAMES` and nothing fires or listens to them. `PlotAssigned` is fired
   by `PlotService.lua:19` and has no client listener.

---

## 4. Ownership boundaries

Four rules, each with the thing that enforces it.

### 4.1 `Config.lua` owns every tunable number — including geometry

Prices, curves, wave timings, belt speed, plot size, machine offsets, slot
distance tables, cabinet and yard positions, UI card sizes, analytics schema.

**The evidence.** `tools/verify_config.lua` (2,976 lines) runs `Config.lua`
outside Roblox against four stubs and asserts the data is internally
consistent. It reads **exactly one file**: `verify.py:check_config` finds the
`--@INJECT src/shared/Config.lua` marker (`verify_config.lua:33`) and splices
that file in. A number that lives anywhere else is a number the suite cannot
see. That is not theoretical — `FloorService.lua:47-51` says so in as many
words: the mezzanine's belt path was built in *code*, so none of the belt-path
assertions ever saw it, and two of them were wrong.

Geometry therefore lives in `Config.Layout` (`Config.lua:143`) and
`Config.World` (`:15`), with the per-track furniture positions derived by
`Config.trackButtonPosition` / `trackCabinet` / `trackShelfPosition` and the yard
by `Config.yardMachinePosition` / `yardButtonPosition` (`:378-383`).

**All three track helpers take their Y from `Config.floorTopY(t.floor)`**, and
both side tracks name `floor = "mezzanine"` — the weapons and armour cabinets,
their nine buy-button pedestals and their shelf displays stand on the deck, in
`Floors[1].zones.armoury`, not on the ground floor. A builder that drops that Y
(`self:at(pos.X, 0, pos.Z)`) builds the whole armoury *underneath* the deck, and
it has happened in three separate places: `Tycoon:buttonBaseCF`,
`Tycoon:ensureCabinets` and `buildShelfDisplay`.

Two escapes, both principled: `tycoon/Class.lua:36` keeps `MIN_PART = 0.05` on
the class table because it is a property of the engine, not a knob; and `Config.Admin`
(`:666`) is deliberately *not* in `Config.Prototypes`, because the verifier
asserts every prototype flag ships `false` and admin commands are finished
code gated on *who is asking*.

### 4.2 `Tycoon` owns one plot, and is data-driven off `Config.Buttons`

You add content by adding a table row. You never edit `Tycoon`.

`Config.Buttons` is *derived*, not written: `Config.lua:2094-2113` walks
`Config.TrackOrder = { "factory", "weapons", "armor", "power" }` over
`Config.Tracks` (which point at `Config.FactoryButtons`, `WeaponButtons`,
`ArmorButtons`, `PowerButtons`) and stamps `track`, `trackOrder`, `order` and —
crucially — **derives `requires` from the previous rung of the same track**. A
track is a chain, so "no requirement crosses a track" is a property of the
loader rather than a promise the verifier has to police.

**The `kind` → required-fields contract.** `tycoon/Tycoon.lua:1-35` states it; the
installers implement it (`Tycoon.INSTALLERS`, `tycoon/Installers.lua:121-539`); and
`verify_config.lua:117-176` asserts it. Every row needs `id`, `name`, `price`
(strictly climbing *within its own track*), plus:

| `kind` | Required fields | Installer (`tycoon/Installers.lua`) |
| --- | --- | --- |
| `Dropper` | placement (below) + `variant`, `dropValue`, `dropRate` (> 0.2s) | `:177` |
| `Upgrader` | placement (below) + `variant`, `multiplier` (> 1) | `:190` |
| `Belt` | `speedBonus` (> 0) | `:258` |
| `Power` | `factor` (> 1, **cumulative**), `variant`, and **no `slot`** — there is one generator stand and every rung upgrades the machine on it | `:267` |
| `Structure` | `structure` ∈ `{ "walls", "roof" }` | `:512` — a two-line dispatch; it emits what `Config.wallSegments` / `Config.wallBays` / `Config.roofUnderside` describe and decides no geometry of its own |
| `Gear` | `grants` → a `Config.Bats` id | `:334` |
| `Armor` | `grants` → a `Config.Armor` id | `:350` |
| `Floor` | a matching `Config.Floors` entry naming this button id | `:371` — a **documented no-op**; `FloorService` builds the deck off `onOwnedChanged` |

*Placement* is exclusive-or: either `slot` (an index into
`Layout.DropperDist` / `Layout.UpgraderDist`, the ground floor's two legs — must
exist and must be unused) **or** `path` + `legIndex` + `legDistance` for a
machine pinned to a named `Config.BeltPaths` entry. Never both, never neither
(`verify_config.lua:85-115`).

**All eight kinds are in all three places now.** The header used to name five:
`Power`, `Armor` and `Floor` arrived later and never reached it, while
`Tycoon.INSTALLERS` and `verify_config.lua`'s `KNOWN_KINDS` carried all eight.
Nothing enforces that third copy: `KNOWN_KINDS` mirrors the installers and the
verifier fails an unknown `kind`, but a kind missing from the *header* fails no
pass at all. It is the copy to check by hand when adding one.

`verify_config.lua` also asserts: no duplicate ids; every `requires` points at a
button defined *earlier* and *in the same track*; every button is reachable from
a root; prices climb per-track; `Power` rungs step inside
`Config.Power.StepMin..StepMax` and the top rung equals `Power.MaxFactor`; and
an unknown `kind` fails the build ("kinds that `Tycoon.lua` has no installer
for" — `verify_config.lua`'s wording, from before the split).

### 4.3 Services own lifecycles; they talk to `Tycoon` through its public surface

| Service | Lifecycle it owns | How it reaches `Tycoon` |
| --- | --- | --- |
| `PlotService` | claim / release / offline grace / auto-assign / respawn position | `Tycoon.new`, `:assign`, `:release`, `:rebirth`, `:updateSign`, `:refreshButtons` |
| `NPCService` | wave schedule, raider AI, boss | not at all — it goes through `Economy` and `CombatService` |
| `DataService` | load / autosave / lock / shutdown flush | not at all — `Tycoon` requires *it* |
| `SessionService` | daily streak, playtime ladder, boost, weekend, offline grant | not at all — profile-only, by design |
| `FloorService` | the deck's existence across purchase, release, rebirth, re-claim | `Tycoon.all()`, `:onOwnedChanged`, `:refreshRoof` |
| `GateService` | whether each opening's leaves are open or closed | `Tycoon.all()`, `:gateLeafSpecs`, `tycoon.machines`, `tycoon.owned` — and **no** `onOwnedChanged`: a gate is a distance test on a fixed beat, not a reaction to a purchase |
| `VaultService` | the gauge, the collect prompt, the drain | `Tycoon.all()`, `:onOwnedChanged`, `:setVaultGauge`, `tycoon.vaultPrompt` |

`Tycoon:onOwnedChanged(fn)` (`tycoon/Class.lua:163`) is the seam. It is a **list**
of listeners now, each `pcall`'d individually in `fireOwnedChanged`
(`tycoon/Class.lua:169`) so one that throws takes down neither the purchase nor
the listeners behind it. Two consumers today: `FloorService.sync` and
`VaultService.refresh`.

`Tycoon.all()` (`tycoon/Class.lua:43`) returns every plot built this session, in
plot order. `PlotService` hands plots out *by player*; a service that must walk all
of them has nowhere else to get the list.

### 4.4 `src/client` owns presentation only

The server never sends a price, a level or a cost, because `Config` is
replicated and the client can read it. What crosses the wire is state and
intent. `SessionUI`'s Vault Timer button is the canonical example: it sends
`{ kind = "capUpgrade" }` and *not* a level or a price.

All remotes are declared up front in `src/shared/Net.lua:28-66` — created
eagerly by the server, so a client with a prototype flag off still resolves them
instead of sitting in `WaitForChild` for 30 seconds.

| Remote | Dir | Payload | Fired by | Handled by |
| --- | --- | --- | --- | --- |
| `Stats` | S→C | `{ cash, rebirths, kills, batTier, armorTier, multiplier, owned, rebirthCost }` | `Economy.push` (`Economy.lua:107`) | `HUD:903`, `UpgradeUI:454` |
| `Notify` | S→C | `{ kind, title, body, color }` | `Economy.notify` (`:212`), `NPCService:27` | `HUD:895` |
| `WaveState` | S→C | `{ phase, wave, remaining, total, seconds, boss, forced, bossHp, bossMaxHp, bossScale }` — `phase` ∈ `idle｜resting｜warning｜spawning｜active｜clear`; `seconds` sent **once** per phase and counted down client-side | `NPCService:26` | `HUD:904` |
| `SocialState` | S→C | `{ friends, cap, bonus, multiplier, names }` | `SocialService:170-181` | `HUD:905` |
| `SessionState` | S→C | `{ enabled = { rebirth }, daily, playtime, boost, offline, capUpgrade, capHours, rebirth }` | `SessionService.stateFor` (`:548`) | `SessionUI:604` |
| `UpgradeState` | S→C | `{ levels, costs, locked, equipped, cooldown, cooldownTotal }` — declared payload is `{ levels, costs }`; the rest is additive | `UpgradeService.push` (`:208`) | `UpgradeUI:437` |
| `HitFeedback` | S→C | `{ damage, crit, killed, position }` | `CombatService:26` | `CombatClient:143` |
| `SwingFx` | S→C | `{ character, combo, duration }` | `CombatService:28` | `CombatClient:162` |
| `Knockback` | S→C | `Vector3` impulse, applied by the owning client | `CombatService:27`, `UpgradeService:62` | `CombatClient:179` |
| `PlotAssigned` | S→C | `plotIndex` | `PlotService:19` | **nothing** |
| `RequestRebirth` | C→S | *(none)* | `HUD:555` | `PlotService:168` |
| `RequestReset` | C→S | *(none)* — leave plot | `HUD:357` | `PlotService:172` |
| `RequestInvite` | C→S | *(none)* — exists for the server-side cooldown; the prompt itself is a client call | `HUD:467` | `SocialService:55` |
| `RequestClaim` | C→S | `{ kind = "offline"｜"daily"｜"playtime"｜"capUpgrade", index? }` | `SessionUI:260,378,390,406` | `SessionService:914-923` |
| `RequestBoost` | C→S | *(none)* | `SessionUI:398` | `SessionService:54` |
| `RequestUpgrade` | C→S | upgrade id (`""` = refresh) | `UpgradeUI:150,477` | `UpgradeService:60` |
| `UseUtility` | C→S | *(none)* | `UpgradeUI:299` | `UpgradeService:61` |
| `ClientHello` | C→S | `{ platform }` — **the one thing the server cannot work out for itself**; re-validated against `Config.Analytics.Fields.platform` and used as a chart label only | `Main.client:50` | `Analytics:600` |
| `Purchased` | S→C | `{ id, name, price }` | **nothing** | **nothing** |
| `Sfx` | S→C | `{ name, position }` | **nothing** | **nothing** |
| `FloorState` | S→C | `{ unlocked }` | **nothing** | **nothing** |

`Net.lua:33-38`'s comment on `SocialState` records why it is a separate remote
rather than a field on `Stats`: folding it in would make `Economy` require
`SocialService`, which is exactly the arrow `setMultiplierHook` exists to
prevent.

---

## 5. The runtime beats

The "everything re-runs here" moments. If a change does not survive all of
these, it does not survive.

### Server boot — `src/server/Main.server.lua`

```
:8         Req bootstrap
:10-34     16 requires (module bodies run here, in this order)
:43        1. MapBuilder.build()            -> world
:46-49     2. DataService.start(); Analytics.start(); Economy.start(); CombatService.start()
:52-53     3. PlotService.build(world); PlotService.start()      -> Config.World.PlotCount Tycoons
:56        4. NPCService.start()
:61        4b. AdminService.start()   (after NPCService: !wave drives its schedule)
:64-75     5. UpgradeService / SessionService / VaultService / FloorService /
              GateService / SocialService .start()
:129       6. Players.PlayerAdded -> onPlayerAdded
```

The comments at `:1-5`, `:58-60`, `:66-67` and `:70-73` are constraints, not
narration: data before economy (leaderstats read profiles), world before plots,
plots before players, **`VaultService.start()` after `SessionService.start()`**
because it registers listeners on already-built plots and reads the projection
`SessionService` owns, and `GateService.start()` after the plots exist because it
walks `Tycoon.all()` rather than waiting to be told about one.

`onPlayerAdded` (`:93-126`) has one hard ordering rule:

```
:94   DataService.load(player)
:102  Analytics.onPlayer(player)        <- MUST sit between load and SessionService.onPlayer
:103  Economy.setupLeaderstats(player)
:104  Economy.push(player)
:105  UpgradeService.onPlayer(player)
:106  SessionService.onPlayer(player)   <- overwrites profile.lastSeen with os.time()
:118  PlotService.autoAssign(player)    (task.delay 1.5s, if still plotless)
```

`profile.lastSeen` is readable exactly once, at `:96`, and it is the only input
the `returned` event has. Move that line below `:100` and nothing breaks
visibly — every "how long before they came back" number silently becomes zero
(`:89-95`).

`onCharacterAdded` (`:72-85`): `WaitForChild("HumanoidRootPart")` →
`task.defer(PlotService.teleportToPlot)` (a reposition, not a `SpawnLocation` —
a per-plot spawn would land in the random pool and send other players to your
factory) → `CombatService.onCharacter` → `UpgradeService.onCharacter` →
`Economy.push`.

### Client boot — `src/client/Main.client.lua`

```
:3      Req bootstrap
:5-11   requires (HUD, CombatClient, UpgradeUI, SessionUI module bodies run here)
:15     HUD.start()              <- builds the only ScreenGui, Root and Overlay
:16     CombatClient.start()
:20     UpgradeUI.start()        <- returns immediately unless its flag is on
:21     SessionUI.start()        <- same
:35     task.spawn -> Net.event("ClientHello"):FireServer{ platform = Util.platformFrom(...) }
```

The requires at `:5-11` run *before* `HUD.start()`, which is why a module-level
error in `SessionUI` kills the entire client — no cash label, no toasts, nothing
(the #50 incident recorded in `verify.py`'s `ROBLOX_GLOBALS` comment). The
`ClientHello` fire is once and immediate: the server holds the session's three
join events open waiting for it and gives up after ten seconds, because a logged
event cannot be edited afterwards. The order inside `Util.platformFrom` is the
whole point — VR and console both report `TouchEnabled`.

### `Tycoon:refreshButtons()` — `tycoon/Buttons.lua:333-477`

**The single beat that re-runs everything on a plot.** Called from four places
that between them cover every event which can open or close a track, and from a
3-second heartbeat:

| Caller | Line |
| --- | --- |
| `Tycoon:install` | `tycoon/Purchase.lua:115` |
| `Tycoon:assign` | `tycoon/Ownership.lua:63` |
| `Tycoon:release` | `tycoon/Ownership.lua:103` |
| `Tycoon:rebirth` | `tycoon/Ownership.lua:171` |
| `PlotService.start`'s 3s loop (owned plots only) | `PlotService.lua:189` |

In one pass it: bails out and unparents everything if the plot is unowned;
computes a **per-track frontier**; decides `available` / `preview` / hidden per
button (a gated track is *hidden*, not previewed); repaints pads, lights,
strokes and the four labels in two "voices" (`BTN` vs `BTN_LOCKED` — smaller,
fainter, thinner, shorter view distance, because colour alone is the first
signal lost to a bright sky); creates and destroys ghost previews; picks the
beacon target by `(TrackRank, price)` lexicographically; then, on the same beat
and for the same reason, calls **`ensureCabinets()` → `updateCabinetSigns()` →
`ensureYard()` → `refreshGenerator()`** (`Buttons.lua:470-476`, the four of them
implemented in `tycoon/Props.lua`). All four are idempotent, and all four have to
survive install, assign, release *and* rebirth — which is why they hang here
instead of on their own listeners.

Each of the four callers pairs `refreshButtons()` with `fireOwnedChanged()`
(`Purchase.lua:116`, `Ownership.lua:65`, `:105`, `:173`), in that order — buttons
first, listeners second.

### `Economy.markDirty` / `Economy.push` — `Economy.lua:107-128`, `:216-231`

`markDirty(player)` sets a flag. `Economy.start()` spawns a `task.wait(0.1)`
loop that drains the dirty set, so droppers firing several times a second
coalesce into ~10 replications/sec instead of one per drop. `push` is also
called *directly* — at boot (`Main.server:98`), on character add (`:84`) and
after a rebirth (`tycoon/Ownership.lua:174`) — where the update must not wait 100 ms.
`PlayerRemoving` clears the flag (`Economy.lua:229`).

Anything that changes cash outside `Economy.add` / `spend` / `steal` must call
`markDirty` itself, or the HUD keeps the old number until the next dropper.

### `FloorService.sync` off `onOwnedChanged` — `FloorService.lua:264-278`

```lua
local unlocked = tycoon.owner ~= nil and tycoon.owned[FLOOR.button] == true
```

Build if unlocked and not built; tear down if built and not unlocked; then
`tycoon:refreshRoof()` either way. **That call is the beat that raises the
building.** The roof sits on the top storey that exists — `Config.roofUnderside`
reads `owned[floor2]` and answers 20.4 or 42 — so without the rebuild the roof
stays on the ground storey's line with a deck at 22 growing through it. It used
to *shrink* instead, pulling its back edge in to clear the deck and leaving open
sky over the back half; there is one structural line now and the roof always
spans the whole plot.

`build()` puts the **upper storey's walls** up in the same pass, into the deck's
own folder. They are structure, but they are not the `Structure` installer's:
`walls` is bought around minute three, when there is no deck to stand a wall on,
and an installer never runs again — that is the hole `refreshRoof` exists to
cover, and rebuilding the ground ring to add a storey above it would destroy the
gate leaves `GateService` may be mid-tween on. Off `onOwnedChanged` the storey
arrives and leaves as one object across purchase, release, rebirth and re-claim,
and there is no state in which a deck has no walls. The one thing that assumes
otherwise is `GateService`'s `tycoon.machines:FindFirstChild(name, true)`; no
upper-storey `Openings` entry exists today, so no leaf is built up there.
`FloorService.start()` (`:280`) registers it on every plot **and calls it once
immediately** (`:291-292`), which is what makes a server restart with saved
plots correct. `VaultService.start()` (`:197`) has the same shape plus a slow
`BEAT` loop behind it, for the things that move without a purchase — a rebirth,
a Vault Timer upgrade, a grant arriving.

---

## 6. Where to change what

| I want to… | Edit | What catches a mistake |
| --- | --- | --- |
| add a dropper / upgrader | a row in `Config.FactoryButtons` (`Config.lua:924`) | `verify_config.lua`: id/name/price, unused slot, known variant, `dropRate > 0.2`, per-track price monotonicity, reachability |
| add a bat / armour tier | `Config.Bats` (`:1097`) + `Config.WeaponButtons` (`:1129`), or `Config.Armor` (`:1177`) + `Config.ArmorButtons` (`:1198`) | `verify_config.lua`: `grants` must resolve in `BatById`/`ArmorById`; requirements may not cross tracks |
| add a generator rung | `Config.PowerButtons` (`:1252`) | `verify_config.lua`: `factor` climbs, step inside `Power.StepMin..StepMax`, top rung equals `Power.MaxFactor`, **no `slot`** |
| invent a new `kind` | a `Tycoon.INSTALLERS.X` case (`tycoon/Installers.lua:121+`) **and** `KNOWN_KINDS` in `verify_config.lua:44` **and** the `kind` list in `tycoon/Tycoon.lua:1-35` | `verify_config.lua` fails an unknown kind; `Tycoon:install` `warn`s if the installer is missing. The header list is checked by nobody. |
| retune the curve | `Config.Economy` (`:635`), `Config.Rebirth` (`:674`), the `price` fields | `verify_config.lua`'s progression simulation + the spine-price assertions |
| move the belt | `Config.Layout` (`:143`) — `BeltStart`/`BeltCorner`/`BeltEnd`/`CollectorAt`/`BeltY`/`BeltWidth`/`BeltSpeed`, or `Config.BeltPaths` (`:1594`) for a non-ground path | `verify_config.lua`: legs stay on the plot, slot distances fit the legs, drops-in-flight against the belt capacity model |
| move a machine or a button | `Layout.DropperDist` / `UpgraderDist` / `MiscButtons` / `MachineOffset` / `ButtonOffset` (`:143-178`), or `Config.trackButtonPosition` (`:2741`) | `verify_config.lua`: slot collisions, slots overflowing the distance tables |
| add a UI panel | a new `src/client/*.lua`, built into `HUD.root()` or `HUD.overlay()`, using `UiKit`; sizes named in `Config.UI` (`:651`); started from `Main.client.lua` | `verify.py` passes 3, 6, 7: no font/outline/distance outside `Style.lua`, no ≥300×200 literal card in `src/client`, no second `ScreenGui` |
| add a save field | `DEFAULT` in `DataService.lua`, and the explicit payload table in `save()` | `reconcile()` iterates the fresh DEFAULT's keys — a field missing from DEFAULT is invisible to it and will never load |
| add a wave behaviour | `Config.Waves` (`:1331`) for numbers; `NPCService.lua` for the state machine | `verify_config.lua`'s wave/boss assertions; `boss_spec.lua` — but `NPCService` itself does **not** execute headless (§7) |
| add a remote | `Net.NAMES` (`Net.lua:28`) — declare it, do not create it on demand | a client resolving an undeclared remote sits in `WaitForChild` for 30s |
| add an analytics event | `Config.Analytics` (`:2563`), then call `Analytics.emit` | `verify_config.lua`: three fields max, string values, `analyticsCombinations()` against the 8,000 cap; `analytics_spec.lua` |
| graduate a prototype | **delete** the flag from `Config.Prototypes` (`:2153`), not set it `false` | `verify.py` pass 4: any `P.DeletedFlag` read left behind is a finding — a nil flag makes `if not P.X` fire forever, which is how `VaultService` shipped dead |
| change the plot's shell — wall height, windows, an opening, a gate, the roof | `Config.Structure` (`Config.lua:1888`) and nothing else. `INSTALLERS.Structure` emits `Config.wallSegments`/`wallBays` verbatim, `Config.roofUnderside` is the one structural line both the walls and the roof derive from, and an opening's `face` (`"inboard"`/`"outboard"`) is which side its leaves hang and slide on — the yard door is `outboard` because the inside of the back wall is the dropper row | `verify_config.lua`'s shell family + `structure_spec.lua`: each wall tiles its extent with no gap or overlap, every opening lies inside the wall it cuts with a lintel above, a gate leaf has a solid run to slide along, glass stays at or above PopperCam's 0.25, and `shellPartCount` stays inside `Structure.PartBudget` |
| rename or move a `Config` key | `Config.lua`, then every reader | `verify.py` pass 5: a `Config.<path>` read that no longer resolves is a finding, aliases followed |
| retune a number, anywhere | `Config.lua` — never a file-local constant | nothing else can see it; see §4.1 |

---

## 7. The tooling

```
python3 tools/verify.py                    # everything, and regenerates build/
python3 tools/test.py --plain              # the runtime specs alone
python3 tools/test.py --filter offline     # one spec family
python3 tools/pack.py                      # regenerate build/ only
```

Needs `luau`, `luau-compile`, `luau-analyze` on `PATH`.
`.github/workflows/verify.yml` runs `verify.py` on push, PR and dispatch.

### `verify.py` — ten passes, in order

The count is load-bearing and has drifted before: `verify.py`'s own docstring
notes it "has said five, seven and eight while `main()` ran nine". Keep the
docstring list, `main()`'s `results` list and this table in step.

| # | Pass | What it asserts |
| --- | --- | --- |
| 1 | syntax | every file in `src/` **and** `tools/testing/` compiles |
| 2 | analysis | `luau-analyze`, with the Roblox globals **named** in `ROBLOX_GLOBALS` rather than the whole `Unknown global` class waved through. Anything not on that list is a deleted require, a typo, or a local removed with its uses left behind. |
| 3 | style ownership | nothing outside `src/shared/Style.lua` names `Enum.Font.*`, sets `TextStrokeTransparency` or sets `MaxDistance`. `src/` only — `tools/` is not shipped. |
| 4 | prototype flags | every `Config.Prototypes.X` read is a flag that still exists, resolved through locals actually bound to `Config.Prototypes` |
| 5 | config paths | every `Config.<path>` read anywhere in `src/` names a key that exists. It indexes `Config.lua` into `known` paths and the subset that is `closed` (a table literal with named keys only, never written by a computed key) and only reports a missing child against a closed table — so arrays (`Config.Bats`), loop-built tables (`Config.ButtonById`) and non-literal values are skipped. Follows local aliases (`local L = Config.Layout`) on both sides. |
| 6 | mixin folders | the file list of `src/server/tycoon/` equals the aggregator's require list. Those requires attach methods to the shared class table, so deleting one removes a dozen methods with every other pass green — and pass 2 cannot see it, because the name that goes missing is a method on a table, not a local. |
| 7 | ui geometry | no `UDim2.fromOffset(w, h)` / `Vector2.new(w, h)` with `w ≥ 300 and h ≥ 200` in `src/client` unless the line goes through `Config.UI.` |
| 8 | one screengui | only `src/client/HUD.lua` calls `Instance.new("ScreenGui")`, so there is one `UIScale` |
| 9 | config integrity | `tools/verify_config.lua`, with `src/shared/Config.lua` spliced in at `--@INJECT`. Reads **that one file**. |
| 10 | runtime specs | `tools/test.py` — executes game code |
| 11 | packed build | regenerates `build/` and syntax-checks the output |

Pass 9 runs before pass 10 deliberately: a broken `Config` makes every spec fail
confusingly, and the useful error is the upstream one.

Passes 3–8 are the ownership lints. Each one exists because the state it
prevents already shipped once; the comment above each in `verify.py` names the
incident.

### `tools/test.py` — what runs headless

It is a **second consumer of `pack.py`**: same `BOOTSTRAP` regex, same `indent`,
a near-identical `module_block`. The difference is that the factory *takes* the
requirer (`function(Req)`) instead of closing over a global, because the harness
runs several **realms** — independent loads of the module tree, each with its own
`Config` and its own service upvalues — over one Lua state and one shared mock
world. That is what lets two realms race one DataStore key in the session-locking
specs.

Mocks, in load order: `clock`, `vector3`, `instance`, `datastore`, `players`,
`gui`, `roblox` (`tools/testing/mock/`), then `runner.lua` and `world.lua`.
`gui.lua` is the screen — `Vector2`, `Rect`, `ColorSequence`, `typeof`, a
`Camera` with a `ViewportSize`, `RenderStepped`, and the `LocalPlayer` with a
`PlayerGui`. Its header names every claim it makes about Roblox and what each one
costs; read it before trusting a client spec.
Fifteen spec files in `tools/testing/specs/`: `analytics`, `boost`, `boss`,
`floor`, `generator`, `hud`, `lock`, `offline`, `playtime`, `smoke`, `social`,
`streak`, `structure`, `vault`, `weekend`.

**What executes:** every `src/shared/*.lua` except `Req.lua`, plus exactly the
modules in `SERVER_MODULES` (`tools/test.py:52-53`) and `CLIENT_MODULES`:

```python
SERVER_MODULES = ["DataService", "Analytics", "Economy", "SessionService", "SocialService",
                  "CombatService", "MapBuilder", "Tycoon"]
CLIENT_MODULES = ["UiKit", "HUD", "CombatClient", "UpgradeUI", "SessionUI", "Main.client"]
```

`CLIENT_MODULES` is new in this round and it is **exhaustive**: `client_sources()`
fails the run if a file in `src/client` is missing from it, because the point of a
boot smoke is that it covers everything that boots. Note `Main.client` in that
list — it is an ENTRY script rather than a module, which `pack.py` treats
differently, but the harness hands it a `Req` like anything else. Requiring it is
what makes the client's boot ORDER covered rather than transcribed into a spec
that would not notice a reordering. Before it, no client module
had ever executed anywhere but Roblox — which is half of why `SessionUI.lua`
shipped raising at require time with a green CI. A lint catches an undeclared
identifier; only execution catches a module that raises for any other reason.

Those are **names, not paths** (`server_sources()`, `test.py:112`). `Tycoon`
resolves inside `src/server/tycoon/`, and when a name resolves inside a folder the
whole folder is bundled: the aggregator requires its mixins through the realm's
`req`, which can only return a module the bundle registered, so listing the
aggregator alone would fail at load with `module not found in spec bundle: Class`
— inside the first spec that touches a plot, reading like a game bug.

**What does NOT execute — nothing in these files has ever run outside Roblox:**

| Out | Why |
| --- | --- |
| `NPCService` | needs `Touched`, a physics step, `Region3` |
| `PlotService` | needs `Touched` on claim pads |
| `UpgradeService` | not in the list |
| `VaultService` | not in the list |
| `FloorService` | not in the list |
| `GateService` | not in the list — and it needs `TweenService`, a `Character` and a physics position to mean anything |
| `AdminService` | not in the list |
| **all of `src/client`** | the collector only walks `src/shared` and `SERVER_MODULES` |

Widening that list is real work and should be its own PR, not a quiet addition
to someone else's.

Tracebacks are mapped back from the temp bundle to real `file:line` by
`map_traceback` (`test.py:169`) — without it every trace points into a ~9,000
line temp file.

### Where the existing docs are wrong

Found while writing this file. Nothing here is fixed by this document; it is
listed so the next reader does not trust the wrong sentence.

1. **`README.md`'s file tree listed 18 of the 31 files** at the start of this
   round — it was missing `Style.lua`, `ShopMath.lua`, `Sound.lua`,
   `AdminService.lua`, `Analytics.lua`, `FloorService.lua`,
   `SessionService.lua`, `SocialService.lua`, `UpgradeService.lua`,
   `VaultService.lua`, `SessionUI.lua`, `UpgradeUI.lua` and `UiKit.lua`, and
   still called `ShopMath.lua` by its old name. Another PR in this round
   completed it. It remains a one-line-per-file index with no dependency
   information; that is this document's job, not its own.
2. **`HANDOFF_v6.md:534`** says `verify.py` "runs eight passes now". It runs
   eleven. (Its own docstring notes the count "has said five, seven and eight
   while `main()` ran nine" — the config-paths and mixin-folder lints made it
   eleven in this round.)
3. **`HANDOFF_v6.md:545-549`** lists `VaultService` among the modules that
   "now execute outside Roblox". **It does not** — it is not in
   `SERVER_MODULES`. The same passage says only `NPCService` and `PlotService`
   "are still out"; `UpgradeService`, `VaultService`, `FloorService`,
   `AdminService` and all of `src/client` are also out.
4. **`Net.lua:56`** documents `RequestClaim` as
   `{ kind = "daily" | "playtime" | "offline", index }`. `SessionService`
   accepts a fourth kind, `"capUpgrade"` (`SessionService.lua:922`), and
   `SessionUI.lua:406` sends it. `SessionState` (`Net.lua:57`) and
   `UpgradeState` (`Net.lua:55`) likewise carry more keys than their comments
   list — `UpgradeService.lua:253` says so explicitly ("the declared payload is
   `{ levels, costs }`; the rest is additive").

Two entries left this list rather than being carried forward, because the PR that
split `Tycoon` fixed them: the header naming five `kind`s of eight, and
`tools/test.py`'s comment excluding the three modules listed two lines below it.
