--[[
	UiKit.lua — the vocabulary every on-screen panel is built out of, plus the
	two measurements that decide whether it survives a phone.

	CLIENT, NOT SHARED, DELIBERATELY. Req searches TungShared then TungClient, so
	`Req("UiKit")` resolves from the client root exactly as `Req("HUD")` already
	does in SessionUI. In src/shared it would be compiled into the SERVER paste
	build too — tools/pack.py builds that from [src/shared, src/server] — which
	hands the server a vocabulary for screen UI it must never draw.

	WHY IT EXISTS. corner / stroke / panel / text / button and the palette were
	written out three times: HUD.lua, SessionUI.lua and UpgradeUI.lua. Two of
	those files carried a header apologising for the copy and naming this module
	as the fix. Three copies of a palette is three chances for the game to be two
	different purples, and the one that drifts first is always the one nobody
	opens.

	ONE DIVERGENCE SURVIVED THE MERGE, and it is the only interesting thing in
	this file. HUD and UpgradeUI build TextScaled buttons with no TextSize;
	SessionUI's are sized text (TextScaled = false, TextSize = 15). `button` here
	is the TextScaled one, and SessionUI keeps a small shim that pre-seeds the
	other two properties before forwarding. Rewriting that panel's call sites to
	remove a shim is how a refactor turns into a redesign.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")

local GuiService = game:GetService("GuiService")

local UI = Config.UI

local UiKit = {}

--- THE PALETTE, once. This is the union of the three copies it replaces: `wave`
--- and `boss` came from HUD (promoted out of a toast-only table, because the
--- raid banner had inline literals of the same two colours and the raid read as
--- two different oranges depending on which widget you looked at), and `dead`
--- came from SessionUI and UpgradeUI, where it greys out a claimed or
--- unaffordable control.
UiKit.PALETTE = {
	panel   = Color3.fromRGB(22, 18, 32),
	panel2  = Color3.fromRGB(32, 26, 46),
	accent  = Color3.fromRGB(190, 130, 255),
	gold    = Color3.fromRGB(255, 205, 90),
	good    = Color3.fromRGB(120, 235, 160),
	bad     = Color3.fromRGB(255, 110, 110),
	text    = Color3.fromRGB(238, 232, 250),
	muted   = Color3.fromRGB(160, 150, 180),
	dead    = Color3.fromRGB(90, 84, 104),
	wave    = Color3.fromRGB(255, 150, 60),
	boss    = Color3.fromRGB(255, 90, 60),
}

--- The ink every button and pill prints its label in. Dark, because every
--- button colour in the palette above is a bright one.
UiKit.INK = Color3.fromRGB(20, 16, 28)

local PALETTE = UiKit.PALETTE

-- ─────────────────────────────────────────────────────────────────────────────
-- builders
-- ─────────────────────────────────────────────────────────────────────────────

function UiKit.corner(parent: Instance, radius: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

function UiKit.stroke(parent: Instance, color: Color3, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 2
	s.Transparency = 0.35
	s.Parent = parent
	return s
end

--- A card: rounded, outlined, with the vertical gradient that makes a stack of
--- them read as one surface rather than as eight rectangles.
function UiKit.panel(parent: Instance, size: UDim2, position: UDim2, anchor: Vector2?): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position
	f.AnchorPoint = anchor or Vector2.zero
	f.BackgroundColor3 = PALETTE.panel
	f.BackgroundTransparency = 0.12
	f.BorderSizePixel = 0
	f.Parent = parent
	UiKit.corner(f, 14)
	UiKit.stroke(f, PALETTE.accent, 2)

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(PALETTE.panel2, PALETTE.panel)
	gradient.Rotation = 90
	gradient.Parent = f
	return f
end

function UiKit.text(parent: Instance, props): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Style.Font.body
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

--- TextScaled by default — see the header. A caller that wants sized text
--- passes TextScaled = false and a TextSize in `props`, which land after these
--- defaults do.
function UiKit.button(parent: Instance, label: string, color: Color3, props): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = color
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Style.Font.title
	b.Text = label
	b.TextColor3 = UiKit.INK
	b.TextScaled = true
	for k, v in pairs(props or {}) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	UiKit.corner(b, 10)
	return b
end

-- ─────────────────────────────────────────────────────────────────────────────
-- fitting the screen
-- ─────────────────────────────────────────────────────────────────────────────

--- The one number the whole HUD is scaled by.
---
--- MIN OF THE TWO RATIOS, not max and not the width alone. The min is what
--- guarantees the layer this is mounted on is at least ReferenceWidth x
--- ReferenceHeight DESIGN pixels at every aspect ratio, which is the property
--- that makes every UDim2.fromOffset literal in src/client correct by
--- construction. Max would guarantee neither axis; width alone would guarantee
--- the wrong one, since it is height that a landscape phone runs out of.
---
--- MinScale is the deliberate hole in that guarantee: below it the UI would
--- shrink past the point of being readable, so it stops shrinking and a very
--- short screen gets a canvas shorter than the reference instead. That is the
--- band the shop-versus-column overlap lived in, and it is why the verifier
--- asserts that layout at the reference height rather than trusting it.
function UiKit.scaleFor(viewport: Vector2): number
	return math.clamp(
		math.min(viewport.X / UI.ReferenceWidth, viewport.Y / UI.ReferenceHeight),
		UI.MinScale, UI.MaxScale)
end

--- The gutter, in PHYSICAL pixels, the persistent HUD should keep clear on each
--- edge: notch, home indicator, rounded corners.
---
--- WHAT IS CONFIDENT AND WHAT IS NOT. GuiService:GetGuiInset() returns two
--- Vector2s and has been stable for years, so it is read directly. Everything
--- else here is newer surface that a given client may not have, so it is
--- pcall'd and simply does not contribute when it is missing — the fallback is
--- the behaviour that shipped, plus SafeAreaPad.
---
--- THE TOP IS DELIBERATELY NOT READ. The ScreenGui is built with
--- IgnoreGuiInset = false, so the engine has ALREADY pushed the whole layer
--- below the topbar. Adding GetGuiInset().Y on top of that is the classic
--- double-inset bug and costs 36 design pixels of screen for nothing.
function UiKit.safeInsets(viewport: Vector2)
	local pad = UI.SafeAreaPad
	local insets = { left = pad, right = pad, top = pad, bottom = pad }

	-- topLeft is the inset the ScreenGui already applied; only bottomRight is
	-- news, and on a phone with a home indicator it is the news that matters.
	local ok, _topLeft, bottomRight = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(bottomRight) == "Vector2" then
		insets.right += math.max(0, bottomRight.X)
		insets.bottom += math.max(0, bottomRight.Y)
	end

	-- TopbarInset is a Rect describing where the CoreUI topbar actually sits.
	-- In landscape on a notched phone its left edge is pushed in past the
	-- notch, which is the only reading of the SIDE safe area available to a
	-- LocalScript. Guarded because it does not exist on every client.
	local okBar, bar = pcall(function()
		return GuiService.TopbarInset
	end)
	if okBar and typeof(bar) == "Rect" and bar.Width > 0 then
		insets.left = math.max(insets.left, bar.Min.X + pad)
		insets.right = math.max(insets.right, viewport.X - bar.Max.X + pad)
	end

	return insets
end

return UiKit
