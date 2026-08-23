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

	-- ...and the masonry is the second axis (#162): a tier owned is a
	-- PerTier step on walls AND gates, with the arithmetic pinned to the
	-- same Config functions the verifier's grid walks.
	local stone = fakePlot(w, nil, { walls = true, gates = true, cobble = true })
	t:eq(stone:masonryTiers(), 1)
	t:eq(stone:siegeMaxHealth("wall_front"), Config.wallMaxHealth(1, 1),
		"a cobbled wall's health is not the level-1 tier-1 number")
	t:eq(stone:siegeMaxHealth("gate_gateway"), Config.gateMaxHealth(1, 1),
		"a cobbled plot's gate missed its tier step")
	t:gt(stone:siegeMaxHealth("wall_front"), bare:siegeMaxHealth("wall_front"),
		"masonry did not toughen the wall")
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

T.spec("anyone repairs a broken thing; only a helper earns the credit", function(t)
	-- #123 opened repair past the owner — a repair only ever helps the plot —
	-- and made a stranger's repair a kindness credit through the observer.
	-- The breaker themselves is the one exclusion, so break-and-repair
	-- cannot farm reputation.
	local w = T.world()
	local Tycoon = w.req("Tycoon")
	local owner = w.join("mason")
	local visitor = w.join("goodneighbour")
	local raider = w.join("vandal")
	local plot = fakePlot(w, owner)

	local credited = {}
	Tycoon.repairObserver = function(_, player)
		table.insert(credited, player)
	end

	plot:damageStructure("gate_gateway", 1e9, raider)
	t:isTrue(plot:structureBroken("gate_gateway"), "the fixture never broke")
	t:isTrue(plot:repairStructure("gate_gateway", visitor),
		"a visitor's repair was refused — helping repair is #123's second trigger")
	t:isFalse(plot:structureBroken("gate_gateway"), "the repair did not restore the gate")
	t:eq(credited[1], visitor, "the helper's repair earned no credit")

	plot:damageStructure("gate_gateway", 1e9, raider)
	t:isTrue(plot:repairStructure("gate_gateway", raider),
		"the breaker's repair was refused — the repair itself is always welcome")
	t:eq(#credited, 1, "the breaker farmed a kindness credit out of their own vandalism")

	plot:damageStructure("gate_gateway", 1e9, raider)
	t:isTrue(plot:repairStructure("gate_gateway", owner), "the owner's repair was refused")
	t:eq(#credited, 1, "the owner earned credit for their own plot")
	t:eq(plot.structureHealth.gate_gateway, plot:siegeMaxHealth("gate_gateway"),
		"the repair did not restore full health")
	t:isFalse(plot:repairStructure("gate_gateway", owner), "an intact gate accepted a repair")
	Tycoon.repairObserver = nil
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
	t:eq(Tycoon.siegeKeyForPart(named("Body_left_1")), "wall_left")
	t:eq(Tycoon.siegeKeyForPart(named("Head_right_2")), "wall_right")
	t:eq(Tycoon.siegeKeyForPart(named("Lintel_back_4")), "wall_back")
	t:eq(Tycoon.siegeKeyForPart(named("Buttress_front_3")), "wall_front",
		"a buttress is a chunk of its wall's face; a swing on it lands on the wall")
	t:eq(Tycoon.siegeKeyForPart(named("Gate_gateway_2")), "gate_gateway")
	t:eq(Tycoon.siegeKeyForPart(named("Gate_yardDoor_1")), "gate_yardDoor")
	t:isNil(Tycoon.siegeKeyForPart(named("Trim_front")), "the trim cap is not a siege target")
	t:isNil(Tycoon.siegeKeyForPart(named("Torch_left_2")), "a torch is dressing, never a target")
	t:isNil(Tycoon.siegeKeyForPart(named("TorchFlame_left_2")), "a flame is dressing, never a target")
	t:isNil(Tycoon.siegeKeyForPart(named("VaultBase")),
		"the storage body must stay outside the wall machinery — its route is siegeStrike's own")
end)

T.spec("a broken wall takes its torches down and leaves the neighbours' burning", function(t)
	-- The torches resolve to no siege key — dressing, never targets — so the
	-- generic sweep cannot touch them and applySiegeState carries an explicit
	-- branch: a torch parses its side from its own name and falls with it.
	-- Without the branch a breach leaves a bracket and a flame floating in
	-- the gap, which is the batten-ghost bug with a fire on it.
	local w = T.world()
	local plot = fakePlot(w, nil)
	plot.refreshSiegePrompts = function() end   -- prompts are Studio's half

	local ring = Instance.new("Model")
	local function part(name)
		local p = Instance.new("Part")
		p.Name = name
		p.Parent = ring
		return p
	end
	part("Sill_front_1")
	local body = part("Body_front_1")
	local frontTorch = part("Torch_front_1")
	local frontFlame = part("TorchFlame_front_1")
	local leftTorch = part("Torch_left_1")
	local buttress = part("Buttress_front_2")

	plot.structureHealth.wall_front = 0
	plot:applySiegeState(ring)

	t:isNil(body.Parent, "the broken wall's body course is still standing")
	t:isNil(buttress.Parent, "the broken wall's buttress is floating over the breach")
	t:isNil(frontTorch.Parent, "the broken wall's torch bracket is floating over the breach")
	t:isNil(frontFlame.Parent, "the broken wall's flame is burning in mid-air")
	t:notNil(leftTorch.Parent, "an intact wall lost its torch to another side's break")
end)

T.spec("a dent survives the save as a fraction, and scales onto new maxes", function(t)
	-- The named [nothing] trap: a field in defaultProfile and not in the save
	-- payload works all session and is gone at next login. This round-trips
	-- through the REAL DataService save/load, then restores onto a plot one
	-- land level up, where the same fraction is more hit points.
	local w = T.world()
	local Data = w.req("DataService")
	local player = w.join("veteran")
	local profile = Data.load(player)

	local plot = fakePlot(w, player)
	plot:damageStructure("wall_front", plot:siegeMaxHealth("wall_front") * 0.5)
	t:near(profile.structure.wall_front, 0.5, 1e-9,
		"half a wall's damage must mirror into the profile as one half")

	t:isTrue(Data.save(player, true), "the save did not go through")
	local reloaded = Data.load(player)
	t:ne(reloaded, profile, "the reload handed back the in-memory profile, so nothing was round-tripped")
	t:near(reloaded.structure.wall_front, 0.5, 1e-9,
		"the dent did not survive the round trip — the payload is missing the field")

	local grown = fakePlot(w, player, { landL1 = true })
	grown:restoreSiege(reloaded)
	t:near(grown.structureHealth.wall_front, grown:siegeMaxHealth("wall_front") * 0.5, 1e-9,
		"the restored dent did not scale onto the grown wall's max")
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
	local parts = { wallPart("Sill_front_3"), wallPart("Body_front_3"), wallPart("Head_front_3") }

	local max = plot:siegeMaxHealth("wall_front")
	Tycoon.siegeStrike(parts, raider, 30)
	t:near(plot.structureHealth.wall_front, max - 30, 1e-9,
		"three boxed parts of one wall must cost exactly one hit")

	Tycoon.siegeStrike(parts, owner, 30)
	t:near(plot.structureHealth.wall_front, max - 30, 1e-9,
		"the owner damaged their own wall — no accidental self-demolition")
end)

T.spec("a swing on the storage body routes to damageStorage, once, and never for the owner", function(t)
	-- #94's entry: VaultBase resolves to the reserved key "storage" inside
	-- siegeStrike alone, so a bat reaches the unit through the same door and
	-- the same per-swing dedup as a wall — and the wall machinery (maxes,
	-- prompts, saved fractions) never learns the key exists.
	local w = T.world()
	local Tycoon = w.req("Tycoon")
	local Config = w.config
	local owner = w.join("homeowner")
	local raider = w.join("raider")

	local plot = fakePlot(w, owner)
	plot:resetStorage()
	plot.model = Instance.new("Model")
	table.insert(Tycoon.all(), plot)

	local body = Instance.new("Part")
	body.Name = "VaultBase"
	body.Parent = plot.model
	local parts = { body, body }   -- one swing boxing the body twice

	local max = Config.Storage.MaxHealth
	local hit = 30 * Config.Structure.Health.PlayerDamageScale
	Tycoon.siegeStrike(parts, raider, 30)
	t:near(plot.storage.health, max - hit, 1e-9,
		"the unit took something other than exactly one scaled hit")
	t:isNil(plot.structureHealth.storage,
		"the strike leaked a 'storage' key into the wall table — repair and persistence would both trip on it")

	Tycoon.siegeStrike({ body }, owner, 30)
	t:near(plot.storage.health, max - hit, 1e-9,
		"the owner dented their own storage unit")
end)

end
