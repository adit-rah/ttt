--[[
	HUD.lua — all of the on-screen furniture, and the one ScreenGui the whole
	game draws into.

	Built in code so there is no .rbxm to keep in sync with the source.

	IT OWNS THE TWO LAYERS EVERY OTHER PANEL BUILDS INTO. `Root` carries the
	UIScale and the safe-area padding and holds the persistent furniture;
	`Overlay` carries the same UIScale and no padding, and holds modals, because
	a dimming shade SHOULD run under the notch and a padded root would leave an
	undimmed strip down the side of it. Panels ask for HUD.root() or
	HUD.overlay(); nothing outside this file makes a ScreenGui, and tools/
	verify.py fails the build if anything tries.

	AND FOUR DOCKED REGIONS INSIDE Root, one per corner it uses:

	  Column    top-left, a UIListLayout — the status card, then whatever else
	            belongs in the stack under it. HUD.column() hands it out.
	  Rail      top-right, the utility icons. One item today, the invite.
	  Toasts    top-right under the rail, derived to clear it.
	  Actions   bottom-right, RAISED off the bottom edge by
	            Config.UI.TouchReserve.Bottom — see buildActions.

	Every one of them is a UiKit.dock call naming a corner. They were four
	hand-written AnchorPoint/UDim2 pairs, in this file and in SessionUI, and the
	left column's two panels were positioned by two files reading the same Config
	keys separately.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Net = Req("Net")
local UiKit = Req("UiKit")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
-- The invite prompt is a CLIENT call. There is no server-side equivalent, which
-- is why the server half of this feature is only a cooldown.
local SocialService = game:GetService("SocialService")

local player = Players.LocalPlayer

local HUD = {}

local UI = Config.UI
-- Spelled from `Config` rather than from `UI` so verify.py's config-path pass
-- resolves it: it treats `local X = Config.a.b` as an alias and checks every
-- `X.key` against Config, and a `local CARD = UI.StatusCard` would be a name it
-- has no way to follow. Every number on the status card is read through here.
local CARD = Config.UI.StatusCard
local RAIL = Config.UI.Rail
local TOAST = Config.UI.Toast
local REBIRTH = Config.UI.Modal.Rebirth
local PALETTE = UiKit.PALETTE

local KIND_COLOR = {
	buy      = PALETTE.good,
	warn     = PALETTE.bad,
	wave     = PALETTE.wave,
	boss     = PALETTE.boss,
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
	friends = 0,
	friendCap = Config.Social.MaxFriends,
	friendBonus = Config.Social.BonusPerFriend,
	-- Until CanSendGameInviteAsync has answered, the button does not exist. It
	-- is never shown optimistically: account policy can refuse invites outright
	-- and a button that errors when a child presses it is worse than no button.
	canInvite = false,
	-- #96: the unlocked surface set, pushed whole by DisclosureService. The
	-- client renders it and decides nothing.
	disclosed = {},
}

local gui, root, overlay, rootScale, overlayScale, rootPadding
local column, cashLabel, multLabel, termsLabel
local inviteButton, inviteCaption
local waveFrame, waveLabel, toastList, rebirthButton
-- the next-purchase half of the status card: name, bar fill, "N to go". The bar's
-- TRACK is not kept — it is drawn once and never written to again, and a module
-- local nothing reads is a local that outlives the reason it was added.
local nextLabel, nextFill, nextDetail
local bossTrack, bossFill
-- #96's help card, and its builder — declared here because the rail builder
-- above the definition calls it
local helpPanel
local buildHelp

-- The panel vocabulary, aliased so every call site below reads exactly as it
-- did when these were five local functions in this file. They are UiKit's now;
-- see src/client/UiKit.lua for what the merge of the three copies cost.
local corner, stroke, panel, text, button =
	UiKit.corner, UiKit.stroke, UiKit.panel, UiKit.text, UiKit.button

-- ─────────────────────────────────────────────────────────────────────────────

--- design:D-05 — ONE CARD, TWO THINGS TO READ: what you have, and what you are
--- saving for. Why it is one card, why the balance is the largest thing on it,
--- why the friend bonus is a term rather than a row, and why nothing on it is
--- pressable.
---
--- mechanism: `multLabel` prints the product; `termsLabel` prints what went
--- into it.
---
--- THE BAR IS A BAR AND A LINE OF TEXT ON PURPOSE. A bar alone cannot say what
--- you are saving for or how much is left; the text alone makes you compare two
--- abbreviated numbers to find out whether you are close. Both, driven off the
--- same lerped balance, answer it at a glance and to the Tung.
---
--- invariant: EVERY NUMBER BELOW COMES FROM Config.UI.StatusCard. Not one Y is
--- typed here — they are accumulated from the row heights in Config's
--- derivation block, so a row that grows moves the rows under it, the card's
--- ContentHeight, the session panel's Y and the column's bottom, and the
--- verifier re-runs the fit against all four.
local function buildStatusCard(parent: Instance)
	-- NO POSITION. The parent is HUD.column(), which is a UIListLayout; the only
	-- thing this card says about where it goes is that it is first.
	local frame = panel(parent,
		UDim2.fromOffset(CARD.Width, CARD.Height),
		UDim2.fromOffset(0, 0))
	frame.Name = "Status"
	frame.LayoutOrder = 1

	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromOffset(CARD.IconSize, CARD.IconSize)
	icon.Position = UDim2.fromOffset(CARD.Pad, CARD.IconY)
	icon.BackgroundColor3 = PALETTE.gold
	icon.BackgroundTransparency = 0.15
	icon.Font = Style.Font.title
	icon.Text = "T"
	icon.TextColor3 = Color3.fromRGB(40, 28, 10)
	icon.TextScaled = true
	icon.Parent = frame
	corner(icon, math.floor(CARD.IconSize / 2))

	cashLabel = text(frame, {
		Size = UDim2.fromOffset(CARD.TextWidth, CARD.BalanceHeight),
		Position = UDim2.fromOffset(CARD.TextX, CARD.BalanceY),
		Font = Style.Font.title,
		Text = "0",
		TextSize = CARD.BalanceTextPx,
		TextColor3 = PALETTE.gold,
	})

	multLabel = text(frame, {
		Size = UDim2.fromOffset(CARD.TextWidth, CARD.MultHeight),
		Position = UDim2.fromOffset(CARD.TextX, CARD.MultY),
		Font = Style.Font.body,
		Text = "x1.00",
		TextSize = CARD.MultTextPx,
		TextColor3 = PALETTE.muted,
	})

	-- THE TERMS, FULL WIDTH, where the two lines above it are indented past the
	-- coin. Everything that went into the product on the line above: the
	-- rebirths, the KOs and the friends. See renderTerms for why one function
	-- writes all three.
	termsLabel = text(frame, {
		Size = UDim2.fromOffset(CARD.ContentWidth, CARD.TermsHeight),
		Position = UDim2.fromOffset(CARD.Pad, CARD.TermsY),
		Font = Style.Font.body,
		Text = "",
		TextSize = CARD.TermsTextPx,
		TextColor3 = PALETTE.muted,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	-- A rule, not a second card. It says "two things to read" without spending a
	-- gutter, an outline and a shadow to say it.
	local divider = Instance.new("Frame")
	divider.Name = "Rule"
	divider.Size = UDim2.fromOffset(CARD.ContentWidth, CARD.DividerHeight)
	divider.Position = UDim2.fromOffset(CARD.Pad, CARD.DividerY)
	divider.BackgroundColor3 = PALETTE.accent
	divider.BackgroundTransparency = 0.75
	divider.BorderSizePixel = 0
	divider.Parent = frame

	text(frame, {
		Size = UDim2.fromOffset(CARD.ContentWidth, CARD.HeadingHeight),
		Position = UDim2.fromOffset(CARD.Pad, CARD.HeadingY),
		Font = Style.Font.body,
		Text = "NEXT UPGRADE",
		TextSize = CARD.HeadingTextPx,
		TextColor3 = PALETTE.muted,
	})

	nextLabel = text(frame, {
		Size = UDim2.fromOffset(CARD.ContentWidth, CARD.NameHeight),
		Position = UDim2.fromOffset(CARD.Pad, CARD.NameY),
		Font = Style.Font.title,
		Text = "Tung Dropper — 50",
		TextSize = CARD.NameTextPx,
		TextColor3 = PALETTE.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	-- THE FILL RIDES THE LERPED BALANCE, not the packet — see renderNext. The
	-- track is drawn once and never written to again; only the fill's width and
	-- colour change, so there is nothing here for a frame to get half-way
	-- through.
	local barTrack = Instance.new("Frame")
	barTrack.Name = "Progress"
	barTrack.Size = UDim2.fromOffset(CARD.ContentWidth, CARD.BarHeight)
	barTrack.Position = UDim2.fromOffset(CARD.Pad, CARD.BarY)
	barTrack.BackgroundColor3 = PALETTE.panel2
	barTrack.BackgroundTransparency = 0.25
	barTrack.BorderSizePixel = 0
	barTrack.Parent = frame
	corner(barTrack, math.floor(CARD.BarHeight / 2))

	nextFill = Instance.new("Frame")
	nextFill.Name = "Fill"
	nextFill.Size = UDim2.fromScale(0, 1)
	nextFill.BackgroundColor3 = PALETTE.gold
	nextFill.BorderSizePixel = 0
	nextFill.Parent = barTrack
	corner(nextFill, math.floor(CARD.BarHeight / 2))

	-- The gap to the next purchase, and how far through the build you are. The
	-- bar says how close; this says what "close" is worth and which rung of which
	-- track you are on. A price on its own does not tell you whether to keep
	-- grinding or go and fight a wave for the bounty.
	nextDetail = text(frame, {
		Size = UDim2.fromOffset(CARD.ContentWidth, CARD.DetailHeight),
		Position = UDim2.fromOffset(CARD.Pad, CARD.DetailY),
		Font = Style.Font.body,
		Text = "",
		TextSize = CARD.DetailTextPx,
		TextColor3 = PALETTE.muted,
	})

	return frame
end

--- The raid banner is a SIGN IN THE WORLD, not a bar across your screen.
---
--- It hangs over the Tung statue in the middle of the arena, which is where
--- the raid is and which is visible from every plot. One line, big, no box —
--- readable at a glance and ignorable the rest of the time, which a panel
--- pinned to the top of the screen never manages.
---
--- CLIENT-OWNED ON PURPOSE. The billboard is created here, on the client,
--- parented to an anchor the server stood up. That is what lets the countdown
--- keep ticking locally off a `seconds` the server sends once per phase,
--- instead of costing a remote every second — which was one of the three
--- properties of the old banner worth carrying over, and the cheapest to lose
--- by accident if the server had drawn this.
local function buildWaveBanner()
	local world = workspace:FindFirstChild("TungWorld")
	local arena = world and world:WaitForChild("Arena", 10)
	local anchor = arena and arena:WaitForChild("RaidAnchor", 10)
	if not anchor then
		-- No banner rather than a broken one. Every read of waveFrame is
		-- already nil-guarded because the HUD used to build it lazily.
		warn("[Tung] no RaidAnchor in the arena; the raid banner has nowhere to hang")
		return
	end

	waveFrame = Style.billboard(anchor, {
		name = "RaidSign",
		width = 60, height = Config.Style.RaidSignHeight,
		distance = "world",
	})
	waveFrame.Enabled = false

	-- THE SIGN IS SPLIT THE WAY THE ARENA TITLE ALREADY IS: a line, and a strip
	-- under it. The strip is the boss's health, and it is here rather than in a
	-- bar across the top of your screen for the reason written on
	-- Config.Style.RaidSignY — the raid is a place, and this is where it is.
	--
	-- The fractions are DERIVED from the two heights rather than typed, so the
	-- bar cannot drift out of the sign the arena title is asserted against.
	local signHeight = Config.Style.RaidSignHeight
	local barFraction = Config.Style.BossBarHeight / signHeight
	local inset = Config.Style.BossBarInset

	waveLabel = Style.text(waveFrame, {
		name = "Line",
		size = UDim2.fromScale(1, 1 - barFraction),
		text = "", color = PALETTE.wave,
	})

	bossTrack = Instance.new("Frame")
	bossTrack.Name = "BossBar"
	bossTrack.Size = UDim2.fromScale(1 - inset * 2, barFraction * 0.7)
	bossTrack.Position = UDim2.fromScale(inset, 1 - barFraction)
	bossTrack.BackgroundColor3 = PALETTE.panel
	bossTrack.BackgroundTransparency = 0.35
	bossTrack.BorderSizePixel = 0
	-- Only ever up during a boss fight. Every other wave, the sign is the one
	-- line it has always been.
	bossTrack.Visible = false
	bossTrack.Parent = waveFrame
	corner(bossTrack, 3)

	bossFill = Instance.new("Frame")
	bossFill.Name = "Fill"
	bossFill.Size = UDim2.fromScale(1, 1)
	bossFill.BackgroundColor3 = PALETTE.boss
	bossFill.BorderSizePixel = 0
	bossFill.Parent = bossTrack
	corner(bossFill, 3)
end

--- THE LEFT COLUMN, as one region rather than as two panels that agree.
---
--- The status card and the session panel are one width stacked from the top
--- margin down, and they used to say so twice: this file positioned the first
--- from Config.UI.StatusCard.Y and SessionUI positioned the second from
--- Config.UI.SessionPanel.Y. Two files reading two derived numbers is the exact
--- shape of the bug Config.UI's column comment says that table exists to catch —
--- it was one edit away at all times. Neither file is told a Y now.
---
--- HEIGHT IS THE COLUMN'S BUDGET, NOT ITS CONTENT. The frame is sized to
--- ColumnBottom so a panel laid out past it is visibly past it; the layout does
--- not clip, and the verifier holds ColumnBottom to the reference height.
local function buildColumn(parent: Instance)
	column = UiKit.dock(parent, {
		name = "Column",
		corner = "topLeft",
		width = UI.ColumnWidth,
		height = UI.ColumnBottom - UI.Margin,
		direction = "Vertical",
	})
end

--- THE TOP-RIGHT RAIL. One item today, and the reason it is a region rather than
--- a button is that the toast column below it is derived from its height: a
--- second item makes the rail wider, not taller, and nothing under it moves.
local function buildUtilityRail(parent: Instance)
	local rail = UiKit.dock(parent, {
		name = "Rail",
		corner = "topRight",
		width = RAIL.ItemWidth,
		height = RAIL.ItemHeight,
		direction = "Horizontal",
	})

	local slot
	inviteButton, slot, inviteCaption = UiKit.railItem(rail, "Invite", PALETTE.good)
	buildHelp(rail)
	UiKit.personPlus(slot, RAIL.GlyphSize, UiKit.INK, PALETTE.good)
	-- Not shown optimistically: until CanSendGameInviteAsync has answered, this
	-- control does not exist. See refreshInvite.
	inviteButton.Visible = false
	inviteButton.Activated:Connect(HUD.promptInvite)
end

local function buildToasts(parent: Instance)
	toastList = UiKit.dock(parent, {
		name = "Toasts",
		corner = "topRight",
		width = UI.Toast.Width,
		height = UI.Toast.ListHeight,
		-- Derived to clear the rail above it. The two shared a corner before the
		-- rail existed and the first toast of the session would have landed on
		-- top of the invite.
		insetY = UI.Toast.Y,
		direction = "Vertical",
	})
end

--- REBIRTH over LEAVE PLOT, on the right edge and RAISED OFF THE BOTTOM.
---
--- It was anchored (1,1) at (1,-Margin),(1,-Margin) — 200x112 in the corner the
--- engine draws the touch jump button in, with the movement thumbstick in the
--- corner opposite. Four out of five sessions are phones, so for four out of
--- five players REBIRTH and JUMP were the same pixels. There is no API that
--- returns either control's rectangle, so the clearance is a declared number:
--- Config.UI.TouchReserve.Bottom, which is what insetY is measured from.
local function buildActions(parent: Instance)
	local holder = UiKit.dock(parent, {
		name = "Actions",
		corner = "bottomRight",
		width = UI.Action.Width,
		height = UI.Action.Height,
		insetY = UI.Action.BottomGap,
		direction = "Vertical",
	})

	rebirthButton = button(holder, "REBIRTH", PALETTE.accent, {
		Size = UDim2.fromOffset(UI.Action.Width, UI.Button.primary),
		LayoutOrder = 1,
	})
	-- No TextSize: UiKit.button is TextScaled, which overrides one. There was a
	-- `TextSize = 16` here doing nothing, which is worse than no number at all —
	-- it reads as the size this label is drawn at and it never was.
	local leave = button(holder, "LEAVE PLOT", Color3.fromRGB(120, 110, 140), {
		Size = UDim2.fromOffset(UI.Action.Width, UI.Button.secondary),
		LayoutOrder = 2,
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

--- Destroy the oldest cards until the column holds no more than it is sized for.
---
--- WITHOUT THIS, UI.Toast.ListHeight IS DECORATION. A UIListLayout does not clip
--- and does not stop: a burst of six toasts drew two of them out of the bottom of
--- a frame that claimed to be five cards tall, and no assertion could be built on
--- a height the runtime treated as advisory. The column has a real ceiling now,
--- so the clearance against the action stack below it means something.
---
--- Oldest first, by LayoutOrder, because that is the order the layout draws them
--- in and the one at the top is the one that has been readable the longest.
local function trimToasts()
	local cards = toastList:GetChildren()
	local live = {}
	for _, child in ipairs(cards) do
		if child:IsA("Frame") then
			table.insert(live, child)
		end
	end
	if #live <= TOAST.MaxCards then
		return
	end
	table.sort(live, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for index = 1, #live - TOAST.MaxCards do
		live[index]:Destroy()
	end
end

function HUD.toast(payload)
	if not toastList then
		return
	end
	toastOrder += 1

	local color = KIND_COLOR[payload.kind] or PALETTE.accent

	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(TOAST.Width, TOAST.CardHeight)
	card.BackgroundColor3 = PALETTE.panel
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.LayoutOrder = toastOrder
	card.Parent = toastList
	corner(card, 12)
	stroke(card, color, 2)
	trimToasts()

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(TOAST.BarWidth, TOAST.BarHeight)
	bar.Position = UDim2.fromOffset(TOAST.BarInset, TOAST.Pad)
	bar.BackgroundColor3 = color
	bar.BorderSizePixel = 0
	bar.Parent = card
	corner(bar, math.floor(TOAST.BarWidth / 2))

	text(card, {
		Size = UDim2.fromOffset(TOAST.TextWidth, TOAST.TitleHeight),
		Position = UDim2.fromOffset(TOAST.TextX, TOAST.TitleY),
		Font = Style.Font.title,
		Text = payload.title or "",
		TextSize = TOAST.TitleTextPx,
		TextColor3 = color,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	text(card, {
		Size = UDim2.fromOffset(TOAST.TextWidth, TOAST.BodyHeight),
		Position = UDim2.fromOffset(TOAST.TextX, TOAST.BodyY),
		Font = Style.Font.body,
		Text = payload.body or "",
		TextSize = TOAST.BodyTextPx,
		TextColor3 = PALETTE.muted,
		TextWrapped = true,
	})

	-- starts one card-width plus a hair off the right edge, and slides in
	card.Position = UDim2.fromOffset(TOAST.Width + UI.Gap, 0)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- the friend bonus
-- ─────────────────────────────────────────────────────────────────────────────

--- What the friend bonus is worth right now, as a percentage.
local function friendPercent(friends: number): number
	return math.floor(math.min(friends, state.friendCap) * state.friendBonus * 100)
end

--- Visible only when there is room under the cap and the account is allowed to
--- send invites at all. Nobody is asked to invite a fourth friend who would be
--- worth nothing.
---
--- THE CAPTION IS THE OLD FRIEND ROW'S ZERO STATE, moved onto the control it was
--- always about. With nobody here it reads what ONE friend would be worth, which
--- is the offer; with somebody here it reads what you are already getting, in the
--- good colour, which is the receipt. An icon with no number is a button a child
--- presses to find out what it does.
--- #96: whether a surface has been earned. Every gated panel asks this at
--- render, and applyDisclosure re-renders them all when the set grows.
function HUD.disclosed(id: string): boolean
	return state.disclosed[id] == true
end

-- Panels outside this file (SessionUI, PartyUI) register here; the set only
-- ever grows, so a re-render on push is the whole protocol.
local disclosureListeners: { () -> () } = {}

function HUD.onDisclosure(fn: () -> ())
	table.insert(disclosureListeners, fn)
end

--- #96's help surface: a "?" on the rail, and a card on the overlay that
--- lists ONLY what this player has unlocked — it grows with them, so it can
--- never become a manual. Rebuilt from Config.Disclosure on every open.
local function renderHelp()
	if not helpPanel then
		return
	end
	for _, child in ipairs(helpPanel:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("Frame") then
			child:Destroy()
		end
	end
	local y = 12
	UiKit.text(helpPanel, {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.head,
		Text = "WHAT YOU HAVE SO FAR",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = PALETTE.gold,
	})
	y += 30
	for _, row in ipairs(Config.Disclosure) do
		if HUD.disclosed(row.id) then
			UiKit.text(helpPanel, {
				Size = UDim2.new(1, -24, 0, 16),
				Position = UDim2.fromOffset(12, y),
				Font = Style.Font.body,
				Text = row.name,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = PALETTE.accent,
			})
			y += 17
			local body = UiKit.text(helpPanel, {
				Size = UDim2.new(1, -36, 0, 28),
				Position = UDim2.fromOffset(24, y),
				Font = Style.Font.body,
				Text = row.help,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = PALETTE.muted,
			})
			body.TextWrapped = true
			y += 34
		end
	end
	helpPanel.Size = UDim2.fromOffset(320, y + 8)
end

function buildHelp(rail)
	local button = UiKit.railItem(rail, "Help", PALETTE.accent)
	button.Text = "?"
	helpPanel = UiKit.panel(overlay, UDim2.fromOffset(320, 60), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	helpPanel.Name = "Help"
	helpPanel.Visible = false
	button.Activated:Connect(function()
		helpPanel.Visible = not helpPanel.Visible
		if helpPanel.Visible then
			renderHelp()
		end
	end)
	local close = UiKit.button(helpPanel, "CLOSE", PALETTE.bad, {
		Size = UDim2.fromOffset(64, 22),
		Position = UDim2.new(1, -72, 0, 8),
	})
	close.Activated:Connect(function()
		helpPanel.Visible = false
	end)
end

local function refreshInvite()
	if not inviteButton then
		return
	end
	inviteButton.Visible = state.canInvite and state.friends < state.friendCap
		and HUD.disclosed("social")
	if state.friends > 0 then
		inviteCaption.Text = ("+%d%%"):format(friendPercent(state.friends))
		inviteCaption.TextColor3 = UiKit.INK
	else
		-- One friend's worth, not zero: zero is what you have, and what you have
		-- is not what a button is offering you.
		inviteCaption.Text = ("+%d%%"):format(friendPercent(1))
		inviteCaption.TextColor3 = UiKit.INK
	end
end

--- THE TERMS LINE HAS ONE WRITER, and that is the whole reason it exists as a
--- function. It prints three things that arrive on two different remotes — the
--- rebirths and the KOs on Stats, the friends on SocialState — and the obvious
--- implementation is for each handler to rewrite the label with what it knows.
--- That is a line that is correct until the two packets disagree about which
--- arrived last, at which point it silently drops whichever term the loser owned.
--- Both handlers write `state` and call this.
local function renderTerms()
	if not termsLabel then
		return
	end
	-- #96: the multiplier vocabulary waits until there is more than one term
	-- to speak of
	if not HUD.disclosed("terms") then
		termsLabel.Text = ""
		return
	end
	local parts = {
		("%d rebirth%s"):format(state.rebirths, state.rebirths == 1 and "" or "s"),
		("%d KO%s"):format(state.kills, state.kills == 1 and "" or "s"),
	}
	if state.friends > 0 then
		table.insert(parts, ("+%d%% friends"):format(friendPercent(state.friends)))
	end
	termsLabel.Text = table.concat(parts, "  •  ")
	termsLabel.TextColor3 = state.friends > 0 and PALETTE.good or PALETTE.muted
end

function HUD.applyDisclosure(payload)
	state.disclosed = {}
	for _, id in ipairs(payload.ids or {}) do
		state.disclosed[id] = true
	end
	renderTerms()
	refreshInvite()
	for _, fn in ipairs(disclosureListeners) do
		fn()
	end
end

--- BOTH SocialService calls YIELD, so neither may run on the signal thread —
--- an Activated handler that yields blocks the button until it returns.
---
--- `CanSendGameInviteAsync` can ERROR as well as return false: under some
--- account policy restrictions it throws rather than answering. Both paths do
--- the same thing, which is to HIDE the button. This game's audience is largely
--- children and the failure they must never see is an error message where a
--- button used to be.
function HUD.promptInvite()
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if not ok or not can then
			state.canInvite = false
			refreshInvite()
			return
		end
		pcall(function()
			SocialService:PromptGameInvite(player)
		end)
		-- Fire-and-forget. The server does not act on this; it rate-limits it,
		-- and it is where an invite analytics event will hang.
		Net.event("RequestInvite"):FireServer()
	end)
end

function HUD.applySocial(payload)
	state.friends = payload.friends or 0
	state.friendCap = payload.cap or state.friendCap
	state.friendBonus = payload.bonus or state.friendBonus

	renderTerms()
	refreshInvite()
end

function HUD.showRebirthModal(cost: number)
	if not overlay or overlay:FindFirstChild("RebirthModal") then
		return
	end

	-- On the OVERLAY layer, not the root one: the shade is supposed to dim the
	-- notch and the home indicator along with everything else, and the root
	-- layer is padded clear of both.
	local shade = Instance.new("Frame")
	shade.Name = "RebirthModal"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = 20
	shade.Parent = overlay

	local card = panel(shade,
		UDim2.fromOffset(REBIRTH.Width, REBIRTH.Height),
		UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	card.ZIndex = 21
	for _, child in ipairs(card:GetDescendants()) do
		if child:IsA("GuiObject") then
			child.ZIndex = 21
		end
	end

	text(card, {
		Size = UDim2.fromOffset(REBIRTH.ContentWidth, REBIRTH.TitleHeight),
		Position = UDim2.fromOffset(REBIRTH.Pad, REBIRTH.TitleY),
		Font = Style.Font.title,
		Text = "SAHUR REBIRTH",
		TextSize = REBIRTH.TitleTextPx,
		TextColor3 = PALETTE.accent,
		ZIndex = 22,
	})

	local affordable = state.cash >= cost
	text(card, {
		Size = UDim2.fromOffset(REBIRTH.ContentWidth, REBIRTH.BodyHeight),
		Position = UDim2.fromOffset(REBIRTH.Pad, REBIRTH.BodyY),
		Font = Style.Font.body,
		Text = ("Cost: <b>%s Tung</b>\n\nYour factory and cash are wiped, but every payout after this is permanently multiplied.\n\nNext multiplier: <b>x%.2f</b>")
			:format(Util.abbreviate(cost), Config.Rebirth.MultiplierPerRebirth ^ (state.rebirths + 1)),
		TextSize = REBIRTH.BodyTextPx,
		TextColor3 = affordable and PALETTE.text or PALETTE.muted,
		TextWrapped = true,
		ZIndex = 22,
	})

	local confirm = button(card, affordable and "DO IT" or "NOT ENOUGH TUNG",
		affordable and PALETTE.accent or PALETTE.dead, {
			Size = UDim2.fromOffset(REBIRTH.ButtonWidth, UI.Button.primary),
			Position = UDim2.fromOffset(REBIRTH.Pad, REBIRTH.ButtonY),
			ZIndex = 22,
			TextSize = REBIRTH.ButtonTextPx,
		})
	local cancel = button(card, "CANCEL", Color3.fromRGB(120, 110, 140), {
		Size = UDim2.fromOffset(REBIRTH.ButtonWidth, UI.Button.primary),
		Position = UDim2.fromOffset(REBIRTH.CancelX, REBIRTH.ButtonY),
		ZIndex = 22,
		TextSize = REBIRTH.ButtonTextPx,
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

-- The ranking Tycoon:pointAt uses. It HAS to be the same, or the card names one
-- purchase — and now fills a bar towards its price — while the beacon out on the
-- plot glows on a different one. A bar makes that disagreement worse, not better:
-- it is a promise about which price you are counting towards. And keeping two
-- hand-maintained copies of a ranking identical is not a plan, it is a hope. So
-- there is one: Config.TrackRank, derived from TrackOrder. Factory first, then
-- cheapest within the track, because a cabinet's first rung is cheap and
-- cheapest-overall would point at a bat for most of the early game.
local function cheapestAvailable()
	local best, bestRank
	for _, def in ipairs(Config.Buttons) do
		-- The gate has to be applied here too, and for the same reason the
		-- ranking does: a track that has not opened yet has no cabinet and no
		-- buttons anywhere on the plot, so naming one of its rungs as your next
		-- purchase points you at nothing.
		if not state.owned[def.id]
			and Config.trackUnlocked(def.track, state.owned)
		then
			local ok = true
			for _, req in ipairs(Config.requirementsOf(def)) do
				if not state.owned[req] then
					ok = false
					break
				end
			end
			local rank = Config.TrackRank[def.track] or 99
			if ok and (not best or rank < bestRank or (rank == bestRank and def.price < best.price)) then
				best, bestRank = def, rank
			end
		end
	end
	return best
end

local displayedCash = 0
-- Lerped towards wave.bossHp by the same connection, for the same reason.
local displayedBossHp = 0

--- What the last Stats packet said the next purchase is: the def cheapestAvailable
--- picked, plus the step count within its own track. `nil` once everything is
--- built, and `nil` before the first packet arrives — which is why `hasStats`
--- exists rather than being inferred from this being nil, because "nothing left to
--- buy" and "nobody has told us anything yet" draw completely different cards.
local nextUp: { name: string, price: number, label: string, step: number, of: number }? = nil
local hasStats = false

--- Redrawn every frame from the SAME RenderStepped connection as the balance, and
--- off the SAME `displayedCash`.
---
--- That is the point of it being here rather than in applyStats. The balance
--- counts up over about a fifth of a second after every drop; a bar and a "N to
--- go" computed from `state.cash` would already be at the destination while the
--- number above them was still climbing, so the card would contradict itself on
--- every purchase — and the one moment it is being read most closely is the moment
--- the money lands. One value drives the number, the fill and the remainder, so
--- there is nothing for them to disagree about.
local function renderNext()
	if not nextLabel or not hasStats then
		return
	end
	if not nextUp then
		nextLabel.Text = "Everything built. Rebirth?"
		nextLabel.TextColor3 = PALETTE.accent
		-- A full bar, in the rebirth colour: there is no next rung, and an empty
		-- track under "everything built" reads as no progress at all.
		nextFill.Size = UDim2.fromScale(1, 1)
		nextFill.BackgroundColor3 = PALETTE.accent
		nextDetail.Text = ("all %d steps built"):format(#Config.Buttons)
		nextDetail.TextColor3 = PALETTE.muted
		return
	end

	-- Guarded rather than trusted: a price of zero would make this inf, and
	-- UDim2.fromScale of a nan is a bar of undefined width rather than an error.
	local fraction = nextUp.price > 0
		and math.clamp(displayedCash / nextUp.price, 0, 1)
		or 1
	local affordable = fraction >= 1

	nextFill.Size = UDim2.fromScale(fraction, 1)
	nextFill.BackgroundColor3 = affordable and PALETTE.good or PALETTE.gold
	nextLabel.Text = ("%s — %s"):format(nextUp.name, Util.abbreviate(nextUp.price))
	nextLabel.TextColor3 = affordable and PALETTE.good or PALETTE.text
	nextDetail.Text = affordable
		and ("%s %d/%d  •  affordable now"):format(nextUp.label, nextUp.step, nextUp.of)
		or ("%s %d/%d  •  %s to go"):format(nextUp.label, nextUp.step, nextUp.of,
			Util.abbreviate(nextUp.price - displayedCash))
	nextDetail.TextColor3 = affordable and PALETTE.good or PALETTE.muted
end

function HUD.applyStats(payload)
	state.cash = payload.cash or 0
	state.rebirths = payload.rebirths or 0
	state.kills = payload.kills or 0
	state.multiplier = payload.multiplier or 1
	state.owned = payload.owned or {}
	state.rebirthCost = payload.rebirthCost or state.rebirthCost
	hasStats = true

	-- The product on one line, and what went into it on the next.
	multLabel.Text = ("x%.2f"):format(state.multiplier)
	renderTerms()

	local next_ = cheapestAvailable()
	if next_ then
		-- Count within the button's OWN track. "step 7 of 30" spanning the
		-- factory, the weapons cabinet and the armoury is three progress bars
		-- averaged into one meaningless number.
		local track = Config.Tracks[next_.track]
		local owned = 0
		-- Counted by CATEGORY (#125): the card says "PLOT 12 of 34", the
		-- same width the pad's own step line uses.
		for _, def in ipairs(Config.Buttons) do
			if def.category == next_.category and state.owned[def.id] then
				owned += 1
			end
		end
		nextUp = {
			name = next_.name,
			price = next_.price,
			label = Config.TrackLabel[next_.track] or "STEP",
			step = owned + 1,
			of = Config.CategoryCount[next_.category] or #track,
		}
	else
		nextUp = nil
	end
	-- Drawn once here as well as every frame, so a card that arrives on a paused
	-- or throttled RenderStepped is not blank while it waits for one.
	renderNext()

	rebirthButton.Text = ("REBIRTH  %s"):format(Util.abbreviate(state.rebirthCost))
	rebirthButton.BackgroundColor3 = state.cash >= state.rebirthCost and PALETTE.accent or PALETTE.dead
end

--- The last wave packet, plus the wall-clock deadline derived from its
--- `seconds`. The server sends `seconds` ONCE per phase and the client counts
--- it down locally, so a ticking banner costs no extra remote traffic.
--- Typed `any` because it IS the packet: NPCService sends a different shape per
--- phase (a boss fight carries three fields an idle one does not), and inferring
--- a struct from the idle placeholder makes every optional field a type error.
local wave: any = { phase = "idle", deadline = 0 }

function HUD.applyWave(payload)
	if not waveFrame then
		return
	end
	-- The bar is lerped towards the packet (see the RenderStepped loop), which
	-- is what turns 2 Hz updates into something worth watching. The FIRST packet
	-- of a fight has to snap, though, or every boss opens with its bar sweeping
	-- up from empty and reading 0% while it does.
	if payload.bossMaxHp and not wave.bossMaxHp then
		displayedBossHp = payload.bossHp or payload.bossMaxHp
	end
	wave = payload
	wave.deadline = os.clock() + (payload.seconds or 0)
	HUD.renderWave()
end

--- Redrawn every frame from the RenderStepped connection that already exists
--- for the cash counter — no second connection, and no `task.delay`.
---
--- The old `clear` branch hid the banner with an unguarded task.delay(4), so a
--- wave that started inside that window had its fresh banner blanked by a
--- stale timer. Visibility is now derived from state that any newer packet
--- overwrites, which makes that failure unreachable rather than guarded.
function HUD.renderWave()
	if not waveFrame then
		return
	end
	local phase = wave.phase
	local left = math.max(0, math.ceil(wave.deadline - os.clock()))
	local boss = wave.boss == true
	-- Off by default and turned on in exactly one branch, so a bar left up by a
	-- phase nobody thought about is unreachable rather than guarded against.
	bossTrack.Visible = false

	-- `Enabled` rather than `Visible`, and no background writes: the banner is a
	-- billboard hanging over the statue now, and the box is gone. Colour is the
	-- only thing left carrying tone, which is what "one line, big, nothing
	-- fancy" costs and buys.
	if phase == "idle" or phase == nil then
		waveFrame.Enabled = false
		return
	end

	if phase == "resting" then
		-- Broadcast rather than left blank: eighteen seconds of dead air with
		-- nothing on screen is most of why the old gap felt long.
		waveFrame.Enabled = left > 0
		waveLabel.Text = ("NEXT RAID IN %ds"):format(left)
		waveLabel.TextColor3 = PALETTE.muted
	elseif phase == "warning" then
		waveFrame.Enabled = true
		waveLabel.Text = boss
			and ("BOSS RAID %d IN %ds"):format(wave.wave, left)
			or ("SAHUR RAID %d IN %ds"):format(wave.wave, left)
		waveLabel.TextColor3 = boss and PALETTE.boss or PALETTE.wave
	elseif phase == "spawning" or phase == "active" then
		waveFrame.Enabled = true
		local maxHp = wave.bossMaxHp
		if maxHp and maxHp > 0 then
			-- THE SHARED OBJECTIVE TAKES THE SIGN. While the boss is up, the
			-- raider counter is the less interesting of the two numbers: what
			-- everyone in the arena is coordinating around is one health bar,
			-- and how many people it was built for.
			local fraction = math.clamp(displayedBossHp / maxHp, 0, 1)
			bossTrack.Visible = true
			bossFill.Size = UDim2.fromScale(fraction, 1)
			waveLabel.Text = ("WAVE %d BOSS  •  %d%%  •  scaled for %d"):format(
				wave.wave, math.floor(fraction * 100 + 0.5), wave.bossScale or 1)
			waveLabel.TextColor3 = PALETTE.boss
		else
			waveLabel.Text = ("WAVE %d  •  %d / %d RAIDERS"):format(
				wave.wave, wave.remaining or 0, wave.total or 0)
			waveLabel.TextColor3 = boss and PALETTE.boss or PALETTE.wave
		end
	elseif phase == "clear" then
		waveFrame.Enabled = left > 0
		waveLabel.Text = wave.forced
			and ("WAVE %d TIMED OUT"):format(wave.wave)
			or ("WAVE %d CLEARED"):format(wave.wave)
		waveLabel.TextColor3 = wave.forced and PALETTE.muted or PALETTE.good
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the two layers, and fitting them to the screen
-- ─────────────────────────────────────────────────────────────────────────────

--- A full-bleed transparent frame with its own UIScale.
---
--- The scale is not set here. It is set by applyViewport() below, which also
--- sets the layer's SIZE to 1/scale — see there for why that pair is what makes
--- a fromScale(1, 1) child still cover the whole screen.
local function buildLayer(name: string): (Frame, UIScale)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = frame
	return frame, scale
end

--- Recomputed on every viewport change, which is one connection covering
--- rotation, window resize and Studio's device emulator at once.
---
--- THE 1/SCALE SIZE IS THE POINT, and it is worth being precise about. A
--- UIScale multiplies the whole subtree uniformly, offsets and scale-derived
--- sizes alike — so a shade at fromScale(1, 1) inside a layer scaled to 0.62
--- would dim 62% of the screen and leave a bright border, which is a bug you
--- only ever see on the device you don't own. Sizing the layer itself at
--- 1/scale cancels exactly that one factor: scale-based children come back out
--- at full screen, while offset-based children (every panel in this file) stay
--- multiplied by scale, which is the whole objective. It also makes the layer's
--- own coordinate space the DESIGN space — at least ReferenceWidth x
--- ReferenceHeight of it, by construction of UiKit.scaleFor.
local function applyViewport()
	local camera = workspace.CurrentCamera
	if not camera or not root then
		return
	end
	local viewport = camera.ViewportSize
	local scale = UiKit.scaleFor(viewport)

	rootScale.Scale = scale
	overlayScale.Scale = scale
	root.Size = UDim2.fromScale(1 / scale, 1 / scale)
	overlay.Size = UDim2.fromScale(1 / scale, 1 / scale)

	-- The insets come back in PHYSICAL pixels and the padding is applied inside
	-- the scaled layer, so it has to be divided back out. If the engine turns
	-- out not to scale UIPadding the way it scales everything else, this errs
	-- generous (1/0.62 is a wider gutter, never a narrower one), which is the
	-- direction a guess about a notch should be wrong in.
	local insets = UiKit.safeInsets()
	rootPadding.PaddingLeft = UDim.new(0, math.round(insets.left / scale))
	rootPadding.PaddingRight = UDim.new(0, math.round(insets.right / scale))
	rootPadding.PaddingBottom = UDim.new(0, math.round(insets.bottom / scale))
	-- Top only gets the pad. IgnoreGuiInset = false already pushed this whole
	-- ScreenGui below the topbar; adding the top inset here would do it twice.
	rootPadding.PaddingTop = UDim.new(0, math.round(insets.top / scale))
end

function HUD.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "TungHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Nothing set this before, so the portrait case never arising was an
	-- accident rather than a decision. This game is a landscape game: the HUD
	-- is a left column, a right column and an arena in the middle.
	pcall(function()
		gui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
	-- The explicit spelling of IgnoreGuiInset = false on clients new enough to
	-- have the enum. Guarded because it is newer surface than the property it
	-- restates, and restating it is worth nothing if it errors.
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	gui.Parent = player:WaitForChild("PlayerGui")

	root, rootScale = buildLayer("Root")
	rootPadding = Instance.new("UIPadding")
	rootPadding.Parent = root
	overlay, overlayScale = buildLayer("Overlay")

	-- One connection, rebound if the camera itself is replaced. Rotation,
	-- resize and device emulation all arrive through it.
	local viewportConnection
	local function watchCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyViewport)
		applyViewport()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	-- The four docked regions, then the one thing that is not on the screen at
	-- all. Column first: buildStatusCard parents into it.
	buildColumn(root)
	buildStatusCard(column)
	buildUtilityRail(root)
	buildToasts(root)
	buildActions(root)
	-- no layer: this one hangs in the world, not on the screen
	buildWaveBanner()

	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if payload.kind == "rebirthPrompt" then
			HUD.showRebirthModal(payload.cost or state.rebirthCost)
		else
			HUD.toast(payload)
		end
	end)

	Net.event("Stats").OnClientEvent:Connect(HUD.applyStats)
	Net.event("WaveState").OnClientEvent:Connect(HUD.applyWave)
	Net.event("SocialState").OnClientEvent:Connect(HUD.applySocial)
	Net.event("Disclosure").OnClientEvent:Connect(HUD.applyDisclosure)

	-- Ask ONCE, off the main thread, whether this account may send invites at
	-- all. The answer decides whether the button ever appears; it is not asked
	-- again on every press, because the press path re-checks it anyway and a
	-- yielding call per click is a double-fire waiting to happen.
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		state.canInvite = ok and can == true
		refreshInvite()
	end)

	-- smooth counting cash so big numbers feel good, and tick the raid
	-- countdown off the same connection
	RunService.RenderStepped:Connect(function(dt)
		if math.abs(displayedCash - state.cash) < 0.5 then
			displayedCash = state.cash
		else
			displayedCash += (state.cash - displayedCash) * math.min(dt * 9, 1)
		end
		cashLabel.Text = Util.abbreviate(displayedCash)
		-- ...and so does the progress bar, off the same value the label just
		-- printed. See renderNext for why they cannot be allowed to diverge.
		renderNext()

		-- The boss bar rides the SAME connection and the same easing. The server
		-- coalesces raid packets at 2 Hz, so a bar driven straight off them
		-- would step four times a second under twelve people's swings; lerped,
		-- the same four packets read as a bar going down.
		local targetHp = wave.bossHp or 0
		if math.abs(displayedBossHp - targetHp) < 0.5 then
			displayedBossHp = targetHp
		else
			displayedBossHp += (targetHp - displayedBossHp) * math.min(dt * 9, 1)
		end

		HUD.renderWave()
	end)

	return gui
end

-- THERE IS DELIBERATELY NO HUD.screenGui().
--
-- There was, and CombatClient used it to parent the hitmarker straight to the
-- ScreenGui — outside the UIScale and outside the safe-area padding. The
-- one-ScreenGui lint could not see it, because nothing had to make a second
-- ScreenGui to escape the first one's layers: an accessor handed the way out.
-- Panels get root() or overlay(); the gui itself is this file's business.

--- The layer persistent furniture belongs on: scaled, and padded clear of the
--- notch and the home indicator.
function HUD.root(): Frame
	return root
end

--- The layer modals belong on: the same scale, no padding. A shade parented
--- here dims the safe area too, which is what a shade is for.
function HUD.overlay(): Frame
	return overlay
end

--- The top-left column, for a panel that belongs in the stack under the status
--- card. Set a LayoutOrder; do not set a Position.
---
--- THIS IS NOT THE ESCAPE HATCH HUD.screenGui() WAS. That accessor handed out
--- the raw ScreenGui, which is outside the UIScale AND outside the safe-area
--- padding, and the one-ScreenGui lint could not see anything wrong because
--- nothing had to make a second one. This is a child of Root: strictly inside
--- both, and strictly narrower than root() — a panel that takes it gets the
--- column's width and the column's stacking, which is the whole point.
function HUD.column(): Frame
	return column
end

return HUD
