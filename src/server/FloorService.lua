--[[
	FloorService.lua — the second storey.

	A mezzanine deck over the BACK half of the plot, with its own belt and
	collector and a ladder up to it. It appears when the plot buys
	Config.Floors[1].button, which now sits just after the walls, near the
	start of the factory track.

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

	  A LADDER, NOT A LIFT AND NO LONGER PADS. TweenService platforms jitter
	  and slide players off, so this was a teleport pair — but that cost a
	  cooldown, an arrival lock and a TouchEnded sweep to stop a character
	  resting on a pad bouncing off its own physics jitter, and the two ends
	  could not be made to line up. Roblox humanoids climb a TrussPart natively
	  in both directions, for no code at all.

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
-- the hopper's own position, not its outboard count. Two of those were wrong.

local COLORS = {
	deck   = Color3.fromRGB(138, 88, 58),
	frame  = Color3.fromRGB(118, 122, 130),
	rail   = Color3.fromRGB(255, 176, 60),
}

-- one entry per plot: { folder, built }
local state: { [any]: any } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- geometry
-- ─────────────────────────────────────────────────────────────────────────────

local function deckTopY(): number
	return FLOOR.height
end

--- The mezzanine's belt. Config.floorBeltPath derives it from the deck
--- rectangle and the stated hopper position, and Config.BeltPaths carries the
--- result — so
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
	-- THE FRONT RUN IS CUT IN TWO, because the ladder arrives at it. A guard
	-- that closes the whole front edge is a ladder to nowhere: you climb 22
	-- studs and hit an invisible wall you cannot see to understand.
	--
	-- The gap is centred on the ladder and both pieces are sized from it, so
	-- moving Floors.ladder.at moves the opening with it rather than leaving a
	-- hole somewhere else. The verifier asserts the two agree.
	local gateHalf = FLOOR.ladder.gate / 2
	local frontZ = size.Z / 2 - FLOOR.rail.thickness / 2
	local gapLeft = FLOOR.ladder.at.X - centre.X - gateHalf     -- deck-local
	local gapRight = FLOOR.ladder.at.X - centre.X + gateHalf
	local leftRun = gapLeft + size.X / 2
	local rightRun = size.X / 2 - gapRight
	local sides = {
		{ Vector3.new(size.X, height, FLOOR.rail.thickness), Vector3.new(0, 0, -size.Z / 2 + FLOOR.rail.thickness / 2) },
		{ Vector3.new(leftRun, height, FLOOR.rail.thickness), Vector3.new(gapLeft - leftRun / 2, 0, frontZ) },
		{ Vector3.new(FLOOR.rail.thickness, height, size.Z), Vector3.new(-size.X / 2 + FLOOR.rail.thickness / 2, 0, 0) },
		{ Vector3.new(FLOOR.rail.thickness, height, size.Z), Vector3.new(size.X / 2 - FLOOR.rail.thickness / 2, 0, 0) },
		{ Vector3.new(rightRun, height, FLOOR.rail.thickness), Vector3.new(gapRight + rightRun / 2, 0, frontZ) },
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

		-- The bars are shortened on the side runs so they abut at the corners
		-- instead of overlapping: two coplanar top faces sharing a corner
		-- square is a z-fight you only notice from the deck itself.
		--
		-- Keyed off the run's own SHAPE rather than its index. It used to read
		-- `index <= 2`, which was true only while the front edge was one piece
		-- and the list was exactly four long; cutting the front in two put a
		-- fifth entry on the end and an index test would have drawn that half
		-- of the railing as a short side, across the deck instead of along it.
		local alongX = extent.X > extent.Z
		local barSize = Vector3.new(
			alongX and extent.X or FLOOR.rail.bar,
			0.4,
			alongX and FLOOR.rail.bar or (extent.Z - 2 * FLOOR.rail.bar))
		-- and it sits just INSIDE the top of the guard, not flush with it
		local bar = Tycoon.part(folder, "Rail" .. index, barSize,
			tycoon:at(centre.X + offset.X, top + height - 0.7, centre.Z + offset.Z),
			COLORS.rail, Enum.Material.Neon, false)
		bar.CanQuery = false
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the ladder
-- ─────────────────────────────────────────────────────────────────────────────

--- The climb up to the deck, and back down it.
---
--- A TrussPart and nothing else. Roblox humanoids enter the Climbing state on
--- contact with truss geometry, in both directions, with no script — which is
--- why this replaced about a hundred lines of teleport pad, arrival lock and
--- TouchEnded sweep that existed to stop a character resting on a pad from
--- bouncing off its own physics jitter.
---
--- Deliberately NOT built through Tycoon.part: that helper makes a Part, and a
--- Part is not climbable however it is coloured.
function FloorService.buildLadder(tycoon, folder: Instance)
	local ladder = FLOOR.ladder
	local height = deckTopY() + ladder.rise

	local truss = Instance.new("TrussPart")
	truss.Name = "Ladder"
	-- A truss takes its length from Y and is 2x2 in section. CanCollide must
	-- stay TRUE: climbing is a collision response, so a non-colliding truss is
	-- scenery you walk through.
	truss.Size = Vector3.new(ladder.width, height, ladder.width)
	truss.CFrame = tycoon:at(ladder.at.X, height / 2, ladder.at.Z)
	truss.Anchored = true
	truss.Color = COLORS.frame
	truss.Material = Enum.Material.Metal
	truss.Parent = folder

	local billboard = Style.billboard(truss, {
		name = "Sign", width = 12, height = 4, distance = "prop", offset = height / 2 + 3,
	})
	Style.text(billboard, { text = "▲ MEZZANINE", color = COLORS.rail })

	return truss
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

	FloorService.buildLadder(tycoon, entry.folder)
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
