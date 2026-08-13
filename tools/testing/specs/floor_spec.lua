--[[
	floor_spec.lua — the second floor's shape: the zoned deck, the stairwell and
	the armoury that moved upstairs.

	WHAT THIS FAMILY IS FOR. The mock is not BaseParts, CFrames or physics
	(tools/testing/mock/instance.lua), and FloorService is not in SERVER_MODULES
	(tools/test.py:52, docs/dev/ARCHITECTURE.md §7), so nothing here builds a deck
	and looks at its slabs. What IS reachable is everything the deck is built FROM:
	Config.floorBeltPath, Config.floorTopY and the three track-furniture helpers
	are pure functions over Config.Floors and Config.Layout.Tracks, and
	Tycoon:buttonPosition / :legOf / :pointOnLeg are pure methods that a stub plot
	with nothing but a `paths` table can drive. Those are the whole surface below,
	plus the plan-view arithmetic that says whether two pieces of furniture on one
	deck are standing in each other.

	WHY IT IS NOT tools/verify_config.lua'S JOB. The verifier pins the SHIPPED
	numbers — one deck, two zones, one hatch, two tracks — which proves these
	functions agree with one table of values. It cannot prove they are DERIVED from
	it, and that is the whole claim this round rests on:

	    Config.floorBeltPath is derived from the `line` ZONE, not from the deck,
	    and the line zone is the old deck rectangle to the stud.

	A function that ignored the zone and returned four literals would satisfy every
	config check the verifier has. So this file moves the inputs. Two specs mutate
	`deckSize`/`deckAt` and require the belt not to move (the property that keeps
	the drop budget, the trigger dwell and mezz_dropper1's position valid now that
	the deck spans the plot), and one mutates the LINE ZONE and requires the belt to
	follow — because without that second half the first half passes for a function
	that reads nothing at all. Mutation is legal because T.world() builds a fresh
	realm with its own load of Config (tools/test.py's __newRealm); structure_spec's
	"a fresh realm's Config is untouched by another spec's mutation" is the
	assertion that licenses it, and this file relies on it rather than restating it.

	EVERY LOOP COUNTS WHAT IT VISITED. A loop that asserts inside itself passes for
	free over an empty list, which is how a green spec ends up being evidence of
	nothing. Every loop below ends on the number of legs, slots, tracks or zones it
	actually saw, and eachTrack additionally counts Layout.Tracks' own keys, so a
	third cabinet cannot be added without this file noticing.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL. All fifteen were watched going red under
	thirty-nine targeted breaks injected into the spec's OWN realm — its Config, or
	a replacement for the very function it guards — and every failure named what
	went wrong rather than raising. The breaks, in order:

	  floorBeltPath rewritten to derive from the DECK instead of the line zone
	    (the bug this round exists to prevent; it reddens four specs on its own),
	    deckLift dropped to 0, belt.side back to the 10 that overshot by a stud
	    and a half;
	  floorTopY returning the deck's UNDERSIDE for a known id, ignoring nil and
	    always answering upstairs, and Layout.Tracks.weapons.floor typo'd to
	    "mezanine" and cleared to nil;
	  trackShelfPosition lifted 5 above the WORLD, trackCabinet's length short by
	    one slot pitch, a third cabinet added to Layout.Tracks that no loop here
	    visits;
	  the mezzanine belt's third outboard sign flipped, so the return leg's
	    machines swing over the walkway;
	  the line zone grown 20 studs deeper, over the armoury and off the deck's
	    back edge; the armour cabinet pushed to x = 60, off the armoury zone;
	  the hatch set flush to the deck's back edge, moved off the deck entirely,
	    moved onto the belt's return leg, moved under the weapons cabinet, turned
	    into a 5x20 slot narrower than its own gate, and shrunk to 3x3 under a
	    2-stud truss inside a 1-stud guard; ladder.gate cut to the truss's bare
	    width; ladder.rise raised past the railing; ladder.at resurrected;
	  floorLadderAt parking the truss in the middle of the void and against the
	    OPPOSITE lip on all four arrivals, floorLandingAt leaving you inside the
	    hole, hatch.arrival renamed to a value no branch handles, the weapons
	    cabinet slid over the landing, and belt.ladderClearance raised past what
	    the landing actually has;
	  the weapons pitch shortened to 10 so a sixth slot would fit after all, and
	    the armour pitch widened to 20 so its fifth would not.

	ONE THING THAT PASSES FOR THE WRONG REASON, AND WHERE IT IS CAUGHT. Rewriting
	floorLandingAt to return the deck's front edge — which is what the check it
	replaced measured — does NOT redden "the stairwell is clear of...": the front
	edge is 91 studs from the hopper and clears it easily. That is the whole reason
	floorLandingAt exists, and it is why the spec below it pins where the landing
	is, per lip, rather than trusting the clearance check to notice.

	WHAT IT DELIBERATELY DOES NOT COVER. Wall spans, bays, roofUnderside and
	shellPartCount are structure_spec's, and the deck appears there only as the
	thing the ground storey's wall stops under. The slab pieces that get built
	AROUND the hatch, the guard that runs round three sides of it and the truss part
	itself are geometry: they need a BasePart, so they are Studio's job and this
	file only checks that the numbers they will be built from leave room. Nor does
	it check the deck's PILLARS: `insetSide 4` and `insetFront 8` now land them at
	x = +-54 and z = -64 / +60 rather than the +-52 and -16 their comment claims,
	and what they might now be standing on down on the plot floor is a clearance
	sweep over Layout, which is the verifier's shape of job rather than this one's.
]]

return function(T)

T.family("floor", "the belt comes from the line zone, the furniture stands on the deck, and the stairwell is clear")

local EPS = 1e-9

-- ── plan-view arithmetic ────────────────────────────────────────────────────
--
-- Everything on a deck is a footprint on one plane, so collisions here are 2D.
-- Y is dropped on purpose: the deck's furniture all stands on floorTopY, and a
-- box's height never decides whether two things are standing in each other.

--- The min/max rectangle a centre-and-size pair occupies on X and Z.
--- Component arithmetic, matching Config's own rule for the same reason: the
--- verifier's Vector3 has no operators and this file's expectations have to be
--- readable beside its.
local function box(centre, size)
	return {
		minX = centre.X - size.X / 2, maxX = centre.X + size.X / 2,
		minZ = centre.Z - size.Z / 2, maxZ = centre.Z + size.Z / 2,
	}
end

--- A square footprint of side `side` round a point — a button pedestal, a
--- machine, a shelf display.
local function square(point, side)
	return box(point, { X = side, Y = 0, Z = side })
end

--- `r` grown by `by` on every side: a rectangle plus the guard round it.
local function grown(r, by: number)
	return { minX = r.minX - by, maxX = r.maxX + by, minZ = r.minZ - by, maxZ = r.maxZ + by }
end

local function describeBox(r): string
	return ("x %g..%g, z %g..%g"):format(r.minX, r.maxX, r.minZ, r.maxZ)
end

--- `inner` lies wholly inside `outer`, named per edge so a failure says WHICH
--- way it hangs over rather than just that it does.
local function within(t, inner, outer, label: string)
	t:gte(inner.minX, outer.minX - EPS, label .. ": hangs over the -X edge")
	t:lte(inner.maxX, outer.maxX + EPS, label .. ": hangs over the +X edge")
	t:gte(inner.minZ, outer.minZ - EPS, label .. ": hangs over the -Z edge")
	t:lte(inner.maxZ, outer.maxZ + EPS, label .. ": hangs over the +Z edge")
end

--- How far apart two footprints are in plan: 0 if they touch or overlap,
--- otherwise the shortest distance between them.
---
--- Separation on EITHER axis is enough to be clear, which is why this is not a
--- centre-to-centre distance: the weapons cabinet runs 64 studs down the deck,
--- so its centre is nowhere near the stairwell while its body passes seven
--- studs from it.
local function gap(a, b): number
	local dx = math.max(a.minX - b.maxX, b.minX - a.maxX, 0)
	local dz = math.max(a.minZ - b.maxZ, b.minZ - a.maxZ, 0)
	return math.sqrt(dx * dx + dz * dz)
end

--- The two footprints are clear of each other by at least `least` studs, with
--- both rectangles and the measured gap in the message — a collision you cannot
--- see is worth the format call.
local function clear(t, a, b, least: number, label: string)
	t:gte(gap(a, b), least - EPS,
		("%s: %s against %s"):format(label, describeBox(a), describeBox(b)))
end

--- The straight-line distance between two points in plan.
local function plan(a, b): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- ── the deck, its zones and its furniture ───────────────────────────────────

local function floorOf(Config)
	local floor = Config.Floors[1]
	assert(floor, "Config.Floors[1] is gone; this whole file is about it")
	return floor
end

local function deckBox(floor)
	return box(floor.deckAt, floor.deckSize)
end

local function zoneBox(floor, name: string)
	local zone = floor.zones[name]
	return box(zone.at, zone.size), zone
end

--- The belt's legs as footprints, from a path's corner list. Each leg is the
--- running SURFACE only (Layout.BeltWidth).
---
--- The machine row outboard of a leg is deliberately not folded in here, because
--- a leg only has one if something in Config.Buttons stands on it: the mezzanine
--- carries exactly one machine, mezz_dropper1 on leg 1. That distinction is
--- load-bearing rather than pedantic — the RETURN leg's outboard row would run at
--- z = -14, straight across the stairwell, so a check written as "no machine row
--- may touch the hatch" would fail today over a machine that does not exist. The
--- specs that do care about machines get their positions from the buttons that
--- place them, through Tycoon:legOf.
local function legBoxes(t, path, width: number, label: string)
	local half = width / 2
	local boxes = {}
	for index = 1, #path.points - 1 do
		local a, b = path.points[index], path.points[index + 1]
		local r = {
			minX = math.min(a.X, b.X), maxX = math.max(a.X, b.X),
			minZ = math.min(a.Z, b.Z), maxZ = math.max(a.Z, b.Z),
		}
		-- An axis-aligned leg is the premise of this rectangle, and it is also a
		-- real property of every path this game ships: a diagonal leg would put
		-- the belt across the deck at 45 degrees and make every clearance
		-- number below meaningless.
		local runsX, runsZ = r.maxX - r.minX > EPS, r.maxZ - r.minZ > EPS
		t:isFalse(runsX and runsZ,
			("%s leg %d is diagonal — every clearance in this file assumes axis-aligned legs"):format(label, index))
		if runsX then
			r.minZ -= half
			r.maxZ += half
		else
			r.minX -= half
			r.maxX += half
		end
		boxes[index] = r
	end
	return boxes
end

local TRACKS = { "weapons", "armor" }

--- Visit every side-track cabinet, and count Layout.Tracks' own keys against the
--- list above — so adding a third cabinet is a failure here rather than a track
--- this file silently skips.
local function eachTrack(t, Config, fn): number
	local seen = 0
	for _, name in ipairs(TRACKS) do
		local track = Config.Layout.Tracks[name]
		t:notNil(track, name .. ": no such entry in Layout.Tracks")
		if track then
			fn(name, track)
			seen += 1
		end
	end
	local declared = 0
	for _ in pairs(Config.Layout.Tracks) do
		declared += 1
	end
	t:eq(seen, declared, "Layout.Tracks holds a track this file never visits")
	return seen
end

--- A plot that is nothing but its two belt paths, in the order Tycoon registers
--- them: the ground floor at construction, the mezzanine when the floor is
--- bought. That order is what makes `path = "mezzanine"` resolve to index 2, and
--- pathIndexOf is the thing being exercised.
local function plotWithBelts(w)
	local Tycoon = w.req("Tycoon")
	local Config = w.config
	local plot = setmetatable({ paths = {} }, { __index = Tycoon })
	plot:addBeltPath(Config.BeltPaths[1])
	plot:addBeltPath(Config.floorBeltPath(floorOf(Config)), floorOf(Config).belt.outboard)
	return plot, Tycoon, Config
end

-- ── the claim the whole round rests on ──────────────────────────────────────

T.spec("the mezzanine belt is the old deck rectangle, corner for corner", function(t)
	-- The line zone IS the deck the mezzanine used to have — 112 x 60 at
	-- (0, 0, -38) — so every point below is what floorBeltPath returned when the
	-- deck itself was that rectangle. These are hand-derived from the margins
	-- (back 13, side 12, front 14, collectorX 28, collectorRun 16), not read back
	-- out of the function, which is the only way they are an oracle rather than a
	-- restatement.
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local path = Config.floorBeltPath(floor)

	t:eq(path.id, "mezzanine", "the path must carry the floor's id, or pathIndexOf cannot find it")
	t:eq(#path.points, 4, "three legs round the line zone and one back across it")
	t:eq(#path.outboard, #path.points - 1, "one outboard sign per LEG, not per point")

	local want = { { 44, -55 }, { -44, -55 }, { -44, -22 }, { 12, -22 } }
	local seen = 0
	for index, pair in ipairs(want) do
		local point = path.points[index]
		t:notNil(point, ("corner %d is missing"):format(index))
		if point then
			t:near(point.X, pair[1], EPS, ("corner %d moved on X"):format(index))
			t:near(point.Z, pair[2], EPS, ("corner %d moved on Z"):format(index))
			t:near(point.Y, 0, EPS,
				("corner %d carries a height; the path's y is the path's, not the corner's"):format(index))
			seen += 1
		end
	end
	t:eq(seen, 4, "every corner must have been checked")

	t:near(path.collectorAt.X, 28, EPS, "the hopper moved on X")
	t:near(path.collectorAt.Z, -22, EPS, "the hopper is not on the return leg")
	t:near(path.y, 22.1, EPS, "the belt must float deckLift over a deck whose top is at 22")
	t:near(path.y, floor.height + floor.deckLift, EPS,
		"the belt's height is the deck's top plus deckLift, not a literal")

	-- ...and the require-time loop that registers it actually ran. A path that
	-- exists only when someone calls floorBeltPath is a path no belt assertion
	-- and no Tycoon ever sees.
	t:eq(#Config.BeltPaths, 2, "the ground floor and the mezzanine")
	t:eq(Config.BeltPaths[2].id, "mezzanine")
	t:near(Config.BeltPaths[1].y, 0, EPS, "the ground floor's belt is on the ground")
	t:near(Config.BeltPaths[2].y, path.y, EPS,
		"BeltPaths[2] disagrees with floorBeltPath — the registered path is a stale copy")
end)

T.spec("widening the deck moves no belt leg, no machine and no hopper", function(t)
	-- THE PROPERTY THIS ROUND NEEDED. The deck grew from 112 x 60 at (0,0,-38) to
	-- 116 x 136 at the origin. A belt derived from the DECK would have spread
	-- itself across the whole storey the moment that happened and taken the drop
	-- budget, the trigger dwell and mezz_dropper1's position with it. Nothing else
	-- in the suite or the verifier tests this: the verifier only ever sees one
	-- deck.
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)

	local before = Config.floorBeltPath(floor)

	-- Four separate ways of moving the deck, in one realm, applied on top of each
	-- other: bigger, smaller than the zone it contains, off-centre, and a deck
	-- whose slab is four times as thick.
	local decks = {
		{ size = { X = 200, Y = 1.6, Z = 200 }, at = { X = 0, Y = 0, Z = 0 } },
		{ size = { X = 60, Y = 1.6, Z = 40 }, at = { X = 0, Y = 0, Z = 0 } },
		{ size = { X = 116, Y = 1.6, Z = 136 }, at = { X = 30, Y = 0, Z = -20 } },
		{ size = { X = 116, Y = 6.4, Z = 136 }, at = { X = -7.5, Y = 0, Z = 12.5 } },
	}

	local moved = 0
	for index, deck in ipairs(decks) do
		floor.deckSize = deck.size
		floor.deckAt = deck.at
		local after = Config.floorBeltPath(floor)
		local label = ("deck %d"):format(index)

		t:eq(#after.points, #before.points, label .. ": the leg count changed with the deck")
		for corner = 1, #before.points do
			t:near(after.points[corner] and after.points[corner].X, before.points[corner].X, EPS,
				("%s: corner %d moved on X when the deck did"):format(label, corner))
			t:near(after.points[corner] and after.points[corner].Z, before.points[corner].Z, EPS,
				("%s: corner %d moved on Z when the deck did"):format(label, corner))
		end
		t:near(after.collectorAt.X, before.collectorAt.X, EPS, label .. ": the hopper moved on X")
		t:near(after.collectorAt.Z, before.collectorAt.Z, EPS, label .. ": the hopper moved on Z")
		-- The height is the ONE thing that may depend on the floor rather than the
		-- zone, and it depends on `height`, which none of these mutations touch.
		t:near(after.y, before.y, EPS, label .. ": the belt changed height when the deck's slab did")
		moved += 1
	end
	t:eq(moved, #decks, "every deck in the table must have been tried")

	-- Nor do the deck's other fittings reach the belt.
	floor.railHeight = 40
	floor.pillar = { size = 20, insetSide = 30, insetBack = 30, insetFront = 30 }
	floor.hatch = { at = { X = -40, Y = 0, Z = 40 }, size = { X = 30, Y = 0, Z = 30 } }
	local last = Config.floorBeltPath(floor)
	t:near(last.points[1].X, before.points[1].X, EPS, "the railing height reached the belt")
	t:near(last.points[4].Z, before.points[4].Z, EPS, "the stairwell reached the belt")
end)

T.spec("the belt follows its line zone, which is what makes the spec above mean anything", function(t)
	-- The other half of "widening the deck moves nothing". A floorBeltPath that
	-- returned four literals would pass that spec perfectly, so: move the zone and
	-- require the belt to move WITH it, by exactly the amount it moved.
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local before = Config.floorBeltPath(floor)

	-- A pure translation: every point shifts by the same vector, and the hopper's
	-- Z does too while its X does not, because collectorX is stated rather than
	-- derived (Config.Floors' `collectorX` comment: "a collector that moves
	-- because a piece of furniture moved is a coupling nobody asked for").
	local zone = floor.zones.line
	zone.at = { X = zone.at.X + 9, Y = 0, Z = zone.at.Z - 17 }
	local shifted = Config.floorBeltPath(floor)
	local slid = 0
	for index, point in ipairs(shifted.points) do
		-- Every corner follows on Z. Only the first three follow on X: the last
		-- one is the run-off toward the hopper, and its X is collectorX minus
		-- collectorRun — stated, not derived from the zone.
		if index < #shifted.points then
			t:near(point.X, before.points[index].X + 9, EPS,
				("corner %d did not follow the line zone on X"):format(index))
		else
			t:near(point.X, before.points[index].X, EPS,
				"the run-off's X comes from collectorX, not from the zone")
		end
		t:near(point.Z, before.points[index].Z - 17, EPS,
			("corner %d did not follow the line zone on Z"):format(index))
		slid += 1
	end
	t:eq(slid, 4)
	t:near(shifted.collectorAt.Z, before.collectorAt.Z - 17, EPS, "the hopper did not follow the zone")
	t:near(shifted.collectorAt.X, 28, EPS, "the hopper's X is stated, so it must not have moved")

	-- ...and the zone's SIZE reaches the two side legs and the back leg, since
	-- each is a margin in from an edge.
	zone.size = { X = zone.size.X + 20, Y = 0, Z = zone.size.Z + 10 }
	local wider = Config.floorBeltPath(floor)
	t:near(wider.points[1].X, shifted.points[1].X + 10, EPS, "leg 1 did not follow the zone's width")
	t:near(wider.points[2].X, shifted.points[2].X - 10, EPS, "leg 2 did not follow the zone's width")
	t:near(wider.points[1].Z, shifted.points[1].Z - 5, EPS, "the back leg did not follow the zone's depth")
	t:near(wider.points[3].Z, shifted.points[3].Z + 5, EPS, "the return leg did not follow the zone's depth")

	-- And the margins themselves are live, not baked.
	floor.belt.side = floor.belt.side + 6
	local tighter = Config.floorBeltPath(floor)
	t:near(tighter.points[1].X, wider.points[1].X - 6, EPS, "belt.side no longer moves the legs")
	t:near(tighter.points[2].X, wider.points[2].X + 6, EPS, "belt.side no longer moves the legs")
end)

T.spec("every belt leg keeps its machine row inside the line zone", function(t)
	-- The verifier checks this against the DECK, which is now 116 x 136 and
	-- forgiving. The zone is 112 x 60 and is the rectangle the numbers were tuned
	-- against, so it is the tighter statement and the one that catches a margin
	-- shrinking: `side` was 10 when it needed 11.5, and leg 2's machine strip
	-- overshot by a stud and a half.
	local w = T.world()
	local Config = w.config
	local L = Config.Layout
	local floor = floorOf(Config)
	local path = Config.floorBeltPath(floor)
	local line = zoneBox(floor, "line")

	local reach = L.MachineOffset + L.MachineFootprint / 2 + floor.rail.thickness
	t:gt(reach, 0, "a machine with no reach")

	local corners = 0
	for index, point in ipairs(path.points) do
		local footprint = square(point, 2 * reach)
		within(t, footprint, line, ("belt corner %d, machine row included"):format(index))
		corners += 1
	end
	t:eq(corners, 4)

	-- The margin is symmetric here on purpose, so this bound holds whichever side
	-- of a leg its machines are on. The buy-button row is INBOARD and therefore
	-- needs the leg's actual normal, which only Tycoon has — it is checked in
	-- "buttonPosition sends the armoury..." below, on the return leg, which is the
	-- one the old inferred-outboard heuristic got wrong.

	-- The hopper stands on the return leg and its run-off is inside the zone too.
	within(t, square(path.collectorAt, 2 * reach), line, "the hopper")
end)

-- ── which floor a thing stands on ───────────────────────────────────────────

T.spec("floorTopY is 0 for the ground and the deck's top for a floor that exists", function(t)
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)

	t:near(Config.floorTopY(nil), 0, EPS, "no floor named means the ground floor")
	t:near(Config.floorTopY("mezzanine"), floor.height, EPS,
		"a floor id must give its deck's TOP, which is what furniture stands on")
	t:near(Config.floorTopY("mezzanine"), 22, EPS, "the deck's top moved")
	t:ne(Config.floorTopY("mezzanine"), floor.height - floor.deckSize.Y,
		"floorTopY returned the deck's UNDERSIDE — the furniture would be buried in the slab")
	t:near(Config.floorTopY("mezzanine"), Config.storey("upper").floorY, EPS,
		"the furniture and the upper wall must stand on the same plane")

	local named = 0
	for _, entry in ipairs(Config.Floors) do
		t:gt(Config.floorTopY(entry.id), 0,
			entry.id .. ": a floor whose top is 0 is indistinguishable from the ground floor")
		named += 1
	end
	t:eq(named, 1, "one floor above the ground; if that changes, so does this file")

	-- AN UNKNOWN ID RAISES. This spec used to pin the opposite — a silent
	-- fallback to 0 — and said in its own comment that the fallback was a decision
	-- worth seeing, because `floor = "mezanine"` would put the whole armoury back
	-- on the ground floor with nothing raised and every verifier check still
	-- passing, since 0 == 0. It was read, and the fallback was removed rather than
	-- documented: Style.distance(tier) sets the precedent that an unknown tier is
	-- a programming mistake, not a value.
	--
	-- `nil` still means the ground floor, and that distinction is the whole point:
	-- "no floor named" is an answer, "a floor named that does not exist" is a typo.
	t:raises(function()
		Config.floorTopY("mezanine")
	end, "no floor with id", "a typo'd floor id must raise, not quietly return the ground floor")
	t:raises(function()
		Config.floorTopY("")
	end, "no floor with id")
	t:near(Config.floorTopY(nil), 0, EPS, "no floor named still means the ground floor")

	local checked = eachTrack(t, Config, function(name, track)
		if track.floor ~= nil then
			local found = false
			for _, entry in ipairs(Config.Floors) do
				found = found or entry.id == track.floor
			end
			t:isTrue(found,
				("%s stands on floor %q, which is not a Config.Floors id — floorTopY would silently put it on the ground"):format(
					name, tostring(track.floor)))
		end
	end)
	t:eq(checked, 2, "both cabinets")
end)

T.spec("the three track helpers put every slot of both cabinets on the ground, in one file", function(t)
	local w = T.world()
	local Config = w.config

	-- Hand-derived from Layout.Tracks (armour firstZ -36, weapons firstZ 14,
	-- both at spacing 12), so the columns are an oracle rather than a re-run of
	-- the same expression.
	--
	-- PREMISE OVERTURNED. This spec used to end "...on the deck" and its oracle
	-- was the mezzanine's y = 22. Both cabinets came back downstairs in round 8
	-- (TODO.md item 2), so every Y here is 0 — and the `t:ne(shelf.Y, 5)` guard
	-- that used to catch a shelf built 5 above the WORLD instead of 5 above the
	-- deck is gone with it, because on the ground floor those are the same
	-- number. What replaces it is the ordering below: the two cases are one
	-- straight file, so their spans must not overlap.
	local want = {
		armor = { buttonX = 40, cabinetX = 48, z = { -36, -24, -12, 0 }, cabinet = { -18, 4, 13, 44 } },
		weapons = { buttonX = 40, cabinetX = 48, z = { 14, 26, 38, 50, 62 }, cabinet = { 38, 4, 13, 56 } },
	}

	local slots = 0
	local spans = {}
	local visited = eachTrack(t, Config, function(name, track)
		local expect = want[name]
		t:notNil(expect, name .. ": this file has no expectation for that track")
		t:eq(track.slots, #expect.z, name .. ": the slot count moved")
		t:isNil(track.floor,
			name .. ": the cabinets stand on the ground floor, and `floor` says so by being absent")

		for slot = 1, track.slots do
			local button = Config.trackButtonPosition(name, slot)
			local shelf = Config.trackShelfPosition(name, slot)
			local label = ("%s slot %d"):format(name, slot)

			t:near(button.X, expect.buttonX, EPS, label .. ": the button column moved on X")
			t:near(button.Z, expect.z[slot], EPS, label .. ": the button moved on Z")
			t:near(button.Y, 0, EPS, label .. ": the buy button left the plot floor")

			t:near(shelf.Y, 5, EPS, label .. ": the shelf display is not 5 above the floor")
			t:near(shelf.X, expect.cabinetX, EPS,
				label .. ": the shelf is not on its cabinet's face")
			t:near(shelf.Z, button.Z, EPS, label .. ": the shelf does not line up with its buy button")
			slots += 1
		end

		local centre, size = Config.trackCabinet(name)
		t:near(centre.X, expect.cabinetX, EPS, name .. ": the cabinet moved on X")
		t:near(centre.Z, expect.cabinet[1], EPS, name .. ": the cabinet is not centred on its column")
		t:near(centre.Y, 0, EPS, name .. ": the cabinet left the plot floor")
		t:near(size.X, expect.cabinet[2], EPS, name .. ": the cabinet's depth moved")
		t:near(size.Y, expect.cabinet[3], EPS, name .. ": the cabinet's height moved")
		t:near(size.Z, expect.cabinet[4], EPS, name .. ": the cabinet no longer spans its column")

		-- The case contains the column, four studs proud at each end.
		t:near(centre.Z - size.Z / 2, expect.z[1] - 4, EPS, name .. ": the cabinet's near end is not 4 proud of slot 1")
		t:near(centre.Z + size.Z / 2, expect.z[#expect.z] + 4, EPS,
			name .. ": the cabinet's far end is not 4 proud of the last slot")

		table.insert(spans, { id = name, from = centre.Z - size.Z / 2, to = centre.Z + size.Z / 2, x = centre.X })
	end)

	-- ONE FILE, WHICH IS THE WHOLE POINT OF THE MOVE. Both cases share an x, so
	-- the only thing keeping them apart is z, and nothing else in this file
	-- would notice if one grew through the other.
	t:eq(#spans, 2, "two cases to compare")
	t:near(spans[1].x, spans[2].x, EPS, "the two cases are not in the same file")
	table.sort(spans, function(a, b) return a.from < b.from end)
	t:gte(spans[2].from - spans[1].to, 2,
		("%s ends at z=%.1f and %s starts at z=%.1f — the two cases are one file and must not grow through each other")
			:format(spans[1].id, spans[1].to, spans[2].id, spans[2].from))

	t:eq(visited, 2, "both cabinets")
	t:eq(slots, 9, "five weapons slots and four armour slots")
end)

T.spec("a track that names a floor rides it, and clearing one does not move the other", function(t)
	-- THE MIRROR OF WHAT THIS SPEC USED TO BE. It was written when both cabinets
	-- named the mezzanine and `floor = nil` was a path with no shipped caller;
	-- round 8 made nil the shipped answer, so the untested direction is now the
	-- other one. Same argument, same reason it is a spec rather than a config
	-- check: nothing in Config.lua exercises a value nothing sets.
	local w = T.world()
	local Config = w.config
	local top = floorOf(Config).height

	-- Both start on the ground.
	t:isNil(Config.Layout.Tracks.weapons.floor)
	t:isNil(Config.Layout.Tracks.armor.floor)
	t:near(Config.trackButtonPosition("weapons", 1).Y, 0, EPS)

	Config.Layout.Tracks.weapons.floor = "mezzanine"

	for slot = 1, Config.Layout.Tracks.weapons.slots do
		t:near(Config.trackButtonPosition("weapons", slot).Y, top, EPS,
			("a track sent upstairs left slot %d's button on the ground"):format(slot))
		t:near(Config.trackShelfPosition("weapons", slot).Y, top + 5, EPS,
			("a track sent upstairs left slot %d's shelf on the ground"):format(slot))
	end
	local centre = Config.trackCabinet("weapons")
	t:near(centre.Y, top, EPS, "a track sent upstairs left its cabinet on the ground")

	-- X and Z are untouched by the floor: sending a track upstairs must not also
	-- slide it sideways.
	t:near(centre.X, 48, EPS)
	t:near(Config.trackButtonPosition("weapons", 1).Z, 14, EPS)

	-- ...and the other cabinet is still downstairs, so this is one track's floor
	-- rather than a global.
	t:near(Config.trackButtonPosition("armor", 1).Y, 0, EPS,
		"setting one track's floor moved the other one too")
end)

T.spec("buttonPosition sends the armoury and the upstairs line to the deck, and the ground floor to the ground", function(t)
	-- The end-to-end version of the two specs above, through the code that
	-- actually places a pedestal: Tycoon:buttonPosition dispatches on
	-- TrackInfo.furniture and on `path`, and pointOnLeg bakes in the path's own
	-- height. Reachable because none of it touches a BasePart.
	local w = T.world()
	local plot, _, Config = plotWithBelts(w)
	local floor = floorOf(Config)
	local L = Config.Layout

	t:eq(plot:pathIndexOf(Config.ButtonById.mezz_dropper1), 2,
		"the mezzanine's dropper does not resolve to the mezzanine's path")

	-- The upstairs dropper: leg 1 of the mezzanine path, 14 along, buy button
	-- ButtonOffset INBOARD of it. Hand-derived: leg 1 runs from (44, -55) toward
	-- -X with its machines outboard at -Z, so 14 along is x = 30 and the button is
	-- at z = -55 + 11.
	local button = plot:buttonPosition(Config.ButtonById.mezz_dropper1)
	t:near(button.X, 30, EPS, "the upstairs dropper's button moved on X")
	t:near(button.Z, -44, EPS, "the upstairs dropper's button is not inboard of leg 1")
	t:near(button.Y, floor.height + floor.deckLift, EPS,
		"the upstairs dropper's buy button is on the GROUND floor, under its own deck")

	-- And the machine it builds, outboard on the same leg, stands in the line
	-- zone with its whole footprint.
	local line = zoneBox(floor, "line")
	local machine = plot:pointOnLeg(1, 14, L.MachineOffset, 2)
	t:near(machine.Z, -63, EPS, "the upstairs dropper is not outboard of its leg")
	t:near(machine.Y, floor.height + floor.deckLift, EPS, "the upstairs dropper is not on the deck")
	within(t, square(machine, L.MachineFootprint), line, "the upstairs dropper")
	within(t, square(button, 5), line, "the upstairs dropper's buy button")

	-- THE RETURN LEG, which is the leg the old inferred-outboard heuristic got
	-- wrong: its midpoint sits near the middle of the plot, so "point away from
	-- the origin" flipped the side and put the machines over the walkway with the
	-- buy buttons out in space. Both rows are checked against the zone, at three
	-- distances along it, because a flipped sign puts one of them outside.
	local returnLeg = 0
	for _, distance in ipairs({ 4, 28, 52 }) do
		local outboard = plot:pointOnLeg(3, distance, L.MachineOffset, 2)
		local inboard = plot:pointOnLeg(3, distance, -L.ButtonOffset, 2)
		t:near(outboard.Z, -14, EPS,
			"the return leg's machine row is on the wrong side — it is over the walkway")
		t:near(inboard.Z, -33, EPS,
			"the return leg's buy-button row is on the wrong side")
		within(t, square(outboard, L.MachineFootprint), line,
			("the return leg's machine row at %g along"):format(distance))
		within(t, square(inboard, 5), line,
			("the return leg's buy-button row at %g along"):format(distance))
		returnLeg += 1
	end
	t:eq(returnLeg, 3, "three points along the return leg")

	-- Both cabinets' first rungs, through the same call. They are DOWNSTAIRS now
	-- (TODO.md item 2), which is what makes the pair of assertions below the
	-- interesting ones: the armoury and the upstairs line share one dispatcher,
	-- and it has to send them to different storeys on the same call.
	local cabinets = 0
	for _, pair in ipairs({ { "batforge", 40, 14 }, { "armor_padded", 40, -36 } }) do
		local def = Config.ButtonById[pair[1]]
		t:notNil(def, pair[1] .. ": no such button")
		if def then
			local spot = plot:buttonPosition(def)
			t:near(spot.X, pair[2], EPS, pair[1] .. ": the button column moved")
			t:near(spot.Z, pair[3], EPS, pair[1] .. ": the first rung is not at firstZ")
			t:near(spot.Y, 0, EPS, pair[1] .. ": the armoury left the plot floor")
			t:ne(spot.Y, floor.height, pair[1] .. ": the armoury is back on the deck")
			cabinets += 1
		end
	end
	t:eq(cabinets, 2, "both cabinets' first rungs")

	-- The ground floor did NOT come up with them. Two kinds, so a change that
	-- lifts everything is caught: a machine on BeltPaths[1] and a spine button
	-- from Layout.MiscButtons.
	t:near(plot:buttonPosition(Config.ButtonById.dropper1).Y, 0, EPS,
		"a ground-floor dropper's button left the ground")
	t:near(plot:buttonPosition(Config.ButtonById.floor2).Y, 0, EPS,
		"the button that BUYS the floor is standing on the floor it buys")
end)

-- ── the zones ───────────────────────────────────────────────────────────────

T.spec("both zones lie on the deck and their interiors do not overlap", function(t)
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local deck = deckBox(floor)

	local names, boxes = {}, {}
	local seen = 0
	for name, zone in pairs(floor.zones) do
		local r = box(zone.at, zone.size)
		within(t, r, deck, name .. " zone")
		t:gt(zone.size.X, 0, name .. " zone has no width")
		t:gt(zone.size.Z, 0, name .. " zone has no depth")
		-- A footprint, not a volume: the containment arithmetic above is 2D and
		-- the slab's thickness is deckSize.Y. A zone with a height would be a
		-- second, disagreeing answer to how thick the floor is.
		t:near(zone.size.Y, 0, EPS, name .. " zone has a height; a zone is a footprint on the deck")
		t:notNil(zone.holds, name .. " zone does not say what it holds")
		table.insert(names, name)
		table.insert(boxes, r)
		seen += 1
	end
	t:eq(seen, 2, "the line and the armoury")

	local pairsChecked = 0
	for i = 1, #boxes do
		for j = i + 1, #boxes do
			-- ABUTTING IS ALLOWED, OVERLAPPING IS NOT: the line ends at z = -8 and
			-- the armoury starts there, so the test is on interiors. A shared edge
			-- is a storey divided in two; a shared area is two owners for one
			-- piece of deck.
			t:eq(gap(boxes[i], boxes[j]), 0,
				("the %s and %s zones do not meet — there is deck belonging to neither"):format(
					names[i], names[j]))
			t:isFalse(
				boxes[i].minX < boxes[j].maxX - EPS and boxes[j].minX < boxes[i].maxX - EPS
					and boxes[i].minZ < boxes[j].maxZ - EPS and boxes[j].minZ < boxes[i].maxZ - EPS,
				("the %s and %s zones overlap: %s against %s"):format(
					names[i], names[j], describeBox(boxes[i]), describeBox(boxes[j])))
			pairsChecked += 1
		end
	end
	t:eq(pairsChecked, 1, "one pair of zones to compare")
end)

T.spec("every cabinet, every button and every shelf stands in the right-hand aisle, off the production line", function(t)
	-- PREMISE OVERTURNED. This spec used to assert the armoury stood in the
	-- mezzanine's `armoury` zone, which is how "the armoury moved upstairs"
	-- became checkable rather than commented. TODO.md item 2 moved it back down,
	-- and there is no ground-floor zone table to point at — the ground storey is
	-- described by Config.Layout, not by Config.Floors.
	--
	-- So the claim is re-stated in the vocabulary the ground floor does have:
	-- the plot's left half is the production line and its right half is the
	-- armoury, and every piece of both cases is on the right of the belt with
	-- clear air between them. That is the same assertion — "it landed somewhere
	-- named" — against the boundary that actually exists.
	local w = T.world()
	local Config = w.config
	local L = Config.Layout

	-- The ground belt as two leg boxes, derived rather than typed: leg 1 runs
	-- along the back at BeltStart.Z, leg 2 down the left at BeltCorner.X. The
	-- machine row sits MachineOffset outboard and the buy-button row
	-- ButtonOffset inboard, so the strip a cabinet must clear is wider than the
	-- running surface — which is the whole reason to derive it here.
	local reach = L.MachineOffset + L.MachineFootprint / 2
	local legs = {
		{ id = "leg 1 (the dropper row)", box = {
			minX = math.min(L.BeltStart.X, L.BeltCorner.X), maxX = math.max(L.BeltStart.X, L.BeltCorner.X),
			minZ = L.BeltStart.Z - reach, maxZ = L.BeltStart.Z + L.ButtonOffset } },
		{ id = "leg 2 (the upgrader row)", box = {
			minX = L.BeltCorner.X - reach, maxX = L.BeltCorner.X + L.ButtonOffset,
			minZ = math.min(L.BeltCorner.Z, L.BeltEnd.Z), maxZ = math.max(L.BeltCorner.Z, L.BeltEnd.Z) } },
	}

	local pieces = 0
	local visited = eachTrack(t, Config, function(name, track)
		local centre, size = Config.trackCabinet(name)
		local body = box(centre, size)

		t:gt(body.minX, 0,
			("%s cabinet crosses into the left half of the plot: %s"):format(name, describeBox(body)))
		for _, leg in ipairs(legs) do
			t:gt(gap(body, leg.box), 0,
				("%s cabinet reaches into %s: %s"):format(name, leg.id, describeBox(body)))
		end
		pieces += 1

		for slot = 1, track.slots do
			local pad = square(Config.trackButtonPosition(name, slot), 5)
			local shelf = square(Config.trackShelfPosition(name, slot), 5)
			local label = ("%s slot %d"):format(name, slot)
			t:gt(pad.minX, 0, label .. " button pedestal is in the left half of the plot")
			for _, leg in ipairs(legs) do
				t:gt(gap(pad, leg.box), 0, label .. " button pedestal reaches into " .. leg.id)
			end
			t:gt(shelf.minX, 0, label .. " shelf display is in the left half of the plot")
			pieces += 2
		end
	end)

	t:eq(visited, 2)
	t:eq(pieces, 20, "two cabinets, nine pedestals and nine shelves")

	-- ONE FILE MEANS ONE COLUMN, which is the thing that changed. Both tracks
	-- share buttonX now, so slot-against-slot in plan is no longer the question
	-- — every pedestal against every OTHER pedestal is, because two columns at
	-- one x are a single ladder and nothing else here would notice a collision.
	local spots = {}
	for _, name in ipairs({ "weapons", "armor" }) do
		for slot = 1, Config.Layout.Tracks[name].slots do
			table.insert(spots, { id = ("%s[%d]"):format(name, slot),
				at = Config.trackButtonPosition(name, slot) })
		end
	end
	t:eq(#spots, 9, "nine pedestals in the file")
	local compared = 0
	for i = 1, #spots do
		for j = i + 1, #spots do
			clear(t, square(spots[i].at, 5), square(spots[j].at, 5), 1,
				("%s and %s are standing in each other"):format(spots[i].id, spots[j].id))
			compared += 1
		end
	end
	t:eq(compared, 36, "every pair of the nine")
end)

-- ── the stairwell ───────────────────────────────────────────────────────────

T.spec("the stairwell is a hole in the deck, with slab left on all four sides", function(t)
	-- The deck used to end at z = -8 with the ladder standing proud of that edge.
	-- A deck that spans the plot has no front edge to stand in front of, so the
	-- slab is built in PIECES around this rectangle — and a piece with a zero or
	-- negative width is a hatch that has eaten the deck's edge rather than a hole
	-- in the middle of it.
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local deck = deckBox(floor)
	local hatch = box(floor.hatch.at, floor.hatch.size)

	within(t, hatch, deck, "the stairwell")
	t:gt(floor.hatch.size.X, 0, "a stairwell with no width")
	t:gt(floor.hatch.size.Z, 0, "a stairwell with no depth")
	t:near(floor.hatch.size.Y, 0, EPS,
		"the stairwell has a height; it is a footprint, and the slab's thickness is deckSize.Y")

	local sides = {
		{ "-X", hatch.minX - deck.minX }, { "+X", deck.maxX - hatch.maxX },
		{ "-Z", hatch.minZ - deck.minZ }, { "+Z", deck.maxZ - hatch.maxZ },
	}
	local counted = 0
	for _, side in ipairs(sides) do
		t:gt(side[2], 0,
			("the slab piece on the %s side of the stairwell is %g studs wide — the hatch has eaten the deck's edge"):format(
				side[1], side[2]))
		counted += 1
	end
	t:eq(counted, 4, "four slab pieces round a rectangular hole")
end)

T.spec("the stairwell is clear of the belt, the hopper, the cabinets and the button columns", function(t)
	local w = T.world()
	local Config = w.config
	local L = Config.Layout
	local floor = floorOf(Config)
	local path = Config.floorBeltPath(floor)
	local hatch = box(floor.hatch.at, floor.hatch.size)

	-- The guard runs round the hatch, so the thing that has to be clear is the
	-- hatch plus half a rail either side, not the hole itself.
	local guard = grown(hatch, floor.rail.thickness / 2)

	local legs = legBoxes(t, path, L.BeltWidth, "the mezzanine belt")
	local checked = 0
	for index, leg in ipairs(legs) do
		t:gt(gap(guard, leg), 0,
			("the stairwell and its guard cut into belt leg %d: %s against %s"):format(
				index, describeBox(guard), describeBox(leg)))
		checked += 1
	end
	t:eq(checked, 3, "three legs round the line zone and one back across it")

	-- THE HOPPER AGAINST WHERE YOU ARRIVE, measured from Config.floorLandingAt —
	-- the spot on the deck you step onto — and not from the truss, which stands
	-- inside the hole, nor from the deck's front edge, which after the deck grew is
	-- 74 studs away and passes for entirely the wrong reason.
	local landing = Config.floorLandingAt(floor)
	t:gte(plan(path.collectorAt, landing), floor.belt.ladderClearance - EPS,
		"the hopper is on top of where you arrive")
	t:gt(gap(guard, square(path.collectorAt, L.MachineFootprint)), 0,
		"the hopper's own footprint is inside the stairwell")

	-- The furniture, against the hole AND against the spot you step onto: a
	-- cabinet you cannot walk out of the stairwell past is as bad as one built
	-- inside it. The weapons cabinet is the tight one both times — it starts at
	-- z = 0, the hatch ends at z = -6 and the landing is at z = -4.
	local standing = square(landing, 5)
	local furniture = 0
	eachTrack(t, Config, function(name, track)
		local centre, size = Config.trackCabinet(name)
		local body = box(centre, size)
		clear(t, guard, body, 1, ("the %s cabinet is standing in the stairwell"):format(name))
		clear(t, standing, body, 1,
			("the %s cabinet is standing where you step off the truss"):format(name))
		furniture += 1
		for slot = 1, track.slots do
			local button = square(Config.trackButtonPosition(name, slot), 5)
			local shelf = square(Config.trackShelfPosition(name, slot), 5)
			clear(t, guard, button, 1,
				("the %s slot %d button is standing in the stairwell"):format(name, slot))
			clear(t, standing, button, 1,
				("the %s slot %d button is standing where you step off the truss"):format(name, slot))
			clear(t, guard, shelf, 1,
				("the %s slot %d shelf is standing in the stairwell"):format(name, slot))
			furniture += 2
		end
	end)
	t:eq(furniture, 20, "two cabinets, nine pedestals and nine shelves")
end)

T.spec("the stairwell takes the truss and its guard, and the arrival opening takes the truss", function(t)
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local ladder = floor.ladder
	local hatch = floor.hatch

	local narrowest = math.min(hatch.size.X, hatch.size.Z)
	t:gt(ladder.width, 0, "a truss with no cross-section")
	t:gte(narrowest, ladder.width + 2 * floor.rail.thickness,
		("the stairwell's narrow side is %g studs for a %g-stud truss inside a %g-stud guard"):format(
			narrowest, ladder.width, floor.rail.thickness))

	-- The gate is cut in ONE lip, so it is bounded by that lip's length rather
	-- than by the hatch's narrow side. On a square hatch those are the same
	-- number, which is exactly why it has to be written as the lip: the day the
	-- hatch becomes a slot, "narrow side" is the wrong bound and nothing says so.
	local alongX = hatch.arrival == "+Z" or hatch.arrival == "-Z" or hatch.arrival == nil
	local lip = alongX and hatch.size.X or hatch.size.Z

	-- Two studs of margin, matching the rule the verifier already applies: a gap
	-- exactly as wide as the truss puts you against the jamb, and there is nothing
	-- to see when it happens.
	t:gte(ladder.gate, ladder.width + 2,
		("the arrival opening is %g studs for a %g-stud truss; you would climb into the jamb"):format(
			ladder.gate, ladder.width))
	t:lte(ladder.gate, lip,
		("the arrival opening is %g studs but the %s lip it is cut in is %g long — the gap runs past the hole"):format(
			ladder.gate, tostring(hatch.arrival), lip))
	t:gt(ladder.rise, 0, "the truss stops level with the deck; it has to overshoot to step off")
	t:lt(ladder.rise, floor.railHeight,
		"the truss overshoots the railing it arrives inside")

	-- ladder.at is GONE, and it should stay gone: it was a spot proud of a deck
	-- edge that no longer exists, and while it survived it was a box the verifier
	-- measured clearances against and the builder never built.
	t:isNil(ladder.at,
		"ladder.at is back — the truss's position is derived by Config.floorLadderAt now, and two answers is how it went wrong before")
end)

T.spec("the truss hugs its arrival lip and the landing is past it, on all four lips", function(t)
	-- Config.floorLadderAt and Config.floorLandingAt each branch four ways on
	-- hatch.arrival and the shipped config takes ONE of those branches. The other
	-- three are the reason this spec exists: a sign error in any of them is a
	-- truss embedded in the slab, and no config check can see a branch the shipped
	-- data never enters.
	local w = T.world()
	local Config = w.config
	local floor = floorOf(Config)
	local hatch = floor.hatch
	local width = floor.ladder.width

	-- The shipped stairwell is in the deck's front-left quarter, arriving on its
	-- -Z lip: the aisle at x = GateCentre failed twice, first against the
	-- mezzanine belt's base and then against the machine row of its return leg,
	-- which owns every x from the left wall to 14.5. Config.Floors[1].hatch
	-- carries that history.
	t:eq(hatch.arrival, "-Z",
		"the shipped arrival lip moved; the pinned numbers below are about -Z")
	local ladderAt = Config.floorLadderAt(floor)
	local landingAt = Config.floorLandingAt(floor)
	t:near(ladderAt.X, -16, EPS, "the truss left the stairwell's x")
	t:near(ladderAt.Z, 55, EPS, "the truss is not against the hatch's -Z lip")
	t:near(landingAt.X, -16, EPS)
	t:near(landingAt.Z, 52, EPS, "you do not step off onto the deck a truss-width past the lip")

	-- Every lip, including the three nothing ships on. `lip` is the signed axis and
	-- component the arrival names; `across` is the other one, which neither
	-- function may touch.
	local lips = {
		{ arrival = "+Z", axis = "Z", sign = 1, across = "X" },
		{ arrival = "-Z", axis = "Z", sign = -1, across = "X" },
		{ arrival = "+X", axis = "X", sign = 1, across = "Z" },
		{ arrival = "-X", axis = "X", sign = -1, across = "Z" },
		-- An arrival nobody set falls back to +Z. Pinned as it behaves: a nil here
		-- is a hatch with no way out, and a silent default at least builds
		-- something you can climb. It is the same shape of fallback as
		-- floorTopY's 0, and the same thing is true of it — it is total, and it
		-- says nothing.
		{ arrival = nil, axis = "Z", sign = 1, across = "X" },
	}

	local checked = 0
	for _, lip in ipairs(lips) do
		hatch.arrival = lip.arrival
		local label = ("arrival %s"):format(tostring(lip.arrival))
		local truss = Config.floorLadderAt(floor)
		local landing = Config.floorLandingAt(floor)
		local half = (lip.axis == "X" and hatch.size.X or hatch.size.Z) / 2

		-- The truss stands INSIDE the hole, flush to the named lip: its outer face
		-- is the lip. A sign error puts it against the opposite lip, which still
		-- lands inside the hatch — so "inside the hatch" alone would not catch it,
		-- and the flush test is the one that does.
		t:near(truss[lip.axis], hatch.at[lip.axis] + lip.sign * (half - width / 2), EPS,
			label .. ": the truss is not against its own lip")
		t:near(truss[lip.across], hatch.at[lip.across], EPS,
			label .. ": the truss drifted along the lip")
		within(t, square(truss, width), box(hatch.at, hatch.size), label .. ": the truss")

		-- The landing is a truss-width PAST the lip: outside the hole, on the deck,
		-- and on the same side the guard is cut.
		t:near(landing[lip.axis], hatch.at[lip.axis] + lip.sign * (half + width), EPS,
			label .. ": the landing is not a truss-width past the lip")
		t:near(landing[lip.across], hatch.at[lip.across], EPS,
			label .. ": the landing drifted along the lip")
		t:gt(gap(square(landing, EPS), box(hatch.at, hatch.size)), 0,
			label .. ": you step off the truss into the hole you just climbed through")
		within(t, square(landing, width), deckBox(floor), label .. ": the landing")
		t:gt((landing[lip.axis] - hatch.at[lip.axis]) * lip.sign, 0,
			label .. ": the landing is on the far side of the hatch from its own lip")
		checked += 1
	end
	t:eq(checked, 5, "four lips and the fallback")
end)

-- ── a slot the shipped table does not have ──────────────────────────────────

T.spec("a sixth weapons slot would stand through the front wall, and armour's fifth inside the weapons column", function(t)
	-- Config.Layout.Tracks says exactly this in a comment. It is a property of
	-- firstZ, spacing and the plot rather than of the shipped table, so a config
	-- check cannot see it — and the day the plot or the belt moves, the comment
	-- becomes wrong silently.
	--
	-- PREMISE OVERTURNED, and what changed is what each column runs OUT OF.
	-- Upstairs both grew forward into open deck and only the front edge ever
	-- stopped anything. Down here the two columns share one file, so weapons —
	-- the front one — still runs out of plot, but armour runs out of WEAPONS:
	-- both grow in +Z from their own firstZ, and armour's next slot lands two
	-- studs short of the first weapons pedestal. That is the cost of one file
	-- and it should fail loudly rather than be discovered by a fifth armour
	-- tier appearing inside a bat cabinet.
	local w = T.world()
	local Config = w.config
	local L = Config.Layout
	local halfZ = Config.World.PlotSize.Z / 2

	local weapons = L.Tracks.weapons
	t:eq(weapons.slots, 5, "the claim below is about the slot AFTER the last shipped one")
	local sixth = Config.trackButtonPosition("weapons", 6)
	t:near(sixth.Z, 74, EPS, "the sixth slot is not where the Config comment says it is")
	t:gt(sixth.Z, halfZ, "a sixth weapons slot would stand outside the plot entirely")

	-- And the case behind it: raising `slots` lengthens the cabinet from both the
	-- count and the pitch, so the body overruns the wall as well as the pedestal.
	weapons.slots = 6
	local centre, size = Config.trackCabinet("weapons")
	local body = box(centre, size)
	t:gt(body.maxZ, halfZ,
		("a six-slot weapons case runs to z = %g and the plot ends at %g"):format(body.maxZ, halfZ))
	weapons.slots = 5

	-- THE OTHER END, and it is the one that only exists because both cases share
	-- a file. Armour stops at four because Config.Armor has four tiers; this is
	-- what says the column could not take a fifth even if it did.
	local armor = L.Tracks.armor
	t:eq(armor.slots, 4)
	local fifth = Config.trackButtonPosition("armor", 5)
	local firstWeapon = Config.trackButtonPosition("weapons", 1)
	t:near(fifth.Z, 12, EPS, "a fifth armour slot is not where firstZ and spacing put it")
	t:lt(fifth.Z, firstWeapon.Z,
		"a fifth armour slot lands past the first weapons pedestal, on the wrong side of the file")
	-- `apart` is a local rather than an expression inside :format because
	-- luau-analyze cannot type `firstWeapon.Z - fifth.Z` through the mock's
	-- Vector3 and pass 2 fails the build on it.
	local apart = math.abs(fifth.Z - firstWeapon.Z)
	t:lt(apart, L.CabinetSlotSpacing,
		("a fifth armour slot lands %g studs from the first weapons pedestal — inside the next cabinet's column, which needs %g")
			:format(apart, L.CabinetSlotSpacing))

	-- ...and the case behind it grows with it, into the weapons case.
	armor.slots = 5
	local armorCentre, armorSize = Config.trackCabinet("armor")
	local weaponsCentre, weaponsSize = Config.trackCabinet("weapons")
	t:gt(box(armorCentre, armorSize).maxZ, box(weaponsCentre, weaponsSize).minZ,
		"a five-slot armour case grows through the weapons case beside it")
end)

end
