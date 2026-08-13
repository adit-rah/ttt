--[[
	FloorService.lua — the second storey: a whole storey, not a shelf.

	It appears when the plot buys Config.Floors[1].button, which sits just after
	the walls, near the start of the factory track.

	WHAT IS UP THERE, AND WHO BUILDS EACH PIECE. Config.Floors[1] states the
	storey as a deck rectangle, two named zones and a stairwell, and that is the
	map — you should not have to read this file to find out what is on the floor:

	  zones.line     the belt, its dropper and its hopper          THIS FILE,
	                 — but only once Floors[1].lineButton is bought  on its own beat
	  zones.landing  the stairwell, its guard, the open floor you
	                 arrive on, and the pedestal that buys the line THIS FILE,
	                                                               tycoon/Buttons
	                 (the armoury USED to be here. Round 8 took
	                 both cabinets back to the ground floor —
	                 Layout.Tracks no longer names a `floor` — so
	                 this half of the storey is deliberately empty)
	  hatch          the void the ladder climbs through, and the
	                 railing round three sides of it                THIS FILE
	  the shell      the upper storey's own walls and the roof
	                 above them                                    THIS FILE calls
	                                                               Tycoon:buildStoreyWalls
	                                                               and :refreshRoof

	Four decisions that look arbitrary and are not:

	  IT SPANS THE PLOT, WITH A VOID FOR THE CLIMB. This file used to argue the
	  other way, and the argument was good: the deck covered the BACK half so the
	  aisle stayed open to the sky, because Roblox has no good answer for a
	  ceiling (opaque snaps the camera to head height, transparent lets it pop
	  through, and LocalTransparencyModifier is overwritten by the default camera
	  scripts every frame). TODO.md item 1 overturns it deliberately: a half deck
	  is half a storey, and there was nowhere on it to put an armoury. The cost is
	  named in Config.Floors[1]'s own comment along with the levers if it plays
	  badly — the ground storey keeps 20.4 studs of headroom, PopperCam sits under
	  it, and the walls are glazed. The slab is therefore built in PIECES around
	  Config.Floors[1].hatch rather than as one box.

	  A LADDER, NOT A LIFT AND NO LONGER PADS. TweenService platforms jitter
	  and slide players off, so this was a teleport pair — but that cost a
	  cooldown, an arrival lock and a TouchEnded sweep to stop a character
	  resting on a pad bouncing off its own physics jitter, and the two ends
	  could not be made to line up. Roblox humanoids climb a TrussPart natively
	  in both directions, for no code at all.

	  ITS OWN LOOP. Each floor runs an independent dropper -> belt -> collector.
	  Cross-floor transport is the trap — upward conveyors need velocity >= 25
	  and still stick.

	  THE UPPER STOREY'S WALLS ARE BUILT FROM HERE, not from the Structure
	  installer that builds the ground ring. The long version is in build().
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Tycoon = Req("Tycoon")
local TweenService = game:GetService("TweenService")

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

--- The mezzanine's belt. Config.floorBeltPath derives it from the LINE ZONE and
--- the stated hopper position, and Config.BeltPaths carries the result — so the
--- belt assertions cover it exactly as they cover the ground floor's, with no new
--- code on their side.
---
--- The zone is the old deck rectangle to the stud, which is what let the deck grow
--- to span the plot without moving a single leg, machine or collector. Derived
--- from the DECK it would have spread itself across the whole storey the moment
--- the deck did, and taken the drop budget and the trigger dwell with it.
local function deckPath()
	return Config.floorBeltPath(FLOOR), FLOOR.belt.outboard
end

--- The storey this deck IS, as a Config.Structure.Storeys id.
---
--- MATCHED, NOT TYPED. "upper" written here would be a second name for
--- Storeys[2], and the thing that actually ties the two together is the height:
--- Storeys[2].floorY is Config.Floors[1].height, from that field. Match on it and
--- a third storey needs no edit here.
local function storeyId(): string?
	for _, storey in ipairs(Config.Structure.Storeys) do
		if storey.floorY == FLOOR.height then
			return storey.id
		end
	end
	return nil
end

--- THE SLAB, AS THE RECTANGLES LEFT WHEN THE STAIRWELL IS TAKEN OUT OF IT.
---
--- The deck spans the plot, so the climb comes up THROUGH it: two full-width bands
--- behind and in front of the hatch, then two short runs beside it. Four pieces
--- for today's numbers, but the count is a CONSEQUENCE of the two rectangles and
--- not a decision — a hatch flush to an edge yields three and a floor with no
--- hatch would yield one. Four hand-listed boxes would be four numbers that stop
--- agreeing with Config.Floors[n].hatch the first time it moves, and the symptom
--- is a hole in the floor somewhere else.
---
--- Stated as spans rather than centres, because from-where-to-where is how both
--- rectangles are written and halving the same extent twice is where a sign error
--- hides.
local function deckPieces()
	local size, at, hatch = FLOOR.deckSize, FLOOR.deckAt, FLOOR.hatch
	local x0, x1 = at.X - size.X / 2, at.X + size.X / 2
	local z0, z1 = at.Z - size.Z / 2, at.Z + size.Z / 2
	local hx0, hx1 = hatch.at.X - hatch.size.X / 2, hatch.at.X + hatch.size.X / 2
	local hz0, hz1 = hatch.at.Z - hatch.size.Z / 2, hatch.at.Z + hatch.size.Z / 2

	local pieces = {}
	for _, span in ipairs({
		{ "Back", x0, x1, z0, hz0 },
		{ "Front", x0, x1, hz1, z1 },
		{ "Left", x0, hx0, hz0, hz1 },
		{ "Right", hx1, x1, hz0, hz1 },
	}) do
		local name, fromX, toX, fromZ, toZ = span[1], span[2], span[3], span[4], span[5]
		-- A piece the two rectangles leave empty is DROPPED, not clamped up to
		-- MIN_PART: a hatch against the deck's own edge should leave three slabs,
		-- not three slabs and a sliver with two visible joins in it.
		if toX - fromX > Tycoon.MIN_PART and toZ - fromZ > Tycoon.MIN_PART then
			table.insert(pieces, {
				name = name,
				size = Vector3.new(toX - fromX, size.Y, toZ - fromZ),
				x = (fromX + toX) / 2,
				z = (fromZ + toZ) / 2,
			})
		end
	end
	return pieces
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the deck
-- ─────────────────────────────────────────────────────────────────────────────

--- ONE RUN OF GUARD: an invisible collide-wall with a thin neon bar along the top
--- of it. A solid 5-stud rail is a wall the camera has to fight; a railing you can
--- see through is a railing. Falling off — or now into the stairwell — is the
--- obvious new failure mode of a floor.
---
--- Extracted because there are TWO callers now, and they used to be one hand-built
--- list of five: the deck's own edges, only where they do not close against a
--- wall, and the three closed sides of the hatch.
local function guardRun(tycoon, folder: Instance, name: string, extent: Vector3, x: number, z: number)
	local top = deckTopY()
	-- sunk 0.4 into the deck so its underside is inside solid geometry
	local guard = Tycoon.part(folder, "Guard" .. name, extent,
		tycoon:at(x, top + extent.Y / 2 - 0.4, z),
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	guard.Transparency = 1
	guard.CanQuery = false
	guard.CastShadow = false

	-- The bars are shortened on the cross runs so they abut at the corners instead
	-- of overlapping: two coplanar top faces sharing a corner square is a z-fight
	-- you only notice from the deck itself.
	--
	-- Keyed off the run's own SHAPE rather than any index. It used to read
	-- `index <= 2`, which was true only while the front edge was one piece and the
	-- list was exactly four long; every later change to that list — cutting the
	-- front in two, and now replacing the whole perimeter with a hatch railing —
	-- would have drawn some run across the deck instead of along it.
	local alongX = extent.X > extent.Z
	local barSize = Vector3.new(
		alongX and extent.X or FLOOR.rail.bar,
		0.4,
		alongX and FLOOR.rail.bar or math.max(extent.Z - 2 * FLOOR.rail.bar, Tycoon.MIN_PART))
	-- and it sits just INSIDE the top of the guard, not flush with it
	local bar = Tycoon.part(folder, "Rail" .. name, barSize,
		tycoon:at(x, top + extent.Y - 0.7, z), COLORS.rail, Enum.Material.Neon, false)
	bar.CanQuery = false
end

--- The deck's own edges — where they do not close against a wall.
---
--- THE PERIMETER GUARD IS ALL BUT GONE, and that is the deck spanning the plot
--- rather than a decision to take a railing away: the slab now meets the INNER
--- FACE of the wall ring on all four sides, and what stops you walking off the
--- edge is the upper storey's wall (built in build(), below). A five-stud
--- collide-wall an inch inside a real wall is two solid surfaces to say one thing.
---
--- So it is derived, per side, from how far short of that face the deck stops —
--- which is zero on all four sides today, and this builds nothing. A deck that is
--- ever pulled back in gets its railing back with no edit here, which is the half
--- of this that is worth the twenty lines.
local function buildEdgeGuards(tycoon, folder: Instance)
	local size, at = FLOOR.deckSize, FLOOR.deckAt
	local thickness = FLOOR.rail.thickness
	for _, side in ipairs(Config.Structure.Sides) do
		local extent = Config.wallExtent(side)
		-- the wall's INNER face, not the centre plane the extent names
		local inner = extent.fixed - extent.outward * Config.Structure.WallThickness / 2
		local alongX = extent.axis == "X"
		local edge = alongX
			and (at.Z + extent.outward * size.Z / 2)
			or (at.X + extent.outward * size.X / 2)
		if extent.outward * (inner - edge) > Tycoon.MIN_PART then
			-- inset half a thickness so the run stands ON the slab rather than
			-- straddling the edge it guards
			local seat = edge - extent.outward * thickness / 2
			local run = alongX
				and Vector3.new(size.X, FLOOR.railHeight, thickness)
				or Vector3.new(thickness, FLOOR.railHeight, size.Z)
			guardRun(tycoon, folder, "Edge" .. side, run,
				alongX and at.X or seat, alongX and seat or at.Z)
		end
	end
end

--- The stairwell's railing: three sides closed, the fourth cut for the arrival.
---
--- The perimeter's front run used to be cut in two around a ladder standing in
--- FRONT of the deck's edge, because a guard that closes the whole edge is a
--- ladder to nowhere: you climb twenty-two studs into an invisible wall you cannot
--- see to understand. The climb comes up through the slab now, so the same idiom
--- moved to the hole — `ladder.gate` wide, centred on the void, jambs either side
--- of it. REUSED rather than reinvented: one number for "how wide is the way onto
--- this floor", and the verifier already holds it to at least the ladder's own
--- width plus two.
---
--- WHICH SIDE IS OPEN is the +Z one, toward the armoury zone and in line with the
--- gateway you walk in through. The ladder hugs that same lip, for the reason in
--- buildLadder.
local function buildHatchGuards(tycoon, folder: Instance)
	local hatch = FLOOR.hatch
	local thickness, height = FLOOR.rail.thickness, FLOOR.railHeight
	local halfX, halfZ = hatch.size.X / 2, hatch.size.Z / 2

	-- The closed sides sit just OUTSIDE the void, on solid slab. The far run is
	-- lengthened by a thickness at each end so the three of them meet at the
	-- corners instead of leaving two notches a foot fits through.
	local runs = {
		{ "HatchFar", Vector3.new(hatch.size.X + 2 * thickness, height, thickness),
			hatch.at.X, hatch.at.Z - halfZ - thickness / 2 },
		{ "HatchLeft", Vector3.new(thickness, height, hatch.size.Z),
			hatch.at.X - halfX - thickness / 2, hatch.at.Z },
		{ "HatchRight", Vector3.new(thickness, height, hatch.size.Z),
			hatch.at.X + halfX + thickness / 2, hatch.at.Z },
	}

	-- The arrival side, minus the gate. Whatever the hatch is wider than the gate
	-- becomes a jamb at each end; a hatch no wider than its own opening leaves the
	-- side entirely open and builds neither.
	local jamb = (hatch.size.X - FLOOR.ladder.gate) / 2
	if jamb > Tycoon.MIN_PART then
		for _, sign in ipairs({ -1, 1 }) do
			table.insert(runs, {
				sign < 0 and "HatchJambLeft" or "HatchJambRight",
				Vector3.new(jamb, height, thickness),
				hatch.at.X + sign * (FLOOR.ladder.gate + jamb) / 2,
				hatch.at.Z + halfZ + thickness / 2,
			})
		end
	end

	for _, run in ipairs(runs) do
		guardRun(tycoon, folder, run[1], run[2], run[3], run[4])
	end
end

function FloorService.buildDeck(tycoon, folder: Instance)
	local size = FLOOR.deckSize
	local centre = FLOOR.deckAt
	local top = deckTopY()

	for _, piece in ipairs(deckPieces()) do
		Tycoon.part(folder, "Deck" .. piece.name, piece.size,
			tycoon:at(piece.x, top - size.Y / 2, piece.z), COLORS.deck, Enum.Material.WoodPlanks)
	end

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

	-- THE RAILINGS. Two calls, both derived: whatever edge of the deck does not
	-- close against a wall, and three sides of the stairwell.
	buildEdgeGuards(tycoon, folder)
	buildHatchGuards(tycoon, folder)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the ladder
-- ─────────────────────────────────────────────────────────────────────────────

--- WHERE THE TRUSS STANDS: inside the hatch, against its ARRIVAL lip.
---
--- Derived from the void it climbs through rather than stated beside it, so the
--- truss and the hole in the floor cannot disagree about where the climb is.
---
--- Against the lip, not in the middle. At the top of a truss you step off
--- HORIZONTALLY onto whatever is there: from the centre of a ten-stud void that is
--- four studs of nothing, and from the far lip the whole hole is between you and
--- the floor you came to reach. Hugging the arrival lip you climb the void side of
--- it and step forward through the gap in the guard onto the slab, and the same
--- move in reverse drops you back into the void rather than onto the truss.
---
--- CONFIG OWNS THIS SPOT, and it briefly did not. `Floors[1].ladder.at` said
--- z = -6.6 — the old design's "just proud of the deck's front edge" — while this
--- file derived z = -8 from the hatch. Two answers, and the one the VERIFIER
--- measured was the one nothing built: every ladder clearance check was holding a
--- phantom box against furniture it was nowhere near. `ladder.at` is deleted and
--- Config.floorLadderAt is the single derivation both sides read.
local function ladderSpot(): (number, number)
	local at = Config.floorLadderAt(FLOOR)
	return at.X, at.Z
end

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
	local x, z = ladderSpot()

	local truss = Instance.new("TrussPart")
	truss.Name = "Ladder"
	-- A truss takes its length from Y and is 2x2 in section. CanCollide must
	-- stay TRUE: climbing is a collision response, so a non-colliding truss is
	-- scenery you walk through.
	--
	-- IT RUNS THE WHOLE WAY, plot floor to `rise` above the deck, through the void
	-- rather than up to the underside of a slab: one part, climbable in both
	-- directions, with nothing to line up at the join.
	truss.Size = Vector3.new(ladder.width, height, ladder.width)
	truss.CFrame = tycoon:at(x, height / 2, z)
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

	entry = { folder = folder, built = false, lineBuilt = false, generation = 0, tweens = {} }
	state[tycoon] = entry
	return entry
end

--- Send every part built during `fn` up to its starting pose, and tween it back
--- down over `stage`'s window.
---
--- WHY THE BUILDERS ARE UNTOUCHED. Staging by wrapping rather than by teaching
--- five builders about animation keeps the geometry in one place: buildDeck
--- still emits a slab where a slab goes, and this moves the finished part and
--- puts it back. A builder that knew about tweens would be a builder the
--- verifier's geometry checks are one step further from.
---
--- `generation` is checked on every resume. A build takes six seconds and
--- onOwnedChanged fires on purchase, release, rebirth AND re-claim, so a
--- teardown can and will land in the middle of one — and the folder those parts
--- are in has been cleared by then. Cancel-then-clear, and a stale stage returns
--- rather than writing to a destroyed instance.
local function raiseStage(entry, generation, stage, fn)
	local before = {}
	for _, existing in ipairs(entry.folder:GetDescendants()) do
		before[existing] = true
	end

	fn()

	local fresh = {}
	for _, part in ipairs(entry.folder:GetDescendants()) do
		if not before[part] and part:IsA("BasePart") then
			table.insert(fresh, part)
		end
	end
	if #fresh == 0 then
		return
	end

	local RAISE = FLOOR.raise
	for index, part in ipairs(fresh) do
		local resting = part.CFrame
		local collide, transparency = part.CanCollide, part.Transparency
		part.CanCollide = false
		part.Transparency = math.max(transparency, RAISE.fade)
		part.CFrame = resting + Vector3.new(0, RAISE.lift, 0)

		local delay = stage.at + (index - 1) * stage.stagger
		task.delay(delay, function()
			if entry.generation ~= generation or part.Parent == nil then
				return
			end
			local tween = TweenService:Create(part,
				TweenInfo.new(stage.time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ CFrame = resting, Transparency = transparency })
			table.insert(entry.tweens, tween)
			tween.Completed:Connect(function()
				if entry.generation == generation and part.Parent ~= nil then
					part.CanCollide = collide
				end
			end)
			tween:Play()
		end)
	end
end

--- Stop whatever is mid-flight and forget it. Cancel BEFORE clearing:
--- TweenService writes a property on the next frame regardless, and writing to a
--- destroyed instance throws.
local function halt(entry)
	entry.generation = (entry.generation or 0) + 1
	for _, tween in ipairs(entry.tweens or {}) do
		pcall(function()
			tween:Cancel()
		end)
	end
	entry.tweens = {}
end

--- One stage of the raise, by id.
local function stageNamed(id: string)
	for _, stage in ipairs(FLOOR.raise.stages) do
		if stage.id == id then
			return stage
		end
	end
	error(("[Tung] FloorService: no raise stage named %q in Config.Floors"):format(id), 2)
end

function FloorService.build(tycoon, animate: boolean?)
	local entry = stateFor(tycoon)
	halt(entry)
	entry.folder:ClearAllChildren()
	local generation = entry.generation

	-- A REBUILD IS NOT A PURCHASE. sync() runs on release, rebirth and re-claim
	-- as well, and a player walking back onto a plot they already own should not
	-- watch six seconds of construction before they can climb their own stairs.
	-- The animation is a reward for buying the thing, so only the purchase gets
	-- it; everything else builds in one frame exactly as before.
	local stage = animate and stageNamed or function()
		return { at = 0, time = 0, stagger = 0 }
	end
	local raise = animate and raiseStage or function(_, _, _, fn)
		fn()
	end

	raise(entry, generation, stage("deck"), function()
		FloorService.buildDeck(tycoon, entry.folder)
	end)

	-- THE UPPER STOREY'S WALLS, AND WHY THEY ARE OURS RATHER THAN THE STRUCTURE
	-- INSTALLER'S.
	--
	-- They are structure, and INSTALLERS.Structure builds the ground ring from this
	-- same call. But the ring that stands on THIS deck cannot come from there: the
	-- walls button is bought around minute three and this floor around minute six,
	-- so at walls-install time there is no deck to stand an upper wall on, and
	-- nothing re-runs an installer. That is exactly the hole the ROOF had to grow
	-- refreshRoof to cover, and giving the walls the same treatment would mean
	-- rebuilding the ground ring to add a storey above it — destroying the gate
	-- leaves GateService may be mid-tween on and re-emitting sixty parts that have
	-- not changed.
	--
	-- Here it costs nothing. The deck's existence is already driven off
	-- onOwnedChanged, the one signal that fires on purchase, release, rebirth AND
	-- re-claim, and these parts go in the deck's own folder — so the storey arrives
	-- and leaves as one object and there is no state in which a deck has no walls
	-- or a wall has no deck. The alternative, parenting them into self.machines,
	-- would split one storey across two folders with two different clearing rules.
	--
	-- ONE CAVEAT, WRITTEN DOWN BECAUSE IT IS INVISIBLE. GateService resolves a gate
	-- leaf with `tycoon.machines:FindFirstChild(name, true)`, and this model is not
	-- in machines. Config.Structure.Openings declares no upper-storey opening, so
	-- buildStoreyWalls emits no leaf here and nothing is unhooked today; the day one
	-- is declared, that lookup has to widen to the plot model.
	local storey = storeyId()
	if storey then
		raise(entry, generation, stage("walls"), function()
			tycoon:buildStoreyWalls(entry.folder, storey)
		end)
	else
		warn(("[Tung] floor %s has no Config.Structure.Storeys entry at y=%s, so it gets no walls")
			:format(tostring(FLOOR.id), tostring(FLOOR.height)))
	end

	-- NO BELT HERE ANY MORE, AND NO DROPPER. TODO.md item 4: the storey arrives
	-- barren. What `floor2` buys is the deck, its guards, the wall ring above it
	-- and the ladder up — somewhere to stand. The conveyor, its corner sensors
	-- and the hopper it ends in are FloorService.buildLine below, keyed on
	-- Floors[n].lineButton, and the machines on it are ordinary Dropper rows
	-- pinned to its path.
	--
	-- (The dropper stopped being built here for a different reason two rounds
	-- ago: it was synthesised in this file and installed straight through
	-- buildDropperMachine/startDropLoop, bypassing Tycoon:install, so it
	-- appeared in neither Config.ButtonById nor `owned` and every income readout
	-- under-reported a plot that had one.)

	raise(entry, generation, stage("ladder"), function()
		FloorService.buildLadder(tycoon, entry.folder)
	end)
	entry.built = true
end

--- The conveyor on the deck, and the hopper it ends in.
---
--- ITS OWN FOLDER, INSIDE THE DECK'S. Nested rather than beside it so that
--- tearing the storey down takes the line with it — there is no state in which
--- a plot has a conveyor and no floor under it — while the line can still be
--- torn down on its own, which is what a rebirth that keeps the deck would need.
function FloorService.buildLine(tycoon)
	local entry = stateFor(tycoon)
	local folder = entry.folder:FindFirstChild("Line")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Line"
		folder.Parent = entry.folder
	end
	folder:ClearAllChildren()

	-- addBeltPath is idempotent by id and Tycoon.new already registered every
	-- path in Config.BeltPaths, so this resolves rather than adds. It has to:
	-- the mezzanine's buy buttons were built on first claim, and they took
	-- their height from this path existing.
	local def, outboard = deckPath()
	local pathIndex = tycoon:addBeltPath(def, outboard)
	tycoon:buildBelt(pathIndex, folder)
	tycoon:buildCollector(pathIndex, folder, false)
	entry.lineBuilt = true
end

function FloorService.teardownLine(tycoon)
	local entry = state[tycoon]
	if not entry then
		return
	end
	local folder = entry.folder:FindFirstChild("Line")
	if folder then
		folder:ClearAllChildren()
	end
	entry.lineBuilt = false
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
	halt(entry)
	entry.folder:ClearAllChildren()
	entry.built = false
	-- The Line folder was a child of the one just cleared, so the belt has gone
	-- with the deck. Say so, or sync would believe a conveyor is standing on a
	-- storey that no longer exists and never rebuild it.
	entry.lineBuilt = false
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

	-- TWO THINGS TO KEEP IN STEP, NOT ONE. The deck and the line on it are
	-- separate purchases (TODO.md item 4), so this is four transitions rather
	-- than two — and the line's is ANDed with the deck's, because a conveyor in
	-- mid-air is worse than no conveyor. The chain makes that unreachable by
	-- purchase, but assign() replays owned ids by `order` and a save can present
	-- them in any state at all.
	local wantsLine = unlocked and Config.floorLineBuilt(FLOOR, tycoon.owned)

	-- WHETHER THIS IS A PURCHASE OR A REBUILD, and only a purchase gets the six
	-- seconds. `sync` fires on purchase, release, rebirth and re-claim, and a
	-- player walking back onto a plot they already own should not watch their
	-- own building go up again before they can climb their own stairs.
	--
	-- The signal is the owner: on the first sync after an assign, `lastOwner` is
	-- nil and the deck arrives instantly; on any later sync for the same owner,
	-- the only way `unlocked` can have just become true is that they bought it.
	local entry0 = state[tycoon]
	local sameOwner = entry0 ~= nil and entry0.lastOwner == tycoon.owner
	local animate = unlocked and not built and sameOwner

	if unlocked and not built then
		FloorService.build(tycoon, animate)
		-- THE BEAT THAT RAISES THE BUILDING. The roof was sitting on the ground
		-- storey's line, which is this deck's underside; rebuilt now it sits on the
		-- upper storey's, on top of the walls build() just put up. Without this call
		-- the deck grows through it — roof is minute 28 and floor is minute 6, so
		-- every player would get a half-roof rather than nobody.
		tycoon:refreshRoof()
	elseif built and not unlocked then
		FloorService.teardown(tycoon)
		tycoon:refreshRoof()
	end

	-- Re-read: build() and teardown() above both move `lineBuilt`.
	local entry2 = state[tycoon]
	local lineBuilt = entry2 ~= nil and entry2.lineBuilt
	local deckStanding = entry2 ~= nil and entry2.built

	if wantsLine and deckStanding and not lineBuilt then
		FloorService.buildLine(tycoon)
	elseif lineBuilt and not (wantsLine and deckStanding) then
		FloorService.teardownLine(tycoon)
	end

	-- Stamped last, so the NEXT sync can tell a purchase from a re-claim.
	local final = state[tycoon]
	if final then
		final.lastOwner = tycoon.owner
	end
end

--- The stage ids this file actually raises. Named here so start() can hold the
--- Config table to it: a stage in Config that nothing dispatches is a duration
--- someone tuned that does nothing, and an id this file asks for that Config
--- does not have takes the whole build down at the first purchase. The verifier
--- reads Config and cannot see either.
local RAISED_STAGES = { "deck", "walls", "ladder" }

function FloorService.start()
	if not FLOOR then
		return
	end

	do
		local declared, dispatched = {}, {}
		for _, stage in ipairs(FLOOR.raise and FLOOR.raise.stages or {}) do
			declared[stage.id] = true
		end
		for _, id in ipairs(RAISED_STAGES) do
			dispatched[id] = true
			if not declared[id] then
				warn(("[Tung] FloorService raises stage %q, which Config.Floors[1].raise does not declare"):format(id))
			end
		end
		for id in pairs(declared) do
			if not dispatched[id] then
				warn(("[Tung] Config.Floors[1].raise declares stage %q, which nothing raises — it is a duration that does nothing"):format(id))
			end
		end
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
