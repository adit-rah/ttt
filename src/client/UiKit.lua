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
	different shades of the same colour, and the one that drifts first is always
	the one nobody opens. The values are in Config now and the copies cannot
	come back — see the note over UiKit.ROLE.

	IT ALSO OWNS WHERE A REGION GOES, not just what it looks like. `dock` names
	the four corners of the design canvas; before it, five call sites in three
	files each spelled out their own AnchorPoint and their own
	`UDim2.new(1, -UI.Margin, 1, -UI.Margin)`, and the left column's two panels
	were placed by two files reading the same Config keys separately. A panel
	asks for a corner now and gets the anchor, the inset and the list alignment
	that agree with it.

	THE ONE DIVERGENCE IS RESOLVED, and SessionUI won it. HUD and UpgradeUI built
	TextScaled buttons with no TextSize while SessionUI's were sized text behind a
	shim, and the shim's argument — TextScaled sizes a label from its own box, so
	two buttons of different widths print at two sizes and neither is a number the
	verifier can read — was true of the whole game. `control` is sized text at the
	variant's textPx, and there is no `button` any more.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")

local GuiService = game:GetService("GuiService")

local UI = Config.UI
-- Spelled from `Config` rather than from `UI`, exactly like HUD.lua's CARD, so
-- verify.py's config-path pass can resolve it: it follows ONE alias hop, and a
-- `local TILE = UI.Tile` would be a name it has no way to check reads against.
local ICON = Config.UI.Icon
local TILE = Config.UI.Tile
local BTN = Config.UI.Button

local UiKit = {}

--- THE PALETTE, RESOLVED. Config.UI.Role names what a colour is FOR and
--- Config.UI.Palette says what it IS; this is the two of them composed, once,
--- into the only colour table src/client is allowed to read.
---
--- WHY THE VALUES ARE NOT HERE. They were, as three copies merged into one —
--- and merging them fixed the values while leaving nothing to stop a fourth
--- copy, which is what twenty-six raw Color3 calls elsewhere in src/client
--- were. In Config the verifier can read them: it stubs Color3.fromRGB as
--- { r, g, b }, so contrast against the surface a label prints on is
--- arithmetic rather than something a reader has to notice.
---
--- A ROLE THAT NAMES A MISSING KEY IS A BUILD FAILURE, not a nil that spreads.
--- Style.Font.head got away with being nil for two rounds because a nil in a
--- props table is a key that never arrives; this errors at require time.
UiKit.ROLE = {}
for role, key in pairs(UI.Role) do
	local colour = UI.Palette[key]
	if not colour then
		error(("[Tung] Config.UI.Role.%s names palette key %q, which does not exist")
			:format(role, tostring(key)), 2)
	end
	UiKit.ROLE[role] = colour
end

local ROLE = UiKit.ROLE

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
	f.BackgroundColor3 = ROLE.surface
	f.BackgroundTransparency = UI.PanelAlpha
	f.BorderSizePixel = 0
	f.Parent = parent
	UiKit.corner(f, 14)
	UiKit.stroke(f, ROLE.line, 2)

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(ROLE.surfaceRaised, ROLE.surface)
	gradient.Rotation = 90
	gradient.Parent = f
	return f
end

function UiKit.text(parent: Instance, props): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Style.Font.body
	l.TextColor3 = ROLE.onSurface
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextScaled = false
	l.RichText = true
	for k, v in pairs(props) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

-- ─────────────────────────────────────────────────────────────────────────────
-- controls
-- ─────────────────────────────────────────────────────────────────────────────

--- invariant: ONE CONTROL, and the variant decides everything about how it
--- looks. The caller decides what it says, how wide it is and where it goes.
---
--- opts:
---   variant     "primary" | "secondary" | "pill" | "ghost" | "danger"  (required)
---   text        the label
---   icon        a UiKit.ICONS name drawn ahead of the label            (optional)
---   width       design px. Ignored when iconOnly
---   height      "primary" | "secondary" | "pill", overriding the variant's own
---   iconOnly    a square control at UI.Button.IconOnly, carrying only a glyph
---   name, layoutOrder, position, anchor, zIndex
---
--- HOVER AND PRESS ARE THE ENGINE'S. AutoButtonColor darkens on press and
--- lightens on hover, on every platform, for free; a second system on top of it
--- is two things to keep in step where one already works. What is ours is the
--- part the engine has no opinion about — see setControlState.
function UiKit.control(parent: Instance, opts): TextButton
	local variant = BTN.Variant[opts.variant]
	if not variant then
		error(("[Tung] unknown control variant %q; Config.UI.Button.Variant has no such row")
			:format(tostring(opts.variant)), 2)
	end
	local heightName = opts.height or variant.height
	local height = BTN[heightName]
	if not height then
		error(("[Tung] control height %q is not a rung of Config.UI.Button")
			:format(tostring(heightName)), 2)
	end
	local width = opts.iconOnly and BTN.IconOnly or (opts.width or BTN.MinWidth)

	local b = Instance.new("TextButton")
	-- An empty string is truthy in Lua, so a control built with text = "" and
	-- filled in by a later state push was landing in the tree called "".
	b.Name = opts.name
		or (opts.text ~= nil and opts.text ~= "" and opts.text)
		or opts.variant
	b.Size = UDim2.fromOffset(width, opts.iconOnly and BTN.IconOnly or height)
	b.BackgroundColor3 = ROLE[variant.fill]
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	-- All three declared rather than left to the engine's defaults, because
	-- setControlState turns all three off and `idle` has to have something
	-- exact to turn them back to.
	b.AutoButtonColor = true
	b.Active = true
	b.Selectable = true
	b.Font = Style.Font.title
	b.TextColor3 = ROLE[variant.ink]
	b.TextSize = variant.textPx
	b.TextScaled = false
	b.TextTruncate = Enum.TextTruncate.AtEnd
	b.Text = (opts.icon or opts.iconOnly) and "" or (opts.text or "")
	if opts.position then
		b.Position = opts.position
	end
	if opts.anchor then
		b.AnchorPoint = opts.anchor
	end
	if opts.layoutOrder then
		b.LayoutOrder = opts.layoutOrder
	end
	if opts.zIndex then
		b.ZIndex = opts.zIndex
	end
	b.Parent = parent
	UiKit.corner(b, BTN.Radius)
	if variant.stroke then
		UiKit.stroke(b, ROLE[variant.stroke], 1.5)
	end
	-- The variant is remembered ON the instance rather than in a closure, so
	-- setControlState needs no capture and a spec can read which variant a live
	-- button is without being handed it.
	b:SetAttribute("Variant", opts.variant)

	if opts.icon then
		local glyph = UiKit.icon(b, opts.icon, ICON.Medium, ROLE[variant.ink], ROLE[variant.fill])
		if opts.iconOnly then
			glyph.Position = UDim2.fromOffset(
				math.floor((BTN.IconOnly - ICON.Medium) / 2),
				math.floor((BTN.IconOnly - ICON.Medium) / 2))
		else
			glyph.Position = UDim2.fromOffset(BTN.Pad, math.floor((height - ICON.Medium) / 2))
			-- A TextButton with Text set runs it UNDER the glyph, so a labelled
			-- icon control carries its label as a child laid out beside the
			-- drawing rather than as the button's own text.
			UiKit.text(b, {
				Name = "Label",
				Size = UDim2.fromOffset(width - BTN.LabelInset - BTN.Pad, height),
				Position = UDim2.fromOffset(BTN.LabelInset, 0),
				Font = Style.Font.title,
				Text = opts.text or "",
				TextSize = variant.textPx,
				TextColor3 = ROLE[variant.ink],
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextYAlignment = Enum.TextYAlignment.Center,
			})
		end
	end

	return b
end

--- invariant: idle | on | disabled | busy, and each one sets ALL SIX properties.
---
--- Four call sites wrote "disabled" by hand and every one of them forgot the
--- same three: AutoButtonColor stayed on so a dead control still flashed under
--- a thumb, the ink stayed at the live variant's so the label went unreadable
--- on the dark fill, and Selectable stayed on so a gamepad still landed there.
--- `busy` is disabled plus a label, for the beat between a press and the
--- server's answer. `on` is unpressable and looks it least: a running boost and
--- a held sprint are both live effects, and greying one reads as it having
--- stopped.
local CONTROL_STATES = { idle = true, on = true, disabled = true, busy = true }

function UiKit.setControlState(button: TextButton, state: string, label: string?)
	local variant = BTN.Variant[button:GetAttribute("Variant")]
	if not variant then
		error(("[Tung] the control %q carries no Variant attribute; it was not built by UiKit.control")
			:format(button.Name), 2)
	end
	if not CONTROL_STATES[state] then
		error(("[Tung] unknown control state %q; expected idle/on/disabled/busy")
			:format(tostring(state)), 2)
	end
	local live = state == "idle"
	local look = (state == "on" and BTN.On) or (not live and BTN.Disabled) or variant
	local fill, ink = look.fill, look.ink

	button.BackgroundColor3 = ROLE[fill]
	button.TextColor3 = ROLE[ink]
	button.AutoButtonColor = live
	button.Active = live
	button.Selectable = live
	if label then
		button.Text = button.Text ~= "" and label or button.Text
	end

	local text = button:FindFirstChild("Label")
	if text and text:IsA("TextLabel") then
		text.TextColor3 = ROLE[ink]
		if label then
			text.Text = label
		end
	end
	local glyph = button:FindFirstChild("Glyph")
	if glyph then
		for _, part in ipairs(glyph:GetChildren()) do
			if part:IsA("Frame") then
				local stroke = part:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = ROLE[ink]
				elseif part.BackgroundColor3 ~= ROLE[variant.fill] then
					part.BackgroundColor3 = ROLE[ink]
				end
			end
		end
	end
end

--- The full-bleed dim behind a modal.
---
--- Built twice by hand before this, in HUD.lua and SessionUI.lua, each then
--- walking its own descendants to force a ZIndex. It goes on the OVERLAY layer,
--- which is the one without safe-area padding, so the dim covers the notch and
--- the home indicator rather than stopping politely short of them.
function UiKit.shade(parent: Instance, name: string, zIndex: number): Frame
	local shade = Instance.new("Frame")
	shade.Name = name
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = ROLE.scrim
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = zIndex
	shade.Parent = parent
	return shade
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
	topLeft      = { x = 0,   y = 0,   alignX = "Left",   alignY = "Top" },
	topRight     = { x = 1,   y = 0,   alignX = "Right",  alignY = "Top" },
	bottomLeft   = { x = 0,   y = 1,   alignX = "Left",   alignY = "Bottom" },
	bottomRight  = { x = 1,   y = 1,   alignX = "Right",  alignY = "Bottom" },
	-- THE CENTRED THREE, and they exist because the claim above was false.
	-- CompassUI and TowerUI both docked topLeft and then overwrote AnchorPoint
	-- and Position to centre themselves, which is two call sites spelling out
	-- what "against the edge" means — the exact thing this function was written
	-- to end. INVARIANTS §7 recorded it as [nothing] rather than fixing it.
	--
	-- A centred dock takes no insetX: there is no edge on that axis to step in
	-- from, and a caller passing one has misunderstood which corner they want.
	topCentre    = { x = 0.5, y = 0,   alignX = "Center", alignY = "Top",    centreX = true },
	bottomCentre = { x = 0.5, y = 1,   alignX = "Center", alignY = "Bottom", centreX = true },
	centre       = { x = 0.5, y = 0.5, alignX = "Center", alignY = "Center", centreX = true, centreY = true },
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
		error(("[Tung] unknown dock corner %q; expected topLeft/topRight/bottomLeft/bottomRight/topCentre/bottomCentre/centre")
			:format(tostring(opts.corner)), 2)
	end

	if spot.centreX and opts.insetX then
		error(("[Tung] dock %q is centred on X; an insetX has no edge to measure from")
			:format(opts.corner), 2)
	end
	if spot.centreY and opts.insetY then
		error(("[Tung] dock %q is centred on Y; an insetY has no edge to measure from")
			:format(opts.corner), 2)
	end
	local insetX = opts.insetX or UI.Margin
	local insetY = opts.insetY or UI.Margin

	local frame = Instance.new("Frame")
	frame.Name = opts.name
	frame.AnchorPoint = Vector2.new(spot.x, spot.y)
	-- The scale term picks the edge and the offset term steps inward from it, so
	-- the same expression serves all four corners.
	-- A centred axis takes no inset at all; the other two step inward from the
	-- edge the scale term picked, so one expression still serves every corner.
	frame.Position = UDim2.new(
		spot.x, spot.centreX and 0 or (spot.x == 0 and insetX or -insetX),
		spot.y, spot.centreY and 0 or (spot.y == 0 and insetY or -insetY))
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
-- icons
-- ─────────────────────────────────────────────────────────────────────────────

--- mechanism: A GLYPH IS A LIST OF PARTS IN GRID UNITS, and the grid is
--- Config.UI.Icon.Grid. Four constructors and no fifth — `rect`, `dot`, `bar`
--- and `ring` — because every one of them is a Frame with a UICorner, and the
--- only thing this game can draw is a Frame with a UICorner.
---
--- WHAT MAKES THE SET A SET: `bar` takes two POINTS and derives its own length
--- and angle, so no glyph author writes a Rotation, and nothing takes a
--- thickness at all. The weight is resolved once per drawing, from the size the
--- caller asked for, and shared by every part of that drawing. A thickness
--- chosen per part, from that part's own length, is exactly what makes a bat
--- and a coin look like two people drew them.
---
--- WHY THE COORDINATES ARE HERE AND THE SIZES ARE IN CONFIG. These numbers are
--- the shape of a drawing: nothing else on screen is measured against them and
--- the verifier has nothing to compare them to. The grid, the three sizes and
--- the three weights ARE layout, and they are in Config where they are held
--- against MinScale and against the rail. That split is UiKit.personPlus's own
--- argument, generalised — its numbers were already fractions of `size`.
local G = ICON.Grid

local function rect(x, y, w, h, radius, rotation)
	return { kind = "rect", x = x, y = y, w = w, h = h, radius = radius or 0, rotation = rotation }
end

local function dot(cx, cy, d)
	return { kind = "rect", x = cx - d / 2, y = cy - d / 2, w = d, h = d, radius = d / 2 }
end

--- `opts` may carry `thick`, a WHOLE multiple of the glyph's weight for a part
--- meant to read as heavier than a line — a bat's barrel against its handle.
--- Whole, because a fraction rounds to a thickness that is not a multiple of
--- anything, which is the drift the shared weight exists to prevent: the barrel
--- was declared at 2.2 and drew at 7 against a glyph weight of 3.
--- It may also carry `cut = true`, which draws the part in the colour behind
--- the glyph so it reads as a hole punched through what is under it.
local function bar(x1, y1, x2, y2, opts)
	return { kind = "bar", x1 = x1, y1 = y1, x2 = x2, y2 = y2,
		thick = opts and opts.thick or 1, cut = opts and opts.cut or false }
end

local function ring(cx, cy, d)
	return { kind = "ring", x = cx - d / 2, y = cy - d / 2, w = d, h = d }
end

--- Every glyph the game can draw. A name that is not in here is an error, not
--- a blank frame: the rail shipped two items whose glyph slot was silently
--- empty, and a drawing that fails quietly is how that happens again.
---
--- `clip` is for a glyph whose parts are meant to run off the edge of the
--- picture. The person's torso is a full rounded rectangle with its bottom half
--- outside the frame; without the clip it is a pill floating under a head.
UiKit.ICONS = {
	-- the currency, replacing a gold disc with the letter T scaled inside it
	coin = { ring(12, 12, 20), bar(8, 9, 16, 9), bar(12, 9, 12, 16.5) },

	-- done. Replaces the ✓ that ObjectivesUI printed as text.
	tick = { bar(5, 12.5, 10, 17.5), bar(10, 17.5, 19, 6.5) },
	close = { bar(6.5, 6.5, 17.5, 17.5), bar(17.5, 6.5, 6.5, 17.5) },
	-- The help rail. A question mark is a smooth open curve and is not
	-- drawable from these four primitives; the substitution is #183's open
	-- question, and this is what it substitutes.
	info = { ring(12, 12, 20), dot(12, 7.5, 3), bar(12, 11, 12, 17) },
	-- The touch pad. Three motion lines, a double chevron, and the roof the
	-- compass already draws.
	run  = { bar(4, 7, 20, 7), bar(7, 12, 20, 12), bar(11, 17, 20, 17) },
	dash = { bar(5, 6, 12, 12), bar(12, 12, 5, 18), bar(12, 6, 19, 12), bar(19, 12, 12, 18) },
	-- The shop rail: an awning over a box with a door in it.
	shop = { bar(3, 6.5, 21, 6.5, { thick = 2 }), rect(5, 10, 14, 11, 1), rect(10, 15, 4, 6, 0.5) },
	-- What the shop sells. The bat runs knob to barrel on the diagonal and is
	-- the one glyph with a deliberately heavier part — `thick` on the barrel,
	-- which is still a multiple of the drawing's own weight.
	bat = { dot(5.5, 18.5, 5), bar(6.5, 17.5, 12, 12),
		bar(12.5, 11.5, 18.5, 5.5, { thick = 2 }) },
	armour = { rect(5, 3, 14, 10, 2), bar(5, 13, 12, 20), bar(12, 20, 19, 13) },
	-- The shackle is a RING DRAWN FIRST and the body an opaque rect over it,
	-- so only the top half of the ring survives. Nothing here can draw an arc.
	lock = { ring(12, 9.5, 11), rect(5, 12, 14, 9, 2) },

	-- the compass set, replacing ◆ ▲ ⌂ ! and a partymate's first initial
	core  = { rect(7, 7, 10, 10, 1, 45) },
	tower = { rect(6, 17, 12, 5, 1), rect(7.5, 11, 9, 5, 1), rect(9, 5, 6, 5, 1) },
	home  = { bar(4, 12, 12, 5), bar(12, 5, 20, 12), rect(6.5, 12, 11, 9, 1) },
	alert = { ring(12, 12, 20), bar(12, 6.5, 12, 13), dot(12, 17, 3) },

	-- the invite. Ported from UiKit.personPlus part for part: the fractions it
	-- carried were already a 24-unit grid in disguise.
	personPlus = { clip = true, parts = {
		dot(9.4, 5.9, 8),
		rect(2.2, 11.5, 14.4, 11, 7.2),
		dot(18.5, 18.5, 11),
		bar(15.7, 18.5, 21.3, 18.5, { cut = true }),
		bar(18.5, 15.7, 18.5, 21.3, { cut = true }),
	} },
}

--- Every glyph name, sorted. icon_spec walks this, so a part declared off the
--- grid fails in the harness rather than in Studio.
function UiKit.iconNames(): { string }
	local names = {}
	for name in pairs(UiKit.ICONS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- The stroke weight a glyph drawn at `size` is built out of. Snaps to the
--- nearest declared tier rather than interpolating: three weights is the point,
--- and a fourth arrived at by arithmetic is the drift this replaces.
local function weightFor(size: number): number
	if size <= (ICON.Small + ICON.Medium) / 2 then
		return ICON.StrokeSmall
	elseif size <= (ICON.Medium + ICON.Large) / 2 then
		return ICON.StrokeMedium
	end
	return ICON.StrokeLarge
end

--- Draw the named glyph into `parent`, `size` design px square.
---
--- `ink` is what it is drawn in. `cut` is what shows THROUGH a part declared
--- `cut = true` — pass the surface behind the glyph, and the plus in the invite
--- disc reads as a hole rather than as a third colour competing with the first
--- two. Defaults to the parent's own background.
---
--- Errors on an unknown name, loudly, the way `dock` does on an unknown corner.
--- A glyph that fell back to an empty frame is the empty-slot defect reached
--- through a different door.
function UiKit.icon(parent: Instance, name: string, size: number, ink: Color3, cut: Color3?): Frame
	local glyph = UiKit.ICONS[name]
	if not glyph then
		error(("[Tung] unknown icon %q; UiKit.ICONS has no such glyph"):format(tostring(name)), 2)
	end
	local parts = glyph.parts or glyph
	local holder = Instance.new("Frame")
	holder.Name = "Glyph"
	holder.Size = UDim2.fromOffset(size, size)
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = glyph.clip == true
	holder.Parent = parent

	local unit = size / G
	local weight = weightFor(size)
	local hole = cut or (parent :: any).BackgroundColor3 or ROLE.glyphCut

	for index, part in ipairs(parts) do
		local f = Instance.new("Frame")
		-- Named by KIND, because the tree is the only thing a spec can read: the
		-- mock stores a UDim2 and never resolves it, so "is this part a bar"
		-- cannot be answered from its size. A non-square rect looks exactly like
		-- one, which is how the first version of icon_spec reported the person's
		-- torso as a bar drawn at its own weight.
		f.Name = ("%s%d"):format(part.kind == "bar" and "Bar" or part.kind == "ring" and "Ring" or "Rect", index)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = part.cut and hole or ink

		if part.kind == "bar" then
			local dx, dy = (part.x2 - part.x1) * unit, (part.y2 - part.y1) * unit
			local length = math.sqrt(dx * dx + dy * dy)
			local thickness = math.max(1, math.round(weight * part.thick))
			-- Extended by one thickness so the round caps land ON the endpoints
			-- rather than inside them; a UICorner of half the height is what
			-- makes them round in the first place.
			f.Size = UDim2.fromOffset(math.round(length + thickness), thickness)
			f.Position = UDim2.fromOffset(
				math.round((part.x1 + part.x2) / 2 * unit),
				math.round((part.y1 + part.y2) / 2 * unit))
			f.Rotation = math.deg(Util.atan2(dy, dx))
			UiKit.corner(f, math.floor(thickness / 2))
		else
			f.Size = UDim2.fromOffset(math.round(part.w * unit), math.round(part.h * unit))
			f.Position = UDim2.fromOffset(
				math.round((part.x + part.w / 2) * unit),
				math.round((part.y + part.h / 2) * unit))
			if part.rotation then
				f.Rotation = part.rotation
			end
			if part.kind == "ring" then
				-- A ring is a circle that is only its own outline: no fill, and
				-- the stroke carries the glyph's one weight like every other part.
				f.BackgroundTransparency = 1
				UiKit.corner(f, math.round(part.w * unit / 2))
				local s = Instance.new("UIStroke")
				s.Color = ink
				s.Thickness = weight
				s.Parent = f
			elseif part.radius > 0 then
				UiKit.corner(f, math.round(part.radius * unit))
			end
		end
		f.Parent = holder
	end

	return holder
end

--- Fades a drawn glyph, whole.
---
--- The ring parts carry their drawing in a UIStroke and the rest carry it in a
--- BackgroundColor3, so one property does not fade both — and a glyph where the
--- outlines stayed hard while the fills receded would read as MORE contrasty
--- dimmed than lit, which is Style.fade's argument about text strokes, one
--- primitive down.
function UiKit.fadeIcon(glyph: Frame, alpha: number)
	for _, part in ipairs(glyph:GetChildren()) do
		if part:IsA("Frame") then
			local stroke = part:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = alpha
			else
				part.BackgroundTransparency = alpha
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the rail
-- ─────────────────────────────────────────────────────────────────────────────

--- invariant: A TILE IS A GLYPH OVER A CAPTION, AND BOTH ARE REQUIRED.
---
--- This returned (button, glyphSlot, caption) and two of its three callers took
--- only the button and wrote text into it — so the rail shipped as one drawn
--- icon beside two text buttons, each carrying an empty GlyphSlot Frame and an
--- empty Caption label nobody could see. Handing back a slot for the caller to
--- fill is what made forgetting possible; nothing is handed back now.
---
--- The caption is not decoration. This is the shape a control takes when it has
--- no room for a sentence, and an icon on its own is a button a child has to
--- press to find out what it does. On the invite the caption carries the number
--- the ask is worth.
---
--- opts: { name, icon, caption, variant }
function UiKit.tile(parent: Instance, opts): TextButton
	if not opts.icon or not opts.caption then
		error(("[Tung] the %q tile needs both an icon and a caption; an icon with no caption is a button nobody can read")
			:format(tostring(opts.name)), 2)
	end
	local variant = BTN.Variant[opts.variant]
	if not variant then
		error(("[Tung] unknown tile variant %q"):format(tostring(opts.variant)), 2)
	end

	local b = Instance.new("TextButton")
	b.Name = opts.name
	b.Size = UDim2.fromOffset(TILE.Width, TILE.Height)
	b.BackgroundColor3 = ROLE[variant.fill]
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Active = true
	b.Selectable = true
	b.Font = Style.Font.title
	b.Text = ""
	b.Parent = parent
	UiKit.corner(b, 12)
	if variant.stroke then
		UiKit.stroke(b, ROLE[variant.stroke], 1.5)
	end
	b:SetAttribute("Variant", opts.variant)

	local glyph = UiKit.icon(b, opts.icon, TILE.GlyphSize, ROLE[variant.ink], ROLE[variant.fill])
	glyph.Position = UDim2.fromOffset(
		math.floor((TILE.Width - TILE.GlyphSize) / 2), TILE.Pad)

	UiKit.text(b, {
		Name = "Caption",
		Size = UDim2.fromOffset(TILE.Width - TILE.Pad * 2, TILE.CaptionHeight),
		Position = UDim2.fromOffset(TILE.Pad, TILE.Pad + TILE.GlyphSize + TILE.GlyphGap),
		Font = Style.Font.title,
		Text = opts.caption,
		TextSize = TILE.CaptionTextPx,
		TextColor3 = ROLE[variant.ink],
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	return b
end

--- Rewrites a tile's caption. The invite's is a live number, so the label has
--- to be reachable — by name off the tile rather than by a Frame the caller was
--- handed and had to keep.
function UiKit.setTileCaption(tile: TextButton, caption: string)
	local label = tile:FindFirstChild("Caption")
	if label and label:IsA("TextLabel") then
		label.Text = caption
	end
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
