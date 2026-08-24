--[[
	icon_spec.lua — every glyph draws, and every glyph draws at one weight.

	WHAT THIS CAN AND CANNOT SEE. The GUI mock stores a UDim2 and never resolves
	it (mock/gui.lua, claim 1), so nothing here knows where a part LANDS or how
	big it looks. What it can read is the tree: how many parts a glyph built,
	what class each is, and the numbers written into their properties. That is
	enough for the one invariant the registry exists to hold — every bar in a
	drawing shares the drawing's weight — because a bar's thickness is the
	SHORTER side of a Size it wrote itself.

	WHETHER A GLYPH LOOKS LIKE THE THING IT NAMES IS NOT IN HERE and cannot be.
	The bat either reads as a bat or it does not, and only Studio and a person
	can say. That list is in the round's handoff, where an unanswerable question
	belongs, rather than in INVARIANTS as though a check existed.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL. Each was watched failing under one
	mutation, applied and reverted in the working tree:

	  draws            a name deleted from UiKit.ICONS
	  one weight       `thick = 1` in `bar` changed to a per-part length term
	  ring weight      the UIStroke thickness set to weight + 1
	  on the grid      one coordinate in `coin` pushed to 26 on a 24 grid
	  unknown name     the error() in UiKit.icon replaced with a bare return
	  cut is a hole    the `cut` flag ignored, so the plus drew in ink
]]

return function(T)

T.family("icon", "every glyph draws, on one grid, at one weight")

local function clientWorld()
	local world = T.world()
	world.client()
	return world
end

--- A detached frame to draw into. Nothing here needs the HUD: UiKit.icon takes
--- a parent and builds downward, which is the whole of its contract.
local function surface(world)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
	frame.Parent = world.playerGui()
	return frame
end

local function parts(glyph)
	local out = {}
	for _, child in ipairs(glyph:GetChildren()) do
		if child.ClassName == "Frame" then
			table.insert(out, child)
		end
	end
	return out
end

--- A bar carries the weight in its SIZE rather than in a UIStroke, and it is
--- always longer than it is thick, so the shorter side is the weight whatever
--- angle it was drawn at. Which parts ARE bars comes from the name UiKit.icon
--- writes: a non-square rect is indistinguishable from a bar by size alone, and
--- the first version of this helper duly reported the person's torso as a bar
--- drawn to its own rule.
local function barThickness(part): number?
	if part.Name:sub(1, 3) ~= "Bar" then
		return nil
	end
	local size = part.Size
	return math.min(size.X.Offset, size.Y.Offset)
end

T.spec("every glyph in the registry draws, at all three sizes", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local Config = world.req("Config")
	local names = UiKit.iconNames()

	t:gt(#names, 0, "UiKit.ICONS is empty — the registry parsed as nothing")

	for _, name in ipairs(names) do
		for _, size in ipairs({ Config.UI.Icon.Small, Config.UI.Icon.Medium, Config.UI.Icon.Large }) do
			local glyph = UiKit.icon(surface(world), name, size, Color3.fromRGB(255, 255, 255))
			t:notNil(glyph, ("icon %q at %d built nothing"):format(name, size))
			t:gt(#parts(glyph), 0,
				("icon %q at %d built a holder with no parts in it — an empty glyph slot is what this registry replaced")
					:format(name, size))
		end
	end
end)

T.spec("every bar in one glyph is drawn at the same weight", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local Config = world.req("Config")

	-- The heaviest part of a glyph may be a DELIBERATE multiple — a bat's
	-- barrel against its handle — so what is asserted is that every thickness is
	-- a whole multiple of the lightest one, rather than that they are all equal.
	-- A weight derived per part from that part's own length passes neither.
	for _, name in ipairs(UiKit.iconNames()) do
		for _, size in ipairs({ Config.UI.Icon.Small, Config.UI.Icon.Medium, Config.UI.Icon.Large }) do
			local glyph = UiKit.icon(surface(world), name, size, Color3.fromRGB(255, 255, 255))
			local thicknesses = {}
			for _, part in ipairs(parts(glyph)) do
				local thickness = barThickness(part)
				if thickness then
					table.insert(thicknesses, thickness)
				end
			end
			if #thicknesses > 1 then
				local base = math.huge
				for _, value in ipairs(thicknesses) do
					base = math.min(base, value)
				end
				for _, value in ipairs(thicknesses) do
					t:eq(value % base, 0,
						("icon %q at %d has a bar %d thick against a lightest of %d — a weight that is not a multiple of the glyph's own is a part drawn to its own rule")
							:format(name, size, value, base))
				end
			end
		end
	end
end)

T.spec("a ring strokes at the tier weight Config declares", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local ICON = world.req("Config").UI.Icon

	-- Against the DECLARED weight, not against the other rings. Every ring in
	-- the set happens to be the same diameter today, so "all the rings agree"
	-- is true of any formula derived from diameter and could not fail — which
	-- is the shape of the four assertions this project has already found that
	-- were guesses with a check() around them.
	local tiers = {
		{ size = ICON.Small,  weight = ICON.StrokeSmall },
		{ size = ICON.Medium, weight = ICON.StrokeMedium },
		{ size = ICON.Large,  weight = ICON.StrokeLarge },
	}
	local rings = 0
	for _, tier in ipairs(tiers) do
		for _, name in ipairs(UiKit.iconNames()) do
			local glyph = UiKit.icon(surface(world), name, tier.size, Color3.fromRGB(255, 255, 255))
			for _, part in ipairs(parts(glyph)) do
				local stroke = part:FindFirstChildOfClass("UIStroke")
				if stroke then
					rings += 1
					t:eq(stroke.Thickness, tier.weight,
						("a ring in %q at %d strokes at %s; the tier declares %d, and a ring drawn to its own rule is the one round thing on screen at the wrong weight")
							:format(name, tier.size, tostring(stroke.Thickness), tier.weight))
				end
			end
		end
	end
	t:gt(rings, 0, "no rings were drawn — the registry lost its round glyphs and this spec went blind")
end)

T.spec("every declared coordinate is on the grid", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local G = world.req("Config").UI.Icon.Grid

	-- Read off the DECLARATIONS rather than off the built frames, because a part
	-- pushed past the edge of the grid is still a Frame at a Position the mock
	-- will happily store. A glyph drawn outside its own box overlaps whatever is
	-- next to it, which on the rail and in a shop row is another glyph.
	local checked = 0
	for _, name in ipairs(UiKit.iconNames()) do
		local glyph = UiKit.ICONS[name]
		for _, part in ipairs(glyph.parts or glyph) do
			local points = part.kind == "bar"
				and { { part.x1, part.y1 }, { part.x2, part.y2 } }
				or { { part.x, part.y }, { part.x + part.w, part.y + part.h } }
			for _, point in ipairs(points) do
				for _, value in ipairs(point) do
					checked += 1
					t:isTrue(value >= 0 and value <= G,
						("icon %q declares a %s at %s, outside the 0-%d grid")
							:format(name, part.kind, tostring(value), G))
				end
			end
		end
	end
	t:gt(checked, 0, "no coordinates were read — the registry's shape changed and this spec went blind")
end)

T.spec("a heavier part is a WHOLE multiple of the glyph's weight", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")

	-- Declared rather than drawn, because a fraction is visible here and not in
	-- the built frame: 2.2 against a weight of 3 rounds to 7, which is not a
	-- multiple of anything and is exactly the drift the shared weight prevents.
	local bars = 0
	for _, name in ipairs(UiKit.iconNames()) do
		local glyph = UiKit.ICONS[name]
		for _, part in ipairs(glyph.parts or glyph) do
			if part.kind == "bar" then
				bars += 1
				t:eq(part.thick, math.floor(part.thick),
					("icon %q declares a bar at %s times the glyph weight; a fraction rounds to a thickness that is a multiple of nothing")
						:format(name, tostring(part.thick)))
				t:gt(part.thick, 0, ("icon %q declares a bar at %s times the weight"):format(name, tostring(part.thick)))
			end
		end
	end
	t:gt(bars, 0, "no bars were declared — the registry changed shape and this spec went blind")
end)

T.spec("an unknown glyph is an error, never an empty frame", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local into = surface(world)
	t:raises(function()
		UiKit.icon(into, "definitely-not-a-glyph", 24, Color3.fromRGB(255, 255, 255))
	end, "unknown icon")
end)

T.spec("a cut part draws in the hole colour, not in the ink", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local ink = Color3.fromRGB(255, 255, 255)
	local hole = Color3.fromRGB(1, 2, 3)

	-- personPlus is the one glyph with cut parts: the plus is meant to read as
	-- punched through the disc rather than as a third colour on top of it.
	local glyph = UiKit.icon(surface(world), "personPlus", 40, ink, hole)
	local cuts = 0
	for _, part in ipairs(parts(glyph)) do
		if part.BackgroundColor3 == hole then
			cuts += 1
		end
	end
	t:eq(cuts, 2,
		("the invite glyph drew %d parts in the hole colour; the plus is two bars and both are holes"):format(cuts))
end)

T.spec("the glyph holder clips only where the drawing runs off the picture", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")

	-- The person's torso is a full rounded rectangle with its bottom half
	-- outside the frame; without the clip it is a pill floating under a head.
	local person = UiKit.icon(surface(world), "personPlus", 40, Color3.fromRGB(255, 255, 255))
	t:isTrue(person.ClipsDescendants, "the invite glyph stopped clipping — its torso is a pill again")

	local coin = UiKit.icon(surface(world), "coin", 40, Color3.fromRGB(255, 255, 255))
	t:isFalse(coin.ClipsDescendants,
		"the coin clips, which costs a render pass for a drawing entirely inside its own box")
end)

end
