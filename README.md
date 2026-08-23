# Tung Tung Tycoon

A complete, end-to-end Roblox tycoon. Ten plots ring a central arena.
You buy droppers, each one a louder variation of Tung Tung Tung Sahur, watch
little angry bat-men ride a conveyor through upgrader arches into your vault,
and beat back raids with a bat.

**Every model is generated in code.** No toolbox models, no uploaded meshes, no
catalog asset IDs that can 404 or get moderated. The characters, their faces,
the bats, the machines and the whole map are built from primitives at runtime.
Sync it and press Play.

The only things not authored here are five files that ship inside the Roblox
client itself — three particle sprites and two sounds under `rbxasset://`, plus
the built-in fonts. They can't be moderated away either, but they are
placeholders rather than original work; see *Sound* below.

---

## Install

### Option A — Rojo (recommended)

```bash
rojo serve                       # then connect from the Roblox Studio plugin
# or, to build a place file directly:
rojo build -o TungTungTycoon.rbxlx
```

The project file maps:

| Source | Roblox |
| --- | --- |
| `src/shared` | `ReplicatedStorage.TungShared` |
| `src/server` | `ServerScriptService.TungServer` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.TungClient` |

It also sets Lighting to stock Roblox daylight (ClockTime 14.5, ShadowMap, no fog).

### Option B — no Rojo, two copy-pastes

```bash
python3 tools/pack.py
```

Then in Studio:

1. `build/PasteInto_ServerScriptService.server.lua` → a **Script** in `ServerScriptService`
2. `build/PasteInto_StarterPlayerScripts.client.lua` → a **LocalScript** in `StarterPlayer > StarterPlayerScripts`

That's it. The packed files are generated from `src/`, so treat `src/` as the
source of truth and re-run the packer after any change.

> Enable **Studio Access to API Services** in Game Settings → Security if you
> want saving to work. Without it the game runs fine, just in memory-only mode.

---

## How it plays

- Step on a plot pad to claim a factory (you also get auto-assigned on join).
- Green buttons are affordable, red ones aren't. Walk into one to buy it.
- Droppers spit out Tung guys → the conveyor carries them around the back and
  down the left edge → **upgraders multiply their value** → the vault pays you.
- The belt hugs the plot border, so the middle of your plot stays open floor.
  Every upgrader is downstream of every dropper, so the upgrade stack always
  applies to everything.
- **PvP is geographic.** You can only hit another player when you are *both*
  inside the arena ring. Your plot is a safe zone.
- A **Sahur Raid** lands 30 seconds after the world loads, and the next one 30
  seconds after you clear the last. Waves start at 6 raiders and climb to 40 —
  but only 8 can engage you at once, so a bigger wave is reinforcements arriving
  rather than more raiders swinging. Every 5th wave brings a boss. The state of
  it is a sign over the statue in the middle of the arena.
- The weapon and armour cabinets appear on the right-hand side of your plot at
  your **fourth purchase**, about three minutes in — bare ground until then.
- From the middle of the build you buy **land**: ten expansions, five a side,
  each narrower than the one before, and the walls move outward with
  every one. Prices alternate west and east, so a plot bought cheapest-first
  grows symmetric — and a maxed plot is three and a half times the ground you
  started on.
- Behind the plot's back-right corner is the **generator yard**: one generator
  and one pad, and the pad upgrades what is standing there rather than adding
  another one beside it. Each rung speeds up the droppers and the belt together
  — the belt half is what stops a faster line simply running out of room.
- The plot's **shell** — walls, gates, then four masonry tiers that turn the
  wooden castle to stone and toughen it — is a separate ladder running
  alongside the factory, so scenery never blocks income.
- The **Bat Forge** buttons upgrade your weapon, six tiers from Sahur Bat to
  Eclipse. Bats are ordinary Roblox `Tool`s, so the built-in hotbar and backpack
  equip them.
- The rebirth pad wipes your factory for a compounding payout multiplier.

Roughly **53 minutes** to a full factory, with the rebirth pad affordable at
minute 42 and six rungs still unbought when it lights up. That curve is
measured, not guessed — see *Verification* below.

**What the game should be, and why, is not in this repo's code.** It is
[issue #72](https://github.com/adit-rah/ttt/issues/72) and its five pillars,
mirrored in [`docs/design/`](docs/design/). `docs/design/GAME.md` is the long
version of this section.

---

## Layout of the code

```
src/shared/     replicated to everyone — compiled into BOTH paste builds
  Req.lua           tiny module locator; every file imports through it
  Config.lua        ← ALL the tuning. Prices, geometry, variants, waves, combat.
  Util.lua          number formatting, welding, part helpers
  Net.lua           declares and hands out the RemoteEvents
  Style.lua         world-space text: the only file that may name a font
  Fx.lua            particle / light / sound recipes per variant
  Sound.lua         sound pools (prototype, off)
  ShopMath.lua      price curves for the upgrade shop and utility slot (prototype)
  TungModels.lua    procedural Sahur models: character, drop, NPC rig, weapon
  SwingAnim.lua     procedural melee swings; drives the rig, client-side only

src/server/
  Main.server.lua   boot order
  MapBuilder.lua    world, arena, lighting, plot pads
  DataService.lua   DataStore with retries, session locking, autosave, flush
  Economy.lua       the only place cash is created or spent
  tycoon/           ← the standardized tycoon. One instance per plot.
    Tycoon.lua        the aggregator: Req("Tycoon") resolves here
    Class.lua         the class table, the shared values, the constructor
    Parts.lua         newPart, and the masses a belt machine is made of
    Belt.lua          the conveyor, its geometry and the plot's one speed
    Vault.lua         the collector, the gauge, and where a drop becomes money
    Props.lua         claim rig, rebirth pad, cabinets, yard, generator
    Buttons.lua       the buy buttons, their three states and their ghosts
    Purchase.lua      tryPurchase and install
    Installers.lua    one case per `kind`, and the machines they build
    Drops.lua         spawning what the belt carries, and the drop budget
    Income.lua        Tung/sec, the income tick, the signs
    Land.lua          the ground the plot grows into, reconciled from owned
    Storage.lua       the storage unit's health and repair
    Ownership.lua     assign, release, rebirth
  PlotService.lua   claiming, releasing, offline grace period
  VaultService.lua  the fill gauge and the number on the way out
  SessionService.lua  offline earnings, streaks, the playtime ladder, boosts
  SocialService.lua friend bonus and the invite prompt
  UpgradeService.lua  player upgrades and the utility slot (prototype)
  CombatService.lua bats, swings, damage, knockback, PvP zoning
  NPCService.lua    the raid waves and the boss
  Analytics.lua     seven events, on a schema the verifier counts
  AdminService.lua  chat commands for the things only a save can reach

src/client/
  Main.client.lua   entry point
  HUD.lua           ← owns the only ScreenGui and its two layers
  UiKit.lua         screen-space palette, scaling and safe-area insets
  SessionUI.lua     the session panel and the welcome-back modal
  UpgradeUI.lua     the upgrade shop and the utility chip (prototype)
  CombatClient.lua  hitmarkers, camera shake, knockback
```

**`docs/dev/ARCHITECTURE.md` is the full map** — every module with its
responsibility, its requirers and what it must not do — and
`docs/dev/INVARIANTS.md` is what you read before changing any of it.

### The import convention

Every module starts with exactly this line:

```lua
local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
```

and pulls in siblings with `Req("Config")`. Keep that line byte-identical —
`tools/pack.py` pattern-matches it to flatten the tree for the no-Rojo build.

---

## Adding content

The tycoon is data driven. **You should never edit `src/server/tycoon/` to add a
dropper.** Add a row to `Config.FactoryButtons` — one of four per-track tables
(`FactoryButtons`, `WeaponButtons`, `ArmorButtons`, `PowerButtons`) that
`Config.Buttons` is merged from at require time:

```lua
{
    id = "dropper11", name = "Hyper Tung", price = 20000000000,
    kind = "Dropper", slot = 11, variant = "infinity",
    dropValue = 1000000, dropRate = 1.0,
    blurb = "tung beyond tung.",
},
```

Note the absence of `requires`: **table order is dependency order** within a
track, and the loader derives the chain from it. Restating a requirement is what
once hid a fork that made the whole second storey a dead-end branch.

…then add a distance to `Config.Layout.DropperDist` for slot 11 (how far along
the belt's back leg it sits). That's the whole change. The button, the machine, the drop loop, the save key, the unlock
dependency and the HUD hint all follow automatically.

Supported `kind` values and what each needs:

| kind | fields | what it builds |
| --- | --- | --- |
| `Dropper` | `slot`, `variant`, `dropValue`, `dropRate` | machine + spout + drop loop on belt leg 1 |
| `Upgrader` | `slot`, `variant`, `multiplier` | scanner over belt leg 2 that multiplies passing drops |
| `Belt` | `speedBonus` | speeds up the conveyor |
| `Structure` | `structure` (`"walls"` / `"gates"` / a masonry tier) | plot buildout, one instalment at a time |
| `Gear` | `grants` (a `Config.Bats` id) | anvil display + weapon upgrade |
| `Armor` | `grants` (a `Config.Armor.Tiers` id) | cabinet shelf + max-health upgrade |
| `Power` | `factor`, `variant` | the generator in the yard; speeds up droppers and belt together |
| `Land` | `side`, `width` | one expansion strip of ground, outward from the centre |

To invent a new kind, add an entry to `Tycoon.INSTALLERS`.

### New Tung variants

Add a table to `Config.Variants` (colour, material, scale, `fx` key, optional
light). The `fx` key selects a recipe in `Fx.lua` — `sparkle`, `dust`, `embers`,
`pulse`, `void`, `eclipse`, `galaxy`, `infinity`, or `none`. Add a function to
`Fx.RECIPES` for a new one.

---

## Verification

```bash
python3 tools/verify.py
```

Needs the [Luau CLI](https://github.com/luau-lang/luau/releases) on your PATH
(`luau`, `luau-compile`, `luau-analyze`). It runs thirteen passes:

1. **Syntax** — compiles every file in `src/` and `tools/testing/`
2. **Static analysis** — `luau-analyze`, with the Roblox globals *named* in a
   list. Anything else that reads as a global is an undeclared identifier and
   fails the build; the old blanket "ignore Unknown global" filter is what let a
   deleted `require` take the entire client down for two rounds
3. **Style ownership** — nothing outside `Style.lua` may name a font, an
   outline or a view distance
4. **Prototype flags** — every `Config.Prototypes` flag read is one that exists
   (a graduated flag is deleted, so a leftover guard reads `nil` forever)
5. **Config paths** — every `Config.<path>` read in `src/` names a key that
   exists, resolved through local aliases (`local L = Config.Layout`)
6. **Mixin folders** — a split class's aggregator requires every file in its
   folder, because those requires are code and deleting one silently removes a
   dozen methods
7. **UI geometry** — no card-scale literal in `src/client`; it comes from `Config.UI`
8. **One ScreenGui** — `HUD.lua` owns it, so there is exactly one `UIScale`
9. **Design refs** — every `design:D-NN` cited in the source names a decision
   that exists in `docs/design/DECISIONS.md`
10. **Comment triage** — a comment block over 15 lines has to declare which of
    the four homes it is: `design:D-NN`, `invariant:` or `mechanism:`
11. **Config integrity** — 2300+ assertions: duplicate ids, dangling `requires`,
    slot collisions, upgraders placed upstream of droppers, plots that would
    overlap on the ring, bats that aren't stronger than the tier below…
12. **Runtime specs** — `tools/test.py` runs the game headless under `luau`
13. **Packed build** — regenerates the paste-in scripts and compiles those too

Pass 11 also *simulates the whole economy*, purchase by purchase, and fails the
build if the curve breaks — a first dropper you can't afford, a mid-game wall
over 15 minutes, or a total build outside 45–150 minutes. It prints the curve:

```
  dropper1      0.0m                                     @   0.0m
  dropper2      0.6m  =                                  @   0.6m
  upgrader1     1.2m  ===                                @   1.9m
  ...
  dropper10     2.9m  ========                           @  49.6m
```

If you retune prices, run this before you playtest. It catches in one second
what would otherwise take an hour of grinding to notice.

---

## Tuning cheatsheet

Everything below lives in `Config.lua`.

| Want to… | Change |
| --- | --- |
| Make the game faster/slower overall | scale all `price` values |
| Make raids harder | `Waves.HealthGrowth`, `Waves.DamageGrowth`, `Waves.MaxCount` |
| Make raids more/less lucrative | `Waves.RewardBase`, `Waves.RewardGrowth` |
| Turn raids off entirely | `Waves.Enabled = false` |
| Allow PvP everywhere | `Combat.ArenaPvP = false` |
| Change how hard bats hit | `Config.Bats[n].damage / cooldown / crit` |
| More or fewer plots | set MaxPlayers in Game Settings (clamped to `World.MinPlots`..`MaxPlots`, 4–10) — the ring sizes itself around the count |
| Bigger plots | `World.PlotSize`; then move `Layout.BeltStart/Corner/End/CollectorAt` and the floor furniture in `Layout` to match — the verifier will tell you what no longer fits |
| Plots further apart | `World.PlotGap` (the ring radius is solved from it) or `World.MinPlotRadius` (a hard floor on the first ring) |
| Move the conveyor | `Layout.BeltStart` / `BeltCorner` / `BeltEnd`; machines and buttons follow |
| Button / belt height | `Layout.ButtonHeight`, `Layout.BeltY` (verifier rejects anything you'd have to jump onto) |
| Change rebirth pacing | `Rebirth.BaseCost`, `Rebirth.CostGrowth`, `Rebirth.MultiplierPerRebirth` |

---

## Notes on things that are easy to get wrong

A few decisions in here are load-bearing and look arbitrary until they bite:

- **Drops move via a `LinearVelocity` constraint, not a script loop.** Hundreds
  of drops with a per-frame Heartbeat update would be the first thing to melt
  the server. An `AlignOrientation` keeps each one upright and facing back down
  the belt so you see a queue of angry faces instead of rolling logs. The bend
  between the two belt legs is a single trigger part that retargets the
  constraint — still no per-frame work.
- **Swings are procedural `Motor6D.Transform` writes, not uploaded animations.**
  Roblox animations are assets, and this game has none. `SwingAnim.lua` writes
  the joints directly.
- **Those writes must happen on `RunService.PreSimulation`, and nowhere else.**
  The frame runs `PreRender` → render → `PreAnimation` → *Animator writes joint
  transforms* → `PreSimulation` → *transforms applied to parts*. `PreSimulation`
  is the last Luau event before that apply. This shipped broken once: it used
  `BindToRenderStep`, which binds to `PreRender`, so every write was overwritten
  by the Animator later in the same frame and **nothing moved at all**.
  `Enum.RenderPriority` is a bare ordering constant with no engine meaning —
  `Character = 300` does not mark where characters are animated.
- **Multiply into `Transform`, don't assign it.** Assigning deletes the
  Animator's pose for that joint and the arm snaps out of the tool-hold with no
  blending. `SwingAnim` also remembers what it wrote, because the Animator does
  *not* reset `Transform` when it's throttled or when no track is playing, and
  an unguarded multiply would compound into a windmill.
- Poses are expressed in **torso space** and conjugated by each joint's own `C0`
  rotation, which is what lets one set of angles drive both R6 and R15. Joints
  are looked up by name and accepted as either `Motor6D` *or*
  `AnimationConstraint` — R15 characters are migrating to the latter under the
  Avatar Joint Upgrade, and an upgraded character has no `Motor6D`s at all.
- **Swings are drawn by every client, not by the server.** `Motor6D.Transform`
  doesn't replicate. The attacker predicts their own swing from `Tool.Activated`
  (which fires client-side too) and everyone else plays it from the `SwingFx`
  broadcast. Waiting for that round trip before starting the wind-up is what
  makes networked melee feel like mud.
- **Damage lands on the strike frame, not on the click.** It used to resolve on
  the same frame the swing started — a whole animation before the bat visibly
  reached anything. `Combat.SwingStrikeAt` is now the delay, and the verifier
  caps the resulting input-to-damage latency at 250 ms.
- **Buy buttons have three states, not two.** Showing every button at once
  gives the plot no focal point; showing only the next one hides the shape of
  the build. Available buttons are lit and touchable, the next three steps
  stand as dimmed, inert pads with a translucent ghost of the machine where it
  will go, and everything beyond that is hidden. The ghost is built from the
  same `MACHINE_MASSES` description as the real machine, so a silhouette can't
  drift from the thing it previews.
- **One `Highlight` per plot, reparented.** Highlights are capped at 255 per
  client and *disabled ones still occupy a slot*, so the "buy this next" marker
  is a single instance that moves rather than one per button.
- **The vault shell must sit downstream of the collector sensor.**
  `tycoon/Vault.lua` asserts this at build time — if the solid body overlaps the belt run-off it
  walls the conveyor off and nothing can ever be collected.
- **Knockback on players is applied client-side.** The victim's own client owns
  their character's physics, so a server `ApplyImpulse` is silently discarded on
  the next replication tick.
- **`Lighting.Technology` isn't script-writable at runtime.** It's set in the
  Rojo project file; the runtime assignment is wrapped in a `pcall` so the
  paste-in build doesn't take the whole boot sequence down.
- **Camera shake binds after `Enum.RenderPriority.Camera`.** On `RenderStepped`
  it runs before the camera module and gets overwritten every frame.
- **`DataService` refuses to save a profile whose load failed.** Better to lose
  a session than to overwrite a real save with a default one.

---

## Sound

This is the weakest part of the build and the one place you'll want real assets.

Roblox can't synthesise audio at runtime, so a game with no uploads has exactly
two options: engine default sounds, or silence. I used the defaults —
`electronicpingshort.wav` pitched randomly per drop for the "tung", and
`impact_water.mp3` for bat hits. They're placeholders, and they sound like it.

Everything routes through two functions in `Fx.lua`, so swapping them is a
two-line change once you've uploaded your own:

```lua
local TUNG_SOUND   = "rbxassetid://YOUR_ID_HERE"
local IMPACT_SOUND = "rbxassetid://YOUR_ID_HERE"
```

`Fx.tung(part, pitch, volume)` already varies pitch per variant and per drop, so
a single short percussion hit is enough — the layering does the rest. A real
"tung tung tung" sample would carry more of the theme than anything else you
could add.

---

## Roadmap, if you want to keep going

- Pets / helpers that auto-collect drops from the belt
- Bat skins as a cosmetic sink for post-rebirth cash
- Trading Tung between players
- Scaling prices by `profile.rebirths` — without it, rebirths 4 through 12
  collapse into one-to-three-minute loops, and no value of `Rebirth.BaseCost` or
  `CostGrowth` fixes it (it was swept for)

---

Built with `Enum.Material.Wood` and disrespect for sleep.
