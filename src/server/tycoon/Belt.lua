--[[
	tycoon/Belt.lua — the conveyor: its geometry, its running surfaces, its
	corner sensors, and the one speed the whole plot runs at.

	A BELT IS A POLYLINE, NOT AN L. `points` is the corner list and everything —
	runs, corner sensors, machines, buttons, flow markers — derives from leg(i),
	so a path with five corners builds exactly like the shipped two-legged one.
	resolvePath CARRIES each leg's outboard side rather than inferring it: the
	inference held only while every leg hugged an outer edge, and it inverted for
	an upper floor's return leg, putting that floor's machines over its walkway
	and its buy buttons out in space.

	NO PER-FRAME WORK, ANYWHERE. Drops are moved by a LinearVelocity in Plane
	mode and handed from leg to leg by one Touched sensor per bend, so an
	N-legged path costs N-1 triggers and no Heartbeat loop over hundreds of
	drops. The corner geometry depends on that: nothing solid stands near the
	belt, every leg's surface runs THROUGH its corner square, and the trim is
	decoration with CanCollide off.

	refreshBeltSpeed is the only writer of self.beltSpeed and it RECOMPUTES from
	the two inputs (additive Belt bonus, multiplicative generator factor) rather
	than accumulating. assign() replays a save by installing every owned button
	in `order`, so a `*=` here would land on the product of every rung instead of
	the top one — the Studio-only assertion in that function is the check that
	would have caught the generator shipping unassigned for two rounds.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local TungModels = Req("TungModels")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local RunService = game:GetService("RunService")

local newPart = Parts.newPart
local COLORS = Tycoon.COLORS

local L = Config.Layout

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
	local GUARD = L.BeltGuard
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

		newPart(folder, "BeltBase" .. index, Vector3.new(width + L.BeltBaseProud, surfaceY - 0.2, length),
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

		return surface
	end

	-- invariant: the guard walls. A run on ONE leg, set back from both of that
	-- leg's ends by BeltGuard.corner, on both sides. design:D-07.
	--
	-- The setback is the whole of the fix. The old rails ran each leg's full
	-- length, and because every leg's surface deliberately overruns its bend by
	-- half a belt width (see the loop below), leg 2's inboard rail crossed leg
	-- 1's path and vice versa. Pulling back eight studs at each end leaves the
	-- corner square completely clear — of the neighbouring leg, and of the turn
	-- sensor whose leading face sits just past the bend.
	--
	-- Two parts a side: a solid kick plate at drop height's underside with a neon
	-- top rail sitting flush on it, so the pair reads as one guard with a lit
	-- cap rather than as two separate bars. The kick is sized off the rail's
	-- centre for exactly that reason — see the note in buildGuard.
	--
	-- NEVER COLLIDABLE. Same contract as the end cap and the flow markers, and
	-- the long argument is in Config.Layout.BeltGuard.
	local function buildGuard(index, fromDist, toDist)
		local run = toDist - fromDist
		if run <= Tycoon.MIN_PART then
			return
		end
		local mid = (fromDist + toDist) / 2
		local lateral = half - GUARD.bite + GUARD.thickness / 2

		for _, side in ipairs({ -1, 1 }) do
			local kickHeight = GUARD.height - GUARD.bar / 2 - GUARD.kick
			local kick = newPart(folder, ("Guard%d_%s"):format(index, side < 0 and "in" or "out"),
				Vector3.new(GUARD.thickness, kickHeight, run),
				self:segmentCF(index, mid, side * lateral, surfaceY + GUARD.kick + kickHeight / 2, pathIndex),
				COLORS.frame, Enum.Material.DiamondPlate, false)
			kick.CanQuery = false

			-- `height` IS THE BAR'S CENTRE, which is what Config says it is and
			-- what the kick plate above is sized against: kickHeight is
			-- `height - bar/2 - kick`, so the plate's top lands at exactly the
			-- bar's underside and the two make one continuous guard.
			--
			-- This read `height + bar` and three things disagreed about one
			-- rail. Config documented the field as the centre; the kick plate's
			-- own arithmetic assumed the centre; the verifier's clearance check
			-- modelled the top at `BeltY + height + bar/2`. Only the builder
			-- added the extra section, so the rail floated 0.35 studs clear of
			-- the plate it is supposed to sit on, and every clearance check in
			-- verify_config was measuring a rail 0.35 studs shorter than the one
			-- being built. The comment above this block then explained the slot
			-- as deliberate air "at exactly drop-body height" — 0.35 studs is
			-- not a drop, and the gap was arithmetic rather than a decision.
			local bar = newPart(folder, ("GuardRail%d_%s"):format(index, side < 0 and "in" or "out"),
				Vector3.new(GUARD.bar, GUARD.bar, run),
				self:segmentCF(index, mid, side * lateral, surfaceY + GUARD.height, pathIndex),
				COLORS.beltLine, Enum.Material.Neon, false)
			bar.CanQuery = false
			bar.CastShadow = false
		end
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
		-- The guard is the run pulled back AT EVERY END THAT MEETS ANOTHER LEG,
		-- measured off the surface's own span rather than off the leg's, so a
		-- leg that overruns its bend does not drag its rails over the neighbour.
		--
		-- PULLED BACK AT BENDS ONLY, WHICH IS WHERE THE REASON HOLDS. This set
		-- back both ends of every leg, and the setback's whole argument is about
		-- a neighbour: clear the corner square the surfaces overrun by half a
		-- belt width, and clear the turn sensor's leading face just past the
		-- bend. Leg 1 starts behind the first dropper and the last leg ends at
		-- the collector — no neighbour, no corner square, no sensor at either.
		-- So the ground belt ran its surface -1.0 .. 94.0 with rail only over
		-- 7.0 .. 86.0, and the eight bare studs at each open end were the rule
		-- being applied where its reason had run out.
		local startsAtBend = index > 1
		local endsAtBend = index < legs
		buildGuard(index,
			fromDist + (startsAtBend and GUARD.corner or 0),
			toDist - (endsAtBend and GUARD.corner or 0))
	end
	path.surfaces = surfaces

	-- Visual end cap behind the first dropper. Non-collidable: nothing should
	-- ever reach it, and if something does we want it to slide off, not wedge.
	local cap = newPart(folder, "BeltCap", Vector3.new(width + L.BeltBaseProud, 1.6, 0.6),
		self:segmentCF(1, -1.2, 0, surfaceY + 0.8, pathIndex), COLORS.metal, Enum.Material.Metal, false)
	cap.CanQuery = false

	-- One trigger per bend, spanning the belt, handing a drop from leg i's
	-- direction to leg i+1's. No geometry, just a retarget — so an N-legged
	-- path costs N-1 triggers and still no per-frame work.
	for index = 1, legs - 1 do
		local _, _, _, length = self:leg(index, pathIndex)
		-- Widened like the others, but SHIFTED DOWNSTREAM by half the extra so
		-- its leading face stays where it was. An early trigger is harmless at
		-- an upgrader or the collector; at a corner it retargets the drop
		-- before it has reached the corner, which cuts it and puts it on the
		-- next leg off-centre.
		local turn = newPart(folder, "TurnSensor" .. index,
			Vector3.new(width + 1, 6, L.TriggerThickness),
			self:segmentCF(index, length + (L.TriggerThickness - 2.5) / 2, 0, surfaceY + 3, pathIndex),
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

--- Recomputes the plot's belt speed from its two inputs and retargets whatever
--- is already rolling.
---
--- ONE SPEED FOR THE WHOLE PLOT, every floor included: eachBeltSurface walks
--- every registered path, and the drops read the cached product at spawn and at
--- each corner. This adds no per-frame work — the retarget below is a one-shot
--- sweep on purchase, and the "no Heartbeat loop over hundreds of drops" rule
--- the conveyor is built around still holds.
function Tycoon:refreshBeltSpeed()
	self.beltSpeed = (L.BeltSpeed + self.beltBonus) * self.powerFactor

	-- THE CHECK THAT WOULD HAVE CAUGHT THE GENERATOR, and it has to live beside
	-- the read rather than in verify_config.lua: the defect was a field declared
	-- in tycoon/Class.lua and assigned nowhere, and the verifier reads Config.lua
	-- and nothing else. Every config-level assertion about the power ladder
	-- passed while the belt ran at stock speed for two rounds. The field is now
	-- written in tycoon/Installers.lua and read here — two files, which is MORE
	-- reason for this assert rather than less.
	--
	-- Recomputed from `owned` and compared against the two cached inputs, so it
	-- fires on a powerFactor that was never set (the shipped bug, 37 instead of
	-- 62.2), on one accumulated across an install replay (78.1), and on a
	-- beltBonus applied after the multiply instead of before it (56).
	if RunService:IsStudio() then
		local want = (L.BeltSpeed + self.beltBonus) * Config.powerFactor(function(id: string): boolean
			return self.owned[id] == true
		end)
		assert(math.abs(self.beltSpeed - want) < 1e-6, ("belt speed is %.2f but this plot's owned set says %.2f")
			:format(self.beltSpeed, want))
	end

	for _, drop in ipairs(self.drops:GetChildren()) do
		local mover = drop:FindFirstChildWhichIsA("LinearVelocity", true)
		if mover then
			mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
		end
	end
end

--- Seconds between drops for `def` on THIS plot right now.
---
--- Read fresh each cycle rather than baked into the loop, so a generator bought
--- mid-run is picked up on the next drop of every dropper with no loop restart
--- and no generation bump. NEVER writes def.dropRate: Config.ButtonById tables
--- are shared by every plot on the server, so mutating one would speed up the
--- neighbours' factories too.
function Tycoon:dropInterval(def): number
	local factor = self.powerFactor
	if not factor or factor < 1 then
		factor = 1   -- a zero here would stop every dropper on the plot forever
	end
	return math.max(0.2, def.dropRate / factor)
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
		return def.legIndex, def.legDistance or 0, self:pathIndexOf(def)
	end
	if def.kind == "Dropper" then
		return 1, L.DropperDist[def.slot], 1
	end
	return 2, L.UpgraderDist[def.slot], 1
end

--- Which registered path a def means. A button carries `path` as an ID rather
--- than an index, because the index is assigned at runtime by addBeltPath and
--- Config has no way to know it. Falls back to the ground floor, which is what
--- every button without a `path` means.
function Tycoon:pathIndexOf(def): number
	if def.pathIndex then
		return def.pathIndex
	end
	if def.path then
		for index, path in ipairs(self.paths) do
			if path.id == def.path then
				return index
			end
		end
		warn("[Tung] button " .. tostring(def.id) .. " names belt path " .. tostring(def.path) .. ", which is not registered")
	end
	return 1
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

return Tycoon
