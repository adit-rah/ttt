--[[
	UpgradeUI.lua — PROTOTYPE. The shop panel for Config.PlayerUpgrades and the
	utility slot for Config.Utilities.

	It draws into HUD's own ScreenGui (HUD.screenGui()) rather than making a
	second one, so the two share a z-order and one ResetOnSpawn = false.

	The panel builders below are a deliberate local copy of HUD's palette and
	its corner/stroke/panel/text/button helpers: HUD doesn't export them, and
	the brief for this prototype is not to touch HUD.lua. If this ships, the
	right move is to lift those five functions into a shared UiKit module and
	have both files call it — right now the palette exists twice and the two
	copies can drift.

	The client is a renderer here. It never decides what you own, what a level
	costs or whether a utility is off cooldown; it draws the last UpgradeState
	the server sent and asks for things.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Net = Req("Net")
local Utilities = Req("Utilities")

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UpgradeUI = {}

local SHOP_ON = Config.Prototypes.PlayerUpgrades
local UTILITY_ON = Config.Prototypes.Utilities
local ENABLED = SHOP_ON or UTILITY_ON

-- Should move to Config alongside the utility rows if this ships. Q is chosen
-- because 1..9 belong to Roblox's hotbar and E is the ProximityPrompt default.
local USE_KEY = Enum.KeyCode.Q
local SEND_THROTTLE = 0.2

local PALETTE = {
	panel   = Color3.fromRGB(22, 18, 32),
	panel2  = Color3.fromRGB(32, 26, 46),
	accent  = Color3.fromRGB(190, 130, 255),
	gold    = Color3.fromRGB(255, 205, 90),
	good    = Color3.fromRGB(120, 235, 160),
	bad     = Color3.fromRGB(255, 110, 110),
	text    = Color3.fromRGB(238, 232, 250),
	muted   = Color3.fromRGB(160, 150, 180),
	dead    = Color3.fromRGB(90, 84, 104),
}

local state = {
	cash = 0,
	-- Nothing is drawn as a real price until the server has spoken once: an
	-- empty costs table and a maxed-out upgrade look identical, and guessing
	-- wrong paints every row "MAX" for the first second of the session.
	received = false,
	levels = {} :: { [string]: number },
	costs = {} :: { [string]: number },
	locked = {} :: { [string]: string },
	equipped = "",
	cooldownTotal = 0,
	-- os.clock() on THIS machine. The server sends seconds-remaining, never a
	-- timestamp, because the two clocks have no relationship to each other.
	readyAt = 0,
}

local rows: { [string]: any } = {}
local panelFrame, toggleButton, chipButton, chipLabel
local lastSend = 0
local flashUntil = 0

-- ─────────────────────────────────────────────────────────────────────────────
-- builders (local copies of HUD's — see the header)
-- ─────────────────────────────────────────────────────────────────────────────

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, color: Color3, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 2
	s.Transparency = 0.35
	s.Parent = parent
	return s
end

local function panel(parent: Instance, size: UDim2, position: UDim2, anchor: Vector2?)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position
	f.AnchorPoint = anchor or Vector2.zero
	f.BackgroundColor3 = PALETTE.panel
	f.BackgroundTransparency = 0.12
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 14)
	stroke(f, PALETTE.accent, 2)

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(PALETTE.panel2, PALETTE.panel)
	gradient.Rotation = 90
	gradient.Parent = f
	return f
end

local function text(parent: Instance, props): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Style.Font.body
	l.TextColor3 = PALETTE.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.RichText = true
	for k, v in pairs(props) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

local function button(parent: Instance, label: string, color: Color3, props): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = color
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Style.Font.title
	b.Text = label
	b.TextColor3 = Color3.fromRGB(20, 16, 28)
	b.TextScaled = true
	for k, v in pairs(props or {}) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	corner(b, 10)
	return b
end

-- ─────────────────────────────────────────────────────────────────────────────
-- rows
-- ─────────────────────────────────────────────────────────────────────────────

local function sectionLabel(parent: Instance, label: string, order: number)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 22)
	holder.LayoutOrder = order
	holder.Parent = parent

	text(holder, {
		Size = UDim2.fromScale(1, 1),
		Font = Style.Font.body,
		Text = label,
		TextSize = 12,
		TextColor3 = PALETTE.muted,
	})
end

--- One row is a single TextButton with labels laid on top, so the whole strip
--- is the hit target. Tapping a 90px pill on a phone is a coin flip.
local function buildRow(parent: Instance, id: string, name: string, order: number)
	local row = Instance.new("TextButton")
	row.Name = id
	row.Text = ""
	row.AutoButtonColor = false
	row.BackgroundColor3 = PALETTE.panel2
	row.BackgroundTransparency = 0.25
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, -6, 0, 62)   -- -6 leaves the scrollbar its lane
	row.LayoutOrder = order
	row.Parent = parent
	corner(row, 10)
	local edge = stroke(row, PALETTE.accent, 1.5)
	edge.Transparency = 0.7

	local title = text(row, {
		Size = UDim2.new(1, -118, 0, 20),
		Position = UDim2.fromOffset(12, 8),
		Font = Style.Font.title,
		Text = name,
		TextSize = 16,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local blurb = text(row, {
		Size = UDim2.new(1, -118, 0, 28),
		Position = UDim2.fromOffset(12, 28),
		Font = Style.Font.body,
		Text = "",
		TextSize = 12,
		TextColor3 = PALETTE.muted,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local pill = Instance.new("Frame")
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.new(1, -10, 0.5, 0)
	pill.Size = UDim2.fromOffset(92, 32)
	pill.BackgroundColor3 = PALETTE.good
	pill.BackgroundTransparency = 0.12
	pill.BorderSizePixel = 0
	pill.Parent = row
	corner(pill, 8)

	local pillLabel = text(pill, {
		Size = UDim2.fromScale(1, 1),
		Font = Style.Font.title,
		Text = "",
		TextSize = 15,
		TextScaled = false,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(20, 16, 28),
	})

	row.Activated:Connect(function()
		Net.event("RequestUpgrade"):FireServer(id)
	end)

	rows[id] = { row = row, title = title, blurb = blurb, pill = pill, pillLabel = pillLabel, edge = edge }
	return rows[id]
end

-- ─────────────────────────────────────────────────────────────────────────────
-- redraw
-- ─────────────────────────────────────────────────────────────────────────────

local function paint(entry, opts)
	entry.blurb.Text = opts.blurb
	entry.title.Text = opts.title
	entry.title.TextColor3 = opts.dim and PALETTE.muted or PALETTE.text
	entry.pill.BackgroundColor3 = opts.pillColor
	entry.pillLabel.Text = opts.pillText
	entry.pillLabel.TextColor3 = opts.pillTextColor or Color3.fromRGB(20, 16, 28)
	entry.row.BackgroundTransparency = opts.dim and 0.55 or 0.25
	entry.edge.Transparency = opts.dim and 0.9 or 0.7
end

local function paintPending(entry, name: string)
	paint(entry, {
		title = name,
		blurb = "…",
		pillText = "…",
		pillColor = PALETTE.dead,
		pillTextColor = PALETTE.muted,
		dim = true,
	})
end

local function refreshUpgrades()
	for _, def in ipairs(Config.PlayerUpgrades) do
		local entry = rows[def.id]
		if entry and not state.received then
			paintPending(entry, def.name)
		elseif entry then
			local level = state.levels[def.id] or 0
			local cost = state.costs[def.id]
			local maxed = cost == nil
			local affordable = not maxed and state.cash >= (cost or 0)

			paint(entry, {
				title = ("%s  <font color=\"#8f86a8\">Lv %d/%d</font>"):format(def.name, level, def.levels),
				-- the CURRENT effect, then what the next level moves it to: a
				-- price with no delta doesn't tell you whether to buy
				blurb = maxed and Utilities.describe(def, level)
					or ("%s  →  %s"):format(
						Utilities.describe(def, level),
						Utilities.formatValue(Utilities.valueAt(def, level + 1))),
				pillText = maxed and "MAX" or Util.abbreviate(cost or 0),
				pillColor = maxed and PALETTE.accent or (affordable and PALETTE.good or PALETTE.dead),
				pillTextColor = (not maxed and not affordable) and PALETTE.muted or nil,
				dim = not maxed and not affordable,
			})
		end
	end
end

local function refreshUtilities()
	for _, def in ipairs(Config.Utilities) do
		local entry = rows[def.id]
		if entry and not state.received then
			paintPending(entry, def.name)
		elseif entry then
			local owned = (state.levels[def.id] or 0) >= 1
			local lockedBy = state.locked[def.id]
			local equipped = state.equipped == def.id
			local affordable = state.cash >= def.price

			local pillText, pillColor, dim
			if equipped then
				pillText, pillColor, dim = "EQUIPPED", PALETTE.accent, false
			elseif owned then
				pillText, pillColor, dim = "EQUIP", PALETTE.gold, false
			elseif lockedBy then
				pillText, pillColor, dim = "LOCKED", PALETTE.dead, true
			else
				pillText = Util.abbreviate(def.price)
				pillColor = affordable and PALETTE.good or PALETTE.dead
				dim = not affordable
			end

			paint(entry, {
				title = ("%s  <font color=\"#8f86a8\">%ds cd</font>"):format(def.name, def.cooldown),
				blurb = lockedBy and ("Needs %s."):format(lockedBy) or Utilities.verbBlurb(def),
				pillText = pillText,
				pillColor = pillColor,
				pillTextColor = dim and PALETTE.muted or nil,
				dim = dim,
			})
		end
	end
end

local function refresh()
	if SHOP_ON then
		refreshUpgrades()
	end
	if UTILITY_ON then
		refreshUtilities()
	end
end

--- The chip is both the readout and the touch button for the utility, so a
--- phone player never needs a keyboard. Desktop gets the same thing plus Q.
local function refreshChip()
	if not chipButton then
		return
	end
	if state.equipped == "" then
		chipButton.Visible = false
		return
	end
	chipButton.Visible = true

	local def = Utilities.UtilityById[state.equipped]
	local remaining = math.max(0, state.readyAt - os.clock())
	if os.clock() < flashUntil then
		-- a mistimed press reads as "not yet" rather than as a dropped input
		chipButton.BackgroundColor3 = PALETTE.bad
		chipLabel.Text = ("%.0fs"):format(math.ceil(remaining))
		chipLabel.TextColor3 = Color3.fromRGB(30, 12, 12)
	elseif remaining > 0 then
		chipButton.BackgroundColor3 = PALETTE.dead
		chipLabel.Text = ("%s  •  %.0fs"):format(def and def.name or "?", math.ceil(remaining))
		chipLabel.TextColor3 = PALETTE.muted
	else
		chipButton.BackgroundColor3 = PALETTE.accent
		chipLabel.Text = ("Q   %s"):format(def and def.name or "?")
		chipLabel.TextColor3 = Color3.fromRGB(20, 16, 28)
	end
end

local function fireUtility()
	if not UTILITY_ON or state.equipped == "" then
		return
	end
	local now = os.clock()
	-- Local gates only stop us spamming the wire; the server owns the real
	-- cooldown and will refuse anything early regardless.
	if now < state.readyAt or now - lastSend < SEND_THROTTLE then
		flashUntil = now + 0.25
		refreshChip()
		return
	end
	lastSend = now
	Net.event("UseUtility"):FireServer()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- construction
-- ─────────────────────────────────────────────────────────────────────────────

local function buildPanel(gui: ScreenGui)
	-- bottom-left: HUD owns top-left (cash / next-up), top-centre (wave),
	-- top-right (toasts) and bottom-right (rebirth / leave)
	local anchorY = UTILITY_ON and -118 or -70

	panelFrame = panel(gui, UDim2.new(0, 340, 0.58, 0), UDim2.new(0, 18, 1, anchorY), Vector2.new(0, 1))
	panelFrame.Name = "UpgradeShop"
	panelFrame.Visible = false

	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(340, 460)
	sizeLimit.MinSize = Vector2.new(340, 180)
	sizeLimit.Parent = panelFrame

	text(panelFrame, {
		Size = UDim2.new(1, -28, 0, 26),
		Position = UDim2.fromOffset(14, 10),
		Font = Style.Font.title,
		Text = "TUNG UPGRADES",
		TextSize = 20,
		TextColor3 = PALETTE.accent,
	})

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(14, 42)
	scroll.Size = UDim2.new(1, -28, 1, -56)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	-- XY is the default and lets a row that is one pixel too wide start
	-- scrolling sideways, which looks like a bug rather than like a list
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = PALETTE.accent
	scroll.Parent = panelFrame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local order = 0
	if SHOP_ON then
		order += 1
		sectionLabel(scroll, "PLAYER UPGRADES", order)
		for _, def in ipairs(Config.PlayerUpgrades) do
			order += 1
			buildRow(scroll, def.id, def.name, order)
		end
	end
	if UTILITY_ON then
		order += 1
		sectionLabel(scroll, "UTILITY SLOT  •  ONE EQUIPPED", order)
		for _, def in ipairs(Config.Utilities) do
			order += 1
			buildRow(scroll, def.id, def.name, order)
		end
	end
end

local function buildToggle(gui: ScreenGui)
	toggleButton = button(gui, "UPGRADES", PALETTE.accent, {
		Name = "UpgradeToggle",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 18, 1, -18),
		Size = UDim2.fromOffset(200, 44),
		TextSize = 18,
	})
	toggleButton.Activated:Connect(function()
		panelFrame.Visible = not panelFrame.Visible
		if panelFrame.Visible then
			refresh()
		end
	end)
end

local function buildChip(gui: ScreenGui)
	chipButton = button(gui, "", PALETTE.accent, {
		Name = "UtilityChip",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 18, 1, -70),
		Size = UDim2.fromOffset(200, 40),
		Visible = false,
	})
	chipLabel = text(chipButton, {
		Size = UDim2.fromScale(1, 1),
		Font = Style.Font.title,
		Text = "",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(20, 16, 28),
	})
	chipButton.Activated:Connect(fireUtility)
end

-- ─────────────────────────────────────────────────────────────────────────────

function UpgradeUI.start()
	if not ENABLED then
		return
	end

	local HUD = Req("HUD")
	local gui = HUD.screenGui()
	if not gui then
		-- Main.client calls HUD.start() first, so this only fires if that order
		-- changes; better a warning than a silent half-built shop.
		warn("[Tung] UpgradeUI: HUD.screenGui() is nil, shop not built")
		return
	end

	buildPanel(gui)
	if UTILITY_ON then
		buildChip(gui)
	end
	buildToggle(gui)

	Net.event("UpgradeState").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		state.received = true
		state.levels = payload.levels or {}
		state.costs = payload.costs or {}
		state.locked = payload.locked or {}
		state.equipped = payload.equipped or ""
		state.cooldownTotal = payload.cooldownTotal or 0
		state.readyAt = os.clock() + (payload.cooldown or 0)
		refresh()
		refreshChip()
	end)

	-- Cash comes from the same broadcast HUD reads; a second listener on one
	-- RemoteEvent is free and beats coupling the two panels together.
	Net.event("Stats").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		local cash = payload.cash or 0
		if cash ~= state.cash then
			state.cash = cash
			if panelFrame and panelFrame.Visible then
				refresh()
			end
		end
	end)

	-- The server pushes state as soon as the profile loads, which can land
	-- before this LocalScript has connected its handler — a RemoteEvent fired
	-- at a client with no listener is simply gone, there is no replay. So ask
	-- for it. An id the server doesn't recognise buys nothing and still gets a
	-- push back, which makes RequestUpgrade("") a resync with no new remote.
	task.spawn(function()
		for _ = 1, 6 do
			if state.received then
				return
			end
			Net.event("RequestUpgrade"):FireServer("")
			task.wait(1.5)
		end
	end)

	if UTILITY_ON then
		UserInputService.InputBegan:Connect(function(input, processed)
			-- processed = the player is typing in the chat box
			if not processed and input.KeyCode == USE_KEY then
				fireUtility()
			end
		end)

		-- Only the cooldown readout needs a clock, and only ~10x a second.
		local accumulator = 0
		RunService.Heartbeat:Connect(function(dt)
			accumulator += dt
			if accumulator < 0.1 then
				return
			end
			accumulator = 0
			if chipButton and chipButton.Visible then
				refreshChip()
			end
		end)
	end

	refresh()
end

return UpgradeUI
