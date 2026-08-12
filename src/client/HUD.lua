--[[
	HUD.lua — all of the on-screen furniture.

	Built in code so there is no .rbxm to keep in sync with the source.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local HUD = {}

local PALETTE = {
	panel   = Color3.fromRGB(22, 18, 32),
	panel2  = Color3.fromRGB(32, 26, 46),
	accent  = Color3.fromRGB(190, 130, 255),
	gold    = Color3.fromRGB(255, 205, 90),
	good    = Color3.fromRGB(120, 235, 160),
	bad     = Color3.fromRGB(255, 110, 110),
	text    = Color3.fromRGB(238, 232, 250),
	muted   = Color3.fromRGB(160, 150, 180),
}

local KIND_COLOR = {
	buy      = PALETTE.good,
	warn     = PALETTE.bad,
	wave     = Color3.fromRGB(255, 150, 60),
	boss     = Color3.fromRGB(255, 90, 60),
	rebirth  = PALETTE.accent,
	gear     = PALETTE.gold,
	ko       = Color3.fromRGB(255, 230, 140),
	claim    = PALETTE.good,
	welcome  = PALETTE.gold,
	info     = PALETTE.accent,
}

local state = {
	cash = 0,
	rebirths = 0,
	kills = 0,
	multiplier = 1,
	owned = {},
	rebirthCost = Config.Rebirth.BaseCost,
}

local gui, cashLabel, multLabel, waveFrame, waveLabel, toastList, nextLabel, nextDetail, rebirthButton

-- ─────────────────────────────────────────────────────────────────────────────
-- builders
-- ─────────────────────────────────────────────────────────────────────────────

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 2
	s.Transparency = 0.35
	s.Parent = parent
	return s
end

local function panel(parent, size, position, anchor)
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

local function text(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextColor3 = PALETTE.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextScaled = false
	l.RichText = true
	for k, v in pairs(props) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

local function button(parent, label, color, props)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = color
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.FredokaOne
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

local function buildCashPanel(root)
	local frame = panel(root, UDim2.fromOffset(280, 96), UDim2.fromOffset(18, 18))
	frame.Name = "Cash"

	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromOffset(56, 56)
	icon.Position = UDim2.fromOffset(14, 20)
	icon.BackgroundColor3 = PALETTE.gold
	icon.BackgroundTransparency = 0.15
	icon.Font = Enum.Font.FredokaOne
	icon.Text = "T"
	icon.TextColor3 = Color3.fromRGB(40, 28, 10)
	icon.TextScaled = true
	icon.Parent = frame
	corner(icon, 28)

	cashLabel = text(frame, {
		Size = UDim2.fromOffset(190, 42),
		Position = UDim2.fromOffset(80, 16),
		Font = Enum.Font.FredokaOne,
		Text = "0",
		TextSize = 34,
		TextColor3 = PALETTE.gold,
	})

	multLabel = text(frame, {
		Size = UDim2.fromOffset(190, 26),
		Position = UDim2.fromOffset(80, 56),
		Font = Enum.Font.GothamMedium,
		Text = "x1.00  •  0 rebirths",
		TextSize = 15,
		TextColor3 = PALETTE.muted,
	})

	return frame
end

local function buildNextPanel(root)
	local frame = panel(root, UDim2.fromOffset(280, 74), UDim2.fromOffset(18, 124))
	frame.Name = "NextUp"

	text(frame, {
		Size = UDim2.fromOffset(250, 18),
		Position = UDim2.fromOffset(14, 8),
		Font = Enum.Font.GothamBold,
		Text = "NEXT UPGRADE",
		TextSize = 12,
		TextColor3 = PALETTE.muted,
	})

	nextLabel = text(frame, {
		Size = UDim2.fromOffset(252, 26),
		Position = UDim2.fromOffset(14, 24),
		Font = Enum.Font.FredokaOne,
		Text = "Tung Dropper — 50",
		TextSize = 18,
		TextColor3 = PALETTE.text,
	})

	-- The gap to the next purchase, and how far through the build you are. A
	-- price on its own doesn't tell you whether to keep grinding or go and
	-- fight a wave for the bounty.
	nextDetail = text(frame, {
		Size = UDim2.fromOffset(252, 18),
		Position = UDim2.fromOffset(14, 48),
		Font = Enum.Font.GothamMedium,
		Text = "",
		TextSize = 13,
		TextColor3 = PALETTE.muted,
	})

	return frame
end

local function buildWaveBanner(root)
	waveFrame = panel(root, UDim2.fromOffset(420, 62), UDim2.new(0.5, 0, 0, 18), Vector2.new(0.5, 0))
	waveFrame.Name = "Wave"
	waveFrame.Visible = false
	waveFrame.BackgroundColor3 = Color3.fromRGB(48, 18, 18)

	waveLabel = text(waveFrame, {
		Size = UDim2.fromScale(1, 1),
		Font = Enum.Font.FredokaOne,
		Text = "SAHUR RAID",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Color3.fromRGB(255, 170, 110),
	})
end

local function buildToasts(root)
	toastList = Instance.new("Frame")
	toastList.Name = "Toasts"
	toastList.AnchorPoint = Vector2.new(1, 0)
	toastList.Position = UDim2.new(1, -18, 0, 18)
	toastList.Size = UDim2.fromOffset(320, 500)
	toastList.BackgroundTransparency = 1
	toastList.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = toastList
end

local function buildActions(root)
	local holder = Instance.new("Frame")
	holder.Name = "Actions"
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -18, 1, -18)
	holder.Size = UDim2.fromOffset(200, 104)
	holder.BackgroundTransparency = 1
	holder.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Parent = holder

	rebirthButton = button(holder, "REBIRTH", PALETTE.accent, {
		Size = UDim2.fromOffset(200, 48),
		LayoutOrder = 1,
	})
	local leave = button(holder, "LEAVE PLOT", Color3.fromRGB(120, 110, 140), {
		Size = UDim2.fromOffset(200, 40),
		LayoutOrder = 2,
		TextSize = 16,
	})

	rebirthButton.Activated:Connect(function()
		HUD.showRebirthModal(state.rebirthCost)
	end)
	leave.Activated:Connect(function()
		Net.event("RequestReset"):FireServer()
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- behaviour
-- ─────────────────────────────────────────────────────────────────────────────

local toastOrder = 0

function HUD.toast(payload)
	if not toastList then
		return
	end
	toastOrder += 1

	local color = KIND_COLOR[payload.kind] or PALETTE.accent

	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(320, 66)
	card.BackgroundColor3 = PALETTE.panel
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.LayoutOrder = toastOrder
	card.Parent = toastList
	corner(card, 12)
	stroke(card, color, 2)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(5, 50)
	bar.Position = UDim2.fromOffset(10, 8)
	bar.BackgroundColor3 = color
	bar.BorderSizePixel = 0
	bar.Parent = card
	corner(bar, 3)

	text(card, {
		Size = UDim2.fromOffset(280, 22),
		Position = UDim2.fromOffset(24, 8),
		Font = Enum.Font.FredokaOne,
		Text = payload.title or "",
		TextSize = 17,
		TextColor3 = color,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	text(card, {
		Size = UDim2.fromOffset(280, 30),
		Position = UDim2.fromOffset(24, 30),
		Font = Enum.Font.Gotham,
		Text = payload.body or "",
		TextSize = 13,
		TextColor3 = PALETTE.muted,
		TextWrapped = true,
	})

	card.Position = UDim2.fromOffset(340, 0)
	TweenService:Create(card, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(0, 0),
	}):Play()

	task.delay(4.5, function()
		if not card.Parent then
			return
		end
		local out = TweenService:Create(card, TweenInfo.new(0.25), { BackgroundTransparency = 1 })
		out:Play()
		out.Completed:Once(function()
			card:Destroy()
		end)
	end)
end

function HUD.showRebirthModal(cost: number)
	if gui:FindFirstChild("RebirthModal") then
		return
	end

	local shade = Instance.new("Frame")
	shade.Name = "RebirthModal"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = 20
	shade.Parent = gui

	local card = panel(shade, UDim2.fromOffset(430, 250), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	card.ZIndex = 21
	for _, child in ipairs(card:GetDescendants()) do
		if child:IsA("GuiObject") then
			child.ZIndex = 21
		end
	end

	text(card, {
		Size = UDim2.fromOffset(390, 34),
		Position = UDim2.fromOffset(20, 18),
		Font = Enum.Font.FredokaOne,
		Text = "SAHUR REBIRTH",
		TextSize = 28,
		TextColor3 = PALETTE.accent,
		ZIndex = 22,
	})

	local affordable = state.cash >= cost
	text(card, {
		Size = UDim2.fromOffset(390, 96),
		Position = UDim2.fromOffset(20, 58),
		Font = Enum.Font.Gotham,
		Text = ("Cost: <b>%s Tung</b>\n\nYour factory and cash are wiped, but every payout after this is permanently multiplied.\n\nNext multiplier: <b>x%.2f</b>")
			:format(Util.abbreviate(cost), Config.Rebirth.MultiplierPerRebirth ^ (state.rebirths + 1)),
		TextSize = 15,
		TextColor3 = affordable and PALETTE.text or PALETTE.muted,
		TextWrapped = true,
		ZIndex = 22,
	})

	local confirm = button(card, affordable and "DO IT" or "NOT ENOUGH TUNG",
		affordable and PALETTE.accent or Color3.fromRGB(90, 84, 104), {
			Size = UDim2.fromOffset(190, 46),
			Position = UDim2.fromOffset(20, 180),
			ZIndex = 22,
			TextSize = 20,
		})
	local cancel = button(card, "CANCEL", Color3.fromRGB(120, 110, 140), {
		Size = UDim2.fromOffset(190, 46),
		Position = UDim2.fromOffset(220, 180),
		ZIndex = 22,
		TextSize = 20,
	})

	confirm.Activated:Connect(function()
		if affordable then
			Net.event("RequestRebirth"):FireServer()
		end
		shade:Destroy()
	end)
	cancel.Activated:Connect(function()
		shade:Destroy()
	end)
end

local function cheapestAvailable()
	local best
	for _, def in ipairs(Config.Buttons) do
		if not state.owned[def.id] then
			local ok = true
			for _, req in ipairs(Config.requirementsOf(def)) do
				if not state.owned[req] then
					ok = false
					break
				end
			end
			if ok and (not best or def.price < best.price) then
				best = def
			end
		end
	end
	return best
end

local displayedCash = 0

function HUD.applyStats(payload)
	state.cash = payload.cash or 0
	state.rebirths = payload.rebirths or 0
	state.kills = payload.kills or 0
	state.multiplier = payload.multiplier or 1
	state.owned = payload.owned or {}
	state.rebirthCost = payload.rebirthCost or state.rebirthCost

	multLabel.Text = ("x%.2f  •  %d rebirth%s  •  %d KO%s"):format(
		state.multiplier, state.rebirths, state.rebirths == 1 and "" or "s",
		state.kills, state.kills == 1 and "" or "s")

	local owned = 0
	for _, def in ipairs(Config.Buttons) do
		if state.owned[def.id] then
			owned += 1
		end
	end

	local next_ = cheapestAvailable()
	if next_ then
		local affordable = state.cash >= next_.price
		nextLabel.Text = ("%s — %s"):format(next_.name, Util.abbreviate(next_.price))
		nextLabel.TextColor3 = affordable and PALETTE.good or PALETTE.text
		nextDetail.Text = affordable
			and ("step %d of %d  •  affordable now"):format(owned + 1, #Config.Buttons)
			or ("step %d of %d  •  %s to go"):format(owned + 1, #Config.Buttons,
				Util.abbreviate(next_.price - state.cash))
		nextDetail.TextColor3 = affordable and PALETTE.good or PALETTE.muted
	else
		nextLabel.Text = "Factory complete. Rebirth?"
		nextLabel.TextColor3 = PALETTE.accent
		nextDetail.Text = ("all %d steps built"):format(#Config.Buttons)
		nextDetail.TextColor3 = PALETTE.muted
	end

	rebirthButton.Text = ("REBIRTH  %s"):format(Util.abbreviate(state.rebirthCost))
	rebirthButton.BackgroundColor3 = state.cash >= state.rebirthCost and PALETTE.accent or Color3.fromRGB(90, 84, 104)
end

function HUD.applyWave(payload)
	if not waveFrame then
		return
	end
	if payload.phase == "warning" then
		waveFrame.Visible = true
		waveLabel.Text = ("SAHUR RAID %d IN %ds"):format(payload.wave, payload.seconds or 10)
		waveLabel.TextColor3 = Color3.fromRGB(255, 190, 120)
	elseif payload.phase == "active" then
		waveFrame.Visible = true
		waveLabel.Text = ("WAVE %d  •  %d RAIDERS LEFT"):format(payload.wave, payload.remaining or 0)
		waveLabel.TextColor3 = Color3.fromRGB(255, 140, 110)
	elseif payload.phase == "clear" then
		waveLabel.Text = ("WAVE %d CLEARED"):format(payload.wave)
		waveLabel.TextColor3 = PALETTE.good
		task.delay(4, function()
			if waveFrame then
				waveFrame.Visible = false
			end
		end)
	end
end

function HUD.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "TungHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	buildCashPanel(gui)
	buildNextPanel(gui)
	buildWaveBanner(gui)
	buildToasts(gui)
	buildActions(gui)

	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if payload.kind == "rebirthPrompt" then
			HUD.showRebirthModal(payload.cost or state.rebirthCost)
		else
			HUD.toast(payload)
		end
	end)

	Net.event("Stats").OnClientEvent:Connect(HUD.applyStats)
	Net.event("WaveState").OnClientEvent:Connect(HUD.applyWave)

	-- smooth counting cash so big numbers feel good
	RunService.RenderStepped:Connect(function(dt)
		if math.abs(displayedCash - state.cash) < 0.5 then
			displayedCash = state.cash
		else
			displayedCash += (state.cash - displayedCash) * math.min(dt * 9, 1)
		end
		cashLabel.Text = Util.abbreviate(displayedCash)
	end)

	return gui
end

function HUD.screenGui(): ScreenGui
	return gui
end

return HUD
