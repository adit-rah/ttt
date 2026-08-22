--[[
	vault_spec.lua — the number the vault promises on your way out.

	The gauge on the side of the vault is world-space geometry and a string, so
	almost none of it can be asserted outside Studio. What CAN be asserted is
	the only part of it that carries a number, and it is the part that would be
	wrong silently: `SessionService.vaultProjectionFor`, which turns a saved
	profile into "leaving now banks X over Nh" and into the fraction of the
	column that gets filled.

	Three things go wrong here and none of them throw:

	  * THE WRONG INCOME. `Tycoon:incomePerSecond` and
	    `SessionService.incomePerSecondFor` are two mirrors of one formula and
	    the plot has an instance of the first one right there, sitting on the
	    same object the sign is bolted to. It is the obvious thing to reach for
	    and it is the wrong one: Economy.multiplier — boost, weekend, friends —
	    feeds the live number and is deliberately excluded from the offline one.
	    A vault quoting the boosted rate promises an offline payout at a rate
	    offline will never pay, and it does it in the player's favour, so the
	    only way anyone finds out is by collecting less than the sign said.
	    Held up by an ABSENCE in the source, exactly as offline_spec's last
	    case is, so only turning a boost on and watching the number NOT move
	    defends it.

	  * A DIVISION BY AN EMPTY FACTORY. capacity is income x rate x hours, and a
	    player who has bought nothing has income 0. banked/capacity is then
	    0/0 = nan, math.clamp(nan, ...) is nan, and a part sized nan studs tall
	    is a Roblox error thrown from inside a render-adjacent setter every
	    five seconds for as long as that plot is claimed.

	  * THE CLAMP AT BOTH ENDS. FillMin exists because Roblox will not accept a
	    zero-height part; 1 exists because a grant can exceed the capacity that
	    is being drawn as the denominator — buy a Vault Timer, be away, then let
	    the cap tier be re-read at a lower level, or simply arrive with a grant
	    computed against a factory that has since been rebirthed away. Neither
	    end is theoretical and neither end is visible in the geometry.
]]

return function(T)

T.family("vault", "what the vault promises on the way out, and how full it draws itself")

--- A joined player with a loaded profile, in a world with the flags on.
local function arrive(w, name: string)
	local Data = w.req("DataService")
	local player = w.join(name)
	return player, Data.load(player)
end

T.spec("an empty factory promises nothing and does not divide by it", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")

	local _, profile = arrive(w, "newcomer")
	local p = Session.vaultProjectionFor(profile, 0)

	t:eq(p.perSecond, 0, "a factory with nothing in it quotes an income")
	t:eq(p.capacity, 0, "a factory with nothing in it has something to bank")

	-- The one that matters: 0/0 is nan, and nan survives math.clamp.
	t:eq(p.fraction, p.fraction, "the fill fraction is nan — banked/capacity divided by an empty factory")
	t:eq(p.fraction, w.config.Offline.Vault.FillMin,
		"an empty vault does not draw at the minimum fill, so its column is either invisible or illegal")
end)

T.spec("capacity is offline income for a full cap, and the cap is the one you bought", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config

	local _, profile = arrive(w, "builder")
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.owned.upgrader1 = true

	local p = Session.vaultProjectionFor(profile, 0)
	local perSecond = Session.incomePerSecondFor(profile)

	t:gt(perSecond, 0, "the fixture has no factory, so nothing below proves anything")
	t:eq(p.perSecond, perSecond, "the projection is not quoting the offline income mirror")
	t:eq(p.rate, Config.Offline.Rate, "the projection is quoting a rate the payout does not use")
	t:eq(p.capHours, 8, "an un-upgraded vault is not projecting the shipped 8-hour cap")
	t:near(p.capacity, perSecond * Config.Offline.Rate * 8 * 3600, 1e-6,
		"capacity is not income/sec x rate x cap hours")

	-- The Vault Timer is the purchase that makes the promise bigger, which is
	-- the entire reason the headline quotes the hours as well as the amount.
	profile.sessions.offlineCapLevel = 3
	local upgraded = Session.vaultProjectionFor(profile, 0)
	t:eq(upgraded.capHours, 24, "a bought-up Vault Timer does not reach the sign")
	t:near(upgraded.capacity, p.capacity * 3, 1e-6,
		"tripling the cap hours did not triple what the vault promises to bank")
end)

T.spec("banked nothing draws an empty column; banked half draws a half one", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config

	local _, profile = arrive(w, "midway")
	profile.owned.dropper1 = true
	profile.owned.dropper3 = true

	local empty = Session.vaultProjectionFor(profile, 0)
	t:eq(empty.banked, 0, "an online player has something already banked")
	t:eq(empty.fraction, Config.Offline.Vault.FillMin,
		"a vault with nothing in it is not drawing empty — the exit hook would read as already full")

	local half = Session.vaultProjectionFor(profile, empty.capacity / 2)
	t:near(half.fraction, 0.5, 1e-9, "half a vault's worth does not draw half a column")
	t:near(half.banked, empty.capacity / 2, 1e-6, "the projection is not reporting what was banked")
end)

T.spec("the fill fraction clamps at both ends", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Config = w.config
	local FillMin = Config.Offline.Vault.FillMin

	local _, profile = arrive(w, "clamped")
	profile.owned.dropper1 = true
	local capacity = Session.vaultProjectionFor(profile, 0).capacity
	t:gt(capacity, 0, "the fixture has no capacity, so neither clamp below is exercised")

	-- FLOOR. A part cannot be zero studs tall, and a sliver of gold in an empty
	-- pane is the difference between "nothing yet" and "broken".
	t:eq(Session.vaultProjectionFor(profile, 0).fraction, FillMin,
		"an empty vault asks for a zero-height part")
	t:eq(Session.vaultProjectionFor(profile, capacity * FillMin / 2).fraction, FillMin,
		"a grant under the minimum fill is not being floored")

	-- CEILING. A grant bigger than the capacity being drawn is reachable — a
	-- rebirth between banking and collecting shrinks the denominator and leaves
	-- the numerator alone — and an unclamped fraction is a column of gold
	-- standing several studs above the vault it is supposed to be inside.
	t:eq(Session.vaultProjectionFor(profile, capacity).fraction, 1,
		"a full vault does not draw full")
	t:eq(Session.vaultProjectionFor(profile, capacity * 40).fraction, 1,
		"a grant over capacity draws a column taller than the vault it sits in")

	-- And a negative banked amount, which is what a corrupted profile field
	-- reaches this function as. The clamp already hides it from the COLUMN, so
	-- the assertion that bites is on the reported figure: `banked` is the
	-- number the headline says is waiting, and "-2.4M WAITING" is a sign that
	-- has to be read as a bug rather than as a gauge drawn slightly wrong.
	local negative = Session.vaultProjectionFor(profile, -capacity)
	t:eq(negative.banked, 0, "a negative grant reached the headline as a negative amount")
	t:eq(negative.fraction, FillMin, "a negative grant drew a negative column")
end)

T.spec("a grant bigger than the cap is still one full column, not more", function(t)
	-- The returning-player half, computed the way a real join does it: twenty
	-- hours away against an eight-hour cap. The grant is clipped by
	-- computeOffline, so the column must land at exactly full — a vault that
	-- draws over-full for the one player who has been away longest is the
	-- opposite of the intended reward.
	local w = T.retention()
	local Session = w.req("SessionService")

	local player, profile = arrive(w, "sleeper")
	profile.owned.dropper1 = true
	profile.owned.upgrader1 = true
	profile.lastSeen = os.time()

	w.clock:skip(20 * 3600)
	Session.onPlayer(player)

	local pending = Session.pendingOffline(player)
	t:notNil(pending, "twenty hours away produced no pending grant to draw")
	t:isTrue(pending.clipped, "the fixture was not clipped, so the ceiling below is untested")

	local p = Session.vaultProjectionFor(profile, pending.earned)
	t:eq(p.banked, pending.earned, "the gauge is not drawing the grant that is actually waiting")
	t:eq(p.fraction, 1, "a capped grant does not fill the column exactly")
end)

T.spec("pendingOffline is the live grant, and it goes away when it is collected", function(t)
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	Session.start()

	local player, profile = arrive(w, "collector")
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.lastSeen = os.time()

	t:isNil(Session.pendingOffline(player), "a player who has not joined yet has a grant waiting")

	w.clock:skip(4 * 3600)
	Session.onPlayer(player)
	local pending = Session.pendingOffline(player)
	t:notNil(pending, "four hours away left nothing for the vault to show")

	local before = Economy.get(player)
	t:isTrue(Session.claimOfflineFor(player), "the prompt path did not pay out")
	-- The grant is deliberately NOT exempt from the storage cap (#98): it
	-- fills the unit and the rest is lost, which is the return-visit
	-- pressure the cap exists to create. Four hours on this fixture's
	-- factory overflows a 30-minute cap, so the clip is the contract here.
	local granted = Economy.get(player) - before
	t:eq(granted, math.min(pending.earned, Economy.storageCapFor(player) - before),
		"the grant must fill the unit to its cap and lose the rest")
	t:gt(granted, 0, "the clip took the whole grant")

	-- entry.offline is cleared BEFORE the payout, which is the guard that makes
	-- a prompt and a panel button safe to have at the same time.
	t:isNil(Session.pendingOffline(player), "the grant survived being collected")
	t:isFalse(Session.claimOfflineFor(player), "the vault prompt paid the same grant twice")
	t:eq(Economy.get(player) - before, granted, "a second trigger paid a second time")
end)

T.spec("the gauge setter survives a collector that has no gauge on it", function(t)
	-- Every upper floor gets a collector too, built by the same function with
	-- `headline` false: no sign, no statue, no pane, no prompt. VaultService
	-- walks Tycoon.all() and does not know which of those a given plot is, so
	-- the setter has to be a no-op on the parts that are not there rather than
	-- an error thrown out of a 5-second loop.
	local w = T.world()
	local Tycoon = w.req("Tycoon")

	local plain = setmetatable({}, { __index = Tycoon })
	plain:setVaultGauge(0.5, "LEAVING NOW BANKS 2.4M OVER 8h", "8h  •  25%  •  84K/sec", false)
	t:eq(plain.vaultHeadline, "LEAVING NOW BANKS 2.4M OVER 8h",
		"the headline was not recorded, so updateSign has nothing to paint the sign with")

	-- ...and with a label but still no pane, which is the state a headline
	-- collector is in for the instant between the sign being built and the
	-- window after it.
	local dressed = setmetatable({}, { __index = Tycoon })
	dressed.vaultLabel = Instance.new("TextLabel", Instance.new("Folder"))
	dressed.vaultDetailLabel = Instance.new("TextLabel", Instance.new("Folder"))
	dressed:setVaultGauge(1, "2.4M WAITING", "hold E at the vault", true)
	t:eq(dressed.vaultLabel.Text, "2.4M WAITING", "the headline did not reach the board")
	t:eq(dressed.vaultDetailLabel.Text, "hold E at the vault", "the small print did not reach its board")

	-- nil headline hands the board back to updateSign rather than blanking it:
	-- a released plot must read "SAHUR VAULT", not the last owner's promise
	dressed:setVaultGauge(0, nil, nil, false)
	t:isNil(dressed.vaultHeadline, "the gauge kept the sign after handing it back")
	t:eq(dressed.vaultLabel.Text, "2.4M WAITING",
		"the setter blanked the board itself instead of leaving it for updateSign")
	t:eq(dressed.vaultDetailLabel.Text, "", "the small print outlived the state that produced it")
end)

T.spec("an active boost does NOT reach the number on the vault", function(t)
	-- The sign's stated invariant. Economy.multiplier feeds
	-- Tycoon:incomePerSecond, which is sitting on the very object this sign is
	-- bolted to and is the obvious thing to reach for — and it is the wrong
	-- one. A vault promising a boosted offline rate promises income that will
	-- never be paid, and the discovery is always the same: the player collects
	-- less than the sign said.
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	local Config = w.config
	Session.start()

	local player, profile = arrive(w, "booster")
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.owned.upgrader1 = true

	local unboosted = Session.vaultProjectionFor(profile, 0)
	t:gt(unboosted.capacity, 0, "the fixture has no factory, so the assertion below proves nothing")

	profile.sessions.boostUntil = os.time() + Config.Sessions.BoostSeconds
	t:eq(Economy.multiplier(player), Config.Sessions.BoostMultiplier,
		"the boost is not actually live, so the exclusion below proves nothing")

	local boosted = Session.vaultProjectionFor(profile, 0)
	t:near(boosted.perSecond, unboosted.perSecond, 1e-9,
		"a live boost moved the rate on the vault sign; the gauge is reading the live income, not the offline mirror")
	t:near(boosted.capacity, unboosted.capacity, 1e-9,
		"the vault is promising to bank a boost that offline earnings will never pay")
end)

end
