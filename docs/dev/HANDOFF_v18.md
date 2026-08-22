# HANDOFF v18 — the open world

The round shipped #89: the belt, the bands, PvP everywhere, per-plot sieges
and the central wave. The design is settled in the issue's design-pass comment
(#89, 2026-08-22); the geometry inverts the old ring's meaning — plots at the
rim, danger concentrated inward — and every promise the ring made is restated
in belt form and asserted.

## 1. What moved

- **The belt is fixed.** `Config.beltRadius()` solves the full server's chord
  once; every count spreads on that circle. A contracting ring would have
  walked small servers' homes into the mid band. `MaxPlotsPerRing` and the
  multi-ring path are gone.
- **Three NPC populations, one machine.** `mintNPC` is the one minting site;
  band roamers (`Config.Mobs.Bands`, census-refilled), the central wave
  (unchanged schedule, at the dais, may still climb) and plot sieges
  (`Config.PlotWave`, per-plot state in NPCService) all differ only in where
  they live and what minted them.
- **Plot sieges press structures**: slotted raiders swing at the gate through
  `damageStructure`, then the storage through `damageStorage`, at
  `MobDamageScale = 0.5` — a level set by `Config.plotWaveLevel(expansions,
  rebirths)`, never by server lifetime. Broken gate = open gate: the raiders'
  home rides the objective inward.
- **PvP is everywhere.** The arena gate and `Combat.ArenaPvP` are deleted;
  `canDamage` answers on identity alone. The economic guards (#94's family)
  are the protection.
- **Gates answer to their owner.** Any-player triggering handed a #94 raider a
  free entrance; `GateService` now opens for the plot's owner alone, and NPCs
  never open anything.
- **The spawn moved to the rim** (`World.SpawnRadius = 660`, between plots 1
  and 2). It used to sit in front of the dais, which is now the level-15
  band's living room.
- `!raidme` collapses your own plot's siege rest, the `!wave` arrangement one
  plot down.

## 2. What only Studio can tell you

1. **Gate-press pathing.** Siege raiders MoveTo the gate point and, once it
   breaks, the storage. Naive MoveTo against a wall ring: do they snag on the
   corners, walk the stump line, actually funnel through the opening? The
   unstick jump is the only help they get.
2. **The wander-into-walls case.** A milling siege raider's wander disc can
   overlap the wall; watch whether they grind against it and whether that
   reads as "trying to get in" (good) or as broken (bad).
3. **Band handoff at the edges.** Stand on a band boundary: do a level-2 and a
   level-8 roamer both engage? The bands are contiguous by assertion; the FEEL
   of the seam is unverifiable here.
4. **Roamer density.** 8/8/8 across annuli of very different areas: the
   outskirts ring is huge, so its 8 will feel sparse. The census makes counts
   config; tune by eye.
5. **The spawn pad's surroundings.** It sits in the quiet strip by assertion;
   whether it READS as safe (and whether the belt walk to an unclaimed plot is
   obvious) is a look.
6. **Central wave opt-in.** Nobody is forced to the core now: does the wave
   banner still make sense to a player who never goes? The banner is global;
   consider muting it for players who have never entered the core (a #96
   disclosure question).
7. **Siege siren timing.** The 3-second world-step granularity stretches the
   warning by up to 3s. Confirm the notify lands before the first raider does.
8. **Owner-only gates and visitors.** A helper (#123) arriving at an intact
   plot waits at a shut gate unless the owner is near. Watch whether that
   kills visits; the fix (party access, #102) is already on the roadmap.
9. **Performance at the ceiling.** 83 bodies is asserted under the part
   budget; frame cost of 83 ticking AIs on a full server is a Studio number.
