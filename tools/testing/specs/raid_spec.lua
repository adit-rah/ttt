--[[
	raid_spec.lua — the loot arithmetic (#94).

	What is pinned: the safe amount is structurally unreachable, spoils go to
	a CARRY instead of the raider's bank, banking is clamped by the raider's
	own cap, a death returns each victim's share, and camping one target
	halves its yield per repeat inside the window. The fake plot is a bare
	`{ owner = victim }` — onStorageBroken reads nothing else, and the break
	TRANSITION that calls it is storage_spec's territory.

	Standing-on-your-own-plot banking is CFrame arithmetic in start()'s
	heartbeat; Studio owns it, the handoff names it.
]]

return function(T)

T.family("raid", "a break spills overflow into a carry; the safe amount, the cap and a kill all bound it")

local function fund(w, name, cash)
	local Data = w.req("DataService")
	local player = w.join(name)
	local profile = Data.load(player)
	profile.cash = cash
	return player, profile
end

T.spec("a break takes from the overflow alone, and the safe amount survives", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")
	local Economy = w.req("Economy")
	local R = w.config.Raid

	local victim, vp = fund(w, "victim", 1000)   -- cap floor 1000, safe 500
	local attacker = fund(w, "attacker", 0)

	local safe = R.SafeFraction * Economy.storageCapFor(victim)
	local overflow = 1000 - safe
	local spoils = Raid.onStorageBroken({ owner = victim }, attacker, 0)

	t:eq(spoils, math.floor(R.SpillFraction * overflow),
		"the spill is a fraction of OVERFLOW; anything else can dig into the safe amount")
	t:eq(vp.cash, 1000 - spoils, "the victim lost something other than the spoils")
	t:isTrue(vp.cash >= safe, "the raid dug below the safe amount")
	t:eq(Raid.carriedBy(attacker), spoils,
		"the spoils belong in the attacker's HANDS; a direct bank credit skips the whole chase")
end)

T.spec("a broke victim pays a minted bounty and loses nothing", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")
	local Economy = w.req("Economy")
	local R = w.config.Raid

	local victim, vp = fund(w, "victim", 100)    -- under the safe line: overflow 0
	local attacker = fund(w, "attacker", 0)

	local spoils = Raid.onStorageBroken({ owner = victim }, attacker, 0)

	t:eq(spoils, math.floor(R.EmptyBountyFraction * Economy.storageCapFor(victim)),
		"an empty unit must still pay the raider, out of thin air")
	t:eq(vp.cash, 100, "the mint came out of the victim")
	t:eq(Raid.carriedBy(attacker), spoils, "the bounty is carried like any other loot")
end)

T.spec("camping the same victim halves each repeat, and the window lapsing resets it", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")
	local R = w.config.Raid

	local victim, vp = fund(w, "victim", 1000)
	local attacker = fund(w, "attacker", 0)
	local full = Raid.onStorageBroken({ owner = victim }, attacker, 0)

	vp.cash = 1000
	local second = Raid.onStorageBroken({ owner = victim }, attacker, 10)
	t:eq(second, math.floor(full * R.CampingHalving),
		"the second break inside the window paid full — camping one target never converges")

	vp.cash = 1000
	local third = Raid.onStorageBroken({ owner = victim }, attacker, 20)
	t:eq(third, math.floor(R.SpillFraction * 500 * R.CampingHalving ^ 2),
		"the third break decayed by something other than the halving squared")

	vp.cash = 1000
	local later = Raid.onStorageBroken({ owner = victim }, attacker,
		20 + R.CampingWindowSeconds + 1)
	t:eq(later, full, "the window lapsed and the yield did not recover")
end)

T.spec("banking goes through the cap, and the carry dies either way", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")
	local victim = fund(w, "victim", 4000)
	-- fill the victim well past what one break spills so the carry is big
	local raider, rp = fund(w, "raider", 900)   -- 100 of room under the floor cap

	w.config.Raid.SafeFraction = 0.0            -- this realm's config only: all 4000 exposed
	local spoils = Raid.onStorageBroken({ owner = victim }, raider, 0)
	t:isTrue(spoils > 100, "the fixture no longer overfills the raider's room")

	local banked = Raid.bankCarry(raider)
	t:eq(banked, 100,
		"the deposit ignored the raider's own cap — stolen Tung found a bigger bank than earned Tung has")
	t:eq(rp.cash, 1000, "the bank credited something other than the room available")
	t:eq(Raid.carriedBy(raider), 0, "the unbankable remainder stayed in hand instead of being lost")
end)

T.spec("death returns each share to its source, and a player kill lifts from the dead", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")
	local R = w.config.Raid

	local victim, vp = fund(w, "victim", 1000)
	local attacker, ap = fund(w, "attacker", 1000)
	local spoils = Raid.onStorageBroken({ owner = victim }, attacker, 0)
	local victimAfterRaid = vp.cash

	Raid.onPlayerDied(attacker, victim, 5)

	t:eq(vp.cash, victimAfterRaid + spoils,
		"the victim's share did not come home when the thief died")
	t:eq(Raid.carriedBy(attacker), 0, "a corpse is still carrying loot")
	-- the kill lifted a tenth of the ATTACKER's overflow (their own 1000: 500
	-- over the safe line) into the killer's hands
	t:eq(Raid.carriedBy(victim), math.floor(R.KillStealFraction * 500),
		"a player kill pays nothing — the chase has no teeth without it")
	t:eq(ap.cash, 1000 - math.floor(R.KillStealFraction * 500),
		"the kill-steal came from somewhere other than the dead player's bank")
end)

T.spec("no owner, or the owner swinging, is refused without advancing the camping ledger", function(t)
	local w = T.world()
	local Raid = w.req("RaidService")

	local victim = fund(w, "victim", 1000)
	local attacker = fund(w, "attacker", 0)

	t:eq(Raid.onStorageBroken({ owner = nil }, attacker, 0), 0,
		"an unowned plot paid a raider")
	t:eq(Raid.onStorageBroken({ owner = victim }, victim, 0), 0,
		"breaking your own unit paid you")
	t:eq(Raid.campingFactor(attacker, victim.UserId, 1), 1,
		"a refused raid advanced the camping ledger")
	t:eq(Raid.carriedBy(attacker), 0, "a refused raid still handed out loot")
end)

end
