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
		Font = Style.Font.head,
		Text = title,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.heading,
	})
	y += 22
	for _, def in ipairs(defs) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -16, 0, 34)
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
		local button = UiKit.button(row, "", ROLE.affirm, {
			Size = UDim2.fromOffset(130, 26),
			Position = UDim2.new(1, -138, 0, 4),
		})
		button.Activated:Connect(function()
			Net.event("Shop"):FireServer({ action = "buy", id = def.id })
		end)
		rows[def.id] = { def = def, nameLabel = name, button = button }
		y += 38
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
		if isOwned then
			row.button.Text = "OWNED"
			row.button.BackgroundColor3 = ROLE.surface
			row.button.Active = false
		elseif blocked then
			row.button.Text = "AFTER " .. blocked.name:upper():sub(1, 12)
			row.button.BackgroundColor3 = ROLE.surface
			row.button.Active = false
		else
			row.button.Text = "$" .. Util.abbreviate(row.def.price)
			row.button.BackgroundColor3 = ROLE.affirm
			row.button.Active = true
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
		Font = Style.Font.head,
		Text = "THE SHOP",
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.heading,
	})
	local close = UiKit.button(panel, "CLOSE", ROLE.danger, {
		Size = UDim2.fromOffset(64, 22),
		Position = UDim2.new(1, -72, 0, 10),
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
	HUD.addRailItem("Shop", "SHOP", function()
		return HUD.disclosed("shop")
	end, open)
	-- ownership rides Stats; re-dress on every push while open
	HUD.onStats(refresh)
end

return ShopUI
