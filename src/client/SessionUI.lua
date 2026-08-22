--[[
	SessionUI.lua — the welcome-back panel, the daily / playtime claims and the
	boost button.

	Built into HUD's layers rather than a second ScreenGui so there is one place
	the game's UI lives, one ZIndex space, one UIScale and one thing to hide:
	the panel goes in HUD.column(), the welcome-back modal on HUD.overlay().

	IT NO LONGER KNOWS WHERE IT IS. The panel used to position itself at
	(Config.UI.Margin, Config.UI.SessionPanel.Y) while HUD.lua positioned the
	status card above it from Config.UI.StatusCard.Y — one column, two files, two
	reads. HUD.column() is a UIListLayout; this file sets a LayoutOrder and every
	remaining number in it is a row height from Config.UI.SessionPanel.

	The palette and the panel/text/button helpers used to be re-stated here, on
	the argument that a prototype which widens another module's public API is a
	prototype you cannot delete. Three copies later the drift risk outweighed
	the deletion cost, and they moved to src/client/UiKit.lua — which is not
	HUD's API, so the original argument is satisfied rather than overruled.

	Everything is presentation. The server sends the whole state on the
	SessionState remote and decides every claim; this file's only outbound
	messages are "I pressed the button". Note that the Vault Timer button sends
	`{ kind = "capUpgrade" }` and NOT a level or a price — the server owns which
	rung is next and what it costs.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Net = Req("Net")
local HUD = Req("HUD")
local UiKit = Req("UiKit")
local Sound = Req("Sound")

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local SessionUI = {}

local UI = Config.UI
local PALETTE = UiKit.PALETTE
-- Spelled from `Config`, like HUD.lua's CARD, because verify.py's config-path
-- pass follows exactly one alias hop. Every number in this file comes from here
-- now; there is no X and no Y among them, because HUD.column() places the panel.
local PANEL = Config.UI.SessionPanel
local OFFLINE = Config.UI.Modal.Offline

local state = {
	payload = nil :: any,
	receivedAt = 0,
}

local column, overlay, panel, dailyRow, playtimeRow, boostButton, vaultRow, offlineRow, weekendBadge
local playtimeFill, modalOpen = nil, false
-- The optional rows, in the order layoutTail() stacks them, and the list
-- Config.UI.SessionPanel.OptionalRows counts. Filled by buildPanel; see
-- layoutTail for why the two have to agree.
local TAIL_ROWS = nil :: any

-- ─────────────────────────────────────────────────────────────────────────────
-- builders
-- ─────────────────────────────────────────────────────────────────────────────

local corner, frame, text = UiKit.corner, UiKit.panel, UiKit.text

--- THE ONE PLACE THIS PANEL DISAGREES WITH THE REST OF THE UI, and the reason
--- the merge into UiKit was not a straight deletion. Every button in HUD and
--- UpgradeUI is TextScaled; every button in here is sized text at 15, because
--- these labels are long ("BOOST READY IN 12:04") in boxes that are not, and
--- TextScaled would set each of them at a different size. Two properties
--- pre-seeded into `props` before forwarding buys that back without touching
--- the three call sites below — and it is deliberately NOT tidied away in the
--- same change that moved the helpers, so that if sized text turns out to be
--- the wrong call on a phone there is one function to look at.
local function button(parent: Instance, label: string, color: Color3, props): TextButton
	props = props or {}
	if props.TextScaled == nil then
		props.TextScaled = false
	end
	if props.TextSize == nil then
		props.TextSize = 15
	end
	return UiKit.button(parent, label, color, props)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- formatting
-- ─────────────────────────────────────────────────────────────────────────────

--- "6h 12m" — the welcome-back panel has to say how long you were gone, and a
--- raw second count is not an answer to that question.
local function describe(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local days = seconds // 86400
	local hours = (seconds % 86400) // 3600
	local minutes = (seconds % 3600) // 60
	if days > 0 then
		return ("%dd %dh"):format(days, hours)
	elseif hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	elseif minutes > 0 then
		return ("%dm"):format(minutes)
	end
	return ("%ds"):format(seconds)
end

--- mm:ss for anything under an hour, h:mm:ss above it
local function clockText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%d:%02d:%02d"):format(seconds // 3600, (seconds % 3600) // 60, seconds % 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

--- Seconds elapsed since the last server push, so every countdown ticks
--- smoothly between pushes instead of stepping once every five seconds.
local function elapsed(): number
	if state.receivedAt == 0 then
		return 0
	end
	return os.clock() - state.receivedAt
end

local function click()
	Sound.play("ui", { volume = 0.4 })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- welcome-back modal
-- ─────────────────────────────────────────────────────────────────────────────

--- The panel is half the value of offline earnings, and the claim IS the
--- reward: nothing is ever credited silently, so the number counts up in front
--- of you and you press the button.
function SessionUI.showOfflineModal(offline)
	if not overlay or modalOpen or not offline then
		return
	end
	modalOpen = true

	-- HUD.overlay(), not HUD.root(): the shade has to dim the safe area it is
	-- covering, and the root layer is padded clear of exactly that strip.
	local shade = Instance.new("Frame")
	shade.Name = "OfflineModal"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = 30
	shade.Parent = overlay

	local card = frame(shade,
		UDim2.fromOffset(OFFLINE.Width, OFFLINE.Height),
		UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	card.ZIndex = 31
	for _, child in ipairs(card:GetDescendants()) do
		if child:IsA("GuiObject") then
			child.ZIndex = 31
		end
	end

	text(card, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, OFFLINE.TitleHeight),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.TitleY),
		Font = Style.Font.title,
		Text = "WELCOME BACK",
		TextSize = OFFLINE.TitleTextPx,
		TextColor3 = PALETTE.accent,
		ZIndex = 32,
	})

	text(card, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, OFFLINE.AwayHeight),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.AwayY),
		Font = Style.Font.body,
		Text = ("Away for <b>%s</b> — your factory kept running."):format(describe(offline.seconds)),
		TextSize = OFFLINE.AwayTextPx,
		TextColor3 = PALETTE.muted,
		ZIndex = 32,
	})

	local amount = text(card, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, OFFLINE.AmountHeight),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.AmountY),
		Font = Style.Font.title,
		Text = "0",
		TextSize = OFFLINE.AmountTextPx,
		TextColor3 = PALETTE.gold,
		ZIndex = 32,
	})

	text(card, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, OFFLINE.RateHeight),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.RateY),
		Font = Style.Font.body,
		Text = ("%d%% of %s/sec for %s"):format(
			math.floor((offline.rate or 0) * 100 + 0.5),
			Util.abbreviate(offline.perSecond or 0),
			describe(offline.creditedSeconds or offline.seconds)),
		TextSize = OFFLINE.RateTextPx,
		TextColor3 = PALETTE.muted,
		ZIndex = 32,
	})

	-- The cap line. If it clipped you, saying so and naming the fix is the
	-- whole difference between a cap that reads as a goal and one that reads
	-- as a confiscation.
	local capText, capColor
	if offline.clipped then
		local upgrade = offline.upgrade
		capText = ("<b>Capped at %dh.</b> %s of tung went uncollected."):format(
			offline.capHours, Util.abbreviate(offline.lost or 0))
		if upgrade then
			capText ..= ("\n<b>%s</b> banks %dh instead — %s, in the session panel."):format(
				upgrade.name, upgrade.hours, Util.abbreviate(upgrade.cost))
		else
			capText ..= "\nYou already own the longest vault timer."
		end
		capColor = PALETTE.bad
	else
		capText = ("Well inside your %dh offline cap."):format(offline.capHours)
		capColor = PALETTE.good
	end

	text(card, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, OFFLINE.CapHeight),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.CapY),
		Font = Style.Font.body,
		Text = capText,
		TextSize = OFFLINE.CapTextPx,
		TextColor3 = capColor,
		TextWrapped = true,
		ZIndex = 32,
	})

	local collect = button(card, ("COLLECT %s"):format(Util.abbreviate(offline.earned)), PALETTE.good, {
		Size = UDim2.fromOffset(OFFLINE.ContentWidth, UI.Button.primary),
		Position = UDim2.fromOffset(OFFLINE.Pad, OFFLINE.ButtonY),
		TextSize = OFFLINE.ButtonTextPx,
		ZIndex = 32,
	})

	-- count-up: the number arriving instantly is a fact, the number climbing is
	-- a payout
	local shown = 0
	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		if not amount.Parent then
			connection:Disconnect()
			return
		end
		shown += (offline.earned - shown) * math.min(dt * 4, 1)
		if offline.earned - shown < 1 then
			shown = offline.earned
			connection:Disconnect()
		end
		amount.Text = Util.abbreviate(shown)
	end)

	collect.Activated:Connect(function()
		click()
		Sound.play("purchase", { volume = 0.6 })
		Net.event("RequestClaim"):FireServer({ kind = "offline" })
		modalOpen = false
		shade:Destroy()
	end)

	card.Position = UDim2.fromScale(0.5, 0.56)
	TweenService:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(0.5, 0.5),
	}):Play()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the session panel
-- ─────────────────────────────────────────────────────────────────────────────

local function buildRow(parent: Instance, y: number, height: number, title: string)
	local row = Instance.new("Frame")
	row.Size = UDim2.fromOffset(PANEL.RowWidth, height)
	row.Position = UDim2.fromOffset(PANEL.Pad, y)
	row.BackgroundColor3 = PALETTE.panel2
	row.BackgroundTransparency = 0.25
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 10)

	local titleLabel = text(row, {
		Size = UDim2.fromOffset(PANEL.ActionTextWidth, PANEL.RowTitleHeight),
		Position = UDim2.fromOffset(PANEL.RowPad, PANEL.RowPadY),
		Font = Style.Font.title,
		Text = title,
		TextSize = PANEL.RowTitleTextPx,
		TextColor3 = PALETTE.text,
	})
	local subLabel = text(row, {
		Size = UDim2.fromOffset(PANEL.ActionTextWidth, PANEL.RowSubHeight),
		Position = UDim2.fromOffset(PANEL.RowPad, PANEL.RowSubY),
		Font = Style.Font.body,
		Text = "",
		TextSize = PANEL.RowSubTextPx,
		TextColor3 = PALETTE.muted,
	})
	-- A 66x30 pill was a 41x19 physical target at MinScale, which is a coin
	-- flip with a thumb. Full touch height, vertically centred in whatever row
	-- it lands in — the rows are 46, 50 and 56 tall.
	local action = button(row, "CLAIM", PALETTE.good, {
		Size = UDim2.fromOffset(PANEL.ActionWidth, UI.Button.pill),
		Position = UDim2.fromOffset(PANEL.ActionX, math.round((height - UI.Button.pill) / 2)),
		TextSize = PANEL.ActionTextPx,
		Visible = false,
	})

	return { row = row, title = titleLabel, sub = subLabel, action = action }
end

--- NO POSITION, AND NO PANEL_X / PANEL_Y ANY MORE. The parent is HUD.column(),
--- which stacks it under the status card; this file used to read
--- Config.UI.SessionPanel.Y and HUD.lua used to read Config.UI.StatusCard.Y, and
--- two files deriving where one column goes is the disagreement Config.UI's
--- column comment says that table exists to prevent.
local function buildPanel()
	panel = frame(column, UDim2.fromOffset(PANEL.Width, PANEL.Height), UDim2.fromOffset(0, 0))
	panel.Name = "Session"
	panel.LayoutOrder = 2
	panel.Visible = false

	text(panel, {
		Size = UDim2.fromOffset(PANEL.ActionTextWidth, PANEL.HeadHeight),
		Position = UDim2.fromOffset(PANEL.Pad, PANEL.HeadPad),
		Font = Style.Font.body,
		Text = "SESSION",
		TextSize = PANEL.HeadTextPx,
		TextColor3 = PALETTE.muted,
	})

	-- the weekend bonus is server-wide and invisible unless something says so
	weekendBadge = text(panel, {
		Size = UDim2.fromOffset(PANEL.BadgeWidth, PANEL.HeadHeight),
		Position = UDim2.fromOffset(PANEL.BadgeX, PANEL.HeadPad),
		Font = Style.Font.body,
		Text = "",
		TextSize = PANEL.HeadTextPx,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = PALETTE.gold,
	})

	dailyRow = buildRow(panel, PANEL.DailyY, PANEL.DailyHeight, "DAILY STREAK")
	playtimeRow = buildRow(panel, PANEL.PlaytimeY, PANEL.PlaytimeHeight, "PLAYTIME")

	-- a thin progress bar along the bottom of the playtime row: the ladder is
	-- the only part of this panel with a "how far to go" answer
	local track = Instance.new("Frame")
	track.Size = UDim2.fromOffset(PANEL.BarWidth, PANEL.BarHeight)
	track.Position = UDim2.fromOffset(PANEL.RowPad, PANEL.BarY)
	track.BackgroundColor3 = PALETTE.panel
	track.BorderSizePixel = 0
	track.Parent = playtimeRow.row
	corner(track, 2)

	playtimeFill = Instance.new("Frame")
	playtimeFill.Size = UDim2.fromScale(0, 1)
	playtimeFill.BackgroundColor3 = PALETTE.accent
	playtimeFill.BorderSizePixel = 0
	playtimeFill.Parent = track
	corner(playtimeFill, 2)

	boostButton = button(panel, "BOOST", PALETTE.gold, {
		Size = UDim2.fromOffset(PANEL.RowWidth, UI.Button.secondary),
		Position = UDim2.fromOffset(PANEL.Pad, PANEL.BoostY),
		TextSize = PANEL.BoostTextPx,
	})

	-- Both of these are positioned by layoutTail() rather than here: they come
	-- and go independently and a fixed y for each leaves a hole in the panel.
	vaultRow = buildRow(panel, PANEL.StackTop, PANEL.RowHeight, "VAULT TIMER")
	vaultRow.row.Visible = false
	vaultRow.action.BackgroundColor3 = PALETTE.gold

	offlineRow = buildRow(panel, PANEL.StackTop, PANEL.RowHeight, "OFFLINE TUNG")
	TAIL_ROWS = { vaultRow, offlineRow }
	offlineRow.row.Visible = false
	offlineRow.action.Text = "OPEN"
	offlineRow.action.BackgroundColor3 = PALETTE.gold

	dailyRow.action.Activated:Connect(function()
		click()
		Net.event("RequestClaim"):FireServer({ kind = "daily" })
	end)

	playtimeRow.action.Activated:Connect(function()
		click()
		local payload = state.payload
		local rungs = payload and payload.playtime and payload.playtime.rungs
		if not rungs then
			return
		end
		for _, rung in ipairs(rungs) do
			if rung.status == "ready" then
				Net.event("RequestClaim"):FireServer({ kind = "playtime", index = rung.index })
				return
			end
		end
	end)

	boostButton.Activated:Connect(function()
		click()
		Net.event("RequestBoost"):FireServer()
	end)

	vaultRow.action.Activated:Connect(function()
		click()
		-- INTENT ONLY. No level, no price: the server reads both from Config and
		-- spends through Economy, so a client that sends a different number gets
		-- charged the real one.
		Net.event("RequestClaim"):FireServer({ kind = "capUpgrade" })
	end)

	offlineRow.action.Activated:Connect(function()
		click()
		local payload = state.payload
		if payload and payload.offline then
			SessionUI.showOfflineModal(payload.offline)
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- rendering
-- ─────────────────────────────────────────────────────────────────────────────

local function renderDaily(daily)
	if not daily then
		dailyRow.row.Visible = false
		return
	end
	dailyRow.row.Visible = true

	if daily.available then
		dailyRow.title.Text = ("DAILY  •  DAY %d"):format(daily.nextStreak)
		dailyRow.sub.Text = daily.milestone
			and ("%s  +  %s milestone"):format(Util.abbreviate(daily.reward - daily.milestone), Util.abbreviate(daily.milestone))
			or ("%s waiting"):format(Util.abbreviate(daily.reward))
		dailyRow.sub.TextColor3 = PALETTE.good
		dailyRow.action.Visible = true
		dailyRow.action.Text = "CLAIM"
		dailyRow.action.BackgroundColor3 = PALETTE.good
	else
		dailyRow.title.Text = ("DAILY  •  %d DAY STREAK"):format(daily.streak)
		dailyRow.sub.Text = ("next in %s  •  %dh grace"):format(
			describe(math.max(0, (daily.resetIn or 0) - elapsed())), daily.graceHours)
		dailyRow.sub.TextColor3 = PALETTE.muted
		dailyRow.action.Visible = false
	end
end

local function renderPlaytime(playtime)
	if not playtime then
		playtimeRow.row.Visible = false
		return
	end
	playtimeRow.row.Visible = true

	-- the server only counts ACTIVE seconds, so this clock is allowed to run
	-- ahead of it locally but must never claim on its own
	local active = playtime.activeSeconds + elapsed()

	local ready, nextRung
	for _, rung in ipairs(playtime.rungs) do
		if rung.status == "ready" and not ready then
			ready = rung
		elseif rung.status == "locked" and not nextRung then
			nextRung = rung
		end
	end

	if ready then
		playtimeRow.title.Text = ("PLAYTIME  •  %d MIN"):format(ready.minutes)
		playtimeRow.sub.Text = ("%s ready to claim"):format(Util.abbreviate(ready.reward))
		playtimeRow.sub.TextColor3 = PALETTE.good
		playtimeRow.action.Visible = true
		playtimeFill.Size = UDim2.fromScale(1, 1)
	elseif nextRung then
		local target = nextRung.minutes * 60
		playtimeRow.title.Text = "PLAYTIME"
		playtimeRow.sub.Text = ("%s at %d min  •  %s to go"):format(
			Util.abbreviate(nextRung.reward), nextRung.minutes, clockText(target - active))
		playtimeRow.sub.TextColor3 = PALETTE.muted
		playtimeRow.action.Visible = false
		local previous = 0
		for _, rung in ipairs(playtime.rungs) do
			if rung.index < nextRung.index then
				previous = rung.minutes * 60
			end
		end
		local span = math.max(1, target - previous)
		playtimeFill.Size = UDim2.fromScale(math.clamp((active - previous) / span, 0, 1), 1)
	else
		playtimeRow.title.Text = "PLAYTIME"
		-- The ladder is claimed per UTC DAY now, not per session, so this line
		-- has to say when it comes back rather than implying a reconnect does it.
		playtimeRow.sub.Text = ("whole ladder claimed  •  resets in %s"):format(
			describe(math.max(0, (playtime.resetIn or 0) - elapsed())))
		playtimeRow.sub.TextColor3 = PALETTE.muted
		playtimeRow.action.Visible = false
		playtimeFill.Size = UDim2.fromScale(1, 1)
	end
end

--- The Vault Timer, as a row you can press. The panel used to name this upgrade
--- in the welcome-back modal and offer no way to buy it.
local function renderVault(payload)
	local upgrade = payload.capUpgrade
	if not upgrade then
		vaultRow.row.Visible = false     -- the longest timer is already owned
		return
	end
	vaultRow.row.Visible = true
	vaultRow.title.Text = upgrade.name:upper()
	vaultRow.sub.Text = ("banks %dh offline, up from %dh"):format(
		upgrade.hours, payload.capHours or upgrade.hours)
	vaultRow.sub.TextColor3 = PALETTE.muted
	vaultRow.action.Visible = true
	vaultRow.action.Text = Util.abbreviate(upgrade.cost)
end

local function renderBoost(boost)
	if not boost then
		boostButton.Visible = false
		return
	end
	boostButton.Visible = true

	local since = elapsed()
	if boost.active then
		boostButton.Text = ("x%g BOOST  •  %s"):format(boost.multiplier, clockText(boost.secondsLeft - since))
		boostButton.BackgroundColor3 = PALETTE.good
	elseif boost.cooldownLeft - since > 0 then
		boostButton.Text = ("BOOST READY IN %s"):format(clockText(boost.cooldownLeft - since))
		boostButton.BackgroundColor3 = PALETTE.dead
	else
		boostButton.Text = ("CLAIM x%g BOOST  •  %d MIN"):format(boost.multiplier, boost.duration // 60)
		boostButton.BackgroundColor3 = PALETTE.gold
	end

	weekendBadge.Text = boost.weekend and ("WEEKEND x%g"):format(boost.weekendMultiplier) or ""
end

--- invariant: stack whichever optional rows are showing, and size the panel to
--- them. THE PANEL'S HEIGHT HAS EXACTLY ONE OWNER AND IT IS THIS FUNCTION.
---
--- A second write in render() is invisible — this one lands after it — and the
--- last one to try it was wrong by a whole row, because both optional rows show
--- at once for any returning player who has not maxed the vault.
---
--- THE ARITHMETIC BELOW IS THE ARITHMETIC Config DERIVES TallHeight FROM, so a
--- full tail produces exactly TallHeight and the number the verifier holds the
--- column to is a number this function can actually reach. TAIL_ROWS is what
--- OptionalRows counts: adding a third row here without adding it there is a
--- panel that grows past the budget again, and tools/testing/specs/hud_spec.lua
--- is what says so.
local function layoutTail()
	local y = PANEL.StackTop
	local shown = 0
	for _, row in ipairs(TAIL_ROWS) do
		if row.row.Visible then
			row.row.Position = UDim2.fromOffset(PANEL.Pad, y)
			y += PANEL.RowHeight + PANEL.RowGap
			shown += 1
		end
	end
	local height = shown == 0 and PANEL.Height or (y - PANEL.RowGap + PANEL.TailPad)
	panel.Size = UDim2.fromOffset(PANEL.Width, height)
end

local function render()
	local payload = state.payload
	if not payload or not panel then
		return
	end
	-- #96: the panel arrives when the streak and the ladder mean something
	if not HUD.disclosed("session") then
		panel.Visible = false
		return
	end
	panel.Visible = true

	renderDaily(payload.daily)
	renderPlaytime(payload.playtime)
	renderBoost(payload.boost)
	renderVault(payload)

	if payload.offline then
		offlineRow.row.Visible = true
		offlineRow.sub.Text = ("%s from %s away"):format(
			Util.abbreviate(payload.offline.earned), describe(payload.offline.seconds))
		offlineRow.sub.TextColor3 = PALETTE.gold
		offlineRow.action.Visible = true
	else
		offlineRow.row.Visible = false
	end

	-- ...and layoutTail owns the height. There were two sizes written here and
	-- both were dead: this function set one and the next line overwrote it.
	layoutTail()
end

function SessionUI.start()
	-- HUD.column(), not HUD.root(): this panel belongs in the left column's
	-- stack, and taking the column rather than the layer is what stops it having
	-- an opinion about where that column starts.
	column = HUD.column()
	HUD.onDisclosure(render)
	if not column then
		-- HUD.start() runs first in Main.client.lua, but a prototype that
		-- assumes boot order is a prototype that breaks when the boot order
		-- changes
		for _ = 1, 100 do
			task.wait(0.1)
			column = HUD.column()
			if column then
				break
			end
		end
		if not column then
			warn("[Tung] SessionUI: no HUD column to build into")
			return
		end
	end
	overlay = HUD.overlay()

	buildPanel()

	Net.event("SessionState").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local hadOffline = state.payload and state.payload.offline
		state.payload = payload
		state.receivedAt = os.clock()
		render()

		-- first sight of a pending offline grant opens the panel by itself;
		-- after that it lives in the row so a mis-click cannot lose it
		if payload.offline and not hadOffline then
			SessionUI.showOfflineModal(payload.offline)
		end
	end)

	-- countdowns tick locally between pushes; the server still owns every
	-- number this reads from
	task.spawn(function()
		while true do
			task.wait(1)
			if state.payload then
				render()
			end
		end
	end)
end

return SessionUI
