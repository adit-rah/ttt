--[[
	siege_spec.lua — the walls' and gate's state machine.

	The parts are a picture; the health table is the authority, and the table's
	arithmetic runs headless. What is pinned: level derives from land, keys are
	stable names, a break is absorbing until the owner repairs, the owner check
	holds, and one swing damages one key once however many parts it boxed.

	The picture — courses falling, the stump recolour, the prompt appearing,
	GateService over a broken opening — needs parts and tweens: Studio items,
	named in the handoff.
]]

return function(T)

T.family("siege", "walls break by key, absorb nothing broken, and repair for the owner alone")

local function fakePlot(w, owner, owned)
	local Tycoon = w.req("Tycoon")
	local plot = setmetatable({}, { __index = Tycoon })
	plot.owner = owner
	plot.owned = owned or {}
	plot.factoryFolders = {}
	plot:resetSiege()
	return plot
end

T.spec("the siege level is the land plus one, and health follows it", function(t)
	local w = T.world()
	local Config = w.config
	local bare = fakePlot(w, nil)
	t:eq(bare:siegeLevel(), 1, "a bare plot is not level 1")
	t:eq(bare:siegeMaxHealth("wall_front"), Config.wallMaxHealth(1),
		"a bare wall's health is not the level-1 number")

	local grown = fakePlot(w, nil, { landL1 = true, landR1 = true, landL2 = true })
	t:eq(grown:siegeLevel(), 4, "three expansions must make level 4")
	t:gt(grown:siegeMaxHealth("gate_gateway"), bare:siegeMaxHealth("gate_gateway"),
		"land did not toughen the gate")
end)

T.spec("damage accumulates per key and the wall breaks exactly at zero", function(t)
	local w = T.world()
	local plot = fakePlot(w, nil)
	local max = plot:siegeMaxHealth("wall_front")

	t:eq(plot:damageStructure("wall_front", max * 0.4), max * 0.4,
		"a live wall must absorb its base damage")
	t:isFalse(plot:structureBroken("wall_front"), "the wall broke with health left")
	t:isFalse(plot:structureBroken("wall_back"), "damage leaked to another side")

	plot:damageStructure("wall_front", max)
	t:isTrue(plot:structureBroken("wall_front"), "the wall survived more than its health")
	t:eq(plot:damageStructure("wall_front", 50), 0,
		"a broken wall reported absorbing damage — wasted swings are counted by this")
end)

T.spec("an unknown key absorbs nothing", function(t)
	local w = T.world()
	local plot = fakePlot(w, nil)
	t:eq(plot:damageStructure("wall_ceiling", 100), 0,
		"a key nothing tracks took damage — a typo would silently discard hits")
end)

T.spec("repair needs the owner; anyone else is refused", function(t)
	local w = T.world()
	local owner = w.join("mason")
	local visitor = w.join("vandal")
	local plot = fakePlot(w, owner)

	plot:damageStructure("gate_gateway", 1e9)
	t:isTrue(plot:structureBroken("gate_gateway"), "the fixture never broke")
	t:isFalse(plot:repairStructure("gate_gateway", visitor), "a visitor repaired someone else's gate")
	t:isTrue(plot:structureBroken("gate_gateway"), "the refused repair still fixed it")

	t:isTrue(plot:repairStructure("gate_gateway", owner), "the owner's repair was refused")
	t:isFalse(plot:structureBroken("gate_gateway"), "the repair did not restore the gate")
	t:eq(plot.structureHealth.gate_gateway, plot:siegeMaxHealth("gate_gateway"),
		"the repair did not restore full health")
	t:isFalse(plot:repairStructure("gate_gateway", owner), "an intact gate accepted a repair")
end)

T.spec("part names resolve to stable keys, and only siege parts resolve", function(t)
	local w = T.world()
	local Tycoon = w.req("Tycoon")
	local function named(name)
		local part = Instance.new("Part")
		part.Name = name
		return part
	end
	t:eq(Tycoon.siegeKeyForPart(named("Sill_front_2")), "wall_front")
	t:eq(Tycoon.siegeKeyForPart(named("Pane_left_1_3")), "wall_left")
	t:eq(Tycoon.siegeKeyForPart(named("Lintel_back_4")), "wall_back")
	t:eq(Tycoon.siegeKeyForPart(named("Gate_gateway_2")), "gate_gateway")
	t:eq(Tycoon.siegeKeyForPart(named("Gate_yardDoor_1")), "gate_yardDoor")
	t:isNil(Tycoon.siegeKeyForPart(named("Roof")), "the roof is not a siege target")
	t:isNil(Tycoon.siegeKeyForPart(named("VaultBase")), "the vault is #94's target, not #124's")
	t:isNil(Tycoon.siegeKeyForPart(named("Fixture_3")), "a light batten is not a wall")
end)

T.spec("one swing hits one key once, and never the swinger's own plot", function(t)
	local w = T.world()
	local Tycoon = w.req("Tycoon")
	local owner = w.join("homeowner")
	local raider = w.join("raider")

	-- a plot with a real model tree, minimally: parts under model
	local plot = fakePlot(w, owner)
	plot.model = Instance.new("Model")
	table.insert(Tycoon.all(), plot)

	local function wallPart(name)
		local part = Instance.new("Part")
		part.Name = name
		part.Parent = plot.model
		return part
	end
	local parts = { wallPart("Pane_front_3_1"), wallPart("Pier_front_3_2"), wallPart("Head_front_3") }

	local max = plot:siegeMaxHealth("wall_front")
	Tycoon.siegeStrike(parts, raider, 30)
	t:near(plot.structureHealth.wall_front, max - 30, 1e-9,
		"three boxed parts of one wall must cost exactly one hit")

	Tycoon.siegeStrike(parts, owner, 30)
	t:near(plot.structureHealth.wall_front, max - 30, 1e-9,
		"the owner damaged their own wall — no accidental self-demolition")
end)

end
