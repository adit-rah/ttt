--[[
	tycoon/Installers.lua — one case per `kind`, and the machines those cases
	build.

	ADDING CONTENT IS A Config.Buttons ROW, NEVER A CASE HERE. A new case means a
	new KIND of buyable, and it has to land in three places at once: this table,
	KNOWN_KINDS in tools/verify_config.lua, and the contract in the header of
	tycoon/Tycoon.lua.

	Every installer takes (self, def, silent) and runs AFTER install() has set
	self.owned[def.id], so a rung may count itself. They must be IDEMPOTENT UNDER
	REPLAY, because assign() reinstalls every owned button in `order`: Power
	assigns Config.powerFactor(owned) rather than multiplying into the factor,
	which is what makes it correct under a replay, under a double install, and
	under a save holding power3 without power2. Land is a documented no-op for a
	related reason — the ground outlives the purchase, so ensureLand reconciles
	it on the refreshButtons beat.

	THE SHELL IS EMITTED FROM Config.Structure AND NOTHING ELSE. buildWallRing
	walks Config.wallSegments and builds exactly the spans it is handed; it does
	not decide where a wall stops, how tall it is or where its openings are. That
	is not tidiness — the walls were five boxes at a local `h = 13` under a roof
	whose underside was 20, so every plot in the game had a seven-stud open band
	around it and none of the 2309 config checks could see the number that caused
	it. A span the verifier can sum is a span the verifier can hold to its extent.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local CombatService = Req("CombatService")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local newPart = Parts.newPart
local COLORS = Tycoon.COLORS

-- Config.Layout is no longer read here. The gateway's centre and width still
-- live in it, but they are read by Config.Structure.Openings now: the shell is
-- built from ONE spec, and a builder that reached into Layout for half a wall
-- would be a second source for the same geometry.
local W = Config.World
local S = Config.Structure

-- The shell's palette. Colour is the one thing about the wall this rewrite did
-- NOT move into Config: what changed is its geometry, and the wall you walk up
-- to is the same colour and material it always was.
local WALL_COLOR = Color3.fromRGB(150, 111, 74)
local ROOF_COLOR = Color3.fromRGB(138, 88, 58)

-- THE NEON TRIM, AND THE INTERIOR STRIP BUILT FROM THE SAME IDIOM.
--
-- Config.Structure.Trim, not derived from the wall's thickness. It was derived
-- while this was written, which read as thrift and was actually a second source
-- for a shipped number: Config.shellPartCount could not count a part whose
-- existence it could not see, and the budget was being asserted 13% under what
-- the builder emits.
local LIGHTS = S.Lights
local TRIM_SECTION = S.Trim.section
local TRIM_PROUD = S.Trim.proud

-- ── the shell's geometry ─────────────────────────────────────────────────────

--- The size and CFrame of a box lying along one wall of the ring.
---
--- WHICH OF X AND Z IS THE LENGTH AND WHICH IS THE THICKNESS IS
--- Config.wallExtent'S BUSINESS. The old wall answered that question by hand,
--- once per box, in five hand-written CFrames — and the asymmetry it encodes
--- (the side walls run the full plot depth, the front and back sit between them)
--- is four corners at once if any one of them is written differently.
---
--- `cross` is how far INBOARD of the wall plane the box's centre sits: 0 for
--- everything in the wall itself, `gateCross(opening)` for a leaf hanging off it.
local function alongWall(tycoon, extent, along: number, y: number, cross: number,
	length: number, height: number, thickness: number)
	local fixed = extent.fixed - extent.outward * cross
	if extent.axis == "X" then
		return Vector3.new(length, height, thickness), tycoon:at(along, y, fixed)
	end
	return Vector3.new(thickness, height, length), tycoon:at(fixed, y, along)
end

--- invariant: HOW FAR OFF THE WALL A GATE LEAF HANGS, and on which side.
---
--- `alongWall`'s `cross` is measured from the wall's CENTRE plane and positive is
--- inboard, so this is half the wall, plus the stated air gap, plus half the leaf
--- — and negated for an opening whose leaves hang outside.
---
--- The yard door hangs outboard and that is not a preference. Its doorway is
--- flush to the end of the back wall, so its single leaf can only slide inward
--- along x, and the inside of the back wall IS the dropper row: an inboard leaf
--- passes 0.1 studs into dropper slot 1. Outboard it travels over the generator
--- yard's own slab, which is empty for its whole run. Both the verifier and this
--- builder found that independently, on the shipped numbers.
---
--- WHICH IS WHY A MISSPELLED FACE IS NOT LET THROUGH QUIETLY. It is not
--- nil-shaped: it is a door built on the wrong side of a wall, and on one of these
--- two walls the wrong side is a machine. Config declares both entries today, so
--- this is for the third opening somebody adds.
local function gateCross(opening): number
	if opening.face ~= "inboard" and opening.face ~= "outboard" then
		warn(("[Tung] opening %s has face %s; it must be \"inboard\" or \"outboard\"")
			:format(tostring(opening.id), tostring(opening.face)))
	end
	local offset = S.WallThickness / 2 + S.Gate.inset + S.Gate.thickness / 2
	return opening.face == "outboard" and -offset or offset
end

--- One course of one wall: `from`..`to` along the side's own axis, `bottom`..`top`
--- in height, a wall thickness across. Callers restyle what comes back — a glass
--- pane is this box with two properties changed, not a second constructor.
local function wallBox(tycoon, parent: Instance, name: string, extent,
	from: number, to: number, bottom: number, top: number)
	local size, cf = alongWall(tycoon, extent, (from + to) / 2, (bottom + top) / 2, 0,
		math.max(to - from, Tycoon.MIN_PART), math.max(top - bottom, Tycoon.MIN_PART),
		S.WallThickness)
	return newPart(parent, name, size, cf, WALL_COLOR, Enum.Material.WoodPlanks)
end

--- A neon bar along one wall, STRADDLING the line it marks rather than sitting
--- flush with it: two coplanar faces at one Y is the z-fight every stacked
--- surface in this game is offset to avoid.
local function neonBar(tycoon, parent: Instance, name: string, extent,
	from: number, to: number, y: number, thickness: number, cross: number)
	local size, cf = alongWall(tycoon, extent, (from + to) / 2, y, cross,
		to - from, TRIM_SECTION, thickness)
	local bar = newPart(parent, name, size, cf, COLORS.beltLine, Enum.Material.Neon, false)
	bar.CanQuery = false
	bar.CastShadow = false
	return bar
end

-- ── installers ───────────────────────────────────────────────────────────────

Tycoon.INSTALLERS = {}

--- The dropper machine itself: masses, dressing, nameplate.
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
		task.wait(math.random() * self:dropInterval(def))
		while self.generation == generation and model.Parent and (alive == nil or alive()) do
			self:spawnDrop(def, nozzle, legIndex, pathIndex)
			task.wait(self:dropInterval(def))
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

	-- The plate you see, which catches nothing...
	local scanner = parts.Scanner
	scanner.Color = variant.light and variant.light.color or variant.wood
	scanner.Material = Enum.Material.Neon
	scanner.Transparency = 0.55
	scanner.CanTouch = false

	-- ...and the volume that does, which you don't. Five studs deep so a drop
	-- cannot cross it between two physics steps on a plot nobody is standing on.
	local trigger = parts.ScanTrigger
	trigger.Transparency = 1
	trigger.CanTouch = true
	trigger.CanQuery = false
	trigger.CastShadow = false

	local billboard = Style.billboard(beam, {
		name = "Plate", width = 11, height = 3, distance = "machine", offset = 3,
	})
	Style.text(billboard, {
		text = ("%s  x%.2g"):format(def.name, def.multiplier),
		color = Color3.fromRGB(255, 240, 210),
	})

	-- The flash. design:D-02 — the upgrader's multiplier lives in
	-- Config.incomeRate; what the trigger does is make the arch visibly work a
	-- drop as it passes. The once-flag stays because Touched fires twice, and
	-- a double flash reads as a stutter.
	local flagName = "up_" .. def.id
	trigger.Touched:Connect(function(hit)
		local drop = hit.Parent
		if not drop or not drop:IsA("Model") then
			return
		end
		if drop:GetAttribute("PlotIndex") ~= self.index then
			return
		end
		if drop:GetAttribute(flagName) then
			return
		end
		drop:SetAttribute(flagName, true)

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
	self.beltBonus += def.speedBonus
	self:refreshBeltSpeed()
	-- one speed for the whole plot, every floor included
	self:eachBeltSurface(function(surface)
		surface.Color = Color3.fromRGB(92, 70, 40)
	end)
end

Tycoon.INSTALLERS.Power = function(self, def, silent)
	-- invariant: THE FACTOR HAS TO BE ASSIGNED HERE. Nothing else writes it on
	-- a purchase, and the generator shipped for two rounds doing nothing at all
	-- because this line was missing — the belt and every dropper ran at stock
	-- speed while incomePerSecond, which reads Config.powerFactor(has) directly,
	-- went on quoting the full multiplier on the HUD, on the buy button and
	-- through SessionService's offline mirror.
	--
	-- DERIVED, NEVER ACCUMULATED. assign() replays a save by installing every
	-- owned button in `order`, so a *= here would land on
	-- 1.19 x 1.42 x 1.68 x 2.00 = 5.67 rather than on 2.00. Config.powerFactor
	-- takes the last owned rung because `factor` is cumulative, which makes
	-- this idempotent under replay, under a double install, and under a save
	-- that somehow holds power3 without power2. install() has already set
	-- self.owned[def.id] before dispatching here, so the rung being bought
	-- counts itself.
	self.powerFactor = Config.powerFactor(function(id: string): boolean
		return self.owned[id] == true
	end)
	self:refreshBeltSpeed()
	-- The machine is derived from `owned` by refreshGenerator, which install()
	-- reaches through refreshButtons on the next line of its own body. It lives
	-- in self.machines rather than self.props, which is what makes a rebirth
	-- take it down along with the droppers it was speeding up while the yard
	-- around it stays.
	self:refreshGenerator()
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

--- Land (#88). A DOCUMENTED NO-OP: the ground outlives the purchase —
--- release, rebirth and re-claim all have to rebuild or drop it and none of
--- them go through install(). ensureLand reconciles the slabs to `owned` on
--- the refreshButtons beat, which install() reaches on its next line anyway.
Tycoon.INSTALLERS.Land = function(self, def, silent)
end

--- Every gate leaf the ring's openings carry: what to build, where it hangs
--- closed, and where it slides to.
---
--- ONE FUNCTION FOR THE BUILDER AND FOR GateService. The walls branch builds
--- these and GateService moves them, and "where does this leaf slide to" written
--- twice is two answers the day either wall moves. GateService finds the parts by
--- the `name` here, so this is also the naming contract between the two files.
function Tycoon:gateLeafSpecs()
	local specs = {}

	for _, side in ipairs(S.Sides) do
		local segments, extent = Config.wallSegments(side)
		for index, segment in ipairs(segments) do
			if segment.kind ~= "opening" then
				continue
			end
			local opening = segment.opening
			local leafWidth = opening.width / opening.leaves
			local bottom, top = 0, opening.height

			-- WHICH WAY A LONE LEAF SLIDES. A pair opens from the middle, one
			-- leaf each way. A single leaf has no middle to open from, so it
			-- slides into whichever neighbouring solid run is LONGER: the yard
			-- door sits at the right-hand end of the back wall with nothing but
			-- the corner on that side, and a leaf sliding the other way would
			-- travel out past the plot edge. Travel is one leaf width, which is
			-- the minimum run length Config.Structure.Gate says beside an opening.
			local before, after = segments[index - 1], segments[index + 1]
			local beforeRun = (before and before.kind == "solid") and (before.to - before.from) or 0
			local afterRun = (after and after.kind == "solid") and (after.to - after.from) or 0
			local lone = (beforeRun >= afterRun) and -1 or 1

			-- The centre of the opening, IN THE WALL PLANE — not out on the leaf
			-- with `gateCross`: what GateService measures a humanoid's distance to
			-- is the doorway, not the door. Following the leaves would put the yard
			-- door's trigger two studs BEHIND the back wall, so walking up to it
			-- from inside the factory would need two studs more approach than
			-- walking up to the inboard gateway does — the same opening measured
			-- differently because of which way its leaf happens to swing.
			local _, centreCF = alongWall(self, extent, opening.centre, (bottom + top) / 2,
				0, opening.width, top - bottom, S.WallThickness)

			for leaf = 1, opening.leaves do
				local closed = segment.from + (leaf - 0.5) * leafWidth
				local direction = lone
				if opening.leaves > 1 then
					direction = (closed < opening.centre) and -1 or 1
				end
				local size, closedCF = alongWall(self, extent, closed, (bottom + top) / 2,
					gateCross(opening), leafWidth, top - bottom, S.Gate.thickness)
				local _, openCF = alongWall(self, extent, closed + direction * leafWidth,
					(bottom + top) / 2, gateCross(opening), leafWidth, top - bottom, S.Gate.thickness)
				table.insert(specs, {
					name = ("Gate_%s_%d"):format(opening.id, leaf),
					opening = opening.id,
					size = size,
					closed = closedCF,
					open = openCF,
					centre = centreCF.Position,
				})
			end
		end
	end

	return specs
end

--- invariant: the ring of walls — the courses Config.wallSegments describes,
--- the gate leaves in its openings, a neon cap along the top of each side and
--- a neon strip along the inside of the ceiling line.
---
--- invariant: THREE COURSES PER SOLID RUN, one lintel per opening. The bay course is
--- Config.wallBays: piers in wall material, panes in glass. A pane is
--- CanCollide — what keeps the camera out of an enclosed plot is the
--- TRANSPARENCY, because PopperCam only treats a part as occluding below 0.25,
--- and Config.Structure.Window.transparency sits at 0.45 for exactly that.
function Tycoon:buildWallRing(model: Instance)
	local win = S.Window
	local floorY = 0
	local top = S.WallHeight
	local sill = floorY + win.sill
	local head = sill + win.height

	for _, side in ipairs(S.Sides) do
		local segments, extent = Config.wallSegments(side)
		for index, segment in ipairs(segments) do
			local tag = ("%s_%d"):format(side, index)
			if segment.kind == "solid" then
				wallBox(self, model, "Sill_" .. tag, extent, segment.from, segment.to, floorY, sill)
				-- A BAY IS BUILT SOLID AND GLAZED LATER. `windows` is its own
				-- purchase now (TODO.md item 3), and the alternative — leaving
				-- the bay as a hole until it is bought — would mean a wall that
				-- does not keep a raider out, which is the one thing `walls` is
				-- sold on. So an unglazed bay is literally a piece of wall, and
				-- buying the windows restyles it rather than filling it.
				--
				-- That also means the part count does not move when the glass
				-- arrives, so Config.shellPartCount and the PartBudget are
				-- measuring the same shell they always were.
				for bay, span in ipairs(Config.wallBays(segment.from, segment.to)) do
					wallBox(self, model,
						("%s_%s_%d"):format(span.kind == "pane" and "Pane" or "Pier", tag, bay),
						extent, span.from, span.to, sill, head)
				end
				wallBox(self, model, "Head_" .. tag, extent, segment.from, segment.to, head, top)
			else
				-- A lintel, not a full-height cut: a 20-stud gateway is not a
				-- door, so the opening keeps its own height and the wall closes
				-- over it.
				wallBox(self, model, "Lintel_" .. tag, extent, segment.from, segment.to,
					floorY + segment.opening.height, top)
			end
		end

		-- ONE CAP AND ONE STRIP PER SIDE, not one per box. The old wall drew a
		-- trim over each of its five pieces; this one is up to thirteen boxes a
		-- side, and thirteen neon slivers is thirteen parts to say one line.
		--
		-- The cap straddles the wall plane and the strip reaches inboard from it,
		-- so from outside the band reads as an eave under the roof and from
		-- inside as a light cove where the wall meets the ceiling. THE STRIP IS
		-- WHY IT IS THERE: the ground floor is an enclosed box now, and the
		-- cheapest light in an enclosed box is a neon part you can see.
		neonBar(self, model, "Trim_" .. side, extent,
			extent.from - TRIM_PROUD / 2, extent.to + TRIM_PROUD / 2, top,
			S.WallThickness + TRIM_PROUD, 0)
		neonBar(self, model, "Light_" .. side, extent,
			extent.from, extent.to, top, TRIM_SECTION, S.WallThickness / 2)
	end

	-- invariant: THE CEILING FIXTURES ARRIVE WITH THE CEILING, not the ring.
	-- refreshCeilingLights is idempotent and driven by whether the plot owns a
	-- roof, so a ring built before the roof comes up unlit and gains its
	-- battens the moment something is overhead.
	self:refreshCeilingLights(model)

	-- invariant: THE TWO UPGRADES THIS RING MAY ALREADY HAVE BEEN SOLD.
	--
	-- `walls`, `gates` and `windows` are three purchases and an installer runs
	-- once, so a ring built after one of them was bought — assign() replaying
	-- a save — has to arrive already carrying it.
	self:applyStructureUpgrades(model)
end

--- Build or remove the ceiling battens to match whether the room is covered —
--- which, with the storey system retired, is exactly "does the plot own a
--- roof".
---
--- IDEMPOTENT IN BOTH DIRECTIONS, because it is called from the roof purchase
--- and because buildWallRing calls it for a ring that may be built after the
--- roof already exists (assign replaying a save). Counted by
--- Config.shellPartCount as part of the shell.
function Tycoon:refreshCeilingLights(model: Instance)
	local wanted = self:hasStructure("roof")
	local prefix = "Fixture_"
	local standing = 0
	for _, part in ipairs(model:GetChildren()) do
		if part.Name:sub(1, #prefix) == prefix then
			if wanted then
				standing += 1
			else
				part:Destroy()
			end
		end
	end
	if not wanted or standing > 0 then
		return
	end
	for index, spot in ipairs(Config.storeyLightPositions()) do
		local batten = newPart(model, ("Fixture_%d"):format(index),
			Vector3.new(LIGHTS.batten.width, LIGHTS.batten.thickness, LIGHTS.batten.length),
			self:at(spot.X, spot.Y, spot.Z), Color3.fromRGB(236, 226, 202), Enum.Material.SmoothPlastic, false)
		batten.CanQuery = false
		Fx.ceilingLight(batten)
	end
end

--- Whether this plot owns a `Structure` button of the given kind.
---
--- Derived from `owned` rather than stored, so it survives release, rebirth and
--- re-claim for free — the same argument as Config.trackUnlocked. A plot that
--- has been rebirthed has lost `walls` too, so there is no state where the glass
--- outlives the wall it is set into.
function Tycoon:hasStructure(structure: string): boolean
	for id in pairs(self.owned) do
		local def = Config.ButtonById[id]
		if def and def.kind == "Structure" and def.structure == structure then
			return true
		end
	end
	return false
end

--- Turn the ring's solid bays into glass. Idempotent, and it adds no parts.
function Tycoon:glazeStorey(model: Instance)
	local glazed = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name:sub(1, 5) == "Pane_" then
			part.Material = Enum.Material.Glass
			part.Transparency = S.Window.transparency
			glazed += 1
		end
	end
	return glazed
end

--- Hang the ring's gate leaves, off the face `opening.face` names.
---
--- They live in the WALL's model rather than one of their own, so release() and
--- rebirth() take them down with everything else — which is why GateService
--- checks a leaf's Parent before it moves it rather than holding a reference and
--- trusting it. Idempotent by name: `gates` can be replayed by assign() over a
--- ring that already has them.
function Tycoon:hangGateLeaves(model: Instance)
	local hung = 0
	for _, leaf in ipairs(self:gateLeafSpecs()) do
		if not model:FindFirstChild(leaf.name, true) then
			newPart(model, leaf.name, leaf.size, leaf.closed, WALL_COLOR, Enum.Material.WoodPlanks)
			hung += 1
		end
	end
	return hung
end

--- Bring the ring up to whatever this plot has bought.
function Tycoon:applyStructureUpgrades(model: Instance)
	if self:hasStructure("windows") then
		self:glazeStorey(model)
	end
	if self:hasStructure("gates") then
		self:hangGateLeaves(model)
	end
end

--- The wall ring standing on this plot right now, handed to `fn`, or nothing.
---
--- Found by its own trim bar rather than by a folder reference, so a caller
--- never holds a model that a release or rebirth already destroyed. This is
--- the same lookup GateService does for a leaf, and it is here so that
--- `gates` and `windows` do not have to learn where the ring lives.
function Tycoon:withWallRing(fn)
	local marker = "Trim_" .. S.Sides[1]
	for _, folder in ipairs(self.factoryFolders) do
		local part = folder:FindFirstChild(marker, true)
		if part and part.Parent then
			fn(part.Parent)
			return 1
		end
	end
	return 0
end

Tycoon.INSTALLERS.Structure = function(self, def, silent)
	local model = Instance.new("Model")
	model.Name = "Structure_" .. def.id
	model.Parent = self.machines

	if def.structure == "walls" then
		self:buildWallRing(model)
	elseif def.structure == "gates" or def.structure == "windows" then
		-- ADDITIVE — never a rebuild. The obvious implementation is to re-emit
		-- the wall with the upgrade included, and that would destroy the gate
		-- leaves GateService may be mid-tween on and re-emit sixty parts that
		-- have not changed. Glass is a material change on a bay that is
		-- already built and a leaf is a part with nothing standing where it
		-- goes, so neither needs the wall touched.
		--
		-- `model` stays empty for these two and that is deliberate: the parts
		-- belong to the ring they are part of, so a rebirth takes the glass
		-- down with the wall rather than leaving panes floating in a plot with
		-- no shell. The entry below still records the model so the object
		-- bookkeeping is uniform.
		self:withWallRing(function(ring)
			if def.structure == "windows" then
				self:glazeStorey(ring)
			else
				self:hangGateLeaves(ring)
			end
		end)
	elseif def.structure == "roof" then
		self:buildRoofModel(model)
		-- THE MOMENT THE ROOM GAINS A CEILING. The ring was built at `walls`
		-- some twenty minutes ago and came up unlit, because until now there
		-- was nothing over it to hang a fixture under.
		self:withWallRing(function(ring)
			self:refreshCeilingLights(ring)
		end)
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

--- invariant: the roof slab, its columns and the company sign.
---
--- Extracted from the installer so refreshRoof can REBUILD it — tween-free,
--- leaf-free, and therefore the one piece of structure that a rebuild cannot
--- hurt. Config.roofUnderside is the one structural line, and the walls are
--- derived from the same one.
function Tycoon:buildRoofModel(model: Instance)
	model:ClearAllChildren()

	local underside = Config.roofUnderside()
	-- The wall ring's own |x| and |z|, read from the extents the walls are built
	-- from rather than re-derived here: "inset in from the wall ring" has to mean
	-- the wall the columns stand beside.
	local ringX = Config.wallExtent("right").fixed
	local ringZ = Config.wallExtent("front").fixed

	local roof = newPart(model, "Roof", Vector3.new(W.PlotSize.X, S.Roof.thickness, W.PlotSize.Z),
		self:at(0, underside + S.Roof.thickness / 2, 0), ROOF_COLOR, Enum.Material.WoodPlanks)
	roof.CanCollide = true

	for _, signX in ipairs({ -1, 1 }) do
		for _, signZ in ipairs({ -1, 1 }) do
			newPart(model, "Column", Vector3.new(S.Roof.column, underside, S.Roof.column),
				self:at(signX * (ringX - S.Roof.columnInset), underside / 2,
					signZ * (ringZ - S.Roof.columnInset)),
				WALL_COLOR, Enum.Material.Wood)
		end
	end

	-- THE SIGN CLEARS THE ROOF'S TOP FACE, and it is the roof's own top face it
	-- clears. This was a literal 27 against a roof at 20; at the mezzanine's
	-- underside of 38 that anchor would have been buried inside the slab.
	local signAnchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1),
		self:at(0, underside + S.Roof.thickness + S.Roof.signLift, 0), COLORS.frame, nil, false)
	signAnchor.Transparency = 1
	local billboard = Style.billboard(signAnchor, {
		name = "Sign", width = 46, height = 12, distance = "plot",
	})
	self.roofSign = Style.text(billboard, {
		text = "TUNG TUNG TUNG SAHUR CO.", color = COLORS.gold,
	})
	self:updateSign()
end

--- Rebuilds an already-built roof and re-answers whether the room is lit.
--- The lights ride along because it is the same event — "something over the
--- room changed" — and they are refreshed FIRST and unconditionally, because
--- on a plot that owns no roof `self.objects.roof` is nil and the tail of
--- this function does nothing at all.
function Tycoon:refreshRoof()
	self:withWallRing(function(ring)
		self:refreshCeilingLights(ring)
	end)

	local entry = self.objects.roof
	local model = entry and entry.machine
	if model and model.Parent then
		self:buildRoofModel(model)
	end
end

return Tycoon
