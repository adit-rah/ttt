--[[
	offline_spec.lua — what the factory pays for the hours nobody was watching.

	Offline earnings are the one payout in the game that is computed entirely
	from a SAVED blob and a subtraction of two clocks. There is no plot to ask,
	no client to correct it and no player watching it happen — which means every
	one of its failure modes is silent, arrives as a number in someone's wallet,
	and is only ever noticed when it is enormous.

	So this family pins the arithmetic from both ends:

	  * the BOUNDARIES, where a payout appears or disappears — a first session
	    (lastSeen == 0), the 120-second floor from either side, the 8-hour cap,
	    the cap after it has been bought up, an empty factory, and a clock that
	    went BACKWARDS. That last one is the reason `away < MinimumSeconds`
	    is written as a floor rather than as an abs(): a host migration or an NTP
	    correction moves os.time() and nothing else, and the only tool in this
	    repo that can reproduce it is `w.clock:set()`.

	  * the RATE, contributor by contributor. `incomePerSecondFor` is a hand
	    mirror of `Tycoon:incomePerSecond` and it exists because an offline
	    player has no Tycoon to ask. Two mirrors of one formula drift; asserting
	    each term separately is what makes the drift land on a named line.

	The last spec is the file's stated invariant and nothing else in the repo can
	check it: the rebirth multiplier and the generator ARE banked while you are
	logged out, and an active boost is NOT. A boost is bought with presence.
	Banking it is the exact opposite of the point, and the code that excludes it
	is an ABSENCE — no line mentions the boost at all — so only a test that turns
	a boost on and watches the number not move can defend it.
]]

return function(T)

T.family("offline", "the welcome-back payout, its boundaries and the rate it is paid at")

--- A joined player with a loaded profile, in a world with the flags on.
local function arrive(w, name: string)
	local Data = w.req("DataService")
	local player = w.join(name)
	return player, Data.load(player)
end

--- What the welcome-back panel would show, computed the way a real join does.
local function offlineFor(w, player)
	local Session = w.req("SessionService")
	Session.onPlayer(player)
	local state = Session.stateFor(player)
	return state and state.offline
end

T.spec("a first session pays nothing, because lastSeen 0 is not a logout", function(t)
	local w = T.retention()
	local player, profile = arrive(w, "newcomer")
	profile.owned.dropper1 = true

	t:eq(profile.lastSeen, 0, "a fresh profile is being seeded with a logout time it never had")

	w.clock:skip(4 * 3600)
	t:isNil(offlineFor(w, player),
		"a profile that has never logged out was paid for the whole epoch")

	-- and the session takes ownership of the stamp on the way in
	t:eq(profile.lastSeen, os.time(),
		"onPlayer did not stamp lastSeen, so the next join computes from a stale one")
end)

T.spec("the 120-second floor is pinned from both sides", function(t)
	local w = T.retention()
	local Config = w.config
	t:eq(Config.Offline.MinimumSeconds, 120, "the floor this spec pins has moved")

	local quiet, quietProfile = arrive(w, "quiet")
	quietProfile.owned.dropper1 = true
	quietProfile.lastSeen = os.time() - 119
	t:isNil(offlineFor(w, quiet),
		"a 119-second absence opened the welcome-back panel; the floor is off by one")

	local loud, loudProfile = arrive(w, "loud")
	loudProfile.owned.dropper1 = true
	loudProfile.lastSeen = os.time() - 121
	local offline = offlineFor(w, loud)
	t:notNil(offline, "a 121-second absence paid nothing; the floor is off by one")
	t:eq(offline and offline.seconds, 121, "the panel is quoting the wrong absence")
	t:gt(offline and offline.earned or 0, 0, "the panel opened with a zero payout in it")
end)

T.spec("four hours away pays four hours at the offline rate, unclipped", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config

	local player, profile = arrive(w, "shift")
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.lastSeen = os.time()

	w.clock:skip(4 * 3600)
	local offline = offlineFor(w, player)
	local perSecond = Session.incomePerSecondFor(profile)

	t:notNil(offline, "four hours away paid nothing at all")
	t:eq(offline.seconds, 14400, "the absence was measured wrong")
	t:eq(offline.creditedSeconds, 14400, "an absence inside the cap must be credited whole")
	t:eq(offline.earned, math.floor(14400 * perSecond * Config.Offline.Rate),
		"the payout is not floor(seconds x income/sec x rate)")
	t:eq(offline.rate, 0.25, "the offline rate on the panel is not the rate that was paid")
	t:isFalse(offline.clipped, "four hours was reported as clipped against an eight-hour cap")
	t:eq(offline.lost, 0, "an unclipped absence lost income")
end)

T.spec("twenty hours clips at eight, states what was lost and names the fix", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config

	local player, profile = arrive(w, "sleeper")
	profile.owned.dropper1 = true
	profile.lastSeen = os.time()

	w.clock:skip(20 * 3600)
	local offline = offlineFor(w, player)
	local perSecond = Session.incomePerSecondFor(profile)
	local cap = Config.Offline.CapHours * 3600

	t:eq(offline.seconds, 72000, "the absence was measured wrong")
	t:eq(offline.creditedSeconds, cap, "the eight-hour cap did not clip a twenty-hour absence")
	t:isTrue(offline.clipped, "a clipped payout is not telling the player it was clipped")
	t:eq(offline.capHours, 8, "the panel is quoting a cap the payout did not use")
	t:eq(offline.earned, math.floor(cap * perSecond * Config.Offline.Rate),
		"the payout is not floor(cap x income/sec x rate)")
	t:eq(offline.lost, math.floor((72000 - cap) * perSecond * Config.Offline.Rate),
		"the hours over the cap are not being reported as lost")

	-- "we took your money" vs "here is what to buy"
	t:notNil(offline.upgrade, "a clipped payout offered no cap upgrade to buy")
	t:eq(offline.upgrade.name, "Vault Timer 1", "the upgrade on the panel is not the next rung")
	t:eq(offline.upgrade.level, 1, "the upgrade on the panel is not the next rung")
	t:eq(offline.upgrade.hours, 12, "Vault Timer 1 is not quoting the 12-hour cap it grants")
	t:eq(offline.upgrade.cost, Config.Offline.CapUpgradeCost[1], "the upgrade is quoting the wrong price")
end)

T.spec("at the top cap level twenty hours does not clip and nothing is upsold", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")

	local player, profile = arrive(w, "vaulted")
	profile.owned.dropper1 = true
	profile.sessions.offlineCapLevel = 3
	profile.lastSeen = os.time()

	t:eq(Session.offlineCapHours(profile), 24, "the top Vault Timer is not banking 24 hours")

	w.clock:skip(20 * 3600)
	local offline = offlineFor(w, player)

	t:eq(offline.creditedSeconds, 72000, "a paid-for 24-hour cap still clipped at twenty hours")
	t:isFalse(offline.clipped, "a payout inside the purchased cap was reported as clipped")
	t:eq(offline.lost, 0, "a payout inside the purchased cap lost income")
	t:isNil(offline.upgrade, "the panel is upselling a Vault Timer that does not exist")
end)

T.spec("a clock that went backwards pays nothing", function(t)
	-- A host migration or an NTP correction moves os.time() and leaves
	-- os.clock() alone. `away` goes NEGATIVE, and the only two honest answers
	-- are "nothing" and "a number with a sign error in it worth billions".
	local w = T.retention()
	local player, profile = arrive(w, "drifter")
	profile.owned.dropper1 = true
	profile.owned.upgrader1 = true
	profile.lastSeen = os.time()

	w.clock:set(os.time() - 3600)
	t:isNil(offlineFor(w, player),
		"a backwards clock produced a payout; `away` is being used without a floor")
end)

T.spec("an empty factory pays nothing for eight hours of nothing", function(t)
	local w = T.retention()
	local player, profile = arrive(w, "empty")
	profile.lastSeen = os.time()

	w.clock:skip(8 * 3600)
	t:isNil(offlineFor(w, player),
		"a player with no droppers was paid offline income")
end)

T.spec("income per second is droppers x upgraders x power x rebirth, term by term", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config

	local _, profile = arrive(w, "accountant")
	t:eq(Session.incomePerSecondFor(profile), 0, "an empty factory quotes an income")

	-- Pinned against the shipped numbers once, so the derivations below cannot
	-- drift with Config and stay green.
	local d1, d2 = Config.ButtonById.dropper1, Config.ButtonById.dropper2
	local up1, pw1 = Config.ButtonById.upgrader1, Config.ButtonById.power1
	t:eq(d1.dropValue / d1.dropRate, 1 / 1.5, "dropper1 is no longer 1 tung every 1.5s")
	t:eq(up1.multiplier, 1.6, "upgrader1 is no longer x1.6")
	t:eq(pw1.factor, 1.19, "power1 is no longer x1.19")
	t:eq(Config.Rebirth.MultiplierPerRebirth, 2.25, "the rebirth multiplier has moved")

	-- droppers SUM, as value per second each
	profile.owned.dropper1 = true
	t:near(Session.incomePerSecondFor(profile), d1.dropValue / d1.dropRate, 1e-9,
		"one dropper is not being quoted as dropValue/dropRate")

	profile.owned.dropper2 = true
	local droppers = d1.dropValue / d1.dropRate + d2.dropValue / d2.dropRate
	t:near(Session.incomePerSecondFor(profile), droppers, 1e-9,
		"two droppers are not summing")

	-- upgraders MULTIPLY the sum
	profile.owned.upgrader1 = true
	t:near(Session.incomePerSecondFor(profile), droppers * up1.multiplier, 1e-9,
		"the upgrader is not multiplying the dropper total")

	-- the generator multiplies too: it is a property of the factory, standing
	-- in the yard whether or not anyone is logged in
	profile.owned.power1 = true
	local powered = droppers * up1.multiplier * pw1.factor
	t:near(Session.incomePerSecondFor(profile), powered, 1e-9,
		"the generator is not banked offline, so the yard pays as though it were empty")

	-- and so does rebirth, for the same reason
	profile.rebirths = 2
	local expected = powered * (Config.Rebirth.MultiplierPerRebirth ^ 2)
	t:near(Session.incomePerSecondFor(profile), expected, 1e-9,
		"the rebirth multiplier is not being banked offline")
end)

T.spec("an active boost does NOT reach the offline rate", function(t)
	-- The file's stated invariant, and an invariant held up by an ABSENCE: no
	-- line of incomePerSecondFor mentions the boost, so nothing but this spec
	-- stops someone "fixing" the offline payout by routing it through
	-- Economy.multiplier. A boost is bought with presence. Banking it while
	-- logged out is the opposite of the point.
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	local Config = w.config
	Session.start()

	local player, profile = arrive(w, "booster")
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.owned.upgrader1 = true
	local unboosted = Session.incomePerSecondFor(profile)
	t:gt(unboosted, 0, "the fixture has no factory, so the assertion below proves nothing")

	profile.sessions.boostUntil = os.time() + Config.Sessions.BoostSeconds
	t:eq(Economy.multiplier(player), Config.Sessions.BoostMultiplier,
		"the boost is not actually live, so the exclusion below proves nothing")

	t:near(Session.incomePerSecondFor(profile), unboosted, 1e-9,
		"an active boost leaked into the offline mirror — presence-bought income is being banked while logged out")
end)

end
