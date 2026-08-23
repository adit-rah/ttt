# HANDOFF v20 — the first Studio contact, answered

Adit ran the merged build in Studio. Two findings, both fixed here.

## 1. Every claim pad was dead

`Class.lua`'s constructor still called `self:ensureCabinets()` after #108
deleted the method. `Tycoon.new` threw, `PlotService.build` died, and nothing
after it in the boot ran — no claim hooks, no PlayerAdded wiring, no
autoAssign. The build was green because the harness never runs the real
constructor (specs use metatable fakes) and no lint could see a method name.

Three fixes, in escalating order:
- the call is gone;
- a new verify pass (tycoon method resolution) fails the build on any
  `self:name(` / `tycoon:name(` call that no mixin defines — falsified with
  this exact bug;
- the boot gained a blast door: every service start below the plot loop is
  pcall'd with a loud warn, so an optional service can never again take
  claiming down with it.

## 2. The belt was too far out

Ten maxed plots forced the fixed belt to 751 studs and the world read as
sprawl. The radius's dominant term is MaxPlots (the chord divisor), so:

- **MaxPlots 10 → 8** (set the place's MaxPlayers to 8 — it is a Studio
  setting and nothing in code can enforce it);
- **PlotGap 44 → 28** (walled neighbours make the grass between them dead
  ground);
- belt 751 → **585**, plot edge 681 → **515**, sprint-to-core 21s → **16s**;
- bands re-tightened to 140 / 300 / 420 (roamer reach 500, 15 clear of the
  plot edge);
- the spawn moved BEYOND the belt (680, mid-gap bearing) since the quiet
  strip inside the ring closed — walking inward past the plots is now the
  first thing a session does, which is the tour.

## 3. What only Studio can tell you

1. **Claim, end to end, again.** Join fresh: the 1.5s autoAssign should
   claim, toast and teleport you; stepping on any unclaimed pad should claim
   instantly. This is the exact path that was dead.
2. **The new density.** Walk the belt at 585: do neighbouring maxed plots
   (420 wide, 28 apart) read as distinct buildings or as one estate? The old
   44 gap was chosen for that read at the old radius.
3. **The spawn's walk in.** You now land beyond the ring and walk inward
   past a plot to reach the world. Check the first thirty seconds still
   read, and that the merchant (660) and board (704) sit sensibly on that
   walk.
4. **Bands at the new radii.** The outskirts are 300–420 now; check level-2
   roamers still feel adjacent to the belt rather than a trek away.
