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
	-- The generator yard behind each plot gets its own too. Stepping off the
	-- pad onto it is a 0.15-stud drop, which is a step rather than a ledge.
	YardTopY       = 0.45,
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
		floor2    = Vector3.new(8, 0,  22),
		walls     = Vector3.new(8, 0, -34),
		belt1     = Vector3.new(8, 0,  -6),
		roof      = Vector3.new(8, 0,   8),
		-- The column runs in purchase order with the later steps nearer the
		-- gate, so the floor goes at the near end. A button with no entry here
		-- gets built at the plot origin, on top of the belt — buttonPosition
		-- falls back to (0,0,0) and says nothing about it.

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

-- The top of the tallest thing standing beside the belt: the dropper's arm,
-- whose centre MACHINE_MASSES puts at BeltY + 5, with half a stud of body above
-- that. Written here rather than left to be measured inside Tycoon.lua because
-- it is what the buy-button label has to clear now that the label no longer
-- draws through walls, and the verifier can only check a relationship it can
-- see. If you raise the arm, raise this.
Config.Layout.MachineTopY = Config.Layout.BeltY + 5.5

-- HOW THICK A TRIGGER ON THE BELT HAS TO BE.
--
-- Everything that happens to a drop happens in a Touched handler on a volume it
-- passes through: the upgrader that multiplies it, the corner that turns it,
-- the collector that pays it. A drop crosses one of those in
-- thickness / beltSpeed seconds, and it is only seen if a physics step lands
-- inside that window. Roblox demotes an unattended assembly to 60 Hz and then
-- to 30 Hz — and an unattended plot is the COMMON case on a ten-player server,
-- because nine of the ten people are standing somewhere else.
--
-- The upgrader's scanner was 1 stud. At the shipped top belt speed of 37 that
-- is 27 milliseconds, which is already under a 30 Hz step: a drop can pass
-- through an upgrader between two physics frames and pay out unrefined. At 5
-- studs it is 135ms, which is four steps even demoted.
Config.Layout.TriggerThickness = 5

-- THE ROOF, which the mezzanine deck has to share a plot with.
--
-- These were literals inside the `roof` structure installer. They are here
-- because the deck sits at height 22 and the roof's columns are 20 tall, and
-- nothing was checking that relationship — the roof already shrinks itself when
-- the floor is on, which is exactly the kind of arrangement that breaks quietly
-- when either side moves. An assertion needs to see both sides.
Config.Layout.RoofY = 20            -- top of the columns, underside of the slab
Config.Layout.RoofThickness = 1.4
Config.Layout.RoofColumn = 2.4
Config.Layout.RoofColumnInset = 3   -- in from the plot's wall ring

-- THE GENERATOR YARD — its own slab, BEHIND the plot rather than part of it.
--
-- Everything on a plot is placed at a fixed plot-local coordinate, so growing
-- the plot slides the pad out from under the walls, the belt, the totem, the
-- cabinets and the mezzanine's deck all at once. Growing SIDEWAYS is worse
-- still: the ring radius is solved from PlotSize.X + PlotGap, so a wider plot
-- re-solves where every plot in the game sits. Growing backwards costs nothing
-- — behind the back wall there is only the 1800-stud ground slab.
--
-- Deliberately NOT an entry in Layout.Tracks. That table is the list of things
-- standing on the plot FLOOR: the verifier runs its inPlot check over every
-- slot of every entry, and ensureCabinets builds a display case for each. A
-- yard at z = -89 is outside the plot on purpose, and it is not a cabinet.
Config.Layout.Yard = {
	-- A SMALL CHUNK IN THE CORNER, not a second plot.
	--
	-- This was 108 x 40 — nearly as wide as the 120-stud plot — with three
	-- fences, a billboard and FOUR generator stands on it, all of which
	-- appeared the moment you claimed. Before you had bought a generator you
	-- were looking at 4320 square studs of concrete and three buy pads for a
	-- track you had no reason to care about yet. That is the same complaint the
	-- cabinets answered in #30, one track over.
	--
	-- 28 x 28 is 784, eighteen percent of it, and twelve studs less deep. There
	-- is one generator now and one pad in front of it, so the yard is sized for
	-- what actually stands there rather than for four of something.
	--
	-- The front face overlaps the pad by a stud so the two slabs interpenetrate
	-- rather than share a vertical plane, which is the same trick the deck's
	-- posts use where they meet the deck.
	Size   = Vector3.new(28, 2, 28),    -- x 32..60, z -97..-69
	-- OFF-CENTRE RIGHT, and that is forced rather than chosen. The back edge of
	-- the plot IS the dropper row (slot 1 reaches x = 43.5) and the left side is
	-- the upgrader alley, so the back-right corner is the only span of wall with
	-- nothing behind it — which is already why DoorFrom is 46. The yard moves to
	-- the door rather than the door moving to the yard, so the wall spec does
	-- not change at all.
	Centre = Vector3.new(46, 0, -83),

	-- THE DOOR, and there is only one place it can go. The back edge of the
	-- plot IS the dropper row — slots 1..10 occupy x = -42.5 to 43.5 — and the
	-- left side is the upgrader alley. The back-right corner is the only span
	-- of wall with nothing behind it, clear of dropper slot 1 by 2.5 studs.
	--
	-- Cut at wall-build time rather than when the generator is bought: `walls`
	-- lands around minute five and the first rung later, and a wall with no
	-- door in it seals the yard off for good.
	DoorFrom = 46,

	-- ONE STAND, ONE PAD. Slots/FirstX/Spacing are gone: there is no per-rung
	-- position any more, because every rung upgrades the machine standing here
	-- rather than adding another one beside it. See Config.PowerButtons.
	MachineZ = -88,
	ButtonZ = -75,         -- its pad, between the door and the machine
	MachineSize = Vector3.new(12, 14, 10),

	FenceHeight = 8,
	FenceThickness = 1,    -- back, left and right; open on the plot side
}

-- plot-local y of the yard's top face. A scalar, worked out after both tables
-- exist, because the verifier's Vector3 has no arithmetic.
Config.Layout.Yard.LocalY = Config.World.YardTopY - Config.World.PlotSurfaceY

--- Where the generator stands, and where its pad does. Both on the yard's
--- centre line; component arithmetic, like every other derived position here.
---
--- These took a `slot` and returned four different places. Every power rung now
--- resolves to the SAME pad position, which is what makes one pad sell four
--- rungs: `requirementsMet` is true for exactly one rung at a time, so exactly
--- one holder is ever parented and the pad in front of the generator always
--- shows the next tier up. See TrackInfo.power.preview, which has to be 0 for
--- that to hold.
function Config.yardMachinePosition(): Vector3
	local y = Config.Layout.Yard
	return Vector3.new(y.Centre.X, y.LocalY, y.MachineZ)
end

function Config.yardButtonPosition(): Vector3
	local y = Config.Layout.Yard
	return Vector3.new(y.Centre.X, y.LocalY, y.ButtonZ)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- WORLD TEXT
--
-- Every label the game draws into the world used to pick its own font, its own
-- outline and its own view distance, one at a time, as it was written: three
-- fonts, six outline settings, and eleven distinct MaxDistance values ranging
-- from 90 studs to 1200 — plus statue faces at 0, which means "always render"
-- and was nobody's decision.
--
-- The numbers live here rather than in Style.lua so the verifier can see them.
-- Style.lua turns them into instances; nothing else in src/ is allowed to name
-- a font, an outline or a view distance (tools/verify.py enforces that).
-- ─────────────────────────────────────────────────────────────────────────────

Config.Style = {
	-- TWO faces, not one: a display face for names and a UI face for the small
	-- print. "One font everywhere" in the literal sense would set prices and
	-- plot names in the same weight, which is how you get a label with no
	-- reading order. What matters is that there is one of EACH and no third.
	TitleFont = "FredokaOne",
	BodyFont  = "GothamBold",

	-- One outline recipe. The old values ran 0.1 to 0.4 with no pattern; 0.25
	-- is legible against both the grass and the neon without ringing the text.
	StrokeTransparency = 0.25,
	StrokeColor = Color3.fromRGB(16, 12, 24),

	-- World text never dims with the scene. Only two of the fourteen labels set
	-- this before, so the same sign was readable on one plot and muddy on the
	-- next depending on what was casting a shadow over it.
	LightInfluence = 0,

	-- FOUR NAMED VIEW DISTANCES. Every label picks one of these by name, so the
	-- question at each site is "how far away does this stop mattering" rather
	-- than "what number did the last one use".
	--
	--   machine  a plate on the machine you are standing at
	--   prop     something you walk up to and use: buttons, pads, cabinets
	--   plot     your factory, read from anywhere on it or from the arena
	--   world    the arena, and finding a free plot from across the ring
	--
	-- `world` is not decoration: the two plots furthest apart on the ring are
	-- 2 * PlotRadius apart, and the claim beacon has to be findable across that
	-- gap. The verifier asserts it against the ring rather than trusting 1200.
	Distance = {
		machine = 140,
		prop    = 220,
		plot    = 500,
		world   = 900,
	},

	-- THE BUY BUTTON, IN TWO VOICES.
	--
	-- A plot has up to a dozen buy-button labels standing on it at once, and
	-- until now the locked ones were exactly as loud as the one you can
	-- actually press: same panel, same opacity, same size, same little light,
	-- differing only in colour. Colour alone is the weakest signal available —
	-- it is the first thing lost to a bright sky, a neon variant behind the
	-- label, or a player who does not separate those two greens — so the plot
	-- read as a wall of labels rather than as one thing to walk towards.
	--
	-- The locked state is therefore quieter on FIVE axes at once. Any one of
	-- them alone is a nudge; together they make the difference structural.
	Button = {
		width = 16,
		height = 9,
		-- Studs above the pad. The label used to sit at 6, which put its lower
		-- half behind the dropper standing next to it — and AlwaysOnTop was
		-- what hid that. With the x-ray off the label has to clear the
		-- machinery on its own; the verifier asserts it against MachineTopY.
		lift = 12,
		panelAlpha = 0.2,
		strokeThickness = 2.5,
		distance = "prop",
	},
	-- THE TWO SIGNS OVER THE ARENA STATUE, in world Y.
	--
	-- The raid line takes the statue's head height and the game's own name
	-- moves up above it. During a raid the sign over the statue should be the
	-- raid; the title is furniture, and it had been sitting across the statue's
	-- face at 34 anyway (the statue tops out around 35.6).
	--
	-- Putting the raid state here rather than in a bar across everyone's screen
	-- is the point: it is where the raid IS, and the statue is visible from
	-- every plot.
	RaidSignY = 40,
	RaidSignHeight = 8,
	ArenaTitleY = 52,
	ArenaTitleHeight = 14,

	ButtonLocked = {
		scale = 0.7,             -- smaller
		panelAlpha = 0.78,       -- fainter panel
		strokeThickness = 1,     -- thinner outline
		textAlpha = 0.4,         -- fainter text, outline fading with it
		distance = "machine",    -- and it drops out of sight first
	},
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

-- ADMIN CHAT COMMANDS. See src/server/AdminService.lua.
--
-- DELIBERATELY NOT IN Config.Prototypes. That table is for unfinished features
-- and the verifier asserts every flag in it ships `false`, so a prototype flag
-- is a thing you cannot turn on. This is the opposite: it is finished, it is
-- meant to be on in Studio, and what gates it is WHO you are rather than
-- whether the feature is ready.
--
-- Three ways to qualify, checked in this order:
--
--   RunService:IsStudio()   anyone testing locally. The overwhelming majority
--                           of the use, and it cannot leak to a live server.
--   game.CreatorId          the owner of the place, in a real server. Group
--                           games report the GROUP id here, which is why
--                           CreatorType is checked before it is trusted.
--   UserIds                 anyone else you want to hand it to. Empty on
--                           purpose: an allowlist that ships with a name in it
--                           is a name nobody re-reads.
--
-- Enabled = false kills all three at once, which is the switch to reach for if
-- these ever need to be off in Studio too.
Config.Admin = {
	Enabled = true,
	UserIds = {},
	-- What a bare `$` grants. Enough to feel like a cheat and not so much that
	-- the HUD's number formatting has to be checked against it.
	DefaultGrant = 1000000,
}

Config.Rebirth = {
	-- THE PAD IS PRICED AS A RUNG, NOT AS A NUMBER. Config.rebirthBaseCost()
	-- in the derived-lookups section fills in BaseCost once the spine exists.
	--
	-- The comment that used to sit here claimed BaseCost was "DERIVED from
	-- endgame income". It was not. It was retyped by hand against whatever the
	-- curve happened to be that week, and it drifted the moment the generator
	-- doubled endgame income — the round that shipped the generator had to come
	-- back and edit this number to keep its own comment true.
	--
	-- PriceRung = 4 means the pad costs what the 4th most expensive thing on
	-- the spine costs, which buys a property no constant can:
	--
	--   the minute you can afford the rebirth is at most the minute you could
	--   afford that rung, so the THREE rungs above it are provably still
	--   unbought when the pad lights up.
	--
	-- That is "the session ends on a choice rather than on being finished",
	-- guaranteed by construction rather than by luck, and it re-derives itself
	-- under whatever prices the ladder lands on next.
	PriceRung = 4,
	CostGrowth = 3.4,            -- cost multiplier per rebirth
	MultiplierPerRebirth = 2.25, -- payout multiplier is this ^ rebirths
	MaxRebirths = 25,
	-- BaseCost is assigned below, once Config.Tracks exists. Every consumer
	-- reads it as a plain number and does not care where it came from.
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

-- NO `requires` FIELD APPEARS BELOW, and that is the point.
--
-- The header above has always said the loader derives it from the row above and
-- that a hand-typed one is the most error-prone field here. Every row restated
-- it anyway, and the restating hid a fork: `dropper8` required `upgrader4`
-- while floor2 -> mezz_dropper1 hung off `upgrader4` too, so the mezzanine was
-- a dead-end branch nothing downstream needed. You could finish the entire
-- ground floor without ever buying the floor — and since Config.TrackUnlock
-- gates BOTH cabinets on floor2, without ever seeing a weapon or a suit of
-- armour either. The verifier's chain check counts requirement-free roots, so a
-- fork downstream of the root was invisible to it.
--
-- Moving the floor to position 6 is what finally makes table order and
-- dependency order the same thing, which is what lets the derivation stand
-- alone. One root, twenty links, no forks, and the order you read is the order
-- you buy.
Config.FactoryButtons = {
	{
		id = "dropper1", name = "Tung Dropper", price = 50,
		kind = "Dropper", slot = 1, variant = "classic",
		dropValue = 1, dropRate = 1.5,
		blurb = "tung.",
	},
	{
		id = "dropper2", name = "Tung Tung Dropper", price = 75,
		kind = "Dropper", slot = 2, variant = "oak",
		dropValue = 4, dropRate = 1.5,
		blurb = "tung tung.",
	},
	{
		id = "upgrader1", name = "Drum Roll Refiner", price = 250,
		kind = "Upgrader", slot = 1, variant = "oak",
		multiplier = 1.6,
		blurb = "A little sahur percussion. x1.6",
	},
	{
		id = "dropper3", name = "Tung Tung Tung Dropper", price = 500,
		kind = "Dropper", slot = 3, variant = "ash",
		dropValue = 12, dropRate = 1.4,
		blurb = "tung tung tung.",
	},
	{
		id = "walls", name = "Plot Walls", price = 1500,
		kind = "Structure", structure = "walls",
		blurb = "Keeps the raiders honest.",
	},
	-- THE SECOND FLOOR, and it is what the walls just made room for.
	--
	-- It has moved twice. It began as a free reward for owning dropper10 — the
	-- very last button, eighty minutes in. #29 made it a purchase at the
	-- halfway mark, minute forty-one. Both of those put the one piece of new
	-- geography in the stretch of the build that GROWTH-TODO item 1 says counts
	-- for nothing, and #29's own note conceded the floor then stayed at minute
	-- 41 while everything around it got faster.
	--
	-- The deciding fact is not about the floor at all: Config.TrackUnlock gates
	-- the weapons AND armour cabinets on this button. Parking it at the halfway
	-- mark parked both side ladders behind it, which is how the verifier ended
	-- up printing "opens at 41 min with 4 of 5 rungs already affordable" — a
	-- cabinet you empty in one pass because you spent forty minutes able to
	-- afford it and unable to reach it. Moving one button fixes three ladders.
	--
	-- So it lands right after the walls, around minute six, for 1750 rather
	-- than eight million. You buy the enclosure, then you buy the storey it
	-- encloses, and the ladder up stands by the gateway you walk in through.
	--
	-- Two buttons, not one. The deck is the purchase; the machine that stands
	-- on it is the next purchase, and it is an ORDINARY Dropper row pinned to
	-- the mezzanine's belt path. That is what makes the floor somewhere you
	-- can buy things rather than scenery with a free dropper on it — and it is
	-- why the income readout can see it, which the free one never could.
	{
		id = "floor2", name = "The Mezzanine", price = 1750,
		kind = "Floor", floor = "mezzanine",
		blurb = "A second storey, with its own line.",
	},
	{
		id = "mezz_dropper1", name = "Mezzanine Tung", price = 2000,
		kind = "Dropper", variant = "eclipse",
		-- `path` is an id, not an index: pathIndex is assigned at runtime by
		-- addBeltPath and Config cannot know it. legIndex/legDistance pin the
		-- machine to a leg of that path, exactly as Config.Layout.DropperDist
		-- pins one to a leg of the ground floor's.
		path = "mezzanine", legIndex = 1, legDistance = 14,
		-- dropValue was 1400, for a machine bought at minute forty-four beside
		-- seven ground droppers. At minute eight it stands beside three, worth
		-- 11.9 raw dps between them, and 1400 would have made the upstairs line
		-- 98% of the plot's income the second it was bought — the ground floor
		-- would have stopped being the thing you were playing. At 12 it is a
		-- shade under dropper3 and a third of plot income, which is a peer of
		-- the newest ground machine rather than a replacement for all of them.
		dropValue = 12, dropRate = 2.0,
		blurb = "The upstairs line.",
	},
	{
		id = "dropper4", name = "Golden Tung", price = 3250,
		kind = "Dropper", slot = 4, variant = "golden",
		dropValue = 40, dropRate = 1.4,
		blurb = "Sahur, but expensive.",
	},
	{
		id = "upgrader2", name = "Sahur Bat Upgrader", price = 9000,
		kind = "Upgrader", slot = 2, variant = "golden",
		multiplier = 1.85,
		blurb = "Whacks value into them. x1.85",
	},
	{
		id = "dropper5", name = "Crimson Tung", price = 21000,
		kind = "Dropper", slot = 5, variant = "crimson",
		dropValue = 150, dropRate = 1.3,
		blurb = "It has seen things.",
	},
	{
		id = "belt1", name = "Belt Overdrive", price = 68000,
		kind = "Belt", speedBonus = 9,
		blurb = "Conveyor goes brrrr.",
	},
	{
		id = "upgrader3", name = "Tralalero Refiner", price = 82000,
		kind = "Upgrader", slot = 3, variant = "crimson",
		multiplier = 2.1,
		blurb = "Sharks approve. x2.1",
	},
	{
		id = "dropper6", name = "Neon Tung", price = 165000,
		kind = "Dropper", slot = 6, variant = "neon",
		dropValue = 620, dropRate = 1.25,
		blurb = "3am energy drink sahur.",
	},
	{
		id = "roof", name = "Sahur Roof + Sign", price = 760000,
		kind = "Structure", structure = "roof",
		blurb = "Now it's a real business.",
	},
	{
		id = "dropper7", name = "Void Tung", price = 900000,
		kind = "Dropper", slot = 7, variant = "void",
		dropValue = 2600, dropRate = 1.2,
		blurb = "tung from beyond.",
	},
	{
		id = "upgrader4", name = "Void Furnace", price = 4500000,
		kind = "Upgrader", slot = 4, variant = "void",
		multiplier = 2.4,
		blurb = "Melts them into money. x2.4",
	},
	{
		id = "dropper8", name = "Eclipse Tung", price = 11000000,
		kind = "Dropper", slot = 8, variant = "eclipse",
		dropValue = 11000, dropRate = 1.15,
		blurb = "Sahur at the end of the night.",
	},
	{
		id = "upgrader5", name = "Eclipse Ascension", price = 48000000,
		kind = "Upgrader", slot = 5, variant = "eclipse",
		multiplier = 2.8,
		blurb = "Ascends the tung. x2.8",
	},
	{
		id = "dropper9", name = "Galaxy Tung", price = 140000000,
		kind = "Dropper", slot = 9, variant = "galaxy",
		dropValue = 48000, dropRate = 1.1,
		blurb = "tung tung tung across the stars.",
	},
	{
		id = "upgrader6", name = "Tung Singularity", price = 820000000,
		kind = "Upgrader", slot = 6, variant = "galaxy",
		multiplier = 3.4,
		blurb = "Do not look directly at it. x3.4",
	},
	{
		id = "dropper10", name = "INFINITY TUNG TUNG TUNG SAHUR", price = 2800000000,
		kind = "Dropper", slot = 10, variant = "infinity",
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

-- ─────────────────────────────────────────────────────────────────────────────
-- THE GENERATOR YARD — the fourth track.
--
-- A slab behind the plot with a row of generators on it. Buying a rung speeds
-- up production, and it does so by speeding up the DROPPERS AND THE BELT
-- TOGETHER, at the same rate.
--
-- That pairing is not flavour, it is the only way the feature works at all.
-- Income is dropValue/dropRate and does not depend on belt speed; what belt
-- speed decides is how CROWDED the belt is. Drops in flight are
-- peakRate x length / speed, so scaling rate alone is a straight multiplier on
-- how many are on the belt at once — and the plot is already at 88% of
-- MaxDropsPerPlot. A x1.4 generator on the droppers alone puts it over the cap,
-- at which point spawnDrop starts silently eating the income you just paid for.
-- Scaling both leaves the number in flight exactly where it was.
--
-- It is also the more honest version of the idea. A generator powers the line;
-- the line runs faster, belt included.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Power = {
	MaxFactor = 2.00,   -- what the top rung must grant; asserted, not assumed
	StepMin = 1.10,     -- and each rung's step over the one below sits in this
	StepMax = 1.30,     -- band, so it is four even rungs rather than one big one
}

-- `factor` is CUMULATIVE — the multiplier owning this rung puts the plot at,
-- not the step it adds. A track is a chain, so "the factor you are on" is the
-- factor of the highest rung you own, which means the verifier asserts the
-- headline x2 against a literal instead of against a product of four floats,
-- and a save that somehow holds rung 3 without rung 2 lands on a defined value.
Config.PowerButtons = {
	{
		id = "power1", name = "Diesel Generator", price = 17500,
		kind = "Power", factor = 1.19, variant = "golden",
		blurb = "The whole line runs 19% faster.",
	},
	{
		id = "power2", name = "Twin Turbine", price = 650000,
		kind = "Power", factor = 1.42, variant = "crimson",
		blurb = "The whole line runs 42% faster.",
	},
	{
		id = "power3", name = "Sahur Reactor", price = 3600000,
		kind = "Power", factor = 1.68, variant = "void",
		blurb = "The whole line runs 68% faster.",
	},
	{
		id = "power4", name = "Tung Fusion Core", price = 260000000,
		kind = "Power", factor = 2.00, variant = "infinity",
		blurb = "Double production. Droppers and belt alike.",
	},
}

--- The production multiplier a plot's `owned` set is running at.
---
--- Iterated in track order taking the LAST hit rather than multiplied, because
--- `factor` is cumulative. Pure arithmetic and no Roblox types, so the server,
--- the offline-earnings mirror and the verifier can all call the same one
--- rather than keeping three copies of it in agreement.
function Config.powerFactor(owns: (string) -> boolean): number
	local factor = 1
	for _, def in ipairs(Config.PowerButtons) do
		if owns(def.id) then
			factor = def.factor
		end
	end
	return factor
end

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
	FirstWaveDelay = 30,
	-- Quiet time between a wave clearing and the next warning going up.
	--
	-- 18 + WarningTime 12 = THIRTY SECONDS from your clear to the next raid
	-- landing, which is the number this is set against. The verifier already
	-- defines dead air as RestTime + WarningTime, so the two agree on what is
	-- being measured. It was 20, for 32.
	RestTime = 18,
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

	-- WAVE SIZE. Bigger, and it climbs faster: the first raid is six rather
	-- than four, and it grows by four a wave to a ceiling of forty.
	--
	-- THIS DOES NOT UNDO THE ANTI-SWARM WORK, and it is worth knowing that
	-- before the two changes look like they are fighting each other. MaxChasers
	-- is still 8, so no matter how many are alive only eight can engage any one
	-- player. A bigger wave is therefore more REINFORCEMENTS — bodies milling
	-- at their home patches and stepping in as slots free — not more people
	-- hitting you at once. The verifier asserts the two stay far enough apart
	-- for that to remain the shape of it.
	BaseCount = 6,
	CountPerWave = 4,
	MaxCount = 40,
	-- Parts in one raider, counted rather than guessed: 26 in the visible Tung
	-- (invisible core, 2 legs + 2 feet, 8-part bat body, face plate, 2 arms +
	-- 2 hands, and another 8-part bat in its hand) plus the 7-part invisible R6
	-- rig underneath it. Recount in TungModels.build/buildBatBody/buildNPC if
	-- you change the silhouette.
	--
	-- The verifier cannot see TungModels, so this is the only way the part
	-- budget is checkable at all — and a wave cap is exactly the number someone
	-- raises without thinking about what it costs on a full server.
	PartsPerRaider = 33,
	MaxRaiderParts = 1600,
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

	-- ANTI-SWARM. An aggro radius alone does not fix the pile-up: raiders that
	-- spawn on one evenly-divided ring all cross the same threshold on the same
	-- tick and then converge on one point, so the wave arrives as a wall and
	-- fights as a single blob standing inside itself.
	SpawnGroupSize = 4,         -- clusters, not one synchronised ring
	SpawnGroupGap = 0.6,        -- pause between clusters
	GroupArc = 0.35,            -- radians of jitter within a cluster (~18 studs at r=52)
	AggroStagger = 1.8,         -- each raider holds you this long, at random, before committing
	-- Raiders MoveTo a point on a ring around you rather than to you. Under
	-- AttackRange, so a raider parked on its slot is already in swing range and
	-- the ring costs no damage output — it only stops 26 bodies occupying one
	-- stud.
	ApproachStandoff = 6.5,
	OrbitSpeed = 0.35,          -- rad/sec of drift, so the ring reads as a mob not a formation
	-- How many may engage one player at once. Not arbitrary: a 6.5-stud ring
	-- has a circumference of 40.8 and a raider is about 4.5 studs wide, so nine
	-- fit shoulder to shoulder. Eight leaves a slot of slack, and the ones over
	-- the cap keep milling and step in as slots free — which reads as
	-- reinforcements rather than as a queue.
	MaxChasers = 8,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- BELT PATHS AND FLOORS
--
-- These lived under the PROTOTYPES banner, which was already a lie:
-- Tycoon.new consumes BeltPaths[1] unconditionally to build the ground floor's
-- conveyor. They are shipped data and they sit with the shipped data.
--
-- A path is just a list of corners, and every piece of belt geometry derives
-- from leg(i), so the runtime does not care how many legs there are.
-- ─────────────────────────────────────────────────────────────────────────────
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
		-- The button that BUILDS this floor. It used to be `requires =
		-- "dropper10"` — own the last dropper and the whole deck appeared for
		-- free, at the very end of the build. Then a purchase at the halfway
		-- mark. It is now the purchase straight after the walls, around minute
		-- six: the storey the enclosure made room for, and the gate on both
		-- side-track cabinets, which is the reason it could not stay at forty.
		button = "floor2",
		height = 22,             -- floor top, plot-local
		-- deck covers the back half only, so it does not roof the walkway
		deckSize = Vector3.new(112, 1.6, 60),
		deckAt = Vector3.new(0, 0, -38),
		-- belt and machines float this far over the deck: a belt base whose
		-- underside is coplanar with the deck's top face is two surfaces at one
		-- Y, which z-fights
		deckLift = 0.1,
		railHeight = 5,          -- falling off is the obvious new failure mode

		-- BELT MARGINS, in from each deck edge.
		--
		-- Each has to clear MachineOffset + MachineFootprint/2 + rail thickness
		-- or a machine standing on that leg hangs over the railing. `side` was
		-- 10 and needed 11.5, so leg 2's machine strip overshot the deck by a
		-- stud and a half; `back` was 12 against 11.5, half a stud of margin.
		-- Nothing stood there only because the floor carried one dropper on leg
		-- 1 — which is the whole reason this geometry had to become data before
		-- anything could be bought on it.
		belt = {
			back = 13,
			side = 12,
			front = 14,
			collectorRun = 16,   -- run-off between the belt's end and the hopper
			-- WHERE THE HOPPER STANDS, stated rather than derived.
			--
			-- This was `pads.up.X - padClearance`: the collector's position was
			-- worked out backwards from a teleport pad. The pads are gone and
			-- the number they produced (40 - 12) is kept exactly, because the
			-- belt geometry was right and only its justification was borrowed.
			-- A collector that moves because a piece of furniture moved is a
			-- coupling nobody asked for.
			collectorX = 28,
			ladderClearance = 10,   -- keep the hopper this clear of the landing
			outboard = { 1, 1, 1 },
		},

		rail = { thickness = 1, bar = 1.4 },

		-- Support posts down to the plot floor. Their footprints miss what is
		-- already down there: 4 in from the deck's sides puts them at x = +-52,
		-- outboard of leg 2 (which reaches x = -48.6) and clear of the upgrader
		-- beams; 8 in from the front edge drops them at z = -16, between
		-- upgrader slots 2 and 3 at z = -26 and z = -10.
		pillar = { size = 2.4, insetSide = 4, insetBack = 4, insetFront = 8 },

		-- A LADDER, WHERE THE TELEPORT PADS WERE.
		--
		-- The pads were a 9x9 pair with a cooldown, an arrival lock and a
		-- TouchEnded sweep to stop a character resting on one from bouncing off
		-- its own physics jitter — about a hundred lines to walk up a flight of
		-- stairs. They also could not be made to line up: the ground end at
		-- (40, -14) interpenetrated the armour cabinet's slot-2 pedestal, and
		-- with the weapons and armour columns at x = 30 and 44 on a 14-stud
		-- pitch there is no clean 9x9 anywhere on that side. It moved to the
		-- aisle, 54 studs from the end it was paired with, and HANDOFF_v5 §5
		-- left "does that still read as a lift or now as a teleport" as an open
		-- question nobody answered.
		--
		-- A TrussPart answers it by not asking. Roblox humanoids climb truss
		-- natively, in both directions, with no script at all — no cooldown, no
		-- arrival lock, no per-frame work, and you can see where it goes from
		-- the bottom of it.
		--
		-- WHERE IT STANDS is the tight part. The deck's front edge is at
		-- z = -8, and the ladder has to be in front of it rather than under it:
		-- coming up THROUGH the deck needs a hatch in the slab and a hole in
		-- the guard. Along that edge x is nearly all spoken for —
		--
		--    x  5.5..10.5   belt1's misc pedestal at MiscButtons.belt1
		--    x 18  ..22     the weapons cabinet body (Tracks.weapons.cabinetX)
		--    x 27.5..32.5   the weapons button column, slot 3 at z = -6
		--    x 41.5..46.5   the armour button column, slot 3 at z = -6
		--
		-- — and x = 14 is the gap. It is also Layout.GateCentre and the x of
		-- OwnerSpawnAt, so the ladder stands directly ahead of the gateway you
		-- walk in through: not beside the main entrance, but in line with it.
		-- It clears belt1 by 2.5 studs and the weapons cabinet by 3.
		ladder = {
			at = Vector3.new(14, 0, -6.6),  -- centre of the column, just proud of the deck
			width = 2,                       -- a TrussPart's cross-section is 2x2
			rise = 1.5,                      -- overshoot above the deck, to step off onto
			-- The front guard is built in two pieces with this much of a gap at
			-- `at.X`, because a ladder that arrives at a railing is a ladder to
			-- nowhere. The visible bar is cut with it.
			gate = 7,
		},
	},
}

--- The mezzanine's belt, as a Config.BeltPaths entry.
---
--- Three legs around the back and left of the deck, then a return leg back
--- across it to the hopper. Derived from the deck rectangle and the pad
--- position rather than written out as a second set of magic coordinates, so it
--- follows the deck if that is ever resized.
---
--- The return leg is what the old inferred-outboard heuristic could not do: its
--- midpoint sits near the middle of the plot, so "point away from the origin"
--- picks the wrong side and hangs the machines over the walkway. Every leg's
--- side is stated.
---
--- COMPONENT ARITHMETIC ONLY. tools/verify_config.lua stubs Vector3 as a plain
--- table with no operators, so `deckSize * 0.5` here would take the entire
--- 1200-check suite down at require time. This function is the reason the
--- mezzanine's belt is visible to the belt assertions at all, so it would be a
--- particularly silly place to break them.
function Config.floorBeltPath(floor)
	local b = floor.belt
	local halfX, halfZ = floor.deckSize.X / 2, floor.deckSize.Z / 2

	local backZ = floor.deckAt.Z - halfZ + b.back
	local frontZ = floor.deckAt.Z + halfZ - b.front
	local rightX = floor.deckAt.X + halfX - b.side
	local leftX = floor.deckAt.X - halfX + b.side
	local collectorX = b.collectorX

	return {
		id = floor.id,
		y = floor.height + floor.deckLift,
		points = {
			Vector3.new(rightX, 0, backZ),
			Vector3.new(leftX, 0, backZ),
			Vector3.new(leftX, 0, frontZ),
			Vector3.new(collectorX - b.collectorRun, 0, frontZ),
		},
		outboard = b.outboard,
		collectorAt = Vector3.new(collectorX, 0, frontZ),
	}
end

for _, floor in ipairs(Config.Floors) do
	table.insert(Config.BeltPaths, Config.floorBeltPath(floor))
end

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

-- `Floors` is gone from this table rather than set true: the check below asserts
-- every prototype flag ships off, so graduating one means it stops being a
-- prototype, not that it becomes the exception. The second floor is a purchase
-- on the factory track now, gated by owning its button like everything else.
Config.Prototypes = {
	PlayerUpgrades = false,-- walkspeed / magnet / cash multiplier shop
	Utilities = false,     -- a second weapon slot holding a verb, not a stat
	RebirthPerks = false,  -- rebirth grants four things instead of one number
	Offline = false,       -- offline earnings and the welcome-back panel
	Sessions = false,      -- daily streak, playtime ladder, boost cooldown
	Sound = false,         -- the engine-asset sound layer
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
-- POWER GOES LAST. Appending leaves every existing button's `order` exactly
-- where it was, so no save's install replay changes sequence and "requires
-- points at an earlier index" stays trivially true.
Config.TrackOrder = { "factory", "weapons", "armor", "power" }
Config.Tracks = {
	factory = Config.FactoryButtons,
	weapons = Config.WeaponButtons,
	armor   = Config.ArmorButtons,
	power   = Config.PowerButtons,
}

-- EVERYTHING THAT IS TRUE OF A TRACK RATHER THAN OF A BUTTON, in one table.
--
-- Adding a fourth track is mostly an exercise in finding the per-track facts,
-- because they were scattered across five tables in three files and one of them
-- existed TWICE. A missing row in each fails differently and none of them fail
-- loudly:
--
--   where its buttons stand    Layout.Tracks[track] is nil -> indexing nil ->
--                              buildButtons throws -> the plot fails to build
--   survives a rebirth         asserted from two places with opposite polarity;
--                              a missing row FAILS OPEN and the generator
--                              survives the reset it is supposed to be part of
--   beacon rank                one copy in Tycoon and one in HUD: the panel
--                              names one purchase, the beacon glows on another
--   preview depth              falls back to 3, so a 4-rung ladder previews
--                              itself entirely from the moment you claim
--   spine or detour            the verifier prices it as a side track, which is
--                              wrong for anything that multiplies income
--
-- `rank` is not here because it is exactly the TrackOrder index; it is derived
-- below, which deletes both copies rather than adding a third.
Config.TrackInfo = {
	factory = { label = "FACTORY", preview = 3, keepOnRebirth = false, paced = "spine", furniture = "misc" },
	weapons = { label = "WEAPONS", preview = 2, keepOnRebirth = true,  paced = "side",  furniture = "cabinet" },
	armor   = { label = "ARMORY",  preview = 2, keepOnRebirth = true,  paced = "side",  furniture = "cabinet" },
	-- The generator multiplies exactly what a rebirth resets. Keeping it would
	-- stack x2 on top of MultiplierPerRebirth 2.25 for an effective 4.5x first
	-- prestige, which makes the asserted CostGrowth/MultiplierPerRebirth ratio
	-- a lie about the real pacing. It is plot machinery, same class as a
	-- dropper — not a monotone character grant like a bat or a suit of armour.
	-- preview = 0, and it is load-bearing rather than a taste call. All four
	-- rungs resolve to ONE pad position, so a preview pad would be built inside
	-- the lit one. At 2 it put three pads in the yard on a plot that had bought
	-- none of them, which is most of what "the generator is visually intrusive
	-- on plot creation" was about. The verifier asserts this is 0.
	power   = { label = "POWER",   preview = 0, keepOnRebirth = false, paced = "spine", furniture = "yard" },
}

Config.TrackLabel = {}
Config.TrackRank = {}
for rank, track in ipairs(Config.TrackOrder) do
	Config.TrackRank[track] = rank
	Config.TrackLabel[track] = Config.TrackInfo[track] and Config.TrackInfo[track].label or track:upper()
end

-- WHAT A WHOLE LADDER WAITS ON.
--
-- Deliberately NOT a `requires` on each track's first rung. The loader derives
-- requirements within a track and the verifier asserts none ever crosses one —
-- that guarantee is worth more than the convenience, and a precondition on an
-- entire ladder is a different kind of thing from a link inside one.
--
-- The two cabinets stood on the plot from the moment you claimed it: two
-- display cases and nine pedestals, for upgrades you could not use and had no
-- reason to care about yet. That is most of the visual noise in the first few
-- minutes, and it is why they now arrive with the second floor.
Config.TrackUnlock = { weapons = "floor2", armor = "floor2" }

--- Whether `track` is open on a plot that owns `owned`.
---
--- STICKY, and derived rather than stored. Owning any rung of a track counts as
--- having it open, which matters because rebirth wipes the factory (and so the
--- gate button) while deliberately keeping weapons and armour. Without that
--- clause a rebirth would make the cabinets vanish while the shelf displays and
--- the granted bat survived — a cabinet-shaped hole with a bat floating in it.
--- Derived this way it costs no new persisted field and no migration.
function Config.trackUnlocked(track: string, owned): boolean
	local gate = Config.TrackUnlock[track]
	if not gate or owned[gate] then
		return true
	end
	for _, def in ipairs(Config.Tracks[track] or {}) do
		if owned[def.id] then
			return true
		end
	end
	return false
end

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

--- Every price on the SPINE — factory plus power — highest first.
---
--- The spine is what the progression simulation walks and what the build time
--- is measured against. Weapons and armour are deliberately excluded: they are
--- side tracks, priced against the factory rather than pacing it, and a bat
--- costing more than a dropper is the entire point of that split.
function Config.spinePricesDescending(): { number }
	local prices = {}
	for _, def in ipairs(Config.Tracks.factory) do
		table.insert(prices, def.price)
	end
	for _, def in ipairs(Config.Tracks.power) do
		table.insert(prices, def.price)
	end
	table.sort(prices, function(a, b)
		return a > b
	end)
	return prices
end

--- What the rebirth pad costs: the price of the PriceRung-th most expensive
--- thing on the spine, rounded to two significant figures.
---
--- The rounding is not cosmetic. Unrounded, this would change in its ninth
--- digit every time anyone touched an unrelated dropper, and every one of those
--- changes would rewrite build/ and land in a diff as noise.
function Config.rebirthBaseCost(): number
	local prices = Config.spinePricesDescending()
	local raw = prices[Config.Rebirth.PriceRung] or prices[#prices] or 0
	if raw <= 0 then
		return 0
	end
	local magnitude = 10 ^ (math.floor(math.log(raw, 10)) - 1)
	return math.floor(raw / magnitude + 0.5) * magnitude
end

Config.Rebirth.BaseCost = Config.rebirthBaseCost()

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
