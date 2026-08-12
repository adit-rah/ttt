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
local Style = Req("Style")
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

--- Every plot built this session, in plot order. PlotService owns the plots and
--- hands them out by player; a service that has to walk ALL of them (like
--- FloorService) has nowhere else to get the list.
local INSTANCES: { any } = {}

function Tycoon.all(): { any }
	return INSTANCES
end

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

-- ── belt paths ───────────────────────────────────────────────────────────────

--- Turns a path definition ({ id, y, points, outboard, collectorAt }) into
--- resolved legs.
---
--- `outboard` is the SIDE each leg's machines stand on: its outboard normal is
--- sign * (-dir.Z, 0, dir.X). It used to be inferred with
--- `normal:Dot(midpoint) < 0` — "point away from the plot origin" — which holds
--- only while every leg hugs an outer edge, and silently inverts for any leg
--- whose midpoint doesn't. An upper floor's return leg runs back across the
--- middle of its own deck, where the inferred side flips and puts the machines
--- over the walkway and the buy buttons out in space. So the side is carried,
--- not guessed. Both ground legs are +1, which is exactly what the old
--- heuristic produced.
local function resolvePath(def, outboard: { number }?)
	outboard = outboard or def.outboard
	local points = def.points
	assert(points and #points >= 2, "a belt path needs at least two points")

	local legs = {}
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local delta = b - a
		local dir = delta.Unit
		local sign = (outboard and outboard[index]) or 1
		legs[index] = {
			a = a,
			b = b,
			dir = dir,
			length = delta.Magnitude,
			normal = Vector3.new(-dir.Z, 0, dir.X) * sign,
		}
	end

	return {
		id = def.id,
		y = def.y or 0,
		legs = legs,
		collectorAt = def.collectorAt,
		surfaces = {},
	}
end

--- Builds a machine's masses into `parent` and returns them keyed by name.
function Tycoon:buildMasses(def, parent: Instance, color: Color3, material: Enum.Material)
	local shape = MACHINE_MASSES[def.kind]
	if not shape then
		return {}
	end
	local legIndex, distance, pathIndex = self:legOf(def)
	local parts = {}
	for _, mass in ipairs(shape()) do
		local name, size, offset, y, collide = mass[1], mass[2], mass[3], mass[4], mass[5]
		parts[name] = newPart(parent, name, size,
			self:segmentCF(legIndex, distance, offset, y, pathIndex), color, material, collide)
	end
	return parts, legIndex, distance, pathIndex
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

	-- Folders that come and go with the factory. Registered as they are built
	-- rather than listed in setFactoryVisible; see registerFactoryFolder.
	self.factoryFolders = {}
	self.factoryShown = true

	-- Belt paths. Path 1 is the ground floor and is always present; anything
	-- above it registers its own through addBeltPath.
	self.paths = {}
	self:addBeltPath(Config.BeltPaths[1])

	local model, cf = MapBuilder.buildPlotPad(parent, index)
	self.model = model
	self.cf = cf
	self.padPart = model:FindFirstChild("Pad")

	self.machines = Instance.new("Folder")
	self.machines.Name = "Machines"
	self.machines.Parent = model
	self:registerFactoryFolder(self.machines)

	-- Side-track props: the cabinets and whatever stands on their shelves.
	-- A SEPARATE folder from self.machines specifically because rebirth does
	-- machines:ClearAllChildren() — putting a bat display in there would wipe
	-- the cabinet every prestige while its purchase survived in the profile.
	-- release() still clears this one: new owner, different tiers.
	self.props = Instance.new("Folder")
	self.props.Name = "Props"
	self.props.Parent = model
	self:registerFactoryFolder(self.props)

	self.buttonsFolder = Instance.new("Folder")
	self.buttonsFolder.Name = "Buttons"
	self.buttonsFolder.Parent = model

	self.drops = Instance.new("Folder")
	self.drops.Name = "Drops"
	self.drops.Parent = model

	self:buildBelt(1)
	self:buildCollector(1, nil, true)
	self:buildRebirthPad()
	self:buildClaimPad()
	self:buildCabinets()

	-- An unclaimed plot shows a bare pad and a claim marker, nothing else.
	-- Leaving the vault and belt standing on an empty plot is what makes it
	-- look like there's a big block parked in front of the thing you're
	-- meant to walk onto.
	self:setFactoryVisible(false)
	self:updateSign()

	table.insert(INSTANCES, self)
	return self
end

--- Listener for "what this plot owns has changed" — a purchase, a claim, a
--- release, a rebirth. FloorService hangs the mezzanine off this rather than
--- polling every plot on a timer. One listener, because there is exactly one
--- consumer; make it a list the day there are two.
function Tycoon:onOwnedChanged(fn: ((any) -> ())?)
	self.ownedChanged = fn
end

function Tycoon:fireOwnedChanged()
	local fn = self.ownedChanged
	if not fn then
		return
	end
	-- pcall'd: a listener that throws must not take a purchase down with it
	local ok, err = pcall(fn, self)
	if not ok then
		warn("[Tung] owned-changed listener error on plot " .. self.index .. ": " .. tostring(err))
	end
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

--- Adds a folder to the set that appears and disappears with the factory.
---
--- Registration rather than a literal list, because setFactoryVisible used to
--- walk `for i = 1, 4` over one: the fifth folder anyone added was silently
--- left standing on an unclaimed plot, which is the exact bug the hidden
--- factory exists to prevent. A folder registered while the factory is hidden
--- is hidden immediately, so late arrivals (an upper floor) can't leak either.
function Tycoon:registerFactoryFolder(folder: Instance)
	table.insert(self.factoryFolders, folder)
	if not self.factoryShown then
		folder.Parent = nil
	end
end

--- Shows/hides the whole factory. Machinery lives in folders so this is a
--- reparent rather than a rebuild.
function Tycoon:setFactoryVisible(visible: boolean)
	self.factoryShown = visible
	local target = visible and self.model or nil
	for _, folder in ipairs(self.factoryFolders) do
		folder.Parent = target
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

--- Builds the running surface, the corner sensors and the flow markers for one
--- belt path. Called once for the ground floor at construction, and once more
--- per floor above it — `parent` lets a floor keep its belt in its own folder
--- so tearing the floor down takes the belt with it.
function Tycoon:buildBelt(pathIndex: number?, parent: Instance?)
	pathIndex = pathIndex or 1

	local folder = parent
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Belt"
		folder.Parent = self.model
		self.beltFolder = folder
		self:registerFactoryFolder(folder)
	end

	local width = L.BeltWidth
	local half = width / 2
	local surfaceY = L.BeltY
	local legs = self:legCount(pathIndex)

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
		trim is decoration with CanCollide off, and every leg's surface runs
		THROUGH its corner square so there is no separate plate to seam
		against — the next leg simply starts a little way inside it.
	]]
	local function buildRun(index, fromDist, toDist)
		local length = toDist - fromDist
		local mid = (fromDist + toDist) / 2

		newPart(folder, "BeltBase" .. index, Vector3.new(width + 1.2, surfaceY - 0.2, length),
			self:segmentCF(index, mid, 0, (surfaceY - 0.2) / 2, pathIndex), COLORS.frame, Enum.Material.DiamondPlate)

		local surface = newPart(folder, "BeltSurface" .. index, Vector3.new(width, 0.4, length),
			self:segmentCF(index, mid, 0, surfaceY - 0.2, pathIndex), COLORS.belt, Enum.Material.SmoothPlastic)
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
			self:segmentCF(index, mid, half + 0.25, surfaceY + 0.15, pathIndex),
			COLORS.beltLine, Enum.Material.Neon, false)
		trim.CanQuery = false

		return surface
	end

	local path = self:beltPath(pathIndex)
	local surfaces = {}
	for index = 1, legs do
		local _, _, _, length = self:leg(index, pathIndex)
		-- The first leg starts a stud behind the first dropper; every other one
		-- starts just INSIDE the corner square its predecessor already covers,
		-- overlapping slightly so the two surfaces share a face rather than
		-- meeting at a hairline seam.
		local fromDist = (index == 1) and -1 or (half - 0.6)
		-- Every leg but the last owns the square at its far end: it runs half a
		-- belt-width past the bend so there is no separate corner plate.
		local toDist = (index == legs) and length or (length + half)
		surfaces[index] = buildRun(index, fromDist, toDist)
	end
	path.surfaces = surfaces

	-- Visual end cap behind the first dropper. Non-collidable: nothing should
	-- ever reach it, and if something does we want it to slide off, not wedge.
	local cap = newPart(folder, "BeltCap", Vector3.new(width + 1.2, 1.6, 0.6),
		self:segmentCF(1, -1.2, 0, surfaceY + 0.8, pathIndex), COLORS.metal, Enum.Material.Metal, false)
	cap.CanQuery = false

	-- One trigger per bend, spanning the belt, handing a drop from leg i's
	-- direction to leg i+1's. No geometry, just a retarget — so an N-legged
	-- path costs N-1 triggers and still no per-frame work.
	for index = 1, legs - 1 do
		local _, _, _, length = self:leg(index, pathIndex)
		local turn = newPart(folder, "TurnSensor" .. index, Vector3.new(width + 1, 6, 2.5),
			self:segmentCF(index, length, 0, surfaceY + 3, pathIndex),
			Color3.new(1, 1, 1), Enum.Material.Neon, false)
		turn.Transparency = 1
		turn.CanQuery = false
		turn.CanTouch = true
		turn.Touched:Connect(function(hit)
			self:onTurn(hit, pathIndex, index)
		end)
	end

	self:buildFlowMarkers(folder, pathIndex)
end

--- Chevrons painted on the floor beside the belt, pointing downstream.
---
--- An L-shaped conveyor with machinery on both sides does not tell you which
--- end is the start. Following the arrows takes you from the first dropper to
--- the vault, which is also the order the buy buttons come in — so "walk the
--- arrows" is the whole tutorial for reading a plot.
function Tycoon:buildFlowMarkers(parent: Instance, pathIndex: number?)
	local SPACING = 18
	local INBOARD = -(L.BeltWidth / 2 + 2.5)   -- clear of the belt, clear of the buttons

	for legIndex = 1, self:legCount(pathIndex) do
		local _, _, _, length = self:leg(legIndex, pathIndex)
		local at = SPACING * 0.5
		while at < length do
			-- two bars meeting at a point: a wedge read from above is just a
			-- rectangle, so the arrowhead has to be drawn rather than modelled
			for _, side in ipairs({ 1, -1 }) do
				local bar = newPart(parent, "Flow", Vector3.new(0.7, 0.25, 4),
					self:segmentCF(legIndex, at, INBOARD, 0.12, pathIndex)
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

--- Hands a drop from leg `fromLeg` of a path onto leg `fromLeg + 1`. Every
--- corner on every floor shares this; the sensor closes over which one it is,
--- so nothing here knows how many legs the path has.
function Tycoon:onTurn(hit: BasePart, pathIndex: number, fromLeg: number)
	local drop = hit.Parent
	if not drop or not drop:IsA("Model") then
		return
	end
	if drop:GetAttribute("PlotIndex") ~= self.index then
		return
	end
	-- Drops that predate multi-floor have no Path attribute; treat them as the
	-- ground floor rather than dropping them on the corner.
	if (drop:GetAttribute("Path") or 1) ~= pathIndex or drop:GetAttribute("Leg") ~= fromLeg then
		return
	end
	local toLeg = fromLeg + 1
	drop:SetAttribute("Leg", toLeg)

	local body = drop.PrimaryPart
	if not body then
		return
	end
	local mover = body:FindFirstChild("BeltMover")
	local upkeep = body:FindFirstChild("StayUpright")
	local direction = self:legDirectionWorld(toLeg, pathIndex)

	if mover and mover:IsA("LinearVelocity") then
		mover.PrimaryTangentAxis = direction
		mover.SecondaryTangentAxis = self:legNormalWorld(toLeg, pathIndex)
		mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
	end
	if upkeep and upkeep:IsA("AlignOrientation") then
		upkeep.CFrame = TungModels.dropOrientation(direction)
	end
end

-- ── belt geometry ────────────────────────────────────────────────────────────
-- A belt is a POLYLINE, not an L. `points` is the corner list and everything —
-- runs, corner sensors, machines, buttons, flow markers — derives from leg(i),
-- so a path with five corners builds exactly like the shipped two-legged one.
-- The ground floor is Config.BeltPaths[1], which is itself written in terms of
-- Layout.BeltStart / BeltCorner / BeltEnd so the two cannot drift apart.

--- Registers a belt path and returns its index. Idempotent by id, because a
--- floor that is torn down and rebuilt must not stack up a second copy of its
--- own geometry — the path is pure maths, only the parts get rebuilt.
function Tycoon:addBeltPath(def, outboard: { number }?): number
	for index, existing in ipairs(self.paths) do
		if existing.id == def.id then
			return index
		end
	end
	table.insert(self.paths, resolvePath(def, outboard or def.outboard))
	return #self.paths
end

function Tycoon:beltPath(pathIndex: number?)
	return self.paths[pathIndex or 1]
end

function Tycoon:legCount(pathIndex: number?): number
	return #self:beltPath(pathIndex).legs
end

--- start, finish, unit direction, length and the outboard normal of a leg,
--- all in PLOT-LOCAL space, plus the path it belongs to.
function Tycoon:leg(index: number, pathIndex: number?)
	local path = self:beltPath(pathIndex)
	local leg = path.legs[index]
	return leg.a, leg.b, leg.dir, leg.length, leg.normal, path
end

--- A point `distance` along a leg, offset sideways. Positive offset is
--- outboard (toward the plot edge), negative is inboard (toward the floor).
--- The path's own height is baked in, so a leg on the mezzanine lands on the
--- mezzanine without every caller having to know which floor it is on.
function Tycoon:pointOnLeg(index: number, distance: number, offset: number, pathIndex: number?): Vector3
	local a, _, dir, _, normal, path = self:leg(index, pathIndex)
	return a + dir * distance + normal * (offset or 0) + Vector3.new(0, path.y, 0)
end

function Tycoon:legDirectionWorld(index: number, pathIndex: number?): Vector3
	local _, _, dir = self:leg(index, pathIndex)
	return self.cf:VectorToWorldSpace(dir).Unit
end

function Tycoon:legNormalWorld(index: number, pathIndex: number?): Vector3
	local _, _, _, _, normal = self:leg(index, pathIndex)
	return self.cf:VectorToWorldSpace(normal).Unit
end

--- Which leg (and which floor's belt) a machine lives on: droppers on the back
--- edge of the ground floor, upgraders on its left edge.
---
--- A def may pin itself instead, which is how FloorService stands a dropper on
--- an upper floor without inventing a second slot table.
function Tycoon:legOf(def): (number, number, number)
	if def.legIndex then
		return def.legIndex, def.legDistance or 0, def.pathIndex or 1
	end
	if def.kind == "Dropper" then
		return 1, L.DropperDist[def.slot], 1
	end
	return 2, L.UpgraderDist[def.slot], 1
end

--- World CFrame of a box lying along a leg.
function Tycoon:segmentCF(index: number, distance: number, offset: number, y: number, pathIndex: number?): CFrame
	local _, _, dir = self:leg(index, pathIndex)
	local point = self:pointOnLeg(index, distance, offset, pathIndex) + Vector3.new(0, y, 0)
	return self.cf * CFrame.lookAt(point, point + dir)
end

--- Every live belt surface on the plot, on every floor. Skips destroyed ones:
--- tearing a floor down leaves its surfaces referenced but dead, and writing a
--- property on a destroyed part throws.
function Tycoon:eachBeltSurface(fn: (BasePart) -> ())
	for _, path in ipairs(self.paths) do
		for _, surface in ipairs(path.surfaces) do
			if surface.Parent then
				fn(surface)
			end
		end
	end
end

-- ── collector ────────────────────────────────────────────────────────────────

--- Run-off ramp, collect sensor and the body that catches the drops, at the end
--- of a path's last leg.
---
--- `headline` adds the vault dressing — gold trim, statue, income sign. Only
--- the ground floor gets it: a second statue on every upper floor is noise, and
--- the income readout on it would be wrong anyway (it reports the whole plot).
function Tycoon:buildCollector(pathIndex: number?, parent: Instance?, headline: boolean?)
	pathIndex = pathIndex or 1
	local path = self:beltPath(pathIndex)

	local folder = parent
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Collector"
		folder.Parent = self.model
		self.collectorFolder = folder
		self:registerFactoryFolder(folder)
	end

	-- The catcher sits past the end of the last leg. Its shell must stay
	-- entirely DOWNSTREAM of the sensor: a solid body overlapping the run-off
	-- walls the belt off and nothing can ever be collected.
	local _, beltEnd, exitDir = self:leg(self:legCount(pathIndex), pathIndex)
	local bodyDepth = headline and 10 or 8
	local bodyWidth = headline and 18 or 13
	local bodyHeight = headline and 9 or 6.5
	local centre = path.collectorAt
	local runOff = (centre - beltEnd).Magnitude
	assert(runOff > bodyDepth / 2 + 3,
		("Collector body overlaps the belt run-off on path %q; move its collectorAt further out"):format(tostring(path.id)))

	-- Path-local: `y` is measured from the floor this belt runs on, exactly as
	-- it is everywhere else on the path.
	local function alongExit(distance, y, lateral)
		local point = beltEnd + exitDir * distance + Vector3.new(0, y + path.y, 0)
			+ Vector3.new(-exitDir.Z, 0, exitDir.X) * (lateral or 0)
		return self.cf * CFrame.lookAt(point, point + exitDir)
	end

	newPart(folder, "VaultBase", Vector3.new(bodyWidth, bodyHeight, bodyDepth),
		alongExit(runOff, bodyHeight / 2, 0), COLORS.vault, Enum.Material.WoodPlanks)
	newPart(folder, "VaultTrim", Vector3.new(bodyWidth + 1, 1.2, bodyDepth + 1),
		alongExit(runOff, bodyHeight + 0.4, 0), COLORS.gold, Enum.Material.Metal)

	-- funnel mouth facing back down the belt
	local mouth = newPart(folder, "Mouth", Vector3.new(bodyWidth - 6, 6, 1.5),
		alongExit(runOff - bodyDepth / 2 - 0.5, L.BeltY + 3, 0),
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

	sensor.Touched:Connect(function(hit)
		self:onCollect(hit)
	end)

	if not headline then
		return
	end

	-- sign
	local signAnchor = newPart(folder, "SignAnchor", Vector3.new(1, 1, 1), alongExit(runOff, 12, 0), COLORS.vault, nil, false)
	signAnchor.Transparency = 1

	local billboard = Style.billboard(signAnchor, {
		name = "Sign", width = 20, height = 6, distance = "plot",
	})
	local label = Style.text(billboard, {
		name = "Rate", text = "SAHUR VAULT", color = COLORS.gold,
	})
	self.vaultLabel = label

	local statue = TungModels.buildStatue("classic", 1.6)
	statue:PivotTo(alongExit(runOff, 13.5, 0) * CFrame.Angles(0, math.pi, 0))
	statue.Parent = folder
	self.vaultStatue = statue
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

	-- `world`, not `plot`: a free plot has to be findable from anywhere on the
	-- ring, and the two furthest-apart plots are a full diameter apart. This is
	-- the one label whose old 1200 was doing a real job rather than being the
	-- number somebody happened to type.
	local billboard = Style.billboard(signAnchor, {
		name = "ClaimSign", width = 34, height = 12, distance = "world",
	})
	local label = Style.text(billboard, {
		text = "PLOT " .. self.index .. "\nFREE — WALK ON IT",
		color = Color3.fromRGB(190, 255, 215),
	})
	self.claimLabel = label
end

-- ── rebirth pad ──────────────────────────────────────────────────────────────

--- The side-track cabinets: a display case standing behind each track's column
--- of buy buttons.
---
--- These carry the wayfinding that the side tracks would otherwise have to
--- take from `pointAt`. There is exactly ONE Highlight per plot and it belongs
--- to the factory (Highlight is capped at 255 per client and disabled ones
--- still occupy a slot), so a cabinet announces itself with a sign instead —
--- which is better anyway, because a sign can say what it is and a glow
--- cannot.
function Tycoon:buildCabinets()
	self.cabinetSigns = {}

	for _, track in ipairs(Config.TrackOrder) do
		if track ~= "factory" and Config.Layout.Tracks[track] then
			local centre, size = Config.trackCabinet(track)
			local model = Instance.new("Model")
			model.Name = "Cabinet_" .. track
			model.Parent = self.props

			local baseCF = self:at(centre.X, 0, centre.Z)
			newPart(model, "Back", size, baseCF * CFrame.new(0, size.Y / 2, 0),
				COLORS.metal, Enum.Material.Metal, true)
			newPart(model, "Trim", Vector3.new(size.X + 1.2, 0.8, size.Z + 1.2),
				baseCF * CFrame.new(0, size.Y + 0.4, 0), COLORS.gold, Enum.Material.Metal, false)

			local anchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1),
				baseCF * CFrame.new(0, size.Y + 2.5, 0), COLORS.metal, Enum.Material.Metal, false)
			anchor.Transparency = 1

			local billboard = Style.billboard(anchor, {
				name = "Sign", width = 18, height = 4, distance = "prop",
			})
			local label = Style.text(billboard, {
				name = "Label", color = COLORS.gold,
				text = (Config.TrackLabel[track] or track:upper()) .. " CABINET",
			})

			self.cabinetSigns[track] = label
		end
	end
end

--- Keeps each cabinet sign honest about how far up its track you are.
function Tycoon:updateCabinetSigns()
	if not self.cabinetSigns then
		return
	end
	for track, label in pairs(self.cabinetSigns) do
		local defs = Config.Tracks[track]
		local owned = 0
		for _, def in ipairs(defs) do
			if self.owned[def.id] then
				owned += 1
			end
		end
		label.Text = ("%s CABINET  •  %d/%d"):format(
			Config.TrackLabel[track] or track:upper(), owned, #defs)
	end
end

function Tycoon:buildRebirthPad()
	local folder = Instance.new("Folder")
	folder.Name = "Rebirth"
	folder.Parent = self.model
	self.rebirthFolder = folder
	self:registerFactoryFolder(folder)

	local spot = L.RebirthPadAt
	local pad = newPart(folder, "RebirthPad", Vector3.new(12, 1.2, 12),
		self:at(spot.X, 0.9, spot.Z), Color3.fromRGB(200, 120, 255), Enum.Material.Neon)
	pad.CanCollide = false
	self.rebirthPad = pad

	local ring = newPart(folder, "RebirthRing", Vector3.new(0.4, 16, 16),
		self:at(spot.X, 0.3, spot.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(120, 60, 200), Enum.Material.Neon, false)
	ring.Shape = Enum.PartType.Cylinder

	local billboard = Style.billboard(pad, {
		name = "Sign", width = 16, height = 6, distance = "prop", offset = 6,
	})
	self.rebirthLabel = Style.text(billboard, {
		name = "Label", text = "SAHUR REBIRTH",
		color = Color3.fromRGB(235, 200, 255),
	})

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
		local legIndex, distance, pathIndex = self:legOf(def)
		return self:pointOnLeg(legIndex, distance, -L.ButtonOffset, pathIndex)
	end
	-- Side tracks stand in their own derived column at their cabinet, so a new
	-- tier needs no coordinate anywhere. Only the factory's non-belt buttons
	-- are still hand-placed in Layout.MiscButtons.
	if def.track and def.track ~= "factory" then
		return Config.trackButtonPosition(def.track, def.trackOrder)
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

		local billboard = Style.billboard(pad, {
			name = "Info", width = 16, height = 9, distance = "prop", offset = 6,
			-- Readable through your own machinery. Without this the label for
			-- the button you are walking towards disappears behind the dropper
			-- next to it exactly when you need it.
			alwaysOnTop = true,
		})

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
		--
		-- The track name, not a global ordinal. "STEP 21 OF 30" on a pedestal
		-- in front of a weapons cabinet tells you nothing; "WEAPONS 2/5" is
		-- the whole feature explained in three words.
		local step = Style.text(frame, {
			name = "Step", weight = "body",
			size = UDim2.fromScale(0.94, 0.18), position = UDim2.fromScale(0.03, 0.02),
			text = ("%s %d/%d"):format(
				Config.TrackLabel[def.track] or "STEP", def.trackOrder, #Config.Tracks[def.track]),
			color = Color3.fromRGB(150, 142, 172),
		})

		local title = Style.text(frame, {
			name = "Title",
			size = UDim2.fromScale(0.94, 0.32), position = UDim2.fromScale(0.03, 0.2),
			text = def.name, color = Color3.fromRGB(255, 240, 210),
		})

		local effect = Style.text(frame, {
			name = "Effect", weight = "body",
			size = UDim2.fromScale(0.94, 0.22), position = UDim2.fromScale(0.03, 0.52),
			text = def.blurb or "", color = Color3.fromRGB(150, 235, 190),
		})

		local price = Style.text(frame, {
			name = "Price", weight = "body",
			size = UDim2.fromScale(0.94, 0.24), position = UDim2.fromScale(0.03, 0.74),
			color = COLORS.buttonOn,
		})
		price.Text = "$" .. Util.abbreviate(def.price)

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
--- How far past its own frontier each track previews.
---
--- 3 on the factory keeps the shipped plot exactly as it reads today. 2 on the
--- side tracks because they are short: at 3 a five-rung cabinet would preview
--- its entire ladder from the moment the plot is claimed, the "hidden" state
--- would stop existing there, and the case would stop reading as something you
--- are climbing.
local TRACK_PREVIEW = { factory = 3, weapons = 2, armor = 2 }

--- Which track the "buy this next" beacon prefers. The beacon picks the
--- cheapest AVAILABLE button, and a cabinet's first rung is cheap — so without
--- a track preference the marker would hop off the factory and onto a bat the
--- moment the plot was claimed. Rank by (track, price), factory first.
local TRACK_RANK = { factory = 1, weapons = 2, armor = 3 }

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

	-- How far along EACH track the player has got. One frontier per track is a
	-- strict generalisation of the old single scan: with one track it produces
	-- exactly the numbers that loop produced.
	local frontier = {}
	for track, defs in pairs(Config.Tracks) do
		frontier[track] = #defs + 1
		for _, def in ipairs(defs) do
			if not self.owned[def.id] then
				frontier[track] = def.trackOrder
				break
			end
		end
	end

	local target, targetRank, targetPrice = nil, math.huge, math.huge

	for id, entry in pairs(self.objects) do
		local def = entry.def
		local owned = self.owned[id] == true
		local available = (not owned) and self:requirementsMet(id)
		local preview = (not owned) and (not available)
			and (def.trackOrder <= frontier[def.track] + (TRACK_PREVIEW[def.track] or 3))

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
			-- Name the thing you have to buy, not an ordinal. "step N" meant
			-- one thing when there was one chain; with three tracks the global
			-- order is meaningless on a pedestal and the per-track one is
			-- ambiguous across cabinets. The requirement is right here, so say
			-- it: "locked — buy Oak Sahur Bat first".
			local blocker
			for _, req in ipairs(Config.requirementsOf(def)) do
				if not self.owned[req] then
					blocker = Config.ButtonById[req]
					break
				end
			end
			entry.effectLabel.Text = blocker
				and ("locked — buy %s first"):format(blocker.name)
				or "locked"
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

			-- (track, price) lexicographically. Cheapest-overall would park the
			-- beacon on the first cabinet rung for the whole early game, since
			-- a bat costs less than the next dropper for most of it.
			local rank = TRACK_RANK[def.track] or 99
			if rank < targetRank or (rank == targetRank and def.price < targetPrice) then
				target, targetRank, targetPrice = entry, rank, def.price
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
	self:updateCabinetSigns()
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
	self:fireOwnedChanged()
end

-- ── installers ───────────────────────────────────────────────────────────────

Tycoon.INSTALLERS = {}

--- The dropper machine itself: masses, dressing, nameplate. Shared by the buy
--- button installer and by FloorService, which stands one on each upper floor —
--- a floor's dropper is not a button, so it cannot go through INSTALLERS.
--- Returns the model, its nozzle, and the leg and path it feeds.
function Tycoon:buildDropperMachine(def, parent: Instance)
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Dropper_" .. def.id
	model.Parent = parent

	local parts, legIndex, _, pathIndex = self:buildMasses(def, model, COLORS.frame, Enum.Material.DiamondPlate)

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

	local billboard = Style.billboard(core, {
		name = "Plate", width = 9, height = 2.6, distance = "machine", offset = 3.4,
	})
	Style.text(billboard, {
		weight = "body", color = Color3.fromRGB(255, 250, 235),
		text = def.name .. "  •  $" .. Util.abbreviate(def.dropValue),
	})

	return model, nozzle, legIndex, pathIndex
end

--- Starts a dropper's drop loop. `alive` is polled each cycle so the caller
--- decides what ends it: a bought dropper dies when its button is wiped by a
--- rebirth, a floor's dropper dies when the floor is torn down (its model is
--- destroyed, which the model.Parent check catches on its own).
function Tycoon:startDropLoop(def, model: Model, nozzle: BasePart, legIndex: number, pathIndex: number?, alive: (() -> boolean)?)
	local generation = self.generation
	task.spawn(function()
		-- stagger so ten droppers don't fire on the same frame
		task.wait(math.random() * def.dropRate)
		while self.generation == generation and model.Parent and (alive == nil or alive()) do
			self:spawnDrop(def, nozzle, legIndex, pathIndex)
			task.wait(def.dropRate)
		end
	end)
end

Tycoon.INSTALLERS.Dropper = function(self, def, silent)
	local model, nozzle, legIndex, pathIndex = self:buildDropperMachine(def, self.machines)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end

	self:startDropLoop(def, model, nozzle, legIndex, pathIndex, function()
		return self.owned[def.id] == true
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

	local billboard = Style.billboard(beam, {
		name = "Plate", width = 11, height = 3, distance = "machine", offset = 3,
	})
	Style.text(billboard, {
		text = ("%s  x%.2g"):format(def.name, def.multiplier),
		color = Color3.fromRGB(255, 240, 210),
	})

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
	-- one speed for the whole plot, every floor included
	self:eachBeltSurface(function(surface)
		surface.Color = Color3.fromRGB(92, 70, 40)
	end)
	-- retro-apply to drops already rolling
	for _, drop in ipairs(self.drops:GetChildren()) do
		local mover = drop:FindFirstChildWhichIsA("LinearVelocity", true)
		if mover then
			mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
		end
	end
end

--- A bought tier's display, standing on its own shelf of the track's cabinet.
---
--- Parented into self.props, NOT self.machines: rebirth clears machines, and a
--- weapon you keep across a rebirth must not lose its shelf.
function Tycoon:buildShelfDisplay(def, variant: string, label: string)
	local model = Instance.new("Model")
	model.Name = "Shelf_" .. def.id
	model.Parent = self.props

	local spot = Config.trackShelfPosition(def.track, def.trackOrder)
	local shelfCF = self:at(spot.X, spot.Y, spot.Z)
	newPart(model, "Shelf", Vector3.new(5, 0.6, 8), shelfCF, COLORS.metal, Enum.Material.Metal)

	-- 0.85 rather than the 1.1 the old free-standing anvil used: the display
	-- now stands INSIDE a 13-stud case, and the tallest variants scale up by a
	-- further 1.5 on top of whatever is asked for here.
	local display = TungModels.buildStatue(variant, 0.85)
	display:PivotTo(shelfCF * CFrame.new(0, 3.2, 0))
	display.Parent = model

	local plate = newPart(model, "Plate", Vector3.new(0.4, 1.6, 7),
		shelfCF * CFrame.new(-2.2, 1, 0), COLORS.metal, Enum.Material.Metal, false)
	local billboard = Style.billboard(plate, {
		name = "Plate", width = 7, height = 1.4, distance = "machine", offset = 1.6,
	})
	Style.text(billboard, { weight = "body", text = label, color = COLORS.gold })

	return model
end

Tycoon.INSTALLERS.Gear = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantBat(owner, def.grants)
	end

	local batDef = Config.BatById[def.grants]
	local model = self:buildShelfDisplay(def, batDef and batDef.variant or "classic",
		batDef and batDef.name or def.name)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Armor = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantArmor(owner, def.grants)
	end

	local tierDef = Config.ArmorById[def.grants]
	local model = self:buildShelfDisplay(def, tierDef and tierDef.variant or "classic",
		tierDef and tierDef.name or def.name)

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
		-- With the Floors prototype on, the mezzanine deck IS the roof of the
		-- back half of the plot. Roofing it twice interpenetrates two slabs a
		-- third of a stud apart and hides a floor under a roof nobody can see,
		-- so the roof stops short of the deck with a couple of studs of
		-- daylight between them. Flag off, this is the full-plot roof it has
		-- always been.
		local front = W.PlotSize.Z / 2
		local back = -W.PlotSize.Z / 2
		local floorDef = Config.Prototypes.Floors and Config.Floors[1]
		if floorDef then
			back = floorDef.deckAt.Z + floorDef.deckSize.Z / 2 + 2
		end

		local roof = newPart(model, "Roof", Vector3.new(W.PlotSize.X, 1.4, front - back),
			self:at(0, 20, (front + back) / 2), Color3.fromRGB(138, 88, 58), Enum.Material.WoodPlanks)
		roof.CanCollide = true
		for _, sign in ipairs({ -1, 1 }) do
			for _, signZ in ipairs({ -1, 1 }) do
				newPart(model, "Column", Vector3.new(2.4, 20, 2.4),
					self:at(sign * (halfX - 3), 10, signZ * (halfZ - 3)), Color3.fromRGB(150, 111, 74), Enum.Material.Wood)
			end
		end

		local signAnchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1), self:at(0, 27, 0), COLORS.frame, nil, false)
		signAnchor.Transparency = 1
		local billboard = Style.billboard(signAnchor, {
			name = "Sign", width = 46, height = 12, distance = "plot",
		})
		self.roofSign = Style.text(billboard, {
			text = "TUNG TUNG TUNG SAHUR CO.", color = COLORS.gold,
		})
		self:updateSign()
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

-- ── drops ────────────────────────────────────────────────────────────────────

function Tycoon:spawnDrop(def, nozzle: BasePart, legIndex: number, pathIndex: number?)
	pathIndex = pathIndex or 1
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

	-- Which belt, and how far along it: the corner sensors and the collector
	-- all filter on these, so a drop on the mezzanine is invisible to the
	-- ground floor's geometry and vice versa.
	drop:SetAttribute("Leg", legIndex)
	drop:SetAttribute("Path", pathIndex)

	local body = drop.PrimaryPart :: BasePart
	local direction = self:legDirectionWorld(legIndex, pathIndex)
	local across = self:legNormalWorld(legIndex, pathIndex)
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
	elseif def.kind == "Gear" then
		-- Same rule as the income kinds: quote the measured effect, not the
		-- flavour text. A bat's whole value is its numbers.
		local bat = Config.BatById[def.grants]
		if bat then
			return ("%d dmg  •  %.0f%% crit"):format(bat.damage, bat.crit * 100)
		end
	elseif def.kind == "Armor" then
		local tier = Config.ArmorById[def.grants]
		if tier then
			local previous = Config.Armor.Tiers[tier.tier - 1]
			return ("%d max health  (+%d)"):format(tier.health, tier.health - (previous and previous.health or 0))
		end
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
	self:fireOwnedChanged()
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
	-- The cabinet BODIES are permanent plot furniture; only the shelves a
	-- previous owner filled come down. A new owner arrives with their own
	-- tiers, and assign() replays them.
	for _, child in ipairs(self.props:GetChildren()) do
		if child.Name:match("^Shelf_") then
			child:Destroy()
		end
	end
	self:clearDrops()
	self:setFactoryVisible(false)

	self:eachBeltSurface(function(surface)
		surface.Color = COLORS.belt
	end)
	self.roofSign = nil

	self:refreshButtons()
	self:updateSign()
	self:fireOwnedChanged()
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

	-- A rebirth is a FACTORY reset, not an account reset. The cabinets are
	-- bought with the same wallet but they are not part of the thing being
	-- rebuilt, and re-earning your bat every prestige is exactly the coupling
	-- this split exists to remove.
	--
	-- This also closes a live bug. Rebirth used to wipe `owned` wholesale
	-- while leaving profile.batTier alone, and CombatService.grantBat is
	-- monotonic — so re-buying batforge afterwards took your money and did
	-- nothing at all.
	local kept = {}
	for id in pairs(profile.owned) do
		local def = Config.ButtonById[id]
		if def and def.track ~= "factory" then
			kept[id] = true
		end
	end
	profile.owned = kept

	self.generation += 1
	self.owned = Util.shallowCopy(kept)
	self.beltSpeed = L.BeltSpeed
	for _, entry in pairs(self.objects) do
		-- Side-track props live in self.props and are not cleared below, so
		-- their entries must keep their handle or the model outlives its
		-- reference and can never be cleaned up.
		if entry.def.track == "factory" then
			entry.machine = nil
		end
	end
	self.machines:ClearAllChildren()
	self:clearDrops()

	self:refreshButtons()
	self:updateSign()
	self:fireOwnedChanged()
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

--- The plot's own part constructor, exposed so FloorService builds its deck out
--- of the same defaults (anchored, smooth surfaces, collidable unless told
--- otherwise) instead of a second near-identical local copy that drifts.
Tycoon.part = newPart

return Tycoon
