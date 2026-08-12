--[[
	TungModels.lua — procedural Tung Tung Tung Sahur models.

	Everything here is built from primitives at runtime. That means:
	  * zero dependency on toolbox / free models that can vanish or be moderated
	  * every variant is a parameter change, not a new upload
	  * the whole game is one Rojo sync away from running

	The silhouette: a wooden baseball bat standing on two skinny legs, with
	stick arms, an angry face, and (usually) a smaller bat in one hand.

	Facing convention: the face points along -Z, which matches Roblox's
	CFrame.LookVector and Enum.NormalId.Front.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")

local TungModels = {}

local HALF_PI = math.pi / 2

local function variantOf(name: string)
	return Config.Variants[name] or Config.Variants.classic
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Vertical cylinder helper (Roblox cylinders run along X, so we spin them).
local function cylinder(parent, name, height, diameter, cf, color, material): Part
	local p = part(parent, name, Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, HALF_PI), color, material)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ball(parent, name, diameter, cf, color, material): Part
	local p = part(parent, name, Vector3.one * diameter, cf, color, material)
	p.Shape = Enum.PartType.Ball
	return p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The face — drawn with a SurfaceGui so it costs no extra physics parts.
-- ─────────────────────────────────────────────────────────────────────────────

local function circle(parent: Instance, size: UDim2, pos: UDim2, color: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = pos
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.ZIndex = z
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	return f
end

--- Angry sahur face: wide eyes, hard brows, gritted mouth.
function TungModels.paintFace(facePlate: BasePart, variant, mood: string?, maxDistance: number?)
	mood = mood or "angry"

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Face"
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(200, 200)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.MaxDistance = maxDistance or 0    -- 0 = always render; drops pass ~140
	gui.Parent = facePlate

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local dark = Color3.fromRGB(12, 10, 14)

	-- eye whites
	circle(root, UDim2.fromScale(0.30, 0.30), UDim2.fromScale(0.31, 0.40), variant.eye, 2)
	circle(root, UDim2.fromScale(0.30, 0.30), UDim2.fromScale(0.69, 0.40), variant.eye, 2)
	-- pupils
	circle(root, UDim2.fromScale(0.13, 0.15), UDim2.fromScale(0.33, 0.42), dark, 3)
	circle(root, UDim2.fromScale(0.13, 0.15), UDim2.fromScale(0.67, 0.42), dark, 3)
	-- glint
	circle(root, UDim2.fromScale(0.05, 0.05), UDim2.fromScale(0.30, 0.38), Color3.new(1, 1, 1), 4)
	circle(root, UDim2.fromScale(0.05, 0.05), UDim2.fromScale(0.64, 0.38), Color3.new(1, 1, 1), 4)

	if mood == "angry" then
		for i, x in ipairs({ 0.31, 0.69 }) do
			local brow = Instance.new("Frame")
			brow.Size = UDim2.fromScale(0.30, 0.075)
			brow.Position = UDim2.fromScale(x, 0.245)
			brow.AnchorPoint = Vector2.new(0.5, 0.5)
			brow.BackgroundColor3 = variant.accent
			brow.BorderSizePixel = 0
			brow.Rotation = (i == 1) and 16 or -16
			brow.ZIndex = 5
			brow.Parent = root
			Util.roundedFrame(brow, 6)
		end
	end

	-- mouth
	local mouth = Instance.new("Frame")
	mouth.Size = UDim2.fromScale(0.42, 0.16)
	mouth.Position = UDim2.fromScale(0.5, 0.70)
	mouth.AnchorPoint = Vector2.new(0.5, 0.5)
	mouth.BackgroundColor3 = dark
	mouth.BorderSizePixel = 0
	mouth.ZIndex = 2
	mouth.Parent = root
	Util.roundedFrame(mouth, 10)

	-- teeth
	for i = 0, 3 do
		local tooth = Instance.new("Frame")
		tooth.Size = UDim2.fromScale(0.075, 0.075)
		tooth.Position = UDim2.fromScale(0.325 + i * 0.117, 0.665)
		tooth.AnchorPoint = Vector2.new(0.5, 0.5)
		tooth.BackgroundColor3 = Color3.fromRGB(245, 245, 240)
		tooth.BorderSizePixel = 0
		tooth.ZIndex = 3
		tooth.Parent = root
	end

	return gui
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bat body (no face) — reused by the character, the weapon, and props.
-- ─────────────────────────────────────────────────────────────────────────────

local SHAPE = Config.BatShape

--- Where along the bat, as a fraction from the knob base, the local +Y offset
--- `y` sits. The bat is centred on its origin, so the base is at -Length/2.
local function batFraction(y: number): number
	return math.clamp(y / SHAPE.Length + 0.5, 0, 1)
end

--- Builds a bat aligned along +Y, centred at `origin`. Returns (barrel, handle).
---
--- The shape comes from Config.BatShape rather than from literals here, for two
--- reasons. It is one silhouette used by the character body, the held mini-bat,
--- the weapon Tool and every statue, so it belongs somewhere it can be tuned
--- once. And tools/verify_config can only see Config — putting the profile
--- there is the only way a geometric fix in this file gets an assertion, which
--- is the standing convention.
---
--- `segments` overrides the sampling density. The default is
--- Config.BatShape.Segments; anything built below MiniScaleBelow drops to
--- MiniSegments on its own, because a raider carries two of these and a late
--- wave has 26 raiders.
function TungModels.buildBatBody(parent: Instance, variantName: string, s: number, origin: CFrame, segments: number?): (Part, Part)
	local v = variantOf(variantName)
	s = s * (v.scale or 1)

	local count = segments
		or ((s < SHAPE.MiniScaleBelow) and SHAPE.MiniSegments or SHAPE.Segments)
	local length = SHAPE.Length * s
	local base = -length / 2
	local step = length / count

	-- One stacked cylinder per segment, each sized from the profile sampled at
	-- its own midpoint. This is what replaced a constant handle, a single
	-- 0.55-tall step and a constant barrel: the step WAS the defect.
	local barrel, handle
	local widest = 0
	for i = 1, count do
		local midY = base + (i - 0.5) * step
		local u = batFraction(midY / s)
		local dia = Config.batDiameterAt(u) * s
		-- The grip is the accent colour, the barrel is the wood, and the
		-- boundary is the end of the handle station rather than a magic number.
		local isGrip = u <= SHAPE.Stations[3].at
		local part = cylinder(parent, ("Seg%d"):format(i), step * 1.02, dia,
			origin * CFrame.new(0, midY, 0),
			isGrip and v.accent or v.wood, v.material)
		if isGrip and not handle then
			handle = part
		end
		if dia > widest then
			widest, barrel = dia, part
		end
	end

	-- Rounded crown. Sized to the profile's last station so it meets the barrel
	-- flush instead of stepping back out to full width like the old ball did.
	local crown = Config.batDiameterAt(1) * s
	ball(parent, "Cap", crown, origin * CFrame.new(0, base + length - crown * 0.35, 0), v.wood, v.material)

	-- wood grain rings, on the barrel where they read
	for i = 1, SHAPE.GrainRings do
		local u = 0.74 + (i - 1) * 0.08
		local ring = cylinder(parent, "Grain" .. i, 0.06 * s, Config.batDiameterAt(u) * s + 0.03 * s,
			origin * CFrame.new(0, (u - 0.5) * length, 0), v.accent, v.material)
		ring.Transparency = 0.35
	end

	return barrel or parent :: any, handle or barrel :: any
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Full character
-- ─────────────────────────────────────────────────────────────────────────────

export type BuildOptions = {
	scale: number?,
	anchored: boolean?,
	withEffects: boolean?,
	holdBat: boolean?,
	mood: string?,
	collide: boolean?,
}

--- The full Tung Tung Tung Sahur guy. PrimaryPart is `Core` at the model centre.
function TungModels.build(variantName: string, opts: BuildOptions?): Model
	local o = opts or {}
	local v = variantOf(variantName)
	local s = (o.scale or 1) * (v.scale or 1)

	local model = Instance.new("Model")
	model.Name = "Tung_" .. variantName

	-- invisible physics core, sized to the whole silhouette
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = Vector3.new(1.6 * s, 3.4 * s, 1.6 * s)
	core.CFrame = CFrame.new(0, 0, 0)
	core.Transparency = 1
	core.Anchored = true
	core.CanCollide = o.collide ~= false
	core.CanQuery = true
	core.CanTouch = true
	core.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.35, 0.2, 1, 1)
	core.Parent = model
	model.PrimaryPart = core

	local origin = CFrame.new(0, 0, 0)

	-- legs
	for i, sign in ipairs({ -1, 1 }) do
		local hip = origin * CFrame.new(sign * 0.34 * s, -2.15 * s, 0)
		local leg = cylinder(model, "Leg" .. i, 1.25 * s, 0.26 * s, hip, v.accent, Enum.Material.SmoothPlastic)
		leg.Color = Color3.fromRGB(232, 214, 186)
		local foot = part(model, "Foot" .. i, Vector3.new(0.52 * s, 0.24 * s, 0.92 * s),
			origin * CFrame.new(sign * 0.34 * s, -2.85 * s, -0.18 * s), Color3.fromRGB(60, 48, 40), Enum.Material.SmoothPlastic)
		local c = Instance.new("SpecialMesh")
		c.MeshType = Enum.MeshType.Sphere
		c.Scale = Vector3.new(1, 0.9, 1)
		c.Parent = foot
	end

	-- Body. Placed by its BASE rather than its middle: buildBatBody centres a
	-- bat on the origin it is given, and the legs, arms and face below are all
	-- positioned against where the body's bottom is.
	local bodyLift = (SHAPE.BodyBaseY + SHAPE.Length / 2) * s
	local barrel = TungModels.buildBatBody(model, variantName, o.scale or 1,
		origin * CFrame.new(0, bodyLift, 0))

	-- Face plate, sitting just proud of the body. Its Z offset is DERIVED from
	-- the profile rather than written down: the body used to be a constant 1.34
	-- barrel so a hardcoded -0.66 happened to be flush, and under a continuous
	-- taper the same literal floats the face off the front.
	local faceY = 1.62 * s
	-- How far up the BODY the face sits, measured from the body's own base.
	local faceU = (faceY / s - SHAPE.BodyBaseY) / SHAPE.Length
	local faceRadius = Config.batDiameterAt(faceU) * s / 2
	local face = part(model, "FacePlate", Vector3.new(1.16 * s, 1.16 * s, 0.08 * s),
		origin * CFrame.new(0, faceY, -(faceRadius + 0.02 * s)), v.wood, v.material)
	face.Transparency = 1
	TungModels.paintFace(face, v, o.mood)

	-- Arms. The RIGHT one — the one holding the bat — is built into its own
	-- sub-model so it can hang off a Motor6D instead of being welded rigidly to
	-- the body. Without that joint there is no way to raise a raider's bat:
	-- the R6 rig underneath is entirely invisible, so animating its shoulder
	-- rotates a stick nobody can see.
	local rightArm = Instance.new("Model")
	rightArm.Name = "RightArm"
	rightArm.Parent = model

	local shoulderCF, armRoot
	for _, sign in ipairs({ -1, 1 }) do
		local parent = (sign > 0) and rightArm or model
		local shoulder = origin * CFrame.new(sign * 0.72 * s, 1.15 * s, 0) * CFrame.Angles(0, 0, math.rad(sign * -34))
		local arm = cylinder(parent, "Arm", 1.30 * s, 0.22 * s, shoulder * CFrame.new(0, -0.55 * s, 0),
			Color3.fromRGB(232, 214, 186), Enum.Material.SmoothPlastic)
		arm.Name = (sign < 0) and "ArmLeft" or "ArmRight"
		local hand = ball(parent, "Hand", 0.34 * s,
			shoulder * CFrame.new(0, -1.25 * s, 0), Color3.fromRGB(240, 226, 200), Enum.Material.SmoothPlastic)
		hand.Name = (sign < 0) and "HandLeft" or "HandRight"

		if sign > 0 then
			shoulderCF = shoulder
			armRoot = arm
			-- the held bat rides with the arm, so it goes in the same sub-model
			if o.holdBat ~= false then
				local grip = CFrame.new(hand.Position) * CFrame.Angles(math.rad(-58), 0, math.rad(-18))
				TungModels.buildBatBody(rightArm, variantName, 0.34 * (o.scale or 1), grip * CFrame.new(0, 0.55 * s, 0))
			end
		end
	end

	-- signature effects
	if o.withEffects ~= false then
		Fx.applyVariant(barrel, v)
	end

	-- Assemble. Everything is welded rigidly to the core except the right arm,
	-- whose parts weld to each other and then join the body on one Motor6D —
	-- the only articulated joint on the visible model.
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= core and p ~= armRoot then
			p.Anchored = true
			Util.weld(p:IsDescendantOf(rightArm) and armRoot or core, p)
		end
	end

	if armRoot then
		armRoot.Anchored = true
		local joint = Instance.new("Motor6D")
		joint.Name = "TungArm"
		joint.Part0 = core
		joint.Part1 = armRoot
		-- Pivot at the shoulder. Both C-frames are expressed relative to the
		-- same world point, so an identity Transform reproduces the pose the
		-- parts were built in.
		joint.C0 = core.CFrame:Inverse() * shoulderCF
		joint.C1 = armRoot.CFrame:Inverse() * shoulderCF
		joint.Parent = core
	end

	if not o.anchored then
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Anchored = false
			end
		end
	end

	model:SetAttribute("Variant", variantName)
	return model
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Conveyor drop — deliberately cheap (2 physics parts) because there can be
-- hundreds of these alive at once.
-- ─────────────────────────────────────────────────────────────────────────────

function TungModels.buildDrop(variantName: string, scale: number?): Model
	local v = variantOf(variantName)
	local s = (scale or 0.5) * (v.scale or 1)

	local model = Instance.new("Model")
	model.Name = "Drop"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(2.4 * s, 1.15 * s, 1.15 * s)
	body.Color = v.wood
	body.Material = v.material
	body.Anchored = false
	body.CanCollide = true
	body.CastShadow = false
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.4, 0.1, 1, 1)
	body.CFrame = CFrame.Angles(0, 0, HALF_PI)
	body.Parent = model
	model.PrimaryPart = body

	local face = Instance.new("Part")
	face.Name = "FacePlate"
	face.Size = Vector3.new(0.95 * s, 0.95 * s, 0.06)
	face.Transparency = 1
	face.CanCollide = false
	face.CanQuery = false
	face.CanTouch = false
	face.CastShadow = false
	face.Massless = true
	face.CFrame = body.CFrame * CFrame.Angles(0, 0, -HALF_PI) * CFrame.new(0, 0.55 * s, -0.58 * s)
	face.Parent = model
	TungModels.paintFace(face, v, "angry", 140)
	Util.weld(body, face)

	if v.fx and v.fx ~= "none" then
		-- no PointLight and fewer particles: there can be hundreds of these
		Fx.applyVariant(body, v, { light = false, rateScale = 0.35 })
	end

	model:SetAttribute("Variant", variantName)
	return model
end

--- The world CFrame a drop should be locked to so it rides the belt upright
--- and looking back at whoever is walking alongside it.
function TungModels.dropOrientation(beltDirection: Vector3): CFrame
	local look = CFrame.lookAt(Vector3.zero, -beltDirection.Unit)
	return look * CFrame.Angles(0, 0, HALF_PI)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NPC rig — a real R6 Humanoid so pathfinding, MoveTo and damage all work,
-- with the Tung visual welded on top of invisible limbs.
-- ─────────────────────────────────────────────────────────────────────────────

local function rigPart(model: Model, name: string, size: Vector3, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.Anchored = false
	p.CanCollide = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function motor(parent: BasePart, part0: BasePart, part1: BasePart, name: string, c0: CFrame, c1: CFrame): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = c0
	m.C1 = c1
	m.Parent = parent
	return m
end

export type NPCOptions = {
	scale: number?,
	health: number?,
	walkSpeed: number?,
	displayName: string?,
	boss: boolean?,
}

function TungModels.buildNPC(variantName: string, opts: NPCOptions?): Model
	local o = opts or {}
	local scale = o.scale or 1

	local model = Instance.new("Model")
	model.Name = o.displayName or ("Sahur Raider (" .. variantName .. ")")

	local base = CFrame.new(0, 0, 0)

	local hrp = rigPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1) * scale, base)
	hrp.CanCollide = false

	local torso = rigPart(model, "Torso", Vector3.new(2, 2, 1) * scale, base)
	local head = rigPart(model, "Head", Vector3.new(1.2, 1.2, 1.2) * scale, base * CFrame.new(0, 1.5 * scale, 0))
	local la = rigPart(model, "Left Arm", Vector3.new(1, 2, 1) * scale, base * CFrame.new(-1.5 * scale, 0, 0))
	local ra = rigPart(model, "Right Arm", Vector3.new(1, 2, 1) * scale, base * CFrame.new(1.5 * scale, 0, 0))
	local ll = rigPart(model, "Left Leg", Vector3.new(1, 2, 1) * scale, base * CFrame.new(-0.5 * scale, -2 * scale, 0))
	local rl = rigPart(model, "Right Leg", Vector3.new(1, 2, 1) * scale, base * CFrame.new(0.5 * scale, -2 * scale, 0))

	-- an R6 Humanoid stands on its Torso + Legs; without collision here the
	-- raider sinks through the floor on spawn.
	torso.CanCollide = true
	ll.CanCollide = true
	rl.CanCollide = true

	motor(hrp, hrp, torso, "RootJoint", CFrame.new(0, 0, 0) * CFrame.Angles(-HALF_PI, 0, math.pi), CFrame.new(0, 0, 0) * CFrame.Angles(-HALF_PI, 0, math.pi))
	motor(torso, torso, head, "Neck", CFrame.new(0, 1 * scale, 0) * CFrame.Angles(-HALF_PI, 0, math.pi), CFrame.new(0, -0.5 * scale, 0) * CFrame.Angles(-HALF_PI, 0, math.pi))
	motor(torso, torso, la, "Left Shoulder", CFrame.new(-1 * scale, 0.5 * scale, 0) * CFrame.Angles(0, -HALF_PI, 0), CFrame.new(0.5 * scale, 0.5 * scale, 0) * CFrame.Angles(0, -HALF_PI, 0))
	motor(torso, torso, ra, "Right Shoulder", CFrame.new(1 * scale, 0.5 * scale, 0) * CFrame.Angles(0, HALF_PI, 0), CFrame.new(-0.5 * scale, 0.5 * scale, 0) * CFrame.Angles(0, HALF_PI, 0))
	motor(torso, torso, ll, "Left Hip", CFrame.new(-1 * scale, -1 * scale, 0) * CFrame.Angles(0, -HALF_PI, 0), CFrame.new(-0.5 * scale, 1 * scale, 0) * CFrame.Angles(0, -HALF_PI, 0))
	motor(torso, torso, rl, "Right Hip", CFrame.new(1 * scale, -1 * scale, 0) * CFrame.Angles(0, HALF_PI, 0), CFrame.new(0.5 * scale, 1 * scale, 0) * CFrame.Angles(0, HALF_PI, 0))

	-- the visible guy
	local visual = TungModels.build(variantName, {
		scale = scale * 0.95,
		anchored = false,
		withEffects = true,
		holdBat = true,
		collide = false,
	})
	visual.Name = "Visual"
	local core = visual.PrimaryPart :: BasePart
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	for _, p in ipairs(visual:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Massless = true
			p.CanCollide = false
		end
	end
	visual:PivotTo(torso.CFrame * CFrame.new(0, 0.7 * scale, 0))
	visual.Parent = model

	-- Motor6D (not a weld) so we can waddle it from code
	local sway = motor(torso, torso, core, "TungSway",
		CFrame.new(0, 0.7 * scale, 0), CFrame.new(0, 0, 0))
	sway.Name = "TungSway"

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.MaxHealth = o.health or 100
	humanoid.Health = o.health or 100
	humanoid.WalkSpeed = o.walkSpeed or 13
	humanoid.HipHeight = 0
	humanoid.AutoRotate = true
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
	humanoid.NameDisplayDistance = 120
	humanoid.HealthDisplayDistance = 120
	humanoid.Parent = model

	model.PrimaryPart = hrp
	model:SetAttribute("Variant", variantName)
	model:SetAttribute("IsSahurNPC", true)
	if o.boss then
		model:SetAttribute("IsBoss", true)
	end

	return model
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Weapon
-- ─────────────────────────────────────────────────────────────────────────────

--- How the Tool's visible bat sits relative to its (invisible-ish) Handle box.
--- Named because the trail attachments have to span exactly this and used to be
--- two unrelated literals.
local DECO_SCALE = 0.72
local DECO_ORIGIN_Y = 1.9

--- Builds the Handle part + decoration for a bat Tool.
function TungModels.buildBatTool(batDef): Tool
	local v = variantOf(batDef.variant)

	local tool = Instance.new("Tool")
	tool.Name = batDef.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = ("%d dmg  •  click to swing"):format(batDef.damage)
	-- Held like a sword rather than straight up out of the fist: the grip drops
	-- the bat into the palm and cants it forward so the barrel reads as a blade
	-- you're about to swing. Grip is the offset of the engine's RightGrip weld,
	-- so this is a pose, not an animation, and it costs nothing.
	tool.Grip = CFrame.new(0, -0.15, 0.1) * CFrame.Angles(math.rad(-18), 0, math.rad(-8))

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 1.6, 0.5)
	handle.Color = v.accent
	handle.Material = v.material
	handle.CanCollide = false
	handle.Massless = true
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	local deco = Instance.new("Model")
	deco.Name = "Deco"
	deco.Parent = tool

	-- barrel above the grip
	local origin = CFrame.new(0, DECO_ORIGIN_Y, 0)
	TungModels.buildBatBody(deco, batDef.variant, DECO_SCALE, origin)

	for _, p in ipairs(deco:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Massless = true
			p.CanCollide = false
			p.Anchored = false
			Util.weld(handle, p)
		end
	end

	-- Swing trail, spanning the deco the Tool actually built. These used to be
	-- hardcoded at 0.8 and 3.4 and did NOT scale with the variant, so on `void`
	-- (scale 1.3) the bat was 30% longer than the streak it drew.
	local decoLength = Config.BatShape.Length * DECO_SCALE * (v.scale or 1)
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailTop"
	a0.Position = Vector3.new(0, DECO_ORIGIN_Y - decoLength / 2, 0)
	a0.Parent = handle
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailBottom"
	a1.Position = Vector3.new(0, DECO_ORIGIN_Y + decoLength / 2, 0)
	a1.Parent = handle
	local trail = Fx.trail(a0, a1, v.light and v.light.color or v.wood)
	trail.Name = "SwingTrail"

	tool:SetAttribute("BatId", batDef.id)
	tool:SetAttribute("Damage", batDef.damage)
	tool:SetAttribute("Cooldown", batDef.cooldown)
	tool:SetAttribute("Knockback", batDef.knockback)
	tool:SetAttribute("Reach", batDef.reach)
	tool:SetAttribute("Crit", batDef.crit)

	return tool
end

--- Big anchored decorative statue for the lobby / plot signage.
function TungModels.buildStatue(variantName: string, scale: number): Model
	local model = TungModels.build(variantName, {
		scale = scale,
		anchored = true,
		withEffects = true,
		holdBat = true,
		collide = true,
	})
	model.Name = "TungStatue"
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
		end
	end
	return model
end

return TungModels
