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
	--
	-- FEWER, BIGGER PLOTS. 24 small plots packed onto two rings read as one
	-- continuous industrial estate: you could not tell where your factory
	-- ended and your neighbour's began, and the second ring put a third of
	-- the server behind a wall of other people's roofs. Ten plots on a single
	-- ring, each half again as large with double the gap, means every plot is
	-- visibly its own building with open grass around it.
	--
	-- Set the place's MaxPlayers to MaxPlots. It is a Studio setting, not a
	-- scriptable one, so nothing here can enforce it; PlotService just leaves
	-- late joiners plotless until someone disconnects.
	MinPlots = 4,
	MaxPlots = 10,           -- geometry budget ceiling; set MaxPlayers to match
	PlotGap = 44,            -- clear studs between neighbouring plot edges
	RingGap = 48,            -- clear studs between concentric plot rings
	MinPlotRadius = 210,     -- closest the first ring may ever sit to the centre

	PlotSize = Vector3.new(120, 2, 140),
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

-- Most plots a single ring may hold before we start a second one. At MaxPlots
-- = 10 this is never reached, which is the point: everybody lives on one ring,
-- at the same distance from the arena, and can see every other factory. The
-- multi-ring path is kept (and still verified) so raising MaxPlots later
-- degrades gracefully instead of producing a 900-stud ring.
Config.World.MaxPlotsPerRing = 14

--- Where each plot sits: { radius, angle, ring }.
---
--- The ring is sized to the plots on it rather than fixed. Two plots on a ring
--- big enough for fourteen would sit a quarter of the map apart for no reason,
--- and a fixed small radius would bunch fourteen shoulder to shoulder. So we
--- solve for the radius that puts exactly `PlotGap` studs of grass between
--- neighbouring plot EDGES, and only clamp it up to MinPlotRadius so the inner
--- ring never eats the arena.
---
--- Note this is a chord, not an arc: neighbouring plot centres are
--- `2r·sin(π/n)` apart, and using the arc length instead (the old
--- `2πr/pitch` capacity formula) silently under-spaces small rings.
function Config.plotPlacements(count: number)
	local pitch = Config.World.PlotSize.X + Config.World.PlotGap
	local depth = Config.World.PlotSize.Z + Config.World.RingGap

	local placements = {}
	local remaining = count
	local ring = 0
	local previousRadius = nil

	while remaining > 0 do
		local take = math.min(remaining, Config.World.MaxPlotsPerRing)

		-- radius at which the chord between neighbours equals the pitch
		local radius = (take > 1) and (pitch / (2 * math.sin(math.pi / take))) or 0
		radius = math.max(radius, Config.World.MinPlotRadius)
		-- and never closer than a full plot depth + gap to the ring inside it
		if previousRadius then
			radius = math.max(radius, previousRadius + depth)
		end

		for i = 1, take do
			table.insert(placements, {
				radius = radius,
				-- stagger alternate rings so plots don't line up radially
				angle = (i - 1) * (2 * math.pi / take) + ((ring % 2 == 1) and (math.pi / take) or 0),
				ring = ring + 1,
			})
		end

		previousRadius = radius
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
	BeltStart  = Vector3.new( 46, 0, -56),   -- back-right corner
	BeltCorner = Vector3.new(-44, 0, -56),   -- back-left corner
	BeltEnd    = Vector3.new(-44, 0,  46),   -- front-left
	CollectorAt = Vector3.new(-44, 0, 58),

	BeltY = 1.4,             -- TOP of the belt surface; low enough to step onto
	BeltWidth = 8,
	-- Fast enough that the belt never runs bumper-to-bumper. At 14 the peak
	-- spawn rate put ~80 drops in flight against a 70 cap: the belt was over
	-- capacity and jammed on its own. verify_config models this. The bigger
	-- plot lengthened the run from 142 to 206 studs, which is 45% more time in
	-- flight, so this went up with it. Belt speed does not affect income.
	BeltSpeed = 28,          -- studs/sec, base

	MachineOffset = 8,       -- droppers/upgraders sit this far OUTBOARD of the belt
	ButtonOffset = 11,       -- buy buttons sit this far INBOARD, facing the floor
	ButtonHeight = 1.4,      -- total button height; must be low enough to run over
	MachineFootprint = 5,    -- machines are this deep along the belt

	-- distance along leg 1 (back edge) for dropper slot 1..10
	DropperDist  = { 5, 14, 23, 32, 41, 50, 59, 68, 77, 86 },
	-- distance along leg 2 (left edge) for upgrader slot 1..6
	UpgraderDist = { 14, 30, 46, 62, 78, 94 },

	-- Buttons with no machine on the belt stand in a row down the middle of the
	-- open floor, in purchase order, so the aisle you walk reads as a queue.
	MiscButtons = {
		walls     = Vector3.new(8, 0, -34),
		belt1     = Vector3.new(8, 0,  -6),
		roof      = Vector3.new(8, 0,   8),
	},
	MiscButtonSpacing = 14,  -- asserted minimum gap between two MiscButtons

	-- SIDE-TRACK FURNITURE. Each cabinet is a display case standing behind a
	-- column of its own buy buttons, so the right half of the plot reads as an
	-- armoury aisle the way the left half reads as a production line.
	--
	-- Positions are DERIVED from the anchor, exactly like DropperDist: adding a
	-- sixth bat tier should be one row in Config.WeaponButtons and nothing
	-- else. Hand-listing nine more coordinates in MiscButtons would have been
	-- nine more chances to place a collision the verifier then has to catch.
	--
	-- `slots` is the capacity of the column, not the number of buttons in the
	-- track; the verifier asserts the track fits, which is what stops a new
	-- tier silently stacking a pedestal on top of the one before it.
	Tracks = {
		-- weapons stops at 5: a sixth slot lands at z = 36, which is 12.6 studs
		-- from the rebirth pad at (42, 40) and fails MiscButtonSpacing.
		weapons = { cabinetX = 20, buttonX = 30, firstZ = -34, spacing = 14, slots = 5, depth = 4, height = 13 },
		armor   = { cabinetX = 54, buttonX = 44, firstZ = -34, spacing = 14, slots = 4, depth = 4, height = 13 },
	},

	RebirthPadAt = Vector3.new(42, 0, 40),   -- front-right, away from the vault
	ClaimPadAt   = Vector3.new(14, 0, 52),   -- front-centre-right, on the aisle
	-- Where the owner lands on claim and on every respawn: just inside the
	-- gateway, on the aisle, looking down plot-local -Z at the machines.
	OwnerSpawnAt = Vector3.new(14, 5, 44),

	-- The front wall's gateway. It sits over the open aisle on the right, NOT
	-- at x = 0: the belt and the vault occupy the left half of the plot, and a
	-- centred gate would open onto machinery.
	GateCentre = 14,
	GateWidth = 22,
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
-- THE BUTTON TABLES — these ARE the tycoon.
--
-- There are THREE of them, one per track, and each track is a chain that is
-- ordered only against ITSELF. The factory does not gate your bat and your bat
-- does not gate the factory; they are separate systems that happen to share a
-- wallet. Before this split every button `requires`d the one before it in a
-- single 21-long line, so `dropper5` was unreachable until you had bought a
-- weapon and the weapon was unreachable until you had bought `upgrader2`.
--
--  id        unique key, also used as the save key
--  name      shown on the button billboard
--  price     cost in Tung
--  kind      "Dropper" | "Upgrader" | "Belt" | "Structure" | "Gear" | "Armor"
--  requires  id (or list of ids) that must be owned first.
--            OMIT IT on a track table and the loader derives it from the row
--            above — a chain should not have to restate that it is a chain,
--            and a hand-typed `requires` is the most error-prone field here.
--  slot      position index into Layout.DropperDist / Layout.UpgraderDist
--
--  Dropper:  variant, dropValue, dropRate (seconds between drops)
--  Upgrader: variant, multiplier
--  Belt:     speedBonus
--  Gear:     grants (a Config.Bats id)
--  Armor:    grants (a Config.Armor.Tiers id)
--
-- The three tables are merged into a single Config.Buttons at the bottom of
-- this file, in track order, so every consumer still iterates one array.
-- ─────────────────────────────────────────────────────────────────────────────

Config.FactoryButtons = {
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
		id = "dropper5", name = "Crimson Tung", price = 25000,
		kind = "Dropper", slot = 5, variant = "crimson", requires = "upgrader2",
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
		id = "dropper8", name = "Eclipse Tung", price = 18000000,
		kind = "Dropper", slot = 8, variant = "eclipse", requires = "upgrader4",
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

-- ORDER MATTERS: index = tier, and profile.batTier stores that INDEX. Inserting
-- a tier therefore renumbers everything above it, which is why DataService
-- carries a profile-version remap — see LEGACY_BAT_TIERS there. Appending is
-- free; inserting is not.
--
-- ash and crimson slot between oak and void, so every stat on the three
-- original tiers is untouched: this is a longer ladder, not a rebalance.
Config.Bats = {
	{ id = "starter", name = "Sahur Bat",         variant = "classic", damage = 18, cooldown = 0.55, knockback = 55,  reach = 9,    crit = 0.08 },
	{ id = "oak",     name = "Oak Sahur Bat",     variant = "golden",  damage = 34, cooldown = 0.5,  knockback = 75,  reach = 10,   crit = 0.14 },
	{ id = "ash",     name = "Ash Sahur Bat",     variant = "ash",     damage = 42, cooldown = 0.48, knockback = 85,  reach = 10.5, crit = 0.16 },
	{ id = "crimson", name = "Crimson Sahur Bat", variant = "crimson", damage = 52, cooldown = 0.46, knockback = 95,  reach = 11,   crit = 0.19 },
	{ id = "void",    name = "Void Sahur Bat",    variant = "void",    damage = 62, cooldown = 0.44, knockback = 105, reach = 11.5, crit = 0.22 },
	{ id = "eclipse", name = "Eclipse Sahur Bat", variant = "eclipse", damage = 86, cooldown = 0.42, knockback = 130, reach = 12,   crit = 0.26 },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- THE WEAPONS CABINET — the second track.
--
-- These two used to be steps 8 and 16 of the factory chain, which meant your
-- bat was gated on an upgrader and two droppers were gated on your bat. They
-- now stand at their own cabinet on the right of the plot and are ordered only
-- against each other.
--
-- Both are cheaper than they were, and that is a consequence rather than a
-- separate decision: a Gear button priced to sit between `upgrader2` and
-- `dropper5` was priced as a toll on the factory. Nothing tolls anything now,
-- so each one is priced against what it does — buy a better bat when a raid
-- is what is stopping you, not because the belt is waiting on it.
-- ─────────────────────────────────────────────────────────────────────────────

-- Prices are set against the DETOUR the verifier measures: how many minutes of
-- the income you have when a rung first comes within reach it costs you. The
-- ceiling is four minutes, because past that buying a bat means visibly
-- stalling the factory — which is the coupling this whole split removes.
--
-- `batforge` and `batforge2` KEEP THEIR IDS. DataService prunes owned ids it
-- cannot find in Config, so renaming them would silently un-buy every weapon
-- every existing player owns.
Config.WeaponButtons = {
	{
		id = "batforge", name = "Bat Forge", price = 2500,
		kind = "Gear", grants = "oak",
		blurb = "Unlocks the Oak Sahur Bat.",
	},
	{
		id = "batforge_ash", name = "Ash Bat Forge", price = 60000,
		kind = "Gear", grants = "ash",
		blurb = "Unlocks the Ash Sahur Bat.",
	},
	{
		id = "batforge_crimson", name = "Crimson Bat Forge", price = 600000,
		kind = "Gear", grants = "crimson",
		blurb = "Unlocks the Crimson Sahur Bat.",
	},
	{
		id = "batforge2", name = "Void Bat Forge", price = 6000000,
		kind = "Gear", grants = "void",
		blurb = "Unlocks the Void Sahur Bat.",
	},
	{
		id = "batforge_eclipse", name = "Eclipse Bat Forge", price = 120000000,
		kind = "Gear", grants = "eclipse",
		blurb = "Unlocks the Eclipse Sahur Bat.",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- THE ARMOUR CABINET — the third track.
--
-- A tier grants MaxHealth and nothing else. Flat damage reduction was the
-- obvious alternative and is a worse first cut for three reasons: Roblox's
-- default health bar renders a MaxHealth gain for free where reduction is
-- invisible, the default Health script regenerates a PERCENTAGE of MaxHealth so
-- regen scales along for nothing, and — the deciding one — effective HP under
-- both stats is health/(1-dr), two variables multiplying into the single
-- assertion that guarantees a boss cannot burst you down. That assertion
-- currently passes with 0.13s of margin. One monotone stat keeps it one line
-- of arithmetic.
--
-- Reduction stays cheap to add later: CombatService.damage holds the only
-- TakeDamage call in the repo, so there is exactly one place to put it.
--
-- Per-tier FEEL comes from the cabinet — each tier lights its own shelf and
-- stands its own variant — rather than from per-tier stats.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Armor = {
	-- Roblox's default humanoid. Named rather than written as a literal
	-- because verify_config's "a boss cannot two-shot you" assertion used to
	-- hardcode 100, and the moment armour exists that literal stops being a
	-- constant and starts being an assumption.
	BaseHealth = 100,
	-- Ceiling on how tanky the top tier may make you. Armour that makes a boss
	-- cosmetic removes the reason the arena exists.
	MaxHealthMultiple = 3.5,

	-- index = tier, exactly like Config.Bats. Tier 1 is what you spawn with
	-- and is never sold.
	Tiers = {
		{ id = "none",    name = "No Armor",      health = 100, variant = "classic" },
		{ id = "padded",  name = "Padded Sahur",  health = 140, variant = "oak" },
		{ id = "plated",  name = "Plated Sahur",  health = 190, variant = "golden" },
		{ id = "void",    name = "Void Carapace", health = 250, variant = "void" },
		{ id = "eclipse", name = "Eclipse Aegis", health = 320, variant = "eclipse" },
	},
}

Config.ArmorButtons = {
	{
		id = "armor_padded", name = "Padded Sahur", price = 12000,
		kind = "Armor", grants = "padded",
		blurb = "Take a hit and keep walking.",
	},
	{
		id = "armor_plated", name = "Plated Sahur", price = 150000,
		kind = "Armor", grants = "plated",
		blurb = "Bat-resistant.",
	},
	{
		id = "armor_void", name = "Void Carapace", price = 2500000,
		kind = "Armor", grants = "void",
		blurb = "It absorbs the tung.",
	},
	{
		id = "armor_eclipse", name = "Eclipse Aegis", price = 40000000,
		kind = "Armor", grants = "eclipse",
		blurb = "Sahur cannot reach you here.",
	},
}

Config.Combat = {
	ComboWindow = 1.6,          -- seconds to chain a swing
	-- One more swing animation than there are combo stacks, because stack 0 is
	-- the first swing of a chain. Stacks 0,1,2,3 map to SwingAnim.SWINGS 1..4,
	-- so the chain plays diagonal / backhand / sweep / slam and then repeats.
	ComboMaxStacks = 3,
	SwingSteps = 4,             -- must equal #SwingAnim.SWINGS; both sides assert it
	ComboDamagePerStack = 0.18, -- +18% per stack
	HitboxSize = Vector3.new(7, 7, 1),
	ArenaPvP = true,            -- PvP only inside the arena ring
	RespawnCash = 0,            -- cash lost on death (0 = friendly)

	-- SWING TIMING, as fractions of the bat's cooldown. The hitbox used to be
	-- evaluated on the same frame the swing started, i.e. a whole animation
	-- BEFORE the bat visibly reached the target — which is most of why the old
	-- combat read as clicking rather than as hitting. Damage now lands on the
	-- strike frame.
	SwingWindUp = 0.26,         -- fraction spent winding up
	SwingStrikeAt = 0.40,       -- fraction at which the bat is at the end of its arc
	-- The strike is a moving arc, so one instantaneous box misses targets that
	-- are a few frames early or late. Sample twice, this far apart.
	SwingSampleGap = 0.07,
	HitStop = 0.07,             -- seconds the swing freezes on a landed hit

	CritMultiplier = 2,
	CritKnockback = 1.6,

	-- The last step of a combo is the overhead slam. It is slower to reach (it
	-- is the fourth click) so it pays out.
	FinisherDamage = 1.5,
	FinisherKnockback = 1.8,
	FinisherReach = 1.25,

	-- Roblox's default is 16. The plot grew by a third, and 22 keeps the walk
	-- from the gateway to the last dropper at about six seconds. Above ~32 a
	-- humanoid starts clipping through 4-stud walls.
	WalkSpeed = 22,
	JumpPower = 52,
}

Config.Waves = {
	Enabled = true,

	-- PACING. There used to be one number here, `Interval = 210`, and the loop
	-- was `while true do startWave(); task.wait(Interval) end` — no check that
	-- the last wave had been cleared, against a 420s straggler despawn, so two
	-- or three waves legally coexisted and the banner attributed leftovers from
	-- one to another. Waves now run one at a time, and the gap is measured from
	-- YOUR clear rather than from a wall clock.
	FirstWaveDelay = 60,
	-- Quiet time between a wave clearing and the next warning going up. The
	-- real wave-to-wave gap is RestTime + WarningTime + the spawn drip, so
	-- roughly 32 seconds plus however long the fight takes — against the old
	-- fixed ~225.
	RestTime = 20,
	-- A boss wave is the one you actually need to bank and heal after.
	RestTimeAfterBoss = 35,
	-- DO NOT SHORTEN WarningTime TO CLOSE THE GAP. It is load-bearing:
	-- 12 x Combat.WalkSpeed = 264 studs against a MinPlotRadius of 210, which
	-- is what lets a player standing on their own plot get back to the arena
	-- before the raiders land. Shorten RestTime instead; the verifier asserts
	-- this relationship.
	WarningTime = 12,
	-- Deadlock breaker, not a pacing tool. Raider pathfinding is still naive
	-- MoveTo, so one snagged on geometry must not stop the schedule forever.
	-- Note this WILL occasionally cut a legitimately hard solo wave short —
	-- 26 wave-20 raiders is about 340s of solo attention — and that is the
	-- intended trade. The banner says "TIMED OUT" rather than "CLEARED".
	MaxWaveTime = 300,
	-- Per-raider backstop, strictly after the wave deadline so it can only
	-- catch an entry whose wave record was somehow lost.
	StragglerGrace = 45,
	ClearBannerTime = 4,        -- how long CLEARED stays up; must be < RestTime
	SpawnGap = 0.12,            -- between raiders in the drip
	JoinGrace = 20,             -- grace before the first wave on a waking server
	BroadcastInterval = 0.5,    -- coalesce the per-death counter updates
	EmptyResetAfter = 180,      -- empty this long and the wave counter resets

	BaseCount = 4,
	CountPerWave = 2,
	MaxCount = 26,
	BaseHealth = 90,
	HealthGrowth = 1.20,        -- wave 20 raider ~2.9k HP: ~13s for one player
	BaseDamage = 9,
	DamageGrowth = 1.07,
	-- A player has 100 HP. These are ABSOLUTE ceilings: the boss multiplier used
	-- to be applied to the cap as well as to the damage, so a wave-20 boss hit
	-- for 61 and killed a full-health player in two swings — exactly what the
	-- cap was written to prevent.
	MaxDamage = 34,
	MaxBossDamage = 45,
	BossHealthMultiplier = 6,
	BossDamageMultiplier = 1.8,
	WalkSpeed = 13,
	RewardBase = 150,
	RewardGrowth = 2.3,         -- reward scales with wave number
	StealPerHit = 0.006,        -- fraction of a player's cash a raider steals on hit
	BossEvery = 5,

	-- RAIDER ATTACKS. Damage used to land on the same tick the raider decided
	-- to attack, with no wind-up and no animation, so being hit was pure
	-- proximity: you could not see it coming and you could not step out of it.
	-- Raiders now raise the bat, hold, and only then swing — and they stand
	-- still while they do it, which is the window you punish.
	AttackRange = 8,
	AttackWindUp = 0.45,        -- seconds of telegraph before the hit lands
	AttackRecover = 0.35,       -- seconds rooted after swinging
	AttackCooldown = 1.35,
	AttackKnockback = 28,
	BossWindUpScale = 1.35,     -- bosses telegraph LONGER; they hit much harder

	-- RAIDER AI. Every raider used to call nearestPlayer(position, 500) every
	-- 0.6 seconds — a radius bigger than the whole map — so all 26 of them
	-- beelined the same player from anywhere, forever, with no wander, no
	-- aggro range and no way to break contact. They now spawn on the rim, walk
	-- in to a home patch in the arena, mill around it, and only commit to a
	-- player who comes close enough.
	--
	-- The whole design rests on the raiders being SLOWER than the players
	-- (13-17 against 22). Without that gap, de-aggro is unreachable and the
	-- leash is the only thing that ever fires. The verifier asserts it.
	AggroRadius = 55,           -- a raider notices you across its own patch...
	DeAggroRadius = 85,         -- ...and needs a real run to lose you again
	-- Measured from the raider's HOME PATCH, not from where it spawned and not
	-- from the world origin. Home patches are scattered within HomeSpread of
	-- the arena centre, so the furthest a leashed raider can ever swing at
	-- something is HomeSpread + LeashRadius + AttackRange = 124 studs — against
	-- a nearest plot EDGE of 140 (MinPlotRadius 210 less half a plot depth).
	-- That 16-stud clearance is what makes plots provably safe, and it is
	-- asserted rather than commented.
	LeashRadius = 72,
	HomeSpread = 44,            -- home patches fill the arena, clear of the wall
	WanderRadius = 18,          -- 44 + 18 = 62 < ArenaRadius 70
	WanderDwellMin = 2.5,
	WanderDwellMax = 5.0,
	WanderSpeedScale = 0.55,    -- idling is visibly slower; that reads the flip
	ReturnSpeedScale = 1.2,     -- and going home is brisk, so the arena refills
	HomeArrive = 8,
	-- A returning raider must get most of the way back before it can bite
	-- again, or a player parked on the leash line yo-yos it forever.
	ReAggroFrac = 0.6,
	RepathChase = 0.35,         -- a 22 studs/s player covers 7.7 studs; at 0.6 it was 13
	RepathWander = 1.2,
	RepathReturn = 0.8,
	AggroCheck = 0.25,          -- how often an idling raider looks around
	SnapshotInterval = 0.1,     -- how often the shared player snapshot rebuilds
}

-- ─────────────────────────────────────────────────────────────────────────────
-- PROTOTYPES
--
-- Everything below this line is unshipped. Each block is gated by a flag in
-- Config.Prototypes and every one of them defaults to OFF, so a build with all
-- the flags false is byte-for-byte the game that ships today. That is the whole
-- contract: a prototype you cannot turn off is not a prototype, it is a
-- half-finished feature you have to finish before you can ship anything else.
--
-- The rationale for each of these — what shipped where, and what players said
-- about it — is in IDEAS.md. Numbers here are first drafts, not balance.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Prototypes = {
	Floors = false,        -- a second storey with its own dropper -> belt -> vault loop
	PlayerUpgrades = false,-- walkspeed / magnet / cash multiplier shop
	Utilities = false,     -- a second weapon slot holding a verb, not a stat
	RebirthPerks = false,  -- rebirth grants four things instead of one number
	Offline = false,       -- offline earnings and the welcome-back panel
	Sessions = false,      -- daily streak, playtime ladder, boost cooldown
	Sound = false,         -- the engine-asset sound layer
}

-- ── multi-leg belt and floors ────────────────────────────────────────────────
--
-- The shipped belt is hardcoded as an L: two legs, one turn sensor, a 1->2
-- transition written into onTurn. A path is just a list of corners, and every
-- piece of belt geometry already derives from leg(i) — so generalising is
-- mostly deleting the assumption that i is 1 or 2.
--
-- Ground floor path is derived from the shipped Layout keys rather than
-- duplicated, so the two cannot drift.
--- `outboard` carries which SIDE of each leg the machines stand on, +1 or -1.
--- It used to be inferred, by taking the perpendicular that points away from
--- the plot origin — which works only while every leg hugs an outer edge. An
--- upper floor's return leg runs back across the middle of its own deck, where
--- the inferred side flips and puts the machines over the walkway and the buy
--- buttons out in space. One entry per leg, so one fewer than `points`.
Config.BeltPaths = {
	{
		id = "ground",
		y = 0,
		points = { Config.Layout.BeltStart, Config.Layout.BeltCorner, Config.Layout.BeltEnd },
		outboard = { 1, 1 },
		collectorAt = Config.Layout.CollectorAt,
	},
}

--- The upper floor. NOT stacked on the ground floor: a ceiling is the one thing
--- Roblox's camera has no good answer for (opaque snaps the camera to head
--- height, transparent lets it pop through, and LocalTransparencyModifier is
--- overwritten by the default camera scripts every frame). An open mezzanine
--- over the BACK half of the plot leaves the aisle you walk open to the sky.
Config.Floors = {
	{
		id = "mezzanine",
		-- unlocked by the LAST button of the ground floor, in the same currency.
		-- Buying floor 2 before you have finished floor 1 is the single most
		-- complained-about thing in multi-floor tycoons.
		requires = "dropper10",
		height = 22,             -- floor top, plot-local
		-- deck covers the back half only, so it does not roof the walkway
		deckSize = Vector3.new(112, 1.6, 60),
		deckAt = Vector3.new(0, 0, -38),
		-- teleport pads. Shipped elevators in this genre are pad pairs, not
		-- moving platforms: TweenService lifts jitter and slide players off.
		padDown = Vector3.new(40, 0, -14),
		padUp = Vector3.new(40, 0, -14),
		railHeight = 5,          -- falling off is the obvious new failure mode
	},
}

-- ── player upgrades ──────────────────────────────────────────────────────────
--
-- Deliberately small. Pet Sim 99's whole walkspeed track is +25% over two
-- tiers, and its biggest stat track is +54% over eight. The large multipliers
-- belong to rebirth; this shop is for shaving friction off the loop.
Config.PlayerUpgrades = {
	{
		id = "speed", name = "Sahur Sprint",
		stat = "WalkSpeed", levels = 8,
		base = 22, perLevel = 1.1,        -- caps at 30.8, under the ~32 wall-clip ceiling
		cost = 250, costGrowth = 4,
		blurb = "Move %s studs/sec.",
	},
	{
		id = "magnet", name = "Tung Magnet",
		stat = "CollectRadius", levels = 7,
		base = 0, perLevel = 4,
		cost = 400, costGrowth = 3.4,
		blurb = "Pull drops in from %s studs.",
	},
	{
		id = "payout", name = "Vault Skimmer",
		stat = "CashMultiplier", levels = 7,
		base = 1, perLevel = 0.08,
		cost = 800, costGrowth = 5,
		blurb = "All income x%s.",
	},
	{
		id = "autocollect", name = "Auto Collector",
		stat = "AutoCollect", levels = 1,
		base = 0, perLevel = 1,
		cost = 60000, costGrowth = 1,
		blurb = "The vault collects itself.",
	},
}

-- ── the utility slot ─────────────────────────────────────────────────────────
--
-- Steal a Brainrot's weapon ladder is one archetype reskinned eleven times,
-- scaling exactly one stat. All of its VARIETY lives in a second slot where
-- every item is a new verb with one duration number. That split is the thing
-- worth copying: progression in the weapon, variety in the utility.
--- `radius` and `force` are per-verb, not global: how far a shove reaches is a
--- property of the shove, and the moment they are shared constants the next
--- utility has to fight them.
Config.Utilities = {
	{ id = "freeze", name = "Sahur Freeze", verb = "freeze", duration = 4, cooldown = 18,
	  price = 40000, requires = "batforge", radius = 34 },
	{ id = "shove", name = "Tung Shove", verb = "shove", duration = 0, cooldown = 12,
	  price = 300000, requires = "upgrader3", radius = 26, force = 130 },
	{ id = "decoy", name = "Sahur Decoy", verb = "decoy", duration = 10, cooldown = 30,
	  price = 4000000, requires = "batforge2", radius = 6 },
}

-- ── rebirth perks ────────────────────────────────────────────────────────────
--
-- Four rewards per rebirth instead of one. The multiplier is the headline but
-- the other three are what stop the re-grind feeling like a punishment, and
-- what give MaxRebirths = 25 something on every rung.
Config.RebirthPerks = {
	StartingCashPerRebirth = 2500,     -- compounding is handled by the multiplier
	StartingCashGrowth = 3.2,
	-- every Nth rebirth grants a permanent extra machine slot
	SlotEveryRebirths = 3,
	-- milestone unlocks: rebirth -> what opens up
	Milestones = {
		[2] = { unlock = "mezzanine", label = "Second floor" },
		[4] = { unlock = "utility2", label = "Utility slot II" },
		[8] = { unlock = "goldplot", label = "Golden plot theme" },
	},
}

-- ── offline earnings ─────────────────────────────────────────────────────────
Config.Offline = {
	Rate = 0.25,             -- fraction of your live income per second
	CapHours = 8,
	-- extending the cap is a purchase, which turns the cap into a goal rather
	-- than a wall you resent
	CapUpgradeHours = { 12, 16, 24 },
	CapUpgradeCost = { 250000, 5000000, 120000000 },
	MinimumSeconds = 120,    -- below this, don't bother with the panel
}

-- ── session loops ────────────────────────────────────────────────────────────
Config.Sessions = {
	-- 7-day loop with milestones. 48h of grace, because losing a 20-day streak
	-- to one missed evening is how you lose the player instead of the streak.
	DailyRewards = { 500, 1500, 4000, 10000, 25000, 60000, 150000 },
	DailyGraceHours = 48,
	DailyMilestones = { [7] = 250000, [14] = 750000, [30] = 3000000 },

	-- Pet Sim 99's ladder, and note the deliberately decaying cadence: close
	-- together early so the first one arrives while you are still deciding
	-- whether to stay.
	PlaytimeMinutes = { 5, 10, 15, 20, 30, 40, 50, 60, 75, 90, 120, 180 },
	PlaytimeRewardBase = 1200,
	PlaytimeRewardGrowth = 1.9,

	-- The rewarded-video-ad shape with the ad removed: a big multiplier over a
	-- short window, which forces an active session rather than being banked.
	BoostMultiplier = 2,
	BoostSeconds = 600,
	BoostCooldown = 2400,

	-- near-zero code, real concurrency effect
	WeekendMultiplier = 2,
	WeekendDays = { [1] = true, [7] = true },   -- os.date("!*t").wday, Sun and Sat
}

-- ── sound ────────────────────────────────────────────────────────────────────
--
-- Every one of these ships INSIDE the Roblox client. No upload, no moderation,
-- and they cannot be taken down. The old handoff assumed audio was blocked
-- until someone uploads samples; it is not, and this is the cheapest quality
-- win on the list.
Config.Sound = {
	Library = {
		collect  = "rbxasset://sounds/electronicpingshort.wav",
		purchase = "rbxasset://sounds/switch3.wav",
		ui       = "rbxasset://sounds/button.wav",
		impact   = "rbxasset://sounds/impact_water.mp3",
		swing    = "rbxasset://sounds/swoosh.wav",
		rebirth  = "rbxasset://sounds/victory.wav",
		siren    = "rbxasset://sounds/action.wav",
	},
	-- Pool and round-robin; never Instance.new per drop. ~400 live Sound
	-- instances is where audio/video desync starts.
	PoolSize = 8,
	MinRepeatSeconds = 0.04,
	RollOffMaxDistance = 60,   -- so a neighbour's factory doesn't blare at you
	PitchPerCombo = 0.06,
	MaxPitch = 2,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Derived lookups (built once at require time)
-- ─────────────────────────────────────────────────────────────────────────────

-- Resolved once, at require time, so every module sees the same numbers.
Config.World.PlotCount = Config.plotCountFor()
Config.World.PlotPlacements = Config.plotPlacements(Config.World.PlotCount)
Config.World.PlotRadius = Config.World.PlotPlacements[1].radius   -- inner ring

-- THE MERGE. Three track tables become one Config.Buttons, in track order, so
-- every consumer downstream still iterates a single array exactly as before.
--
-- FACTORY FIRST IS LOAD-BEARING. It leaves every factory button with the same
-- `order` it had when there was only one table, which is what lets
-- Tycoon:assign keep replaying installs by sorting on `order` — weapons and
-- armour land after the whole factory, and because no requirement crosses a
-- track that ordering is trivially valid. It also keeps the verifier's
-- "requires must point at an earlier index" check true without modification.
--
--   order       position in the merged array. The install-order key. Global.
--   trackOrder  position within the button's own track. The gating and
--               display key: it is what the buy-button billboard counts, what
--               the three-state reveal measures its frontier against, and
--               what the HUD calls a step.
Config.TrackOrder = { "factory", "weapons", "armor" }
Config.Tracks = {
	factory = Config.FactoryButtons,
	weapons = Config.WeaponButtons,
	armor   = Config.ArmorButtons,
}
Config.TrackLabel = { factory = "FACTORY", weapons = "WEAPONS", armor = "ARMORY" }

Config.Buttons = {}
Config.ButtonById = {}
for _, track in ipairs(Config.TrackOrder) do
	local defs = Config.Tracks[track]
	for trackOrder, def in ipairs(defs) do
		def.track = track
		def.trackOrder = trackOrder
		-- A track IS a chain, so derive the link rather than restating it.
		-- This is what makes "no requirement crosses a track" a property of
		-- the loader instead of a promise the verifier has to police, and it
		-- deletes the single most error-prone field in this file for every
		-- row that doesn't genuinely need something unusual.
		if def.requires == nil and trackOrder > 1 then
			def.requires = defs[trackOrder - 1].id
		end
		table.insert(Config.Buttons, def)
		def.order = #Config.Buttons
		Config.ButtonById[def.id] = def
	end
end

Config.BatById = {}
for tier, def in ipairs(Config.Bats) do
	def.tier = tier
	Config.BatById[def.id] = def
end

Config.ArmorById = {}
for tier, def in ipairs(Config.Armor.Tiers) do
	def.tier = tier
	Config.ArmorById[def.id] = def
end

--- Where a side track's buy button `slot` stands, in plot-local coordinates.
---
--- Component arithmetic on purpose: tools/verify_config.lua stubs Vector3 as a
--- plain table with no operators, so anything that adds or scales a Vector3 at
--- require time takes the whole verifier down.
function Config.trackButtonPosition(track: string, slot: number): Vector3
	local t = Config.Layout.Tracks[track]
	return Vector3.new(t.buttonX, 0, t.firstZ + (slot - 1) * t.spacing)
end

--- The cabinet body behind that column: centre, then size. Its long axis is Z,
--- running the length of its own button column with four studs of overhang at
--- each end so the case reads as containing the buttons rather than starting
--- level with them.
function Config.trackCabinet(track: string): (Vector3, Vector3)
	local t = Config.Layout.Tracks[track]
	local length = (t.slots - 1) * t.spacing + 8
	return Vector3.new(t.cabinetX, 0, t.firstZ + (t.slots - 1) * t.spacing / 2),
		Vector3.new(t.depth, t.height, length)
end

--- Shelf slot `slot` on the cabinet — where the display for a bought tier
--- stands, so the case visibly fills up as you climb the track.
function Config.trackShelfPosition(track: string, slot: number): Vector3
	local t = Config.Layout.Tracks[track]
	return Vector3.new(t.cabinetX, 5, t.firstZ + (slot - 1) * t.spacing)
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
