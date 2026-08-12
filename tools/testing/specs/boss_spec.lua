--[[
	boss_spec.lua — the arithmetic of the shared boss, executed.

	The boss is the one fight in this game that needs another human being, and
	the whole of that claim rests on three pure functions in Config: how much
	health a boss gets for a given headcount, how much the pot grows, and how the
	pot is divided among the people who actually did the damage.

	WHY THESE ARE SPECS AND NOT ONLY CONFIG CHECKS. tools/verify_config.lua reads
	the numbers; these run the functions, over the whole supported player range,
	against the properties that make the feature safe to ship:

	  * THE SOLO GUARANTEE. bossHealthFactor(1) and bossRewardFactor(1) are
	    exactly 1 and bossShare at one eligible contributor is the identity, so
	    a 1-player server gets the boss it had before any of this existed — with
	    no branch anywhere in the code. Every other property here is about
	    groups; this one is what stops the feature costing the person who was
	    already playing.

	  * POT CONSERVATION. Summed over the eligible, the split is exactly the pot.
	    A floor share divided evenly plus a remainder divided by damage is only
	    conservative because the two fractions add to one, and that is precisely
	    the kind of relationship a later "just bump the floor share" edit breaks
	    without anything noticing.

	NPCService — which owns the ledger these functions are fed from — is not
	loadable in this harness: it needs Touched, a physics step and a live
	Humanoid. What it does with the numbers is UNVERIFIED. What the numbers are
	is not.
]]

return function(T)

T.family("boss", "the shared boss splits its pot exactly, and leaves the solo game alone")

--- Every player count this game supports, which is the range that matters:
--- MaxPlots is also the place's player cap (see Config.World).
local function eachPlayerCount(Config, fn)
	for n = 1, Config.World.MaxPlots do
		fn(n)
	end
end

T.spec("a one-player server gets exactly the boss it had before", function(t)
	local Config = T.world().config

	t:eq(Config.bossHealthFactor(1), 1, "a solo boss must not gain a stud of health from this feature")
	t:eq(Config.bossRewardFactor(1), 1, "a solo boss must not pay a coin more or less than it used to")

	-- ...and the split, which is the half that could go wrong quietly: the floor
	-- share and the damage share have to reconstitute the whole pot, or a solo
	-- kill pays BossFloorShare of what it did yesterday and nobody finds out
	-- until a player does the sums.
	for _, pot in ipairs({ 1, 150, 12345.678, 8.43e7 }) do
		t:near(Config.bossShare(pot * 3, pot * 3, 1, pot), pot, pot * 1e-9,
			"one eligible contributor must take the whole pot")
	end
end)

T.spec("the pot is conserved at every player count, evenly split or lopsided", function(t)
	local Config = T.world().config
	local pot = 1e6

	eachPlayerCount(Config, function(n)
		local equal, lopsided = {}, {}
		local equalTotal, lopsidedTotal = 0, 0
		for i = 1, n do
			-- One fight where everybody pulled their weight, and one where the
			-- last person to arrive did a hundredth of what the first did.
			equal[i] = 250
			lopsided[i] = i * i * 37
			equalTotal += equal[i]
			lopsidedTotal += lopsided[i]
		end

		local equalSum, lopsidedSum = 0, 0
		for i = 1, n do
			equalSum += Config.bossShare(equal[i], equalTotal, n, pot)
			lopsidedSum += Config.bossShare(lopsided[i], lopsidedTotal, n, pot)
		end

		t:near(equalSum, pot, pot * 1e-9,
			("%d equal contributors did not split the pot into the pot"):format(n))
		t:near(lopsidedSum, pot, pot * 1e-9,
			("%d uneven contributors did not split the pot into the pot"):format(n))
	end)
end)

T.spec("everyone who showed up is paid, and the one who did the work is paid more", function(t)
	local Config = T.world().config
	local pot = 1e6

	-- The shape the design is actually asking for, stated as an ordering rather
	-- than as a number: a floor for turning up, and a real gradient on top of
	-- it. Either half alone is a worse game — a pure damage split pays the
	-- eleventh person nothing, and a pure even split pays the person who tanked
	-- it the same as the person who threw one rock.
	local damage = { 900, 100, 40 }
	local total = 900 + 100 + 40
	local shares = {}
	for i, mine in ipairs(damage) do
		shares[i] = Config.bossShare(mine, total, #damage, pot)
	end

	t:gt(shares[3], 0, "the smallest eligible contributor must still be paid something")
	t:gt(shares[1], shares[2], "the top contributor must out-earn the second")
	t:gt(shares[2], shares[3], "and the second must out-earn the third")
	-- The floor is a floor, not a rounding error: the least of them takes at
	-- least an even share of the floor half.
	t:gte(shares[3], (pot * Config.Waves.BossFloorShare) / #damage - 1e-6,
		"the even floor share is not reaching the smallest contributor")
	-- ...and it is not the whole story either: with 74% of the damage, the top
	-- contributor has to beat an even split by a distance.
	t:gt(shares[1], pot / #damage, "the damage half of the split is doing nothing")
end)

T.spec("a busy server is neither a wall nor a payday", function(t)
	local Config = T.world().config

	eachPlayerCount(Config, function(n)
		local health = Config.bossHealthFactor(n)
		local reward = Config.bossRewardFactor(n)

		-- Sub-linear, both of them: ten players do not deal ten players' damage
		-- to one target with one hitbox, and a boss that scaled linearly would
		-- make a full server the worst place to fight one.
		t:lt(health, n + 1e-9,
			("at %d players the boss health scales %.2fx — at or above linear, a full server is a wall"):format(n, health))
		-- And the pot grows slower than the health, which is the sentence that
		-- keeps the boss a fight rather than something you stand near.
		t:lte(reward, health + 1e-9,
			("at %d players the pot grows %.2fx against %.2fx of health"):format(n, reward, health))
		-- ...but not so much slower that arriving to a busy arena is a demotion.
		t:gte(reward / health, 0.6,
			("at %d players you fight %.2fx the boss for %.2fx the pot"):format(n, health, reward))
	end)
end)

T.spec("both factors are monotonic and land on their ceilings, not past them", function(t)
	local Config = T.world().config
	local WV = Config.Waves

	local previousHealth, previousReward = 0, 0
	eachPlayerCount(Config, function(n)
		local health = Config.bossHealthFactor(n)
		local reward = Config.bossRewardFactor(n)
		-- A tuning pass that puts a ceiling BELOW the per-player step turns
		-- these into a curve that goes down as more people arrive, which is the
		-- one shape nobody would ever intend.
		t:gte(health, previousHealth, ("boss health scaling fell between %d and %d players"):format(n - 1, n))
		t:gte(reward, previousReward, ("boss reward scaling fell between %d and %d players"):format(n - 1, n))
		t:lte(health, WV.BossMaxHealthFactor, "boss health scaling ran past its own ceiling")
		t:lte(reward, WV.BossMaxRewardFactor, "boss reward scaling ran past its own ceiling")
		previousHealth, previousReward = health, reward
	end)

	-- A fractional or absurd headcount cannot reach these from NPCService, but
	-- the floor and the clamp are what make that true rather than lucky.
	t:eq(Config.bossHealthFactor(0), 1, "a headcount of zero must not shrink the boss below solo")
	t:eq(Config.bossHealthFactor(1000), WV.BossMaxHealthFactor, "the ceiling has to hold for any headcount")
end)

T.spec("an empty ledger pays nothing rather than dividing by zero", function(t)
	local Config = T.world().config

	-- The paths NPCService takes when a boss times out with nobody eligible: a
	-- pot of zero (a wave whose contributions were all below the floor, paid
	-- pro-rata to nothing) and a count of zero.
	t:eq(Config.bossShare(100, 100, 0, 5000), 0, "no eligible players must pay out nothing")
	t:eq(Config.bossShare(100, 100, 3, 0), 0, "an empty pot must pay out nothing")
	-- And the unreachable one: eligible players whose damage somehow sums to
	-- zero still split the pot evenly instead of returning a NaN into
	-- Economy.add, which would land in somebody's saved profile.
	t:near(Config.bossShare(0, 0, 4, 4000), 1000, 1e-9,
		"a zero-damage eligible set must fall back to an even split, not a NaN")
end)

end
