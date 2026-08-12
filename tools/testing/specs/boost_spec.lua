--[[
	boost_spec.lua — the rewarded-video button with the video taken out.

	Ten minutes of double income, then forty minutes of cooldown. There is no ad
	network and no purchase behind it, so the only thing standing between a
	player and permanent 2x is `boostReadyAt` — one comparison, in one function,
	with no server-side receipt to check it against. That makes the cooldown
	boundary the security boundary, and it is pinned here from three sides:
	refused a second after the boost ends, refused a second before the cooldown
	ends, and granted at exactly 2400.

	The round-trip spec is the other half. `boostUntil` and `boostReadyAt` are
	stored as ABSOLUTE UTC epochs, which is the only representation that
	survives a save: a remaining-seconds field would be frozen at logout, so
	logging out with 599 seconds of boost left and back in tomorrow would hand
	the player 599 more. The spec saves mid-boost, reloads, and asserts both the
	stored number and the remaining time it produces — because storing the epoch
	and then recomputing the remainder wrongly is the same bug with an extra
	step.

	Claims go through the real RequestBoost remote, so the flood guard and the
	state re-push are inside the test rather than beside it.
]]

return function(T)

T.family("boost", "ten minutes of x2, and the one comparison that stops it being permanent")

local function fireBoost(w, player)
	local folder = w.replicatedStorage:FindFirstChild("TungNet")
	local remote = folder and folder:FindFirstChild("RequestBoost")
	assert(remote, "harness: no RequestBoost remote in TungNet")
	remote.OnServerEvent:Fire(player)
end

--- A running server with one live player, one second in.
---
--- The second matters: the per-player flood guard is `os.clock() - lastClaim <
--- 0.25` and both sides read 0 on a brand new world, so a claim at monotonic
--- zero is refused for reasons that have nothing to do with the boost.
local function seated(w, name: string)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	Session.start()
	local player = w.join(name)
	local profile = Data.load(player)
	Session.onPlayer(player)
	w.clock:advance(1)
	return player, profile
end

T.spec("claiming stamps both clocks and doubles the multiplier immediately", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "sipper")

	t:eq(Config.Sessions.BoostSeconds, 600, "the boost duration this spec pins has moved")
	t:eq(Config.Sessions.BoostCooldown, 2400, "the boost cooldown this spec pins has moved")
	t:eq(Economy.multiplier(player), 1, "the fixture was already boosted")

	fireBoost(w, player)
	local now = os.time()

	t:eq(profile.sessions.boostUntil, now + 600, "the boost is not running for its configured duration")
	t:eq(profile.sessions.boostReadyAt, now + 2400, "the cooldown was not stamped when the boost was granted")
	t:eq(Economy.multiplier(player), 2,
		"claiming a boost did not change the multiplier — the hook is not registered or not reading boostUntil")
end)

T.spec("the boost is live at 599 seconds and dead at 601", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local player = seated(w, "timer")

	fireBoost(w, player)
	w.clock:skip(599)
	t:eq(Economy.multiplier(player), 2, "the boost expired before its 600 seconds were up")

	w.clock:skip(2)
	t:eq(Economy.multiplier(player), 1, "the boost outlived its 600 seconds")
end)

T.spec("a re-claim is refused until exactly 2400 seconds have passed", function(t)
	local w = T.retention()
	local player, profile = seated(w, "greedy")

	fireBoost(w, player)
	local first = os.time()
	t:eq(profile.sessions.boostUntil, first + 600, "the fixture never got its first boost")

	-- the boost is over, the cooldown is not
	w.clock:skip(601)
	fireBoost(w, player)
	t:eq(profile.sessions.boostUntil, first + 600,
		"a second boost was granted 601s in — the cooldown is only as long as the boost")

	-- one second short
	w.clock:skip(2399 - 601)
	fireBoost(w, player)
	t:eq(profile.sessions.boostUntil, first + 600,
		"a second boost was granted one second before the cooldown expired")
	t:eq(profile.sessions.boostReadyAt, first + 2400,
		"a refused claim still moved the cooldown")

	-- and on the second it expires
	w.clock:skip(1)
	t:eq(os.time(), first + 2400, "the fixture is not sitting exactly on the cooldown boundary")
	fireBoost(w, player)
	t:eq(profile.sessions.boostUntil, first + 2400 + 600,
		"the cooldown did not expire at exactly 2400 seconds")
	t:eq(profile.sessions.boostReadyAt, first + 2400 + 2400,
		"the second grant did not restamp the cooldown")
end)

T.spec("a boost survives a save and reload with the right time left on it", function(t)
	local w = T.retention()
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local player, profile = seated(w, "commuter")

	fireBoost(w, player)
	local started = os.time()
	w.clock:skip(300)

	t:isTrue(Data.save(player, true), "the mid-boost save did not go through")

	local stored = w.store():raw("player_" .. player.UserId)
	t:notNil(stored.sessions, "the sessions sub-table did not reach the DataStore")
	t:eq(stored.sessions.boostUntil, started + 600,
		"boostUntil was stored as a remaining duration rather than an absolute epoch")
	t:eq(stored.sessions.boostReadyAt, started + 2400,
		"boostReadyAt was stored as a remaining duration rather than an absolute epoch")

	local reloaded = Data.load(player)
	t:ne(reloaded, profile, "the reload handed back the in-memory profile, so nothing was round-tripped")
	t:eq(reloaded.sessions.boostUntil, started + 600, "boostUntil did not survive the round trip")

	-- and the derived remainder, which is where an absolute epoch stored
	-- correctly can still be read back wrongly
	local boost = Session.stateFor(player).boost
	t:isTrue(boost.active, "a boost with five minutes left read as inactive after a reload")
	t:eq(boost.secondsLeft, 300, "the remaining boost time is wrong after a reload")
	t:eq(boost.cooldownLeft, 2100, "the remaining cooldown is wrong after a reload")
end)

T.spec("the boost multiplies the rebirth multiplier rather than adding to it", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	local player, profile = seated(w, "prestiged")

	profile.rebirths = 3
	local rebirthOnly = Config.Rebirth.MultiplierPerRebirth ^ 3
	t:near(Economy.multiplier(player), rebirthOnly, 1e-9, "the fixture's rebirths are not being counted")

	fireBoost(w, player)
	t:near(Economy.multiplier(player), rebirthOnly * Config.Sessions.BoostMultiplier, 1e-9,
		"the boost is not stacking multiplicatively with rebirth")
end)

end
