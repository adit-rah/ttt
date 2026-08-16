--[[
	structure_spec.lua — the building shell's span arithmetic.

	WHAT THIS FAMILY IS FOR. The mock is not BaseParts, CFrames or physics
	(tools/testing/mock/instance.lua), so nothing here builds a wall and looks at
	it. It does not need to: the shell's geometry was deliberately written as
	FUNCTIONS on Config rather than inlined in the builder, precisely so the same
	arithmetic the builder emits from can be read by a test. Config.wallSegments,
	Config.wallBays, Config.roofUnderside and Config.shellPartCount are pure
	scalar functions over Config.Structure, and that is the whole surface below.

	WHY IT IS NOT tools/verify_config.lua'S JOB. The verifier asserts these
	functions against the SHIPPED numbers — one plot size, two openings, one
	window spec. That proves the functions agree with one table of values. It does
	not prove they are correct, because every degenerate case the shipped config
	happens not to contain is unchecked: a wall with two openings, an opening
	flush to the START of a wall, two openings that share an edge, a solid run one
	stud too short for a pane. Those are where span arithmetic actually breaks, so
	those are what this file feeds it. Several specs below therefore MUTATE
	Config.Structure.Openings — legal because T.world() builds a fresh realm with
	its own load of Config (tools/test.py's __newRealm), and asserted as legal by
	"a fresh realm's Config is untouched by another spec's mutation".

	THE BUG THIS ROUND CLOSED, as a property. The walls were five boxes at a
	literal h = 13 under a roof at y = 20, so every plot had a seven-stud band of
	daylight all the way round and no check anywhere looked at it. Stated as a
	property that is: a wall's spans must account for its whole extent, and a
	storey's wall must stop exactly at the floor above it. Both are specs here —
	the first horizontally, the second vertically (the deck's UNDERSIDE, not its
	middle; that number was briefly wrong by half a thickness while the contract
	was being written, and half a thickness is a wall ending inside the floor
	above it).

	EVERY LOOP COUNTS WHAT IT VISITED. A spec that iterates a list and asserts
	inside the loop passes for free when the list is empty, which is how a green
	spec ends up being evidence of nothing. Every loop below ends with an
	assertion on how many walls, runs, bays or openings it actually saw.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL. Two specs in this project were found
	that could not, and a green spec over a wrong mock reads as evidence while
	being worse than nothing. Each of the nineteen below was watched failing under
	a broken copy of the function it guards, injected into its own realm's Config:
	wallSegments without the trailing run (the seven-stud band itself), with `>=`
	and `<=` so flush edges emit zero-width runs, openingsIn without its sort,
	wallBays with the slack all on the last pier / counting panes as
	floor(length / (pane+pier)) / guarding on `panes < 0` / dropping the leading
	pier / never glazing, roofUnderside ignoring the mezzanine, the ground storey
	at half a deck thickness, a 30-stud window, shortened side walls, an opening
	moved off its wall, a 130-stud leaf with nothing to slide onto, a constant
	shellPartCount, and glass at 0.1. The counted numbers (six unbroken walls,
	nine runs, two openings) are what those failures printed, so they are here as
	oracles rather than as decoration — if one moves, someone changed the shell
	and this file is the second half of that change.

	ONE THING RUNTIME CANNOT SEE. Storeys[1].clear is asserted equal to
	`Floors[1].height - deckSize.Y`, which catches the deck MOVING, but a literal
	20.4 typed in its place would pass — the derivation itself is only visible in
	the source. That check belongs to review, not here.
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

local function countKind(spans, kind: string): number
	local n = 0
	for _, span in ipairs(spans) do
		if span.kind == kind then
			n += 1
		end
	end
	return n
end

--- An opening literal, in the shape Config.Structure.Openings holds. Centre and
--- width rather than from/to, because that is what the shipped table uses and a
--- test that reshapes its input is testing something else.
local function opening(id: string, side: string, storey: string, from: number, to: number, leaves: number?)
	return {
		id = id, side = side, storey = storey,
		centre = (from + to) / 2, width = to - from,
		height = 13, leaves = leaves or 1,
	}
end

local STOREYS = { "ground", "upper" }

-- ── the wall, horizontally ──────────────────────────────────────────────────

T.spec("every wall of both storeys tiles its extent exactly", function(t)
	local w = T.world()
	local Config = w.config

	local walls = 0
	for _, storey in ipairs(STOREYS) do
		for _, side in ipairs(Config.Structure.Sides) do
			local segments, extent = Config.wallSegments(side, storey)
			t:notNil(extent, side .. ": no extent")
			tiles(t, segments, extent.from, extent.to, side .. "/" .. storey)
			walls += 1
		end
	end
	t:eq(walls, 8, "four sides times two storeys — the loop must not have run dry")
end)

T.spec("a wall with no opening is one solid run, end to end", function(t)
	local w = T.world()
	local Config = w.config

	local blank = 0
	for _, storey in ipairs(STOREYS) do
		for _, side in ipairs(Config.Structure.Sides) do
			if #Config.openingsIn(side, storey) == 0 then
				local segments, extent = Config.wallSegments(side, storey)
				local label = side .. "/" .. storey
				t:eq(kinds(segments), "solid", label .. ": an unbroken wall is not one run")
				-- guarded, so a wall that came back empty reports as a failed
				-- check rather than as "spec raised: index nil with 'from'"
				t:near(segments[1] and segments[1].from, extent.from, EPS, label)
				t:near(segments[1] and segments[1].to, extent.to, EPS, label)
				blank += 1
			end
		end
	end
	-- Ships as: left/right ground, and all four upper. If this number moves,
	-- someone cut a new opening and should look at the rest of this file.
	t:eq(blank, 6, "the shipped shell has six unbroken walls")
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
	t:isNil(Config.storey("basement"), "a storey nobody defined must be nil")
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
	table.insert(Config.Structure.Openings, opening("far", "left", "ground", 20, 32))
	table.insert(Config.Structure.Openings, opening("near", "left", "ground", -32, -20))

	local found = Config.openingsIn("left", "ground")
	t:eq(#found, 2, "both openings should be in this wall")
	t:eq(found[1].id, "near", "the openings came back in insertion order, not wall order")
	t:eq(found[2].id, "far")
	t:lt(found[1].centre, found[2].centre)

	-- and the other storey of the same side is unaffected
	t:eq(#Config.openingsIn("left", "upper"), 0, "an opening leaked between storeys")
	t:eq(#Config.openingsIn("right", "ground"), 0, "an opening leaked between sides")
end)

T.spec("two openings give solid/opening/solid/opening/solid", function(t)
	local w = T.world()
	local Config = w.config

	-- entered far-then-near again, so this spec fails if the ordering fails
	table.insert(Config.Structure.Openings, opening("b", "left", "ground", 24, 36))
	table.insert(Config.Structure.Openings, opening("a", "left", "ground", -36, -24))

	local segments, extent = Config.wallSegments("left", "ground")
	t:eq(kinds(segments), "solid|opening|solid|opening|solid",
		"a wall with two openings must alternate, in wall order")
	tiles(t, segments, extent.from, extent.to, "left/ground with two openings")

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
	local back, backExtent = Config.wallSegments("back", "ground")
	t:eq(kinds(back), "solid|opening", "the yard doorway is flush to the wall end")
	t:near(back[#back] and back[#back].to, backExtent.to, EPS)
	tiles(t, back, backExtent.from, backExtent.to, "back/ground")

	-- Flush to the START does not ship, and is the mirror-image bug: a leading
	-- solid run of width 0, which is a BasePart with a zero-length side.
	local extent = Config.wallExtent("left")
	table.insert(Config.Structure.Openings, opening("start", "left", "ground", extent.from, extent.from + 18))
	local left = Config.wallSegments("left", "ground")
	t:eq(kinds(left), "opening|solid", "a flush opening produced a zero-width leading run")
	tiles(t, left, extent.from, extent.to, "left/ground flush to the start")

	-- And a wall that is entirely one opening is one segment, not three.
	table.insert(Config.Structure.Openings, opening("all", "right", "ground", extent.from, extent.to))
	local right = Config.wallSegments("right", "ground")
	t:eq(kinds(right), "opening", "a fully open wall must be exactly one opening span")
	tiles(t, right, extent.from, extent.to, "right/ground fully open")
end)

T.spec("openings that share an edge leave no zero-width solid", function(t)
	local w = T.world()
	local Config = w.config

	local extent = Config.wallExtent("left")
	table.insert(Config.Structure.Openings, opening("one", "left", "ground", extent.from, extent.from + 30))
	table.insert(Config.Structure.Openings, opening("two", "left", "ground", extent.from + 30, extent.from + 60))

	local segments = Config.wallSegments("left", "ground")
	t:eq(kinds(segments), "opening|opening|solid",
		"two openings meeting at a stud must not have a zero-width pier between them")
	tiles(t, segments, extent.from, extent.to, "left/ground, openings sharing an edge")
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
		local storey = Config.storey(entry.storey)
		t:notNil(storey, entry.id .. ": names a storey that does not exist")

		t:gt(entry.width, 0, entry.id .. ": an opening with no width")
		t:gte(entry.centre - entry.width / 2, extent.from - EPS,
			entry.id .. ": the opening starts outside its wall")
		t:lte(entry.centre + entry.width / 2, extent.to + EPS,
			entry.id .. ": the opening ends outside its wall")
		t:gt(entry.height, 0, entry.id .. ": an opening with no height")
		t:lt(entry.height, storey.clear,
			entry.id .. ": no room for a lintel — the opening is as tall as the storey")
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
	for _, storey in ipairs(STOREYS) do
		for _, side in ipairs(Config.Structure.Sides) do
			local segments = Config.wallSegments(side, storey)
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
	t:eq(#first.config.openingsIn("left", "ground"), 0,
		"an earlier spec's opening leaked into this realm")

	table.insert(first.config.Structure.Openings, opening("leak", "right", "upper", -10, 10))
	t:eq(#first.config.openingsIn("right", "upper"), 1, "the mutation did not take")
	t:eq(#second.config.openingsIn("right", "upper"), 0,
		"a mutation in one realm reached another realm's Config")

	-- and a realm built AFTER the mutation is clean too
	local third = T.world()
	t:eq(#third.config.Structure.Openings, 2, "the mutation leaked forward into a new realm")
	t:eq(#third.config.openingsIn("right", "upper"), 0)
end)

-- ── the bay course ──────────────────────────────────────────────────────────

T.spec("wallBays tiles its run, pier first, pier last, alternating", function(t)
	local w = T.world()
	local Config = w.config
	local window = Config.Structure.Window

	-- Shipped run lengths and then some the shipped config has never produced,
	-- including fractional ones and a run offset off the origin.
	local runs = {
		{ -59, 46 }, { -59, 3 }, { 25, 59 }, { -70, 70 },     -- as shipped
		{ 0, 32 }, { 0, 33.5 }, { -13.25, 88.75 }, { 100, 420 }, { -400, -399.5 },
	}

	local checked, withPanes = 0, 0
	for _, run in ipairs(runs) do
		local from, to = run[1], run[2]
		local bays = Config.wallBays(from, to)
		local label = ("run %g..%g"):format(from, to)

		tiles(t, bays, from, to, label)
		t:eq(bays[1].kind, "pier", label .. ": a bay course must start on a pier")
		t:eq(bays[#bays].kind, "pier", label .. ": a bay course must end on a pier")
		t:eq(#bays % 2, 1, label .. ": pier-first pier-last means an odd number of bays")

		local panes = countKind(bays, "pane")
		t:eq(#bays, 2 * panes + 1, label .. ": bays are not 2n+1 for n panes")
		for index, bay in ipairs(bays) do
			t:eq(bay.kind, index % 2 == 1 and "pier" or "pane",
				("%s: bay %d breaks the pier/pane alternation"):format(label, index))
		end
		if panes > 0 then
			withPanes += 1
		end
		checked += 1
	end
	t:eq(checked, #runs)
	t:gte(withPanes, 6, "most of these runs are wide enough to glaze — do not test only pier runs")
	t:gt(window.pier, 0, "a pier needs a width")
	t:gt(window.pane, 0, "a pane needs a width")
end)

T.spec("a run too short for a pane is all pier, not a negative pane", function(t)
	local w = T.world()
	local Config = w.config
	local window = Config.Structure.Window

	-- A bay needs a pier on BOTH sides, so the real threshold is
	-- pane + 2*pier, not pane + pier. Check either side of both, because
	-- `panes = floor((length - pier) / (pane + pier))` gets one of them wrong if
	-- the guard is written as `panes < 0` or the floor drops.
	local pier, pane = window.pier, window.pane
	local short = { 0.5, 1, pier, pane, pier + pane - 0.001, pier + pane, pier + pane + 0.001,
		pane + 2 * pier - 0.001 }
	for _, length in ipairs(short) do
		local bays = Config.wallBays(0, length)
		local label = ("a %g-stud run"):format(length)
		t:eq(kinds(bays), "pier", label .. " is too short to glaze and must be solid pier")
		tiles(t, bays, 0, length, label)
	end

	-- The first length that CAN take a pane takes exactly one, with a minimum
	-- pier either side and nothing left over.
	local exact = pane + 2 * pier
	local bays = Config.wallBays(0, exact)
	t:eq(kinds(bays), "pier|pane|pier", ("a %g-stud run is exactly one bay"):format(exact))
	tiles(t, bays, 0, exact, "the one-bay run")
	t:near(bays[2].to - bays[2].from, pane, EPS, "the pane is not a full pane wide")
	t:near(bays[1].to - bays[1].from, pier, EPS, "the pier is thinner than the spec")
	t:near(bays[3].to - bays[3].from, pier, EPS)
end)

T.spec("panes are exactly pane wide and the slack is even on the piers", function(t)
	local w = T.world()
	local Config = w.config
	local window = Config.Structure.Window

	-- The pane count is an ORACLE here, not a re-derivation: n panes need
	-- n*pane + (n+1)*pier, so the boundary for every n is walked from below,
	-- exactly on, and above. A floor() that drops or an off-by-one pier lands on
	-- one of these three, for some n, always.
	local step = window.pane + window.pier
	local lengths = {}
	for n = 1, 8 do
		local minimum = n * step + window.pier
		table.insert(lengths, { minimum - 0.001, n - 1 })
		table.insert(lengths, { minimum, n })
		table.insert(lengths, { minimum + 0.001, n })
		table.insert(lengths, { minimum + step / 2, n })
	end
	-- and the five run lengths the shipped shell actually produces, counted by
	-- hand off Config.Structure.Window rather than off Config.wallBays
	for _, pair in ipairs({ { 34, 1 }, { 62, 2 }, { 105, 4 }, { 118, 4 }, { 140, 5 } }) do
		table.insert(lengths, pair)
	end

	local glazed = 0
	for _, entry in ipairs(lengths) do
		local length, expected = entry[1], entry[2]
		local bays = Config.wallBays(0, length)
		local panes = countKind(bays, "pane")
		local label = ("a %g-stud run"):format(length)
		tiles(t, bays, 0, length, label)
		t:eq(panes, expected, label .. (" should hold exactly %d pane(s)"):format(expected))
		if expected == 0 then
			t:eq(kinds(bays), "pier", label .. " is too short to glaze")
			continue
		end

		local firstPier = nil
		for _, bay in ipairs(bays) do
			if bay.kind == "pane" then
				t:near(bay.to - bay.from, window.pane, EPS,
					label .. ": a pane is not exactly Window.pane wide — glass must not stretch")
			else
				local width = bay.to - bay.from
				t:gte(width, window.pier - EPS,
					label .. ": a pier is thinner than Window.pier — the slack went the wrong way")
				firstPier = firstPier or width
				t:near(width, firstPier, EPS,
					label .. ": the piers are not all the same width — the slack is not spread evenly")
			end
		end

		-- The packing is MAXIMAL: one more pane would not have fitted. This is
		-- the half of the arithmetic a floor() typo silently loses.
		t:gt((panes + 1) * window.pane + (panes + 2) * window.pier, length,
			label .. (": %d panes leaves room for another one"):format(panes))
		glazed += 1
	end
	t:eq(glazed, 36, "every glazed length in the table must have been walked")
end)

T.spec("the bay course fits inside its storey, sill and head included", function(t)
	local w = T.world()
	local Config = w.config
	local window = Config.Structure.Window

	local seen = 0
	for _, id in ipairs(STOREYS) do
		local storey = Config.storey(id)
		local bay = window[id]
		t:notNil(bay, id .. ": no window spec for this storey")
		t:gt(bay.sill, 0, id .. ": a sill course with no height")
		t:gt(bay.height, 0, id .. ": glass with no height")
		t:lt(bay.sill + bay.height, storey.clear,
			id .. ": no room for a head course — the glass reaches the ceiling")
		seen += 1
	end
	t:eq(seen, 2, "both storeys have a window spec")
end)

-- ── vertically: the storey, the deck and the roof ───────────────────────────

T.spec("roofUnderside sits on the top storey that exists", function(t)
	local w = T.world()
	local Config = w.config

	local ground = Config.storey("ground")
	local upper = Config.storey("upper")
	t:notNil(ground)
	t:notNil(upper)

	t:near(Config.roofUnderside(false), ground.floorY + ground.clear, EPS,
		"before the mezzanine the roof sits on the ground storey's top")
	t:near(Config.roofUnderside(true), upper.floorY + upper.clear, EPS,
		"after the mezzanine the roof sits on the upper storey's top")
	t:gt(Config.roofUnderside(true), Config.roofUnderside(false),
		"buying a floor must raise the roof, not lower it")

	-- There is no half-roof state, which is what let the old "shrink to dodge
	-- the deck" rule go: the two answers differ by a whole storey.
	t:near(Config.roofUnderside(true) - Config.roofUnderside(false),
		upper.clear + Config.Floors[1].deckSize.Y, EPS,
		"the gap between the two roof heights is the upper storey plus the deck")
end)

T.spec("the ground storey stops at the deck's underside, not its middle", function(t)
	-- This number was wrong by half a thickness while the contract was written,
	-- and half a thickness is a wall that ends INSIDE the floor above it.
	local w = T.world()
	local Config = w.config
	local floor = Config.Floors[1]
	local ground = Config.storey("ground")

	t:near(ground.clear, floor.height - floor.deckSize.Y, EPS,
		"the ground storey's clear height must be the deck's UNDERSIDE")
	t:ne(ground.clear, floor.height - floor.deckSize.Y / 2,
		"the ground wall ends half a deck thickness inside the floor above it")
	t:lt(ground.clear, floor.height, "the ground wall passes through the deck")

	-- No band, stated the way the seven-stud hole should have been: the deck
	-- exactly fills the space between the ground storey's top and the upper
	-- storey's floor. Nothing left over, nothing overlapping.
	t:near(Config.roofUnderside(false) + floor.deckSize.Y, Config.storey("upper").floorY, EPS,
		"there is a gap (or an overlap) between the ground wall's top and the upper floor")
	t:near(Config.storey("upper").floorY, floor.height, EPS,
		"the upper storey does not start at the floor it stands on")
end)

-- ── the part budget ─────────────────────────────────────────────────────────

T.spec("shellPartCount is 2n+3 a run, grows with the floor, and is stable", function(t)
	local w = T.world()
	local Config = w.config

	-- An independent model of the same total, from the documented per-course
	-- claim ("parts per run is 2n+3 where n is the pane count") rather than from
	-- shellPartCount's own loop.
	--
	-- The two per-side extras and the sign anchor are here because they were
	-- MISSING from shellPartCount when this spec was first written: it modelled
	-- the wall spec rather than what the builder emits, and reported 59 against 68
	-- actually built. A budget asserted 13% under the truth is a budget that
	-- passes right up until it matters, so this model counts the trim cap, the
	-- interior light strip and the anchor the roof sign hangs on.
	local function model(hasFloor: boolean)
		local total, runs, cuts = 6, 0, 0   -- roof slab + four columns + sign anchor
		for _, storey in ipairs(hasFloor and { "ground", "upper" } or { "ground" }) do
			-- The ceiling fixtures this storey hangs, modelled from columns x rows
			-- rather than from the function that places them — so this stays a
			-- second opinion. A grid that stopped emitting its far column would
			-- agree with itself and disagree here.
			total += Config.Structure.Lights.columns * Config.Structure.Lights.rows
			for _, side in ipairs(Config.Structure.Sides) do
				total += 2   -- this wall's neon cap, and the light strip inside it
				for _, segment in ipairs(Config.wallSegments(side, storey)) do
					if segment.kind == "solid" then
						local bays = Config.wallBays(segment.from, segment.to)
						local panes = countKind(bays, "pane")
						t:eq(#bays, 2 * panes + 1, "a run's bay course is not 2n+1")
						total += 2 * panes + 3   -- sill + head + (2n+1) bays
						runs += 1
					else
						total += 1 + segment.opening.leaves   -- lintel + leaves
						cuts += 1
					end
				end
			end
		end
		return total, runs, cuts
	end

	local full, runs, cuts = model(true)
	local ground = model(false)
	t:eq(Config.shellPartCount(true), full, "shellPartCount disagrees with 2n+3 a run")
	t:eq(Config.shellPartCount(false), ground, "shellPartCount disagrees with 2n+3 a run")
	t:eq(runs, 9, "five solid runs downstairs and four upstairs")
	t:eq(cuts, 2, "the gateway and the yard doorway, both on the ground storey")

	t:gt(Config.shellPartCount(true), Config.shellPartCount(false),
		"the mezzanine adds a whole storey of wall, so it must add parts")
	t:eq(Config.shellPartCount(true), Config.shellPartCount(true),
		"counting twice gave two answers — something accumulates across calls")

	t:lte(Config.shellPartCount(true), Config.Structure.PartBudget,
		"the full shell is over Config.Structure.PartBudget")
	t:lte(Config.shellPartCount(false), Config.Structure.PartBudget)
end)

T.spec("shellPartCount answers to inputs the shipped config never has", function(t)
	-- The verifier checks the shipped total against the budget. That passes just
	-- as well if shellPartCount ignores half its inputs, so: move the inputs.
	local w = T.world()
	local Config = w.config
	local base = Config.shellPartCount(true)

	table.insert(Config.Structure.Openings, opening("sideDoor", "left", "ground", -7, 7))
	local withDoor = Config.shellPartCount(true)
	t:ne(withDoor, base, "cutting a third opening did not change the part count")
	t:lte(withDoor, Config.Structure.PartBudget,
		"a third opening puts the shell over budget")

	Config.Structure.Window.pane = Config.Structure.Window.pane / 2
	t:gt(Config.shellPartCount(true), withDoor,
		"halving the pane must double up the bays, and each bay is a part")

	Config.Structure.Window.pier = 400   -- wider than any run: every wall goes solid
	local solid = Config.shellPartCount(true)
	t:lt(solid, withDoor, "with no run wide enough to glaze the shell must get cheaper")
	t:gt(solid, 5, "the roof and its columns are always there")
end)

T.spec("glass stays at or above PopperCam's 0.25 occlusion threshold", function(t)
	-- Roblox's PopperCam only treats a part as occluding when
	-- `Transparency < 0.25 and CanCollide`. Every pane in this shell is
	-- CanCollide, so below 0.25 the camera shoves itself through the windows of
	-- a plot that is now fully enclosed — and the plot is only enclosed BECAUSE
	-- of this round. This number is load-bearing, not cosmetic.
	local w = T.world()
	local window = w.config.Structure.Window

	t:gte(window.transparency, 0.25,
		"glass below 0.25 is opaque to PopperCam — the camera will pop through the walls")
	t:lt(window.transparency, 1, "a fully invisible pane is not a window")
end)

-- ── the shell as its own track ──────────────────────────────────────────────

T.spec("the shell is walls, then gates, then windows, then roof, on a track of its own", function(t)
	-- The ORDER IS THE TABLE ORDER — the loader derives `requires` from it and
	-- nothing else states the dependency. INVARIANTS.md marks that [nothing],
	-- and this is half of what closes it; the other half is a config check.
	--
	-- THE TRACK IS `structure` AND IT USED TO BE `factory`. The four rows were
	-- positions 5, 6, 7 and 14 of the factory chain, which made the building
	-- mandatory and blocking: no dropper4 until you had bought walls, gates and
	-- windows. They are a parallel ladder now, gated as a whole on `dropper1`.
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
	t:eq(structures, 4, "walls, gates, windows and the roof")

	-- ...and nothing was left behind on the spine. A Structure row still sitting
	-- in FactoryButtons would be a fifth piece of building blocking the line,
	-- which is the entire defect this split was for.
	for _, def in ipairs(Config.Tracks.factory) do
		t:isTrue(def.kind ~= "Structure",
			("%s is a Structure row still on the factory track — the shell is not supposed to block the line any more"):format(def.id))
	end

	t:notNil(seen.walls)
	t:gt(seen.gates, seen.walls, "gates hang on the wall ring, so they cannot precede it")
	t:gt(seen.windows, seen.walls, "glass is set into the bay course, so it cannot precede it")
	t:gt(seen.roof, seen.windows, "the roof is still the last piece of the shell")

	-- The chain the loader derives, end to end: each names the one before it
	-- without any of them saying so in Config, and the FIRST one names nothing.
	-- `walls` is a track root now rather than a link behind dropper3, and a root
	-- that carried a requirement would be a ladder nothing can start.
	t:isNil(Config.ButtonById.walls.requires,
		"walls is the root of the structure track; a root with a requirement is a track nothing can start")
	t:eq(Config.ButtonById.gates.requires, "walls",
		"the derived chain no longer runs walls -> gates")
	t:eq(Config.ButtonById.windows.requires, "gates",
		"the derived chain no longer runs gates -> windows")
	t:eq(Config.ButtonById.roof.requires, "windows",
		"the derived chain no longer runs windows -> roof")

	-- The whole ladder waits on the first dropper, so the shell can never be
	-- somebody's opening purchase.
	t:eq(Config.TrackUnlock.structure, "dropper1",
		"the structure track is meant to open one purchase in, not on claim")
	t:isFalse(Config.trackUnlocked("structure", {}),
		"a plot that has bought nothing must not be offered Plot Walls")
	t:isTrue(Config.trackUnlocked("structure", { dropper1 = true }),
		"one dropper in, the building becomes something you can want")
end)

T.spec("the mezzanine cannot be bought before something has roofed the storey below", function(t)
	-- FloorService stands each storey's own wall ring up and nothing else ever
	-- roofs it. While the shell was welded into the factory chain this was
	-- guaranteed by ORDERING — `roof` was simply an earlier row, and the config
	-- check asserted the deck was bought later. A parallel track is one you can
	-- decline, so that guarantee left with the shell and Config.ButtonUnlock
	-- replaces it.
	local w = T.world()
	local Config = w.config

	t:eq(Config.ButtonUnlock.floor2, "roof",
		"nothing makes the storey wait for a roof; it would arrive open to the sky")

	t:isFalse(Config.buttonUnlocked("floor2", { upgrader4 = true }),
		"every chain requirement is met and the roof is not bought — this must still be refused")
	t:isTrue(Config.buttonUnlocked("floor2", { upgrader4 = true, roof = true }),
		"with the roof standing the storey is buyable")

	-- NOT STICKY, which is the one way it differs from Config.trackUnlocked.
	-- That function forgives a missing gate because rebirth keeps the cabinets
	-- while wiping the factory button that opened them. Nothing like that can
	-- happen here: factory and structure are both keepOnRebirth = false, so a
	-- rebirth takes `roof` and `floor2` together.
	t:isFalse(Config.buttonUnlocked("floor2", { floor2 = true }),
		"owning the gated button must not satisfy its own gate")

	-- An ungated button is unaffected — the helper answers true for everything
	-- that has no row, or it would gate the entire game.
	t:isTrue(Config.buttonUnlocked("dropper1", {}))
	t:isTrue(Config.buttonUnlocked("walls", {}))
end)

T.spec("splitting the shell costs no parts, because an unglazed bay is still a wall", function(t)
	-- THE DESIGN DECISION, AS AN ASSERTION. `walls` could have left the bays as
	-- holes for `windows` to fill, and that reading is refused: a purchase
	-- called "Plot Walls" that does not keep a raider out is not walls. So a bay
	-- is built solid and glazing restyles it.
	--
	-- The consequence worth pinning is that Config.shellPartCount — and
	-- therefore the whole PartBudget argument — is measuring the same shell it
	-- measured before the split. If someone later makes `windows` emit its own
	-- parts, this is what says the budget has to be re-derived.
	local w = T.world()
	local Config = w.config

	local panes, piers = 0, 0
	for _, side in ipairs(Config.Structure.Sides) do
		for _, segment in ipairs(Config.wallSegments(side, "ground")) do
			if segment.kind == "solid" then
				for _, bay in ipairs(Config.wallBays(segment.from, segment.to)) do
					if bay.kind == "pane" then panes += 1 else piers += 1 end
				end
			end
		end
	end
	t:gt(panes, 0, "a shell with no bays cannot demonstrate anything about glazing")
	t:gt(piers, 0, "a bay course with no piers is one continuous window")

	-- Both kinds are boxes in the same course, and shellPartCount counts a bay
	-- as one part whichever it is — which is what makes the glass free.
	local counted = Config.shellPartCount(false)
	Config.Structure.Window.transparency = 1
	t:eq(Config.shellPartCount(false), counted,
		"the part count moved with the glass; glazing is a material change, not a part")
end)

T.spec("a plot owns the glass only while it owns the wall the glass is in", function(t)
	-- Tycoon:hasStructure is derived from `owned` rather than stored, and this is
	-- the reason: rebirth wipes the factory track, so it takes `walls` AND
	-- `windows` together. A stored flag would survive it and leave a plot
	-- claiming to be glazed with no shell to be glazed in — the same failure the
	-- sticky cabinet gate exists to prevent, one purchase over.
	local w = T.world()
	local Tycoon = w.req("Tycoon")

	local bare = { owned = {} }
	t:isFalse(Tycoon.hasStructure(bare, "walls"))
	t:isFalse(Tycoon.hasStructure(bare, "gates"))
	t:isFalse(Tycoon.hasStructure(bare, "windows"))

	local glazed = { owned = { walls = true, gates = true, windows = true } }
	t:isTrue(Tycoon.hasStructure(glazed, "walls"))
	t:isTrue(Tycoon.hasStructure(glazed, "gates"))
	t:isTrue(Tycoon.hasStructure(glazed, "windows"))
	t:isFalse(Tycoon.hasStructure(glazed, "roof"),
		"owning the other three must not imply the roof")

	-- It answers about the STRUCTURE, not the id, so a plot that owns a dropper
	-- of the same name would not be glazed by it.
	local partial = { owned = { walls = true, dropper1 = true } }
	t:isTrue(Tycoon.hasStructure(partial, "walls"))
	t:isFalse(Tycoon.hasStructure(partial, "windows"),
		"a plot with walls and no windows is reporting glass it never bought")

	-- An id that is not a button at all must not answer true for anything.
	local junk = { owned = { not_a_button = true } }
	t:isFalse(Tycoon.hasStructure(junk, "walls"),
		"an owned id with no Config row is being treated as a structure")
end)

-- ── a storey is lit when it is covered, not when it is walled ───────────────

T.spec("a storey has a ceiling only once something stands over it", function(t)
	-- THE FIXTURES USED TO ARRIVE WITH THE WALL RING, unconditionally, and the
	-- comment defending that quoted the cost as "three minutes of
	-- lights-on-in-daylight between `walls` and the roof". The real curve is
	-- walls 4.8, roof 26.4, deck 35.2 — thirty minutes of lit battens hanging at
	-- ceiling height over a plot that had no ceiling, twenty-one of them under
	-- open sky.
	--
	-- The verifier cannot see this: Config.storeyLightPositions is a pure
	-- function of the storey and shellPartCount counts every fixture whenever it
	-- is built, so both are identical before and after. WHEN a batten exists is
	-- runtime, and storeyHasCeiling is the whole of the decision.
	local w = T.world()
	local Config = w.config
	local Tycoon = w.req("Tycoon")

	local ground = Config.Structure.Storeys[1].id
	local upper = Config.Structure.Storeys[2].id
	local floor2 = Config.Floors[1].button

	local function plot(owned)
		return setmetatable({ owned = owned }, { __index = Tycoon })
	end

	-- A walled plot with nothing over it is not a room yet.
	t:isFalse(plot({}):storeyHasCeiling(ground),
		"a bare plot is lit")
	t:isFalse(plot({ walls = true, gates = true, windows = true }):storeyHasCeiling(ground),
		"the whole shell is bought, there is still open sky overhead, and the battens are on")

	-- The roof is what covers the ground floor first, at minute 26.
	t:isTrue(plot({ walls = true, roof = true }):storeyHasCeiling(ground),
		"the roof is on and the room below it is dark")

	-- ...and the deck covers it too, which matters because the deck is what
	-- makes the room genuinely dark and it lands nine minutes later.
	local decked = {}
	decked[floor2] = true
	t:isTrue(plot(decked):storeyHasCeiling(ground),
		"a storey with a deck over it is uncovered")

	-- THE UPPER STOREY IS COVERED BY THE ROOF AND NOT BY ITS OWN DECK. The
	-- comparison is floor.height > storey.floorY, so the mezzanine's 22 covers
	-- the ground storey at floorY 0 and does not cover the storey it creates at
	-- floorY 22. Getting this backwards would light the upper ring off the deck
	-- it is standing on.
	local upperOnly = {}
	upperOnly[floor2] = true
	t:isFalse(plot(upperOnly):storeyHasCeiling(upper),
		"the mezzanine is lit by the deck it stands on rather than by the roof above it")
	upperOnly.roof = true
	t:isTrue(plot(upperOnly):storeyHasCeiling(upper),
		"the roof is over the mezzanine and the mezzanine is dark")
end)

-- ── the shell does not survive a rebirth, and must not ──────────────────────

T.spec("a rebirth takes the whole shell down and every rung of it is buyable again", function(t)
	-- THIS IS A TRACE OF A BUG THAT WOULD BE PERMANENT AND SILENT, written as a
	-- test because nothing else in the repo can see it.
	--
	-- TrackInfo.structure.keepOnRebirth is false. If it were true:
	-- Tycoon:rebirth keeps the four ids in `profile.owned`, SKIPS clearing their
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
