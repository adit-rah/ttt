--[[
	tower_spec.lua — the daily tower's arithmetic (#95).

	Pinned: the day's composition (deterministic, every archetype dealt, the
	boss on top), the per-floor pay in minutes of the climber's OWN income,
	the best-floor day roll, and the round trip through the save. The run
	driver — platforms, spawns, wipes — needs a workspace; Studio owns it,
	the handoff names it.
]]

return function(T)

T.family("tower", "the day deals the floors, a floor pays your own minutes, the best rolls daily")

T.spec("a day's deck is deterministic, covers every archetype, and ends on the boss", function(t)
	local w = T.world()
	local Config = w.config

	local seen = {}
	for seed = 1, 40 do
		local deck = Config.towerFloors(seed)
		local again = Config.towerFloors(seed)
		t:eq(#deck, Config.Tower.Floors, "the deck is the wrong height")
		t:eq(table.concat(deck, ","), table.concat(again, ","),
			"the same day dealt two different towers")
		t:eq(deck[#deck], "boss", "the top floor must be the boss")
		for _, archetype in ipairs(deck) do
			seen[archetype] = true
		end
	end
	for _, archetype in ipairs(Config.TowerArchetypes) do
		t:isTrue(seen[archetype], ("archetype %q never appears"):format(archetype))
	end
	t:ne(table.concat(Config.towerFloors(1), ","), table.concat(Config.towerFloors(2), ","),
		"two different days dealt the same tower — the shuffle is dead")
end)

T.spec("a cleared floor pays minutes of the climber's own income", function(t)
	local w = T.world()
	local Tower = w.req("TowerService")
	local Session = w.req("SessionService")
	local Data = w.req("DataService")
	local Config = w.config

	local climber = w.join("climber")
	local profile = Data.load(climber)
	profile.owned.dropper1 = true
	profile.owned.dropper5 = true

	local before = profile.cash
	local expected = math.floor(Config.Tower.FloorRewardMinutes * 60
		* Session.incomePerSecondFor(profile))
	t:isTrue(expected > 0, "the fixture earns nothing; the spec would pass vacuously")
	local gained = Tower.recordClear(climber, 3, 0)
	t:eq(gained, expected, "the floor must pay FloorRewardMinutes of THIS climber's rate")
	t:eq(profile.cash, before + expected, "the pay never landed")
end)

T.spec("the best floor is today's, survives the save, and rolls at midnight", function(t)
	local w = T.world()
	local Tower = w.req("TowerService")
	local Data = w.req("DataService")

	local climber = w.join("climber")
	Data.load(climber)
	local day1 = 86400 * 100

	Tower.recordClear(climber, 3, day1)
	Tower.recordClear(climber, 5, day1 + 60)
	Tower.recordClear(climber, 4, day1 + 120)
	t:eq(Tower.bestFloor(climber, day1 + 200), 5, "the best floor did not stick")

	t:isTrue(Data.save(climber, true), "the save did not go through")
	local reloaded = Data.load(climber)
	t:eq(reloaded.tower.best, 5,
		"the tower record did not survive the round trip — the payload is missing the field")

	t:eq(Tower.bestFloor(climber, day1 + 86400), 0,
		"yesterday's best leaked into today — the daily reset is the arithmetic")
end)

end
