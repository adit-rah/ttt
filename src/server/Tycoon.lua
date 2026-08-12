--[[
	Tycoon.lua — the standardized tycoon.

	One instance per plot. Everything it builds comes from Config.Buttons, so
	adding content is a data edit, never a code edit. The contract for a new
	entry is just:

		kind = "Dropper"   -> needs slot, variant, dropValue, dropRate
		kind = "Upgrader"  -> needs slot, variant, multiplier
		kind = "Belt"      -> needs speedBonus
		kind = "Structure" -> needs structure ("walls" | "roof")
		kind = "Gear"      -> needs grants (a Config.Bats id)

	Add a case to INSTALLERS below to invent a new kind.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local Economy = Req("Economy")
local DataService = Req("DataService")
local CombatService = Req("CombatService")
local MapBuilder = Req("MapBuilder")

local L = Config.Layout
local W = Config.World

local Tycoon = {}
Tycoon.__index = Tycoon

-- Buttons that aren't attached to a belt machine sit in a row on the open
-- floor, spaced further apart than a button is wide. Positions live in Config
-- so they scale with the plot instead of drifting into the wall when it grows.
local MISC_SPOTS = L.MiscButtons

local COLORS = {
	frame     = Color3.fromRGB(118, 122, 130),
	metal     = Color3.fromRGB(160, 164, 172),
	belt      = Color3.fromRGB(62, 62, 68),
	beltLine  = Color3.fromRGB(255, 176, 60),
	buttonOn  = Color3.fromRGB(110, 235, 150),
	buttonOff = Color3.fromRGB(230, 90, 90),
	preview   = Color3.fromRGB(126, 122, 146),
	vault     = Color3.fromRGB(146, 110, 72),
	gold      = Color3.fromRGB(255, 205, 90),
}

-- ─────────────────────────────────────────────────────────────────────────────
-- construction helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function newPart(parent, name, size, cf, color, material, collide)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = collide ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- ── machine geometry ─────────────────────────────────────────────────────────

--- The masses a belt machine is made of: { name, size, offset, y, collide }.
--- Offset is outboard of the belt, y is the centre height, both in the leg's
--- own frame (see Tycoon:segmentCF).
---
--- This exists so the GHOST PREVIEW and the real machine are built from one
--- description. A silhouette hand-copied from the installer is a silhouette
--- that stops matching the machine the first time either is touched.
local MACHINE_MASSES = {
	Dropper = function()
		-- Sized to Layout.MachineFootprint so neighbouring droppers can never
		-- overlap. The arm hangs directly over the running surface, so it is
		-- non-collidable: a tall drop has to pass under it untouched.
		local depth = L.MachineFootprint
		return {
			{ "Base", Vector3.new(depth, 3.6, depth), L.MachineOffset, 1.8, true },
			{ "Core", Vector3.new(depth - 1.4, 2.2, depth - 1.4), L.MachineOffset, 4.7, true },
			{ "Arm", Vector3.new(L.MachineOffset, 1, 1.4), L.MachineOffset / 2, L.BeltY + 5, false },
			{ "Spout", Vector3.new(2.4, 1.8, 2.4), 0, L.BeltY + 4.2, false },
			{ "Nozzle", Vector3.new(1.8, 0.5, 1.8), 0, L.BeltY + 3.2, false },
		}
	end,
	Upgrader = function()
		-- Single post on the OUTBOARD side with a cantilevered beam, rather
		-- than an arch straddling the belt: keeps the inboard walkway clear.
		local reach = L.MachineOffset + L.BeltWidth / 2
		return {
			{ "Post", Vector3.new(1.8, 6, 1.8), L.MachineOffset, 3, true },
			{ "Beam", Vector3.new(reach, 1.5, 2.2), (L.MachineOffset - L.BeltWidth / 2) / 2, L.BeltY + 4.6, false },
			{ "Scanner", Vector3.new(L.BeltWidth, 3.6, 1), 0, L.BeltY + 1.8, false },
		}
	end,
}

--- Builds a machine's masses into `parent` and returns them keyed by name.
function Tycoon:buildMasses(def, parent: Instance, color: Color3, material: Enum.Material)
	local shape = MACHINE_MASSES[def.kind]
	if not shape then
		return {}
	end
	local legIndex, distance = self:legOf(def)
	local parts = {}
	for _, mass in ipairs(shape()) do
		local name, size, offset, y, collide = mass[1], mass[2], mass[3], mass[4], mass[5]
		parts[name] = newPart(parent, name, size,
			self:segmentCF(legIndex, distance, offset, y), color, material, collide)
	end
	return parts, legIndex, distance
end

-- ─────────────────────────────────────────────────────────────────────────────

function Tycoon.new(index: number, parent: Instance)
	local self = setmetatable({}, Tycoon)

	self.index = index
	self.owner = nil :: Player?
	self.owned = {}
	self.objects = {}
	self.generation = 0
	self.beltSpeed = L.BeltSpeed
	self.dropCount = 0

	local model, cf = MapBuilder.buildPlotPad(parent, index)
	self.model = model
	self.cf = cf
	self.padPart = model:FindFirstChild("Pad")

	self.machines = Instance.new("Folder")
	self.machines.Name = "Machines"
	self.machines.Parent = model

	self.buttonsFolder = Instance.new("Folder")
	self.buttonsFolder.Name = "Buttons"
	self.buttonsFolder.Parent = model

	self.drops = Instance.new("Folder")
	self.drops.Name = "Drops"
	self.drops.Parent = model

	self:buildBelt()
	self:buildCollector()
	self:buildRebirthPad()
	self:buildClaimPad()

	-- An unclaimed plot shows a bare pad and a claim marker, nothing else.
	-- Leaving the vault and belt standing on an empty plot is what makes it
	-- look like there's a big block parked in front of the thing you're
	-- meant to walk onto.
	self:setFactoryVisible(false)
	self:updateSign()

	return self
end

--- Buy buttons are built on first claim, not at server start: every plot x 21
--- buttons is a lot of instances to create just to immediately hide them.
function Tycoon:ensureButtons()
	if self.buttonsBuilt then
		return
	end
	self.buttonsBuilt = true
	self:buildButtons()
end

--- Shows/hides the whole factory. Machinery lives in folders so this is a
--- reparent rather than a rebuild.
function Tycoon:setFactoryVisible(visible: boolean)
	local target = visible and self.model or nil
	local folders = { self.beltFolder, self.collectorFolder, self.rebirthFolder, self.machines }
	for i = 1, 4 do
		local folder = folders[i]
		if folder then
			folder.Parent = target
		end
	end
end

function Tycoon:at(x: number, y: number, z: number): CFrame
	return self.cf * CFrame.new(x, y, z)
end

--- Where the owner is placed on claim and on every respawn: just inside the
--- gateway, on the open aisle, looking down plot-local -Z. A CFrame looks
--- along its own -Z by default, so with no rotation you land facing the length
--- of the factory with the belt on your left and the buy buttons ahead of you.
function Tycoon:ownerSpawnCFrame(): CFrame
	local spot = L.OwnerSpawnAt
	return self:at(spot.X, spot.Y, spot.Z)
end

-- ── belt ─────────────────────────────────────────────────────────────────────

function Tycoon:buildBelt()
	local folder = Instance.new("Folder")
	folder.Name = "Belt"
	folder.Parent = self.model
	self.beltFolder = folder

	local width = L.BeltWidth
	local half = width / 2
	local surfaceY = L.BeltY

	local _, _, _, leg1Len = self:leg(1)
	local _, _, _, leg2Len = self:leg(2)

	--[[
		SEAMLESS CORNER, AND NOTHING SOLID NEAR THE BELT.

		The drops are driven by a LinearVelocity in Plane mode, which pins
		their lateral velocity to exactly zero — they physically cannot drift
		sideways off the belt. Side rails were therefore never load-bearing,
		and because each leg's rails ran its FULL length, leg 2's inboard rail
		crossed leg 1's path and vice versa: two solid walls straight across
		the conveyor, plus an 11x11 corner block sitting on the bend. That is
		what the drops were piling up against.

		So: the running surface is the only collidable thing here. The edge
		trim is decoration with CanCollide off, and leg 1's surface runs
		THROUGH the corner square so there is no separate plate to seam
		against — leg 2 simply starts a little way inside it.
	]]
	local function buildRun(index, fromDist, toDist)
		local length = toDist - fromDist
		local mid = (fromDist + toDist) / 2

		newPart(folder, "BeltBase" .. index, Vector3.new(width + 1.2, surfaceY - 0.2, length),
			self:segmentCF(index, mid, 0, (surfaceY - 0.2) / 2), COLORS.frame, Enum.Material.DiamondPlate)

		local surface = newPart(folder, "BeltSurface" .. index, Vector3.new(width, 0.4, length),
			self:segmentCF(index, mid, 0, surfaceY - 0.2), COLORS.belt, Enum.Material.SmoothPlastic)
		surface.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.02, 0.05, 1, 1)

		local texture = Instance.new("Texture")
		texture.Face = Enum.NormalId.Top
		texture.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		texture.Transparency = 0.75
		texture.StudsPerTileU = 5
		texture.StudsPerTileV = 5
		texture.Color3 = COLORS.beltLine
		texture.Parent = surface

		-- Decorative edge trim ONLY on the outer side of the L, and never
		-- collidable. The inner side is left completely open so the two legs
		-- flow into each other.
		local trim = newPart(folder, "Trim" .. index, Vector3.new(0.5, 0.5, length),
			self:segmentCF(index, mid, half + 0.25, surfaceY + 0.15),
			COLORS.beltLine, Enum.Material.Neon, false)
		trim.CanQuery = false

		return surface
	end

	-- leg 1 owns the corner square: it runs half a belt-width past the bend
	local surface1 = buildRun(1, -1, leg1Len + half)
	-- leg 2 starts just inside that square, overlapping slightly so the two
	-- surfaces share a face rather than meeting at a hairline seam
	local surface2 = buildRun(2, half - 0.6, leg2Len)
	self.beltSurfaces = { surface1, surface2 }
	self.beltSurface = surface1

	-- Visual end cap behind the first dropper. Non-collidable: nothing should
	-- ever reach it, and if something does we want it to slide off, not wedge.
	local cap = newPart(folder, "BeltCap", Vector3.new(width + 1.2, 1.6, 0.6),
		self:segmentCF(1, -1.2, 0, surfaceY + 0.8), COLORS.metal, Enum.Material.Metal, false)
	cap.CanQuery = false

	-- The bend: a trigger spanning the belt at the corner that hands a drop
	-- from leg 1's direction to leg 2's. No geometry, just a retarget.
	local turn = newPart(folder, "TurnSensor", Vector3.new(width + 1, 6, 2.5),
		self:segmentCF(1, leg1Len, 0, surfaceY + 3),
		Color3.new(1, 1, 1), Enum.Material.Neon, false)
	turn.Transparency = 1
	turn.CanQuery = false
	turn.CanTouch = true
	turn.Touched:Connect(function(hit)
		self:onTurn(hit)
	end)

	self:buildFlowMarkers(folder)
end

--- Chevrons painted on the floor beside the belt, pointing downstream.
---
--- An L-shaped conveyor with machinery on both sides does not tell you which
--- end is the start. Following the arrows takes you from the first dropper to
--- the vault, which is also the order the buy buttons come in — so "walk the
--- arrows" is the whole tutorial for reading a plot.
function Tycoon:buildFlowMarkers(parent: Instance)
	local SPACING = 18
	local INBOARD = -(L.BeltWidth / 2 + 2.5)   -- clear of the belt, clear of the buttons

	for legIndex = 1, 2 do
		local _, _, _, length = self:leg(legIndex)
		local at = SPACING * 0.5
		while at < length do
			-- two bars meeting at a point: a wedge read from above is just a
			-- rectangle, so the arrowhead has to be drawn rather than modelled
			for _, side in ipairs({ 1, -1 }) do
				local bar = newPart(parent, "Flow", Vector3.new(0.7, 0.25, 4),
					self:segmentCF(legIndex, at, INBOARD, 0.12)
						* CFrame.new(side * 1.1, 0, -1.1)
						* CFrame.Angles(0, math.rad(side * 32), 0),
					COLORS.beltLine, Enum.Material.Neon, false)
				bar.Transparency = 0.25
				bar.CanQuery = false
				bar.CanTouch = false
			end
			at += SPACING
		end
	end
end

--- Hands a drop from leg 1 onto leg 2 at the corner.
function Tycoon:onTurn(hit: BasePart)
	local drop = hit.Parent
	if not drop or not drop:IsA("Model") then
		return
	end
	if drop:GetAttribute("PlotIndex") ~= self.index or drop:GetAttribute("Leg") ~= 1 then
		return
	end
	drop:SetAttribute("Leg", 2)

	local body = drop.PrimaryPart
	if not body then
		return
	end
	local mover = body:FindFirstChild("BeltMover")
	local upkeep = body:FindFirstChild("StayUpright")
	local direction = self:legDirectionWorld(2)

	if mover and mover:IsA("LinearVelocity") then
		mover.PrimaryTangentAxis = direction
		mover.SecondaryTangentAxis = self:legNormalWorld(2)
		mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
	end
	if upkeep and upkeep:IsA("AlignOrientation") then
		upkeep.CFrame = TungModels.dropOrientation(direction)
	end
end

-- ── belt geometry ────────────────────────────────────────────────────────────
-- The run is an L: leg 1 along the back edge, leg 2 along the left edge.
-- Everything (machines, buttons, rails, the corner) is derived from these two
-- segments, so moving the belt is a Config edit.

--- start, finish, unit direction, length and the outboard normal of a leg,
--- all in PLOT-LOCAL space.
function Tycoon:leg(index: number)
	local a = (index == 1) and L.BeltStart or L.BeltCorner
	local b = (index == 1) and L.BeltCorner or L.BeltEnd
	local delta = b - a
	local length = delta.Magnitude
	local dir = delta.Unit

	-- horizontal perpendicular, flipped to point AWAY from the plot centre
	local normal = Vector3.new(-dir.Z, 0, dir.X)
	local midpoint = (a + b) * 0.5
	if normal:Dot(midpoint) < 0 then
		normal = -normal
	end

	return a, b, dir, length, normal
end

--- A point `distance` along a leg, offset sideways. Positive offset is
--- outboard (toward the plot edge), negative is inboard (toward the floor).
function Tycoon:pointOnLeg(index: number, distance: number, offset: number): Vector3
	local a, _, dir, _, normal = self:leg(index)
	return a + dir * distance + normal * (offset or 0)
end

function Tycoon:legDirectionWorld(index: number): Vector3
	local _, _, dir = self:leg(index)
	return self.cf:VectorToWorldSpace(dir).Unit
end

function Tycoon:legNormalWorld(index: number): Vector3
	local _, _, _, _, normal = self:leg(index)
	return self.cf:VectorToWorldSpace(normal).Unit
end

--- Which leg a machine slot lives on: droppers on the back edge, upgraders
--- on the left edge.
function Tycoon:legOf(def): (number, number)
	if def.kind == "Dropper" then
		return 1, L.DropperDist[def.slot]
	end
	return 2, L.UpgraderDist[def.slot]
end

--- World CFrame of a box lying along a leg.
function Tycoon:segmentCF(index: number, distance: number, offset: number, y: number): CFrame
	local _, _, dir = self:leg(index)
	local point = self:pointOnLeg(index, distance, offset) + Vector3.new(0, y, 0)
	return self.cf * CFrame.lookAt(point, point + dir)
end

-- ── collector ────────────────────────────────────────────────────────────────

function Tycoon:buildCollector()
	local folder = Instance.new("Folder")
	folder.Name = "Collector"
	folder.Parent = self.model
	self.collectorFolder = folder

	-- The vault sits past the end of leg 2. Its shell must stay entirely
	-- DOWNSTREAM of the sensor: a solid body overlapping the run-off walls
	-- the belt off and nothing can ever be collected.
	local _, beltEnd, dir2 = self:leg(2)
	local vaultDepth = 10
	local vaultCentre = L.CollectorAt
	local runOff = (vaultCentre - beltEnd).Magnitude
	assert(runOff > vaultDepth / 2 + 3,
		"Collector vault overlaps the belt run-off; move Layout.CollectorAt further out")

	local function alongExit(distance, y, lateral)
		local point = beltEnd + dir2 * distance + Vector3.new(0, y, 0)
			+ Vector3.new(-dir2.Z, 0, dir2.X) * (lateral or 0)
		return self.cf * CFrame.lookAt(point, point + dir2)
	end

	newPart(folder, "VaultBase", Vector3.new(18, 9, vaultDepth), alongExit(runOff, 4.5, 0),
		COLORS.vault, Enum.Material.WoodPlanks)
	newPart(folder, "VaultTrim", Vector3.new(19, 1.2, vaultDepth + 1), alongExit(runOff, 9.4, 0),
		COLORS.gold, Enum.Material.Metal)

	-- funnel mouth facing back down the belt
	local mouth = newPart(folder, "Mouth", Vector3.new(12, 6, 1.5),
		alongExit(runOff - vaultDepth / 2 - 0.5, L.BeltY + 3, 0),
		Color3.fromRGB(30, 24, 40), Enum.Material.Neon, false)
	mouth.Transparency = 0.5

	-- run-off ramp carrying drops off the end of the belt into the sensor
	local ramp = newPart(folder, "Ramp", Vector3.new(L.BeltWidth, 0.6, 5), alongExit(2.4, L.BeltY - 0.2, 0),
		COLORS.belt, Enum.Material.SmoothPlastic)
	ramp.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)

	local sensor = newPart(folder, "Sensor", Vector3.new(L.BeltWidth + 3, 7, 2.5), alongExit(2, L.BeltY + 3, 0),
		Color3.fromRGB(255, 255, 255), Enum.Material.Neon, false)
	sensor.Transparency = 1
	sensor.CanTouch = true

	-- sign
	local signAnchor = newPart(folder, "SignAnchor", Vector3.new(1, 1, 1), alongExit(runOff, 12, 0), COLORS.vault, nil, false)
	signAnchor.Transparency = 1

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(20, 6)
	billboard.MaxDistance = 260
	billboard.Parent = signAnchor

	local label = Instance.new("TextLabel")
	label.Name = "Rate"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "SAHUR VAULT"
	label.TextColor3 = COLORS.gold
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard
	self.vaultLabel = label

	local statue = TungModels.buildStatue("classic", 1.6)
	statue:PivotTo(alongExit(runOff, 13.5, 0) * CFrame.Angles(0, math.pi, 0))
	statue.Parent = folder
	self.vaultStatue = statue

	sensor.Touched:Connect(function(hit)
		self:onCollect(hit)
	end)
end

function Tycoon:onCollect(hit: BasePart)
	local model = hit.Parent
	if not model or not model:IsA("Model") then
		return
	end
	local value = model:GetAttribute("Value")
	if not value then
		return
	end
	if model:GetAttribute("PlotIndex") ~= self.index then
		return
	end
	model:SetAttribute("Value", nil)  -- claim it immediately, touch fires twice

	local owner = self.owner
	self.dropCount = math.max(0, self.dropCount - 1)

	if owner and owner.Parent then
		local gained = Economy.add(owner, value, true)
		-- late game the vault eats ~10 drops/sec; throttle the confetti so a
		-- finished factory doesn't spam hundreds of billboards per minute
		local now = os.clock()
		if now - (self.lastPayoutFx or 0) > 0.3 then
			self.lastPayoutFx = now
			Fx.floatingText(hit.Position + Vector3.new(0, 3, 0), "+" .. Util.abbreviate(gained), COLORS.gold, self.model)
			Fx.tung(hit, 0.9 + math.random() * 0.35, 0.18)
		end
	end
	model:Destroy()
end

-- ── claim pad ────────────────────────────────────────────────────────────────

function Tycoon:buildClaimPad()
	local folder = Instance.new("Folder")
	folder.Name = "Claim"
	folder.Parent = self.model
	self.claimFolder = folder

	local frontX, frontZ = L.ClaimPadAt.X, L.ClaimPadAt.Z

	-- The pad itself. Safe to centre now that the factory is hidden while
	-- unclaimed -- there is nothing standing on the frontage to hide behind.
	local pad = newPart(folder, "ClaimPad", Vector3.new(34, 1.2, 20),
		self:at(frontX, 0.6, frontZ), Color3.fromRGB(120, 230, 160), Enum.Material.Neon)
	pad.CanCollide = false
	pad:SetAttribute("PlotIndex", self.index)
	self.claimPad = pad

	-- A beacon, because a flat pad on the floor is invisible from more than a
	-- few studs away or from any angle that isn't directly above it. THIS is
	-- the thing you actually navigate by.
	local beacon = newPart(folder, "ClaimBeacon", Vector3.new(7, 80, 7),
		self:at(frontX, 40, frontZ), Color3.fromRGB(120, 255, 170), Enum.Material.Neon, false)
	beacon.Transparency = 0.55
	beacon.CanQuery = false

	local halo = newPart(folder, "ClaimHalo", Vector3.new(0.6, 44, 44),
		self:at(frontX, 0.35, frontZ) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(80, 220, 130), Enum.Material.Neon, false)
	halo.Shape = Enum.PartType.Cylinder
	halo.Transparency = 0.4
	halo.CanQuery = false

	-- Sign high up the beacon so it clears the walls of neighbouring plots and
	-- is readable from the arena.
	local signAnchor = newPart(folder, "ClaimSign", Vector3.new(1, 1, 1),
		self:at(frontX, 62, frontZ), Color3.new(1, 1, 1), nil, false)
	signAnchor.Transparency = 1
	signAnchor.CanQuery = false

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(34, 12)
	billboard.MaxDistance = 1200
	billboard.AlwaysOnTop = false
	billboard.Parent = signAnchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "PLOT " .. self.index .. "\nFREE — WALK ON IT"
	label.TextColor3 = Color3.fromRGB(190, 255, 215)
	label.TextStrokeTransparency = 0.15
	label.TextStrokeColor3 = Color3.fromRGB(12, 46, 26)
	label.TextScaled = true
	label.Parent = billboard
	self.claimLabel = label
end

-- ── rebirth pad ──────────────────────────────────────────────────────────────

function Tycoon:buildRebirthPad()
	local folder = Instance.new("Folder")
	folder.Name = "Rebirth"
	folder.Parent = self.model
	self.rebirthFolder = folder

	local spot = L.RebirthPadAt
	local pad = newPart(folder, "RebirthPad", Vector3.new(12, 1.2, 12),
		self:at(spot.X, 0.9, spot.Z), Color3.fromRGB(200, 120, 255), Enum.Material.Neon)
	pad.CanCollide = false
	self.rebirthPad = pad

	local ring = newPart(folder, "RebirthRing", Vector3.new(0.4, 16, 16),
		self:at(spot.X, 0.3, spot.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(120, 60, 200), Enum.Material.Neon, false)
	ring.Shape = Enum.PartType.Cylinder

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(16, 6)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	billboard.MaxDistance = 200
	billboard.Parent = pad

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "SAHUR REBIRTH"
	label.TextColor3 = Color3.fromRGB(235, 200, 255)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard
	self.rebirthLabel = label

	-- keyed by UserId, not by Player, so leaving players aren't kept alive
	local debounce: { [number]: number } = {}
	pad.Touched:Connect(function(hit)
		local player = self:playerFromHit(hit)
		if not player or player ~= self.owner then
			return
		end
		local last = debounce[player.UserId]
		if last and os.clock() - last < 3 then
			return
		end
		debounce[player.UserId] = os.clock()
		Economy.notify(player, {
			kind = "rebirthPrompt",
			title = "SAHUR REBIRTH",
			body = ("Wipe your factory for a permanent x%.2f payout boost?"):format(Config.Rebirth.MultiplierPerRebirth),
			cost = Economy.rebirthCost(player),
		})
	end)
end

-- ── buttons ──────────────────────────────────────────────────────────────────

--- Buy buttons line the INBOARD side of the belt, next to the machine they
--- build, so the row you walk along is the row you buy from.
function Tycoon:buttonPosition(def): Vector3
	if def.kind == "Dropper" or def.kind == "Upgrader" then
		local legIndex, distance = self:legOf(def)
		return self:pointOnLeg(legIndex, distance, -L.ButtonOffset)
	end
	return MISC_SPOTS[def.id] or Vector3.new(0, 0, 0)
end

function Tycoon:buildButtons()
	for _, def in ipairs(Config.Buttons) do
		local pos = self:buttonPosition(def)
		local base = self:at(pos.X, 0, pos.Z)

		local holder = Instance.new("Model")
		holder.Name = "Btn_" .. def.id
		holder.Parent = self.buttonsFolder

		-- Total height is Layout.ButtonHeight (1.4 studs). A Roblox humanoid
		-- steps over ~2 studs without jumping, so you can run straight across
		-- these instead of having to hop onto each one.
		local plinth = L.ButtonHeight * 0.55
		newPart(holder, "Pedestal", Vector3.new(5, plinth, 5), base * CFrame.new(0, plinth / 2, 0),
			COLORS.frame, Enum.Material.DiamondPlate)

		local pad = newPart(holder, "Pad", Vector3.new(4.6, L.ButtonHeight - plinth, 4.6),
			base * CFrame.new(0, (L.ButtonHeight + plinth) / 2, 0), COLORS.buttonOn, Enum.Material.Neon)
		pad.CanCollide = false
		pad:SetAttribute("ButtonId", def.id)

		local light = Instance.new("PointLight")
		light.Color = COLORS.buttonOn
		light.Range = 11
		light.Brightness = 1.4
		light.Shadows = false
		light.Parent = pad

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Info"
		billboard.Size = UDim2.fromScale(16, 9)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
		billboard.MaxDistance = 220
		-- Readable through your own machinery. Without this the label for the
		-- button you are walking towards disappears behind the dropper next to
		-- it exactly when you need it.
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.Parent = pad

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromRGB(20, 16, 30)
		frame.BackgroundTransparency = 0.2
		frame.BorderSizePixel = 0
		frame.Parent = billboard
		Util.roundedFrame(frame, 10)

		local stroke = Instance.new("UIStroke")
		stroke.Color = COLORS.buttonOn
		stroke.Thickness = 2.5
		stroke.Parent = frame

		-- Four lines, in the order you ask the questions: where am I in the
		-- build, what is this, what does it do for me, what does it cost.
		local step = Instance.new("TextLabel")
		step.Name = "Step"
		step.BackgroundTransparency = 1
		step.Size = UDim2.fromScale(0.94, 0.18)
		step.Position = UDim2.fromScale(0.03, 0.02)
		step.Font = Enum.Font.GothamBold
		step.Text = ("STEP %d OF %d"):format(def.order, #Config.Buttons)
		step.TextColor3 = Color3.fromRGB(150, 142, 172)
		step.TextScaled = true
		step.Parent = frame

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(0.94, 0.32)
		title.Position = UDim2.fromScale(0.03, 0.2)
		title.Font = Enum.Font.FredokaOne
		title.Text = def.name
		title.TextColor3 = Color3.fromRGB(255, 240, 210)
		title.TextScaled = true
		title.Parent = frame

		local effect = Instance.new("TextLabel")
		effect.Name = "Effect"
		effect.BackgroundTransparency = 1
		effect.Size = UDim2.fromScale(0.94, 0.22)
		effect.Position = UDim2.fromScale(0.03, 0.52)
		effect.Font = Enum.Font.GothamBold
		effect.Text = def.blurb or ""
		effect.TextColor3 = Color3.fromRGB(150, 235, 190)
		effect.TextScaled = true
		effect.Parent = frame

		local price = Instance.new("TextLabel")
		price.Name = "Price"
		price.BackgroundTransparency = 1
		price.Size = UDim2.fromScale(0.94, 0.24)
		price.Position = UDim2.fromScale(0.03, 0.74)
		price.Font = Enum.Font.GothamBold
		price.Text = "$" .. Util.abbreviate(def.price)
		price.TextColor3 = COLORS.buttonOn
		price.TextScaled = true
		price.Parent = frame

		local lastTouch = 0
		pad.Touched:Connect(function(hit)
			if os.clock() - lastTouch < 0.35 then
				return
			end
			lastTouch = os.clock()
			local player = self:playerFromHit(hit)
			if player then
				self:tryPurchase(player, def.id)
			end
		end)

		self.objects[def.id] = {
			def = def,
			holder = holder,
			pad = pad,
			pedestal = holder:FindFirstChild("Pedestal"),
			stroke = stroke,
			priceLabel = price,
			effectLabel = effect,
			stepLabel = step,
			titleLabel = title,
			light = light,
			machine = nil,
			ghost = nil,
		}
	end
end

function Tycoon:requirementsMet(id: string): boolean
	local def = Config.ButtonById[id]
	if not def then
		return false
	end
	for _, req in ipairs(Config.requirementsOf(def)) do
		if not self.owned[req] then
			return false
		end
	end
	return true
end

--- A translucent stand-in for a machine you haven't bought yet, built from the
--- same MACHINE_MASSES description as the real thing.
---
--- Showing the next few purchases as ghosts turns the plot into a plan you are
--- filling in, rather than a row of anonymous pads with prices on them. It also
--- answers the standing complaint about tycoon infrastructure — "why am I
--- buying walls before I can buy upgraders" stops being a fair question once
--- you can see the upgraders standing there waiting.
function Tycoon:buildGhost(def)
	if not MACHINE_MASSES[def.kind] then
		return nil
	end
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Ghost_" .. def.id

	local parts = self:buildMasses(def, model, variant.wood, Enum.Material.ForceField)
	for _, part in pairs(parts) do
		part.Transparency = 0.72
		-- A ghost must never be walked into, stood on, or hit by a drop: it is
		-- a drawing, and the belt has to run through where it will stand.
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
	end
	return model
end

--- Buy buttons have three states, because the two obvious designs both fail:
--- showing every button at once gives the plot no focal point, and showing
--- only the next one hides the shape of the build from you.
---
---   available   full colour, lit, touchable, and the cheapest one wears a
---               Highlight and a beacon so it is findable from anywhere
---   preview     the next few steps: dimmed, inert, with a ghost of the
---               machine standing where it will go
---   hidden      everything further out, and everything already owned
local PREVIEW_AHEAD = 3

function Tycoon:refreshButtons()
	if not self.owner then
		for _, entry in pairs(self.objects) do
			entry.holder.Parent = nil
			if entry.ghost then
				entry.ghost:Destroy()
				entry.ghost = nil
			end
		end
		if self.marker then
			self:pointAt(nil)
		end
		return
	end

	local cash = Economy.get(self.owner)

	-- how far along the linear chain the player has got
	local nextOrder = #Config.Buttons + 1
	for _, def in ipairs(Config.Buttons) do
		if not self.owned[def.id] then
			nextOrder = def.order
			break
		end
	end

	local target, targetPrice = nil, math.huge

	for id, entry in pairs(self.objects) do
		local def = entry.def
		local owned = self.owned[id] == true
		local available = (not owned) and self:requirementsMet(id)
		local preview = (not owned) and (not available) and (def.order <= nextOrder + PREVIEW_AHEAD)

		entry.holder.Parent = (available or preview) and self.buttonsFolder or nil

		if preview then
			-- inert: a preview pad you can buy from would just spam "you can't
			-- afford that yet" every time you crossed it
			entry.pad.CanTouch = false
			entry.pad.Color = COLORS.preview
			entry.pad.Transparency = 0.45
			if entry.pedestal then
				entry.pedestal.Transparency = 0.55
				entry.pedestal.CanCollide = false
			end
			entry.light.Enabled = false
			entry.stroke.Color = COLORS.preview
			entry.stepLabel.TextColor3 = COLORS.preview
			entry.titleLabel.TextColor3 = COLORS.preview
			entry.effectLabel.Text = "locked — finish step " .. (def.order - 1)
			entry.effectLabel.TextColor3 = COLORS.preview
			entry.priceLabel.Text = "$" .. Util.abbreviate(def.price)
			entry.priceLabel.TextColor3 = COLORS.preview
		elseif available then
			local affordable = cash >= def.price
			local color = affordable and COLORS.buttonOn or COLORS.buttonOff
			entry.pad.CanTouch = true
			entry.pad.Transparency = 0
			entry.pad.Color = color
			if entry.pedestal then
				entry.pedestal.Transparency = 0
				entry.pedestal.CanCollide = true
			end
			entry.light.Enabled = true
			entry.light.Color = color
			entry.stroke.Color = color
			entry.stepLabel.TextColor3 = Color3.fromRGB(150, 142, 172)
			entry.titleLabel.TextColor3 = Color3.fromRGB(255, 240, 210)
			entry.effectLabel.Text = self:effectLine(def)
			entry.effectLabel.TextColor3 = Color3.fromRGB(150, 235, 190)
			entry.priceLabel.TextColor3 = color
			entry.priceLabel.Text = affordable
				and ("$" .. Util.abbreviate(def.price))
				or ("NEED " .. Util.abbreviate(def.price - cash) .. " MORE")

			if def.price < targetPrice then
				target, targetPrice = entry, def.price
			end
		end

		-- ghosts stand for anything not yet built, available or previewed
		local wantsGhost = (available or preview) and MACHINE_MASSES[def.kind] ~= nil
		if wantsGhost and not entry.ghost then
			entry.ghost = self:buildGhost(def)
			if entry.ghost then
				entry.ghost.Parent = self.machines
			end
		elseif not wantsGhost and entry.ghost then
			entry.ghost:Destroy()
			entry.ghost = nil
		end
	end

	self:pointAt(target)
end

--- Moves the "buy this next" marker onto `entry`. One Highlight and one light
--- column per plot, reparented, rather than one of each per button: Highlight
--- is capped at 255 per client and disabled ones still occupy a slot.
function Tycoon:pointAt(entry)
	if not self.marker then
		local marker = Instance.new("Model")
		marker.Name = "NextMarker"

		local beam = newPart(marker, "Beam", Vector3.new(4, 26, 4), CFrame.new(),
			COLORS.gold, Enum.Material.Neon, false)
		beam.Transparency = 0.75
		beam.CanQuery = false

		local highlight = Instance.new("Highlight")
		highlight.FillColor = COLORS.gold
		highlight.FillTransparency = 0.65
		highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
		-- through your own machinery: the point of the marker is that you can
		-- find it from the far end of a plot you have already half filled
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = marker

		self.marker = marker
		self.markerBeam = beam
		self.markerHighlight = highlight
	end

	if not entry then
		self.marker.Parent = nil
		self.markerHighlight.Adornee = nil
		return
	end

	self.markerHighlight.Adornee = entry.holder
	self.markerBeam.CFrame = entry.pad.CFrame * CFrame.new(0, 13, 0)
	self.marker.Parent = self.buttonsFolder
end

-- ── purchasing ───────────────────────────────────────────────────────────────

function Tycoon:playerFromHit(hit: BasePart): Player?
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return game:GetService("Players"):GetPlayerFromCharacter(character)
end

function Tycoon:tryPurchase(player: Player, id: string)
	if player ~= self.owner then
		return
	end
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	if not self:requirementsMet(id) then
		return
	end
	if not Economy.spend(player, def.price) then
		local short = def.price - Economy.get(player)
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("You need %s more for %s."):format(Util.abbreviate(short), def.name),
		})
		return
	end

	local profile = DataService.get(player)
	if profile then
		profile.owned[id] = true
	end

	self:install(id, false)

	Economy.notify(player, {
		kind = "buy",
		title = def.name,
		body = def.blurb or "",
		price = def.price,
	})
	Economy.push(player)
end

--- Applies a purchase. `silent` skips effects (used when loading a save).
function Tycoon:install(id: string, silent: boolean?)
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	self.owned[id] = true

	local entry = self.objects[id]
	if entry then
		entry.holder.Parent = nil
	end

	local installer = Tycoon.INSTALLERS[def.kind]
	if installer then
		installer(self, def, silent)
	else
		warn("[Tung] no installer for kind " .. tostring(def.kind))
	end

	if not silent then
		local pos = self:buttonPosition(def)
		local variant = Config.Variants[def.variant or "classic"]
		Fx.burst((self:at(pos.X, 5, pos.Z)).Position, variant.wood, 18, self.model)
	end

	self:refreshButtons()
end

-- ── installers ───────────────────────────────────────────────────────────────

Tycoon.INSTALLERS = {}

Tycoon.INSTALLERS.Dropper = function(self, def, silent)
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Dropper_" .. def.id
	model.Parent = self.machines

	local parts, legIndex = self:buildMasses(def, model, COLORS.frame, Enum.Material.DiamondPlate)

	local core = parts.Core
	core.Color = variant.wood
	core.Material = variant.material
	Fx.applyVariant(core, variant)

	parts.Arm.Color = COLORS.metal
	parts.Arm.Material = Enum.Material.Metal
	parts.Spout.Color = COLORS.metal
	parts.Spout.Material = Enum.Material.Metal

	local nozzle = parts.Nozzle
	nozzle.Color = variant.light and variant.light.color or variant.wood
	nozzle.Material = Enum.Material.Neon

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(9, 2.6)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	billboard.MaxDistance = 130
	billboard.Parent = core

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = def.name .. "  •  $" .. Util.abbreviate(def.dropValue)
	label.TextColor3 = Color3.fromRGB(255, 250, 235)
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Parent = billboard

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end

	local generation = self.generation
	task.spawn(function()
		-- stagger so ten droppers don't fire on the same frame
		task.wait(math.random() * def.dropRate)
		while self.generation == generation and self.owned[def.id] and model.Parent do
			self:spawnDrop(def, nozzle, legIndex)
			task.wait(def.dropRate)
		end
	end)
end

Tycoon.INSTALLERS.Upgrader = function(self, def, silent)
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Upgrader_" .. def.id
	model.Parent = self.machines

	local parts = self:buildMasses(def, model, COLORS.metal, Enum.Material.Metal)

	local beam = parts.Beam
	beam.Color = variant.wood
	beam.Material = variant.material
	Fx.applyVariant(beam, variant)

	local scanner = parts.Scanner
	scanner.Color = variant.light and variant.light.color or variant.wood
	scanner.Material = Enum.Material.Neon
	scanner.Transparency = 0.55
	scanner.CanTouch = true

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(11, 3)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.MaxDistance = 140
	billboard.Parent = beam

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = ("%s  x%.2g"):format(def.name, def.multiplier)
	label.TextColor3 = Color3.fromRGB(255, 240, 210)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Parent = billboard

	local flagName = "up_" .. def.id
	scanner.Touched:Connect(function(hit)
		local drop = hit.Parent
		if not drop or not drop:IsA("Model") then
			return
		end
		if drop:GetAttribute("PlotIndex") ~= self.index then
			return
		end
		local value = drop:GetAttribute("Value")
		if not value or drop:GetAttribute(flagName) then
			return
		end
		drop:SetAttribute(flagName, true)
		drop:SetAttribute("Value", value * def.multiplier)

		local body = drop.PrimaryPart or drop:FindFirstChild("Body")
		if body and body:IsA("BasePart") then
			body.Color = Util.lerpColor(body.Color, variant.wood, 0.55)
			body.Material = variant.material
			Fx.burst(body.Position, variant.wood, 4, self.model)
			Fx.tung(body, 1.15 + math.random() * 0.2, 0.12)
		end
	end)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Belt = function(self, def, silent)
	self.beltSpeed += def.speedBonus
	for _, surface in ipairs(self.beltSurfaces or {}) do
		surface.Color = Color3.fromRGB(92, 70, 40)
	end
	-- retro-apply to drops already rolling
	for _, drop in ipairs(self.drops:GetChildren()) do
		local mover = drop:FindFirstChildWhichIsA("LinearVelocity", true)
		if mover then
			mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
		end
	end
end

Tycoon.INSTALLERS.Gear = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantBat(owner, def.grants)
	end

	local model = Instance.new("Model")
	model.Name = "Gear_" .. def.id
	model.Parent = self.machines

	local spot = MISC_SPOTS[def.id] or Vector3.new(0, 0, 0)
	local anvilCF = self:at(spot.X + (spot.X < 0 and 10 or -10), 0, spot.Z)
	newPart(model, "Anvil", Vector3.new(8, 4, 6), anvilCF * CFrame.new(0, 2, 0), COLORS.metal, Enum.Material.Metal)

	local batDef = Config.BatById[def.grants]
	if batDef then
		local display = TungModels.buildStatue(batDef.variant, 1.1)
		display:PivotTo(anvilCF * CFrame.new(0, 8, 0))
		display.Parent = model
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Structure = function(self, def, silent)
	local model = Instance.new("Model")
	model.Name = "Structure_" .. def.id
	model.Parent = self.machines

	local halfX = W.PlotSize.X / 2 - 1
	local halfZ = W.PlotSize.Z / 2 - 1

	if def.structure == "walls" then
		local h = 13
		-- The gateway sits over the open floor on the right, NOT at x = 0:
		-- the belt and vault occupy the left half, so a centred gate would
		-- open onto machinery. Config owns the numbers so they scale with
		-- the plot and can be checked against the aisle by the verifier.
		local gateCentre, gateWidth = L.GateCentre, L.GateWidth
		local gateLeft = gateCentre - gateWidth / 2
		local gateRight = gateCentre + gateWidth / 2
		local leftSpan = gateLeft + halfX
		local rightSpan = halfX - gateRight
		local specs = {
			{ Vector3.new(W.PlotSize.X, h, 2), CFrame.new(0, h / 2, -halfZ) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(halfX, h / 2, 0) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(-halfX, h / 2, 0) },
			-- front wall in two pieces, leaving the gateway over the aisle
			{ Vector3.new(leftSpan, h, 2), CFrame.new(gateLeft - leftSpan / 2, h / 2, halfZ) },
			{ Vector3.new(rightSpan, h, 2), CFrame.new(gateRight + rightSpan / 2, h / 2, halfZ) },
		}
		for i, spec in ipairs(specs) do
			newPart(model, "Wall" .. i, spec[1], self.cf * spec[2], Color3.fromRGB(150, 111, 74), Enum.Material.WoodPlanks)
			newPart(model, "Trim" .. i, spec[1] + Vector3.new(0.4, -h + 1, 0.4),
				self.cf * spec[2] * CFrame.new(0, h / 2, 0), COLORS.beltLine, Enum.Material.Neon, false)
		end
	elseif def.structure == "roof" then
		local roof = newPart(model, "Roof", Vector3.new(W.PlotSize.X, 1.4, W.PlotSize.Z),
			self:at(0, 20, 0), Color3.fromRGB(138, 88, 58), Enum.Material.WoodPlanks)
		roof.CanCollide = true
		for _, sign in ipairs({ -1, 1 }) do
			for _, signZ in ipairs({ -1, 1 }) do
				newPart(model, "Column", Vector3.new(2.4, 20, 2.4),
					self:at(sign * (halfX - 3), 10, signZ * (halfZ - 3)), Color3.fromRGB(150, 111, 74), Enum.Material.Wood)
			end
		end

		local signAnchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1), self:at(0, 27, 0), COLORS.frame, nil, false)
		signAnchor.Transparency = 1
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromScale(46, 12)
		billboard.MaxDistance = 700
		billboard.Parent = signAnchor
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = "TUNG TUNG TUNG SAHUR CO."
		label.TextColor3 = COLORS.gold
		label.TextStrokeTransparency = 0.15
		label.TextScaled = true
		label.Parent = billboard
		self.roofSign = label
		self:updateSign()
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

-- ── drops ────────────────────────────────────────────────────────────────────

function Tycoon:spawnDrop(def, nozzle: BasePart, legIndex: number)
	if not self.owner then
		return
	end
	if self.dropCount >= Config.Economy.MaxDropsPerPlot then
		return
	end
	self.dropCount += 1

	local drop = TungModels.buildDrop(def.variant, 0.62)
	drop:SetAttribute("Value", def.dropValue)
	drop:SetAttribute("PlotIndex", self.index)
	drop:SetAttribute("Variant", def.variant)

	drop:SetAttribute("Leg", legIndex)

	local body = drop.PrimaryPart :: BasePart
	local direction = self:legDirectionWorld(legIndex)
	local across = self:legNormalWorld(legIndex)
	local jitter = (math.random() - 0.5) * (L.BeltWidth * 0.35)

	-- NOTE: the model's pivot is the body, so PivotTo overwrites the body's
	-- rotation outright. The upright orientation has to be baked into the
	-- target CFrame or every drop spawns lying on its side.
	local upright = TungModels.dropOrientation(direction)
	local spawnPosition = nozzle.Position + across * jitter - Vector3.new(0, 1.6, 0)
	drop:PivotTo(CFrame.new(spawnPosition) * upright)

	local attachment = Instance.new("Attachment")
	attachment.Name = "BeltAttach"
	attachment.Parent = body

	-- conveyor motion, done with a constraint so there is no per-frame script
	local mover = Instance.new("LinearVelocity")
	mover.Name = "BeltMover"
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	mover.PrimaryTangentAxis = direction
	mover.SecondaryTangentAxis = across
	mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
	mover.MaxForce = 120000
	mover.Parent = body

	-- keep the little guy standing up and facing back down the belt, so you
	-- see a queue of angry faces instead of a pile of rolling logs
	local upkeep = Instance.new("AlignOrientation")
	upkeep.Name = "StayUpright"
	upkeep.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upkeep.Attachment0 = attachment
	upkeep.RigidityEnabled = true
	upkeep.CFrame = upright
	upkeep.Parent = body

	drop.Parent = self.drops

	Fx.tung(body, 1.6 + math.random() * 0.3, 0.08)

	task.delay(Config.Economy.DropLifetime, function()
		if drop.Parent then
			self.dropCount = math.max(0, self.dropCount - 1)
			drop:Destroy()
		end
	end)
end

function Tycoon:clearDrops()
	for _, drop in ipairs(self.drops:GetChildren()) do
		drop:Destroy()
	end
	self.dropCount = 0
end

-- ── income readout ───────────────────────────────────────────────────────────

--- Estimated Tung/second with everything currently installed.
---
--- `extraId` pretends one more button is owned, which is how a buy button can
--- advertise "+$28/sec" instead of only a price. A price alone is a cost with
--- no stated benefit, and for an Upgrader the benefit is not even guessable —
--- x1.85 of an unknown number is not information.
function Tycoon:incomePerSecond(extraId: string?): number
	local function has(id: string): boolean
		return self.owned[id] == true or id == extraId
	end

	local upgradeMult = 1
	local total = 0
	for id, def in pairs(Config.ButtonById) do
		if has(id) then
			if def.kind == "Upgrader" then
				upgradeMult *= def.multiplier
			elseif def.kind == "Dropper" then
				total += (def.dropValue / def.dropRate)
			end
		end
	end
	local rebirthMult = self.owner and Economy.multiplier(self.owner) or 1
	return total * upgradeMult * rebirthMult
end

--- One line of plain English for what a button actually does for you. Income
--- kinds get the measured delta; the rest get their blurb, because "walls" has
--- no income to quote.
function Tycoon:effectLine(def): string
	if def.kind == "Dropper" or def.kind == "Upgrader" then
		local delta = self:incomePerSecond(def.id) - self:incomePerSecond()
		if delta > 0 then
			return ("+%s/sec"):format(Util.abbreviate(delta))
		end
	elseif def.kind == "Belt" then
		return ("belt +%d studs/sec"):format(def.speedBonus)
	end
	return def.blurb or ""
end

function Tycoon:updateSign()
	local ownerName = self.owner and self.owner.DisplayName or nil
	local sign = self.model:FindFirstChild("Totem")
	local billboard = sign and sign:FindFirstChild("Sign")
	-- the label lives inside a Frame inside the BillboardGui, so this lookup
	-- has to be recursive or it silently returns nil forever
	local label = billboard and billboard:FindFirstChild("Owner", true)
	if label then
		if ownerName then
			label.Text = ("%s's TUNG FACTORY\n%s Tung/sec"):format(ownerName, Util.abbreviate(self:incomePerSecond()))
		else
			label.Text = ("UNCLAIMED PLOT %d\nstep on the pad to claim"):format(self.index)
		end
	end
	if self.vaultLabel then
		self.vaultLabel.Text = ownerName
			and ("SAHUR VAULT  •  %s/sec"):format(Util.abbreviate(self:incomePerSecond()))
			or "SAHUR VAULT"
	end
	-- the whole claim rig (pad, beacon, halo, sign) appears and disappears
	-- together, so an owned plot never shows a stray "free" marker
	if self.claimFolder then
		self.claimFolder.Parent = (ownerName == nil) and self.model or nil
	end
	if self.rebirthLabel and self.owner then
		self.rebirthLabel.Text = ("SAHUR REBIRTH\n%s"):format(Util.abbreviate(Economy.rebirthCost(self.owner)))
	end
end

-- ── ownership ────────────────────────────────────────────────────────────────

function Tycoon:assign(player: Player)
	if self.owner then
		return false
	end
	self.owner = player
	self.generation += 1
	self:ensureButtons()
	self:setFactoryVisible(true)

	local profile = DataService.get(player)
	if profile then
		-- rebuild everything they had, cheapest-first so requirements resolve
		local ids = {}
		for id, owned in pairs(profile.owned) do
			if owned and Config.ButtonById[id] then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return Config.ButtonById[a].order < Config.ButtonById[b].order
		end)
		for _, id in ipairs(ids) do
			self:install(id, true)
		end
	end

	self:refreshButtons()
	self:updateSign()
	return true
end

function Tycoon:release()
	self.owner = nil
	self.generation += 1
	self.owned = {}
	self.beltSpeed = L.BeltSpeed

	for _, entry in pairs(self.objects) do
		if entry.machine then
			entry.machine:Destroy()
			entry.machine = nil
		end
	end
	self.machines:ClearAllChildren()
	self:clearDrops()
	self:setFactoryVisible(false)

	for _, surface in ipairs(self.beltSurfaces or {}) do
		surface.Color = COLORS.belt
	end
	self.roofSign = nil

	self:refreshButtons()
	self:updateSign()
end

--- Wipes the factory but keeps the player, and hands out a rebirth.
function Tycoon:rebirth(player: Player): boolean
	if player ~= self.owner then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	local cost = Economy.rebirthCost(player)
	if profile.rebirths >= Config.Rebirth.MaxRebirths then
		Economy.notify(player, { kind = "warn", title = "Max rebirths", body = "You have ascended as far as sahur allows." })
		return false
	end
	if profile.cash < cost then
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("Rebirth costs %s."):format(Util.abbreviate(cost)),
		})
		return false
	end

	profile.rebirths += 1
	profile.cash = Config.Economy.StartingCash
	profile.owned = {}

	self.generation += 1
	self.owned = {}
	self.beltSpeed = L.BeltSpeed
	for _, entry in pairs(self.objects) do
		entry.machine = nil
	end
	self.machines:ClearAllChildren()
	self:clearDrops()

	self:refreshButtons()
	self:updateSign()
	Economy.push(player)

	Economy.notify(player, {
		kind = "rebirth",
		title = "SAHUR REBIRTH #" .. profile.rebirths,
		body = ("All payouts are now x%.2f."):format(Economy.multiplier(player)),
	})

	local character = player.Character
	if character and character.PrimaryPart then
		Fx.burst(character:GetPivot().Position, Color3.fromRGB(200, 120, 255), 60, workspace)
	end
	return true
end

return Tycoon
