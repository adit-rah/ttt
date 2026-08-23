--[[
	frontier_spec.lua — the edge of what exists (#105).

	Pinned: the frontier means ALL of it (every button, at the rebirth cap),
	the stamp lands once and survives the save, and the standings order by
	Tung. The board and the announcement are surfaces; Studio owns them.
]]

return function(T)

T.family("frontier", "the frontier is everything, stamped once; the standings order by Tung")

T.spec("the frontier means every button at the cap", function(t)
	local w = T.world()
	local Board = w.req("LeaderboardService")
	local Data = w.req("DataService")
	local Config = w.config

	local player = w.join("finisher")
	local profile = Data.load(player)

	for _, def in ipairs(Config.Buttons) do
		profile.owned[def.id] = true
	end
	profile.rebirths = Config.Rebirth.MaxRebirths - 1
	t:isFalse(Board.isFrontier(profile), "the frontier arrived a rebirth early")

	profile.rebirths = Config.Rebirth.MaxRebirths
	t:isTrue(Board.isFrontier(profile), "everything owned at the cap is not the frontier")

	profile.owned[Config.Buttons[1].id] = nil
	t:isFalse(Board.isFrontier(profile), "a missing button still counted as everything")
end)

T.spec("the stamp lands once and survives the save", function(t)
	local w = T.world()
	local Board = w.req("LeaderboardService")
	local Data = w.req("DataService")
	local Config = w.config

	local player = w.join("finisher")
	local profile = Data.load(player)
	for _, def in ipairs(Config.Buttons) do
		profile.owned[def.id] = true
	end
	profile.rebirths = Config.Rebirth.MaxRebirths

	t:isTrue(Board.checkFrontier(player, 12345), "the frontier moment never fired")
	t:eq(profile.frontier, 12345, "the stamp did not land")
	t:isFalse(Board.checkFrontier(player, 99999), "the moment fired twice")
	t:eq(profile.frontier, 12345, "the second check moved the stamp")

	t:isTrue(Data.save(player, true), "the save did not go through")
	local reloaded = Data.load(player)
	t:eq(reloaded.frontier, 12345,
		"the stamp did not survive the round trip — the payload is missing the field")
end)

T.spec("the standings order by Tung", function(t)
	local w = T.world()
	local Board = w.req("LeaderboardService")
	local Data = w.req("DataService")

	local poor = w.join("poor")
	Data.load(poor).cash = 10
	local rich = w.join("rich")
	Data.load(rich).cash = 1000

	local rows = Board.standings()
	t:eq(rows[1].player, rich, "the richest is not first")
	t:eq(Board.rankOf(poor), 2, "the poor player's rank is wrong")
end)

end
