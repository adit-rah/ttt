# Tung Tung Tycoon — Handoff v4

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v3.md` on progression, waves, combat stats and the
verifier. v3 is still the only correct account of **procedural animation** —
read its §2 before you touch `SwingAnim.lua` — and `HANDOFF.md` (v1) is still
right about the base game.

Nine pull requests landed since v3. §2 is the part to read before you change
anything; every entry in it is a bug that shipped, or a trap that is one edit
away from being one.

---

## 1. What changed

| PR | What |
| --- | --- |
| #11 | the handoffs moved into `docs/`, `IDEAS.md` stopped being tracked |
| #12 | progression split into three independent tracks |
| #13 | the weapons cabinet filled in, and the saves it renumbers migrated |
| #14 | the armour cabinet — the first new player stat since launch |
| #15 | one wave at a time, and the next one starts from your clear |
| #16 | raiders got a home, an aggro range and a leash |
| #17 | anti-swarm: clusters, approach rings, a chaser cap |
| #18 | the bat silhouette re-cut as a continuous taper |
| #20 | …and reverted |

### #12–#14 — progression stopped being one line

`Config.Buttons` was 21 buttons in a strictly linear `requires` chain, and the
two weapon unlocks were links *in* it: `batforge` was step 8 and `dropper5`
required it. You could not get a better bat without first buying a specific
upgrader, and you could not continue the factory without buying the bat.

There are now three tables — `FactoryButtons`, `WeaponButtons`, `ArmorButtons` —
merged into one `Config.Buttons` at require time. Each is a chain ordered only
against itself.

**Three tables rather than a `track` field on one array**, because separate
tables let the merge *derive* `requires` from the row above. A hand-typed
`requires` is the most error-prone field in that file — the reachability walk in
the verifier exists because it has been got wrong — and a track that is by
definition a chain should not restate that 21 times. Nothing is lost: the merge
produces `Config.Buttons` exactly as before, so every consumer still iterates one
array.

The weapons ladder went 3 → 6 tiers and the armour ladder is new at 5 (4
purchasable). Armour grants **MaxHealth only**. Flat damage reduction was the
obvious alternative and is worse: Roblox's health bar renders a MaxHealth gain
for free where reduction is invisible, the default `Health` script regenerates a
*percentage* so regen scales along for nothing, and — deciding it — effective HP
under both stats is `health / (1 - dr)`, two variables multiplying into the one
assertion that guarantees a boss cannot burst you down, which passes with 0.13 s
of margin. One monotone stat keeps that assertion one line of arithmetic.

Rebirth now wipes the factory only. That also closed a live bug: it used to clear
`owned` wholesale while leaving `profile.batTier` alone, and `grantBat` is
monotonic — so re-buying `batforge` after a rebirth took 17,000 Tung and did
nothing at all.

### #15–#17 — the raid became an encounter

`NPCService.start` was `while true do startWave(); task.wait(Interval) end` with
no check that the previous wave had cleared. Against a hardcoded 420 s straggler
despawn and a real ~225 s period, two or three waves legally coexisted, and
because `aliveCount` was one global counter labelled with the module-global
`waveNumber`, leftovers from one wave were counted against — and announced as —
the wave after it.

Waves now run a six-phase schedule
(`idle → resting → warning → spawning → active → clear → resting`) driven by a
non-blocking poller. Dead air went from a fixed ~225 s to 32 s measured from
*your* clear.

Raiders were calling `nearestPlayer(position, 500)` every 0.6 s — a radius larger
than the entire plot ring, so there was no such thing as being out of range. They
now spawn on the rim, walk *in* to a home patch scattered within 44 studs of the
arena centre, mill around it, and commit only to a player who comes within 55.
They break off at 85, or when dragged more than 72 studs from home.

Anti-swarm is three things: clusters instead of one synchronised ring, an
approach ring 6.5 studs around the target (under `AttackRange`, so it costs no
damage output), and a cap of 8 raiders engaging any one player.

### #18 / #20 — the bat, built and taken back out

The shipped silhouette is a constant handle, one 0.55-tall step, then a constant
barrel — 11% of the length spent on the handle→barrel sweep where a real bat
spends about a third. #18 replaced it with ten cylinders sampling a curve held in
`Config.BatShape`, and put the profile in Config specifically so the verifier
could see it: a geometric change inside a model function is otherwise
unassertable.

The assertions were real. One measured the exact defect — the fraction of length
spent crossing the middle 20–80% of the diameter range — and the old shape scored
7.6% against a floor of 20%, so it discriminated rather than decorating.

**It still looked wrong, and it was reverted.** The lesson is §5's, and it is the
most useful thing in this document: *passing an assertion is not the same as
looking right.* Two fixes that rode in on #18 stayed, because they were bugs
before it and would be bugs again — the swing trail now spans the bat it draws
(it covered 76% of a `classic` and 50% of an `infinity`), and the face plate's Z
is derived from the barrel radius rather than a literal that happens to match.

---

## 2. Invariants — the landmine list

Additions to `HANDOFF.md` §5 and `HANDOFF_v2.md` §5. Everything there still
applies.

### Progression and persistence

- **`profile.batTier` is an INDEX, not an id.** Inserting a tier renumbers
  everything above it, so a save written yesterday reading `3` meant `void` and
  today means `ash`. That is not an out-of-range value a clamp would catch — it
  is an in-range value that quietly means something weaker. `PROFILE_VERSION` and
  `LEGACY_BAT_TIERS` in `DataService` exist for exactly this, and **the remap
  runs before the clamp** for the same reason.
- **A weapon or armour button is the RECORD of a granted tier and must never
  disagree with the tier itself.** A pre-split save owns `batforge` and
  `batforge2` but none of the rungs now between them, and `grantBat` is
  monotonic — so those rungs would light up and then charge 60,000 Tung to grant
  a bat the player already holds. `reconcile` backfills ownership for any
  `Gear`/`Armor` button whose tier is already reached. Idempotent, and it fixes
  the class rather than the instance.
- **Never rename a button id.** `reconcile` prunes `owned` ids it cannot find in
  Config, so a rename silently un-buys that purchase for every existing player.
  `batforge`/`batforge2` kept their ids through the whole track split for this
  reason.
- **Merging the track tables factory-first is load-bearing.** It leaves every
  factory button with the `order` it had, which is what lets `Tycoon:assign` keep
  replaying installs by sorting on `order`, and what keeps the verifier's
  "requires points at an earlier index" true without modification.
- **A new persisted field needs BOTH DataService edits** — the key in
  `defaultProfile()` *and* the key in the explicit `save()` payload. With only
  the first it defaults correctly, works all session, and is gone at next login.
  (This was already in v2. It is here again because `armorTier` nearly repeated
  it.)

### Waves and raider AI

- **`WarningTime` is load-bearing and is not a pacing dial.**
  `12 × Combat.WalkSpeed 22 = 264` studs against a `MinPlotRadius` of 210 — that
  is what lets a player standing on their own plot get back to the arena before
  the raid lands. Shortening it is the obvious way to close the gap between
  waves and it is the wrong one; shorten `RestTime`. The verifier asserts the
  relationship and says so in the failure message.
- **The leash is measured from the raider's HOME PATCH, and the number it has to
  clear is the plot EDGE.** Raiders spawn on a ring of radius 52, so a leash of
  *L* measured from the spawn point permits a world distance of `52 + L`. The
  plot edge is `MinPlotRadius 210 − PlotSize.Z/2 70 = 140`, **not** the 210 the
  centre suggests. Home-relative the worst case is `44 + 72 + 8 = 124`, and the
  assertion loops the supported player range rather than reading
  `Config.World.PlotRadius`, because the ring is clamped to `MinPlotRadius` for
  4–7 plots and only grows past it at 8+ — the tightest case is not the one this
  server is configured for.
- **The telegraph pose block runs regardless of AI state.** Gating it on `chase`
  freezes a raider mid-swing with its bat overhead the instant it de-aggros.
- **The AI state machine is skipped entirely while a swing is in flight**, so a
  de-aggro on the same frame as an impact cannot cancel the range re-check that
  makes walking out of a telegraph work.
- **`humanoid.WalkSpeed` must keep being written EVERY frame**, and hard-zeroed
  while rooted. `UpgradeService`'s freeze verb anchors the assembly *specifically
  because* that write exists — moving it into a repath branch would break a
  documented contract in another file. Per-state speed scales **multiply** the
  captured `entry.walkSpeed`; they never replace it, or every raider loses the
  jitter `buildNPC` gave it.
- **The AI state is `entry.ai`, not `entry.phase`.** That name is already the
  waddle's sine phase, and reusing it desyncs the walk cycle every time a raider
  changes its mind.
- **The chaser count is recomputed from scratch each snapshot.** A decrement that
  has to happen on de-aggro, on death, on target death *and* on leash is one that
  eventually does not happen in one of them — and the failure mode is a player
  nothing will attack.
- **`MaxChasers` is bounded by the approach ring, not chosen.** A 6.5-stud ring
  has circumference 40.8 and a raider is ~4.5 studs wide, so nine fit shoulder to
  shoulder. Tune `ApproachStandoff` down and the cap silently becomes a queue;
  the verifier asserts the relationship.

### Things the verifier itself got wrong

- **`verify_config.lua` measured the Floors unlock against the END of
  `Config.Buttons`** (`order >= #Config.Buttons - 1`). True only while there was
  one track — appending anything after the factory failed it, on a feature whose
  flag is off. It now reads `trackOrder` against `#Config.Tracks.factory`. Expect
  more of this shape: assertions written against a global that quietly became a
  per-track one.

### Two known defects, not fixed

- **`Tycoon:buildButtons` discards `pos.Y`.** `buttonPosition` returns the
  correct height for a belt machine on any path — including an upper floor —
  and then `buildButtons` builds at `self:at(pos.X, 0, pos.Z)`. **No purchasable
  content can stand on a mezzanine until that line reads `pos.Y`.** It is the
  single blocker for a real second floor.
- **`Config.Floors[1].padDown` overlaps the armour cabinet's slot-2 pedestal.**
  The pad is at `(40, 0, -14)` with a 9×9 footprint; the pedestal added in #14 is
  at `(44, 0, -20)` with a 5×5. They interpenetrate by **3 × 1 studs**. Latent
  only because `Prototypes.Floors` is off. Nothing catches it: the verifier never
  cross-checks floor pads against the floor-furniture list, which is itself the
  fix — add `padUp`/`padDown` to `miscList` and the collision becomes a build
  failure rather than a thing somebody notices in Studio.

---

## 3. The verifier

720 checks at v3, 1180 at the top of #18, **1146 after the revert.**

New families since v3: per-track price monotonicity and reachability, no
requirement crossing a track, one root per track, `trackOrder` consistency, bat
and armour ladder coverage, the side-track detour model, cabinet AABBs against
every other thing on the plot floor, raid pacing, raider aggro/leash geometry,
and anti-swarm ring capacity.

The economy simulation now walks the **factory track only** — that is the spine
whose 45–150 minute pacing the check is about — and the side tracks are paced
against the curve it produces, since with no cross-track requirement the only
thing gating them is price. The metric is **detour**: minutes of your current
income a tier costs, capped at 4.

Current output: 28 buttons (19 factory / 5 weapons / 4 armour), factory build
79.8 min, side tracks 16.4 min of detour (21% against a 35% budget), endgame
4.2e7/sec, first rebirth +9.9 min.

**Its limits have not moved, and two of them bit this round:**

- It sees `src/shared/Config.lua` and nothing else. `Vector3` is a bare table
  with no arithmetic — the harness carries its own `sub`/`len`/`boxPointGap`.
- It cannot reach frame ordering, AI behaviour, or geometry that is not data.
  The bat proved the corollary: moving geometry into Config makes it *checkable*
  without making it *right*.
- **`FloorService.deckPath()` builds a belt path in code**, not in
  `Config.BeltPaths`, so none of the belt-path assertions ever see the mezzanine
  — not that its legs stay on the deck, not that its collector clears the pad,
  not its outboard signs.
- **`Prototypes.Floors = true` fails the build.** `check(on == false)` asserts
  every prototype flag ships off. Turning floors on means graduating it out of
  `Config.Prototypes`, not flipping it.

---

## 4. What is still open

- **DataStore session locking is still missing.** Two servers can load the same
  profile and the last save wins. Untouched by this pass, still the
  highest-severity item in the repo, and it still gates trading.
- **The price curve is 79.8 minutes** against Roblox's 60-minute daily playtime
  credit cap — see `docs/ideas/GROWTH.md` §2, which argues the back third
  currently counts for nothing. `IDEAS.md` P0 #2 has the formula.
- **Nothing from this round has run in Roblox.** Not the cabinets, not the wave
  schedule, not the AI, not the revert. The verifier is a data checker and the
  last two rounds have now produced three separate things — two swing bugs and
  one bat silhouette — that only Studio could judge.
- **Part budget at full scale is still untested**, and this round added to it: a
  26-raider wave is ~546 bat parts, plus cabinets and shelf displays per plot.
- **Raider pathfinding is still naive `MoveTo`** with a jump-if-stuck hack. The
  leash makes it *less* exposed by keeping raiders in the open arena; it does not
  fix it.
- **Still no runtime tests.** A headless smoke test remains the highest-leverage
  unowned item.

---

## 5. Conventions

Unchanged from v3, plus one addition and one correction.

- **Verifier before commit**, `build/` regenerated, `src/` is the source of
  truth, commit messages explain the *why*, config over code.
- **When you fix something geometric, add the assertion.**
- **When the verifier structurally cannot catch it, write it down here instead.**
- **New:** *moving geometry into Config makes it checkable, not correct.* The bat
  did exactly what this document has been telling people to do — put the shape in
  data, write the assertion that measures the defect, prove the assertion
  discriminates against the old shape — and the result still had to be reverted
  on sight. Do it anyway; the assertion is cheap and it catches regressions. Just
  do not let a green verifier stand in for looking at the thing.
