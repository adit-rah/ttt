--[[
	FloorService.lua — the second storey.

	A mezzanine deck over the BACK half of the plot, with its own belt and
	collector and a pair of teleport pads. It appears when the plot buys
	Config.Floors[1].button, which sits at roughly the halfway point of the
	factory track.

	NO LONGER A PROTOTYPE. It was gated on Config.Prototypes.Floors, and the
	verifier asserts every prototype flag ships false — so graduating it meant
	deleting the flag rather than flipping it. It also used to appear for FREE
	the moment you owned dropper10, the last button of the ground floor, about
	eighty minutes in. "You buy floor 2 before you get anywhere near finishing
	floor 1" is the most complained-about thing in multi-floor tycoons, but the
	answer to it is not "put it where nobody will ever see it".

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

-- All of this used to be file-local constants under two SHOULD MOVE TO CONFIG
-- comments. It is in Config now, and the reason is not tidiness: deckPath()
-- built the mezzanine's belt in CODE, so none of the belt-path assertions ever
-- saw it — not that its legs stay on the deck, not that its collector clears
-- the teleport pad, not its outboard count. Two of those were wrong.

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

--- The mezzanine's belt. Config.floorBeltPath derives it from the deck
--- rectangle and the pad position, and Config.BeltPaths carries the result — so
--- the belt assertions cover it exactly as they cover the ground floor's, with
--- no new code on their side.
local function deckPath()
	return Config.floorBeltPath(FLOOR), FLOOR.belt.outboard
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
	local postX = size.X / 2 - FLOOR.pillar.insetSide
	local postZ = { centre.Z - size.Z / 2 + FLOOR.pillar.insetBack, centre.Z + size.Z / 2 - FLOOR.pillar.insetFront }
	for _, x in ipairs({ -1, 1 }) do
		for _, z in ipairs(postZ) do
			Tycoon.part(folder, "Post", Vector3.new(FLOOR.pillar.size, postTop, FLOOR.pillar.size),
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
		{ Vector3.new(size.X, height, FLOOR.rail.thickness), Vector3.new(0, 0, -size.Z / 2 + FLOOR.rail.thickness / 2) },
		{ Vector3.new(size.X, height, FLOOR.rail.thickness), Vector3.new(0, 0, size.Z / 2 - FLOOR.rail.thickness / 2) },
		{ Vector3.new(FLOOR.rail.thickness, height, size.Z), Vector3.new(-size.X / 2 + FLOOR.rail.thickness / 2, 0, 0) },
		{ Vector3.new(FLOOR.rail.thickness, height, size.Z), Vector3.new(size.X / 2 - FLOOR.rail.thickness / 2, 0, 0) },
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
			(index <= 2) and extent.X or FLOOR.rail.bar,
			0.4,
			(index <= 2) and FLOOR.rail.bar or (extent.Z - 2 * FLOOR.rail.bar))
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
		if arrivals[model] ~= pad and now - (lastRide[model] or 0) > FLOOR.pads.cooldown then
			lastRide[model] = now
			arrivals[model] = destination

			local pivot = model:GetPivot()
			local offset = pivot.Position - pad.Position
			local landing = destination.Position
				+ Vector3.new(offset.X, 0, offset.Z)
				+ Vector3.new(0, destination.Size.Y / 2 + FLOOR.pads.stand, 0)

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
	local pad = Tycoon.part(folder, name, FLOOR.pads.size,
		tycoon:at(at.X, topY - FLOOR.pads.size.Y / 2, at.Z), color, Enum.Material.Neon)
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
	local toDeck = buildPad(tycoon, folder, "PadToMezzanine", FLOOR.pads.down, FLOOR.pads.groundTop,
		COLORS.padUp, "▲ MEZZANINE")
	local toGround = buildPad(tycoon, folder, "PadToGround", FLOOR.pads.up,
		deckTopY() + FLOOR.deckLift + FLOOR.pads.size.Y, COLORS.padDown, "▼ GROUND FLOOR")
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

	-- addBeltPath is idempotent by id and Tycoon.new already registered every
	-- path in Config.BeltPaths, so this resolves rather than adds. It has to:
	-- the mezzanine's buy buttons were built on first claim, and they took
	-- their height from this path existing.
	local def, outboard = deckPath()
	local pathIndex = tycoon:addBeltPath(def, outboard)
	tycoon:buildBelt(pathIndex, entry.folder)
	tycoon:buildCollector(pathIndex, entry.folder, false)

	-- NO DROPPER HERE ANY MORE. It used to be synthesised in this file and
	-- installed straight through buildDropperMachine/startDropLoop, bypassing
	-- Tycoon:install — which is why it appeared in neither Config.ButtonById
	-- nor `owned`, and why every income readout in the game under-reported a
	-- plot that had one. It is Config.FactoryButtons.mezz_dropper1 now, an
	-- ordinary Dropper row pinned to this path, installed like everything else.

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
---
--- Driven off ownedChanged rather than from the Floor button's installer,
--- because the deck outlives the button: a release, a rebirth and a re-claim
--- all have to rebuild or drop it and none of them go through install().
function FloorService.sync(tycoon)
	local unlocked = tycoon.owner ~= nil and tycoon.owned[FLOOR.button] == true
	local entry = state[tycoon]
	local built = entry ~= nil and entry.built

	if unlocked and not built then
		FloorService.build(tycoon)
		-- The roof was shaped for a plot with no floor in it. Reshape it now,
		-- or the deck grows through it.
		tycoon:refreshRoof()
	elseif built and not unlocked then
		FloorService.teardown(tycoon)
		tycoon:refreshRoof()
	end
end

function FloorService.start()
	if not FLOOR then
		return
	end
	local button = Config.ButtonById[FLOOR.button]
	if not button then
		warn("[Tung] floor " .. tostring(FLOOR.id) .. " is built by an unknown button: " .. tostring(FLOOR.button))
		return
	end

	for _, tycoon in ipairs(Tycoon.all()) do
		tycoon:onOwnedChanged(FloorService.sync)
		FloorService.sync(tycoon)
	end
end

return FloorService
