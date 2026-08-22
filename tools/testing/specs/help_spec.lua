--[[
	help_spec.lua — kindness pays, weighted down the ladder (#123).

	What is pinned: the gap weighting (helping DOWN pays more, capped),
	credit through the one door (reputation persisted, boosts for both
	sides, the boost as a live Economy multiplier), the per-pair cooldown,
	and the raid-defence trigger arriving through RaidService's death path.

	The repair trigger's plumbing (prompt → repairStructure → observer) is
	specced in siege_spec/storage_spec, where the repair contract lives.
]]

return function(T)

T.family("help", "credit weighs the rebirth gap, boosts both sides, and one pair cannot farm it")

local function join(w, name, rebirths)
	local Data = w.req("DataService")
	local player = w.join(name)
	local profile = Data.load(player)
	profile.rebirths = rebirths or 0
	return player, profile
end

T.spec("the weight climbs with the helper's lead and is capped", function(t)
	local w = T.world()
	local Help = w.req("HelpService")
	local H = w.config.Help

	local veteran = join(w, "veteran", 2)
	local newbie = join(w, "newbie", 0)
	local ancient = join(w, "ancient", 40)

	t:eq(Help.weightFor(newbie, veteran), 1,
		"helping UP the ladder must pay the base — the weighting exists to pull new players up")
	t:eq(Help.weightFor(veteran, newbie), 1 + H.GapWeightPerRebirth * 2,
		"a two-rebirth lead must weigh in at the configured rate")
	t:eq(Help.weightFor(ancient, newbie), H.MaxWeight,
		"the weight must cap — an uncapped gap makes farming alts scale with progression")
end)

T.spec("a credit pays reputation that survives the save, and boosts both sides", function(t)
	local w = T.world()
	local Help = w.req("HelpService")
	local Data = w.req("DataService")
	local H = w.config.Help

	local helper, hp = join(w, "helper", 2)
	local helped = join(w, "helped", 0)
	local now = w.clock:clockTime()

	local earned = Help.credit(helper, helped, "raid defence", now)
	t:eq(earned, 2, "the veteran's credit must carry the gap weight")
	t:eq(hp.reputation, 2, "reputation did not accrue the weighted credit")

	t:near(Help.boostRemaining(helper, now), H.BoostMinutes * 2 * 60, 1e-9,
		"the helper's boost must scale by the same weight as the reputation")
	t:near(Help.boostRemaining(helped, now), H.BoostMinutes * 60, 1e-9,
		"the helped side's boost is flat — being helped is not a graded act")

	t:isTrue(Data.save(helper, true), "the save did not go through")
	local reloaded = Data.load(helper)
	t:eq(reloaded.reputation, 2,
		"reputation did not survive the round trip — the payload is missing the field")
end)

T.spec("the boost is a live income multiplier that expires", function(t)
	local w = T.world()
	local Help = w.req("HelpService")
	local Economy = w.req("Economy")
	local H = w.config.Help

	local helper = join(w, "helper", 0)
	local helped = join(w, "helped", 0)
	Help.start()

	local base = Economy.multiplier(helper)
	Help.credit(helper, helped, "repairs", w.clock:clockTime())
	t:near(Economy.multiplier(helper), base * H.BoostMultiplier, 1e-9,
		"the boost never reached the income multiplier")
	t:near(Economy.multiplier(helped), base * H.BoostMultiplier, 1e-9,
		"the helped side's boost never reached their multiplier")

	w.clock:advance(H.BoostMinutes * 60 + 1)
	t:near(Economy.multiplier(helper), base, 1e-9, "the boost never expired")
end)

T.spec("one pair earns once per cooldown, and the boost extension is capped", function(t)
	local w = T.world()
	local Help = w.req("HelpService")
	local H = w.config.Help

	local helper, hp = join(w, "helper", 0)
	local helped = join(w, "helped", 0)
	local other = join(w, "other", 0)

	t:eq(Help.credit(helper, helped, "repairs", 0), 1, "the first credit was refused")
	t:eq(Help.credit(helper, helped, "repairs", 10), 0,
		"the same pair paid twice inside the cooldown — two tame accounts hold a boost forever")
	t:eq(Help.credit(helper, other, "repairs", 10), 1,
		"a different helped player must be a fresh pair")
	t:eq(Help.credit(helper, helped, "repairs", H.PairCooldownSeconds + 1), 1,
		"the cooldown lapsing must re-open the pair")
	t:eq(hp.reputation, 3, "three honest credits must be three reputation")

	t:eq(Help.credit(helper, helper, "repairs", 999), 0, "self-help paid")

	local now = H.PairCooldownSeconds + 1
	t:isTrue(Help.boostRemaining(helper, now) <= H.MaxBoostMinutes * 60,
		"repeated credits stacked the boost past MaxBoostMinutes")
end)

T.spec("downing a thief credits the defender for everyone robbed, never for yourself", function(t)
	local w = T.world()
	local Help = w.req("HelpService")
	local Raid = w.req("RaidService")
	local Data = w.req("DataService")

	local victim = join(w, "victim", 0)
	local thief = join(w, "thief", 0)
	local defender, dp = join(w, "defender", 0)
	local vprofile = Data.load(victim)
	vprofile.cash = 1000

	Raid.onStorageBroken({ owner = victim }, thief, 0)
	Raid.onPlayerDied(thief, defender, 5)
	t:eq(dp.reputation, 1,
		"killing the carrier of someone else's Tung must land as a kindness to its source")
	t:isTrue(Help.boostRemaining(defender, 5) > 0, "the defence paid no boost")

	-- the victim downing their own thief is self-interest: the return happens,
	-- the credit does not
	local victim2 = join(w, "victim2", 0)
	local thief2 = join(w, "thief2", 0)
	local v2profile = Data.load(victim2)
	v2profile.cash = 1000
	local v2p = Data.load(victim2)
	Raid.onStorageBroken({ owner = victim2 }, thief2, 0)
	Raid.onPlayerDied(thief2, victim2, 5)
	t:eq(v2p.reputation or 0, 0, "recovering your own money counted as a kindness")
end)

end
