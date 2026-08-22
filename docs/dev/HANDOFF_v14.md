# HANDOFF v14 — the walls can be broken

design:D-02, via #124. The walls and the gate carry health, keyed by side and
opening on `tycoon.structureHealth`; toughness is the land level (expansions
owned + 1, no separate ladder); a swing that boxes wall parts lands one hit
per key through CombatService's structure observer; the owner repairs at a
prompt on the stump, inside the raid's warning window; and dents persist as
fractions of full health so they survive the max moving when the plot buys
land.

The arena ring still stands and PvP inside it is unchanged. What died with
this round is the ring's monopoly on the boundary CONCEPT: the wall is the
boundary against mobs now, and structures are hittable wherever they stand —
the arena rule is deliberately not consulted for them. #89 deletes the ring
itself.

## 1. What only Studio can tell you

1. **A break, watched.** `!siege wall_front 2000`: the courses above the sill
   should fall, the sill recolour to the charred stump, and the repair prompt
   appear on it. Then `!siege gate_gateway 2000`: the leaves go, GateService's
   tick nil-skips them without a warn spam.
2. **The repair, held.** The prompt holds for RepairSeconds, refuses a
   visitor, and the wall re-emits — with glazing and leaves intact, because
   repair goes through rebuildWallRing and applyStructureUpgrades.
3. **Bat hitscan on wall parts.** The observer receives whatever
   GetPartBoundsInBox boxed; nobody has watched a real swing box a pier. The
   one-hit-per-swing dedup is specced, the boxing itself is not reachable
   headless.
4. **A dent across a re-log.** Damage a wall to half, leave, rejoin: the
   restore runs in assign after the install replay, and the ring should come
   up dented.
5. **A break DURING a gate tween.** Break the gate while a leaf is moving;
   the tween's target part is destroyed mid-flight.
6. **The prompt through a wall.** RequiresLineOfSight is off; check the
   repair prompt does not read from outside the plot.

## 2. Seams left deliberately open

- **Mob siege ships dark.** `Tycoon:damageStructure` is the door and
  `MobDamageScale` the knob, but the leash cannot reach a wall until #89
  moves it — wiring NPCService in now would be code nothing can execute. The
  INVARIANTS entry is the reminder.
- **A broken wall lets mobs stream in** is pathing, live the moment #89 gives
  mobs a route: the hole is real geometry.
- **#94's raid arithmetic** reads the same return values a wasted swing does:
  `damageStructure` reports what was absorbed, and the gate's 90-second
  worst-case break is the opening beat of the raid pacing.
- **Breaking a wall does not yet alert the owner.** The victim-notification
  loop belongs to #94's anti-grief candidates.
