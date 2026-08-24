--[[
	shop_spec.lua — the storefront's gate (#108).

	Pinned: every refusal in tryBuy (unknown wares, the disclosure gate, the
	plot milestone, the chain, the price), the happy path landing as a
	monotonic grant, and the profile/economy arithmetic. The merchant, the
	panel and the rail item are surfaces; Studio owns them.
]]

return function(T)

T.family("shop", "the shop refuses in order, and a sale lands as a monotonic grant")

local function shopper(w, name)
	local Data = w.req("DataService")
	local D = w.req("DisclosureService")
	local player = w.join(name)
	local profile = Data.load(player)
	profile.owned.dropper1 = true
	profile.owned.dropper2 = true
	profile.owned.dropper3 = true
	D.reconcile(player)
	return player, profile
end

T.spec("the refusals, in the order a player meets them", function(t)
	local w = T.world()
	local Shop = w.req("ShopService")
	local Data = w.req("DataService")

	local fresh = w.join("fresh")
	local fp = Data.load(fresh)
	fp.cash = 1e9
	-- the plot milestone is met but the disclosure beat has not run, so the
	-- ONLY thing refusing this sale is the disclosure gate itself
	fp.owned.dropper1, fp.owned.dropper2, fp.owned.dropper3 = true, true, true
	t:isFalse(Shop.tryBuy(fresh, "dropper1"), "the shop sold a plot machine")
	t:isFalse(Shop.tryBuy(fresh, "batforge"),
		"an undisclosed shop sold a bat — the first-minute screen leaks through the till")

	local buyer, profile = shopper(w, "buyer")
	profile.cash = 1e9
	t:isFalse(Shop.tryBuy(buyer, "batforge_ash"),
		"the chain was skipped — un-ordered buys break the monotone grant")

	profile.cash = 10
	t:isFalse(Shop.tryBuy(buyer, "batforge"), "an unaffordable bat sold anyway")
	t:eq(profile.cash, 10, "a refused sale still charged")
end)

T.spec("a sale charges, owns, and grants monotonically", function(t)
	local w = T.world()
	local Shop = w.req("ShopService")
	local Config = w.config

	local buyer, profile = shopper(w, "buyer")
	profile.cash = 1e9

	t:isTrue(Shop.tryBuy(buyer, "batforge"), "a clean first bat was refused")
	t:eq(profile.cash, 1e9 - Config.ButtonById.batforge.price, "the till took the wrong amount")
	t:isTrue(profile.owned.batforge == true, "the sale never landed in owned — the sim and the replay both read it")
	t:eq(profile.batTier, 2, "the oak bat must be tier 2 in the hand")

	t:isFalse(Shop.tryBuy(buyer, "batforge"), "the same bat sold twice")

	t:isTrue(Shop.tryBuy(buyer, "armor_padded"), "the first vest was refused")
	t:eq(profile.armorTier, 2, "the padded vest must be tier 2 on the body")

	t:isTrue(Shop.tryBuy(buyer, "batforge_ash"), "the chain refused its own next rung")
	t:eq(profile.batTier, 3, "the second bat must climb the tier")
end)


-- ── the storefront's face ───────────────────────────────────────────────────
--
-- The two specs above are the SERVER's refusals. These are what the card shows
-- before you press anything, which used to be nothing at all: ShopUI did not
-- read the balance, so an unaffordable buy fired the remote, failed server-side
-- and came back as a toast saying no.
--
-- Layout is not here and cannot be — the mock stores a UDim2 and never resolves
-- it. Every size in Config.UI.Shop is held by verify_config instead. What these
-- read is state: which control is pressable, and what its label says.

local function shopWorld()
	local world = T.world()
	world.client()
	world.services.UserInputService.TouchEnabled = false
	world.req("HUD").start()
	world.req("ShopUI").start()
	world.cfg = world.req("Config")
	world.util = world.req("Util")
	return world
end

local function shopPanel(world)
	local function find(node)
		for _, child in ipairs(node:GetChildren()) do
			if child.Name == "Shop" and child.ClassName == "Frame" then
				return child
			end
			local found = find(child)
			if found then
				return found
			end
		end
		return nil
	end
	return find(world.playerGui())
end

local function rowNamed(panel, id: string)
	local scroll = panel:FindFirstChild("Rows")
	return scroll and scroll:FindFirstChild(id)
end

--- Push a Stats payload the way the server would, so the card re-dresses.
local function stats(world, cash: number, owned)
	local folder = world.replicatedStorage:FindFirstChild("TungNet")
	folder:FindFirstChild("Stats").OnClientEvent:Fire({ cash = cash, owned = owned or {} })
end

T.spec("a row a player cannot pay for is not pressable", function(t)
	local world = shopWorld()
	local panel = shopPanel(world)
	t:notNil(panel, "the shop card was not built")
	panel.Visible = true

	local first = world.cfg.WeaponButtons[1]
	stats(world, 0, {})
	local row = rowNamed(panel, first.id)
	t:notNil(row, ("no row was built for %q"):format(first.id))
	if row then
		local buy = row:FindFirstChild("Buy")
		t:isFalse(buy.Active,
			"a row nobody can pay for is pressable — this is the round trip that came back as a toast saying no")

		stats(world, first.price, {})
		t:isTrue(buy.Active, "a row the player can now afford stayed dead")
		t:eq(buy.Text, "$" .. world.util.abbreviate(first.price), "an affordable row does not print its price")
	end
end)

T.spec("owned reads as owned, and locked names what it waits for", function(t)
	local world = shopWorld()
	local panel = shopPanel(world)
	panel.Visible = true

	local first = world.cfg.WeaponButtons[1]
	stats(world, 0, { [first.id] = true })
	local buy = rowNamed(panel, first.id):FindFirstChild("Buy")
	t:eq(buy.Text, "OWNED", "an owned row does not say so")
	t:isFalse(buy.Active, "an owned row is still pressable")

	-- Something further up the ladder whose rung below is NOT owned. Owning the
	-- first bat unlocks the second, so "has requirements" is not the same
	-- question as "is locked" — the first draft of this spec asked the wrong one
	-- and picked a row that was merely expensive.
	local owned = { [first.id] = true }
	for _, def in ipairs(world.cfg.WeaponButtons) do
		local blocked = false
		for _, req in ipairs(world.cfg.requirementsOf(def)) do
			blocked = blocked or not owned[req]
		end
		if blocked then
			local locked = rowNamed(panel, def.id):FindFirstChild("Buy")
			t:eq(locked.Text:sub(1, 5), "AFTER",
				("a locked row says %q rather than naming what it waits for"):format(locked.Text))
			t:isFalse(locked.Active, "a locked row is pressable")
			break
		end
	end
end)

T.spec("the balance is on the card, so nobody closes it to check", function(t)
	local world = shopWorld()
	local panel = shopPanel(world)
	panel.Visible = true

	stats(world, 12345, {})
	local balance = panel:FindFirstChild("Balance")
	t:notNil(balance, "the shop header has no balance on it")
	if balance then
		t:eq(balance.Text, world.util.abbreviate(12345), "the shop's balance does not follow the Stats push")
	end
end)

T.spec("every row carries a well, a stat line and its rung", function(t)
	local world = shopWorld()
	local panel = shopPanel(world)
	panel.Visible = true
	stats(world, 0, {})

	for index, def in ipairs(world.cfg.WeaponButtons) do
		local row = rowNamed(panel, def.id)
		t:notNil(row:FindFirstChild("Well"), ("%q has no icon well"):format(def.id))
		t:ne(row:FindFirstChild("Stat").Text, "",
			("%q prints no stat line — the measured effect was the buy pads' best feature and it had to survive the move")
				:format(def.id))
		-- The pips are the tier, read off table position rather than off any
		-- per-item colour, so they survive the art being replaced.
		local pips = row:FindFirstChild("Pips")
		t:eq(#pips:GetChildren(), #world.cfg.WeaponButtons,
			("%q draws %d rungs for a ladder of %d"):format(def.id, #pips:GetChildren(), #world.cfg.WeaponButtons))
		local filled = 0
		for _, pip in ipairs(pips:GetChildren()) do
			if pip.BackgroundTransparency == 0 then
				filled += 1
			end
		end
		t:eq(filled, index, ("%q is rung %d and fills %d pips"):format(def.id, index, filled))
	end
end)


end
