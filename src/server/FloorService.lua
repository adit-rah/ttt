--[[
	FloorService.lua — the second-storey prototype.

	A mezzanine deck over the BACK half of the plot, with its own dropper ->
	belt -> collector loop and a pair of teleport pads. Gated on
	Config.Prototypes.Floors; a no-op when the flag is off, and per plot it only
	appears once that plot owns Config.Floors[1].requires — the last button of
	the ground floor. "You buy floor 2 before you get anywhere near finishing
	floor 1" is the single most complained-about thing in multi-floor tycoons.

	Three decisions that look arbitrary and are not:

	  OFFSET, NOT STACKED. The deck covers the back half only, so the aisle you
	  walk down and the buy-button spine stay open to the sky. Roblox has no
	  good answer for a ceiling: opaque snaps the camera to head height,
	  transparent lets it pop through, and LocalTransparencyModifier is
	  overwritten by the default camera scripts every frame.

	  PADS, NOT A LIFT. Every shipped "elevator" in this genre is a teleport
	  pair. TweenService platforms jitter and slide players off, and they buy
	  nothing: the pads do not even have to be vertically aligned.

	  ITS OWN LOOP. Each floor runs an independent dropper -> belt -> collector.
	  Cross-floor transport is the trap — upward conveyors need velocity >= 25
	  and still stick.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Tycoon = Req("Tycoon")

local FloorService = {}

local FLOOR = Config.Floors and Config.Floors[1]

-- Geometry Config.Floors has no key for yet, so it lives here rather than in
-- someone else's file this week. SHOULD MOVE TO CONFIG: all of it belongs in
-- the Config.Floors entry beside deckSize / padUp / railHeight.
local DECK_LIFT = 0.1        -- belt and machines float this far over the deck
local BACK_MARGIN = 12       -- belt leg 1, in from the deck's back edge
local FRONT_MARGIN = 14      -- the return leg, in from the front edge
local SIDE_MARGIN = 10       -- the side legs, in from the left/right edges
local COLLECTOR_RUN = 16     -- run-off between the belt's end and the hopper
local PAD_CLEARANCE = 12     -- keep the hopper this clear of the teleport pad
local DROPPER_AT = 14        -- distance along leg 1 for the floor's dropper
local RAIL_THICKNESS = 1
local RAIL_BAR = 1.4         -- the visible top bar, on top of the guard
local PILLAR = 2.4           -- support posts down to the plot floor
-- The posts stand on the GROUND floor, so their footprints are chosen to miss
-- everything already down there: 4 in from the deck's sides puts them at x=+-52,
-- outboard of the belt's leg 2 (which reaches x=-48.6) and clear of the upgrader
-- beams; 8 in from the deck's front edge drops them at z=-16, between upgrader
-- slots 2 and 3 at z=-26 and z=-10.
local PILLAR_INSET_SIDE = 4
local PILLAR_INSET_BACK = 4
local PILLAR_INSET_FRONT = 8
local PAD_SIZE = Vector3.new(9, 1, 9)
local PAD_GROUND_TOP = 1.1   -- its own Y: the claim pad tops out at 1.2, rebirth at 1.5
local PAD_STAND = 3.5        -- pivot height above the pad you land on
local PAD_COOLDOWN = 1.5

local COLORS = {
	deck   = Color3.fromRGB(138, 88, 58),
	frame  = Color3.fromRGB(118, 122, 130),
	rail   = Color3.fromRGB(255, 176, 60),
	padUp  = Color3.fromRGB(120, 200, 255),
	padDown = Color3.fromRGB(255, 190, 120),
}

-- one entry per plot: { folder, built }
local state: { [any]: any } = {}

-- Characters currently standing on a pad they were just delivered to. Weak
-- keys so a player who leaves mid-ride doesn't pin their character forever.
local arrivals: { [Model]: BasePart } = setmetatable({}, { __mode = "k" }) :: any
local lastRide: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- ─────────────────────────────────────────────────────────────────────────────
-- geometry
-- ─────────────────────────────────────────────────────────────────────────────

local function deckTopY(): number
	return FLOOR.height
end

--- The mezzanine's belt: three legs around the back and left of the deck, then
--- a return leg back across it to the hopper. Derived from the deck rectangle
--- and the pad position rather than written out as a second set of magic
--- coordinates, so it follows Config.Floors[1] if the deck is ever resized.
---
--- The return leg is what the shipped outboard heuristic could not do. Its
--- midpoint sits near the middle of the plot, so `normal:Dot(midpoint) < 0`
--- picks the wrong side and hangs the machines over the walkway. Signs are
--- explicit: every leg's outboard side faces out of the U.
local function deckPath(): (any, { number })
	local half = FLOOR.deckSize * 0.5
	local centre = FLOOR.deckAt

	local backZ = centre.Z - half.Z + BACK_MARGIN
	local frontZ = centre.Z + half.Z - FRONT_MARGIN
	local rightX = centre.X + half.X - SIDE_MARGIN
	local leftX = centre.X - half.X + SIDE_MARGIN
	local collectorX = FLOOR.padUp.X - PAD_CLEARANCE

	return {
		id = FLOOR.id,
		-- lifted off the deck: a belt base whose underside is coplanar with the
		-- deck's top face is two surfaces at one Y, which z-fights
		y = deckTopY() + DECK_LIFT,
		points = {
			Vector3.new(rightX, 0, backZ),
			Vector3.new(leftX, 0, backZ),
			Vector3.new(leftX, 0, frontZ),
			Vector3.new(collectorX - COLLECTOR_RUN, 0, frontZ),
		},
		collectorAt = Vector3.new(collectorX, 0, frontZ),
	}, { 1, 1, 1 }
end

--- The mezzanine's dropper. It mirrors the button that unlocked the floor, so
--- the upper floor rides the ground floor's balance instead of introducing a
--- second curve nobody has tuned — but at half the rate and twice the value,
--- for the same income out of half as many parts. Config.Economy.MaxDropsPerPlot
--- is a whole-plot budget and the modelled ground-floor peak already spends 58
--- of its 70.
---
--- SHOULD MOVE TO CONFIG: Config.Floors[1] has no dropper spec.
local function dropperDef(pathIndex: number)
	local unlock = Config.ButtonById[FLOOR.requires]
	return {
		id = "floor_" .. FLOOR.id,
		name = "Mezzanine Tung",
		kind = "Dropper",
		variant = (unlock and unlock.variant) or "classic",
		dropValue = ((unlock and unlock.dropValue) or 1) * 2,
		dropRate = ((unlock and unlock.dropRate) or 1.5) * 2,
		-- pins the machine to a leg of a specific floor's belt; see Tycoon:legOf
		legIndex = 1,
		legDistance = DROPPER_AT,
		pathIndex = pathIndex,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the deck
-- ─────────────────────────────────────────────────────────────────────────────

function FloorService.buildDeck(tycoon, folder: Instance)
	local size = FLOOR.deckSize
	local centre = FLOOR.deckAt
	local top = deckTopY()

	Tycoon.part(folder, "Deck", size,
		tycoon:at(centre.X, top - size.Y / 2, centre.Z), COLORS.deck, Enum.Material.WoodPlanks)

	-- Posts down to the plot floor. They overlap INTO the deck rather than
	-- meeting its underside, because a post whose top face is coplanar with the
	-- deck's bottom face z-fights from below.
	local postTop = top - size.Y / 2 + 0.6
	local postX = size.X / 2 - PILLAR_INSET_SIDE
	local postZ = { centre.Z - size.Z / 2 + PILLAR_INSET_BACK, centre.Z + size.Z / 2 - PILLAR_INSET_FRONT }
	for _, x in ipairs({ -1, 1 }) do
		for _, z in ipairs(postZ) do
			Tycoon.part(folder, "Post", Vector3.new(PILLAR, postTop, PILLAR),
				tycoon:at(centre.X + x * postX, postTop / 2, z),
				COLORS.frame, Enum.Material.Metal)
		end
	end

	-- Perimeter guard: an invisible collide-wall, because a solid 5-stud rail
	-- around the deck is a wall the camera has to fight. The visible part is a
	-- thin bar along the top of it, which reads as a railing and occludes
	-- nothing. Falling off is the obvious new failure mode of a floor.
	local height = FLOOR.railHeight
	local sides = {
		{ Vector3.new(size.X, height, RAIL_THICKNESS), Vector3.new(0, 0, -size.Z / 2 + RAIL_THICKNESS / 2) },
		{ Vector3.new(size.X, height, RAIL_THICKNESS), Vector3.new(0, 0, size.Z / 2 - RAIL_THICKNESS / 2) },
		{ Vector3.new(RAIL_THICKNESS, height, size.Z), Vector3.new(-size.X / 2 + RAIL_THICKNESS / 2, 0, 0) },
		{ Vector3.new(RAIL_THICKNESS, height, size.Z), Vector3.new(size.X / 2 - RAIL_THICKNESS / 2, 0, 0) },
	}
	for index, side in ipairs(sides) do
		local extent, offset = side[1], side[2]
		-- sunk 0.4 into the deck so its underside is inside solid geometry
		local guard = Tycoon.part(folder, "Guard" .. index, extent,
			tycoon:at(centre.X + offset.X, top + height / 2 - 0.4, centre.Z + offset.Z),
			Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
		guard.Transparency = 1
		guard.CanQuery = false
		guard.CastShadow = false

		-- The bars are shortened on the long sides so the four of them abut at
		-- the corners instead of overlapping: two coplanar top faces sharing a
		-- corner square is a z-fight you only notice from the deck itself.
		local barSize = Vector3.new(
			(index <= 2) and extent.X or RAIL_BAR,
			0.4,
			(index <= 2) and RAIL_BAR or (extent.Z - 2 * RAIL_BAR))
		-- and it sits just INSIDE the top of the guard, not flush with it
		local bar = Tycoon.part(folder, "Rail" .. index, barSize,
			tycoon:at(centre.X + offset.X, top + height - 0.7, centre.Z + offset.Z),
			COLORS.rail, Enum.Material.Neon, false)
		bar.CanQuery = false
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- teleport pads
-- ─────────────────────────────────────────────────────────────────────────────

local function humanoidsOn(pad: BasePart): { Model }
	-- Sweep the pad's volume instead of trusting the part that touched it.
	-- Teleporting only the toucher is the classic pad bug: it strands whoever
	-- walked in with them on the wrong floor.
	local volume = pad.Size + Vector3.new(0, 8, 0)
	local parts = workspace:GetPartBoundsInBox(pad.CFrame * CFrame.new(0, 4, 0), volume)

	local seen: { [Model]: boolean } = {}
	local found: { Model } = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and model.PrimaryPart and not seen[model] then
			seen[model] = true
			table.insert(found, model)
		end
	end
	return found
end

local function ride(pad: BasePart, destination: BasePart)
	local now = os.clock()
	for _, model in ipairs(humanoidsOn(pad)) do
		-- Don't bounce someone we just delivered here. The time window alone is
		-- not enough: a character resting on a part re-fires Touched off its own
		-- physics jitter, so the lock is only released when a sweep of the pad
		-- no longer finds them (see the TouchEnded handler).
		if arrivals[model] ~= pad and now - (lastRide[model] or 0) > PAD_COOLDOWN then
			lastRide[model] = now
			arrivals[model] = destination

			local pivot = model:GetPivot()
			local offset = pivot.Position - pad.Position
			local landing = destination.Position
				+ Vector3.new(offset.X, 0, offset.Z)
				+ Vector3.new(0, destination.Size.Y / 2 + PAD_STAND, 0)

			-- PivotTo overwrites the model's rotation outright, so the facing
			-- has to be baked into the target or everyone lands staring at
			-- world -Z regardless of which way they walked in.
			model:PivotTo(CFrame.new(landing) * (pivot - pivot.Position))
		end
	end
end

--- Both pads of a pair, wired to each other.
local function linkPads(a: BasePart, b: BasePart)
	for _, pair in ipairs({ { a, b }, { b, a } }) do
		local pad, destination = pair[1], pair[2]
		pad.Touched:Connect(function()
			ride(pad, destination)
		end)
		pad.TouchEnded:Connect(function()
			-- release the arrival lock once they have actually stepped off
			local standing: { [Model]: boolean } = {}
			for _, model in ipairs(humanoidsOn(pad)) do
				standing[model] = true
			end
			for model, held in pairs(arrivals) do
				if held == pad and not standing[model] then
					arrivals[model] = nil
				end
			end
		end)
	end
end

local function buildPad(tycoon, folder: Instance, name: string, at: Vector3, topY: number, color: Color3, text: string): BasePart
	local pad = Tycoon.part(folder, name, PAD_SIZE,
		tycoon:at(at.X, topY - PAD_SIZE.Y / 2, at.Z), color, Enum.Material.Neon)
	-- walk-over, not step-onto, exactly like the claim and rebirth pads
	pad.CanCollide = false

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = pad

	local billboard = Style.billboard(pad, {
		name = "Sign", width = 12, height = 4, distance = "prop", offset = 6,
	})
	Style.text(billboard, { text = text, color = color })

	return pad
end

function FloorService.buildPads(tycoon, folder: Instance)
	-- Config.Floors gives padDown and padUp the same X/Z, so which name means
	-- which cannot bite: the ground pad takes you up, the deck pad takes you
	-- down. They do not have to line up at all — the shipped elevators in this
	-- genre explicitly don't — but a pair that does reads as a lift shaft.
	local toDeck = buildPad(tycoon, folder, "PadToMezzanine", FLOOR.padDown, PAD_GROUND_TOP,
		COLORS.padUp, "▲ MEZZANINE")
	local toGround = buildPad(tycoon, folder, "PadToGround", FLOOR.padUp,
		deckTopY() + DECK_LIFT + PAD_SIZE.Y, COLORS.padDown, "▼ GROUND FLOOR")
	linkPads(toDeck, toGround)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

local function stateFor(tycoon)
	local entry = state[tycoon]
	if entry then
		return entry
	end

	local folder = Instance.new("Folder")
	folder.Name = "Floors"
	folder.Parent = tycoon.model
	-- so a released plot doesn't leave a deck hanging over a bare claim pad
	tycoon:registerFactoryFolder(folder)

	entry = { folder = folder, built = false }
	state[tycoon] = entry
	return entry
end

function FloorService.build(tycoon)
	local entry = stateFor(tycoon)
	entry.folder:ClearAllChildren()

	FloorService.buildDeck(tycoon, entry.folder)

	local def, outboard = deckPath()
	local pathIndex = tycoon:addBeltPath(def, outboard)
	tycoon:buildBelt(pathIndex, entry.folder)
	tycoon:buildCollector(pathIndex, entry.folder, false)

	local dropper = dropperDef(pathIndex)
	local model, nozzle, legIndex = tycoon:buildDropperMachine(dropper, entry.folder)
	tycoon:startDropLoop(dropper, model, nozzle, legIndex, pathIndex)

	FloorService.buildPads(tycoon, entry.folder)
	entry.built = true
end

function FloorService.teardown(tycoon)
	local entry = state[tycoon]
	if not entry then
		return
	end
	-- Clearing the folder ends the floor's drop loop on its own: the loop polls
	-- its own model's Parent. The belt PATH stays registered — it is pure maths
	-- and addBeltPath is idempotent by id, so a rebuild rebuilds parts rather
	-- than stacking a second path onto the plot.
	entry.folder:ClearAllChildren()
	entry.built = false
end

--- Builds or tears down a plot's floors to match what it owns right now.
function FloorService.sync(tycoon)
	local unlocked = tycoon.owner ~= nil and tycoon.owned[FLOOR.requires] == true
	local entry = state[tycoon]
	local built = entry ~= nil and entry.built

	if unlocked and not built then
		FloorService.build(tycoon)
	elseif built and not unlocked then
		FloorService.teardown(tycoon)
	end
end

function FloorService.start()
	if not Config.Prototypes.Floors then
		return
	end
	if not FLOOR then
		warn("[Tung] Prototypes.Floors is on but Config.Floors is empty")
		return
	end
	if not Config.ButtonById[FLOOR.requires] then
		warn("[Tung] floor " .. tostring(FLOOR.id) .. " requires an unknown button: " .. tostring(FLOOR.requires))
		return
	end

	for _, tycoon in ipairs(Tycoon.all()) do
		tycoon:onOwnedChanged(FloorService.sync)
		FloorService.sync(tycoon)
	end
end

return FloorService
