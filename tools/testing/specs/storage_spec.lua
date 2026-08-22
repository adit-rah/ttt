--[[
	storage_spec.lua — the storage unit's state machine.

	The unit is the vault body with health (#93): raids (#94) and sieges
	(#124) will call damageStorage, #98 hangs the overflow cap on
	storageIntact. What is pinned here is the machine itself — break at zero,
	absorb nothing while broken, repair only by the present owner — and the
	one scaling rule already live: damage multiplies by storedOverflowFraction,
	which is 0 until #98.

	The prompt, the recolour and the attribute mirror need parts and
	replication; they are Studio items in the handoff.
]]

return function(T)

T.family("storage", "the unit breaks at zero, absorbs nothing broken, and repairs for its owner alone")

local function fakePlot(w, owner)
	local Tycoon = w.req("Tycoon")
	local plot = setmetatable({}, { __index = Tycoon })
	plot.owner = owner
	plot:resetStorage()
	return plot
end

T.spec("damage accumulates and the unit breaks exactly at zero", function(t)
	local w = T.world()
	local S = w.config.Storage
	local plot = fakePlot(w, nil)

	local dealt = plot:damageStorage(S.MaxHealth * 0.4)
	t:near(dealt, S.MaxHealth * 0.4, 1e-9,
		"at zero overflow a hit must deal exactly its base damage")
	t:isTrue(plot:storageIntact(), "the unit broke with health left")

	plot:damageStorage(S.MaxHealth)
	t:isFalse(plot:storageIntact(), "the unit survived more damage than its health")
	t:eq(plot.storage.health, 0, "health went past zero")
end)

T.spec("a broken unit absorbs nothing, and the return value says so", function(t)
	local w = T.world()
	local S = w.config.Storage
	local plot = fakePlot(w, nil)

	plot:damageStorage(S.MaxHealth * 2)
	t:eq(plot:damageStorage(10), 0,
		"a broken unit reported absorbing damage — #94 counts wasted swings by this")
end)

T.spec("repair needs the owner; anyone else is refused", function(t)
	local w = T.world()
	local S = w.config.Storage
	local owner = w.join("owner")
	local visitor = w.join("visitor")
	local plot = fakePlot(w, owner)

	plot:damageStorage(S.MaxHealth * 2)
	t:isFalse(plot:repairStorage(visitor), "a visitor repaired someone else's unit")
	t:isFalse(plot:storageIntact(), "the refused repair still fixed the unit")

	t:isTrue(plot:repairStorage(owner), "the owner's repair was refused")
	t:isTrue(plot:storageIntact(), "the repair did not restore the unit")
	t:eq(plot.storage.health, S.MaxHealth, "the repair did not restore full health")

	t:isFalse(plot:repairStorage(owner), "an intact unit accepted a repair")
end)

T.spec("resetStorage is the tenancy boundary", function(t)
	local w = T.world()
	local S = w.config.Storage
	local plot = fakePlot(w, nil)

	plot:damageStorage(S.MaxHealth * 2)
	plot:resetStorage()
	t:isTrue(plot:storageIntact(), "a new tenancy inherited the last one's broken unit")
	t:eq(plot.storage.health, S.MaxHealth, "a new tenancy inherited the last one's dents")
end)

T.spec("the cap clamps at the one door money comes in through", function(t)
	-- #98: earnings above the cap are LOST, at Economy.add, so the income
	-- tick, the offline grant and every session reward all meet the same
	-- ceiling — there is no second bank without a cap on it.
	local w = T.world()
	local Config = w.config
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local player = w.join("hoarder")
	local profile = Data.load(player)
	profile.owned.dropper1 = true

	local cap = Economy.storageCapFor(player)
	t:eq(cap, Config.storageCap(function(id) return profile.owned[id] == true end, 0, true),
		"Economy's cap and Config's formula disagree")

	profile.cash = cap - 50
	t:eq(Economy.add(player, 200, false), 50, "the door paid past the cap")
	t:eq(Economy.get(player), cap, "the bank went over the unit's capacity")
	t:eq(Economy.add(player, 200, false), 0, "a full unit accepted more")

	-- spending makes room again: the whole point of the cap
	t:isTrue(Economy.spend(player, 400), "spending from a full bank failed")
	t:gt(Economy.add(player, 200, false), 0, "spending did not reopen the door")
end)

T.spec("a broken unit collapses the cap to its floor", function(t)
	local w = T.world()
	local Config = w.config
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local player = w.join("besieged")
	local profile = Data.load(player)
	profile.owned.dropper5 = true

	local intact = true
	Economy.setStorageIntactHook(function() return intact end)
	local whole = Economy.storageCapFor(player)
	t:gt(whole, Config.Storage.BrokenCapFloor, "the fixture's cap is not above the broken floor")

	intact = false
	t:eq(Economy.storageCapFor(player), Config.Storage.BrokenCapFloor,
		"a smashed unit still banks at full capacity — the repair loop has no stakes")
	Economy.setStorageIntactHook(nil)
end)

T.spec("damage scales by the overflow fraction", function(t)
	local w = T.world()
	local S = w.config.Storage
	local plot = fakePlot(w, nil)

	-- #98's seam, stubbed to a full unit: base x (1 + DamagePerOverflowFraction)
	plot.storedOverflowFraction = function() return 1 end
	local dealt = plot:damageStorage(10)
	t:near(dealt, 10 * (1 + S.DamagePerOverflowFraction), 1e-9,
		"a full unit must take the configured multiple of base damage")
end)

end
