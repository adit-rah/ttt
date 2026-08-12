--[[
	generator_spec.lua — the generator must actually speed the plot up.

	HANDOFF_v5 §2 states the invariant in writing:

		"It must multiply belt speed by exactly the factor it multiplies drop
		 rate by. In-flight drops are peakRate x length / speed; the two cancel."

	and the verifier asserts the Config side of it per tier. What nothing has
	ever checked is whether Tycoon APPLIES it — and it does not.
	`self.powerFactor` is initialised to 1 (Tycoon.lua:204), reset to 1 on
	release and rebirth (:2192, :2272), and assigned nowhere else.
	INSTALLERS.Power (:1762) calls refreshBeltSpeed() without setting it.

	So buying a generator speeds up nothing, while `Tycoon:incomePerSecond`
	(:2063) and `SessionService.incomePerSecondFor` both multiply by the
	correct derived Config.powerFactor(has). The plot's QUOTED income is up to
	2x what it produces, and the offline mirror banks against the quote.

	The three assertions below are one defect with three symptoms, and they are
	pinned as a group ON PURPOSE. incomePerSecond calls Config.powerFactor
	directly while the other two read the cached self.powerFactor field; that
	asymmetry is exactly why this stayed invisible, and after the fix they still
	agree via different routes. The group is what stops them diverging again.

	Spec 3 is HANDOFF_v5 §5 item 8 — the number a human was asked to verify in
	Studio two rounds running, and nobody did.
]]

return function(T)

T.family("generator", "buying power must move belt speed and drop rate, not just the quote")

--- A plot with the state INSTALLERS.Power touches and nothing else.
--- Everything that would need a BasePart is stubbed on the instance, which
--- shadows the class method without changing it.
local function fakePlot(w)
	local Tycoon = w.req("Tycoon")
	local Config = w.config
	local plot = setmetatable({}, { __index = Tycoon })
	plot.powerFactor = 1
	plot.beltBonus = 0
	plot.beltSpeed = Config.Layout.BeltSpeed
	plot.owned = {}
	plot.drops = { GetChildren = function() return {} end }
	plot.eachBeltSurface = function() end
	plot.buildYardMachine = function() end
	plot.buildShelfDisplay = function() end
	return plot, Tycoon, Config
end

local function install(plot, Tycoon, Config, id: string)
	local def = Config.ButtonById[id]
	assert(def, "no such button: " .. id)
	plot.owned[id] = true
	Tycoon.INSTALLERS[def.kind](plot, def, true)
	return def
end

T.spec("power1 multiplies belt speed by its factor", function(t)
	local w = T.world()
	local plot, Tycoon, Config = fakePlot(w)

	install(plot, Tycoon, Config, "power1")

	local base = Config.Layout.BeltSpeed
	local factor = Config.ButtonById.power1.factor
	t:near(plot.beltSpeed, base * factor, 1e-9,
		"belt speed ignored the generator — self.powerFactor is never assigned")
end)

T.spec("power1 divides the drop interval by its factor", function(t)
	local w = T.world()
	local plot, Tycoon, Config = fakePlot(w)

	install(plot, Tycoon, Config, "power1")

	local dropper = Config.ButtonById.dropper1
	local factor = Config.ButtonById.power1.factor
	t:near(plot:dropInterval(dropper), dropper.dropRate / factor, 1e-9,
		"drop rate ignored the generator — droppers still fire at the base interval")
end)

T.spec("power3 + belt1 is (28+9) x 1.68, not 28x1.68+9 and not 78.1", function(t)
	-- HANDOFF_v5 §5 item 8, verbatim: "Belt should be (28+9)x1.68 = 62.2, not
	-- 28x1.68+9 = 56 and not 78.1. This is the install-replay trap."
	local w = T.world()
	local plot, Tycoon, Config = fakePlot(w)

	-- installed in `order`, the way Tycoon:assign replays a save
	install(plot, Tycoon, Config, "belt1")
	install(plot, Tycoon, Config, "power1")
	install(plot, Tycoon, Config, "power2")
	install(plot, Tycoon, Config, "power3")

	local expected = (Config.Layout.BeltSpeed + Config.ButtonById.belt1.speedBonus)
		* Config.ButtonById.power3.factor

	t:near(plot.beltSpeed, expected, 1e-9,
		"belt speed is not (base + bonus) x powerFactor")
	t:near(expected, 62.16, 0.01, "the handoff's own arithmetic")
end)

T.spec("belt speed is DERIVED, so replaying a save does not compound it", function(t)
	-- Tycoon:assign replays every owned button in `order`. If powerFactor were
	-- accumulated rather than derived, four generators would land on
	-- 1.19 x 1.42 x 1.68 x 2.00 = 5.68 instead of 2.00.
	local w = T.world()
	local plot, Tycoon, Config = fakePlot(w)

	install(plot, Tycoon, Config, "power1")
	install(plot, Tycoon, Config, "power2")
	install(plot, Tycoon, Config, "power3")
	install(plot, Tycoon, Config, "power4")

	local top = Config.ButtonById.power4.factor
	t:near(plot.beltSpeed, Config.Layout.BeltSpeed * top, 1e-9,
		"the top rung must be 2.00x, not the product of every rung")
end)

T.spec("the plot's quoted income and its production agree about power", function(t)
	-- The two halves of the defect, in one assertion. Config.powerFactor is
	-- what incomePerSecond multiplies by; self.powerFactor is what the belt
	-- and the droppers read. They must be the same number.
	local w = T.world()
	local plot, Tycoon, Config = fakePlot(w)

	install(plot, Tycoon, Config, "power1")
	install(plot, Tycoon, Config, "power2")

	local quoted = Config.powerFactor(function(id)
		return plot.owned[id] == true
	end)
	t:near(plot.powerFactor, quoted, 1e-9,
		"the plot quotes income at one power factor and produces at another")
end)

end
