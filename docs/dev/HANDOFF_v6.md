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

---
---

# Handoff v6 — the growth round

**Brief:** `GROWTH-TODO.md`, worked in parallel with the round above in a
separate worktree. `RECONCILE_v6.md` maps the files the two rounds share and the
order they merge in. Read that first if you are resolving a conflict.

Ten pull requests, all stacked on `#37`.

Where the round above is about the inside of one session, this one is about
whether anyone comes back tomorrow, brings a friend, or taps the icon at all.
Roblox rewrote its recommendation algorithm in June 2026 to score a **28-day
window**, explicitly to stop rewarding games that "win attention with exciting
thumbnails but don't deliver long-term value." Retention stopped being the thing
you fix after you get traffic and became the thing that decides whether you get
any.

**§G2 is the part to read before you change anything.**

---

## G1. What changed

| PR | What |
| --- | --- |
| #37 | **the game runs outside Roblox** — a headless spec harness |
| #41 | the store-page brief, the live-ops calendar, `RECONCILE_v6.md` |
| #43 | the rebirth pad priced as a rung; the 60-minute credit cap asserted |
| #44 | a friend bonus, and an invite button where the number is |
| #45 | **DataStore session locking** — the standing highest-severity defect |
| #46 | one `UiKit`, one `UIScale`, and a safe area |
| #47 | analytics: seven events, and a schema the verifier can count |
| #48 | a vault you can watch fill |
| #50 | offline earnings, streaks, the ladder, the boost and weekend 2× **turned on** |
| #51 | the boss became a shared objective |

### #37 — the sentence that had appeared five times

Every handoff since v1 opens with *"nothing in this round has run in Roblox"*,
and it was true every time because there was no way to make it false. The
verifier reads `Config.lua` and nothing else.

`tools/test.py` assembles the mocks, the real `src/` modules and the specs into
one Lua chunk and runs it under the `luau` CLI. It is a **second consumer of
`tools/pack.py`** — same `BOOTSTRAP` regex, different replacement — so a packer
regression now surfaces as a failing spec rather than as a `build/` nobody
reads.

**What it found immediately was #35**, and the shape of that find is the reason
the harness exists: the generator's contract was asserted six ways in Config and
the assignment it described was never written. `got 37, want 62.16` is
HANDOFF_v5 §5 item 8 — a number that handoff asked a human to verify in Studio,
naming the two wrong answers it might be. It was asked twice, answered zero
times, and **the real answer was a third thing neither round guessed.**

**And then it found that the retention features are correct.** 30 specs across
offline earnings, streaks, the playtime ladder, the boost and the weekend, all
green against code that had never executed. Including the two most likely to be
wrong: day buckets survive New Year's Eve, and a backwards clock pays nothing.

### #45 — session locking

Open in all five previous handoffs. `save()` used `UpdateAsync` with a transform
that **ignored its argument** — a `SetAsync` with retries, last-write-wins by
construction.

The lock lives **inside** the profile record. Roblox has no cross-key
transaction, so the only way to make "only the holder may write" atomic is for
the check and the write to be the same call.

Proven by 17 specs, **mutation-tested against 15 deliberately broken versions of
`DataService` — all 15 caught.** Three of those were only caught after adding
assertions the first pass had missed.

### #50 — the switches, and the three things behind them

`GROWTH-TODO.md` item 2 says *"Don't just flip the switches."* It was right:

- **The Vault Timer was advertised and unbuyable.** `offlineCapLevel` had no
  writer anywhere. The panel dangled a product that did not exist.
- **The playtime ladder was a rejoin farm.** `claimedPlaytime` was
  per-session and never persisted.
- **`profile.unlocks` was a cache of a pure function.** It could only go stale,
  and had — recording `"mezzanine"` forever after the mezzanine became a button.

### #51 — the boss

The raid was already server-wide. What was missing is that the boss was a
*bigger raider* rather than a *shared objective*: credit was strictly
last-hitter, and nobody could see its health.

---

## G2. Invariants — the landmine list

Additions to v1 §5, v2 §5, v4 §2, v5 §2 and §2 above. Everything there applies.

### The harness

- **A mock is a claim about Roblox that only Roblox can settle.** Everything
  `tools/testing/mock/` asserts — that `UpdateAsync` re-runs its transform on
  conflict, that a `nil` return aborts the write, that `IsFriendsWith` throws
  rather than returning `false` on a web failure — is an assumption. Where the
  game depends on one, it is named in §G6.
- **The DataStore mock deep-copies on every read and write.** A mock that stores
  by reference makes every save/load spec a tautology that passes forever.
- **`Players.MaxPlayers` must be a number.** `Config.plotCountFor()` reads it at
  module load inside a `pcall`; leave it nil and the specs run against different
  plot geometry than the verifier, with no error anywhere.
- **The default clock epoch is a Thursday, deliberately.** A weekend default
  would silently double every income assertion in the suite.
- **`_G` is readonly under the `luau` CLI.** Globals are assigned directly.
- **`os` is shadowed, and `os.date` delegates** to the real implementation with
  an explicit timestamp rather than reimplementing the civil calendar — which is
  what keeps `wday` correct for the weekend multiplier.

### Persistence

- **The lock is `stored.__lock`, and it never reaches the profile.**
  `reconcile()` iterates the keys of the fresh *default*, so an extra key in the
  stored blob is structurally invisible. `save()` builds an explicit payload, so
  it cannot leak back. **No `PROFILE_VERSION` bump and no migration** — verify
  that reasoning before you change either.
- **The `UpdateAsync` transform can run more than once.** Assign the outcome,
  never accumulate it; sample `os.time()` *inside* the transform.
- **`SERVER_ID` falls back to the stable string `"studio"`**, not a random id, so
  a Studio restart re-acquires its own leftover lock instead of waiting out the
  stale window. `BindToClose` early-returns in Studio, so nothing releases it.
- **A contended load can now take ~32 seconds**, against milliseconds before.
  Anything that assumes a profile is present shortly after join got weaker. This
  already found one live bug in the other round's admin commands.
- **A sparse numeric-keyed table does not round-trip through the DataStore.**
  JSON turns `{[3] = true}` into a string key, and the playtime ladder silently
  re-opens on every load. It is a `bit32` mask for that reason.

### Screen UI

- **There is exactly one `ScreenGui`, and a lint keeps it that way.** One
  ScreenGui means one `Root` means one `UIScale`, so a new panel cannot bypass
  mobile scaling by accident.
- **The client is guaranteed at least 1280×720 of DESIGN space** at every aspect
  ratio, because the scale divides by `min(vx/1280, vy/720)`. That is what makes
  every existing `UDim2.fromOffset` literal correct by construction.
- **A `UIScale` transforms its whole subtree**, so a shade at `fromScale(1,1)`
  inside a 0.62 layer dims 62% of the screen and leaves a bright border. Both
  layers are sized `fromScale(1/scale)` to cancel exactly that.
- **Do not re-apply the top inset.** `IgnoreGuiInset = false` already pushes the
  ScreenGui below the topbar; subtracting `GetGuiInset()` again is the classic
  double-inset bug.
- **Card-scale geometry belongs to `Config.UI`, and a lint enforces it.**
- **Combat is not touched, deliberately.** The bat is a plain `Tool`, so
  Roblox's mobile fire button drives `Tool.Activated` for free.

### Growth surfaces

- **Never put a continuous value in an analytics custom field.** Three fields per
  event, string values only, and **8,000 unique combinations per experience** —
  a shared budget across every event. The schema sits in `Config.Analytics` so
  the verifier can count it, because every one of those limits fails *silently*.
- **The friend bonus does not bank while you are logged out**, by the same
  mechanism that excludes the boost. A bonus for being in a server with friends
  must not pay while you are in no server.
- **A failed `IsFriendsWith` caches nothing.** Caching a web failure as `false`
  silently deletes the bonus for the rest of the session.
- **The multiplier hook runs on every `Economy.add`** — up to ~10/sec/plot at
  endgame. It must be an O(1) table read, never a web call.
- **Boss scaling is sampled once at `beginWave` and never re-read.** If it
  tracked live player count, someone leaving would change the boss's max health
  under a bar twelve people are watching.
- **The damage ledger takes `before - humanoid.Health`, not `amount`.** A 10k
  overkill on a 2k boss would otherwise buy 80% of the pot.
- **At one eligible player the boss split is algebraically the identity**, and
  the verifier asserts it. A solo server gets byte-for-byte the old boss with no
  branch anywhere in the code.
- **`forceEnd` settles the boss ledger pro-rata before zeroing healths.** The old
  "no reward for a wave nobody finished" is right for raiders and wrong for a
  shared boss — twelve people fighting for five minutes would have got nothing.

### Pacing

- **`Config.Rebirth.BaseCost` is DERIVED and must not be hand-set again.** The
  comment claiming it was "derived from endgame income" was false for two
  rounds. `PriceRung` anchors it to the spine, which guarantees the rungs above
  it are still unbought when the pad lights.
- **`BaseCost` is not the lever, and this is the round's most useful negative
  result.** Sweeping it across a 20× price cut moves the first rebirth about
  **twelve minutes**. `upgrader6` and `dropper10` multiply income ~17× between
  them, so saving instead of buying them is never worth it. **The lever was
  always build length.**
- **The 60-minute credit cap is its own check**, separate from the build-length
  band. One is an opinion someone may widen; the other is a platform fact that
  has to keep refusing when they do.

---

## G3. The tooling

**`tools/verify.py` runs eight passes now**, not five: syntax and analysis cover
`tools/testing/` as well as `src/`; the style lint does not (a mock may name an
`Enum.Font`, and `tools/` is not shipped); two new UI lints; and **`runtime
specs`, which executes the game.**

```
python3 tools/test.py --plain              # the specs alone
python3 tools/test.py --filter offline     # one family
python3 tools/verify.py                    # everything, and regenerates build/
```

Modules that now execute outside Roblox: `Config`, `Util`, `Net`, `Economy`,
`DataService`, `SessionService`, `Tycoon`, `CombatService`, `MapBuilder`,
`Analytics`, `SocialService`, `VaultService`. **`NPCService` and `PlotService`
are still out** — they need `Touched` and a physics step. Widening
`SERVER_MODULES` is real work and should be its own PR.

Every PR in this round falsified every assertion it added. Between them that is
**over 150 deliberate breakages**, each confirmed to fire with the message
written for it. Three found real defects while being checked:

- a `math.clamp` in the verifier that **errors when floor > ceiling**, making the
  check that would have caught a bad pair unreachable — it would have crashed all
  1732 checks with a stack trace instead of reporting one failure;
- two assertions in the vault work that **could not fail** — one measuring a
  lateral pane against the wrong axis, one whose bound was unsatisfiable
  alongside geometry that already existed;
- `Case:warned` and `Case:fired` in the harness, which read a field nothing
  assigns. Dead-on-arrival API, found independently by two PRs within an hour.

**That is now four instances this round of the same shape: a thing that reads as
checked and is not.** With the generator and the `PathTopY` dead key, it is the
round's real theme, and it is worth naming as a class rather than as four
incidents.

---

## G4. What is still open

- **The seventh verifier pass, and it is the top unclaimed item.** A sweep for
  `X = Config.<path>` where the leaf does not exist in `Config.lua` — about
  fifteen lines of Python. Both rounds named it and neither took it; it belongs
  against `main` after both stacks land, touching only `verify.py`. Given the
  theme above, it is the highest-value tooling change available.
- **Rebirths 4 through 12 collapse to one-to-three-minute loops.** Rebirth
  multiplies income while nothing scales the price ladder, so rebuild time falls
  as `M^-(n-1)` while saving time grows only as `(G/M)^(n-1)`. **No value of
  `BaseCost` or `CostGrowth` fixes this** — it was swept for. The lever is
  scaling prices by `profile.rebirths`, which lives in `Tycoon:tryPurchase`.
  Strongest candidate for the next round's item 1.
- **`NPCService` and `PlotService` cannot be specced.**
- **No icon, no thumbnails, no trailer.** `docs/growth/STORE_PAGE.md` removes
  every decision except the drawing, and the drawing still needs a person. It is
  100% of acquisition.
- **The analytics A/B loop cannot start until the events have aggregated** —
  Roblox's charts lag ~24h, and you cannot read a CTR change against a game
  whose retention is also moving.
- **Two of six ranking signals remain permanently zero** by the no-monetization
  decision. The other four have to be exceptional rather than adequate.

---

## G5. What only Studio can tell you

The list is shorter than v5's, and that is the point of §G3 — but the items left
are left because **no harness can reach them**, not because nobody looked.

**Three of these need a populated server.**

1. **Which lateral face the vault gauge landed on.** Derived from `exitDir`. If
   the sign is backwards the gauge faces a wall and the entire feature is
   invisible. **Check this first; it is cheap and it is total.**
2. **Whether the vault reads as a vault filling** or as a bar stuck on a crate.
   And the detail plaque sits at knee height, because the headline board's
   footprint forced it there.
3. **The mobile layout on a real phone.** The shop/NEXT-UPGRADE overlap was
   computed, not seen — it overlaps at the 720px reference height itself with the
   utility slot on. The fix moved the shop to its own column; that needs eyes.
4. **`ScreenInsets` semantics on the 2026 unified topbar.** `pcall`'d with a
   fallback, and `SafeAreaPad = 12` means a wrong guess is a generous gutter
   rather than an amputated button — but it is still a guess.
5. **The shared boss bar on a full server.** Watch whether 2 Hz packets lerp
   smoothly, and whether twelve people can find a boss on the dais.
6. **A boss fought by one player on a full server.** The check says 248s against
   a 300s deadline with the *starting* bat. That is the floor-of-the-experience
   case and it is thin.
7. **The invite prompt actually appearing.** `CanSendGameInviteAsync` can error
   *or* return false under account policy; both paths hide the button, and
   neither has been seen.
8. **Two servers racing one profile.** The specs prove the logic; only Roblox
   proves that `UpdateAsync` re-runs its transform on conflict and that a `nil`
   return aborts the write. **Everything in #45 rests on those two claims.**
9. **Whether any analytics event arrives at all.** `AnalyticsService` is
   published-place-only, and every one of its limits fails by showing nothing
   rather than erroring. The first thing to check is that the funnel is
   non-empty.
10. **Whether stopping at `upgrader5` to save for the rebirth FEELS like a
    choice** rather than like being told to wait. The pad is affordable at minute
    43 with four things still standing that you cannot afford. That is a
    statement about a simulation, not about a person.

---

## G6. Conventions

Unchanged from §6 above, plus three.

- **New: write the spec before the fix, and hand over the red.** #37's generator
  family went red against `ee44387` and green against #35 without changing. That
  is a cleaner falsification than breaking your own fix on purpose, precisely
  because it was not written to make the fix look good.
- **New: a mock is a claim, so write the claim down.** Every place the harness
  assumes Roblox behaviour, §G5 names it. A green suite over a wrong mock is
  more dangerous than no suite, because it reads as evidence.
- **New: when an assertion cannot fail, that is a defect, not a spare.** Four
  showed up this round. Falsifying every assertion is what catches them, which is
  why the convention above it is not optional.
