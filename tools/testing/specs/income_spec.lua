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
