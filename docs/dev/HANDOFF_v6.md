# Tung Tung Tycoon — Handoff v6

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v5.md` on the generator, the second floor's place in the
build, the price curve and the yard. v5 is still right about world text, the
belt's triggers and the mezzanine's geometry. v4 is still right about raider AI
and the persistence landmines. v3 is still the only correct account of
**procedural animation** — read its §2 before you touch `SwingAnim.lua`.
`HANDOFF.md` (v1) is still right about the base game.

Five pull requests landed, all stacked. §2 is the part to read before you change
anything.

**This round found a shipped bug that made the last two rounds' numbers wrong**,
and it is the first thing in §1. Everything else follows from `TODO.md`.

> **A second round is running in parallel** against `GROWTH-TODO.md` — offline
> earnings, session locking, analytics, mobile UI, the shared boss. Its section
> is appended below this one, attributed separately, and `RECONCILE_v6.md` maps
> the files the two rounds share. Where a fact here and a fact there disagree
> about `Config`, check which landed later.

---

## 1. What changed

| PR | What |
| --- | --- |
| #35 | **the generator was doing nothing, and had been since #32** |
| #36 | the mid game moves, and the floor moves to minute six |
| #38 | a ladder to the mezzanine instead of teleport pads |
| #39 | the yard shrinks to one generator and an upgrade pad |
| #40 | admin chat commands |

### #35 — the generator was doing nothing

`self.powerFactor` was initialised to `1` (`Tycoon.lua:204`), reset to `1` by
`release()` and `rebirth()`, and **never assigned anywhere else**.
`INSTALLERS.Power` called `refreshBeltSpeed()` without setting it. Both readers
of the field — `refreshBeltSpeed`'s `(BeltSpeed + beltBonus) * powerFactor` and
`dropInterval`'s `dropRate / powerFactor` — therefore multiplied by one. **The
belt and every dropper have been running at stock speed since #32.**

`incomePerSecond` reads `Config.powerFactor(has)` *directly* rather than the
cached field, so it was correct the whole time. That asymmetry is why nothing
looked wrong: the plot quoted the full multiplier on the HUD, on the buy button
and through `SessionService`'s offline mirror while producing none of it. Four
rungs, up to 326.5M Tung, and the only thing they bought was a bigger number in
the corner. It was shipping wrong numbers to players, not waiting for a flag.

Three things about it are worth carrying forward:

- **The invariant was written down and nothing enforced it.** v5 §2 says "it
  must multiply belt speed by exactly the factor it multiplies drop rate by",
  and goes on to warn about the install-replay trap *on this exact field*. The
  invariant was written carefully and the assignment it was written about was
  never there at all.
- **The verifier structurally could not catch it.** It reads `Config.lua` and
  nothing else; the defect was a field in `Tycoon.lua`. Every config-level
  assertion about the power ladder passed throughout.
- **v5 §5 item 8 asked a human to check exactly this**, in Studio, and named the
  two wrong answers it might be — 56 and 78.1. It was asked twice across two
  rounds and answered zero times, and the real answer was a third thing neither
  round guessed: **37**.

The fix is one derived assignment. The check went where the defect was: a
Studio-only assert in `refreshBeltSpeed` that recomputes the speed from `owned`.

### #36 — the curve, and the floor

`TODO.md`: progression crawls from step 8 unless you fight, which makes combat a
requirement rather than the accelerant it is meant to be.

| | before | after |
| --- | --- | --- |
| steps 8–17, per purchase | 2.9–4.5 min | 1.9–2.6 min |
| largest single wait | 5.2 min | 2.93 min |
| full build | 67 min | **50 min** |
| floor2 | minute 41.5 (62%) | **minute 6.3 (13%)** |
| weapons cabinet | 41 min, 4 of 5 rungs affordable | 6 min, **1 of 5** |
| armour cabinet | 41 min, 4 of 4 rungs affordable | 6 min, **0 of 4** |

The first five rows of the ladder are byte-identical. The opening four and a
half minutes were not the problem.

**Moving the floor is not really about the floor.** `Config.TrackUnlock` gates
both cabinets on it, so parking it at the halfway mark parked both side ladders
behind it — which is how the verifier came to print *"opens at 41 min with 4 of
5 rungs already affordable"*: a cabinet you empty in one pass because you spent
forty minutes able to afford it and unable to reach it. Moving one button fixes
three ladders, and closes v5 §5 item 4 (twenty minutes of unclearable raids).

### #38–#39 — the ladder, and the yard

The teleport pads were about a hundred lines — a cooldown, an arrival lock and a
`TouchEnded` sweep — whose job was to stop a character resting on a pad from
bouncing off its own physics jitter. A `TrussPart` needs none of it.

The yard was 108 × 40 with three fences, a billboard and **three buy pads**
standing on it from the moment you claimed. It is 28 × 28 with one generator and
one pad, and the pad sells the next rung rather than four pads standing in a row.

### #40 — admin commands

`$`, `$$`, `!give`, `!wave`, `!clear`, `!tp mezz`. The one that pays for itself
is `!give`: it is how you reach the saves the handoffs keep asking to be checked
and nobody can reach by playing. `!give power3` + `!give belt1` is v5 §5 item 8
in two lines.

---

## 2. Invariants — the landmine list

Additions to v1 §5, v2 §5, v4 §2 and v5 §2. Everything there still applies
except where noted below.

### The generator

- **`self.powerFactor` must be ASSIGNED, from `Config.powerFactor(owns)`.** This
  is the bug in #35 and it is the first thing to check if the generator ever
  looks wrong again. Derived, never accumulated: `assign()` replays a save by
  installing every owned rung in `order`, so a `*=` lands on
  `1.19 × 1.42 × 1.68 × 2.00 = 5.67`.
- **Three things read the power factor and they reach it by two different
  routes.** `incomePerSecond` calls `Config.powerFactor(has)` directly;
  `refreshBeltSpeed` and `dropInterval` read the cached `self.powerFactor`
  field. That is exactly why the bug was invisible for two rounds — one route
  was correct by construction and the other was silently absent. **If you touch
  either route, check that both still agree.** The parallel round's headless
  spec pins all three together.
- **The four power rungs stand on ONE pedestal position**, and
  `TrackInfo.power.preview = 0` is what makes that safe. At 1 a dimmed preview
  pad is built *inside* the lit one; at 2 you get the three-pad yard this round
  removed. Asserted.
- **`ensureYard` is idempotent and re-run from `refreshButtons`**, exactly like
  `ensureCabinets`, because `release()` does `props:ClearAllChildren()`. The old
  `buildYard()` ran once from the constructor, so the first owner to leave a
  plot took the slab with them for the rest of the server's life and every later
  owner bought generators that stood in mid-air.
- **The generator is derived from `owned`, not built by the installer**, and it
  must **not** be written to `self.objects[id].machine` — four button entries
  would share one model handle and `release()` destroys through one of them.
- **Nothing goes in `self.cabinetSigns` that is not a cabinet.**
  `updateCabinetSigns` rewrites every entry with `"%s CABINET • %d/%d"`, which
  is why the yard's sign read "POWER CABINET • 0/4".

### The second floor

- **v5 §2's "the floor is the halfway mark" is superseded.** It is the purchase
  straight after `walls`, around minute six, and the assertion that guards it is
  *early but not first*: anchored to `walls` by name, plus a 6–20% band.
- **The floor's deadline is 10 minutes, not 50, because it gates three
  ladders** — itself, weapons and armour. The question stopped being "inside the
  session" and became "with a session left after it".
- **The floor's income share is measured at the moment of purchase**, so its
  band moved when its position did: 25–45% against three owned droppers, not
  10–30% against seven. `mezz_dropper1.dropValue` is 12 for this reason and not
  1400 — at 1400 the upstairs line would be 98% of plot income the second you
  bought it.
- **There is no `Floors.pads` table.** The ladder is a `TrussPart` at
  `x = Layout.GateCentre`, in front of the deck's front edge, and **the deck's
  front guard is built in two pieces with a gap over it**. A guard that closes
  the whole front edge is a ladder to nowhere.
- **`Config.floorBeltPath` states the collector's x** rather than deriving it
  from a pad. It used to read `pads.up.X - padClearance`, so the hopper's
  position was worked out backwards from a piece of furniture.

### The factory track

- **No factory button carries an explicit `requires`.** The loader derives the
  chain from table order, which the file header has always asked for. Restating
  it is what hid the fork: `dropper8` required `upgrader4` while
  `floor2 → mezz_dropper1` hung off `upgrader4` too, so **the mezzanine was a
  dead-end branch** and you could finish the whole ground floor without ever
  buying the floor or seeing either cabinet. The verifier's chain check counts
  requirement-free *roots*, so a fork below the root was invisible to it.
- **Table order is now dependency order.** Moving a row moves its place in the
  build. That is the point, and it is also the new way to get this wrong.

### The yard

- **`Yard.Slots`, `FirstX` and `Spacing` do not exist.** A per-rung slot is how
  the yard grew four generators; the assertion is now `def.slot == nil`.
- **The yard is off-centre for the first time**, so width alone no longer says it
  fits — a 28-stud slab is narrower than the plot and can still hang over its
  edge, eating the ring gap the packing checks solved for without changing
  `Size.X`. Asserted separately.
- **The doorway is checked as a SPAN, not a point.** A corner chunk can sit
  entirely clear of the door it is reached through, and you would step out of
  the back wall onto grass. The old 108-stud yard could not miss.
- **`DoorFrom` is still 46 and the wall spec is unchanged.** The yard moved to
  the door, not the door to the yard — the back edge of the plot *is* the
  dropper row and the left side is the upgrader alley, so the back-right corner
  remains the only legal position.

### Admin

- **`Config.Admin` is not a `Config.Prototypes` flag**, and must not become one:
  the verifier asserts every prototype flag ships `false`, so a prototype flag
  is one you cannot turn on.
- **Check `CreatorType` before trusting `CreatorId`.** For a group-owned place
  `game.CreatorId` is the *group's* id, and comparing a `UserId` to it is
  comparing two namespaces that can collide.
- **`!give` does not check `requirementsMet`, deliberately.** Producing a save
  that holds `power3` without `power2` is the entire point.

---

## 3. The verifier

1706 checks at v5, **1701 now** — the only decrease in the project's history,
and it is honest: four generator slots' worth of geometry became one stand's.
Six families were added or re-authored against that.

**Three assertions were re-authored rather than relaxed**, each because the
premise underneath it was deliberately overturned: the floor-pacing band, the
floor's deadline, and the floor's income share. Each carries a comment naming
what it now guards and why the old one was right for the design it was written
against.

**Two assertions that had never actually run were fixed:**

- The distinct-surface-heights check contained
  `PathTopY = Config.World.PathTopY` — **a key that does not exist**. The value
  was `nil`, so the entry never entered the table and `pairs()` never visited
  it; the check silently covered three surfaces while appearing to cover four,
  and its own `type(y) == "number"` guard could never fire. `YardTopY` was
  missing beside it, so **#32's claim that the yard's surface height was covered
  by that check has never been true.** It iterates names now.
- The vending-machine check finally landed as an assertion. Its comment promised
  it *"becomes an assertion in the round that retunes the curve"*; this is that
  round, and it passes without a cabinet price moving.

**Every new assertion in this round was falsified** — broken against the defect
it exists for, and confirmed to fire with the message written for it. Two are
worth knowing about:

- Moving the floor back to where it was reproduces the old shipped state
  exactly: *"opens at 68% of the build"*, *"4 of 5 rungs already affordable"*.
  They discriminate against the previous design rather than decorating the new
  one.
- `YardTopY` set to `0.30` fires for the first time in the check's existence.

Current output: 34 buttons (21 factory / 5 weapons / 4 armour / 4 power), full
build **50 minutes**, floor at 6.3 (13%), endgame 8.41e7/sec, side tracks 15.5
min of detour (31% of a 35% budget), first rebirth +10 min.

**Its limits have not moved.** It sees `src/shared/Config.lua` and nothing else,
`Vector3` is a bare table with no arithmetic, and it cannot reach frame
ordering, AI behaviour, or anything about how a thing looks. #35 is the sharpest
demonstration of that boundary the project has produced.

---

## 4. What is still open

- **DataStore session locking is still missing.** Untouched by this round, still
  the highest-severity item in the repo. The parallel round is taking it.
- **`Config.Rebirth.BaseCost` was deliberately not touched.** The first rebirth
  still lands ~10 minutes *after* the build ends, so almost nobody sees it —
  GROWTH-TODO item 1's complaint, unaddressed here because `Config.Rebirth`
  belongs to the parallel round. Note it is **coupled to this round**:
  `rebirthMinutes = BaseCost / endgameIncome / 60`, and endgame income moved.
- **`power4` returns 2.23× against a required 2.0×** and is bounded by only two
  purchases existing after it. It is the thinnest margin in the new curve;
  anything that shortens the tail breaks this check first.
- **The side-track budget is at 31% of 35%**, tighter than the 26% it had before,
  because the build got shorter while the cabinets did not get cheaper. 1.83
  minutes of slack.
- **`mezz_dropper1` is 0.002% of endgame income.** It is a minute-eight purchase
  that stops mattering by minute twenty, exactly like `dropper1`. The floor's
  long-term value needs a *second* mezzanine dropper priced into the mid-game —
  a follow-up round, not this one.
- **Raider pathfinding is still naive `MoveTo`.**
- **Part budget at full scale is still untested.**

---

## 5. What only Studio can tell you

The round's brief was three items and none of them are checkable by the
verifier. `!give` exists specifically so this list stops going unanswered — the
last two rounds' worth of it did.

1. **Belt speed with `power3` and `belt1`.** `!give power3`, `!give belt1`, read
   the belt. Must be `(28 + 9) × 1.68 = 62.2` — not 37 (the shipped bug), not 56
   (`28 × 1.68 + 9`), not 78.1 (accumulate-on-replay). **This is the third
   handoff to ask.** It is now two chat commands.
2. **A drop crossing an upgrader on an UNATTENDED plot** — still unanswered from
   v5. Stand on a neighbour's plot or force `PhysicsSteppingMethod = Fixed60`.
3. **The ladder.** Climbable up *and* down, the railing gap is where you arrive,
   and you do not clip the deck edge stepping off. No assertion can tell you
   whether a truss at `x = 14` reads as "the way up" from the gateway.
4. **The mezzanine at minute six.** It arrives when the plot is still nearly
   empty. Does a second storey with one dropper on it read as somewhere to go,
   or as a deck with nothing on it? If it reads as premature, the lever is
   `floor2`'s price — the assertion band is 6–20% and it currently sits at 13%.
5. **Both cabinets at minute six.** This fixes v5 §5 item 4, but it puts a lot
   on the plot early. Watch for the opposite failure: too much at once.
6. **The small yard on a fresh plot.** Is one pad behind the belt legible as
   "there is something back there", or is it now *too* hidden? This is the one
   place this round could plausibly have overcorrected.
7. **The upgrade pad after the first purchase.** Does it read as upgrading the
   generator standing in front of it, or as a second unrelated thing to buy? If
   the latter, `effectLine` gaining a `Power` branch that quotes the factor it
   is coming *from* is the cheapest fix.
8. **The yard doorway with walls AND roof.** Unchanged from v5 §5 item 9 — the
   back-right roof column narrows the clear span to 8.8 studs.
9. **A 40-raider wave on a full server.** `!wave` reaches it now. Watch frame
   time.
10. **Drops at the corners at 74 studs/s** — and note this is the first round
    where 74 is a speed the belt can actually reach, because until #35 the
    generator never multiplied anything.

---

## 6. Conventions

Unchanged from v5 §6, plus one.

- **Verifier before commit**, `build/` regenerated, `src/` is the source of
  truth, commit messages explain the *why*, config over code.
- **When you fix something geometric, add the assertion.**
- **When the verifier structurally cannot catch it, write it down here instead.**
- *Moving geometry into Config makes it checkable, not correct.*
- **Falsify every assertion you add.**
- **When a rule is enforceable by a lint, write the lint.**
- **New: an invariant in a document is not enforcement, and the gap between the
  two is where #35 lived for two rounds.** v5 §2 stated the generator's
  contract precisely and completely. The assignment it described was never
  written, and no amount of care in the prose could have caught that. When you
  write an invariant here, ask what would fail if it were violated — and if the
  answer is "nothing", that is the work, not the document.
