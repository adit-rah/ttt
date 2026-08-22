--[[
	disclosure_spec.lua — the interface grows and never shrinks (#96).

	Pinned: earning writes the high-water, the always-on set arrives at once,
	a rebirth wiping `owned` forgives nothing, and the water survives the
	save. The client gates are pinned where the panels live (hud_spec); the
	siege gate reads the same profile field and NPCService is a Studio
	concern.
]]

return function(T)

T.family("disclosure", "surfaces are earned into a high-water that nothing drains")

T.spec("earning writes the water, and the always-on set needs no earning", function(t)
	local w = T.world()
	local D = w.req("DisclosureService")
	local Data = w.req("DataService")
	local player = w.join("fresh")
	local profile = Data.load(player)

	D.reconcile(player)
	t:isTrue(D.unlocked(player, "hud"), "the day-one set never arrived")
	t:isFalse(D.unlocked(player, "terms"), "an unearned surface unlocked itself")
	t:isFalse(D.unlocked(player, "siege"), "the siege gate opened on join — the first minute has a siren in it")

	profile.owned.dropper2 = true
	local arrived = D.reconcile(player)
	t:eq(arrived, 1, "owning dropper2 must arrive exactly the terms row")
	t:isTrue(D.unlocked(player, "terms"), "the earned surface never unlocked")
end)

T.spec("a rebirth wipes owned and forgives nothing", function(t)
	local w = T.world()
	local D = w.req("DisclosureService")
	local Data = w.req("DataService")
	local player = w.join("veteran")
	local profile = Data.load(player)

	profile.owned.dropper2 = true
	profile.owned.walls = true
	D.reconcile(player)
	t:isTrue(D.unlocked(player, "siege"), "walls did not open the siege gate")

	profile.owned = {}
	D.reconcile(player)
	t:isTrue(D.unlocked(player, "terms"),
		"the wipe drained the water — a rebirthed player got re-onboarded")
	t:isTrue(D.unlocked(player, "siege"), "the siege gate closed again after rebirth")
end)

T.spec("the water survives the save", function(t)
	local w = T.world()
	local D = w.req("DisclosureService")
	local Data = w.req("DataService")
	local player = w.join("returning")
	local profile = Data.load(player)

	profile.owned.dropper3 = true
	D.reconcile(player)
	t:isTrue(Data.save(player, true), "the save did not go through")
	local reloaded = Data.load(player)
	t:isTrue(reloaded.disclosed.session == true,
		"the water did not survive the round trip — the payload is missing the field")
end)

end
