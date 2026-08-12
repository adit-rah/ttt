# Depth backlog

What to build next, and why. Every item here is grounded in something a
well-received tycoon actually shipped, or in a complaint players actually made
about one — not in "wouldn't it be cool if". Sources are the Roblox DevForum
Creations Feedback boards, published game wikis and changelogs, and the games
themselves: Miner's Haven, Retail Tycoon 2, Restaurant Tycoon 2, Lumber Tycoon
2, Theme Park Tycoon 2, Mall Tycoon, Pet Simulator 99, Steal a Brainrot, Blade
Ball, Bloxburg, Ultimate Mining Tycoon, Factory Town Tycoon.

Difficulty: **S** = a few hours · **M** = about a day · **L** = multi-day.

Prototypes for the P0 and P1 items live on the `prototypes` branch. Nothing
here is on `main` yet.

---

## The six findings that should change the plan

**1. Rebirth is the weakest system in the game.** `Config.Rebirth` grants
exactly one thing: `MultiplierPerRebirth ^ rebirths`. Every well-regarded
tycoon grants **four things per rebirth at once** — a multiplier, starting
cash, permanent capacity, and *a new verb*. War Tycoon's R30–68 grants only a
title and players say so openly; Steal a Brainrot grants gear at every rung
through R18. `MaxRebirths = 25` currently means 25 rungs of nothing but a
number going up.

**2. The build is ~88 minutes; the genre benchmark for first completion is
30–60.** The pricing formula developers actually use is
`price = income_per_sec × seconds_you_want_it_to_take`, with roughly **10s per
button early and 60s+ late**. Anything unaffordable for more than ~90 seconds
gets flagged as broken pacing in feedback threads. `tools/verify_config.lua`
already models and prints this curve, so retuning is a Config edit plus a
verifier run.

**3. Do not stack floor 2 directly on floor 1.** Roblox has an unsolved camera
problem here: opaque ceilings snap the camera to head height, transparent
ceilings let it pop through, and `LocalTransparencyModifier` is continuously
overwritten by the default camera scripts (every "it doesn't work" thread is
this). Restaurant Tycoon 2's elevator pads explicitly *do not need to be
vertically aligned*. **Offsetting the floors sidesteps the entire problem for
free.**

**4. Shipped "elevators" are teleport pairs, not moving platforms.** RT2 and
Mall Tycoon both teleport. TweenService elevators have documented jitter and
players-slide-off bugs and buy you nothing.

**5. Sound is the highest quality-per-hour win available and it is free.**
`rbxasset://sounds/*` ships inside the client — no upload, no moderation, and
it cannot be taken down. The current handoff assumes Track A is blocked until
someone uploads samples. It isn't.

**6. Drops are physics-driven, and that caps everything below.** Multi-line ×
multi-floor multiplies part count against `MaxDropsPerPlot`. Moving to
CFrame-along-a-lane in one batched loop is the prerequisite for most of the
depth in P2.

---

## P0 — do these first

Everything here is **S**, and everything here is directly evidenced.

### 1. A real sound layer, from engine assets · S
`rbxasset://sounds/*` is shipped with the client. Everything routes through
`Fx.tung()` and `Fx.impact()` already, so this is a contained change in
`Fx.lua`.

| Sound | Use |
| --- | --- |
| `electronicpingshort.mp3` | collect — pitch-stack it |
| `snap.mp3` + `bass.mp3` layered | purchase confirm (layering makes stock sounds sound authored) |
| `button.mp3` / `switch.mp3` / `SWITCH3.mp3` | UI, rotated to avoid fatigue |
| `victory.mp3` | rebirth sting |
| `impact_*` / `metal*` / `wood*` | machine thunks, belt impacts |

Pitch-stacking recipe: `PlaybackSpeed = math.min(1 + combo * 0.06, 2)`, combo
decaying after 0.5 s of silence.

Hard rules: **pool 8 instances per sound and round-robin** — never
`Instance.new` per drop. Skip a play if the same sound fired under 40 ms ago.
About 400 live Sound instances is where audio/video desync starts, and
server-side sound spam can take down a 20-player server, so play locally.
`SoundService:PlayLocalSound` for UI; machine sounds parented to parts with
`RollOffMaxDistance ≈ 60` so a neighbour's factory doesn't blare. Route
everything through a `SoundGroup` — "no sound toggle" is a recurring playtest
complaint.

### 2. Re-tune the price curve to 30–60 minutes · S
Apply `price = income_per_sec × target_seconds`, ramping the target from ~10 s
early to ~60 s late. Aim for first purchase under 45 s, and a full build in
30–60 min rather than 88. The verifier prints the curve and will fail the build
if any single purchase crosses 15 minutes of grind.

### 3. Free boost button on a cooldown · S
2× cash for 10 minutes, claimable every 30–60 minutes. This is the
rewarded-video-ad UX with the ad removed. Pet Sim 99's daily streak gives
**+550% for 15 minutes** — a huge multiplier over a short window forces an
active session instead of being banked.

### 4. Server-wide weekend 2× · S
An `os.date("!*t").wday` check. Near-zero code, real concurrency effect. Steal
a Brainrot runs 2× all income Sat 00:00 → Sun 23:59 UTC.

### 5. Collision group `Ore ↔ Ore = false` · S
Kills the entire class of drop pile-up bugs and cuts solver cost, today,
without touching the belt.

---

## P1 — structural depth

### 6. Rebirth grants four things, not one · S–M
Rewrite `Config.Rebirth` on the Steal a Brainrot template. Every rebirth grants
**all four**:

- **Multiplier.** Note SAB uses a *linear* bonus (+1× per rebirth) against an
  *exponential* cost (median 3.5× per step). The real power is in the other
  three.
- **Starting cash.** Removes the early re-grind. This is the anti-frustration
  mechanism and the game currently has nothing like it.
- **Permanent capacity.** +1 dropper slot, +1 upgrader slot, or +belt length.
- **A new verb.** A bat tier, a utility item, an unlock.

Milestone rebirths should unlock *physical space* — SAB opens floor 2 at R2 and
floor 3 at R10. Every rung of `MaxRebirths` needs something on it.

Two cheap ideas worth stealing outright:

- **Mining Tycoon Revival**: most of its rebirth nodes *delete chores* rather
  than add percentages — teleport to the far end of the plot, faster belts,
  spawn at your own base. Ten-line scripts, disproportionate player affection.
- **Mall Tycoon**: a **cosmetic branch** (plot recolours, decor). Zero balance
  cost, real player value. Tier 1–3 nodes cost 1 point and tier 4 costs 2, which
  buys a depth-vs-breadth choice for free.

If you go points-based, `p = k·√(lifetime/scale)` is AdVenture Capitalist's
form: each rebirth ends up ~3–4× harder than the last, which reads as fair.
Cookie Clicker's cube root is slower; Egg Inc's `^0.14` needs 128× to double.

### 7. Player upgrade shop · S
The genre-standard set. The surprise is how **small** the numbers are — these
are Pet Sim 99's actual figures: Walkspeed **2 tiers, +25% total**; Magnet 7
tiers, +32%; Luck 7 tiers, +50%; Coins 8 tiers, +54%. Costs span 180 → 39M.
**Seven-ish tiers, +5–8% each, cost ×4–6 per tier.** The big multipliers belong
in rebirth, not here.

```lua
WalkSpeed = 22 * (1 + 0.06 * L),  L = 0..8   cost = 250 * 4^L    -- caps ~32, the wall-clip ceiling
Capacity  = 10 + 5 * L,           L = 0..10  cost = 100 * 2.5^L
CashMult  = 1 + 0.08 * L,         L = 0..7   cost = 500 * 5^L
Magnet    = +32% over 7 tiers
```

Cost-curve bands worth knowing: **1.07** for rapid-fire repeatables, **1.15**
for chunky buildings, **2.0–2.5** for ~10-level player stats, **4.0–6.0** for
~7-level premium stats. Avoid polynomials — a developer who shipped
`6*level^3` reported it "extremely steep early, progressively less steep
later"; polynomials misbehave at both ends.

Auto-collect is normally a 150 R$ gamepass and was the single most-endorsed
pass in the feedback threads. With no monetisation here, make it a cash
purchase that lands **inside session one**, around 20 minutes.

### 8. Offline earnings and a welcome-back panel · S
`profile.playtime` is already tracked and unused.

```lua
elapsed  = os.time() - lastSeen          -- os.time(), NEVER tick()
capped   = math.min(elapsed, CAP_HOURS * 3600)
earnings = capped * serverDerivedCPS * RATE
```

**Never `tick()`** — one developer reported accidentally granting 1.6 billion
from a few seconds of drift. **Derive CPS server-side from persisted plot
state**, never from a stored or client-supplied value.

Shipped rates: Steal a Brainrot 3% / 5 h cap; Restaurant Tycoon 3 franchise
$50/hr capped at $250; the DevForum community resource 25% / 24 h. With nothing
to monetise, **20–35% at an 8 h cap, extendable to 12/16/24 h as cash
upgrades** — which turns the cap itself into a goal.

The panel is half the value. State how long you were away, what you earned, and
**whether the cap clipped it** — and if it did, show the upgrade that would have
prevented it. Count-up animation, one big COLLECT button. Never auto-credit
silently: the claim *is* the reward.

### 9. Onboarding — the 30-second script · M
The hard number: *"If your game is a tycoon, they should be placing their first
machine within 30 seconds."* Every second of non-gameplay in the first five
minutes costs roughly 2–3% of the new-player cohort, and one developer measured
**41% quitting before finishing step one of a 20-second tutorial**. Tycoon D1
benchmarks are 30% good / 45% excellent; D7 is 15% / 25%.

1. **0 s** — spawn on or beside the plot, facing button one.
2. **0 s** — the first button costs nothing, or you spawn with exactly enough.
   `StartingCash = 100` against `dropper1` at 50 nearly does this already;
   tighten it so the first purchase is immediate.
3. **0–30 s** — exactly one `Highlight` and one `Beam` at a time. **No text
   box.** (The Highlight half of this shipped in the ergonomics change.)
4. **~10 s** — first income, with a `+$` popup and a ticking counter,
   establishing cause and effect before anything is explained.

*"The best onboarding on Roblox is invisible."* Teach each feature as it becomes
relevant.

### 10. Daily rewards and playtime rewards · S each
- **Daily**: a 7-day loop with milestones at 7/14/30. Bloxburg pays
  $100/$200/$500/$1,000 then premium currency, with trophies at 7/14/30 days
  worth $10k/$30k/$75k. Bucket with `math.floor(os.time()/86400)` UTC — *not*
  `os.date("%j")`, which breaks at the year rollover. Give a **48 h grace
  period** so one missed day doesn't destroy a 20-day streak.
- **Playtime**: Pet Sim 99's ladder is the best-tuned one found, and note the
  deliberately decaying cadence — **5/10/15/20 min → 30/40/50/60 → 75/90 →
  120/180**. Session-scoped; Roblox's own package resets per session. Gate on
  *activity* rather than wall-clock or you're paying people to alt-tab (Roblox
  auto-kicks at ~20 min idle anyway).

### 11. Combat feel, beyond the swing rewrite · S–M
The swing animation, strike-frame damage, hit-stop and raider telegraph have
shipped. What's still missing:

| Layer | Spec |
| --- | --- |
| Hit detection | Raycast hitbox, **7–15 attachments 1 stud apart** along the bat. Benchmarked at 181 raycasts/frame with minimal FPS cost, and it's animation-agnostic so it works with the procedural swing. The current box hitscan still misses fast diagonal arcs at the edges. **M** |
| Knockback | Server-side `LinearVelocity`, direction × 20–100, **destroyed after 0.15–0.25 s**. Leaving it attached is the documented cause of the fling-and-clip-into-ground bug. **S** |
| Damage numbers | Already present via `Fx.floatingText`; add ±0.5 stud X jitter and scale-up on crit so stacked numbers don't smear. **S** |
| Ragdoll | Currently Motor6Ds are just disabled and the model flops. Real `BallSocketConstraint` ragdoll plus `Humanoid.PlatformStand`. **M** |

One free trick worth knowing: a `StringValue` named `toolanim` with value
`"Slash"` or `"Lunge"` inside a Tool triggers Roblox's **built-in, hard-coded
arm animation** with no upload. It fights the procedural swing, so it's not
useful here — but it's the right answer if the procedural system ever has to be
backed out.

### 12. Weapon progression — copy the Steal a Brainrot split · S
SAB's entire weapon ladder is **one archetype reskinned eleven times**
(Iron → Gold → Diamond → Emerald → Ruby → Dark Matter → Flame → Nuclear →
Galaxy → Glitched → Splatter), scaling exactly **one stat: knockback**. Price
×4–5 per tier, gated on rebirth *and* cash. Players chase it because the
material name carries the prestige.

Alongside it sits a **utility slot where each item is a new verb with one
duration number** — freeze 10 s, reverse controls 5 s, ragdoll, petrify 3 s,
invisibility. Variety lives in the utility slot; progression lives in the
weapon slot.

`Config.Bats` currently scales five stats across three tiers. Consider
collapsing toward one and putting the variety in a utility slot. Worth noting
that **SAB has no HP at all** — combat is pure displacement and denial, which
is far simpler and sidesteps every PvP-balance complaint. Blade Ball goes
further: swords are purely cosmetic and 100% of power is in abilities, so there
is no power creep and the top unlock is bounded at ~20K coins.

---

## P2 — vertical and multi-line

### 13. Move drops off physics onto CFrame · M — prerequisite for everything below
Blunt DevForum feedback on a shipped tycoon: *"Using Roblox's physics engine as
your conveyor system isn't the best and you'll have to find a better method."*
One batched server loop advancing each item's `t` along its lane and setting
CFrame. Deterministic, no jams, no overlap, no network ownership handoff.
Process in chunks with a `task.wait()` every ~20 items. Items should be
`Massless`, `CastShadow = false`, minimal descendants.

One freebie regardless: animate `Texture.OffsetStudsV` on the existing belt
texture. "It's running" with zero moving parts.

### 14. Multiple conveyor lines · S once #13 lands
**Parallel lines read better than one long belt, but only if each line carries
something visibly different.** This is the Factorio main-bus principle — one
lane, one item type. Ultimate Mining Tycoon's own guide is explicit: *"run
separate parallel spines only when each has dedicated input ore types."*

Three 30-stud belts side by side occupy the footprint of one 90-stud belt, but
the player stands in one place and sees all three — which also shortens the
walk. Different `Color` and `Size` per lane is enough differentiation in a
code-only game.

**Gate a line as "belt + dropper + collector" in a single button.** Never sell
an empty belt segment; every purchase must move the income number. Ice Tycoon
2's conveyor expander "adds another dropper lane, not just belt length."

**Splitters before mergers.** Splitting is trivially safe. Merging is where the
jams live — Ultimate Mining Tycoon's jam table lists corner buildup from tight
90° turns, idle machines from downstream-slower-than-upstream, and unloader
backlog. Merge only at the sell point. Factory Town Tycoon's changelog is a list
of every bug you'll hit, including raising buffer capacity "to 25 from 10"
because 10 was too small, and conveyor direction arrows they shipped,
redesigned, then re-centred — arrows matter and are hard to get right.

The existing `TurnSensor` + `onTurn` retarget pattern generalises cleanly:
`Config.Layout`'s legs become a list of lines, each with its own Y and
direction. The blockers are all in `Tycoon.lua` — the two-branch `leg()`, the
two explicit `buildRun` calls, the single turn sensor with its hardcoded 1→2
transition, `legOf`'s dropper/else fallthrough, the outboard-normal dot
heuristic (which degenerates for any leg whose midpoint is near the plot
centre), and `setFactoryVisible`'s hardcoded `for i = 1, 4`.

### 15. Floor 2, offset, unlocked by the last button of floor 1 · S
**The documented number-one multi-floor mistake**, quoted from feedback on a
real two-floor tycoon: *"I dislike that you buy floor 2 before you even get
close to finishing floor 1."* The same thread also flagged floor 2 using a
different currency as poorly integrated.

So: the **floor-2 unlock is the last button of floor 1, in the same currency.**
Mall Tycoon does exactly this — the escalator purchase *is* the floor unlock,
and the escalator is the thing you walk on, so there's no ambiguity. Cost anchor
from an RT2 feedback board: **×5 per floor** (10M → 50M → 250M).

**Build floor 2 offset, not stacked** (see finding 3). The first purchase on a
new floor must be affordable within ~90 s of arriving, or you hit the documented
post-unlock stall.

**Each floor gets its own independent dropper → belt → collector loop.** Every
shipped game does this. Cross-floor item transport is the trap: upward conveyors
need velocity ≥ 25 and *still* stick; the fixes are lower density, higher
friction, and several shallow segments rather than one steep ramp. If you want
visible cross-floor flow, use a **gravity chute downward** — free physics, no
tuning.

Keep the collector and the main buy-button spine on the ground floor, with
passive generators upstairs. Never make the player round-trip vertically on the
income loop.

Headroom check against the current plot: the roof sits at y = 20 and the walls
reach y = 13, so there are 20 studs of interior clearance. Everything on the
belt tops out well below that — the tallest are the upgrader post (y = 6), the
dropper arm (6.9), the turn sensor (7.4) and the vault trim (10). Only the vault
statue and its sign anchor (12–13.5) would clash with a mezzanine under the
current roof.

### 16. Teleport-pad elevator with a floor-select UI · S
Two pads, about thirty lines. Fade a black ScreenGui to 1, teleport, fade back —
that handles camera orientation without any CFrame maths. **Sweep the car volume
with `GetPartBoundsInBox` and teleport every Humanoid found**; the classic bug is
moving only the player who touched the pad.

Better still, one feature that is simultaneously elevator, floor select and
camera fix, lifted from Bloxburg: a **▲ / ▼ ScreenGui** that sets the active
floor, hides floors above it, and teleports you to that floor's pad. Bloxburg
binds it to Page Up/Down and also offers hold-Space for a top-down view.

Upper floors also need **perimeter invisible collide-walls** — 1 stud thick,
~6 high, `Transparency = 1`. Falling off is the obvious new failure mode.

### 17. Quests, achievements, leaderboards, codes · S–M each
- **Three daily quests**, seeded with `Random.new(dayNumber + userId)` so every
  server agrees without cross-server sync. Reward **3–10 minutes of that
  player's own production** — income-relative scaling keeps a quest relevant at
  every stage, where SAB's flat $200K–$500K is meaningful early and trivial
  late.
- **In-game achievements, not platform badges** — badges require a 512×512
  image upload. Pet Sim 99's model is passive-accrual tracks that fill by
  playing normally and reward *permanent capacity* (slots) rather than currency.
  Cosmetics are the only status currency a free game has.
- **Leaderboards**: `leaderstats` is free, but an in-world SurfaceGui board is
  the tycoon-native form and it's diegetic — players walk past it.
  OrderedDataStore for global; store **UserIds**, cache resolved names ~5 min,
  write on leave plus a 60 s tick. **Add a weekly-reset board**
  (`Leaderboard_Week_<n>`) — an all-time board is unwinnable for anyone joining
  after week one. Rank **current income/sec**; it's the real skill expression.
- **Codes**: about 80 lines, table server-side only. The virality trick is
  **milestone codes, not dated codes** — *"a dated code rewards whoever happens
  to already be playing; a milestone code rewards the act of pushing the counter
  forward."* Typical payload is cash **plus a timed boost**, and the boost is
  what pulls someone into a session.
- **Friend bonus**: +10% per friend in the server, capped at +30%. Players with
  one in-game friend show 3× higher D30 retention and co-play sessions run 1.9×
  longer. It is the cheapest virality lever available.

---

## P3 — explicitly deprioritised

- **Curved and upward conveyors, moving-platform elevators, belt merging,
  free-placement building.** All M–L with documented failure modes that shipped
  games route around rather than solve.
- **Minimap.** Fixes a plot that shouldn't be that big. Shrink the plot instead.
- **Positional screen shake on purchases.** At tycoon purchase frequency it
  becomes constant vibration with a real motion-sickness cost, and Roblox's
  platform "Reduce Motion" setting does not reach in-experience effects. Use an
  **FOV punch** (2–3°, 200 ms, Sine) instead, and reserve actual shake for
  rebirth.
- **Per-frame `LocalTransparencyModifier` occlusion fading.** Fights the default
  camera scripts. Build roofless instead.
- **Trading.** The highest-risk item found — duping, scams, dispute load. It
  requires session-locked persistence first, which is still the number-one known
  gap.
- **Pets.** The systems are easy (600–1000 lines) but they need models. Only
  viable with a deliberate "geometric creature" art direction composed from
  primitives, with rarity conveyed by particles, glow and scale rather than
  silhouette.

---

## Performance ceilings to design against

| Budget | Limit |
| --- | --- |
| `Highlight` | **255 per client**, and disabled ones still count — delete, don't disable |
| Particles | 400/sec desktop, **100/sec mobile** — and tycoons skew mobile |
| Sounds | ~400 live instances before A/V desync |
| Parts per plot | Ultimate Mining Tycoon enforces **4,000** as a hard cap |
| Active drops | Template guidance is **30–50 per plot**; `MaxDropsPerPlot` is 70 |

## Where the evidence is thin

No sourced stud-count guidance for plot size exists anywhere; the traversal
numbers in this document are arithmetic off Roblox's documented 16 studs/sec.
There is no DevForum debate on show-all versus show-next buy buttons —
progressive reveal is the revealed default, but nobody argues the case. Reddit
was blocked at the search layer, so the player complaints quoted here come from
DevForum Creations Feedback playtests instead: arguably higher quality, but
skewed toward people who post on a developer forum. Fandom wikis returned 402s
throughout, so the Mall Tycoon and War Tycoon figures came via search snippets
and mirrors — treat those exact numbers as good but unverified.
