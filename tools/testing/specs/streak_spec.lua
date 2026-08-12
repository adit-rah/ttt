--[[
	streak_spec.lua — the daily login ladder, and the two ways it eats itself.

	A streak is a promise: come back tomorrow and the number goes up. Every bug
	in a streak system breaks that promise silently, for everyone, and the player
	does not report it — they just stop coming back. So the two failure modes
	worth pinning are the two that reset a streak that should have survived:

	  * THE GRACE WINDOW. `DailyGraceHours = 48` is not implemented as 48 hours,
	    and it must not be: the implementation counts whole UTC day BUCKETS,
	    `graceBuckets = 1 + floor(48/24) = 3`, so a gap of three buckets still
	    advances and a gap of four resets. Buckets are coarse on purpose (claim
	    at 23:00 and again at 01:00 two buckets later is 26 real hours), and
	    every rounding error in a grace period should fall on the player's side.
	    The boundary between 3 and 4 is the whole point of this file.

	  * NEW YEAR'S EVE. SessionService's header names this one as a landmine
	    already: a streak keyed on os.date("%j") breaks for every player in the
	    game on the same night, because day-of-year restarts at 1 and every gap
	    computes NEGATIVE. The last spec below claims across 2026-12-31T23:59Z
	    and asserts the streak advanced — and asserts the yday roll happened, so
	    the spec cannot quietly stop testing the thing it was written for.

	Everything is driven through the real RequestClaim remote rather than by
	calling claimDaily, so the flood guard, the payload handling and the state
	re-push are all inside the test. See tools/testing/mock/instance.lua.
]]

return function(T)

T.family("streak", "the daily ladder must survive a missed evening and a new year")

local DAY = 86400

--- Push a claim through the real remote, the way a client does.
---
--- The 0.5s nudge clears SessionService's 0.25s per-player flood guard, which
--- is measured on os.clock() — the monotonic base — and therefore reads 0 for
--- both operands on a brand new world.
local function claim(w, player, payload)
	local folder = w.replicatedStorage:FindFirstChild("TungNet")
	local remote = folder and folder:FindFirstChild("RequestClaim")
	assert(remote, "harness: no RequestClaim remote in TungNet")
	w.clock:advance(0.5)
	remote.OnServerEvent:Fire(player, payload)
end

local function dayBucket(): number
	return math.floor(os.time() / DAY)
end

--- A running server with one player whose profile is loaded and live.
local function seated(w, name: string)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	Session.start()
	local player = w.join(name)
	local profile = Data.load(player)
	Session.onPlayer(player)
	return player, profile
end

T.spec("the first claim starts the streak at one and pays day one", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "day1")

	t:eq(Config.Sessions.DailyRewards[1], 500, "the day-one payout this spec pins has moved")

	local before = Economy.get(player)
	claim(w, player, { kind = "daily" })

	t:eq(profile.sessions.streak, 1, "a first claim did not start the streak at one")
	t:eq(profile.sessions.dailyDay, dayBucket(), "the claim was not stamped into today's bucket")
	t:eq(Economy.get(player) - before, 500, "the first day paid something other than its ladder rung")
end)

T.spec("the daily reward is flat, so a boost cannot be farmed by waiting", function(t)
	-- A login reward that scales with the 2x boost turns the boost button into
	-- a "wait before claiming" puzzle, which is a worse game than no boost.
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "waiter")

	profile.sessions.boostUntil = os.time() + Config.Sessions.BoostSeconds
	t:eq(Economy.multiplier(player), Config.Sessions.BoostMultiplier,
		"the boost is not live, so the flat-payout assertion below proves nothing")

	local before = Economy.get(player)
	claim(w, player, { kind = "daily" })
	t:eq(Economy.get(player) - before, 500,
		"the daily reward was scaled by the active boost — claiming is now a timing puzzle")
end)

T.spec("a second claim in the same UTC bucket pays nothing", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local player, profile = seated(w, "doubler")

	claim(w, player, { kind = "daily" })
	local after = Economy.get(player)

	claim(w, player, { kind = "daily" })
	t:eq(Economy.get(player) - after, 0, "the daily reward can be claimed twice in one day")
	t:eq(profile.sessions.streak, 1, "a same-day re-claim advanced the streak")
end)

T.spec("a one-bucket gap advances the streak", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "regular")

	claim(w, player, { kind = "daily" })
	w.clock:skip(DAY)

	local before = Economy.get(player)
	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 2, "coming back the next day did not advance the streak")
	t:eq(Economy.get(player) - before, Config.Sessions.DailyRewards[2],
		"day two paid the wrong rung of the ladder")
end)

T.spec("a three-bucket gap survives; a four-bucket gap resets to one", function(t)
	-- graceBuckets = 1 + floor(DailyGraceHours / 24) = 3. This boundary IS the
	-- grace period; every other assertion about grace is downstream of it.
	local w = T.retention()
	local Config = w.config
	local player, profile = seated(w, "traveller")
	t:eq(Config.Sessions.DailyGraceHours, 48, "the grace window this spec pins has moved")

	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 1, "the fixture did not start at one")

	w.clock:skip(3 * DAY)
	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 2,
		"a three-bucket gap reset a streak that 48 hours of grace should have carried")

	w.clock:skip(4 * DAY)
	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 1,
		"a four-bucket gap kept the streak alive — the grace window is wider than it says")
end)

T.spec("day seven pays its rung plus the milestone; day eight wraps to day one", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "veteran")

	t:eq(Config.Sessions.DailyRewards[7], 150000, "the day-seven rung has moved")
	t:eq(Config.Sessions.DailyMilestones[7], 250000, "the seven-day milestone has moved")

	-- six days in, claimed yesterday
	profile.sessions.streak = 6
	profile.sessions.dailyDay = dayBucket() - 1

	local before = Economy.get(player)
	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 7, "the seventh day did not land on streak seven")
	t:eq(Economy.get(player) - before, 150000 + 250000,
		"day seven did not pay its rung plus the seven-day milestone")

	-- the ladder LOOPS; the milestones carry the long tail
	w.clock:skip(DAY)
	before = Economy.get(player)
	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 8, "the streak stopped counting past the length of the ladder")
	t:eq(Economy.get(player) - before, Config.Sessions.DailyRewards[1],
		"day eight did not wrap to the first rung of the ladder")
	t:isNil(Config.Sessions.DailyMilestones[8], "day eight has grown a milestone this spec does not expect")
end)

T.spec("a streak claimed either side of midnight on New Year's Eve advances", function(t)
	-- 2026-12-31T23:59:00Z. Day-of-year is 365 here and 1 two minutes later, so
	-- a streak keyed on os.date("%j") computes a gap of -364 and resets every
	-- player in the game on the same night. Day buckets do not care.
	local w = T.retention()
	local player, profile = seated(w, "newyear")

	w.clock:set(1798761540)
	t:eq(tonumber(os.date("!%j")), 365, "the fixture is not sitting on New Year's Eve any more")

	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 1, "the fixture did not start the streak")
	local bucket = profile.sessions.dailyDay

	w.clock:skip(120)
	t:eq(tonumber(os.date("!%j")), 1, "the fixture no longer crosses the year boundary")
	t:eq(dayBucket(), bucket + 1, "two minutes past midnight is not the next day bucket")

	claim(w, player, { kind = "daily" })
	t:eq(profile.sessions.streak, 2,
		"the streak reset across New Year — day-of-year arithmetic has crept back into nextStreak")
end)

end
