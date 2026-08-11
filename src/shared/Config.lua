--[[
	Config.lua — every tunable number in Tung Tung Tycoon lives here.

	The tycoon is DATA DRIVEN. To add content you add a table entry below;
	you should never need to touch the tycoon runtime to add a dropper,
	an upgrader, or a new tier. That is the "standardized tycoon system".
]]

local Config = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- WORLD
-- ─────────────────────────────────────────────────────────────────────────────

Config.World = {
	-- Plot count is derived from the place's player cap at the bottom of this
	-- file, so every player who can join has somewhere to build.
	MinPlots = 6,
	MaxPlots = 24,           -- geometry budget ceiling; raise MaxPlayers to match
	PlotGap = 20,            -- clear studs between neighbouring plot edges
	RingGap = 24,            -- clear studs between concentric plot rings
	MinPlotRadius = 180,     -- how far the FIRST ring sits from the centre

	PlotSize = Vector3.new(88, 2, 104),
	BaseplateSize = 1800,
	ArenaRadius = 70,
	ArenaWallHeight = 22,

	-- Stacked surface heights. Every horizontal surface in the world gets its
	-- OWN height: two coplanar faces at the same Y is exactly what produces
	-- the shimmering/tearing you see when the camera moves.
	GroundTopY     = 0,
	ArenaFloorTopY = 0.30,
	PlotSurfaceY   = 0.60,   -- plot-local y = 0 lives here, not on the ground
}

--- Where each plot sits: { radius, angle, ring }.
---
--- A single ring would work, but its radius grows linearly with the plot
--- count — 24 plots on one ring puts the far plots 650 studs out, which is a
--- 35-second walk. Instead we fill an inner ring first and only start a
--- second ring once the first is full, so most players stay close to spawn.
function Config.plotPlacements(count: number)
	local pitch = Config.World.PlotSize.X + Config.World.PlotGap
	local depth = Config.World.PlotSize.Z + Config.World.RingGap

	local placements = {}
	local remaining = count
	local ring = 0

	while remaining > 0 do
		local radius = Config.World.MinPlotRadius + ring * depth
		local capacity = math.max(1, math.floor((2 * math.pi * radius) / pitch))
		local take = math.min(remaining, capacity)

		for i = 1, take do
			table.insert(placements, {
				radius = radius,
				-- stagger alternate rings so plots don't line up radially
				angle = (i - 1) * (2 * math.pi / take) + ((ring % 2 == 1) and (math.pi / take) or 0),
				ring = ring + 1,
			})
		end

		remaining -= take
		ring += 1
	end

	return placements
end

--- How many plots this server should build. Reads the place's player cap so a
--- 12-player server gets 12 factories, clamped to the geometry budget.
function Config.plotCountFor(playerCap: number?): number
	local cap = playerCap
	if not cap then
		local ok, maxPlayers = pcall(function()
			return game:GetService("Players").MaxPlayers
		end)
		cap = (ok and type(maxPlayers) == "number" and maxPlayers > 0) and maxPlayers or Config.World.MinPlots
	end
	return math.clamp(math.floor(cap), Config.World.MinPlots, Config.World.MaxPlots)
end

-- Plot-local layout. Plot origin = centre of the pad, floor top at y = 0.
-- +Z is "front" (faces the arena), -Z is the back where droppers live.
-- The belt runs as an L around the back and left edges of the plot rather than
-- straight through the middle. That keeps the centre of the plot as open floor,
-- puts every machine against a wall, and lines the buy buttons up along the
-- inside of the run where you actually walk.
--
--        back edge
--    +---------------+
--    |=====<=========|  <- leg 1: droppers
--    |v              |
--    |v              |     (open floor)
--    |v              |
--    |v  leg 2:      |
--    |v  upgraders   |
--    |[VAULT]        |
--    +---------------+
--        front edge (faces the arena)
Config.Layout = {
	BeltStart  = Vector3.new( 32, 0, -40),   -- back-right corner
	BeltCorner = Vector3.new(-30, 0, -40),   -- back-left corner
	BeltEnd    = Vector3.new(-30, 0,  30),   -- front-left
	CollectorAt = Vector3.new(-30, 0, 40),

	BeltY = 1.4,             -- TOP of the belt surface; low enough to step onto
	BeltWidth = 8,
	-- Fast enough that the belt never runs bumper-to-bumper. At 14 the peak
	-- spawn rate put ~80 drops in flight against a 70 cap: the belt was over
	-- capacity and jammed on its own. verify_config models this.
	BeltSpeed = 22,          -- studs/sec, base

	MachineOffset = 7,       -- droppers/upgraders sit this far OUTBOARD of the belt
	ButtonOffset = 9,        -- buy buttons sit this far INBOARD, facing the floor
	ButtonHeight = 1.4,      -- total button height; must be low enough to run over
	MachineFootprint = 5,    -- machines are this deep along the belt

	-- distance along leg 1 (back edge) for dropper slot 1..10
	DropperDist  = { 4, 10, 16, 22, 28, 34, 40, 46, 52, 58 },
	-- distance along leg 2 (left edge) for upgrader slot 1..6
	UpgraderDist = { 10, 21, 32, 43, 54, 65 },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- ECONOMY
-- ─────────────────────────────────────────────────────────────────────────────

Config.Economy = {
	CurrencyName = "Tung",
	-- MUST be >= the cheapest button with no requirements, or a fresh player
	-- has no income and no way to ever buy their first dropper.
	StartingCash = 100,
	DropLifetime = 45,          -- seconds before an orphaned drop despawns
	MaxDropsPerPlot = 70,       -- hard cap so a mega-tycoon can't melt the server
	OfflineGraceSeconds = 180,  -- keep a plot reserved this long after a disconnect
}

Config.Rebirth = {
	-- ~10 minutes of fully-built income. Full build is ~87 min (see
	-- tools/verify_config.lua, which prints the modelled curve).
	BaseCost = 25e9,
	CostGrowth = 3.0,           -- cost multiplier per rebirth
	MultiplierPerRebirth = 2.25, -- payout multiplier is this ^ rebirths
	MaxRebirths = 25,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- TUNG VARIANTS
-- Each variant is a visual + audio recipe used by both the dropper's spout
-- and the little bat-guy that rides the conveyor.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Variants = {
	classic = {
		wood       = Color3.fromRGB(150, 103, 60),
		accent     = Color3.fromRGB(96, 62, 33),
		eye        = Color3.fromRGB(250, 250, 250),
		material   = Enum.Material.Wood,
		scale      = 1.0,
		fx         = "none",
		light      = nil,
	},
	oak = {
		wood       = Color3.fromRGB(122, 84, 48),
		accent     = Color3.fromRGB(74, 48, 26),
		eye        = Color3.fromRGB(255, 240, 200),
		material   = Enum.Material.WoodPlanks,
		scale      = 1.06,
		fx         = "sparkle",
		light      = nil,
	},
	ash = {
		wood       = Color3.fromRGB(196, 160, 112),
		accent     = Color3.fromRGB(120, 92, 55),
		eye        = Color3.fromRGB(255, 255, 255),
		material   = Enum.Material.Wood,
		scale      = 1.12,
		fx         = "dust",
		light      = nil,
	},
	golden = {
		wood       = Color3.fromRGB(240, 190, 60),
		accent     = Color3.fromRGB(176, 128, 22),
		eye        = Color3.fromRGB(255, 252, 220),
		material   = Enum.Material.Metal,
		scale      = 1.16,
		fx         = "sparkle",
		light      = { color = Color3.fromRGB(255, 205, 90), range = 9, brightness = 1.4 },
	},
	crimson = {
		wood       = Color3.fromRGB(154, 34, 42),
		accent     = Color3.fromRGB(88, 16, 22),
		eye        = Color3.fromRGB(255, 138, 138),
		material   = Enum.Material.Slate,
		scale      = 1.2,
		fx         = "embers",
		light      = { color = Color3.fromRGB(255, 90, 70), range = 11, brightness = 2 },
	},
	neon = {
		wood       = Color3.fromRGB(40, 240, 200),
		accent     = Color3.fromRGB(10, 130, 120),
		eye        = Color3.fromRGB(240, 255, 255),
		material   = Enum.Material.Neon,
		scale      = 1.24,
		fx         = "pulse",
		light      = { color = Color3.fromRGB(60, 255, 220), range = 13, brightness = 2.4 },
	},
	void = {
		wood       = Color3.fromRGB(46, 28, 78),
		accent     = Color3.fromRGB(18, 10, 34),
		eye        = Color3.fromRGB(196, 120, 255),
		material   = Enum.Material.Glass,
		scale      = 1.3,
		fx         = "void",
		light      = { color = Color3.fromRGB(150, 70, 255), range = 15, brightness = 3 },
	},
	eclipse = {
		wood       = Color3.fromRGB(24, 24, 30),
		accent     = Color3.fromRGB(255, 148, 40),
		eye        = Color3.fromRGB(255, 190, 90),
		material   = Enum.Material.Neon,
		scale      = 1.36,
		fx         = "eclipse",
		light      = { color = Color3.fromRGB(255, 150, 45), range = 18, brightness = 3.4 },
	},
	galaxy = {
		wood       = Color3.fromRGB(70, 92, 220),
		accent     = Color3.fromRGB(190, 120, 255),
		eye        = Color3.fromRGB(255, 255, 255),
		material   = Enum.Material.Neon,
		scale      = 1.42,
		fx         = "galaxy",
		light      = { color = Color3.fromRGB(120, 150, 255), range = 20, brightness = 3.8 },
	},
	infinity = {
		wood       = Color3.fromRGB(255, 255, 255),
		accent     = Color3.fromRGB(255, 215, 90),
		eye        = Color3.fromRGB(120, 255, 255),
		material   = Enum.Material.Neon,
		scale      = 1.5,
		fx         = "infinity",
		light      = { color = Color3.fromRGB(255, 255, 255), range = 24, brightness = 5 },
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- THE BUTTON TABLE — this IS the tycoon.
--
--  id        unique key, also used as the save key
--  name      shown on the button billboard
--  price     cost in Tung
--  kind      "Dropper" | "Upgrader" | "Belt" | "Structure" | "Gear"
--  requires  id (or list of ids) that must be owned first; nil = available at spawn
--  slot      position index into Layout.DropperZ / Layout.UpgraderZ
--
--  Dropper:  variant, dropValue, dropRate (seconds between drops)
--  Upgrader: variant, multiplier
--  Belt:     speedBonus
--  Gear:     grants (bat tier id)
-- ─────────────────────────────────────────────────────────────────────────────

Config.Buttons = {
	{
		id = "dropper1", name = "Tung Dropper", price = 50,
		kind = "Dropper", slot = 1, variant = "classic",
		dropValue = 1, dropRate = 1.5,
		blurb = "tung.",
	},
	{
		id = "dropper2", name = "Tung Tung Dropper", price = 75,
		kind = "Dropper", slot = 2, variant = "oak", requires = "dropper1",
		dropValue = 4, dropRate = 1.5,
		blurb = "tung tung.",
	},
	{
		id = "upgrader1", name = "Drum Roll Refiner", price = 250,
		kind = "Upgrader", slot = 1, variant = "oak", requires = "dropper2",
		multiplier = 1.6,
		blurb = "A little sahur percussion. x1.6",
	},
	{
		id = "dropper3", name = "Tung Tung Tung Dropper", price = 500,
		kind = "Dropper", slot = 3, variant = "ash", requires = "upgrader1",
		dropValue = 12, dropRate = 1.4,
		blurb = "tung tung tung.",
	},
	{
		id = "walls", name = "Plot Walls", price = 1500,
		kind = "Structure", requires = "dropper3", structure = "walls",
		blurb = "Keeps the raiders honest.",
	},
	{
		id = "dropper4", name = "Golden Tung", price = 2500,
		kind = "Dropper", slot = 4, variant = "golden", requires = "walls",
		dropValue = 40, dropRate = 1.4,
		blurb = "Sahur, but expensive.",
	},
	{
		id = "upgrader2", name = "Sahur Bat Upgrader", price = 8500,
		kind = "Upgrader", slot = 2, variant = "golden", requires = "dropper4",
		multiplier = 1.85,
		blurb = "Whacks value into them. x1.85",
	},
	{
		id = "batforge", name = "Bat Forge", price = 17000,
		kind = "Gear", requires = "upgrader2", grants = "oak",
		blurb = "Unlocks the Oak Sahur Bat.",
	},
	{
		id = "dropper5", name = "Crimson Tung", price = 25000,
		kind = "Dropper", slot = 5, variant = "crimson", requires = "batforge",
		dropValue = 150, dropRate = 1.3,
		blurb = "It has seen things.",
	},
	{
		id = "belt1", name = "Belt Overdrive", price = 80000,
		kind = "Belt", requires = "dropper5", speedBonus = 9,
		blurb = "Conveyor goes brrrr.",
	},
	{
		id = "upgrader3", name = "Tralalero Refiner", price = 100000,
		kind = "Upgrader", slot = 3, variant = "crimson", requires = "belt1",
		multiplier = 2.1,
		blurb = "Sharks approve. x2.1",
	},
	{
		id = "dropper6", name = "Neon Tung", price = 250000,
		kind = "Dropper", slot = 6, variant = "neon", requires = "upgrader3",
		dropValue = 620, dropRate = 1.25,
		blurb = "3am energy drink sahur.",
	},
	{
		id = "roof", name = "Sahur Roof + Sign", price = 1000000,
		kind = "Structure", requires = "dropper6", structure = "roof",
		blurb = "Now it's a real business.",
	},
	{
		id = "dropper7", name = "Void Tung", price = 1250000,
		kind = "Dropper", slot = 7, variant = "void", requires = "roof",
		dropValue = 2600, dropRate = 1.2,
		blurb = "tung from beyond.",
	},
	{
		id = "upgrader4", name = "Void Furnace", price = 6000000,
		kind = "Upgrader", slot = 4, variant = "void", requires = "dropper7",
		multiplier = 2.4,
		blurb = "Melts them into money. x2.4",
	},
	{
		id = "batforge2", name = "Void Bat Forge", price = 14000000,
		kind = "Gear", requires = "upgrader4", grants = "void",
		blurb = "Unlocks the Void Sahur Bat.",
	},
	{
		id = "dropper8", name = "Eclipse Tung", price = 18000000,
		kind = "Dropper", slot = 8, variant = "eclipse", requires = "batforge2",
		dropValue = 11000, dropRate = 1.15,
		blurb = "Sahur at the end of the night.",
	},
	{
		id = "upgrader5", name = "Eclipse Ascension", price = 80000000,
		kind = "Upgrader", slot = 5, variant = "eclipse", requires = "dropper8",
		multiplier = 2.8,
		blurb = "Ascends the tung. x2.8",
	},
	{
		id = "dropper9", name = "Galaxy Tung", price = 250000000,
		kind = "Dropper", slot = 9, variant = "galaxy", requires = "upgrader5",
		dropValue = 48000, dropRate = 1.1,
		blurb = "tung tung tung across the stars.",
	},
	{
		id = "upgrader6", name = "Tung Singularity", price = 1200000000,
		kind = "Upgrader", slot = 6, variant = "galaxy", requires = "dropper9",
		multiplier = 3.4,
		blurb = "Do not look directly at it. x3.4",
	},
	{
		id = "dropper10", name = "INFINITY TUNG TUNG TUNG SAHUR", price = 5000000000,
		kind = "Dropper", slot = 10, variant = "infinity", requires = "upgrader6",
		dropValue = 240000, dropRate = 1.0,
		blurb = "TUNG TUNG TUNG TUNG TUNG TUNG SAHUR",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- COMBAT
-- ─────────────────────────────────────────────────────────────────────────────

Config.Bats = {
	-- order matters: index = tier, higher tier replaces lower
	{ id = "starter", name = "Sahur Bat",      variant = "classic", damage = 18, cooldown = 0.55, knockback = 55,  reach = 9,  crit = 0.08 },
	{ id = "oak",     name = "Oak Sahur Bat",  variant = "golden",  damage = 34, cooldown = 0.5,  knockback = 75,  reach = 10, crit = 0.14 },
	{ id = "void",    name = "Void Sahur Bat", variant = "void",    damage = 62, cooldown = 0.44, knockback = 105, reach = 11.5, crit = 0.22 },
}

Config.Combat = {
	ComboWindow = 1.6,          -- seconds to chain a swing
	ComboMaxStacks = 4,
	ComboDamagePerStack = 0.18, -- +18% per stack
	HitboxSize = Vector3.new(7, 7, 1),
	ArenaPvP = true,            -- PvP only inside the arena ring
	RespawnCash = 0,            -- cash lost on death (0 = friendly)
}

Config.Waves = {
	Enabled = true,
	FirstWaveDelay = 90,
	Interval = 210,             -- seconds between waves
	WarningTime = 12,
	BaseCount = 4,
	CountPerWave = 2,
	MaxCount = 26,
	BaseHealth = 90,
	HealthGrowth = 1.20,        -- wave 20 raider ~2.9k HP: ~13s for one player
	BaseDamage = 9,
	DamageGrowth = 1.07,
	MaxDamage = 34,             -- a player has 100 HP; never let a raider 2-shot
	BossHealthMultiplier = 6,
	BossDamageMultiplier = 1.8,
	WalkSpeed = 13,
	RewardBase = 150,
	RewardGrowth = 2.3,         -- reward scales with wave number
	StealPerHit = 0.006,        -- fraction of a player's cash a raider steals on hit
	BossEvery = 5,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Derived lookups (built once at require time)
-- ─────────────────────────────────────────────────────────────────────────────

-- Resolved once, at require time, so every module sees the same numbers.
Config.World.PlotCount = Config.plotCountFor()
Config.World.PlotPlacements = Config.plotPlacements(Config.World.PlotCount)
Config.World.PlotRadius = Config.World.PlotPlacements[1].radius   -- inner ring

Config.ButtonById = {}
for index, def in ipairs(Config.Buttons) do
	def.order = index
	Config.ButtonById[def.id] = def
end

Config.BatById = {}
for tier, def in ipairs(Config.Bats) do
	def.tier = tier
	Config.BatById[def.id] = def
end

function Config.requirementsOf(def)
	local req = def.requires
	if req == nil then
		return {}
	elseif type(req) == "string" then
		return { req }
	end
	return req
end

return Config
