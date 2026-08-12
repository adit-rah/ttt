--[[
	smoke_spec.lua — proves the harness loads and executes real src/ modules.

	Small on purpose. If this family is red, nothing else in the suite means
	anything, and the failure should point at the harness rather than at the
	game.
]]

return function(T)

T.family("smoke", "the harness can load and run src/ under a fake Roblox")

T.spec("loads Config and sees the real shipped numbers", function(t)
	local w = T.world()
	local Config = w.config

	t:eq(Config.Economy.CurrencyName, "Tung")
	t:gt(#Config.Buttons, 20, "the button table should be the full merged spine")
	t:eq(Config.Rebirth.MultiplierPerRebirth, 2.25)

	-- Graduating a feature DELETES its flag; it never sets it true, because
	-- tools/verify_config.lua fails the build on a flag that ships on. So the
	-- shipped offline/session families have no flag at all, and the four that
	-- are still prototypes are all false.
	t:isNil(Config.Prototypes.Offline,
		"Offline graduated — the flag must be gone from Config.Prototypes, not set to false or true")
	t:isNil(Config.Prototypes.Sessions,
		"Sessions graduated — the flag must be gone from Config.Prototypes, not set to false or true")
	t:eq(Config.Prototypes.RebirthPerks, false, "prototypes must ship OFF; a spec flips them at runtime")
end)

T.spec("Players.MaxPlayers is a number, so plot geometry matches the verifier", function(t)
	local w = T.world()
	-- Config.plotCountFor() reads Players.MaxPlayers at MODULE LOAD inside a
	-- pcall. If the mock left it nil the pcall would swallow it and the specs
	-- would silently run against different plot geometry than verify.py does --
	-- same Config, two answers, no error anywhere.
	local World = w.config.World
	t:gte(w.players.MaxPlayers, World.MinPlots)
	t:eq(World.PlotCount, math.clamp(w.players.MaxPlayers, World.MinPlots, World.MaxPlots))
	t:eq(#World.PlotPlacements, World.PlotCount)
end)

T.spec("the clock drives os.time, and os.date reads the fake epoch", function(t)
	local w = T.world()
	local start = os.time()
	t:eq(start, w.clock.DEFAULT_EPOCH or 1767225600)

	-- 2026-01-01 is a THURSDAY. This matters: Config.Sessions.WeekendDays is
	-- { [1] = Sun, [7] = Sat }, so a weekend default would silently double
	-- every income assertion in every other spec.
	local now = os.date("!*t")
	t:eq(now.year, 2026)
	t:eq(now.wday, 5, "the default seed must not be a weekend")

	w.clock:skip(3600)
	t:eq(os.time(), start + 3600)
end)

T.spec("task.wait and task.spawn run on the fake clock", function(t)
	local w = T.world()
	local order = {}

	task.spawn(function()
		table.insert(order, "immediate")
		task.wait(5)
		table.insert(order, "after-5")
		task.wait(10)
		table.insert(order, "after-15")
	end)

	-- Roblox resumes a spawned thread up to its first yield straight away.
	t:eq(order[1], "immediate", "task.spawn must resume before it returns")
	t:eq(#order, 1)

	w.clock:advance(5)
	t:eq(order[2], "after-5")

	w.clock:advance(9)
	t:eq(#order, 2, "the second wait has one second left to run")

	w.clock:advance(1)
	t:eq(order[3], "after-15")
end)

T.spec("DataService loads a default profile and round-trips it", function(t)
	local w = T.world()
	local Data = w.req("DataService")

	local player = w.join("smoker")
	local profile = Data.load(player)

	t:notNil(profile)
	t:eq(profile.cash, w.config.Economy.StartingCash)
	t:eq(profile.version, 2)
	t:eq(profile.lastSeen, 0, "a profile that has never saved must not look like a logout")

	profile.cash = 4242
	profile.owned.dropper1 = true
	t:isTrue(Data.save(player, true))

	local again = Data.load(player)
	t:eq(again.cash, 4242, "cash did not survive the round trip")
	t:isTrue(again.owned.dropper1)
end)

T.spec("the DataStore mock deep-copies, so a save is a real snapshot", function(t)
	local w = T.world()
	local Data = w.req("DataService")

	local player = w.join("copier")
	local profile = Data.load(player)
	profile.cash = 1000
	profile.owned.dropper1 = true
	Data.save(player, false)

	-- Mutating AFTER the save must not reach the stored blob. If the mock
	-- stored by reference this assertion passes for the wrong reason and every
	-- persistence spec in the suite becomes a tautology.
	profile.cash = 9999
	profile.owned.dropper2 = true

	local stored = w.store():raw("player_" .. player.UserId)
	t:eq(stored.cash, 1000, "the mock stored by reference — every save spec is now meaningless")
	t:isNil(stored.owned.dropper2)
end)

end
