--[[
	Style.lua — the one place that turns Config.Style into instances.

	Every label this game draws, in the world and on the screen, comes through
	here. Before it existed each site picked its own font, its own outline and
	its own view distance as it was written, which is how the plot ended up
	using three fonts, six outline settings and eleven view distances from 90
	studs to 1200 — none of them chosen against each other.

	WHY A MODULE AND NOT JUST CONSTANTS. Constants would have fixed the values
	and left the *shape* free: one site setting LightInfluence and the next
	forgetting, one billboard with StudsOffsetWorldSpace and the next without.
	The point of a builder is that the site cannot leave a field out. What a
	caller still gets to choose is what a label IS — its size, its colour, and
	how far away it stops mattering — and nothing else.

	tools/verify.py fails the build if `Enum.Font`, `TextStrokeTransparency` or
	`MaxDistance` appears anywhere in src/ outside this file. That lint is the
	only reason this stays true; the state it replaced is what happens without
	one.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local S = Config.Style

local Style = {}

--- The two faces. `title` is the display face — names, headlines, anything you
--- read at a glance from across the plot. `body` is everything else: prices,
--- step counters, blurbs, the small print on a panel.
Style.Font = {
	title = (Enum.Font :: any)[S.TitleFont],
	body  = (Enum.Font :: any)[S.BodyFont],
}

--- Named view distances, resolved. Anything that wants a number reads
--- `Style.distance("prop")` rather than writing 220.
function Style.distance(tier: string): number
	local value = S.Distance[tier]
	if not value then
		-- Loud rather than silent: a typo'd tier that fell back to a default
		-- would be a label that quietly renders at the wrong range forever,
		-- which is exactly the class of bug this module exists to end.
		error(("[Tung] unknown view-distance tier %q; expected one of machine/prop/plot/world"):format(tostring(tier)), 2)
	end
	return value
end

--- A world-space label anchor.
---
---   width, height   studs (BillboardGui scale maps 1:1 to studs)
---   distance        a Config.Style.Distance key
---   offset          studs straight up from the adornee, world-space
---   alwaysOnTop     draws through geometry. Two things in this game are
---                   allowed it — damage numbers and enemy nameplates — and
---                   the nameplates are Roblox's own. Everything else obeys
---                   walls, which is the whole point of hiding behind one.
function Style.billboard(parent: Instance, opts): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = opts.name or "Label"
	gui.Size = UDim2.fromScale(opts.width, opts.height)
	gui.MaxDistance = Style.distance(opts.distance)
	gui.AlwaysOnTop = opts.alwaysOnTop == true
	gui.LightInfluence = S.LightInfluence
	if opts.offset then
		gui.StudsOffsetWorldSpace = Vector3.new(0, opts.offset, 0)
	end
	gui.Parent = parent
	return gui
end

--- A line of world text. Defaults to filling its billboard, because most of
--- them hold exactly one line; the buy button is the only label with enough to
--- say that it needs its own layout.
function Style.text(parent: Instance, opts): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = opts.name or "Text"
	label.BackgroundTransparency = 1
	label.Size = opts.size or UDim2.fromScale(1, 1)
	if opts.position then
		label.Position = opts.position
	end
	label.Font = (opts.weight == "body") and Style.Font.body or Style.Font.title
	label.Text = opts.text or ""
	label.TextColor3 = opts.color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = S.StrokeTransparency
	label.TextStrokeColor3 = S.StrokeColor
	label.TextScaled = opts.scaled ~= false
	label.Parent = parent
	return label
end

--- Retunes a live billboard's view distance. Some labels have more than one
--- voice — a locked buy button drops out of sight sooner than a buyable one —
--- and the tier still has to come from here rather than from a number written
--- at the call site.
function Style.setDistance(gui: BillboardGui, tier: string)
	gui.MaxDistance = Style.distance(tier)
end

--- Fades a label, outline included.
---
--- The outline has to fade WITH the text or a dimmed label keeps its hard dark
--- edge and ends up reading as MORE contrasty than the bright one it was
--- supposed to recede behind — which is the exact opposite of the point.
function Style.fade(label: TextLabel, alpha: number)
	label.TextTransparency = alpha
	label.TextStrokeTransparency = alpha + (1 - alpha) * S.StrokeTransparency
end

return Style
