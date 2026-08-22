--[[
	recall_spec.lua — the way home's bookkeeping (#103).

	Pinned: the cooldown, and the carry block — a raider's stolen Tung walks
	home or dies with them, never blinks. The cast watch (stand still, take no
	hits) needs a character and a clock; Studio owns it, the handoff names it.
]]

return function(T)

T.family("recall", "the cooldown holds, and stolen Tung blocks the way home")

T.spec("a completed recall rests, and the rest expires", function(t)
	local w = T.world()
	local Recall = w.req("RecallService")
	local R = w.config.Recall
	local player = w.join("homesick")
	w.req("DataService").load(player)

	t:isTrue(Recall.tryStart(player, 0), "a clean first recall was refused")
	Recall.complete(player, R.CastSeconds)
	t:isFalse(Recall.tryStart(player, R.CastSeconds + 1),
		"recall ignored its own cooldown")
	t:isTrue(Recall.tryStart(player, R.CastSeconds + R.CooldownSeconds + 1),
		"the cooldown never expired")
end)

T.spec("a carry blocks recall until it is banked", function(t)
	local w = T.world()
	local Recall = w.req("RecallService")
	local Raid = w.req("RaidService")
	local Data = w.req("DataService")

	local victim = w.join("victim")
	local vp = Data.load(victim)
	vp.cash = 1000
	local raider = w.join("raider")
	Data.load(raider)

	Raid.onStorageBroken({ owner = victim }, raider, 0)
	t:isTrue(Raid.carriedBy(raider) > 0, "the fixture never loaded the raider's hands")
	t:isFalse(Recall.tryStart(raider, 5),
		"a loaded raider recalled — the carry chase ends in a blink")

	Raid.bankCarry(raider)
	t:isTrue(Recall.tryStart(raider, 6), "an empty-handed raider was still blocked")
end)

end
