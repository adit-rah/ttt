--[[
	MapBuilder.lua — generates the whole world at runtime.

	Layout: a central open-air arena (PvP + raid target) ringed by
	Config.World.PlotCount tycoon plots, each rotated to face inward.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local TungModels = Req("TungModels")

local Lighting = game:GetService("Lighting")

local MapBuilder = {}

local W = Config.World

local PALETTE = {
	ground   = Color3.fromRGB(106, 168, 79),   -- grass
	pad      = Color3.fromRGB(199, 195, 185),  -- light concrete
	padEdge  = Color3.fromRGB(255, 176, 60),   -- warm marker stripe
	arena    = Color3.fromRGB(178, 172, 160),
	arenaLip = Color3.fromRGB(255, 140, 40),
	wood     = Color3.fromRGB(150, 103, 60),
}

local function newPart(parent, name, size, cf, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Stock Roblox daylight. Deliberately plain: bright, neutral and readable.
function MapBuilder.applyLighting()
	-- Lighting.Technology is not script-writable at runtime; it is set in
	-- default.project.json instead. Guarded so a manual/paste-in install
	-- doesn't take the whole boot sequence down with it.
	pcall(function()
		Lighting.Technology = Enum.Technology.ShadowMap
	end)
	Lighting.Ambient = Color3.fromRGB(0, 0, 0)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
	Lighting.Brightness = 3
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 41.733
	Lighting.ExposureCompensation = 0
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	Lighting.FogColor = Color3.fromRGB(192, 192, 192)
	Lighting.FogStart = 0
	Lighting.FogEnd = 100000
	Lighting.GlobalShadows = true

	-- strip anything a previous (darker) build left behind, so re-running
	-- doesn't stack post-effects
	for _, existing in ipairs(Lighting:GetChildren()) do
		if existing:IsA("Atmosphere") or existing:IsA("PostEffect") then
			existing:Destroy()
		end
	end
end

--- Returns the CFrame for plot `index` (1-based). +Z of the CFrame points
--- at the arena, matching the plot-local layout in Config.
function MapBuilder.plotCFrame(index: number): CFrame
	local placement = W.PlotPlacements[index] or W.PlotPlacements[1]
	local angle, radius = placement.angle, placement.radius
	-- y = PlotSurfaceY, so plot-local y=0 is the top of the pad and sits
	-- clear of the ground plane instead of z-fighting with it
	local position = Vector3.new(math.sin(angle) * radius, W.PlotSurfaceY, math.cos(angle) * radius)
	-- look at the origin, then flip so plot-local +Z faces the arena
	local look = CFrame.lookAt(position, Vector3.new(0, 0, 0))
	return look * CFrame.Angles(0, math.pi, 0)
end

-- MVP arena: a floor, a low plinth, the statue and a sign. The torches, the
-- 32-segment glowing rim and the 72-tile ring path were all decoration with
-- no gameplay attached, so they are gone.
local function buildArena(parent: Instance)
	local arena = Instance.new("Model")
	arena.Name = "Arena"
	arena.Parent = parent

	local floorThickness = 3
	local floor = newPart(arena, "ArenaFloor", Vector3.new(floorThickness, W.ArenaRadius * 2, W.ArenaRadius * 2),
		CFrame.new(0, W.ArenaFloorTopY - floorThickness / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		PALETTE.arena, Enum.Material.Pebble)
	floor.Shape = Enum.PartType.Cylinder

	-- single ring border instead of 32 separate segments
	local rim = newPart(arena, "Rim", Vector3.new(1.2, W.ArenaRadius * 2 + 6, W.ArenaRadius * 2 + 6),
		CFrame.new(0, W.ArenaFloorTopY - 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
		PALETTE.arenaLip, Enum.Material.Neon)
	rim.Shape = Enum.PartType.Cylinder
	rim.CanCollide = false

	local daisHeight = 4
	local daisTopY = W.ArenaFloorTopY + daisHeight
	local dais = newPart(arena, "Dais", Vector3.new(daisHeight, 26, 26),
		CFrame.new(0, daisTopY - daisHeight / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		PALETTE.pad, Enum.Material.Slate)
	dais.Shape = Enum.PartType.Cylinder

	-- The statue's feet are 2.85 * scale below its pivot (see TungModels), and
	-- the infinity variant carries its own 1.5x scale. Stand it ON the dais
	-- instead of guessing a height and burying its legs in the platform.
	local statueScale = 3.5
	local footDrop = 2.85 * statueScale * Config.Variants.infinity.scale
	local statue = TungModels.buildStatue("infinity", statueScale)
	statue.Name = "ArenaStatue"
	statue:PivotTo(CFrame.new(0, daisTopY + footDrop, 0))
	statue.Parent = arena

	local sign = newPart(arena, "TitleAnchor", Vector3.new(1, 1, 1), CFrame.new(0, 34, 0), PALETTE.pad)
	sign.Transparency = 1
	sign.CanCollide = false

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(56, 14)
	billboard.MaxDistance = 900
	billboard.Parent = sign

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.62)
	title.Font = Enum.Font.FredokaOne
	title.Text = "TUNG TUNG TYCOON"
	title.TextColor3 = Color3.fromRGB(255, 214, 90)
	title.TextStrokeColor3 = Color3.fromRGB(46, 32, 16)
	title.TextStrokeTransparency = 0.1
	title.TextScaled = true
	title.Parent = billboard

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromScale(0, 0.62)
	subtitle.Size = UDim2.fromScale(1, 0.34)
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.Text = "pvp enabled inside the ring"
	subtitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	subtitle.TextStrokeColor3 = Color3.fromRGB(46, 32, 16)
	subtitle.TextStrokeTransparency = 0.4
	subtitle.TextScaled = true
	subtitle.Parent = billboard

	return arena
end

local function buildSpawn(parent: Instance)
	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "TungSpawn"
	spawnPad.Size = Vector3.new(36, 1.5, 24)
	-- in FRONT of the dais, not on top of it: spawning at the origin puts
	-- players inside the statue's legs
	spawnPad.CFrame = CFrame.new(0, W.ArenaFloorTopY + 0.75, 52)
	spawnPad.Anchored = true
	spawnPad.CanCollide = true
	spawnPad.Color = Color3.fromRGB(150, 103, 60)
	spawnPad.Material = Enum.Material.WoodPlanks
	spawnPad.TopSurface = Enum.SurfaceType.Smooth
	spawnPad.Duration = 0
	spawnPad.Neutral = true
	spawnPad.Parent = parent
	return spawnPad
end

function MapBuilder.build(): Folder
	local existing = workspace:FindFirstChild("TungWorld")
	if existing then
		existing:Destroy()
	end

	-- clear the default baseplate if the place still has one
	local defaultBase = workspace:FindFirstChild("Baseplate")
	if defaultBase then
		defaultBase:Destroy()
	end

	local world = Instance.new("Folder")
	world.Name = "TungWorld"
	world.Parent = workspace

	local groundThickness = 12
	local ground = newPart(world, "Ground", Vector3.new(W.BaseplateSize, groundThickness, W.BaseplateSize),
		CFrame.new(0, W.GroundTopY - groundThickness / 2, 0), PALETTE.ground, Enum.Material.Grass)
	ground.Anchored = true

	buildArena(world)
	buildSpawn(world)

	local plots = Instance.new("Folder")
	plots.Name = "Plots"
	plots.Parent = world

	MapBuilder.applyLighting()

	return world
end

--- Builds the flat pad + signage for one plot. The tycoon machinery is added
--- later by Tycoon.lua; this is just the real estate.
function MapBuilder.buildPlotPad(parent: Instance, index: number): (Model, CFrame)
	local cf = MapBuilder.plotCFrame(index)

	local model = Instance.new("Model")
	model.Name = "Plot" .. index
	model.Parent = parent

	local pad = newPart(model, "Pad", W.PlotSize, cf * CFrame.new(0, -W.PlotSize.Y / 2, 0), PALETTE.pad, Enum.Material.Concrete)
	pad:SetAttribute("PlotIndex", index)

	-- glowing border. The pad is no longer square, so the front/back strips key
	-- off half the DEPTH and the side strips off half the width; using one
	-- `half` for both left the front and back edges floating inside the pad.
	local half = W.PlotSize.X / 2
	local halfZ = W.PlotSize.Z / 2
	local edges = {
		{ Vector3.new(W.PlotSize.X, 1, 2), CFrame.new(0, 0.2, halfZ) },
		{ Vector3.new(W.PlotSize.X, 1, 2), CFrame.new(0, 0.2, -halfZ) },
		{ Vector3.new(2, 1, W.PlotSize.Z), CFrame.new(half, 0.2, 0) },
		{ Vector3.new(2, 1, W.PlotSize.Z), CFrame.new(-half, 0.2, 0) },
	}
	for i, edge in ipairs(edges) do
		local e = newPart(model, "Edge" .. i, edge[1], cf * edge[2], PALETTE.padEdge, Enum.Material.Neon)
		e.CanCollide = false
	end

	-- Claim totem, parked in the front-RIGHT corner. It used to stand at x = 0,
	-- directly on top of the pad you are meant to step on, and then in the
	-- front-left corner, which is where Tycoon builds the vault — the two
	-- models were interpenetrating on every plot.
	local totemCF = cf * CFrame.new(half - 12, 6, halfZ - 8)
	local totem = newPart(model, "Totem", Vector3.new(4, 12, 4), totemCF, Color3.fromRGB(70, 52, 40), Enum.Material.Wood)
	totem:SetAttribute("PlotIndex", index)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Sign"
	billboard.Size = UDim2.fromScale(26, 9)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	billboard.MaxDistance = 500
	billboard.AlwaysOnTop = false
	billboard.Parent = totem

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(24, 18, 34)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = billboard
	Util.roundedFrame(frame, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = PALETTE.padEdge
	stroke.Thickness = 3
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Owner"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.92, 0.9)
	label.Position = UDim2.fromScale(0.04, 0.05)
	label.Font = Enum.Font.FredokaOne
	label.Text = "UNCLAIMED PLOT " .. index .. "\nstep on the pad to claim"
	label.TextColor3 = Color3.fromRGB(255, 236, 180)
	label.TextScaled = true
	label.Parent = frame

	return model, cf
end

return MapBuilder
