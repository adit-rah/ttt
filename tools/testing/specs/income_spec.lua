--[[
	income_spec.lua — the three readers of the income model agree.

	Config.incomeRate is THE model: dropper value over rate, times the
	upgraders, times the generator. Tycoon:incomePerSecond multiplies it by
	the live multiplier stack, SessionService.incomePerSecondFor by the saved
	rebirth term, and the verifier's progression simulation reads it raw.

	This family holds the two runtime wrappers to the model so they cannot
	drift. Drift between hand-maintained copies of this arithmetic is the
	defect class behind #35, where a cached factor and the derived one
	disagreed for two rounds.
]]

return function(T)

T.family("income", "the three readers of Config.incomeRate agree")

-- A mixed bag on purpose: droppers, an upgrader, the generator, a belt rung
-- (income-neutral) and a structure rung (income-neutral). The neutral ids are
-- in the set so a reader that mistakes "owned" for "earning" fails here.
local MIX = { "dropper1", "dropper2", "upgrader1", "power1", "belt1", "walls" }

local function mixedOwned(Config)
	local owned = {}
	for _, id in ipairs(MIX) do
		assert(Config.ButtonById[id], "income_spec MIX names a button that no longer exists: " .. id)
		owned[id] = true
	end
	return owned
end

local function fakePlot(w, owned)
	local Tycoon = w.req("Tycoon")
	local plot = setmetatable({}, { __index = Tycoon })
	plot.owned = owned
	plot.owner = nil       -- no owner: the live multiplier stack is exactly 1
	return plot
end

T.spec("an unowned plot's quote IS the model", function(t)
	local w = T.world()
	local Config = w.config
	local owned = mixedOwned(Config)
	local plot = fakePlot(w, owned)

	local model = Config.incomeRate(function(id) return owned[id] == true end)
	t:near(plot:incomePerSecond(), model, 1e-9,
		"incomePerSecond with no owner must equal Config.incomeRate exactly")
end)

T.spec("the offline mirror is the model times the rebirth term", function(t)
	local w = T.world()
	local Config = w.config
	local Session = w.req("SessionService")
	local owned = mixedOwned(Config)
	local profile = { owned = owned, rebirths = 3 }

	local model = Config.incomeRate(function(id) return owned[id] == true end)
	local expected = model * Config.Rebirth.MultiplierPerRebirth ^ 3
	t:near(Session.incomePerSecondFor(profile), expected, 1e-9,
		"incomePerSecondFor must be Config.incomeRate times the rebirth multiplier and nothing else")
end)

T.spec("a buy button's advertised delta is the model's delta", function(t)
	local w = T.world()
	local Config = w.config
	local owned = mixedOwned(Config)
	local plot = fakePlot(w, owned)

	local function has(extra)
		return function(id) return owned[id] == true or id == extra end
	end
	local delta = plot:incomePerSecond("upgrader2") - plot:incomePerSecond()
	local modelDelta = Config.incomeRate(has("upgrader2")) - Config.incomeRate(has(nil))
	t:near(delta, modelDelta, 1e-6,
		"the +N/sec a pad advertises must be the model's own delta")
end)

--- A tung standing at a collect sensor, in the shape onCollect reads: a
--- Model with a body, the routing attributes, and its dropper's raw value.
local function fakeDrop(w, plotIndex, dropValue)
	local drop = Instance.new("Model")
	local body = Instance.new("Part")
	body.Position = Vector3.new(0, 0, 0)
	body.Parent = drop
	drop.PrimaryPart = body
	drop:SetAttribute("PlotIndex", plotIndex)
	drop:SetAttribute("Variant", "classic")
	drop:SetAttribute("DropValue", dropValue)
	drop.Parent = Instance.new("Folder")
	return drop, body
end

T.spec("a collected tung pays its dropper's value through the full stack, once", function(t)
	-- design:D-02, via #180 — onCollect is the game's ONE live payer. What is
	-- pinned: the payout is dropPayout (value x every owned upgrader x the
	-- generator) times the live multiplier, the stack is read fresh at
	-- COLLECTION, and the double-firing Touched pays exactly once through
	-- the Collected flag.
	local w = T.world()
	local Config = w.config
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local player = w.join("earner")
	local profile = Data.load(player)

	local owned = { dropper2 = true, upgrader1 = true, power1 = true }
	local plot = fakePlot(w, owned)
	plot.owner = player
	plot.index = 1
	plot.dropCount = 1
	plot.dropPool = {}
	plot.model = Instance.new("Model")

	local value = Config.ButtonById.dropper2.dropValue
	local drop, body = fakeDrop(w, 1, value)
	local before = profile.cash
	plot:onCollect(body)

	local expected = Config.dropPayout(value, function(id) return owned[id] == true end)
		* Economy.multiplier(player)
	t:near(profile.cash - before, expected, 1e-9,
		"one tung must pay its value through the plot multiplier and the live stack")
	t:isNil(drop.Parent, "the collected tung was not recycled off the belt")
	t:eq(plot.dropCount, 0, "the visual budget slot never came back")

	plot:onCollect(body)
	t:near(profile.cash - before, expected, 1e-9,
		"Touched fires twice and the second firing paid a second time")
end)

T.spec("a tung pays the owner alone, and the stack it pays through is the one owned now", function(t)
	-- The wipe/rebirth property the old income loop carried, restated for the
	-- collector: no owner means no payment (the slot still returns), and the
	-- multiplier is read at collection — a tung spawned before an upgrader
	-- was bought pays through it, and one collected after a rebirth wipe
	-- pays the bare value.
	local w = T.world()
	local Config = w.config
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local player = w.join("cycler")
	local profile = Data.load(player)

	local owned = { dropper1 = true, upgrader1 = true }
	local plot = fakePlot(w, owned)
	plot.owner = player
	plot.index = 1
	plot.dropCount = 2
	plot.dropPool = {}
	plot.model = Instance.new("Model")
	local value = Config.ButtonById.dropper1.dropValue

	-- the wipe: same plot, owned emptied mid-ride
	for id in pairs(owned) do
		owned[id] = nil
	end
	local drop1, body1 = fakeDrop(w, 1, value)
	local before = profile.cash
	plot:onCollect(body1)
	t:near(profile.cash - before, value * Economy.multiplier(player), 1e-9,
		"a tung collected after the wipe still paid the wiped upgraders")
	t:isNil(drop1.Parent)

	-- no owner: nothing is paid, the slot still returns
	plot.owner = nil
	local drop2, body2 = fakeDrop(w, 1, value)
	local atRelease = profile.cash
	plot:onCollect(body2)
	t:near(profile.cash, atRelease, 1e-9, "an ownerless plot's tung paid somebody")
	t:isNil(drop2.Parent, "the ownerless tung was not recycled")
	t:eq(plot.dropCount, 0, "the ownerless collect kept the budget slot")
end)

T.spec("the drops' long-run average IS the model", function(t)
	-- THE IDENTITY, stated as an assertion (#180): every owned dropper lands
	-- dropPayout(dropValue) each dropRate seconds, so the sum of payout over
	-- rate must equal Config.incomeRate exactly — this is what lets the HUD
	-- quote, the offline mirror and the pacing simulation keep reading one
	-- model while the conveyor carries the actual money.
	local w = T.world()
	local Config = w.config
	local owned = mixedOwned(Config)
	local has = function(id) return owned[id] == true end

	local average = 0
	for id, def in pairs(Config.ButtonById) do
		if owned[id] and def.kind == "Dropper" then
			average += Config.dropPayout(def.dropValue, has) / def.dropRate
		end
	end
	t:near(average, Config.incomeRate(has), 1e-9,
		"the per-collection payout has drifted from the rate every other reader quotes")
end)

T.spec("the model multiplies the whole plot by every upgrader", function(t)
	-- Pinned by hand so the spec can fail if Config.incomeRate changes shape:
	-- two droppers summed, one upgrader multiplied, the generator applied.
	local w = T.world()
	local Config = w.config
	local d1, d2 = Config.ButtonById.dropper1, Config.ButtonById.dropper2
	local u1, p1 = Config.ButtonById.upgrader1, Config.ButtonById.power1
	local owned = { dropper1 = true, dropper2 = true, upgrader1 = true, power1 = true }

	local expected = (d1.dropValue / d1.dropRate + d2.dropValue / d2.dropRate)
		* u1.multiplier * p1.factor
	t:near(Config.incomeRate(function(id) return owned[id] == true end), expected, 1e-9,
		"Config.incomeRate is not sum(droppers) x upgraders x generator")
end)

end
