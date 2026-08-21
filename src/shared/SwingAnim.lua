--[[
	SwingAnim.lua — procedural melee swings that move the CHARACTER, not just
	the bat.

	The old swing tweened Tool.Grip, which is the offset of the engine's
	RightGrip weld. That rotates the bat inside a motionless hand: the arm, the
	shoulders and the torso never moved, so a "swing" read as the bat pivoting
	in mid-air. This drives the rig itself.

	WHY NOT AN AnimationTrack? Roblox animations are uploaded assets. This game
	has zero uploads by design (see README), and an animation asset would also
	have to be authored twice, once per rig type. Writing the joints directly
	costs one PreSimulation connection and works on R6 and R15 from the same
	pose data.

	THE FOUR THINGS THAT MAKE THIS WORK
	  1. We write Motor6D.Transform, not C0. Transform is the channel the
	     Animator itself writes into every frame, so it composes with the
	     playing animation and leaves the rig's rest pose (C0/C1) untouched.
	     Stop writing and Roblox's own Animate script takes the limb straight
	     back over, with no restore step. (C0 is also becoming read-only on
	     character joints under the Avatar Joint Upgrade, so it is a dead end.)
	  2. We write on RunService.PreSimulation, and ONLY there. This is the part
	     that was wrong for the whole first version of this file, which used
	     BindToRenderStep at Enum.RenderPriority.Character + 1 and was
	     consequently a no-op: nothing moved, ever.

	     BindToRenderStep binds to PreRender, and the frame goes

	         PreRender -> render -> PreAnimation -> [Animator writes joint
	         transforms] -> PreSimulation -> [transforms applied to parts]

	     so a PreRender write is overwritten by the Animator later in the same
	     frame and is discarded before it ever reaches a part. PreSimulation is
	     the last Luau event before the batch apply. Enum.RenderPriority is a
	     bare ordering constant with no engine meaning; `Character = 300` does
	     not mark where characters are animated, and reading it that way is
	     what produced the bug. The reasoning was imported from the camera
	     shake in CombatClient, where binding at `RenderPriority.Camera + 1`
	     genuinely does work — because the default camera module really IS a
	     BindToRenderStep binding, so priority ordering applies to it. The
	     Animator is not, so no priority value could ever have won.
	  3. We MULTIPLY into Transform rather than assigning it. Assigning throws
	     away the Animator's pose for that joint, so the arm snaps out of the
	     tool-hold with no blending.
	  4. Poses are expressed in TORSO space, not joint space, and converted per
	     joint by conjugating with that joint's own C0 rotation:

	         Transform = C0.Rotation:Inverse() * Q * C0.Rotation

	     R6 and R15 bake completely different rotations into their shoulder C0s,
	     so a raw joint-space angle that raises an R15 arm forwards swings an R6
	     arm out sideways. Conjugating makes "rotate the arm 90 degrees about
	     the torso's X axis" mean the same thing on both rigs, and means this
	     file never has to know a single rig convention.

	This module runs on the CLIENT ONLY. Motor6D.Transform is not replicated, so
	every client plays every swing locally: the attacker predicts their own on
	Tool.Activated and everyone else plays it from the SwingFx broadcast.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local RunService = game:GetService("RunService")

local SwingAnim = {}

local ZERO = Vector3.new(0, 0, 0)

--- invariant: poses are ABSOLUTE torso-space Euler angles in DEGREES —
--- (pitch, yaw, roll),
--- measured from the rig's bind pose — arms hanging straight down. They are not
--- offsets from whatever the character is currently doing; see applyJoint.
---
--- THE FRAME. A Roblox character faces -Z, up is +Y, and +X is its own right.
--- Both arms hang along -Y from their shoulder. So for an ARM joint:
---
---   pitch    0 = straight down      90 = straight forward (horizontal)
---          180 = straight up       270 = straight back
---   roll   +90 = out to the character's RIGHT      -90 = out to its LEFT
---   yaw        = twist about the limb's own length; unused here
---
--- Note "right" and "left" are the CHARACTER's, in torso space, for BOTH arms.
--- The rotation is applied to each arm identically, so a symmetric two-handed
--- pose needs the off-arm's roll to reach ACROSS: positive roll swings the left
--- arm toward the body's centre, negative swings it away. Mirroring the sign,
--- which is the intuitive thing to write, splays the arms apart instead.
---
--- ORDER MATTERS. CFrame.Angles(x, y, z) composes as Rx * Ry * Rz, so roll is
--- applied first, in the hanging frame, and pitch then swings the result up and
--- over. Reading a pair as "point the arm here, then rotate to there" is why
--- these are easier to reason about as a cone than as a direction vector.
---
--- For a TORSO joint (R15 Waist, R6 RootJoint) the same frame applies to the
--- upper body: pitch +  leans BACK, pitch - leans forward, yaw + turns left.
---
--- Choreography lives here rather than in Config because these are drawings,
--- not balance. The timings that damage depends on ARE in Config. design:D-10.
local function P(arm: Vector3, offArm: Vector3?, torso: Vector3?)
	return { arm = arm, offArm = offArm or ZERO, torso = torso or ZERO }
end

--- One entry per step of the combo. `Config.Combat.SwingSteps` (which is
--- ComboMaxStacks + 1, because stack 0 is the first swing of a chain) selects
--- among these. Alternating the direction is what makes a chain read as a combo
--- instead of as the same swing played four times.
SwingAnim.SWINGS = {
	{   -- 1. overhead diagonal: cocked over the right shoulder, chopped down
	    -- across to the left hip. Wind-up pitch is past 180 so the arm goes up
	    -- and BEHIND; at 158 it was raised up and in FRONT, which reads as
	    -- presenting the bat rather than loading a swing.
		name = "diagonal",
		windUp = P(Vector3.new(200, 0, 35), Vector3.new(30, 0, -20), Vector3.new(-6, -30, 0)),
		strike = P(Vector3.new(60, 0, -45), Vector3.new(20, 0, 25), Vector3.new(-10, 28, 0)),
	},
	{   -- 2. backhand: low across the body on the left, swept up to the right
		name = "backhand",
		windUp = P(Vector3.new(55, 0, -70), Vector3.new(25, 0, 20), Vector3.new(-4, 32, 0)),
		strike = P(Vector3.new(120, 0, 60), Vector3.new(30, 0, -18), Vector3.new(-8, -30, 0)),
	},
	{   -- 3. flat horizontal sweep, right to left. Pitch stays near 90 through
	    -- both poses so the arm stays level and only the roll travels — that
	    -- level arc is what distinguishes it from the two diagonals.
		name = "sweep",
		windUp = P(Vector3.new(95, 0, 75), Vector3.new(28, 0, -22), Vector3.new(0, -38, 0)),
		strike = P(Vector3.new(95, 0, -68), Vector3.new(35, 0, 28), Vector3.new(0, 36, 0)),
	},
	{   -- 4. two-handed overhead slam; the combo finisher. Both rolls are
	    -- POSITIVE so the off-arm reaches across to meet the bat instead of
	    -- splaying away from it, and the torso leans back to load and forward
	    -- to land — which is the way round it was NOT written the first time.
		name = "slam",
		windUp = P(Vector3.new(196, 0, 6), Vector3.new(190, 0, 20), Vector3.new(16, 0, 0)),
		strike = P(Vector3.new(58, 0, -4), Vector3.new(62, 0, 12), Vector3.new(-24, 0, 0)),
	},
}

-- The server times its hitbox off the same two numbers, so they live in Config
-- rather than here. If they drift apart, damage stops landing when the bat
-- looks like it connects.
assert(#SwingAnim.SWINGS == Config.Combat.SwingSteps,
	"SwingAnim.SWINGS and Config.Combat.SwingSteps disagree; the combo would repeat a swing")

local active: { [Model]: any } = {}
local bound = false

local function angles(v: Vector3): CFrame
	return CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
end

--- A rig joint by name, accepting either class.
---
--- R15 characters are migrating from Motor6D to AnimationConstraint under the
--- Avatar Joint Upgrade, and an upgraded character has no Motor6Ds at all.
--- Both classes carry C0 and Transform with the same meaning, so everything
--- here works on either — but only if we never filter on Motor6D. The name
--- check alone is not enough: a rig part can hold other children.
local function jointNamed(parent: Instance?, name: string): Instance?
	local joint = parent and parent:FindFirstChild(name)
	if joint and (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) then
		return joint
	end
	return nil
end

--- The rig's joints, found once per swing. Named by ROLE, not by rig: `arm` is
--- whichever joint swings the weapon, `torso` is whichever one twists the upper
--- body relative to the root.
local function jointsFor(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local torso = character:FindFirstChild("Torso")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not torso or not rootPart then
			return nil
		end
		return {
			arm = jointNamed(torso, "Right Shoulder"),
			offArm = jointNamed(torso, "Left Shoulder"),
			-- R6 has no waist. RootJoint is the closest thing, but it is NOT
			-- equivalent to R15's Waist: every R6 limb joint hangs off the
			-- Torso, so a rotation here carries the arms, legs and head with
			-- it and the character bodily leans rather than twisting at the
			-- middle. Yaw only, and damped — that reads as a shoulder turn,
			-- where the raw pose would swing the feet.
			torso = jointNamed(rootPart, "RootJoint"),
			torsoGain = Vector3.new(0, 0.45, 0),
		}
	end

	local rightUpperArm = character:FindFirstChild("RightUpperArm")
	local leftUpperArm = character:FindFirstChild("LeftUpperArm")
	local upperTorso = character:FindFirstChild("UpperTorso")
	return {
		arm = jointNamed(rightUpperArm, "RightShoulder"),
		offArm = jointNamed(leftUpperArm, "LeftShoulder"),
		-- R15's Waist joins LowerTorso to UpperTorso, so the legs stay put
		torso = jointNamed(upperTorso, "Waist"),
		torsoGain = Vector3.new(1, 1, 1),
	}
end

--- Blend a joint from whatever the Animator put there this frame toward an
--- absolute torso-space pose. See the header: conjugating by the joint's own
--- C0 rotation is what makes one set of angles work on both rigs.
---
--- `state` carries, per joint, the Transform we wrote last frame and the pose
--- we blended from. That pair is what stops the pose drifting. Normally the
--- Animator resets Transform before every PreSimulation, so `current` is a
--- fresh pose and there is nothing to undo — but it does NOT reset when the
--- Animator is throttled (it reuses the previous frame's pose for distant
--- characters, see Animator.EvaluationThrottled) or when no track is playing at
--- all. In those frames Transform is still exactly what we wrote, so without
--- this check a partial-weight blend would creep toward the target a little
--- more every frame and the pose would slowly overshoot into a pose we never
--- authored.
local function applyJoint(state, joint: Instance?, rotation: Vector3, weight: number)
	if not joint or not joint.Parent then
		return
	end

	local current = (joint :: any).Transform
	if state.written[joint] == current then
		current = state.baseline[joint]
	end
	state.baseline[joint] = current

	-- BLEND toward the pose, do not stack onto it. Multiplying our rotation
	-- into the Animator's looks right until you remember the tool-hold has
	-- already raised the right arm about 90 degrees forward: a 200-degree
	-- wind-up then becomes 290 and the bat starts somewhere behind the
	-- character's back. Poses are absolute, so the Animator's contribution is
	-- what we blend FROM, not something we add to.
	--
	-- Lerping also makes the weight envelope do the whole job of easing in and
	-- out: at weight 0 this is exactly the Animator's pose, so a swing can
	-- start and end without a pop and without ever needing to restore anything.
	local basis = (joint :: any).C0.Rotation
	local target = basis:Inverse() * angles(rotation) * basis
	local result = current:Lerp(target, weight)
	;(joint :: any).Transform = result
	state.written[joint] = result
end

local function lerpPose(a, b, alpha: number)
	return {
		arm = a.arm:Lerp(b.arm, alpha),
		offArm = a.offArm:Lerp(b.offArm, alpha),
		torso = a.torso:Lerp(b.torso, alpha),
	}
end

local REST = P(ZERO, ZERO, ZERO)

--- Where the rig should be, `t` seconds into a swing of length `duration`.
--- Returns the pose plus a blend weight that fades the whole thing in over the
--- first few frames and out over the tail, so nothing pops when Roblox's own
--- animation takes the limbs back.
local function evaluate(swing, t: number, duration: number)
	local f = math.clamp(t / duration, 0, 1)
	local windUpEnd = Config.Combat.SwingWindUp
	local strikeEnd = Config.Combat.SwingStrikeAt

	local pose
	if f < windUpEnd then
		-- decelerating into the top of the wind-up
		local a = f / windUpEnd
		pose = lerpPose(REST, swing.windUp, 1 - (1 - a) * (1 - a))
	elseif f < strikeEnd then
		-- accelerating through the strike: this is the fast part
		local a = (f - windUpEnd) / (strikeEnd - windUpEnd)
		pose = lerpPose(swing.windUp, swing.strike, a * a)
	else
		-- HOLD the strike and let the weight envelope carry the arm back into
		-- whatever the Animator is doing. This used to lerp the pose toward
		-- REST, which is the bind pose — arms hanging at the sides — so at full
		-- weight the arm was driven down to the hip and then snapped back up to
		-- the tool-hold as the weight finally released. That was the odd ending.
		pose = swing.strike
	end

	-- The weight envelope does all the easing in and out of the Animator's
	-- pose, so it has to reach 1 before the strike and be back at 0 by the end.
	local weight
	local riseEnd = windUpEnd * 0.6
	if f < riseEnd then
		local a = f / riseEnd
		weight = a * a
	elseif f < strikeEnd then
		weight = 1
	else
		local a = (f - strikeEnd) / (1 - strikeEnd)
		weight = (1 - a) * (1 - a)
	end
	return pose, weight
end

--- Start (or restart) a swing on `character`.
function SwingAnim.play(character: Model?, comboIndex: number, duration: number)
	if not character or not character.Parent then
		return
	end
	local swing = SwingAnim.SWINGS[((comboIndex - 1) % #SwingAnim.SWINGS) + 1]
	if not swing then
		return
	end
	active[character] = {
		swing = swing,
		joints = jointsFor(character),
		elapsed = 0,
		duration = math.max(0.15, duration),
		freeze = 0,
		-- per-joint memory of what we wrote and what we layered onto; see
		-- applyJoint for why both are needed
		written = {},
		baseline = {},
	}
end

--- Freeze the pose for a moment. Called on a landed hit: stopping the arc dead
--- for two or three frames is most of what makes a hit feel like it connected
--- with something solid rather than passing through it.
function SwingAnim.hitStop(character: Model?, seconds: number?)
	local entry = character and active[character]
	if entry then
		entry.freeze = math.max(entry.freeze, seconds or 0.07)
	end
end

function SwingAnim.stop(character: Model?)
	if character then
		active[character] = nil
	end
end

local function step(dt: number)
	for character, entry in pairs(active) do
		if not character.Parent then
			active[character] = nil
		else
			if entry.freeze > 0 then
				entry.freeze -= dt
			else
				entry.elapsed += dt
			end

			if entry.elapsed >= entry.duration then
				active[character] = nil
			else
				local joints = entry.joints
				if not joints or not joints.arm or not joints.arm.Parent then
					-- the character can respawn mid-swing
					joints = jointsFor(character)
					entry.joints = joints
				end
				if joints then
					local pose, weight = evaluate(entry.swing, entry.elapsed, entry.duration)
					applyJoint(entry, joints.arm, pose.arm, weight)
					applyJoint(entry, joints.offArm, pose.offArm, weight)
					applyJoint(entry, joints.torso, pose.torso * (joints.torsoGain or ZERO), weight * 0.8)
				end
			end
		end
	end
end

function SwingAnim.start()
	if bound then
		return
	end
	bound = true
	-- PreSimulation, and nothing else. See the header: this is the last Luau
	-- event before Motor6D transforms are applied to part CFrames, and the
	-- first one after the Animator has written its own. A render-step binding
	-- here does nothing at all — that was the original bug.
	--
	-- Do NOT "modernise" this to its deprecated alias Stepped. PreSimulation
	-- passes (deltaTime); Stepped passes (timeSinceStart, deltaTime). With
	-- Stepped, `step` would take the elapsed run time as its dt and every swing
	-- would blow past its duration on the first frame — invisible again, for a
	-- completely different reason.
	RunService.PreSimulation:Connect(step)
end

return SwingAnim
