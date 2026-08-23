# The asset ledger

Every model, face, weapon and sound in this game is generated in code at
runtime. `D-06` ([#92](https://github.com/adit-rah/ttt/issues/92)) sets the
policy for which of them get made for real: **if a player looks directly at it
and judges the game by it, it should be made. Structure they walk past stays
generated.** This file is the ledger that policy calls for — every generated
asset, where it is built, which bucket it falls in, and what a replacement
inherits.

| bucket | what goes in it |
| --- | --- |
| **stays generated** | structure the player walks past |
| **the storage unit** | arrives with [#93](https://github.com/adit-rah/ttt/issues/93); every raid targets it |
| **needs a real asset** | what the player looks directly at — bats, characters, rigs |
| **audio** | all of it |

Making the assets is [#119](https://github.com/adit-rah/ttt/issues/119)
(bats), [#120](https://github.com/adit-rah/ttt/issues/120) (characters and
drops), [#121](https://github.com/adit-rah/ttt/issues/121) (rigs),
[#122](https://github.com/adit-rah/ttt/issues/122) (audio) and
[#126](https://github.com/adit-rah/ttt/issues/126) (the storage unit). The
detail lives in those issues; a row here points at one and stops.

## What every replacement inherits

Three constraints hold for every entry below, so they are stated once:

- **The same collision footprint.** `tools/verify_config.lua` asserts
  clearances — machines against the belt, walls, pedestals and decks — from
  `Config.Layout` alone. A model of a different size fails those assertions.
- **Degrade to the generated version.** An upload can 404, be moderated, or be
  pulled by a copyright claim. Every builder below stays in the code as the
  fallback, so a missing upload costs appearance and nothing else.
- **Part-count bounds where they bind**, named per entry. The hard ones: 70
  drops in flight per plot times ten plots, and 40 raiders in a wave.

---

## Stays generated

Structure the player walks past. Generating it is fine and cheaper, and every
entry here works today.

| asset | built in |
| --- | --- |
| the conveyor — running surfaces, base, guard rails, end cap, corner sensors | `tycoon/Belt.lua` `buildBelt`. The surface is the only collidable part; rails and cap are dressing. |
| flow chevrons on the floor beside the belt | `tycoon/Belt.lua` `buildFlowMarkers` |
| buy pads and pedestals | `tycoon/Buttons.lua` `buildButtons` |
| ghost previews of unbought machines | `tycoon/Buttons.lua` `buildGhost`, drawn from the same `MACHINE_MASSES` description as the real machine |
| machine silhouettes — dropper and upgrader masses | `tycoon/Parts.lua` `MACHINE_MASSES`, dressed by `tycoon/Installers.lua` (`buildDropperMachine`, `INSTALLERS.Upgrader`). Design-unowned — see below. |
| the generator | `tycoon/Props.lua` `refreshGenerator` |
| the yard — slab and fence | `tycoon/Props.lua` `ensureYard` |
| the cabinets and their signs | `tycoon/Props.lua` `ensureCabinets` |
| the claim rig — pad, beacon, halo, sign | `tycoon/Props.lua` `buildClaimPad` |
| the rebirth pad and ring | `tycoon/Props.lua` `buildRebirthPad` |
| shelf displays — the shelf and its plate | `tycoon/Installers.lua` `buildShelfDisplay`. The statue standing on the shelf is the character — see [#120](https://github.com/adit-rah/ttt/issues/120) below. |
| the plot shell — wall courses, gate leaves, lintels, neon trim | `tycoon/Installers.lua` `buildWallRing`, `hangGateLeaves`. Part count is asserted against `Config.shellPartCount`. |
| the mezzanine — deck, edge and hatch guards, ladder | `src/server/FloorService.lua` `buildDeck`, `buildEdgeGuards`, `buildHatchGuards`, `buildLadder` |
| the world — ground, arena floor, rim and dais, spawn pad, plot pads, edges and totems | `src/server/MapBuilder.lua` `build`, `buildArena`, `buildSpawn`, `buildPlotPad` |
| particle and light recipes — variant effects, purchase bursts, floating text, swing trails, ceiling fixtures | `src/shared/Fx.lua` `RECIPES`, `burst`, `floatingText`, `trail`, `ceilingLight`. Textures are the engine's own (`rbxasset://textures/particles/*`) and cannot be moderated away. |
| screen UI — panels, buttons, the rail, the drawn `personPlus` glyph | `src/client/UiKit.lua`. design:D-05 for why the glyph is drawn. |

---

## The storage unit

**Today's stand-in is the collector**: body, gold trim, funnel mouth, run-off
ramp, collect sensor, fill gauge and a Tung statue on the lid, all built in
`tycoon/Vault.lua` `buildCollector`.

[#93](https://github.com/adit-rah/ttt/issues/93) replaces it with the storage
unit — the largest single object on the plot, with capacity, health and repair.
Every player has one, every raid targets it, and its fill state is how a
visitor reads someone's wealth, so it needs a real model:
**[#126](https://github.com/adit-rah/ttt/issues/126)**.

What the model inherits, beyond the three global constraints:

- The collect sensor stays entirely downstream of the shell —
  `buildCollector` asserts the run-off clearance, because a shell over the
  sensor walls the belt off and nothing is ever collected.
- The fill gauge, the detail board and the `CollectOffline` prompt keep their
  anchors. `VaultService` works out all four gauge values;
  `Tycoon:setVaultGauge` only draws them.
- Fill and damage states have to read from across the ring — the fill state is
  the wealth read, and a broken unit stores nothing.

---

## Needs a real asset

What the player looks directly at and judges the game by. Each has an issue;
the issue owns the scope.

| asset | built in | issue | what the replacement inherits |
| --- | --- | --- | --- |
| bats, six tiers | `src/shared/TungModels.lua` `buildBatBody`, `buildBatTool` | [#119](https://github.com/adit-rah/ttt/issues/119) | an ordinary Roblox `Tool`, so hotbar and mobile fire button keep working; grip matches what `SwingAnim`'s procedural `Motor6D` swings assume; trail attachments span `BAT_BASE`..`BAT_TOP` |
| the Tung character | `src/shared/TungModels.lua` `build` | [#120](https://github.com/adit-rah/ttt/issues/120) | one model serves the arena statue (`MapBuilder.buildArena`), the vault statue (`tycoon/Vault.lua`) and every shelf display; the right arm hangs off the model's one `Motor6D` so a raider's bat can be raised; variants are data-driven treatments, so one asset covers the tier ladder |
| the drop | `src/shared/TungModels.lua` `buildDrop` | [#120](https://github.com/adit-rah/ttt/issues/120) | two physics parts today, and 70 in flight per plot times ten plots is the budget; moved by a `LinearVelocity` with an `AlignOrientation`, so it needs a sensible pivot and a consistent forward axis |
| the face | `src/shared/TungModels.lua` `paintFace` | [#120](https://github.com/adit-rah/ttt/issues/120) | a sixteen-frame `SurfaceGui` on every character, drop, statue and raider; the `MaxDistance` tiers stay — a face drawn at unlimited range was a real, shipped cost |
| the raider and boss rig | `src/shared/TungModels.lua` `buildNPC` | [#121](https://github.com/adit-rah/ttt/issues/121) | an invisible R6 rig with the character welded on; joints are looked up by name and accept `Motor6D` or `AnimationConstraint`; 40 raiders in a wave, 8 engaging; the boss is the same rig at the scale `Config` names |

---

## Audio

All of it. Roblox cannot synthesise audio at runtime, so everything today is an
engine default. [#122](https://github.com/adit-rah/ttt/issues/122) owns the
replacement and calls it the single largest quality gap in the game.

| sound | built in | today |
| --- | --- | --- |
| the tung | `src/shared/Fx.lua` `Fx.tung` (`TUNG_SOUND`) | a short electronic ping, pitched per variant and per drop — one good sample carries the whole line |
| bat impact | `src/shared/Fx.lua` `Fx.impact` (`IMPACT_SOUND`) | a water impact |
| the prototype library — collect, purchase, ui, impact, swing, rebirth, siren | `Config.Sound.Library`, played through `src/shared/Sound.lua`'s pools | engine defaults behind `Config.Prototypes.Sound`; whether real audio graduates that flag is part of #122 |

Swapping a sound is a two-line change: both live entry points route through
`Fx.lua`, and the pooled layer reads asset ids from `Config.Sound.Library`.

---

## Design-unowned

`SYSTEMS.md`'s closing section names three categories the design tree does not
own yet, and this audit confirms all three. The verifier structurally cannot
see any of them. They stay generated under the policy; owning them is open
work under `D-06` and `D-05`.

- **Player-facing copy** is a literal in the module that sends it: every
  notification title and body, every button label, the arena title and
  subtitle, the claim, rebirth, vault and cabinet signs. Only a
  purchase's `name` and `blurb` are data.
- **Machine silhouettes** — the shape of a dropper and an upgrader — are
  `MACHINE_MASSES` in `tycoon/Parts.lua`.
- **The two palettes.** The plot's colour language is `Tycoon.COLORS` in
  `tycoon/Class.lua`, `PALETTE` in `src/server/MapBuilder.lua` and the shell's
  `WALL_COLOR` in `tycoon/Installers.lua`; the screen's is
  `UiKit.PALETTE` and `UiKit.INK` in `src/client/UiKit.lua`.
