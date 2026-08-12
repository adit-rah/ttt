--[[
	weekend_spec.lua — double income on Saturday and Sunday, everywhere at once.

	Near-zero code and a real concurrency effect: three lines that read

		S.WeekendDays[os.date("!*t").wday] == true

	and the entire behaviour lives in that leading `!`. Without it the weekend
	starts when the machine hosting that particular server thinks it starts,
	which means two players in the same game get different multipliers, the
	bonus rolls over at seven different local midnights, and nobody can tell you
	which server they were on. The bug is invisible on any developer's machine
	that happens to be running UTC.

	So the spec that carries this file is the last one: 23:59:59Z on Sunday pays
	double and one second later does not. It pins the boundary to the second, in
	UTC, and it only passes if os.date is being asked for UTC time — which in
	turn only works because the mock delegates to the real os.date with an
	explicit timestamp instead of reimplementing the civil calendar.

	The Saturday-plus-boost spec is here rather than in boost_spec because it is
	a statement about STACKING: two independent multipliers registered through
	one Economy hook, and the only way they can come out as 4 is if both of them
	multiply. A 3 means someone added them; a 2 means one of them is being
	silently dropped on the days the other one applies.
]]

return function(T)

T.family("weekend", "the weekend bonus is UTC, and it stacks rather than replaces")

-- 2026-01-03T00:00:00Z, a Saturday. The suite's default seed is deliberately a
-- Thursday so that no other spec picks this up by accident.
local SATURDAY = 1767398400
local SUNDAY = SATURDAY + 86400
local MONDAY = SATURDAY + 2 * 86400

--- A running server with one loaded profile. `Economy.multiplier` is the
--- observation point on purpose: the weekend has to arrive through the same
--- hook every payout already goes through, not through a second path only the
--- session panel reads.
local function seated(w, name: string)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	Session.start()
	local player = w.join(name)
	return player, Data.load(player)
end

T.spec("Saturday and Sunday pay double; Monday does not", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player = seated(w, "weekender")

	t:eq(Config.Sessions.WeekendMultiplier, 2, "the weekend multiplier this spec pins has moved")
	t:isTrue(Config.Sessions.WeekendDays[7], "Saturday is no longer a weekend day")
	t:isTrue(Config.Sessions.WeekendDays[1], "Sunday is no longer a weekend day")

	w.clock:set(SATURDAY)
	t:eq(os.date("!*t").wday, 7, "the fixture epoch is not a Saturday any more")
	t:eq(Economy.multiplier(player), 2, "Saturday did not pay the weekend multiplier")

	w.clock:set(SUNDAY)
	t:eq(os.date("!*t").wday, 1, "the fixture epoch is not a Sunday any more")
	t:eq(Economy.multiplier(player), 2, "Sunday did not pay the weekend multiplier")

	w.clock:set(MONDAY)
	t:eq(os.date("!*t").wday, 2, "the fixture epoch is not a Monday any more")
	t:eq(Economy.multiplier(player), 1, "Monday paid the weekend multiplier")
end)

T.spec("a boost on a Saturday is x4, not x3 and not x2", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "partier")

	w.clock:set(SATURDAY)
	t:eq(Economy.multiplier(player), 2, "the fixture is not on a weekend")

	profile.sessions.boostUntil = os.time() + Config.Sessions.BoostSeconds
	t:eq(Economy.multiplier(player), 4,
		"the weekend and the boost are not stacking multiplicatively through the Economy hook")

	-- the same boost off the weekend is only the boost
	w.clock:set(MONDAY)
	profile.sessions.boostUntil = os.time() + Config.Sessions.BoostSeconds
	t:eq(Economy.multiplier(player), 2, "the weekend multiplier is being applied on a Monday")
end)

T.spec("the weekend ends at midnight UTC, to the second", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local player = seated(w, "nightowl")

	w.clock:set(SUNDAY + 86399)
	t:eq(os.date("!%H:%M:%S"), "23:59:59", "the fixture is not sitting on the last second of Sunday")
	t:eq(Economy.multiplier(player), 2,
		"the weekend ended before Sunday did — os.date is being read in machine-local time, not UTC")

	w.clock:set(SUNDAY + 86400)
	t:eq(os.date("!%H:%M:%S"), "00:00:00", "the fixture did not land on midnight")
	t:eq(Economy.multiplier(player), 1,
		"the weekend ran past midnight UTC — os.date is being read in machine-local time")
end)

end
