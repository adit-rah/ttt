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

	IT ALSO OWNS WHERE A REGION GOES, not just what it looks like. `dock` names
	the four corners of the design canvas; before it, five call sites in three
	files each spelled out their own AnchorPoint and their own
	`UDim2.new(1, -UI.Margin, 1, -UI.Margin)`, and the left column's two panels
	were placed by two files reading the same Config keys separately. A panel
	asks for a corner now and gets the anchor, the inset and the list alignment
	that agree with it.

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
-- Spelled from `Config` rather than from `UI`, exactly like HUD.lua's CARD, so
-- verify.py's config-path pass can resolve it: it follows ONE alias hop, and a
-- `local RAIL = UI.Rail` would be a name it has no way to check reads against.
local RAIL = Config.UI.Rail

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
-- putting a region against an edge
-- ─────────────────────────────────────────────────────────────────────────────

--- THE FOUR CORNERS, and the AnchorPoint and list alignment each one implies.
---
--- A dock is (anchor, position, alignment) and the three have to agree: a frame
--- anchored (1,0) and positioned from the LEFT edge is off the right side of the
--- screen, and a right-hand column whose list layout aligns Left grows away from
--- the edge it is docked to. Naming the corner once is what stops a call site
--- getting two of the three right.
local DOCKS = {
	topLeft     = { x = 0, y = 0, alignX = "Left",  alignY = "Top" },
	topRight    = { x = 1, y = 0, alignX = "Right", alignY = "Top" },
	bottomLeft  = { x = 0, y = 1, alignX = "Left",  alignY = "Bottom" },
	bottomRight = { x = 1, y = 1, alignX = "Right", alignY = "Bottom" },
}

--- invariant: a transparent region pinned to one corner of the design canvas,
--- and THE ONLY WAY ANYTHING GETS PINNED TO AN EDGE. Five call sites spelling
--- out their own AnchorPoint is five chances to disagree about what "against
--- the edge" means, and they did.
---
--- `insetX` / `insetY` default to UI.Margin and are the distance from that edge,
--- always measured INWARD whichever corner it is, so a caller never writes the
--- sign. UI.Action passes an insetY of TouchReserve.Bottom to sit above the
--- engine's own controls; everything else takes the margin.
---
--- `direction` is "Vertical" or "Horizontal", and attaches a UIListLayout that
--- stacks children away from the docked corner with UI.Gap between them. Omit it
--- for a region that positions its own children.
function UiKit.dock(parent: Instance, opts): Frame
	local spot = DOCKS[opts.corner]
	if not spot then
		-- Loud, like Style.distance: a typo'd corner that fell back to top-left
		-- would be a panel silently drawn on top of the status card.
		error(("[Tung] unknown dock corner %q; expected topLeft/topRight/bottomLeft/bottomRight")
			:format(tostring(opts.corner)), 2)
	end

	local insetX = opts.insetX or UI.Margin
	local insetY = opts.insetY or UI.Margin

	local frame = Instance.new("Frame")
	frame.Name = opts.name
	frame.AnchorPoint = Vector2.new(spot.x, spot.y)
	-- The scale term picks the edge and the offset term steps inward from it, so
	-- the same expression serves all four corners.
	frame.Position = UDim2.new(
		spot.x, spot.x == 0 and insetX or -insetX,
		spot.y, spot.y == 0 and insetY or -insetY)
	frame.Size = UDim2.fromOffset(opts.width, opts.height)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = parent

	if opts.direction then
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = (Enum.FillDirection :: any)[opts.direction]
		layout.Padding = UDim.new(0, UI.Gap)
		layout.HorizontalAlignment = (Enum.HorizontalAlignment :: any)[spot.alignX]
		layout.VerticalAlignment = (Enum.VerticalAlignment :: any)[spot.alignY]
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = frame
	end

	return frame
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the rail, and the one glyph on it
-- ─────────────────────────────────────────────────────────────────────────────

--- mechanism: a person with a plus, drawn out of rounded rectangles — a head, a
--- domed torso clipped at the container's bottom edge, and a plus in a disc over
--- its shoulder. design:D-10 for why it is drawn rather than uploaded.
---
--- `ink` is the glyph and `cut` is the colour showing THROUGH the plus — pass
--- the button's own background for that, and the plus reads as a hole punched in
--- the disc rather than as a third colour competing with the first two.
---
--- Every number is a fraction of `size`. They are here rather than in Config
--- because they are the shape of a drawing, not the layout of a card: nothing
--- else on screen is measured against them and the verifier has nothing to
--- compare them to. The one number that IS layout, how big the glyph is drawn,
--- is UI.Rail.GlyphSize and comes in as `size`.
function UiKit.personPlus(parent: Instance, size: number, ink: Color3, cut: Color3): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Glyph"
	holder.Size = UDim2.fromOffset(size, size)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	-- The torso is a full rounded rectangle whose bottom half is meant to be off
	-- the picture; without this it is a pill floating under a head.
	holder.ClipsDescendants = true
	holder.Parent = parent

	local function block(name: string, w: number, h: number, x: number, y: number, colour: Color3, radius: number)
		local part = Instance.new("Frame")
		part.Name = name
		part.Size = UDim2.fromOffset(w, h)
		part.Position = UDim2.fromOffset(x, y)
		part.BackgroundColor3 = colour
		part.BorderSizePixel = 0
		part.Parent = holder
		if radius > 0 then
			UiKit.corner(part, radius)
		end
		return part
	end

	-- The person is pushed left of centre to leave the lower right for the disc.
	local head = math.floor(size * 0.34)
	local torsoW, torsoH = math.floor(size * 0.60), math.floor(size * 0.46)
	local centre = math.floor(size * 0.39)
	block("Head", head, head, centre - math.floor(head / 2), math.floor(size * 0.08),
		ink, math.floor(head / 2))
	block("Torso", torsoW, torsoH, centre - math.floor(torsoW / 2), math.floor(size * 0.48),
		ink, math.floor(torsoW / 2))

	local disc = math.floor(size * 0.46)
	local discX, discY = size - disc, size - disc
	block("Plus", disc, disc, discX, discY, ink, math.floor(disc / 2))

	-- The two bars are children of the holder, not of the disc, so they are
	-- positioned in one coordinate space; the disc is behind them by creation
	-- order under ZIndexBehavior.Sibling.
	local barLong, barShort = math.floor(disc * 0.52), math.max(2, math.floor(disc * 0.16))
	local barX = discX + math.floor((disc - barLong) / 2)
	local barY = discY + math.floor((disc - barShort) / 2)
	block("PlusH", barLong, barShort, barX, barY, cut, 0)
	block("PlusV", barShort, barLong, discX + math.floor((disc - barShort) / 2),
		discY + math.floor((disc - barLong) / 2), cut, 0)

	return holder
end

--- A rail item: a glyph over a caption, the whole thing one hit target.
---
--- The caption is not decoration. This is the only control in the game that asks
--- a player to do something outside the server, and the number under the glyph
--- is what the ask is worth — an icon on its own is a button a child has to
--- press to find out what it does.
---
--- Returns the button and its caption label; the caller draws into the glyph
--- slot and writes the caption.
function UiKit.railItem(parent: Instance, name: string, colour: Color3): (TextButton, Frame, TextLabel)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.fromOffset(RAIL.ItemWidth, RAIL.ItemHeight)
	b.BackgroundColor3 = colour
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Style.Font.title
	b.Text = ""
	b.Parent = parent
	UiKit.corner(b, 12)

	local slot = Instance.new("Frame")
	slot.Name = "GlyphSlot"
	slot.Size = UDim2.fromOffset(RAIL.GlyphSize, RAIL.GlyphSize)
	slot.Position = UDim2.fromOffset(RAIL.GlyphX, RAIL.GlyphY)
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Parent = b

	local caption = UiKit.text(b, {
		Name = "Caption",
		Size = UDim2.fromOffset(RAIL.BadgeWidth, RAIL.BadgeHeight),
		Position = UDim2.fromOffset(RAIL.Pad, RAIL.BadgeY),
		Font = Style.Font.title,
		Text = "",
		TextSize = RAIL.BadgeTextPx,
		TextColor3 = UiKit.INK,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	return b, slot, caption
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

--- invariant: the gutter, in PHYSICAL pixels, the persistent HUD keeps clear on
--- each edge — notch, home indicator, rounded corners.
---
--- Takes no viewport. It took one, to measure a right-hand inset off
--- GuiService.TopbarInset's far edge; that whole reading is gone — see the note
--- at the bottom of this function for what it actually measured.
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
function UiKit.safeInsets()
	local pad = UI.SafeAreaPad
	local insets = { left = pad, right = pad, top = pad, bottom = pad }

	-- GetGuiInset's two corners answer two different questions.
	--
	-- topLeft.Y is the topbar, which the ScreenGui has ALREADY been pushed below
	-- (see the note above) and which must not be counted twice. topLeft.X is
	-- something else entirely: it is how far in from the left the usable area
	-- starts, which is zero on every desktop and is the DISPLAY CUTOUT on a
	-- notched phone held in landscape. bottomRight is the home indicator, and on
	-- a phone that has one it is the news that matters.
	--
	-- The X terms err outward on purpose. If a client turns out to apply the
	-- side inset to the ScreenGui itself, this double-counts it and the cost is a
	-- gutter one notch too wide — the direction Config.UI.SafeAreaPad's comment
	-- says a guess about a cutout should be wrong in.
	local ok, topLeft, bottomRight = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(topLeft) == "Vector2" then
		insets.left += math.max(0, topLeft.X)
	end
	if ok and typeof(bottomRight) == "Vector2" then
		insets.right += math.max(0, bottomRight.X)
		insets.bottom += math.max(0, bottomRight.Y)
	end

	-- invariant: GuiService.TopbarInset IS NOT READ, AND THAT IS THE POINT OF
	-- THIS COMMENT.
	--
	-- It was, on the argument that "in landscape on a notched phone its left edge
	-- is pushed in past the notch, which is the only reading of the SIDE safe
	-- area available to a LocalScript":
	--
	--     insets.left = math.max(insets.left, bar.Min.X + pad)
	--
	-- That is not what the Rect measures. TopbarInset is the strip left over for
	-- CUSTOM topbar buttons, so its left edge sits past Roblox's OWN menu and
	-- chat buttons — 165 physical pixels in on the desktop this was found on, and
	-- nothing to do with a notch. Applied as a full-height gutter it pushed the
	-- entire left column 191 px inside the screen, on every device, to clear an
	-- obstruction that lives in a strip `IgnoreGuiInset = false` has already put
	-- the whole layer below. It cost about a sixth of the screen's width and it
	-- looked deliberate.
	--
	-- The notch case it was reaching for is real and is covered twice over: the
	-- ScreenGui asks for Enum.ScreenInsets.CoreUISafeInsets, which is the device
	-- safe area, and topLeft.X above is the same number read a second way. A
	-- top-strip measurement is not a side gutter, and there is no third reading
	-- to go looking for.

	return insets
end

return UiKit
