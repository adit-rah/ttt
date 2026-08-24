--[[
	ShopUI.lua — the storefront's face (#108).

	One overlay card, two sections: BATS and ARMOUR. Every row prints the
	measured effect the buy pads used to print — "34 dmg • 14% crit", the
	armour's health — because that legibility was the pads' best feature and
	it had to survive the move. Rows come straight from Config; ownership
	comes off the Stats payload the HUD already holds, so the shop needs no
	state push of its own.

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
local UI = Config.UI
local BUY_WIDTH = 132
local ROW_HEIGHT = UI.Button.pill + 8

local panel
local rows = {}

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

--- One section of catalog rows; returns the next free y.
local function buildSection(title: string, defs, y: number): number
	UiKit.text(panel, {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.title,
		Text = title,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.heading,
	})
	y += 22
	for _, def in ipairs(defs) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -16, 0, ROW_HEIGHT)
		row.Position = UDim2.fromOffset(8, y)
		row.BackgroundColor3 = ROLE.surface
		row.BackgroundTransparency = 0.35
		row.BorderSizePixel = 0
		row.Parent = panel
		UiKit.corner(row, 6)

		local name = UiKit.text(row, {
			Size = UDim2.new(1, -160, 0, 16),
			Position = UDim2.fromOffset(8, 2),
			Font = Style.Font.body,
			Text = def.name,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.emphasis,
		})
		UiKit.text(row, {
			Size = UDim2.new(1, -160, 0, 13),
			Position = UDim2.fromOffset(8, 18),
			Font = Style.Font.body,
			Text = statLine(def),
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.onSurfaceMuted,
		})
		-- 130x26 was an 81x16 physical target at MinScale, on the buy button of
		-- the game's only storefront. The row grows to hold a real one; the rest
		-- of this card's layout is #183's next step.
		local button = UiKit.control(row, {
			variant = "pill", text = "", width = BUY_WIDTH,
			position = UDim2.new(1, -(BUY_WIDTH + 8), 0, math.round((ROW_HEIGHT - UI.Button.pill) / 2)),
		})
		button.Activated:Connect(function()
			Net.event("Shop"):FireServer({ action = "buy", id = def.id })
		end)
		rows[def.id] = { def = def, nameLabel = name, button = button }
		y += ROW_HEIGHT + 4
	end
	return y + 6
end

--- Re-reads ownership off the HUD's Stats mirror and dresses every row.
local function refresh()
	if not panel or not panel.Visible then
		return
	end
	local owned = HUD.ownedSet()
	for id, row in pairs(rows) do
		local isOwned = owned[id] == true
		local blocked
		for _, req in ipairs(Config.requirementsOf(row.def)) do
			if not owned[req] then
				blocked = Config.ButtonById[req]
				break
			end
		end
		-- A state, not a colour. The inline version set a fill and Active and
		-- left AutoButtonColor on, so a dead button still flashed under a thumb,
		-- and left the ink at the live variant's, so OWNED printed unreadably.
		if isOwned then
			row.button.Text = "OWNED"
			UiKit.setControlState(row.button, "disabled")
		elseif blocked then
			row.button.Text = "AFTER " .. blocked.name:upper():sub(1, 12)
			UiKit.setControlState(row.button, "disabled")
		else
			row.button.Text = "$" .. Util.abbreviate(row.def.price)
			UiKit.setControlState(row.button, "idle")
		end
	end
end

local function open()
	panel.Visible = true
	refresh()
end

function ShopUI.start()
	panel = UiKit.panel(HUD.overlay(), UDim2.fromOffset(340, 60), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	panel.Name = "Shop"
	panel.Visible = false

	local y = 10
	UiKit.text(panel, {
		Size = UDim2.new(1, -24, 0, 20),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.title,
		Text = "THE SHOP",
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.heading,
	})
	local close = UiKit.control(panel, {
		variant = "ghost", name = "Close", icon = "close", iconOnly = true,
		position = UDim2.new(1, -(UI.Button.IconOnly + 8), 0, 8),
	})
	close.Activated:Connect(function()
		panel.Visible = false
	end)
	y += 30
	y = buildSection("BATS", Config.WeaponButtons, y)
	y = buildSection("ARMOUR", Config.ArmorButtons, y)
	panel.Size = UDim2.fromOffset(340, y)

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
	-- ownership rides Stats; re-dress on every push while open
	HUD.onStats(refresh)
end

return ShopUI
