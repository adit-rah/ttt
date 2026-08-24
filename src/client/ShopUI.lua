--[[
	ShopUI.lua — the storefront's face (#108).

	One overlay card, two sections: BATS and ARMOUR. Every row prints the
	measured effect the buy pads used to print — "34 dmg • 14% crit", the
	armour's health — because that legibility was the pads' best feature and
	it had to survive the move. Rows come straight from Config.

	FIVE SLOTS TO A ROW AND NEVER A SIXTH: a well with the item's glyph in it,
	the name, the stat line under it, the tier pips, and one control on the
	right whose LABEL IS THE STATE. A column of wells is what makes a list
	scannable; a column of text is a wall.

	IT SCROLLS. Nine rows at a thumb-sized height is well past Modal.MaxHeight,
	and the card used to grow from an accumulated `y` with nothing checking it
	against the viewport — so it got taller every time somebody added a row to
	Config, and the first time anyone would have found out is on a phone.

	AFFORDABILITY IS READ, NOT GUESSED. This panel did not look at the player's
	balance at all: an unaffordable buy fired the remote, failed server-side and
	came back as a toast. It reads HUD.cash() now, and the price control is
	pressable only when it can be paid. The server still validates everything;
	this is only what the button looks like.

	Two doors in: the SHOP rail item (disclosure-gated, like every earned
	surface) and the merchant's prompt, which arrives as { open = true } on
	the Shop remote. Buying sends { action = "buy", id } and nothing else; the
	server validates everything and answers through the notify stream.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local UiKit = Req("UiKit")
local HUD = Req("HUD")
local Style = Req("Style")

local ShopUI = {}

local ROLE = UiKit.ROLE
local SHOP = Config.UI.Shop

local panel, scroll, balanceLabel
local rows = {}

--- The measured effect, which is the best thing on this screen.
local function statLine(def): string
	if def.track == "weapons" then
		local bat = Config.BatById[def.grants]
		if bat then
			return ("%d dmg • %d%% crit"):format(bat.damage, math.floor(bat.crit * 100 + 0.5))
		end
	else
		for _, tier in ipairs(Config.Armor.Tiers) do
			if tier.id == def.grants then
				return ("%d health"):format(tier.health)
			end
		end
	end
	return ""
end

--- The rungs, filled to this row's place in its own ladder.
---
--- Derived from table POSITION, so it survives the tiers being redrawn — which
--- is the whole reason it is not the item's own colour. Fill-versus-empty is a
--- SHAPE, so it works before colour does on a bright sky, which is what
--- SYSTEMS.md §8 asks of every state on this screen.
local function buildPips(parent: Instance, index: number, count: number, y: number)
	for rung = 1, count do
		local pip = Instance.new("Frame")
		pip.Name = ("Pip%d"):format(rung)
		pip.Size = UDim2.fromOffset(SHOP.PipSize, SHOP.PipSize)
		pip.Position = UDim2.fromOffset((rung - 1) * (SHOP.PipSize + SHOP.PipGap), y)
		pip.BackgroundColor3 = rung <= index and ROLE.currency or ROLE.line
		pip.BackgroundTransparency = rung <= index and 0 or 0.4
		pip.BorderSizePixel = 0
		pip.Parent = parent
		UiKit.corner(pip, math.floor(SHOP.PipSize / 2))
	end
end

--- One row. Returns the y after it.
local function buildRow(def, icon: string, index: number, count: number, y: number): number
	local row = Instance.new("Frame")
	row.Name = def.id
	row.Size = UDim2.fromOffset(SHOP.ContentWidth, SHOP.RowHeight)
	row.Position = UDim2.fromOffset(0, y)
	row.BackgroundColor3 = ROLE.surfaceRaised
	row.BackgroundTransparency = 0.35
	row.BorderSizePixel = 0
	row.Parent = scroll
	UiKit.corner(row, 8)

	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.fromOffset(SHOP.WellSize, SHOP.WellSize)
	well.Position = UDim2.fromOffset(SHOP.RowPad, math.round((SHOP.RowHeight - SHOP.WellSize) / 2))
	well.BackgroundColor3 = ROLE.surface
	well.BackgroundTransparency = 0.25
	well.BorderSizePixel = 0
	well.Parent = row
	UiKit.corner(well, 8)

	local glyph = UiKit.icon(well, icon,
		Config.UI.Icon.Medium, ROLE.onSurface, ROLE.surface)
	glyph.Position = UDim2.fromOffset(
		math.floor((SHOP.WellSize - Config.UI.Icon.Medium) / 2),
		math.floor((SHOP.WellSize - Config.UI.Icon.Medium) / 2))

	local name = UiKit.text(row, {
		Name = "Name",
		Size = UDim2.fromOffset(SHOP.TextWidth, SHOP.NameHeight),
		Position = UDim2.fromOffset(SHOP.TextX, SHOP.RowPad),
		Font = Style.Font.title,
		Text = def.name,
		TextSize = SHOP.NameTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = ROLE.emphasis,
	})
	UiKit.text(row, {
		Name = "Stat",
		Size = UDim2.fromOffset(SHOP.TextWidth, SHOP.StatHeight),
		Position = UDim2.fromOffset(SHOP.TextX, SHOP.RowPad + SHOP.NameHeight),
		Font = Style.Font.body,
		Text = statLine(def),
		TextSize = SHOP.StatTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})

	local pips = Instance.new("Frame")
	pips.Name = "Pips"
	pips.Size = UDim2.fromOffset(count * (SHOP.PipSize + SHOP.PipGap), SHOP.PipSize)
	pips.Position = UDim2.fromOffset(SHOP.TextX, SHOP.RowHeight - SHOP.RowPad - SHOP.PipSize)
	pips.BackgroundTransparency = 1
	pips.BorderSizePixel = 0
	pips.Parent = row
	buildPips(pips, index, count, 0)

	local button = UiKit.control(row, {
		variant = "pill", text = "", name = "Buy", width = SHOP.BuyWidth,
		position = UDim2.fromOffset(
			SHOP.ContentWidth - SHOP.RowPad - SHOP.BuyWidth,
			math.round((SHOP.RowHeight - Config.UI.Button.pill) / 2)),
	})
	button.Activated:Connect(function()
		Net.event("Shop"):FireServer({ action = "buy", id = def.id })
	end)

	rows[def.id] = { def = def, nameLabel = name, button = button, glyph = glyph, pips = pips }
	return y + SHOP.RowHeight + SHOP.RowGap
end

--- A section heading over a hairline. Not a second card: a stack of cards reads
--- as a stack of things, and this is one thing with two parts.
local function buildSection(title: string, defs, icon: string, y: number): number
	UiKit.text(scroll, {
		Size = UDim2.fromOffset(SHOP.ContentWidth, SHOP.SectionHeight),
		Position = UDim2.fromOffset(0, y),
		Font = Style.Font.title,
		Text = title,
		TextSize = SHOP.SectionTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.heading,
	})
	local rule = Instance.new("Frame")
	rule.Name = title .. "Rule"
	rule.Size = UDim2.fromOffset(SHOP.ContentWidth, 1)
	rule.Position = UDim2.fromOffset(0, y + SHOP.SectionHeight - 2)
	rule.BackgroundColor3 = ROLE.line
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.Parent = scroll
	y += SHOP.SectionHeight + SHOP.RowGap

	for index, def in ipairs(defs) do
		y = buildRow(def, icon, index, #defs, y)
	end
	return y + SHOP.RowGap
end

--- Re-dresses every row against ownership and the balance.
---
--- Three states, and each differs from the others in MORE THAN COLOUR: the
--- control's label says which one it is, the glyph dims when the row is locked,
--- and the pips outline rather than fill. SYSTEMS.md §8 requires that, because
--- colour is the first thing a bright sky takes away.
local function refresh()
	if not panel or not panel.Visible then
		return
	end
	local owned = HUD.ownedSet()
	local cash = HUD.cash()
	balanceLabel.Text = Util.abbreviate(cash)

	for id, row in pairs(rows) do
		local isOwned = owned[id] == true
		local blocked
		for _, req in ipairs(Config.requirementsOf(row.def)) do
			if not owned[req] then
				blocked = Config.ButtonById[req]
				break
			end
		end

		if isOwned then
			row.button.Text = "OWNED"
			UiKit.setControlState(row.button, "on")
			UiKit.fadeIcon(row.glyph, 0)
		elseif blocked then
			row.button.Text = "AFTER " .. blocked.name:upper():sub(1, 12)
			UiKit.setControlState(row.button, "disabled")
			UiKit.fadeIcon(row.glyph, 0.6)
		else
			row.button.Text = "$" .. Util.abbreviate(row.def.price)
			-- Pressable only when it can be paid. The server still validates;
			-- this stops the round trip that came back as a toast saying no.
			UiKit.setControlState(row.button, cash >= row.def.price and "idle" or "disabled")
			UiKit.fadeIcon(row.glyph, 0)
		end
	end
end

local function open()
	panel.Visible = true
	refresh()
end

function ShopUI.start()
	panel = UiKit.overlayCard(HUD.overlay(),
		UDim2.fromOffset(Config.UI.Shop.Width, Config.UI.Modal.MaxHeight))
	panel.Name = "Shop"
	panel.Visible = false

	UiKit.text(panel, {
		Name = "Title",
		Size = UDim2.fromOffset(SHOP.ContentWidth, SHOP.HeadHeight),
		Position = UDim2.fromOffset(SHOP.Pad, SHOP.Pad),
		Font = Style.Font.title,
		Text = "THE SHOP",
		TextSize = SHOP.HeadTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextColor3 = ROLE.heading,
	})

	-- The balance, in the header. A shop you have to close to check your money
	-- is a shop you close.
	local coin = UiKit.icon(panel, "coin", Config.UI.Icon.Small, ROLE.currency, ROLE.surface)
	coin.Name = "HeaderCoin"
	coin.Position = UDim2.fromOffset(
		SHOP.Pad + SHOP.ContentWidth - Config.UI.Button.IconOnly - SHOP.RowPad
			- SHOP.BuyWidth,
		SHOP.Pad + math.floor((SHOP.HeadHeight - Config.UI.Icon.Small) / 2))
	balanceLabel = UiKit.text(panel, {
		Name = "Balance",
		Size = UDim2.fromOffset(SHOP.BuyWidth - SHOP.RowPad, SHOP.HeadHeight),
		Position = UDim2.fromOffset(
			SHOP.Pad + SHOP.ContentWidth - Config.UI.Button.IconOnly - SHOP.BuyWidth
				+ Config.UI.Icon.Small - SHOP.RowPad,
			SHOP.Pad),
		Font = Style.Font.title,
		Text = "0",
		TextSize = SHOP.BalanceTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextColor3 = ROLE.currency,
	})

	local close = UiKit.control(panel, {
		variant = "ghost", name = "Close", icon = "close", iconOnly = true,
		position = UDim2.fromOffset(
			SHOP.Pad + SHOP.ContentWidth - Config.UI.Button.IconOnly, SHOP.Pad),
	})
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.Size = UDim2.fromOffset(SHOP.ContentWidth, SHOP.ViewportHeight)
	scroll.Position = UDim2.fromOffset(SHOP.Pad, SHOP.Pad + SHOP.HeadHeight)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = ROLE.line
	scroll.Parent = panel

	local y = buildSection("BATS", Config.WeaponButtons, "bat", 0)
	y = buildSection("ARMOUR", Config.ArmorButtons, "armour", y)
	scroll.CanvasSize = UDim2.fromOffset(0, y)

	-- door one: the merchant's prompt answers { open = true }
	Net.event("Shop").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.open then
			open()
		end
	end)
	-- door two: the rail item, earned like every surface
	HUD.addRailItem("Shop", "shop", "SHOP", function()
		return HUD.disclosed("shop")
	end, open)
	-- ownership and the balance both ride Stats; re-dress on every push
	HUD.onStats(refresh)
end

return ShopUI
