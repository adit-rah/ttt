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
	t:isTrue(reloaded.disclosed.shop == true,
		"the water did not survive the round trip — the payload is missing the field")
end)


-- ── the NEW card ────────────────────────────────────────────────────────────
--
-- An arrival used to be a toast, in the same side column as a knockout and a
-- loot drop. These pin the two things that made it worth moving: that a batch
-- arrives as ONE card, and that a join push announces nothing.

local function clientWorld()
	local world = T.world()
	world.client()
	world.services.UserInputService.TouchEnabled = false
	world.req("HUD").start()
	return world
end

local function findCard(world)
	local function walk(node)
		for _, child in ipairs(node:GetChildren()) do
			if child.Name == "NewCard" then
				return child
			end
			local found = walk(child)
			if found then
				return found
			end
		end
		return nil
	end
	return walk(world.playerGui())
end

local function namesOn(card): { string }
	local out = {}
	for _, child in ipairs(card:GetChildren()) do
		if child.ClassName == "TextLabel" and child.Name ~= "Title" then
			table.insert(out, child.Text)
		end
	end
	return out
end

T.spec("a batch of arrivals is one card, not one card each", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	local card = findCard(world)
	t:notNil(card, "the HUD built no NEW card")

	t:eq(card.Visible, false, "the NEW card is showing before anything has arrived")
	HUD.applyDisclosure({ ids = { "siege", "party", "recall" }, fresh = {
		{ name = "Raids on your plot", help = "Sahur press your gate." },
		{ name = "Parties", help = "Party up from the left card." },
		{ name = "Recall", help = "H walks you home." },
	} })
	t:eq(card.Visible, true, "three surfaces arrived and the card stayed hidden")

	-- Buying `walls` earns all three at once. Three cards in a row is the toast
	-- problem with bigger rectangles, which is what this replaced.
	local names = namesOn(card)
	local found = 0
	for _, text in ipairs(names) do
		if text == "Parties" or text == "Recall" or text == "Raids on your plot" then
			found += 1
		end
	end
	t:eq(found, 3, ("the card names %d of the three arrivals"):format(found))
end)

T.spec("a join push announces nothing", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	local card = findCard(world)

	-- A returning player owns most of the list already, and a card naming
	-- eleven things they have had for a week is not an announcement.
	HUD.applyDisclosure({ ids = { "hud", "movement", "session", "shop", "party" } })
	t:eq(card.Visible, false, "a push with no `fresh` opened the NEW card anyway")
end)

T.spec("GOT IT dismisses it, and the next arrival opens a fresh one", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	local card = findCard(world)

	HUD.applyDisclosure({ ids = { "party" }, fresh = { { name = "Parties", help = "Party up." } } })
	t:eq(card.Visible, true, "one arrival did not open the card")

	local ok
	for _, child in ipairs(card:GetChildren()) do
		if child.ClassName == "TextButton" then
			ok = child
		end
	end
	t:notNil(ok, "the NEW card has nothing to dismiss it with")
	if ok then
		ok.Activated:Fire()
		t:eq(card.Visible, false, "GOT IT did not close the card")
	end

	HUD.applyDisclosure({ ids = { "party", "recall" }, fresh = { { name = "Recall", help = "H walks you home." } } })
	t:eq(card.Visible, true, "a second arrival did not reopen the card")
	local names = namesOn(card)
	for _, text in ipairs(names) do
		t:ne(text, "Parties", "the dismissed arrival came back on the next card")
	end
end)

T.spec("reconcile hands back what arrived, and says nothing for the always-on rows", function(t)
	local world = T.world()
	local Data = world.req("DataService")
	local D = world.req("DisclosureService")
	local player = world.join("Fresh")
	local profile = Data.load(player)

	-- hud and movement have no `after`: they are on from the first frame and
	-- announcing them would be a card in the face at spawn.
	local arrived, fresh = D.reconcile(player)
	t:gt(arrived, 0, "a fresh profile disclosed nothing at all")
	t:eq(#fresh, 0, ("the always-on rows announced %d arrivals at spawn"):format(#fresh))

	-- ...and an earned row does come back, with the text the card prints.
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	local _, second = D.reconcile(player)
	t:gt(#second, 0, "an earned surface arrived with nothing to announce it")
	if second[1] then
		t:ne(second[1].name, nil, "an arrival came back with no name on it")
		t:ne(second[1].help, nil, "an arrival came back with no blurb on it")
	end
end)


end
