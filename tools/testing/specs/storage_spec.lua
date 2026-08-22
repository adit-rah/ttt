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
