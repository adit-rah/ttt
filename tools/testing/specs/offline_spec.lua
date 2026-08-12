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

	Then the file's stated invariant, which nothing else in the repo can check:
	the rebirth multiplier and the generator ARE banked while you are logged out,
	and an active boost is NOT. A boost is bought with presence. Banking it is the
	exact opposite of the point, and the code that excludes it is an ABSENCE — no
	line mentions the boost at all — so only a test that turns a boost on and
	watches the number not move can defend it.

	THE VAULT TIMER is the last family here, and it is new. The cap upgrade was
	advertised on the welcome-back panel for two rounds with no way to buy it:
	`offlineCapLevel` was clamped on read and read on payout and WRITTEN BY
	NOTHING in the repo, so the panel named a product that did not exist. The
	specs below drive the purchase through the real RequestClaim remote and pin
	the four things a purchase has to get right — it charges the configured
	price, it charges it once, it refuses when the money is not there, and it
	changes the payout it was sold on.
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

-- ─────────────────────────────────────────────────────────────────────────────
-- the Vault Timer
-- ─────────────────────────────────────────────────────────────────────────────

--- Push the purchase through the real remote. The client sends an INTENT with
--- no level and no price in it, which is the property most worth having a test
--- hold: everything about what this costs is decided server-side.
local function buyVaultTimer(w, player)
	local folder = w.replicatedStorage:FindFirstChild("TungNet")
	local remote = folder and folder:FindFirstChild("RequestClaim")
	assert(remote, "harness: no RequestClaim remote in TungNet")
	w.clock:advance(0.5)          -- clear the 0.25s per-player flood guard
	remote.OnServerEvent:Fire(player, { kind = "capUpgrade" })
end

--- A running server with one live session, which the claim path needs.
local function shopping(w, name: string)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	Session.start()
	local player = w.join(name)
	local profile = Data.load(player)
	Session.onPlayer(player)
	return player, profile
end

T.spec("the panel offers the next Vault Timer, and buying it charges the configured price", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = shopping(w, "buyer")

	local cost = Config.Offline.CapUpgradeCost[1]
	t:eq(cost, 250000, "the price this spec pins has moved")

	-- the offer is part of the replicated state, not a line in a modal
	local offered = Session.stateFor(player).capUpgrade
	t:notNil(offered, "the session panel is not offering a Vault Timer at cap level 0")
	t:eq(offered.level, 1, "the panel is offering the wrong rung")
	t:eq(offered.cost, cost, "the panel is quoting a price the server does not charge")
	t:eq(Session.stateFor(player).capHours, Config.Offline.CapHours,
		"the panel is quoting a cap the payout does not use")

	profile.cash = cost + 7
	buyVaultTimer(w, player)

	t:eq(profile.sessions.offlineCapLevel, 1,
		"the purchase did not raise offlineCapLevel — the field still has no writer")
	t:eq(Economy.get(player), 7, "the Vault Timer charged something other than its price")
	t:eq(Session.offlineCapHours(profile), Config.Offline.CapUpgradeHours[1],
		"the bought cap is not the cap the payout uses")
	t:eq(Session.stateFor(player).capUpgrade.level, 2,
		"the panel is still offering the rung that was just bought")
end)

T.spec("a Vault Timer nobody can afford is refused and charges nothing", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = shopping(w, "broke")

	profile.cash = Config.Offline.CapUpgradeCost[1] - 1
	buyVaultTimer(w, player)

	t:eq(profile.sessions.offlineCapLevel, 0,
		"a player one tung short bought the Vault Timer anyway")
	t:eq(Economy.get(player), Config.Offline.CapUpgradeCost[1] - 1,
		"a refused purchase still moved the wallet")
	t:eq(Session.offlineCapHours(profile), Config.Offline.CapHours,
		"a refused purchase still extended the cap")
end)

T.spec("the ladder runs out rather than wrapping, and the top rung stops being offered", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = shopping(w, "collector")

	local top = #Config.Offline.CapUpgradeHours
	profile.sessions.offlineCapLevel = top
	profile.cash = 1e15

	t:isNil(Session.stateFor(player).capUpgrade,
		"the panel is upselling a Vault Timer past the end of the ladder")

	buyVaultTimer(w, player)
	t:eq(profile.sessions.offlineCapLevel, top,
		"a purchase past the top of the ladder incremented the level anyway")
	t:eq(Economy.get(player), 1e15, "a purchase past the top of the ladder still took the money")
end)

T.spec("a bought Vault Timer survives a save and changes the next payout", function(t)
	-- The purchase only means anything if it reaches the DataStore and then
	-- reaches the ARITHMETIC. `offlineCapLevel` already rode along in
	-- profile.sessions before anything could write it, so this is the spec that
	-- says the write and the persistence line up.
	local w = T.retention()
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local Config = w.config
	Data.start()
	local player, profile = shopping(w, "commuter")

	profile.owned.dropper1 = true
	profile.cash = Config.Offline.CapUpgradeCost[1]
	buyVaultTimer(w, player)
	t:eq(profile.sessions.offlineCapLevel, 1, "the fixture never bought the timer")

	-- Leaving is what saves, and it is also what ends the live session — which
	-- matters, because a session that is still ticking keeps stamping lastSeen
	-- and there would be no absence to pay for.
	local userId = player.UserId
	profile.lastSeen = os.time()
	w.leave(player)

	local stored = w.store():raw("player_" .. userId)
	t:eq(stored.sessions.offlineCapLevel, 1, "the bought cap level did not reach the DataStore")

	-- and back in, twenty hours later: the 8-hour cap would have clipped this
	w.clock:skip(20 * 3600)
	local rejoined = w.join("commuter", userId)
	Data.load(rejoined)
	Session.onPlayer(rejoined)
	local offline = Session.stateFor(rejoined).offline
	t:notNil(offline, "twenty hours away paid nothing at all")
	t:eq(offline.capHours, Config.Offline.CapUpgradeHours[1],
		"the payout used the default cap, not the one that was bought and saved")
	t:isTrue(offline.clipped, "a 20-hour absence against a 12-hour cap did not clip")
	t:eq(offline.creditedSeconds, Config.Offline.CapUpgradeHours[1] * 3600,
		"the credited hours are not the hours the Vault Timer bought")
end)

end
