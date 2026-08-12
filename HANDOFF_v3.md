# Tung Tung Tycoon — Handoff v3

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v2.md` on one subject only — procedural animation.
Everything else in v2 is current, and `HANDOFF.md` (v1) is still right about the
base game. Read §2 here before you touch `SwingAnim.lua`; it is short and every
line of it cost a round trip through Studio.

---

## 1. What changed since v2

| PR | What |
| --- | --- |
| #9 | the swing animation never moved anything at all — timing |
| #10 | the swing poses were absolute, stacked, and pointing the wrong way |

Both are the same feature failing twice, in two completely different ways, and
both were invisible to the verifier because neither is expressible as a config
assertion. The lesson at the bottom of §2 is the one worth carrying forward.

### #9 — it never moved anything

`SwingAnim` bound its update with `BindToRenderStep` at
`Enum.RenderPriority.Character + 1`. `BindToRenderStep` binds to `PreRender`,
and a frame runs:

```
PreRender → render → PreAnimation → [Animator writes joint transforms]
          → PreSimulation → [transforms applied to part CFrames]
```

So every `Transform` written was overwritten by the Animator later in the same
frame and discarded before it reached a part. Not a race — structurally
impossible, every frame, every joint, with no error and no log line. Damage
landed, hitmarkers fired, the combo advanced, and the character stood still.

The reasoning was imported from the camera shake, which binds at
`RenderPriority.Camera + 1` and genuinely works — because the default camera
module really is a `BindToRenderStep` binding, so priority ordering applies to
it. The Animator is not one, so no priority value could ever have won.

### #10 — the poses

Once it moved, the first swing started from behind the character's back with the
arm roughly square to an upright body. Three independent faults:

**The tool-hold was counted twice.** Making the animation visible meant
multiplying into `Transform` rather than assigning — the documented way to
*layer* a procedural offset onto a playing track. But these poses were never
offsets: they are absolute angles measured from the bind pose, and the
Animator's tool-hold has already raised the right arm ~90° forward.

```
swing 1 wind-up, as authored     (+0.56, +0.77, -0.31)   up, right, FORWARD
the same pose + the tool-hold    (+0.56, +0.31, +0.77)   up, right, BEHIND
```

**The recovery drove the arm to the wrong place.** It lerped the pose toward
`REST`, which is the *bind* pose — arms at the sides. At full weight that hauled
the arm down to the hip and then snapped it back to the tool-hold when the
weight released.

**The poses pointed the wrong way**, having been written against a half-derived
idea of the frame: the overhead wind-up was pitched in *front* of the shoulder
rather than behind it, the slam's torso lean was inverted, and the off-arm's
roll was mirrored.

---

## 2. Procedural animation — the rules

This supersedes the "Procedural animation" block in `HANDOFF_v2.md` §5.

**Where to write**

- **Write `Motor6D.Transform`, not `C0`.** `Transform` is the channel the
  Animator writes, so it composes with the playing animation and needs no
  restore step when you stop. `C0` is also becoming read-only on character
  joints under the Avatar Joint Upgrade.
- **Write on `RunService.PreSimulation`, and nowhere else.** It is the last Luau
  event before transforms are applied to part CFrames and the first after the
  Animator has written its own. `PreRender` (and therefore `BindToRenderStep`)
  is too early and is silently discarded; `PostSimulation` is too late.
- **`Enum.RenderPriority` has no engine meaning.** It only sequences
  `BindToRenderStep` callbacks against each other. `Character = 300` does not
  mark where characters are animated.
- **Do not "modernise" `PreSimulation` to `Stepped`.** `PreSimulation` passes
  `(deltaTime)`; `Stepped` passes `(timeSinceStart, deltaTime)`. Swapping them
  hands your step function the elapsed run time as its delta and every animation
  finishes on its first frame — invisible again, for a new reason.

**What to write**

- **Decide whether your poses are ABSOLUTE or OFFSETS, and never mix.** Absolute
  poses are blended toward with `current:Lerp(target, weight)`; offsets are
  stacked with `offset * current`. Using the stacking form on absolute poses
  silently adds whatever animation is already playing to every pose you
  authored, which is how the wind-up ended up behind the back.
- **Blending beats stacking for anything that owns a limb.** At weight 0 a lerp
  is exactly the Animator's pose, so a swing starts and ends without a pop and
  never needs to restore anything.
- **Remember what you wrote.** The Animator resets `Transform` before every
  `PreSimulation` — *except* when it is throttled (`Animator.EvaluationThrottled`,
  for distant characters) or when no track is playing. In those frames it is
  still exactly your last write, so an unguarded blend creeps toward the target
  every frame and drifts into a pose nobody authored.
- **Look joints up by name and accept `AnimationConstraint` as well as
  `Motor6D`.** R15 characters are migrating to the former under the Avatar Joint
  Upgrade; an upgraded character has no `Motor6D`s, so any `IsA("Motor6D")`
  filter silently finds nothing. Check the class rather than trusting the name —
  a rig part can hold other children.

**The coordinate frame**

A character faces **-Z**, up is **+Y**, and **+X is its own right**. Both arms
hang along **-Y** from the shoulder. `CFrame.Angles(x, y, z)` composes as
`Rx · Ry · Rz`, so roll is applied first in the hanging frame and pitch then
swings the result up and over.

| | |
| --- | --- |
| pitch 0 | straight down |
| pitch 90 | straight forward, horizontal |
| pitch 180 | straight up |
| pitch >180 | up and **behind** — this is where a wind-up lives |
| roll +90 | out to the character's **right** |
| roll -90 | out to its **left** |

Two traps:

- **The off-arm's roll is not mirrored.** The rotation is applied to both arms
  in the same torso space, so mirroring the sign splays them apart. A two-handed
  pose needs the *left* arm's roll **positive**, reaching across toward the bat.
- **Torso pitch + leans BACK** at the waist (R15) or the root (R6). Load a slam
  with positive pitch and land it with negative.

**Poses are expressed in torso space and conjugated per joint** —
`Transform = C0.Rotation:Inverse() * Q * C0.Rotation` — which is what lets one
set of angles drive both R6 and R15. R6's `RootJoint` is *not* R15's `Waist`:
every R6 limb hangs off the Torso, so a rotation there takes the legs with it.
The torso channel is yaw-only and damped on R6 for that reason.

**Check poses numerically, not by eye.** Evaluate `Rx·Ry·Rz` against `(0,-1,0)`
and read off the direction. Every one of the pose faults above would have been
caught in seconds by doing that, and none of them was catchable by the verifier
— they are not expressible as config assertions, which is precisely why they
survived a review that did catch five other defects in the same file.

---

## 3. The wider lesson

`tools/verify.py` is genuinely good at what it covers, and it caught real bugs
this pass — a boss that could two-shot a full-health player, buy buttons
overlapping on the plot floor, plots under-spaced on their ring. But **both
animation bugs sailed straight through it, and through a careful code review.**

The reason is worth writing down: the verifier checks *data against data*. It
cannot check code against the engine. Anything whose correctness depends on
Roblox's frame ordering, on what an Animator does to a property you also write,
or on which way a character is facing, is outside its reach by construction.

For that class of change there is currently no substitute for opening Studio.
The honest position going in should have been "this is unverified" rather than
"the maths is derived and reviewed" — the maths *was* right both times, and it
did not matter.

---

## 4. Everything else

Unchanged from `HANDOFF_v2.md`, which remains the reference for:

- the plot rescale, the ergonomics pass and the prototypes (§1, §6 there)
- the full landmine list for world geometry, combat, economy and tooling (§5)
- the open list (§7) — **DataStore session locking is still missing and is still
  the highest-severity item in the repo**, the price curve is still 88 minutes
  against a 30–60 minute benchmark, and there are still no runtime tests

Two additions to the open list:

- **The prototypes are still unexercised.** Every flag in `Config.Prototypes`
  still defaults to `false` and none of that code has run in Roblox. Given that
  the *shipped* swing animation was broken in two different ways that only
  Studio could reveal, treat the flag-gated features as less proven than the
  line count suggests.
- **The swing still has not been load-tested with several players swinging at
  once.** Each client animates every character locally, so the per-frame cost
  scales with the number of visible swinging players, not with your own.

---

## 5. Conventions

Unchanged, plus:

- **Verifier before commit**, `build/` regenerated, `src/` is the source of
  truth, commit messages explain the *why*, config over code.
- **When you fix something geometric, add the assertion.**
- **When you fix something that the verifier structurally cannot catch, write it
  down here instead.** That is what §2 is.
