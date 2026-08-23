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

end
