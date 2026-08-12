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
	costs one bound render step and works on R6 and R15 from the same pose data.

	THE THREE THINGS THAT MAKE THIS WORK
	  1. We write Motor6D.Transform, not C0. Transform is the channel the
	     Animator itself writes into every frame, so setting it replaces the
	     playing animation's contribution for that joint and leaves the rig's
	     rest pose (C0/C1) untouched. Stop writing and Roblox's own Animate
	     script takes the limb straight back over.
	  2. We bind AFTER Enum.RenderPriority.Character. That is the point in the
	     frame where character animations are applied; anything written before
	     it is overwritten in the same frame.
	  3. Poses are expressed in TORSO space, not joint space, and converted per
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

--- Poses are torso-space Euler angles in DEGREES: (pitch, yaw, roll).
---
--- The arms hang along -Y at rest and the character faces -Z, so:
---   pitch +90  = arm straight forward       pitch +180 = arm straight up
---   roll  +90  = right arm out to the side  roll  -90  = across the body
---   yaw        = twist
---
--- Choreography lives here rather than in Config because these are drawings,
--- not balance. The timings that damage depends on ARE in Config.
local function P(arm: Vector3, offArm: Vector3?, torso: Vector3?)
	return { arm = arm, offArm = offArm or ZERO, torso = torso or ZERO }
end

--- One entry per step of the combo. `Config.Combat.SwingSteps` (which is
--- ComboMaxStacks + 1, because stack 0 is the first swing of a chain) selects
--- among these. Alternating the direction is what makes a chain read as a combo
--- instead of as the same swing played four times.
SwingAnim.SWINGS = {
	{   -- 1. overhead diagonal, right shoulder down to left hip
		name = "diagonal",
		windUp = P(Vector3.new(158, 0, 34), Vector3.new(24, 0, -18), Vector3.new(0, -32, 0)),
		strike = P(Vector3.new(52, 0, -42), Vector3.new(38, 0, 16), Vector3.new(6, 28, 0)),
	},
	{   -- 2. backhand, low left sweeping up to the right
		name = "backhand",
		windUp = P(Vector3.new(44, 0, -72), Vector3.new(20, 0, 14), Vector3.new(0, 34, 0)),
		strike = P(Vector3.new(104, 0, 58), Vector3.new(34, 0, -12), Vector3.new(-4, -30, 0)),
	},
	{   -- 3. flat horizontal sweep across the body
		name = "sweep",
		windUp = P(Vector3.new(96, 0, 74), Vector3.new(28, 0, 10), Vector3.new(0, -40, 0)),
		strike = P(Vector3.new(92, 0, -66), Vector3.new(46, 0, -20), Vector3.new(0, 38, 0)),
	},
	{   -- 4. two-handed overhead slam; the combo finisher
		name = "slam",
		windUp = P(Vector3.new(176, 0, 12), Vector3.new(170, 0, -12), Vector3.new(-18, 0, 0)),
		strike = P(Vector3.new(26, 0, -6), Vector3.new(32, 0, 6), Vector3.new(26, 0, 0)),
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
			arm = torso:FindFirstChild("Right Shoulder"),
			offArm = torso:FindFirstChild("Left Shoulder"),
			-- R6 has no waist. RootJoint is the closest thing, but it is NOT
			-- equivalent to R15's Waist: every R6 limb joint hangs off the
			-- Torso, so a rotation here carries the arms, legs and head with
			-- it and the character bodily leans rather than twisting at the
			-- middle. Yaw only, and damped — that reads as a shoulder turn,
			-- where the raw pose would swing the feet.
			torso = rootPart:FindFirstChild("RootJoint"),
			torsoGain = Vector3.new(0, 0.45, 0),
		}
	end

	local rightUpperArm = character:FindFirstChild("RightUpperArm")
	local leftUpperArm = character:FindFirstChild("LeftUpperArm")
	local upperTorso = character:FindFirstChild("UpperTorso")
	return {
		arm = rightUpperArm and rightUpperArm:FindFirstChild("RightShoulder"),
		offArm = leftUpperArm and leftUpperArm:FindFirstChild("LeftShoulder"),
		-- R15's Waist joins LowerTorso to UpperTorso, so the legs stay put
		torso = upperTorso and upperTorso:FindFirstChild("Waist"),
		torsoGain = Vector3.new(1, 1, 1),
	}
end

--- Apply a torso-space rotation to a joint. See the header: conjugating by the
--- joint's own C0 rotation is what makes one set of angles work on both rigs.
local function applyJoint(joint: Motor6D?, rotation: Vector3, weight: number)
	if not joint or not joint.Parent then
		return
	end
	local target = angles(rotation)
	if weight < 1 then
		target = CFrame.identity:Lerp(target, weight)
	end
	local basis = joint.C0.Rotation
	joint.Transform = basis:Inverse() * target * basis
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
		local a = (f - strikeEnd) / (1 - strikeEnd)
		pose = lerpPose(swing.strike, REST, 1 - (1 - a) * (1 - a))
	end

	-- ease in over 60ms, ease out over the last 25% of the swing
	local weight = math.min(1, t / 0.06)
	if f > 0.75 then
		weight = math.min(weight, (1 - f) / 0.25)
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
					applyJoint(joints.arm, pose.arm, weight)
					applyJoint(joints.offArm, pose.offArm, weight)
					applyJoint(joints.torso, pose.torso * (joints.torsoGain or ZERO), weight * 0.8)
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
	-- Enum.RenderPriority.Character is where the engine applies character
	-- animation. Bind before it and every write is overwritten the same frame.
	RunService:BindToRenderStep("TungSwingAnim", Enum.RenderPriority.Character.Value + 1, step)
end

return SwingAnim
