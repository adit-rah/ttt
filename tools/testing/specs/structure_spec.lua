--[[
	structure_spec.lua — the building shell's span arithmetic.

	WHAT THIS FAMILY IS FOR. The mock is not BaseParts, CFrames or physics
	(tools/testing/mock/instance.lua), so nothing here builds a wall and looks at
	it. It does not need to: the shell's geometry was deliberately written as
	FUNCTIONS on Config rather than inlined in the builder, precisely so the same
	arithmetic the builder emits from can be read by a test. Config.wallSegments
	and Config.shellPartCount are pure scalar functions over Config.Structure,
	and that is the whole surface below.

	WHY IT IS NOT tools/verify_config.lua'S JOB. The verifier asserts these
	functions against the SHIPPED numbers — one plot size, two openings. That
	proves the functions agree with one table of values. It does not prove they
	are correct, because every degenerate case the shipped config happens not to
	contain is unchecked: a wall with two openings, an opening flush to the START
	of a wall, two openings that share an edge. Those are where span arithmetic
	actually breaks, so those are what this file feeds it. Several specs below
	therefore MUTATE Config.Structure.Openings — legal because T.world() builds a
	fresh realm with its own load of Config (tools/test.py's __newRealm), and
	asserted as legal by "a fresh realm's Config is untouched by another spec's
	mutation".

	THE BUG THIS FAMILY CLOSED, as a property. The walls were five boxes at a
	literal h = 13 under a roof at y = 20, so every plot had a seven-stud band of
	daylight all the way round and no check anywhere looked at it. Stated as a
	property that is: a wall's spans must account for its whole extent.

	EVERY LOOP COUNTS WHAT IT VISITED. A spec that iterates a list and asserts
	inside the loop passes for free when the list is empty, which is how a green
	spec ends up being evidence of nothing. Every loop below ends with an
	assertion on how many walls, runs or openings it actually saw.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL. Two specs in this project were found
	that could not, and a green spec over a wrong mock reads as evidence while
	being worse than nothing. Each spec below was watched failing under a broken
	copy of the function it guards, injected into its own realm's Config:
	wallSegments without the trailing run (the seven-stud band itself), with `>=`
	and `<=` so flush edges emit zero-width runs, openingsIn without its sort,
	shortened side walls, an opening moved off its wall, a 130-stud leaf with
	nothing to slide onto, and a constant shellPartCount. The counted numbers
	(six unbroken walls, nine runs, two openings) are what those failures
	printed, so they are here as oracles rather than as decoration — if one
	moves, someone changed the shell and this file is the second half of that
	change.
]]

return function(T)

T.family("structure", "the shell's spans must account for the whole wall, and no part may have a zero side")

local EPS = 1e-9

--- Every span in `spans` is contiguous, positive and covers `from`..`to`
--- exactly. This is the seven-stud-band property, and it is the reason
--- Config.wallSegments and Config.wallBays return lists rather than looping
--- internally.
local function tiles(t, spans, from: number, to: number, label: string)
	t:gte(#spans, 1, label .. ": no spans at all")
	if #spans == 0 then
		return
	end
	t:near(spans[1].from, from, EPS, label .. ": the first span does not start at the wall's start")
	t:near(spans[#spans].to, to, EPS, label .. ": the last span does not reach the wall's end")

	local sum = 0
	for index, span in ipairs(spans) do
		t:gt(span.to - span.from, 0,
			("%s: span %d (%s) has no width — that is a Vector3 with a 0 component"):format(
				label, index, tostring(span.kind)))
		sum += span.to - span.from
		if index > 1 then
			t:near(span.from, spans[index - 1].to, EPS,
				("%s: span %d does not start where span %d ended"):format(label, index, index - 1))
		end
	end
	t:near(sum, to - from, EPS, label .. ": the spans do not sum to the extent")
end

--- "solid|opening|solid" — the sequence, as one comparable string, so a failure
--- prints what the wall actually came back as.
local function kinds(spans): string
	local out = {}
	for _, span in ipairs(spans) do
		table.insert(out, span.kind)
	end
	return table.concat(out, "|")
end

--- The id of the opening at `index`, or nil. Nil-safe on purpose: an ordering
--- assertion must report "got nil, want \"a\"" rather than raise "index nil with
--- 'opening'" and hide behind a traceback.
local function idAt(spans, index: number)
	local span = spans[index]
	return span and span.opening and span.opening.id
end

--- An opening literal, in the shape Config.Structure.Openings holds. Centre and
--- width rather than from/to, because that is what the shipped table uses and a
--- test that reshapes its input is testing something else.
local function opening(id: string, side: string, from: number, to: number, leaves: number?)
	return {
		id = id, side = side,
		centre = (from + to) / 2, width = to - from,
		height = 13, leaves = leaves or 1,
	}
end

-- ── the wall, horizontally ──────────────────────────────────────────────────

T.spec("every wall tiles its extent exactly", function(t)
	local w = T.world()
	local Config = w.config

	local walls = 0
	for _, side in ipairs(Config.Structure.Sides) do
		local segments, extent = Config.wallSegments(side)
		t:notNil(extent, side .. ": no extent")
		tiles(t, segments, extent.from, extent.to, side)
		walls += 1
	end
	t:eq(walls, 4, "four sides — the loop must not have run dry")
end)

T.spec("a wall with no opening is one solid run, end to end", function(t)
	local w = T.world()
	local Config = w.config

	local blank = 0
	for _, side in ipairs(Config.Structure.Sides) do
		if #Config.openingsIn(side) == 0 then
			local segments, extent = Config.wallSegments(side)
			t:eq(kinds(segments), "solid", side .. ": an unbroken wall is not one run")
			-- guarded, so a wall that came back empty reports as a failed
			-- check rather than as "spec raised: index nil with 'from'"
			t:near(segments[1] and segments[1].from, extent.from, EPS, side)
			t:near(segments[1] and segments[1].to, extent.to, EPS, side)
			blank += 1
		end
	end
	-- Ships as: left and right. If this number moves, someone cut a new
	-- opening and should look at the rest of this file.
	t:eq(blank, 2, "the shipped shell has two unbroken walls")
end)

T.spec("the wall ring closes at all four corners", function(t)
	local w = T.world()
	local Config = w.config

	local back = Config.wallExtent("back")
	local front = Config.wallExtent("front")
	local left = Config.wallExtent("left")
	local right = Config.wallExtent("right")

	for _, pair in ipairs({ { "back", back }, { "front", front }, { "left", left }, { "right", right } }) do
		local side, extent = pair[1], pair[2]
		t:notNil(extent, side)
		t:lt(extent.from, extent.to, side .. ": the wall runs backwards")
		t:gt(extent.outward * extent.fixed, 0,
			side .. ": outward points into the plot, so the wall faces the wrong way")
	end

	-- The side walls run the FULL plot depth and the front and back sit between
	-- them, so the sides must reach at least the front/back planes and the
	-- front/back must reach at least the side planes. Fail either and the plot
	-- has an open corner — the same class of hole as the seven-stud band, just
	-- rotated 90 degrees.
	t:lte(left.from, back.fixed, "open corner: the left wall stops short of the back wall")
	t:gte(left.to, front.fixed, "open corner: the left wall stops short of the front wall")
	t:lte(right.from, back.fixed, "open corner: the right wall stops short of the back wall")
	t:gte(right.to, front.fixed, "open corner: the right wall stops short of the front wall")
	t:lte(front.from, left.fixed, "open corner: the front wall stops short of the left wall")
	t:gte(front.to, right.fixed, "open corner: the front wall stops short of the right wall")
	t:lte(back.from, left.fixed, "open corner: the back wall stops short of the left wall")
	t:gte(back.to, right.fixed, "open corner: the back wall stops short of the right wall")

	t:isNil(Config.wallExtent("ceiling"), "a side nobody defined must be nil, not a guess")
end)

-- ── the wall, against openings the shipped config does not contain ──────────
--
-- These four mutate this spec's OWN realm's Config. See the isolation spec
-- below, which is what makes that safe rather than merely convenient.

T.spec("openings come back in wall order, however they were entered", function(t)
	local w = T.world()
	local Config = w.config

	-- Entered right-to-left on purpose: openingsIn sorts, and nothing else in
	-- the shipped config has two openings in one wall to sort.
	table.insert(Config.Structure.Openings, opening("far", "left", 20, 32))
	table.insert(Config.Structure.Openings, opening("near", "left", -32, -20))

	local found = Config.openingsIn("left")
	t:eq(#found, 2, "both openings should be in this wall")
	t:eq(found[1].id, "near", "the openings came back in insertion order, not wall order")
	t:eq(found[2].id, "far")
	t:lt(found[1].centre, found[2].centre)

	t:eq(#Config.openingsIn("right"), 0, "an opening leaked between sides")
end)

T.spec("two openings give solid/opening/solid/opening/solid", function(t)
	local w = T.world()
	local Config = w.config

	-- entered far-then-near again, so this spec fails if the ordering fails
	table.insert(Config.Structure.Openings, opening("b", "left", 24, 36))
	table.insert(Config.Structure.Openings, opening("a", "left", -36, -24))

	local segments, extent = Config.wallSegments("left")
	t:eq(kinds(segments), "solid|opening|solid|opening|solid",
		"a wall with two openings must alternate, in wall order")
	tiles(t, segments, extent.from, extent.to, "left with two openings")

	t:near(segments[2] and segments[2].from, -36, EPS)
	t:near(segments[2] and segments[2].to, -24, EPS)
	t:eq(idAt(segments, 2), "a", "the segments are not in wall order")
	t:eq(idAt(segments, 4), "b")
	t:near(segments[3] and segments[3].from, -24, EPS, "the middle run must start at the first opening's far edge")
	t:near(segments[3] and segments[3].to, 24, EPS, "the middle run must end at the second opening's near edge")
	t:isNil(idAt(segments, 1), "a solid run must not carry an opening")
end)

T.spec("an opening flush to either end leaves no zero-width run", function(t)
	local w = T.world()
	local Config = w.config

	-- Flush to the END ships already: the yard doorway runs to the back wall's
	-- far edge, so `cursor < extent.to` is false and there is no trailing run.
	local back, backExtent = Config.wallSegments("back")
	t:eq(kinds(back), "solid|opening", "the yard doorway is flush to the wall end")
	t:near(back[#back] and back[#back].to, backExtent.to, EPS)
	tiles(t, back, backExtent.from, backExtent.to, "back")

	-- Flush to the START does not ship, and is the mirror-image bug: a leading
	-- solid run of width 0, which is a BasePart with a zero-length side.
	local extent = Config.wallExtent("left")
	table.insert(Config.Structure.Openings, opening("start", "left", extent.from, extent.from + 18))
	local left = Config.wallSegments("left")
	t:eq(kinds(left), "opening|solid", "a flush opening produced a zero-width leading run")
	tiles(t, left, extent.from, extent.to, "left flush to the start")

	-- And a wall that is entirely one opening is one segment, not three.
	table.insert(Config.Structure.Openings, opening("all", "right", extent.from, extent.to))
	local right = Config.wallSegments("right")
	t:eq(kinds(right), "opening", "a fully open wall must be exactly one opening span")
	tiles(t, right, extent.from, extent.to, "right fully open")
end)

T.spec("openings that share an edge leave no zero-width solid", function(t)
	local w = T.world()
	local Config = w.config

	local extent = Config.wallExtent("left")
	table.insert(Config.Structure.Openings, opening("one", "left", extent.from, extent.from + 30))
	table.insert(Config.Structure.Openings, opening("two", "left", extent.from + 30, extent.from + 60))

	local segments = Config.wallSegments("left")
	t:eq(kinds(segments), "opening|opening|solid",
		"two openings meeting at a stud must not have a zero-width pier between them")
	tiles(t, segments, extent.from, extent.to, "left, openings sharing an edge")
	t:eq(idAt(segments, 1), "one")
	t:eq(idAt(segments, 2), "two")
end)

T.spec("every opening lies inside the wall it cuts, with a lintel above", function(t)
	local w = T.world()
	local Config = w.config

	local seen = 0
	for _, entry in ipairs(Config.Structure.Openings) do
		local extent = Config.wallExtent(entry.side)
		t:notNil(extent, entry.id .. ": names a side that does not exist")
		t:gt(entry.width, 0, entry.id .. ": an opening with no width")
		t:gte(entry.centre - entry.width / 2, extent.from - EPS,
			entry.id .. ": the opening starts outside its wall")
		t:lte(entry.centre + entry.width / 2, extent.to + EPS,
			entry.id .. ": the opening ends outside its wall")
		t:gt(entry.height, 0, entry.id .. ": an opening with no height")
		t:lt(entry.height, Config.Structure.WallHeight,
			entry.id .. ": no room for a lintel — the opening is as tall as the wall")
		t:gte(entry.leaves, 1, entry.id .. ": an opening with no door")
		seen += 1
	end
	t:eq(seen, 2, "the gateway and the yard doorway")
end)

T.spec("a gate leaf has a solid run to slide along", function(t)
	-- Config.Structure.Gate: "travel is one leaf width, so the solid run beside
	-- an opening has to be at least that long". A leaf that slides into the void
	-- beside the wall is a door that vanishes when it opens.
	local w = T.world()
	local Config = w.config

	local openings = 0
	do
		for _, side in ipairs(Config.Structure.Sides) do
			local segments = Config.wallSegments(side)
			for index, segment in ipairs(segments) do
				if segment.kind == "opening" then
					local leaf = (segment.to - segment.from) / segment.opening.leaves
					local widest = 0
					for _, neighbour in ipairs({ segments[index - 1], segments[index + 1] }) do
						if neighbour and neighbour.kind == "solid" then
							widest = math.max(widest, neighbour.to - neighbour.from)
						end
					end
					t:gte(widest, leaf,
						("%s: no solid run long enough for a %g-stud leaf to slide onto"):format(
							segment.opening.id, leaf))
					openings += 1
				end
			end
		end
	end
	t:eq(openings, 2, "both shipped openings must have been visited")
end)

T.spec("a fresh realm's Config is untouched by another spec's mutation", function(t)
	-- The licence for every mutation above. T.world() builds a realm — its own
	-- load of the module tree, its own Config table (tools/test.py __newRealm) —
	-- so an opening pushed into one spec's Openings must not exist in the next.
	-- If this spec ever fails, the mutating specs above are cross-contaminating
	-- and the whole family is unsound.
	local first = T.world()
	local second = T.world()

	t:ne(first.config, second.config, "two worlds share one Config table")
	t:ne(first.config.Structure.Openings, second.config.Structure.Openings,
		"two worlds share one Openings table")

	-- Five specs above have already pushed openings into their own realms.
	t:eq(#first.config.Structure.Openings, 2,
		"an earlier spec's opening leaked into this realm")
	t:eq(#first.config.openingsIn("left"), 0,
		"an earlier spec's opening leaked into this realm")

	table.insert(first.config.Structure.Openings, opening("leak", "right", -10, 10))
	t:eq(#first.config.openingsIn("right"), 1, "the mutation did not take")
	t:eq(#second.config.openingsIn("right"), 0,
		"a mutation in one realm reached another realm's Config")

	-- and a realm built AFTER the mutation is clean too
	local third = T.world()
	t:eq(#third.config.Structure.Openings, 2, "the mutation leaked forward into a new realm")
	t:eq(#third.config.openingsIn("right"), 0)
end)

-- ── the courses, vertically ─────────────────────────────────────────────────

T.spec("the three courses stack to the wall's top with a head course left", function(t)
	local w = T.world()
	local Config = w.config
	local course = Config.Structure.Course

	t:gt(Config.Structure.WallHeight, 0, "a shell with no height")
	t:gt(course.sill, 0, "a sill course with no height cannot be a repair stump")
	t:gt(course.body, 0, "a body course with no height")
	t:lt(course.sill + course.body, Config.Structure.WallHeight,
		"no room for a head course — the body reaches the top of the wall")
end)

-- ── the part budget ─────────────────────────────────────────────────────────

T.spec("shellPartCount is three courses a run, and is stable", function(t)
	local w = T.world()
	local Config = w.config

	-- An independent model of the same total, from the documented per-course
	-- claim ("per solid run: a sill, body and head course") rather than from
	-- shellPartCount's own loop.
	--
	-- The per-side trim is here because two per-side parts were MISSING from
	-- shellPartCount when this spec was first written: it modelled the wall
	-- spec rather than what the builder emits, and reported 59 against 68
	-- actually built. A budget asserted 13% under the truth is a budget that
	-- passes right up until it matters.
	local function model()
		-- The buttress and torch counts are re-derived from the pitch
		-- arithmetic rather than read from the position functions, so this
		-- stays a second opinion: a placement that dropped a run or doubled
		-- a corner would agree with itself and disagree here. Buttresses are
		-- corner-anchored per WALL (#162 tophat): count+1 posts across the
		-- extent, minus any whose footprint lands in an opening plus jamb.
		local B, T = Config.Structure.Buttress, Config.Structure.Torch
		local function torchCount(run)
			local usable = run - 2 * (T.clearance + T.bracket[1] / 2)
			if usable < 0 then
				return 0
			end
			return math.floor(usable / T.spacing) + 1
		end
		local function buttressCount(side)
			local extent = select(2, Config.wallSegments(side))
			local length = extent.to - extent.from
			local count = math.max(1, math.floor(length / B.spacing + 0.5))
			local pitch = length / count
			local posts = 0
			for index = 0, count do
				local post = extent.from + index * pitch
				local blocked = false
				for _, opening in ipairs(Config.openingsIn(side)) do
					local from = opening.centre - opening.width / 2 - B.clearance - B.width / 2
					local to = opening.centre + opening.width / 2 + B.clearance + B.width / 2
					if post > from and post < to then
						blocked = true
					end
				end
				posts += blocked and 0 or 1
			end
			return posts
		end
		local total, runs, cuts = 0, 0, 0
		for _, side in ipairs(Config.Structure.Sides) do
			total += 1   -- this wall's trim cap
			total += buttressCount(side)
			for _, segment in ipairs(Config.wallSegments(side)) do
				if segment.kind == "solid" then
					total += 3   -- sill + body + head
					total += 2 * torchCount(segment.to - segment.from)
					runs += 1
				else
					total += 1 + segment.opening.leaves   -- lintel + leaves
					cuts += 1
				end
			end
		end
		return total, runs, cuts
	end

	local full, runs, cuts = model()
	t:eq(Config.shellPartCount(), full, "shellPartCount disagrees with three courses a run")
	t:eq(runs, 5, "five solid runs around the ring")
	t:eq(cuts, 2, "the gateway and the yard doorway")

	t:eq(Config.shellPartCount(), Config.shellPartCount(),
		"counting twice gave two answers — something accumulates across calls")

	t:lte(Config.shellPartCount(), Config.Structure.PartBudget,
		"the full shell is over Config.Structure.PartBudget")
end)

T.spec("shellPartCount answers to inputs the shipped config never has", function(t)
	-- The verifier checks the shipped total against the budget. That passes just
	-- as well if shellPartCount ignores half its inputs, so: move the inputs.
	local w = T.world()
	local Config = w.config
	local base = Config.shellPartCount()

	table.insert(Config.Structure.Openings, opening("sideDoor", "left", -7, 7))
	local withDoor = Config.shellPartCount()
	t:ne(withDoor, base, "cutting a third opening did not change the part count")
	t:lte(withDoor, Config.Structure.PartBudget,
		"a third opening puts the shell over budget")

	-- The delta is exact: the left wall's one run (3 courses) becomes two runs
	-- (6) plus a lintel and a single leaf — +5 — and each new run re-derives
	-- its own buttress and torch counts from the pitch arithmetic.
	local B, T = Config.Structure.Buttress, Config.Structure.Torch
	local function postCount(run, spacing, clearance)
		local usable = run - 2 * clearance
		return usable >= 0 and math.floor(usable / spacing) + 1 or 0
	end
	local function torches(run)
		return 2 * postCount(run, T.spacing, T.clearance + T.bracket[1] / 2)
	end
	-- The torches re-derive per run; the buttresses are corner-anchored per
	-- WALL, so the door costs any post whose footprint its span (plus jamb)
	-- swallows — on the shipped pitch, the one at the wall's centre.
	local extent = Config.wallExtent("left")
	local length = extent.to - extent.from
	local count = math.max(1, math.floor(length / B.spacing + 0.5))
	local swallowed = 0
	for index = 0, count do
		local post = extent.from + index * (length / count)
		if post > -7 - B.clearance - B.width / 2 and post < 7 + B.clearance + B.width / 2 then
			swallowed += 1
		end
	end
	local dressingDelta = torches(-7 - extent.from) + torches(extent.to - 7)
		- torches(length) - swallowed
	t:eq(withDoor, base + 5 + dressingDelta,
		"a third opening's cost is one extra run of courses, a lintel, its leaf, and the re-derived dressing")

	-- ...and the count moves with the LAND, because the front and back walls
	-- split their runs at every owned boundary.
	t:gt(Config.shellPartCount(1, 1), base,
		"a grown plot's shell counts the same as the bare one — the land splits are not being counted")
end)

-- ── the shell as its own track ──────────────────────────────────────────────

T.spec("the shell is walls, gates, then the masonry, on a track of its own", function(t)
	-- The ORDER IS THE TABLE ORDER — the loader derives `requires` from it and
	-- nothing else states the dependency. INVARIANTS.md marks that [nothing],
	-- and this is half of what closes it; the other half is a config check.
	--
	-- THE TRACK IS `structure` AND IT USED TO BE `factory`, where the shell's
	-- rows were welded into the chain and blocking. They are a parallel ladder
	-- now, gated as a whole on `dropper1`.
	local w = T.world()
	local Config = w.config

	local seen = {}
	local structures = 0
	for _, def in ipairs(Config.Tracks.structure) do
		t:eq(def.kind, "Structure",
			("%s is on the structure track and is not a Structure row"):format(def.id))
		seen[def.structure] = def.trackOrder
		structures += 1
	end
	t:eq(structures, 6, "walls, gates, and the four masonry tiers")

	-- ...and nothing was left behind on the spine. A Structure row still sitting
	-- in FactoryButtons would be a piece of building blocking the line, which is
	-- the entire defect this split was for.
	for _, def in ipairs(Config.Tracks.factory) do
		t:isTrue(def.kind ~= "Structure",
			("%s is a Structure row still on the factory track — the shell is not supposed to block the line any more"):format(def.id))
	end

	t:notNil(seen.walls)
	t:gt(seen.gates, seen.walls, "gates hang on the wall ring, so they cannot precede it")

	-- The chain the loader derives, end to end: each names the one before it
	-- without any of them saying so in Config, and the FIRST one names nothing.
	-- A root that carried a requirement would be a ladder nothing can start.
	t:isNil(Config.ButtonById.walls.requires,
		"walls is the root of the structure track; a root with a requirement is a track nothing can start")
	t:eq(Config.ButtonById.gates.requires, "walls",
		"the derived chain no longer runs walls -> gates")
	t:eq(Config.ButtonById.cobble.requires, "gates",
		"the derived chain no longer runs gates -> cobble")
	t:eq(Config.ButtonById.stone.requires, "cobble",
		"the derived chain no longer runs cobble -> stone")
	t:eq(Config.ButtonById.slate.requires, "stone",
		"the derived chain no longer runs stone -> slate")
	t:eq(Config.ButtonById.stonebrick.requires, "slate",
		"the derived chain no longer runs slate -> stonebrick")

	-- ...and the Tiers list walks the same chain in the same order, because
	-- masonryTiers counts the list against `owned`.
	for index, tier in ipairs(Config.Structure.Tiers) do
		t:eq(tier.structure, Config.Tracks.structure[index + 2].structure,
			("Structure.Tiers[%d] disagrees with the track's rung %d"):format(index, index + 2))
	end

	-- The whole ladder waits on the first dropper, so the shell can never be
	-- somebody's opening purchase.
	t:eq(Config.TrackUnlock.structure, "dropper1",
		"the structure track is meant to open one purchase in, not on claim")
	t:isFalse(Config.trackUnlocked("structure", {}),
		"a plot that has bought nothing must not be offered Plot Walls")
	t:isTrue(Config.trackUnlocked("structure", { dropper1 = true }),
		"one dropper in, the building becomes something you can want")
end)

T.spec("a plot owns the leaves only while it owns the wall they hang on", function(t)
	-- Tycoon:hasStructure is derived from `owned` rather than stored, and this is
	-- the reason: rebirth wipes the structure track, so it takes `walls` AND
	-- `gates` together. A stored flag would survive it and leave a plot claiming
	-- doors with no shell to hang them in — the same failure the sticky cabinet
	-- gate exists to prevent, one purchase over.
	local w = T.world()
	local Tycoon = w.req("Tycoon")

	local bare = { owned = {} }
	t:isFalse(Tycoon.hasStructure(bare, "walls"))
	t:isFalse(Tycoon.hasStructure(bare, "gates"))

	local gated = { owned = { walls = true, gates = true } }
	t:isTrue(Tycoon.hasStructure(gated, "walls"))
	t:isTrue(Tycoon.hasStructure(gated, "gates"))

	-- It answers about the STRUCTURE, not the id, so a plot that owns a dropper
	-- of the same name would not be gated by it.
	local partial = { owned = { walls = true, dropper1 = true } }
	t:isTrue(Tycoon.hasStructure(partial, "walls"))
	t:isFalse(Tycoon.hasStructure(partial, "gates"),
		"a plot with walls and no gates is reporting doors it never bought")

	-- An id that is not a button at all must not answer true for anything.
	local junk = { owned = { not_a_button = true } }
	t:isFalse(Tycoon.hasStructure(junk, "walls"),
		"an owned id with no Config row is being treated as a structure")
end)

T.spec("a masonry tier restyles the standing ring and adds no parts", function(t)
	-- The glazing mechanism generalised (#162): applyMasonry walks the ring
	-- and changes Material/Color on the wall's own parts. What is pinned:
	-- the count is derived from `owned`, the restyle touches courses, lintels
	-- and buttresses and NOTHING else, and the part count never moves — the
	-- whole PartBudget argument is tier-blind because of this spec.
	local w = T.world()
	local Config = w.config
	local Tycoon = w.req("Tycoon")

	local function plot(owned)
		return setmetatable({ owned = owned }, { __index = Tycoon })
	end

	t:eq(plot({}):masonryTiers(), 0, "a bare plot wears a tier")
	t:eq(plot({ walls = true, gates = true, cobble = true }):masonryTiers(), 1)
	t:eq(plot({ walls = true, gates = true, cobble = true, stone = true,
		slate = true, stonebrick = true }):masonryTiers(), 4, "the whole ladder is four tiers")
	t:eq(plot({ cobble = true, dropper1 = true }):masonryTiers(), 1,
		"masonryTiers answers about structures, so an unrelated id counts nothing")

	local ring = Instance.new("Model")
	local function part(name)
		local p = Instance.new("Part")
		p.Name = name
		p.Parent = ring
		return p
	end
	local body = part("Body_front_1")
	local sill = part("Sill_front_1")
	part("Buttress_left_2")
	part("Lintel_front_2")
	local trim = part("Trim_front")
	local leaf = part("Gate_gateway_1")
	part("Torch_left_1")
	trim.Material = Enum.Material.Wood
	leaf.Material = Enum.Material.WoodPlanks

	local stone = plot({ walls = true, gates = true, cobble = true, stone = true })
	local before = #ring:GetChildren()
	local restyled = stone:applyMasonry(ring)
	t:eq(#ring:GetChildren(), before,
		"the restyle moved the part count — the budget argument just broke")
	t:eq(restyled, 4,
		"the two courses, the lintel and the buttress restyle; the trim, the leaf and the torch keep their timber")
	local tier = Config.Structure.Tiers[2]
	t:eq(body.Material, Enum.Material[tier.material], "the body course missed the stone")
	t:eq(sill.Color, tier.color, "the sill course missed the colour")
	t:eq(trim.Material, Enum.Material.Wood, "the trim went stone")
	t:eq(leaf.Material, Enum.Material.WoodPlanks,
		"the gate leaf went stone — a stone door reads as more wall")

	-- Tier 0 is the wooden default, so a ring rebuilt after a rebirth
	-- restyles back down with no special case.
	plot({}):applyMasonry(ring)
	t:eq(body.Material, Enum.Material.WoodPlanks, "a bare plot's ring must wear wood")
end)

-- ── the purchase surface is three categories ────────────────────────────────

T.spec("every button carries a category ordinal the width of its category", function(t)
	-- #125: a pad says "PLOT 20/34", counting across the three plot chains.
	-- The ordinals must tile each category — a gap or a duplicate is a pad
	-- lying about how much game is left.
	local w = T.world()
	local Config = w.config

	local seen = {}
	for _, def in ipairs(Config.Buttons) do
		t:notNil(def.category, def.id .. " has no category")
		t:notNil(def.categoryOrder, def.id .. " has no category ordinal")
		seen[def.category] = seen[def.category] or {}
		t:isNil(seen[def.category][def.categoryOrder],
			("%s repeats ordinal %d in %s"):format(def.id, def.categoryOrder, def.category))
		seen[def.category][def.categoryOrder] = true
	end
	for category, count in pairs(Config.CategoryCount) do
		for ordinal = 1, count do
			t:notNil(seen[category] and seen[category][ordinal],
				("%s is missing ordinal %d of %d"):format(category, ordinal, count))
		end
	end
	t:eq(Config.CategoryCount.plot, 36, "the plot category is structure's 6 plus thirty land rows")
	t:eq(Config.CategoryCount.conveyor, 17, "the conveyor category is the factory chain")
end)

-- ── the shell does not survive a rebirth, and must not ──────────────────────

T.spec("a rebirth takes the whole shell down and every rung of it is buyable again", function(t)
	-- THIS IS A TRACE OF A BUG THAT WOULD BE PERMANENT AND SILENT, written as a
	-- test because nothing else in the repo can see it.
	--
	-- TrackInfo.structure.keepOnRebirth is false. If it were true:
	-- Tycoon:rebirth keeps the track's ids in `profile.owned`, SKIPS clearing their
	-- entry.machine handles because the skip is keyed on the same flag, and then
	-- calls self.machines:ClearAllChildren() anyway — which destroys the wall
	-- ring, because the ring is parented to self.machines and not to the
	-- self.props folder the exemption is actually about. refreshButtons then
	-- reads owned.walls == true and unparents the pad. The plot has no shell,
	-- cannot buy one, and stays that way for the rest of that owner's session.
	--
	-- The verifier asserts keepOnRebirth == (furniture == "cabinet") from the
	-- config side. This is the behavioural half: it runs the real rebirth.
	local w = T.world()
	local Config = w.config
	local Data = w.req("DataService")
	local Tycoon = w.req("Tycoon")

	local player = w.join("rebuilder")
	local profile = Data.load(player)

	local cleared = 0
	local plot = setmetatable({}, { __index = Tycoon })
	plot.owner = player
	plot.owned = {}
	plot.objects = {}
	plot.generation = 0
	plot.beltBonus, plot.powerFactor = 0, 1
	plot.machines = { ClearAllChildren = function() cleared += 1 end }
	plot.refreshBeltSpeed = function() end
	plot.refreshButtons = function() end
	plot.updateSign = function() end
	plot.fireOwnedChanged = function() end
	plot.clearDrops = function() end

	-- Own the entire shell plus a weapons tier, so the assertion below
	-- distinguishes "a rebirth wipes everything" from "a rebirth wipes the
	-- right things". A spec where all the ids vanish proves much less.
	local shell = {}
	for _, def in ipairs(Config.Tracks.structure) do
		table.insert(shell, def.id)
		profile.owned[def.id] = true
		plot.owned[def.id] = true
		plot.objects[def.id] = { def = def, machine = { name = def.id } }
	end
	local bat = Config.Tracks.weapons[1]
	profile.owned[bat.id] = true
	plot.owned[bat.id] = true
	plot.objects[bat.id] = { def = bat, machine = { name = bat.id } }
	profile.owned.dropper1 = true
	plot.owned.dropper1 = true

	profile.cash = 60e9
	t:isTrue(plot:rebirth(player), "the rebirth was refused, so this proves nothing")

	t:eq(cleared, 1, "self.machines was never cleared, so the wall ring is still standing")
	for _, id in ipairs(shell) do
		t:isNil(profile.owned[id],
			("%s survived a rebirth; the wall ring it refers to was just destroyed, so the pad would hide itself for a building that is not there"):format(id))
		t:isNil(plot.owned[id],
			("the plot still thinks it owns %s after a rebirth"):format(id))
		t:isNil(plot.objects[id].machine,
			("%s kept its machine handle through a rebirth; the model is destroyed and the reference outlives it"):format(id))
	end

	-- ...and the bat did not go with it. keepOnRebirth is not "wipe everything".
	t:isTrue(profile.owned[bat.id],
		"the rebirth took a weapons tier, which is the coupling the track split exists to remove")
	t:notNil(plot.objects[bat.id].machine,
		"a cabinet prop lost its handle; those live in self.props and are not cleared")

	-- The gate is sticky for the cabinets and NOT for the shell, and both of
	-- those are load-bearing. The shell has to be re-offered from scratch.
	t:isFalse(Config.trackUnlocked("structure", plot.owned),
		"the structure track stayed open after a rebirth wiped the dropper that gates it")
	t:isTrue(Config.trackUnlocked("weapons", plot.owned),
		"the weapons cabinet closed on a rebirth, leaving the granted bat with no cabinet")
end)

end
