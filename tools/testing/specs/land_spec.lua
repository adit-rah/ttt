--[[
	land_spec.lua — the ground the plot grows into, as arithmetic.

	Config's land helpers are pure functions and the harness runs them for
	real. What is pinned: ownership is a prefix count, the strips tile with no
	gap on either side, and — the property the no-rebuild rule stands on — the
	centre's wall spans and its openings are byte-identical at every land
	state, so buying ground never touches a box a gate leaf hangs in.

	ensureLand itself needs a model and a plot CFrame, which the mock world
	does not claim (its CFrame has no arithmetic), so the reconciler's
	behaviour on a real plot is a Studio item in the handoff.
]]

return function(T)

T.family("land", "ownership is a prefix, strips tile, and the centre never moves")

T.spec("landCounts counts a chain prefix, whatever else is owned", function(t)
	local w = T.world()
	local Config = w.config

	t:eq(Config.landCounts({}).left, 0, "an empty save owns land")
	local counts = Config.landCounts({ landL1 = true, landL2 = true, landR1 = true, dropper5 = true })
	t:eq(counts.left, 2, "two west lots owned, two counted")
	t:eq(counts.right, 1, "one east lot owned, one counted")
end)

T.spec("the strips tile outward from the centre with no gap", function(t)
	local w = T.world()
	local Config = w.config

	for _, side in ipairs({ "left", "right" }) do
		local edge = Config.World.PlotSize.X / 2
		for _, def in ipairs(Config.landRows(side)) do
			local rect = Config.landRect(def.id)
			t:notNil(rect, def.id .. " has no rectangle")
			local inner = (side == "left") and -rect.toX or rect.fromX
			local outer = (side == "left") and -rect.fromX or rect.toX
			t:near(inner, edge, 1e-9,
				def.id .. " does not start where the ground inside it ends")
			t:near(outer - inner, def.width, 1e-9,
				def.id .. "'s rectangle is not its stated width")
			edge = outer
		end
		local extents = Config.landExtents(5, 5)
		local reach = (side == "left") and -extents.minX or extents.maxX
		t:near(reach, edge, 1e-9,
			side .. ": landExtents disagrees with the last strip's outer edge")
	end
end)

T.spec("buying land never moves an opening or a centre span", function(t)
	-- THE NO-REBUILD GUARANTEE, as arithmetic: the gate leaves hang in the
	-- centre span's openings, and a land purchase adds spans without touching
	-- what stands. So every opening segment, and every solid span that lies
	-- on the centre pad, is identical at every land state.
	local w = T.world()
	local Config = w.config

	local function centreSpans(left, right)
		local out = {}
		for _, side in ipairs({ "front", "back" }) do
			for _, segment in ipairs(Config.wallSegments(side, left, right)) do
				local halfCentre = Config.World.PlotSize.X / 2
				if segment.from >= -halfCentre and segment.to <= halfCentre then
					table.insert(out, ("%s|%s|%.3f|%.3f"):format(
						side, segment.kind, segment.from, segment.to))
				end
			end
		end
		return table.concat(out, ";")
	end

	local bare = centreSpans(0, 0)
	t:eq(centreSpans(2, 1), bare, "a lopsided plot reshaped the centre's spans")
	t:eq(centreSpans(5, 5), bare, "a maxed plot reshaped the centre's spans")
end)

T.spec("the grown wall gains one span per expansion and nothing else", function(t)
	local w = T.world()
	local Config = w.config

	local function solids(left, right)
		local count = 0
		for _, segment in ipairs(Config.wallSegments("front", left, right)) do
			if segment.kind == "solid" then
				count += 1
			end
		end
		return count
	end

	local bare = solids(0, 0)
	t:eq(solids(1, 0), bare + 1, "one expansion must add exactly one span to the front wall")
	t:eq(solids(5, 5), bare + 10, "ten expansions must add exactly ten spans to the front wall")
end)

T.spec("the side walls move outward and keep the plot's depth", function(t)
	local w = T.world()
	local Config = w.config

	local bare = Config.wallExtent("left", 0, 0)
	local grown = Config.wallExtent("left", 3, 0)
	t:lt(grown.fixed, bare.fixed, "three west lots did not move the west wall outward")
	t:eq(grown.from, bare.from, "the moved wall changed the depth it runs")
	t:eq(grown.to, bare.to, "the moved wall changed the depth it runs")

	local right = Config.wallExtent("right", 3, 0)
	t:eq(right.fixed, Config.wallExtent("right", 0, 0).fixed,
		"west land moved the EAST wall")
end)

end
