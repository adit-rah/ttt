--[[
	Config.lua — every tunable number in Tung Tung Tycoon lives here.

	The tycoon is DATA DRIVEN. To add content you add a table entry below;
	you should never need to touch the tycoon runtime to add a dropper,
	an upgrader, or a new tier. That is the "standardized tycoon system".

	IT IS 2400 LINES AND IT IS DELIBERATELY NOT SPLIT. tools/verify_config.lua
	inlines this exact file at its `--@INJECT src/shared/Config.lua` marker and
	every one of its several hundred assertions evaluates that single chunk — a
	split would either have to be re-stitched before injection or the checks would
	quietly stop seeing half the numbers. So the answer to the length is the table
	of contents below: grep to one banner, read that section, leave the rest alone.

	DECLARATION ORDER IS LOAD-BEARING, from the button tables (~line 920) all the
	way down to the analytics field values (~line 2300). This file does real work
	at require time. The `Derived lookups` section merges the four track tables
	into Config.Buttons and Config.ButtonById — deriving each row's `requires`,
	`order` and `trackOrder` as it goes — builds TrackRank, TrackLabel, BatById and
	ArmorById, and assigns Config.Rebirth.BaseCost from the spine's prices; then the
	ANALYTICS section fills Analytics.Fields.buttonId.values from
	Config.Tracks.factory and .milestone.values from Config.Buttons. Every one of
	those reads a table declared ABOVE it, and Lua will not complain if it is not:
	moving an assignment below its consumer yields an empty field set or a nil
	price, not an error. Do not renumber or reorder sections. Append.

	Two things the whole file obeys, both because the verifier has to be able to
	require it: PLAIN NUMBERS AND THE THREE STUBBED TYPES ONLY (verify_config stubs
	Color3, Vector3 and Enum — a UDim2 or a Vector2 in any table here takes every
	config check down at require time), and NO VECTOR ARITHMETIC AT REQUIRE TIME
	(the Vector3 stub is a plain table with no operators, which is why the helpers
	at the bottom do component arithmetic instead).

	── CONTENTS, in file order. Grep the banner text; line numbers rot. ─────────

	  WORLD                Config.World — plot count, plot size, the ring the
	                       plots stand on, the arena. plotPlacements() solves the
	                       ring radius from the plot count; plotCountFor() reads
	                       Players.MaxPlayers, which is a Studio setting nothing
	                       here can enforce.
	  (no banner)          Config.Layout — plot-LOCAL coordinates for everything a
	                       Tycoon builds: belt corners, machine slots, buy-button
	                       spine, roof, Layout.Vault, Layout.Yard, Layout.Tracks.
	                       The ASCII plot map just above it is the fastest way in.
	  WORLD TEXT           Config.Style — the fonts, outlines and view distances
	                       every in-world label uses. They live here so the
	                       verifier can see them; Style.lua is the only file
	                       allowed to turn them into instances.
	  SCREEN UI            Config.UI — the reference canvas, the one UIScale
	                       formula the client mounts, and every panel and card
	                       size that used to be a literal in src/client.
	  ECONOMY              Config.Economy (currency, StartingCash, drop caps,
	                       OfflineGraceSeconds), Config.Admin (who gets the chat
	                       commands, and why it is not a prototype flag),
	                       Config.Rebirth (PriceRung, CostGrowth,
	                       MultiplierPerRebirth — BaseCost is derived far below).
	  PERSISTENCE          Config.Persistence — the retry, lock and autosave
	                       timings DataService's session lock runs on.
	  SOCIAL               Config.Social — the friend bonus, its cap, and the
	                       kill switch (BonusPerFriend = 0, which the verifier
	                       refuses to let you commit).
	  TUNG VARIANTS        Config.Variants — the visual and audio recipe shared by
	                       a dropper's spout and the bat-guy it drops.
	  THE BUTTON TABLES    Config.FactoryButtons — the spine, and the field
	                       reference for every track table. READ THIS BANNER
	                       BEFORE EDITING ANY TRACK: `requires` is derived from
	                       the row above, so table order IS dependency order.
	  COMBAT               Config.Bats and nothing else. Index is the tier and
	                       profile.batTier stores that index, so inserting a tier
	                       renumbers live saves; appending is free.
	  THE WEAPONS CABINET  Config.WeaponButtons — track 2, priced against the
	                       detour the verifier measures, not against the factory.
	  THE ARMOUR CABINET   Config.Armor (tiers, granting MaxHealth only) and
	                       Config.ArmorButtons — track 3.
	  THE GENERATOR YARD   Config.Power, Config.PowerButtons, powerFactor() —
	                       track 4 — AND THEN, sharing this section with no banner
	                       of their own, Config.Combat (swing timing, combo,
	                       walkspeed) and Config.Waves (raid pacing, the boss, and
	                       bossHealthFactor / bossRewardFactor / bossShare). If you
	                       are hunting a combat number, it is here, not under the
	                       COMBAT banner above.
	  BELT PATHS AND FLOORS
	                       Config.BeltPaths (the ground floor, derived from Layout
	                       so the two cannot drift), Config.Floors (the mezzanine)
	                       and floorBeltPath().
	  PROTOTYPES, and the graduates that used to be here
	                       Config.Prototypes — every flag ships false, and
	                       graduating a feature DELETES its flag rather than
	                       flipping it. Then three sub-banners of prototype data:
	                       `player upgrades` (Config.PlayerUpgrades), `the utility
	                       slot` (Config.Utilities), `rebirth perks`
	                       (Config.RebirthPerks).
	  SHIPPED: offline earnings and the session loops
	                       Sub-banners `offline earnings` (Config.Offline, whose
	                       Vault sub-table drives the gauge on the plot), `session
	                       loops` (Config.Sessions — streak, playtime ladder,
	                       boost, weekend) and `sound` (Config.Sound).
	  Derived lookups      THE CODE THAT RUNS AT REQUIRE TIME, and the reason
	                       order matters: World.PlotCount and the placements;
	                       TrackOrder, Tracks, TrackInfo, TrackRank, TrackLabel,
	                       TrackUnlock and trackUnlocked(); the merge into
	                       Config.Buttons and Config.ButtonById;
	                       spinePricesDescending() and Rebirth.BaseCost; BatById
	                       and ArmorById.
	  ANALYTICS            Config.Analytics (the four silent platform limits and
	                       the kill switch), .Fields (closed value sets — buttonId
	                       and milestone are FILLED from Config.Tracks.factory and
	                       Config.Buttons in the loops just below), .Events (the
	                       seven), and analyticsCombinations(), which prices the
	                       whole schema against the 8,000-combination budget.
	  (no banner, at EOF)  trackButtonPosition(), trackCabinet(),
	                       trackShelfPosition(), requirementsOf().
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
	-- The plinth the statue stands on, in the middle of the arena. It was a 26
	-- written into MapBuilder; it is here because the boss now spawns at a fixed
	-- radius from the same centre and the verifier has to be able to check that
	-- the two do not intersect. MapBuilder builds the dais from this.
	DaisRadius = 13,

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
	-- THE SPINE COLUMN MOVED FROM x = 8 TO x = 0, because it grew by two.
	--
	-- Splitting the shell into walls, gates and windows (TODO.md item 3) makes
	-- this six pedestals rather than four, and the column is bounded at BOTH
	-- ends: belt leg 1's buy-button row runs across z -47.5..-42.5 at every x
	-- from -46.5 to 48.5, so nothing can go behind z = -38, and six at the
	-- 14-stud pitch then reaches z = 36. At x = 8 that last pedestal lands 10
	-- studs from OwnerSpawnAt (14, 44) — you would respawn standing on the
	-- button that buys the storey.
	--
	-- Sliding the whole column to x = 0 buys the six studs: the same pedestal is
	-- then 16.1 from the spawn. It is also, incidentally, where a spine down the
	-- middle of an open floor belongs — x = 8 was chosen when the right half of
	-- the plot was empty and the column was the only thing in it.
	MiscButtons = {
		walls     = Vector3.new(0, 0, -34),
		gates     = Vector3.new(0, 0, -20),
		windows   = Vector3.new(0, 0,  -6),
		belt1     = Vector3.new(0, 0,   8),
		roof      = Vector3.new(0, 0,  22),
		floor2    = Vector3.new(0, 0,  36),
		-- The column runs in purchase order with the later steps nearer the
		-- gate, so the floor goes at the near end. A button with no entry here
		-- gets built at the plot origin, on top of the belt — buttonPosition
		-- falls back to (0,0,0) and says nothing about it.
	},
	MiscButtonSpacing = 14,  -- asserted minimum gap between two MiscButtons

	-- THE SAME RULE FOR A CABINET COLUMN, AND A DIFFERENT NUMBER.
	--
	-- One constant used to police both, and that was one constant doing two
	-- jobs. MiscButtonSpacing is about the misc COLUMN — five unrelated
	-- purchases (the shell, the belt, the storey) standing in a line down the
	-- middle of an open floor, where 14 studs is what stops them reading as one
	-- object. A cabinet column is the opposite case: nine pads that are
	-- deliberately one object, in front of one case, in track order.
	--
	-- 12 is what makes the armoury a single straight file. Nine pedestals at 14
	-- need 112 studs of run; the clear band down the right-hand side is 101.5,
	-- bounded at the back by belt leg 1's base and buy-button row and at the
	-- front by the wall. At 12 the run is 96 and it fits with five studs spare.
	--
	-- A pedestal is 5 wide, so 12 leaves SEVEN studs of clear floor between two
	-- pads — you cannot stand on one and wonder which one you are on, which is
	-- the entire thing either number is protecting. Below about 10 you could.
	CabinetSlotSpacing = 12,

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
	--
	-- THEY STAND ON THE GROUND FLOOR, IN ONE FILE DOWN THE RIGHT-HAND SIDE, and
	-- `floor` is ABSENT rather than set — Config.floorTopY documents nil as "the
	-- ground floor, and a legitimate answer", so the three position helpers at
	-- the bottom of this file take y = 0 for both tracks.
	--
	-- #58 moved them onto the mezzanine and this moves them back. That is a
	-- reversal, not drift: #58's own Studio list asked "does the ground floor
	-- read as emptier for having lost them?", and TODO.md item 2 is the answer.
	-- The production line is the left half and the armoury is the right half,
	-- which is the arrangement the plot had before the deck existed and the one
	-- that survives the deck now spanning the whole storey.
	--
	-- ONE FILE, BOTH CASES, WHICH IS WHY THE REBIRTH PAD MOVED. Nine pedestals
	-- on a 14-stud pitch is 112 studs of column plus 4 studs of case overhang at
	-- each end: 120 studs of display case looking for a straight run. The pad
	-- stood at (42, 40) with a 12x12 body and a 14-stud spacing rule around it,
	-- which forbade any pedestal between z 26 and z 54 — room for one slot above
	-- it and eight below, and eight below runs off the back of the plot. Moving
	-- one pad is what makes the file straight; see RebirthPadAt.
	--
	-- WHY x = 48 AND NOT HARD AGAINST THE WALL AT 54. Two solids stand at
	-- x = ±54 for the full height of the ground storey, and neither can move:
	-- the roof's columns (Structure.Roof.columnInset 3, so x = ±56, 2.4 square)
	-- and the mezzanine deck's own posts (Floors[1].pillar.insetSide 4, so
	-- x = ±54 — and widening that inset walks the LEFT pair into belt leg 2's
	-- base at x -48.6..-39.4). A 4-deep case centred at 54 spans x 52..56 and
	-- interpenetrates both. At 48 it spans 46..50 and clears the posts by 2.8.
	--
	-- The aisle then has to go inboard of the case (buttonX 40), which is the
	-- correct side anyway: you walk the armoury with the cases on your right,
	-- the mirror of walking the line with the belt on your left.
	Tracks = {
		-- weapons is the FRONT column, nearer the gateway, because refreshButtons
		-- picks the beacon target by (TrackRank, price) and weapons outranks
		-- armour — so the marker points at this cabinet first for the whole build,
		-- and the nearer aisle has to be the one it points at.
		--
		-- firstZ is not a free choice for either. Belt leg 1's buy-button row is a
		-- 95x5 box centred at (1, -45), and these pedestals share its x range, so
		-- no pedestal centre may sit between z -50 and z -40. armour's column is
		-- aligned to land on -52 and -38 rather than straddling that band.
		weapons = { cabinetX = 48, buttonX = 40, firstZ = 14, spacing = 12, slots = 5, depth = 4, height = 13 },
		armor   = { cabinetX = 48, buttonX = 40, firstZ = -36, spacing = 12, slots = 4, depth = 4, height = 13 },
	},

	-- MOVED OFF THE RIGHT-HAND WALL, so the armoury can be one straight file.
	--
	-- It was (42, 40): front-right, chosen when the right wall was empty floor.
	-- It is now the open middle of the plot, which is the one large clear area
	-- left once the line has the left half and the cases have the right — and it
	-- is on the walk from the gateway to both, rather than tucked behind one of
	-- them. Still clear of the vault, which is the constraint the old comment
	-- named and the only one that was ever about the pad itself.
	RebirthPadAt = Vector3.new(24, 0, 0),
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

-- THE ROOF AND THE WALLS NOW LIVE IN Config.Structure, near the bottom of this
-- file, because the ground storey's height is DERIVED from the mezzanine deck's
-- underside and Config.Floors is not defined until then.
--
-- Config.Layout.RoofY/RoofThickness/RoofColumn/RoofColumnInset are gone. RoofY
-- was 20 while the deck's underside was 20.4, and the roof carried a shrink rule
-- to dodge the deck — two pieces of geometry reaching into each other, each
-- correct on its own. There is one structural line now and both of them are
-- derived from it. See Config.Structure.

-- THE VAULT SHELL, which now carries a gauge as well as a sign.
--
-- Every number below was a literal inside Tycoon:buildCollector — the body's
-- 18x9x10, the sign anchor's +12, the statue's +13.5 — which is exactly the
-- situation RoofY above was written to fix. The lid is crowded: the trim sits
-- at bodyHeight + 0.4, the 20x6 sign spans y 9..15 and the statue stands over
-- both of them, so ANYTHING added to this object has to be checked against
-- three neighbours at once, and the verifier could not see a single one of
-- them while they lived in code.
--
-- The gauge therefore goes on a LATERAL face rather than on the lid. Note
-- which axis that puts it on: the body is 18 WIDE and 10 DEEP, so a lateral
-- face measures depth x height, and the window's horizontal extent is bounded
-- by bodyDepth, not by bodyWidth. That is the check in verify_config, and it
-- is the tighter of the two.
Config.Layout.Vault = {
	-- the headline shell: ground floor only, the one with the statue on it
	bodyWidth  = 18,
	bodyHeight = 9,
	bodyDepth  = 10,

	-- the plain catcher every upper floor gets instead. No sign, no statue and
	-- no gauge: a second income readout per floor would quote the whole plot.
	plainWidth  = 13,
	plainHeight = 6.5,
	plainDepth  = 8,

	signY = 12,          -- the headline board's anchor, plot-local
	signWidth = 20,
	signHeight = 6,

	statueY = 13.5,
	statueScale = 1.6,

	-- THE FILL GAUGE. A glass inlay half-sunk into the lateral face with a
	-- neon slab inside it, anchored to the window's BOTTOM edge so it grows
	-- upward like a filling tank rather than outward from the middle.
	window = {
		width     = 7,     -- along the body's depth, because this is a side face
		height    = 5,
		y         = 5.5,   -- centre, plot-local; spans 3.0 .. 8.0 of a 9-tall shell
		thickness = 0.6,
		lateral   = 9.2,   -- |x| from the body centre: 0.1 sunk, 0.5 proud of the face
	},

	-- The small print, bolted to the same face UNDER the window. It cannot go
	-- on the lid: the headline board already owns y 9..15 across the full
	-- width, and two billboards sharing that volume read as one smeared label.
	detailSignY  = 1.6,
	detailWidth  = 9,
	detailHeight = 2.2,
	detailLateral = 9.6,
}

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

	-- THE BOSS HEALTH BAR, carved OUT of the raid sign rather than added under
	-- it. The sign's total height is asserted against the arena title above it,
	-- so a bar that made the billboard taller would push the two signs into each
	-- other — the raid line gives up its bottom 2.6 studs instead, and gets them
	-- back the moment the boss is down.
	--
	-- It lives on the sign, not on your screen, for the reason written twenty
	-- lines up: the raid is where the raid IS.
	BossBarHeight = 2.6,
	-- Left and right margin, as a fraction of the sign's width, so the bar reads
	-- as sitting under the line rather than as the edge of the billboard.
	BossBarInset = 0.06,

	ButtonLocked = {
		scale = 0.7,             -- smaller
		panelAlpha = 0.78,       -- fainter panel
		strokeThickness = 1,     -- thinner outline
		textAlpha = 0.4,         -- fainter text, outline fading with it
		distance = "machine",    -- and it drops out of sight first
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SCREEN UI
--
-- Four out of five Roblox sessions are on a phone, and until this table existed
-- not one number in this file described the screen. Every panel size, margin
-- and button height was a literal in src/client/ — the one directory the
-- verifier cannot see — which is how "the upgrade shop sits on top of the NEXT
-- UPGRADE panel below 638 design pixels" became a defect with no owner: HUD.lua
-- held one of the two numbers and UpgradeUI.lua held the other, and nothing in
-- the repo could read both at once. Now something can.
--
-- PLAIN NUMBERS ONLY. tools/verify_config.lua stubs Color3, Vector3 and Enum
-- and nothing else. A single Vector2 or UDim2 in this table takes every config
-- check down at require time, which is a much worse failure than the one it
-- would be describing. Sizes are two named scalars, never a vector.
--
-- THE SCALING CONTRACT, which is what makes the rest of these numbers mean
-- anything. The client mounts ONE UIScale of
--
--     clamp(min(vx / ReferenceWidth, vy / ReferenceHeight), MinScale, MaxScale)
--
-- Taking the MIN of the two ratios is the whole trick: it buys a design canvas
-- of at least ReferenceWidth x ReferenceHeight at every aspect ratio, so every
-- offset below is correct by construction rather than correct on the machine it
-- was typed on. MinScale is the one hole in that — a landscape phone shorter
-- than MinScale * ReferenceHeight physical pixels gets a canvas shorter than
-- the reference, which is exactly the band the shop overlap lived in.
-- MaxScale is 1 because nobody asked for a HUD blown up to fill a 4K monitor.
-- ─────────────────────────────────────────────────────────────────────────────

Config.UI = {
	ReferenceWidth = 1280,
	ReferenceHeight = 720,
	MinScale = 0.62,
	MaxScale = 1.0,

	-- The gutter every panel keeps from the edge of the design canvas, and the
	-- gap between two panels stacked in one column.
	Margin = 18,
	Gap = 10,
	-- Added ON TOP of whatever the device reports as its safe-area inset. A
	-- wrong guess about a notch should cost a slightly generous gutter, not an
	-- amputated button, so the padding errs outward.
	SafeAreaPad = 12,

	-- The floor for anything a thumb has to hit, and for anything an eye has to
	-- read, both in DESIGN pixels — multiply by MinScale for the worst physical
	-- case, which is what the verifier asserts.
	MinTouchPx = 44,
	MinTextPx = 13,

	-- THREE BUTTON HEIGHTS AND NO FOURTH. `primary` is a decision you came to
	-- the panel to make (collect, confirm, rebirth), `secondary` is the way out
	-- of it, `pill` is a toggle or a claim sitting inside a row. Every one of
	-- them is >= MinTouchPx: at MinScale the old 46px confirm button landed at
	-- 28 physical pixels, under half of Apple's and Google's published minimum.
	Button = {
		primary = 56,
		secondary = 46,
		pill = 44,
	},

	-- WHAT IS RESERVED FOR ROBLOX'S OWN CONTROLS, and the one number in this
	-- table that is about a rectangle nothing in this repo draws.
	--
	-- On a touch device the engine puts the movement thumbstick in the BOTTOM
	-- LEFT and the jump button in the BOTTOM RIGHT, on a layer above ours, and
	-- there is no API a LocalScript can ask for either rectangle. The action
	-- stack shipped anchored at (1,-Margin),(1,-Margin) — 200x112 in exactly the
	-- corner the jump button occupies — so on four out of five sessions REBIRTH
	-- and the jump button were the same pixels. It looked fine on the machine it
	-- was written on, which is the failure mode this whole table exists for.
	--
	-- So both bottom corners belong to the engine and the HUD keeps off them.
	-- The number is a guess at the tallest those controls get, and it errs
	-- generous for the same reason SafeAreaPad does: being wrong should cost
	-- empty screen, not an unpressable button. Only Studio on a real phone can
	-- settle it — see docs/dev/HANDOFF_v8.md.
	TouchReserve = {
		Bottom = 170,
	},

	-- THE TOP-LEFT COLUMN. The status card, then the session panel, both one
	-- width, stacked from the top margin down.
	--
	-- THE Y OF EACH PANEL IS NO LONGER A NUMBER AT ALL. It was derived here and
	-- read by two files; it is now a UIListLayout in HUD.column(), so the two
	-- panels cannot disagree about where the column starts because neither of
	-- them is told. What survives here is ColumnBottom — derived below, and the
	-- budget the verifier holds the column to, since a list layout will happily
	-- lay a panel out past the bottom of the screen.
	ColumnWidth = 280,

	-- ONE STATUS CARD, WHERE THERE WERE TWO PANELS. It replaces CashPanel
	-- (280x126) and NextPanel (280x74), which were always read together and
	-- always in that order: what you have, then what you are saving for. Two
	-- outlined cards with a gap between them said they were two subjects.
	--
	-- THE ROW HEIGHTS ARE THE INPUT AND THE Y OF EACH ROW IS DERIVED from them,
	-- in the block below, along with the ContentHeight they add up to. Height is
	-- the one number here that is chosen rather than derived, so that the
	-- verifier has two independent numbers to assert against each other — a
	-- Height computed from the sum would fit by construction and catch nothing,
	-- which is how an assertion that cannot fail gets written. Growing a row is
	-- still a one-number edit everywhere else: the session panel's Y and the
	-- column's bottom follow Height, and Height is refused if it stops fitting.
	--
	-- The *TextPx numbers are here rather than in HUD.lua for the same reason
	-- every other number in this table is: the verifier asserts each of them
	-- against MinTextPx, and it can only assert what it can read.
	StatusCard = {
		Width  = 280,
		Height = 208,

		Pad     = 14,   -- the gutter inside the card, all four sides
		RowGap  = 6,    -- between two lines of the same group
		GroupGap = 14,  -- between the balance group and the next-purchase group

		-- THE BALANCE GROUP IS THREE LINES: the number, what it multiplies to,
		-- and the terms that got it there. The coin sits beside the first two.
		--
		-- THE CARD HAS NO BUTTON ON IT ANY MORE. There was an INVITE pill on a
		-- friend row here, and four keys plus five derived Xs and Ys existed to
		-- fit it. A control on the one surface whose whole job is to be read at a
		-- glance is a control competing with the number the game is about; the
		-- invite is a rail item now (see UI.Rail) and the friend bonus is what it
		-- always was arithmetically — a term in the multiplier, printed on the
		-- terms line with the others.
		IconSize = 48,
		IconGap  = 10,
		BalanceHeight = 46, BalanceTextPx = 38,
		MultHeight    = 22, MultTextPx    = 15,
		-- FULL WIDTH, UNLIKE THE TWO LINES ABOVE IT, which are indented past the
		-- coin. "x1.30 • 2 rebirths • 0 KOs • +20% friends" is 40 characters and
		-- the indented lines get 194 design px; at MultTextPx that truncates the
		-- moment a player has a friend in the server, which is the moment the
		-- line has something to say. A row that fits only until its feature turns
		-- on is not a row, so the terms get the card's whole content width.
		TermsHeight = 18, TermsTextPx = 13,

		-- a rule between the two groups: one card, two things to read
		DividerHeight = 2,

		-- the next-purchase group: what it is, how close you are, and by how much
		--
		-- 13 rather than the 12 the NEXT UPGRADE heading shipped at. That 12 was
		-- 7.4 physical pixels at MinScale, under both floors this file declares —
		-- MinTextPx, and the 8-px absolute the verifier holds MinTextPx to. It
		-- was a literal in HUD.lua, so nothing could read it to say so.
		HeadingHeight = 16, HeadingTextPx = 13,
		NameHeight    = 26, NameTextPx    = 18,
		-- THE BAR IS A GAUGE, NOT A CONTROL. It has to be visible at MinScale and
		-- it must not read as something to press, so it is asserted from both
		-- sides: at least 3 physical pixels tall, and under MinTouchPx.
		BarHeight = 10,
		DetailHeight = 18, DetailTextPx = 13,
	},

	-- THE SESSION PANEL, ROW BY ROW — and BOTH ITS HEIGHTS ARE DERIVED NOW.
	--
	-- Height is the ordinary panel; TallHeight is the panel with its whole
	-- optional tail showing. There used to be a third, CompactHeight = 88: the
	-- panel a build with Prototypes.Sessions OFF collapsed to. That flag
	-- graduated in #50 and the local that chose between the two heights was
	-- deleted with it — but both READS of that local were left behind, in a file
	-- that had also lost its `Req("Config")`. A height nothing can reach reads as
	-- a supported layout and is not one, so it is gone and asserted absent.
	--
	-- TALLHEIGHT SHIPPED AT 258 AND THE PANEL COULD REACH 310. 258 is the
	-- one-optional-row case, and there are two optional rows: the Vault Timer
	-- (gone at the top of the ladder) and the pending-offline row. Both are
	-- visible at once for any returning player who has not maxed the vault, and
	-- SessionUI.layoutTail() sized the panel from its own literals, so the number
	-- ColumnBottom was measured against had already been left behind by the code.
	-- OptionalRows is the input now and both heights come out of it.
	--
	-- The row geometry below was eleven literals in src/client/SessionUI.lua,
	-- three of which (STACK_TOP, ROW_HEIGHT/ROW_GAP, PANEL_BASE_HEIGHT) were
	-- hand-copies of numbers that already lived here.
	SessionPanel = {
		Width = 280,
		Pad = 14,          -- the gutter inside the panel
		RowGap = 6,        -- between two stacked rows
		TailPad = 12,      -- what the panel keeps under its last row

		-- the panel's own heading, and the weekend badge opposite it
		HeadHeight = 16, HeadTextPx = 13,
		BadgeWidth = 110,
		HeadPad = 8,       -- the heading's own inset from the panel's top

		-- a row: a title, a sub-line under it, and a claim pill on the right
		RowPad = 12,
		RowTitleHeight = 18, RowTitleTextPx = 15,
		RowSubHeight   = 16, RowSubTextPx   = 13,
		RowPadY = 8,
		ActionWidth = 66, ActionTextPx = 14,
		-- 12 shipped on the heading, the sub-lines and the badge — 7.4 physical
		-- pixels at MinScale, under both floors this file declares. It is the
		-- same defect the NEXT UPGRADE heading had, for the same reason: it was a
		-- literal in a builder and nothing could read it to say so.

		-- the fixed stack, top to bottom
		DailyY = 28, DailyHeight = 50,
		PlaytimeHeight = 56,
		BarHeight = 4, BarY = 44,   -- the playtime gauge, inside the playtime row
		BoostTextPx = 18,

		-- the optional tail
		RowHeight = 46,
		OptionalRows = 2,
	},

	-- THE TOP-RIGHT UTILITY RAIL. One item wide today and built to hold more:
	-- an icon over a caption, docked to the top-right corner, with the toast
	-- column derived to start below it rather than on top of it.
	--
	-- WHY THE INVITE IS HERE AND NOT ON THE STATUS CARD. It was a pill on the
	-- card's friend row, which put the game's only social control inside the
	-- surface a player reads to answer "can I afford the next thing yet". The
	-- rail is where a control that acts on the world outside this server belongs,
	-- and the top-right corner is reachable and out of the way of both thumbs.
	--
	-- THE CAPTION IS THE PRICE TAG. The friend row's zero state was the whole
	-- point of it — "+0% • no friends here yet" is what turns an invite into an
	-- offer — and that argument survives the move: the badge under the glyph
	-- reads what you would gain when you have nobody here, and what you are
	-- getting once you do.
	Rail = {
		ItemWidth = 56,
		ItemHeight = 72,
		Pad = 6,
		GlyphSize = 40,
		GlyphGap = 2,
		BadgeHeight = 16, BadgeTextPx = 13,
	},

	-- THE UPGRADE SHOP IS A SECOND COLUMN, not the bottom of the first. It is
	-- bottom-anchored and proportionally tall, so on a short screen it grows
	-- upwards into whatever is above it; when it shared the left column that
	-- meant the NEXT UPGRADE panel. X is derived below to clear the column
	-- outright, which is an invariant at every viewport height rather than a
	-- number that happens to hold at the height it was checked on.
	ShopPanel = {
		Width = 340,
		HeightScale = 0.58,
		MinHeight = 180,
		MaxHeight = 460,
		RowHeight = 62,      -- the whole row is the hit target, so this is a touch size
	},

	-- THE NOTIFICATION COLUMN, under the rail on the same right edge.
	--
	-- MaxCards IS ENFORCED, NOT DESCRIBED. ListHeight shipped at 500 with nothing
	-- bounding how many cards went into the frame, so a burst of toasts simply
	-- drew past the bottom of their own container — which meant ListHeight was a
	-- number no assertion could be built on. HUD.toast destroys the oldest card
	-- past this count now, so ListHeight is derived from it and the clearance
	-- against the action stack below means something.
	Toast = {
		Width = 320,
		CardHeight = 66,
		MaxCards = 4,
		-- the card's own insides, which were six literals in HUD.lua
		Pad = 8,
		BarWidth = 5,
		BarInset = 10,
		TextX = 24,
		TitleHeight = 22, TitleTextPx = 17,
		BodyHeight  = 30, BodyTextPx  = 13,
	},

	-- Rebirth over leave-plot: primary + Gap + secondary. Right edge, and raised
	-- clear of TouchReserve.Bottom rather than sitting in the corner — see that
	-- table for what is down there.
	Action = { Width = 200, Height = 112 },

	-- Modals are centred and live on the overlay layer, which is unpadded on
	-- purpose: a dimming shade SHOULD cover the notch.
	--
	-- Each card's insides are named here for the same reason every other number
	-- in this table is. Both modals were a ladder of hand-typed Ys — the offline
	-- one had seven — and a hand-typed ladder is one where growing the third row
	-- means finding the four below it by eye.
	Modal = {
		MinWidth = 300,
		MaxWidth = 470,
		MaxHeight = 330,
		Offline = {
			Width = 470, Height = 330,
			Pad = 22, TopPad = 18, RowGap = 6,
			TitleHeight  = 34, TitleTextPx  = 28,
			AwayHeight   = 20, AwayTextPx   = 14,
			AmountHeight = 60, AmountTextPx = 46,
			RateHeight   = 20, RateTextPx   = 13,
			CapHeight    = 50, CapTextPx    = 13,
			ButtonTextPx = 22,
		},
		Rebirth = {
			Width = 430, Height = 250,
			Pad = 20, TopPad = 18, RowGap = 6,
			TitleHeight = 34, TitleTextPx = 28,
			BodyHeight  = 96, BodyTextPx  = 15,
			ButtonTextPx = 20,
		},
	},
}

do
	local ui = Config.UI

	-- THE STATUS CARD, ROW BY ROW. Every Y below is an accumulation of the row
	-- heights above it, so a row that grows pushes everything under it down and
	-- the card's ContentHeight grows with it. HUD.lua reads these; it types none
	-- of them, which is the property that stopped being true the moment anyone
	-- wrote `Position = UDim2.fromOffset(14, 48)` in a builder.
	--
	-- WRITTEN THE LONG WAY ON PURPOSE. `sc` is a read shorthand; every assignment
	-- is spelled `ui.StatusCard.X`, because verify.py's config-path pass declares
	-- a key by matching `<alias>.a.b =` where the alias is `local x = Config.…`.
	-- It cannot follow a second hop, so `sc.BarY = …` would declare nothing and
	-- HUD.lua's read of it would be reported as a key Config does not have.
	local sc = ui.StatusCard
	ui.StatusCard.ContentWidth = sc.Width - sc.Pad * 2
	-- the balance group
	ui.StatusCard.TextX = sc.Pad + sc.IconSize + sc.IconGap
	ui.StatusCard.TextWidth = sc.Width - sc.TextX - sc.Pad
	ui.StatusCard.BalanceY = sc.Pad
	ui.StatusCard.MultY = sc.BalanceY + sc.BalanceHeight
	-- the coin is centred on the two lines it belongs to, not on either one
	ui.StatusCard.IconY = sc.BalanceY
		+ math.floor((sc.BalanceHeight + sc.MultHeight - sc.IconSize) / 2)
	-- The terms line closes the balance group and gets the card's full width; the
	-- two lines above it are indented past the coin.
	ui.StatusCard.TermsY = sc.MultY + sc.MultHeight
	-- the rule, centred in the gap between the two groups
	ui.StatusCard.DividerY = sc.TermsY + sc.TermsHeight
		+ math.floor((sc.GroupGap - sc.DividerHeight) / 2)
	-- the next-purchase group
	ui.StatusCard.HeadingY = sc.TermsY + sc.TermsHeight + sc.GroupGap
	ui.StatusCard.NameY = sc.HeadingY + sc.HeadingHeight
	ui.StatusCard.BarY = sc.NameY + sc.NameHeight
	ui.StatusCard.DetailY = sc.BarY + sc.BarHeight + sc.RowGap
	-- What the rows actually need. Height is chosen, not derived, so that
	-- verify_config can assert the two against each other; a Height derived from
	-- this sum would fit by construction and catch nothing.
	ui.StatusCard.ContentHeight = sc.DetailY + sc.DetailHeight + sc.Pad

	-- ── THE SESSION PANEL, ROW BY ROW, and both of its heights ───────────────
	local sp = ui.SessionPanel
	ui.SessionPanel.RowWidth = sp.Width - sp.Pad * 2
	-- a row's insides
	ui.SessionPanel.RowSubY = sp.RowPadY + sp.RowTitleHeight
	ui.SessionPanel.ActionX = sp.RowWidth - sp.RowPad - sp.ActionWidth
	ui.SessionPanel.ActionTextWidth = sp.ActionX - sp.RowPad - ui.Gap
	ui.SessionPanel.BarWidth = sp.RowWidth - sp.RowPad * 2
	-- the heading and the badge opposite it
	ui.SessionPanel.BadgeX = sp.Width - sp.Pad - sp.BadgeWidth
	-- the fixed stack
	ui.SessionPanel.PlaytimeY = sp.DailyY + sp.DailyHeight + sp.RowGap
	ui.SessionPanel.BoostY = sp.PlaytimeY + sp.PlaytimeHeight + sp.RowGap
	-- WHERE THE OPTIONAL TAIL STARTS, which SessionUI used to type as 200.
	ui.SessionPanel.StackTop = sp.BoostY + ui.Button.secondary + sp.RowGap
	-- ...and the two heights that fall out of it. Both derived: the panel is laid
	-- out at render time from whichever optional rows are showing, so a chosen
	-- Height would be a claim about code rather than an input to it. The number
	-- the verifier holds this to is ColumnBottom, above.
	ui.SessionPanel.Height = sp.StackTop + sp.TailPad
	ui.SessionPanel.TallHeight = sp.StackTop
		+ sp.OptionalRows * (sp.RowHeight + sp.RowGap) - sp.RowGap + sp.TailPad

	-- THE LEFT COLUMN'S BUDGET, and no panel Y anywhere any more.
	--
	-- ui.StatusCard.Y and ui.SessionPanel.Y used to live here and be read by two
	-- files. HUD.column() is a UIListLayout now, so the runtime stacks the panels
	-- and neither file is told a Y — but a list layout will lay its children out
	-- past the bottom of the screen just as happily as two hand-typed Ys would,
	-- so the budget stays, measured at the session panel's TALLEST. "It fits
	-- unless you have offline earnings waiting" is not a layout that fits.
	ui.ColumnBottom = ui.Margin + ui.StatusCard.Height + ui.Gap
		+ ui.SessionPanel.TallHeight

	-- ── THE TOP-RIGHT RAIL, and the notification column under it ─────────────
	local rail = ui.Rail
	ui.Rail.GlyphX = math.floor((rail.ItemWidth - rail.GlyphSize) / 2)
	ui.Rail.GlyphY = rail.Pad
	ui.Rail.BadgeY = rail.Pad + rail.GlyphSize + rail.GlyphGap
	ui.Rail.BadgeWidth = rail.ItemWidth - rail.Pad * 2
	ui.Rail.ContentHeight = rail.BadgeY + rail.BadgeHeight + rail.Pad
	ui.Rail.Bottom = ui.Margin + rail.ItemHeight

	local toast = ui.Toast
	ui.Toast.Y = ui.Rail.Bottom + ui.Gap
	ui.Toast.ListHeight = toast.MaxCards * toast.CardHeight
		+ (toast.MaxCards - 1) * ui.Gap
	ui.Toast.Bottom = toast.Y + toast.ListHeight
	-- the card's insides
	ui.Toast.BarHeight = toast.CardHeight - toast.Pad * 2
	ui.Toast.TitleY = toast.Pad
	ui.Toast.BodyY = toast.Pad + toast.TitleHeight
	ui.Toast.TextWidth = toast.Width - toast.TextX - toast.BarInset

	-- ── THE ACTION STACK, raised clear of the engine's own controls ──────────
	ui.Action.BottomGap = ui.TouchReserve.Bottom
	ui.Action.Top = ui.ReferenceHeight - ui.Action.BottomGap - ui.Action.Height

	-- the shop's own column, starting one gap clear of the left one
	ui.ShopPanel.X = ui.Margin + ui.ColumnWidth + ui.Gap
	-- What the shop leaves below itself: the toggle button always, plus the
	-- utility chip when that prototype is on.
	--
	-- NOT YET MEASURED FROM TouchReserve, and deliberately so: the shop is behind
	-- two Prototypes flags that both ship false, so it draws nothing and moving a
	-- surface nobody can see is a change nobody can check. When PlayerUpgrades
	-- graduates, this is the number that has to start at ui.TouchReserve.Bottom
	-- rather than at ui.Margin — see docs/dev/HANDOFF_v8.md.
	ui.ShopPanel.BottomGapNoUtility = ui.Margin + ui.Button.pill + ui.Gap
	ui.ShopPanel.BottomGap = ui.ShopPanel.BottomGapNoUtility + ui.Button.pill + ui.Gap

	-- ── THE TWO MODAL CARDS, row by row ──────────────────────────────────────
	local reb = ui.Modal.Rebirth
	ui.Modal.Rebirth.ContentWidth = reb.Width - reb.Pad * 2
	ui.Modal.Rebirth.TitleY = reb.TopPad
	ui.Modal.Rebirth.BodyY = reb.TopPad + reb.TitleHeight + reb.RowGap
	ui.Modal.Rebirth.ButtonWidth = math.floor((reb.ContentWidth - ui.Gap) / 2)
	ui.Modal.Rebirth.ButtonY = reb.Height - reb.Pad - ui.Button.primary
	ui.Modal.Rebirth.CancelX = reb.Pad + reb.ButtonWidth + ui.Gap
	ui.Modal.Rebirth.ContentHeight = reb.BodyY + reb.BodyHeight

	local off = ui.Modal.Offline
	ui.Modal.Offline.ContentWidth = off.Width - off.Pad * 2
	ui.Modal.Offline.TitleY = off.TopPad
	ui.Modal.Offline.AwayY = off.TopPad + off.TitleHeight
	ui.Modal.Offline.AmountY = off.AwayY + off.AwayHeight + off.RowGap
	ui.Modal.Offline.RateY = off.AmountY + off.AmountHeight
	ui.Modal.Offline.CapY = off.RateY + off.RateHeight + off.RowGap
	ui.Modal.Offline.ButtonY = off.Height - off.Pad - ui.Button.primary
	ui.Modal.Offline.ContentHeight = off.CapY + off.CapHeight
end

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
-- PERSISTENCE — the numbers behind DataService's session lock.
--
-- They live here rather than as literals in DataService for the reason
-- everything else in this file does: tools/verify.py can see this file and
-- cannot see src/server, and every one of these is a number in a RELATIONSHIP
-- with another one. tools/verify_config.lua asserts all three of them.
--
-- THE ACQUIRE WINDOW MUST OUTLAST A SOFT SHUTDOWN.
-- AcquireAttempts x AcquireRetrySeconds = 32s against a ShutdownDrainSeconds of
-- 25. The common contention case is NOT two live servers fighting over a key —
-- it is a soft shutdown, where the source server has up to 25 seconds to drain
-- and release while the player is already landing on the destination. A
-- destination that gives up sooner than the source takes to let go turns every
-- soft shutdown into a kick storm.
--
-- A LOCK MUST OUTLIVE THREE MISSED HEARTBEATS.
-- The heartbeat rides the autosave — there is no second loop, because every
-- autosave is already an UpdateAsync and refreshing the lock in that same
-- transform is free — so a lock only refreshes every AutosaveSeconds.
-- LockStaleSeconds at 300 is three missed beats plus 30s of margin. Set it
-- below 3x and an ordinary DataStore throttle on a healthy server is enough for
-- a stranger to declare it dead and take its player's save.
--
-- AND STALENESS MUST OUTLAST A WHOLE HANDOVER (25 + 32 = 57s), or a joining
-- server could call a lock dead while the server holding it is still
-- legitimately draining — which is the two-writer race this exists to close,
-- reintroduced by the timings instead of by the code.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Persistence = {
	AutosaveSeconds = 90,
	ShutdownDrainSeconds = 25,
	LockStaleSeconds = 300,
	AcquireAttempts = 8,
	-- plus up to 2s of jitter, applied per attempt. A mass teleport lands a
	-- dozen players on one server at once; unjittered retries arrive as a burst
	-- against a per-key request budget.
	AcquireRetrySeconds = 4,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SOCIAL — the one number that makes another human being worth something.
--
-- Roblox scores this place on "intentional co-play days": sessions where you
-- played with a friend through a JOIN, an INVITE or a private server rather
-- than through matchmaking. The game had no social surface at all — ten plots
-- in a ring, ten people each watching their own number — so that metric was
-- structurally zero and no amount of retention work could move it.
--
-- A friend in your server is +10% income each, capped at three. Small on
-- purpose: it has to be legible on the HUD ("+30%") and it must never out-earn
-- a prestige, which the verifier asserts against MultiplierPerRebirth.
--
-- NOT A PROTOTYPE, and deliberately without a Config.Prototypes flag —
-- verify_config asserts every remaining flag ships false, and the precedent
-- (FloorService) is that a flag is a thing you delete, not a thing you add. The
-- kill switch is BonusPerFriend = 0, on which SocialService.start() declines to
-- register its multiplier hook at all — and note the verifier REFUSES a
-- committed zero, so that is a hotfix you can paste into a live server, not a
-- state this repo will let you ship and forget about.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Social = {
	BonusPerFriend = 0.10,
	MaxFriends = 3,           -- capped +30%
	-- Seconds between IsFriendsWith calls. Friendship is resolved PAIRWISE, one
	-- web call at a time, so ten people joining at once cannot trip the
	-- per-player web throttle in a burst. The verifier asserts the whole fan-out
	-- for one joiner finishes before that joiner's first raid warning.
	ResolveGap = 0.15,
	-- A failed call is RETRIED, never cached. Caching a web failure as `false`
	-- would silently delete the bonus for the rest of the server's life.
	RetrySeconds = 20,
	InviteCooldown = 300,     -- per-player floor between RequestInvite remotes
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
	-- THE SHELL, IN THREE RUNGS. TODO.md item 3 asks for walls, then gates, then
	-- windows, and they are in that order because each one is only worth
	-- anything once the one before it is standing.
	--
	-- The wall arrives SOLID and CLOSED — bays included, glazed later. The
	-- alternative reading, where `walls` leaves the bays as holes and `windows`
	-- fills them, gives you a purchase called "Plot Walls" that does not keep a
	-- raider out; and INSTALLERS.Structure builds a bay as a box either way, so
	-- glazing is a material change on a part that already exists rather than
	-- sixty new ones. The part count does not move between these three.
	{
		id = "walls", name = "Plot Walls", price = 1500,
		kind = "Structure", structure = "walls",
		blurb = "Keeps the raiders honest.",
	},
	{
		id = "gates", name = "Sliding Gates", price = 1600,
		kind = "Structure", structure = "gates",
		blurb = "They know when you're coming.",
	},
	{
		id = "windows", name = "Glazed Bays", price = 1700,
		kind = "Structure", structure = "windows",
		blurb = "Let the neighbours watch.",
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
		blurb = "A second storey. Empty, for now.",
	},
	{
		-- THE UPSTAIRS LINE, AND IT IS NOT THE STOREY. TODO.md items 4 and 5:
		-- the mezzanine arrives barren — deck, ladder and its own wall ring —
		-- and the conveyor on it is a later purchase. Placed here in the table
		-- so the derived chain runs floor2 -> mezz_line -> mezz_dropper1; the
		-- rungs between them are what item 5's "after all of first floor" moves,
		-- and that reorder is its own change.
		--
		-- `kind = "Line"` rather than a second Floor row: verify_config refuses
		-- two Floor buttons naming one floor, and it is right to — Floors[n].button
		-- is read as "the button that builds this storey" by the rebirth perks
		-- and by FloorService. A named kind also gives every assertion below
		-- something to be about.
		id = "mezz_line", name = "The Upstairs Line", price = 1900,
		kind = "Line", floor = "mezzanine",
		blurb = "A conveyor for the empty storey.",
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
		-- 12000 BEFORE THE CABINET GATE MOVED, and the two side-track bounds
		-- squeeze from opposite ends once it does.
		--
		-- The gate is `dropper3` now rather than `floor2`, so the case opens at
		-- minute three instead of minute six. FIRST_SIDE_RUNG_BY_MINUTE measures
		-- from when the cabinet APPEARS, and at 12000 the factory does not bank
		-- it until eleven minutes after that — a case you cannot buy from for
		-- eleven minutes is the scenery that check exists to refuse. But
		-- SIDE_MAX_DETOUR_MINUTES measures price against the income you have the
		-- moment you can first afford it, and dropping the price makes THAT
		-- worse, because minute-three income is small: 10000 costs 5.8 minutes
		-- of it and 8000 costs 7.0, against a limit of 4.
		--
		-- There is no price between those two that satisfies both, which is the
		-- finding rather than the problem: 12000 was priced against a cabinet
		-- that opened at minute six with three droppers running. Against one
		-- that opens at minute three it has to be priced the way the weapons
		-- track already is — against what it does, not as a toll on the factory.
		-- `batforge` is 2500, so your first vest costing a shade under twice
		-- your first bat is the shape being asserted. At 4500 the detour is 3.6
		-- minutes and the cabinet opens with one of four rungs in reach.
		id = "armor_padded", name = "Padded Sahur", price = 4500,
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
	-- The rig's arm span in scale units: arms sit at +/-1.5 and are 1 wide, so
	-- the body is 2 * scale half-wide (see TungModels.buildNPC). It lives here
	-- because the verifier cannot see TungModels and the boss now spawns at a
	-- fixed point rather than out on the rim where nothing could be near it.
	BossBodyScale = 2.1,
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

	-- ── THE BOSS AS A SHARED OBJECTIVE ──────────────────────────────────────
	--
	-- Everything above this line describes a raid that six people can play in
	-- six separate boxes. The boss is the one thing in the game that could need
	-- another human being, and it was a bigger raider: last hit took the whole
	-- reward, nobody could see its health, and the fight did not know how many
	-- people were in it.
	--
	-- SUB-LINEAR ON PURPOSE. Ten players do not deal ten players' damage to one
	-- target: MaxChasers is 8, the boss has one hitbox and one telegraph, and on
	-- a ten-plot server most of the ten are standing on their own plot watching
	-- their own number. Scaling health linearly with headcount would make a busy
	-- server a wall instead of an event.
	--
	-- AND DAMAGE DOES NOT SCALE AT ALL. MaxBossDamage owns the "a boss may never
	-- two-shot you" ceiling and the verifier asserts it with margin against an
	-- unarmoured player; making damage a function of headcount would put that
	-- assertion at the mercy of who happens to be online.
	BossSpawnRadius = 20,       -- on the dais, fixed bearing, NOT the rim
	BossHealthPerPlayer = 0.55,
	BossMaxHealthFactor = 4.0,
	-- The pot grows SLOWER than the health, so the boss stays a fight rather
	-- than a payday. The verifier holds the ratio above 0.6 from the other end,
	-- because a boss whose pot fell far behind its health would make joining a
	-- busy server a punishment.
	BossRewardPerPlayer = 0.45,
	BossMaxRewardFactor = 3.2,
	-- Tighter than LeashRadius. A shared objective that can be kited to the far
	-- side of the arena is one that eleven people spend the fight looking for.
	BossLeashRadius = 40,
	BossMinDamageFrac = 0.02,   -- of max health, to be paid at all
	-- Of the pot, split evenly among everyone eligible; the rest is split by
	-- damage. Everyone who showed up gets something, the person who did the work
	-- gets more, and at ONE eligible player the two terms sum to exactly the pot.
	BossFloorShare = 0.35,
}

--- BOSS SCALING, SAMPLED ONCE PER WAVE.
---
--- Pure arithmetic and no Roblox types, like Config.powerFactor: the server
--- mints these into the wave record at beginWave and the verifier and the specs
--- call the same ones, rather than three copies of the formula agreeing by
--- inspection.
---
--- THE SOLO GUARANTEE. Both return exactly 1 at one player, and Config.bossShare
--- is algebraically the identity at one eligible contributor — so a 1-player
--- server gets byte-for-byte the boss it got before this existed, with no branch
--- anywhere in the code. The verifier asserts that rather than trusting this
--- paragraph.
local function scaleFor(players: number, perPlayer: number, ceiling: number): number
	local n = math.max(1, math.floor(players or 1))
	return math.min(1 + perPlayer * (n - 1), ceiling)
end

function Config.bossHealthFactor(players: number): number
	return scaleFor(players, Config.Waves.BossHealthPerPlayer, Config.Waves.BossMaxHealthFactor)
end

function Config.bossRewardFactor(players: number): number
	return scaleFor(players, Config.Waves.BossRewardPerPlayer, Config.Waves.BossMaxRewardFactor)
end

--- One player's cut of a boss pot.
---
---   myDamage       applied damage this player dealt to the boss
---   eligibleTotal  the same, summed over everyone eligible
---   eligibleCount  how many players cleared BossMinDamageFrac
---   pot            the whole reward, already scaled by bossRewardFactor
---
--- CONSERVES THE POT. Summed over the eligible it is exactly `pot`, at every
--- count and every distribution — a floor share split evenly plus the remainder
--- split by damage, and the two fractions add to one. Neither leaked nor minted,
--- which is the property a verifier can hold and a comment cannot.
function Config.bossShare(myDamage: number, eligibleTotal: number, eligibleCount: number, pot: number): number
	if eligibleCount <= 0 or pot <= 0 then
		return 0
	end
	local floorShare = Config.Waves.BossFloorShare
	local even = (pot * floorShare) / eligibleCount
	-- Falls back to an even split of the contribution half rather than dividing
	-- by zero. Unreachable while eligibility requires a positive damage floor,
	-- and it still sums to the pot if it ever is reached.
	if eligibleTotal <= 0 then
		return even + (pot * (1 - floorShare)) / eligibleCount
	end
	return even + pot * (1 - floorShare) * (myDamage / eligibleTotal)
end

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
		--
		-- IT NO LONGER GATES THE CABINETS — round 8 moved both downstairs and
		-- put their gate on dropper3 — so the argument that pinned this button to
		-- minute six is gone with them. Where it lands now is TODO.md item 3's
		-- question and it is answered when the ladder is reordered.
		button = "floor2",

		-- ...AND WHAT IT BUILDS IS THE STOREY, NOT THE LINE ON IT. TODO.md item
		-- 4: the mezzanine arrives BARREN. `button` gets you the deck, its
		-- guards, the ladder and the storey's own wall ring; `lineButton` gets
		-- you the conveyor, its corner sensors and the hopper it ends in.
		--
		-- Two buttons because they are two purchases with two different reasons.
		-- The deck is somewhere to stand and the room the building grows; the
		-- line is income. Bundling them made the storey a machine you bought
		-- rather than a place you filled, which is the thing item 4 is about.
		--
		-- The belt PATH is registered at plot construction either way and always
		-- has been — a path is pure maths, registering one builds nothing, and a
		-- buy button standing on this deck needs it to exist to know its own
		-- height.
		lineButton = "mezz_line",
		height = 22,             -- floor top, plot-local

		-- THE DECK SPANS THE PLOT, wall face to wall face on both axes: x -58..58
		-- and z -68..68 inside a 2-stud ring at ±59/±69. It covered the back 60
		-- studs of a 140-deep plot, so the deck stopped in mid-air at z = -8 and
		-- the ladder had to stand in front of that edge.
		--
		-- The cost is named rather than hidden: FloorService's header argued for
		-- the back half because "Roblox has no good answer for a ceiling", and a
		-- full-span deck roofs the ground floor. What makes it liveable is that the
		-- ground storey has 20.4 studs of headroom and PopperCam sits under it, and
		-- what makes it legible is that the walls are now glazed. It is the first
		-- item in this round's Studio list, and the levers if it plays badly are,
		-- cheapest first: more glass, a taller ground storey, or a light well over
		-- the aisle.
		deckSize = Vector3.new(116, 1.6, 136),
		deckAt = Vector3.new(0, 0, 0),

		-- WHAT IS ON THE FLOOR, AS NAMED ZONES.
		--
		-- TODO.md item 1: "make the code clean so each floor and its contents can
		-- be easily deciphered without extensive detailing". A deck rectangle plus
		-- four belt margins could not say that the back of the storey is a
		-- production line and the front is where you arrive — you had to read
		-- FloorService and Layout.Tracks and hold both in your head.
		--
		-- `line` IS DELIBERATELY THE OLD DECK RECTANGLE, to the stud. The belt is
		-- derived from this zone rather than from the deck (see Config.floorBeltPath
		-- below), so widening the deck moved no belt leg, no machine and no
		-- collector — and every belt assertion, the drop budget and the trigger
		-- dwell all still measure exactly what they measured before.
		--
		-- THE FRONT ZONE WAS `armoury` AND IT IS `landing` NOW. It was named for
		-- the two display cases #58 stood in it, and TODO.md item 2 has taken
		-- both of them back downstairs — so the name described a thing that is no
		-- longer there, and every check written against it was measuring an empty
		-- rectangle and passing for that reason. Renaming it is the cheap half;
		-- the expensive half is that the containment checks which named it are
		-- deleted rather than left standing, because an assertion that cannot
		-- fail is a guess with a check() around it.
		--
		-- What is actually in it: the stairwell, and the way onto the storey. It
		-- keeps the full deck width because the zone pair has to tile the slab —
		-- floor that belongs to neither zone is floor nothing describes.
		zones = {
			line = {
				at = Vector3.new(0, 0, -38),
				size = Vector3.new(112, 0, 60),
				holds = "the mezzanine belt, its dropper and its hopper",
			},
			landing = {
				at = Vector3.new(0, 0, 30),
				size = Vector3.new(116, 0, 76),
				holds = "the stairwell, its guard, and the open floor you arrive on",
			},
		},

		-- THE STAIRWELL, a void in the slab rather than a ladder in front of it.
		--
		-- The deck used to end at z = -8 and the ladder stood just proud of that
		-- edge, with a gap cut in the front guard to arrive through. A deck that
		-- spans the plot has no front edge to stand in front of, so the slab is
		-- built in pieces around this rectangle and the guard runs round three
		-- sides of it.
		--
		-- WHERE IT IS, and it is not where two earlier attempts put it.
		--
		-- The obvious spot is x = Layout.GateCentre 14, in line with the gateway —
		-- which is where the old ladder stood and where this hatch started. The
		-- aisle at x 9..19, z -16..-6 turns out to be the most contested strip on
		-- the storey, and it failed twice:
		--
		--   * against the mezzanine belt's BASE. The return leg runs at z = -22
		--     with an 8-stud running surface, but Belt.lua builds the base at
		--     BeltWidth + 1.2, so its inboard edge is z = -17.4 and the hatch's
		--     guard landed 0.1 studs inside it. Measuring against the surface said
		--     it cleared by a stud.
		--   * against that leg's MACHINE ROW, x -46.5..14.5, z -16.5..-11.5. Every
		--     x from the left wall to 14.5 is spoken for by a machine that could
		--     stand on leg 3, and nothing stands there today only because the
		--     floor's one dropper is on leg 1. A hole in the slab where a future
		--     dropper goes is a dropper built in mid-air.
		--
		-- So it goes in the deck's front-left quarter instead: inside the armoury
		-- zone, clear of every belt leg's machine and button bands, clear of both
		-- cabinets and their columns, and — because the truss runs from the plot
		-- floor up through the void — clear of the vault, the claim pad and the
		-- misc spine on the ground floor below. You come in the gateway and the
		-- stairs are on your left. Arrival is on the -Z lip so you step off facing
		-- into the armoury rather than out at the front wall.
		hatch = {
			-- z = 58, not 60: the slab is built in PIECES around this rectangle, so
			-- the hatch needs enough deck between it and the edge to leave a piece
			-- worth building — six studs, which is also what the perimeter guard
			-- would stand on if the deck ever pulls back from a wall.
			at = Vector3.new(-16, 0, 58),
			size = Vector3.new(8, 0, 8),
			-- WHICH LIP YOU ARRIVE OVER. The guard closes the other three sides and
			-- `ladder.gate` is the opening cut in this one. -Z faces back into the
			-- armoury, so the climb ends looking at the thing the storey is for
			-- rather than at the front wall two studs away.
			--
			-- Stated rather than chosen in the builder because two things have to
			-- agree about it — where the truss stands and where the gap is cut —
			-- and a builder that decides for itself is a builder the verifier
			-- cannot check against.
			arrival = "-Z",
		},
		-- WHERE THE LINE'S OWN BUY BUTTON STANDS, and it stands UPSTAIRS.
		--
		-- It could have gone in the misc column downstairs with the walls and the
		-- roof, and that would be one fewer moving part. It is up here because
		-- the storey is barren for as long as it takes to afford this, and a
		-- barren room with nothing in it to press is a room you climb once. It is
		-- also the only thing that makes the ladder worth using before the line
		-- exists.
		--
		-- In the landing zone, on the deck's centre line, well clear of the
		-- stairwell at (-16, 58) and of every leg of the belt it buys — the belt
		-- lives in the `line` zone, which ends at z = -8.
		lineButtonAt = Vector3.new(0, 0, 20),

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

		-- Support posts down to the plot floor, inset from the DECK's edges — and
		-- the deck is now the whole plot, so they land at x = +-54 and
		-- z = -64 / +60 rather than the x = +-52, z = -16 this comment described
		-- when the deck was the back half. They are in the corners of the building
		-- now instead of standing in the middle of the ground floor, which is a
		-- better place for a post. The verifier re-derives them and asserts they
		-- clear every dropper and upgrader box, so the numbers here are
		-- illustrative and that check is the authority.
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
			-- THERE IS NO `ladder.at` ANY MORE, and that is the point. It was
			-- Vector3.new(14, 0, -6.6): a spot just proud of the deck's front
			-- edge, correct while the deck stopped at z = -8 and meaningless once
			-- it spans the plot. It survived this round's first pass as a number
			-- the VERIFIER still measured while the builder had started deriving
			-- its own — a box nothing builds, checked for clearances against
			-- furniture it is nowhere near. Deleted, and replaced by
			-- Config.floorLadderAt below so both read one derivation.
			width = 2,                       -- a TrussPart's cross-section is 2x2
			rise = 1.5,                      -- overshoot above the deck, to step off onto
			-- The hatch guard is cut this wide on the arrival lip, because a
			-- ladder that arrives at a railing is a ladder to nowhere. The visible
			-- bar is cut with it. Six in an eight-stud lip leaves a jamb a full
			-- rail thickness wide at each end; seven would leave half of one.
			gate = 6,
		},
	},
}

--- WHERE THE TRUSS STANDS: inside the hatch, against its arrival lip.
---
--- Against the lip and not in the middle of the void, because at the top of a
--- truss you step off HORIZONTALLY. From the centre of a 10-stud hole there is
--- nothing within reach to step onto; from the far lip the hole is between you
--- and the floor. So the column hugs the lip the guard is cut in.
---
--- This exists because the builder and the verifier both need it and briefly had
--- different answers: `ladder.at` said z = -6.6 and the builder derived z = -8,
--- so every ladder clearance check measured a box nothing built. One function,
--- read by both. Component arithmetic only — the verifier's Vector3 has no
--- operators.
function Config.floorLadderAt(floor)
	local h = floor.hatch
	local inset = floor.ladder.width / 2
	if h.arrival == "-Z" then
		return Vector3.new(h.at.X, 0, h.at.Z - h.size.Z / 2 + inset)
	elseif h.arrival == "+X" then
		return Vector3.new(h.at.X + h.size.X / 2 - inset, 0, h.at.Z)
	elseif h.arrival == "-X" then
		return Vector3.new(h.at.X - h.size.X / 2 + inset, 0, h.at.Z)
	end
	return Vector3.new(h.at.X, 0, h.at.Z + h.size.Z / 2 - inset)
end

--- Where you actually stand when you step off it: just past the arrival lip, on
--- the deck. This is the point the hopper has to keep `belt.ladderClearance`
--- away from — the old check measured the deck's front edge, which after the deck
--- grew was 74 studs from the truss and passed for entirely the wrong reason.
function Config.floorLandingAt(floor)
	local h = floor.hatch
	local step = floor.ladder.width
	if h.arrival == "-Z" then
		return Vector3.new(h.at.X, 0, h.at.Z - h.size.Z / 2 - step)
	elseif h.arrival == "+X" then
		return Vector3.new(h.at.X + h.size.X / 2 + step, 0, h.at.Z)
	elseif h.arrival == "-X" then
		return Vector3.new(h.at.X - h.size.X / 2 - step, 0, h.at.Z)
	end
	return Vector3.new(h.at.X, 0, h.at.Z + h.size.Z / 2 + step)
end

--- The mezzanine's belt, as a Config.BeltPaths entry.
---
--- Three legs around the back and left of the LINE ZONE, then a return leg back
--- across it to the hopper. Derived from that zone's rectangle rather than from
--- the deck, which is the change that let the deck grow to span the plot without
--- moving a single belt leg: the zone is the old deck rectangle to the stud, so
--- every point this function returns is byte-identical to what it returned when
--- the deck WAS that rectangle. A belt derived from the deck would have spread
--- itself across the whole storey the moment the deck did, and taken the drop
--- budget, the trigger dwell and the mezzanine dropper's position with it.
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
	local zone = floor.zones.line
	local halfX, halfZ = zone.size.X / 2, zone.size.Z / 2

	local backZ = zone.at.Z - halfZ + b.back
	local frontZ = zone.at.Z + halfZ - b.front
	local rightX = zone.at.X + halfX - b.side
	local leftX = zone.at.X - halfX + b.side
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
-- THE BUILDING SHELL — walls, windows, gates and the roof
--
-- It lives HERE, after Config.Floors, because the ground storey's clear height
-- is derived from the mezzanine deck's underside, and Config.Floors is the thing
-- that states where the deck is.
--
-- WHAT WAS WRONG. The walls were five boxes emitted by INSTALLERS.Structure at a
-- local literal `h = 13`, and the roof's underside was Layout.RoofY = 20. So
-- every plot had a SEVEN-STUD OPEN BAND all the way round, above the wall and
-- below the roof, and none of the 2309 config checks looked at wall height at
-- all — not the height, not the thickness, not what the openings were. The two
-- deliberate openings (the gateway and the yard doorway) had no doors, and there
-- were no windows anywhere in the game.
--
-- ONE STRUCTURAL LINE. A storey's ceiling is the floor above it. The ground
-- storey stops at the deck's underside whether or not the deck has been bought:
-- before floor2 the roof sits on that line, after it the deck does. That is why
-- the roof's old "shrink to dodge the deck" rule is gone rather than extended —
-- it existed because two pieces of geometry were each derived separately and had
-- to be kept out of each other's way.
--
-- SPANS ARE A LIST, NOT ARITHMETIC IN A LOOP. Config.wallSegments returns the
-- solid runs and the openings of one wall of one storey, and the builder emits
-- exactly what it is given. That is what makes "the wall accounts for its whole
-- span" an assertion rather than a hope, and it is why the same function is read
-- by tools/verify_config.lua and by a runtime spec.
--
-- SCALAR ARITHMETIC ONLY, like every derived position in this file: the
-- verifier stubs Vector3 as a plain table with no operators.
Config.Structure = {
	WallThickness = 2,

	-- The neon cap along a wall's top and the interior strip at the storey line
	-- are built from the same bar. `section` reproduces the 1-stud cap the old
	-- five-box wall carried and `proud` its 0.4 of overhang, so the trim that
	-- ships is the trim that shipped. They are keys rather than literals in the
	-- builder because Config.shellPartCount has to count them: it did not, and
	-- the budget was being asserted against a number 13% below what is built.
	Trim = { section = 1, proud = 0.4 },

	-- Ground clear height is DERIVED (see below). `upper` is chosen, and the
	-- binding constraint is not headroom: a cabinet body is 13 tall and hangs its
	-- sign anchor at 15.5 with an 18x4 billboard on it, so the label reaches 17.5
	-- above the deck. At 16 the top two studs of every cabinet sign were inside
	-- the ceiling. 20 clears the sign, the dropper's arm (MachineTopY 6.9) and a
	-- player, and leaves the storey a shade lower than the ground floor's 20.4 —
	-- which is what a mezzanine should read as.
	UpperClear = 20,

	-- WINDOW BAYS. A solid run is built as three courses: a sill course from the
	-- floor to `sill`, a bay course of alternating piers and glass panes, and a
	-- head course from `sill + height` to the wall top.
	--
	-- Wide bays, few piers, deliberately: parts per run is 2n+3 where n is the
	-- pane count, and this shell is the largest single addition to a plot's part
	-- count the project has made. See PartBudget.
	Window = {
		pane = 16,
		pier = 8,
		ground = { sill = 6, height = 9 },
		upper  = { sill = 4, height = 8 },
		-- GLASS MUST STAY AT OR ABOVE 0.25. Roblox's PopperCam only treats a
		-- part as occluding when `Transparency < 0.25 and CanCollide`, so at
		-- 0.45 a glazed bay passes the camera and the light while staying solid
		-- to a player. Below 0.25 every window becomes a thing the camera
		-- shoves itself through, indoors, on a plot that is now enclosed.
		transparency = 0.45,
	},

	-- THE OPENINGS, as an inventory. Both keep height 13 — the old wall height —
	-- with a lintel course above, because a 20-stud gateway is not a door.
	Openings = {
		{
			id = "gateway", side = "front", storey = "ground",
			centre = Config.Layout.GateCentre, width = Config.Layout.GateWidth,
			height = 13, leaves = 2,
			-- Which face the leaves hang on and slide along. INBOARD here: the
			-- front wall's inside is the open aisle, and a leaf out on the grass
			-- in front of the gateway would be the first thing you see.
			face = "inboard",
		},
		{
			id = "yardDoor", side = "back", storey = "ground",
			-- The cut in the back wall onto the generator yard. Derived from the
			-- yard's own DoorFrom and the wall ring, so it cannot drift from the
			-- slab it opens onto: x = DoorFrom .. halfX.
			centre = (Config.Layout.Yard.DoorFrom + (Config.World.PlotSize.X / 2 - 1)) / 2,
			width = (Config.World.PlotSize.X / 2 - 1) - Config.Layout.Yard.DoorFrom,
			height = 13, leaves = 1,
			-- OUTBOARD, and this one is not a preference. The doorway is flush to
			-- the end of the back wall, so its single leaf can only slide inward
			-- along x — and the inside of the back wall IS the dropper row. Slot 1
			-- stands at x 38.5..43.5, z -66.5..-61.5, and an inboard leaf sliding
			-- x 33..46 passes 0.1 studs INTO it. Found by the verifier while the
			-- gate assertions were being falsified, on the shipped numbers.
			--
			-- Outboard it slides over the generator yard's own slab (x 32..60,
			-- z -97..-69), which is empty for its whole travel. The alternative
			-- was shaving `inset` to 0.1 for 0.2 studs of clearance against a
			-- machine, which is the kind of margin that becomes a bug the next
			-- time anything on that row moves.
			face = "outboard",
		},
	},

	-- GATES THAT OPEN ON APPROACH. Leaves slide along the inside face of the
	-- wall; travel is one leaf width, so the solid run beside an opening has to
	-- be at least that long (asserted).
	--
	-- Driven by a distance test on a fixed tick, NOT by Touched/TouchEnded. The
	-- teleport pads were deleted for exactly that: a character resting on a
	-- trigger bounces off its own physics jitter, which cost a cooldown, an
	-- arrival lock and a TouchEnded sweep to paper over.
	Gate = {
		thickness = 1.2,
		-- Clear air between the wall's FACE and the leaf's near face — not from
		-- the wall's centre plane. Which face is `opening.face`.
		inset = 0.4,
		triggerRadius = 20,      -- open when a humanoid is this close to the opening
		tickRate = 0.2,          -- seconds between distance tests, per claimed plot
		travelTime = 0.45,       -- tween seconds, each direction
	},

	Roof = {
		thickness = 1.4,
		column = 2.4,
		columnInset = 3,         -- in from the wall ring
		signLift = 6,            -- the company sign, above the roof's top face
	},

	-- A BUDGET, BECAUSE THIS IS THE FIRST CHANGE BIG ENOUGH THAT GUESSING IS NOT
	-- GOOD ENOUGH. The shell was ~10 parts; windows and gates take it to ~115,
	-- times ten plots. HANDOFF_v5 §4 has listed "part budget at full scale is
	-- still untested" for three rounds. Config.shellPartCount() models it from
	-- this spec and the verifier asserts the result.
	PartBudget = 200,
}

--- The two storeys, ground first. `clear` is floor-top to the underside of the
--- floor above — which for the ground storey IS the mezzanine deck's underside,
--- derived rather than typed so the wall cannot stop short of it again.
Config.Structure.Storeys = {
	{
		id = "ground",
		floorY = 0,
		-- The deck's TOP is `height`, so its underside is a full thickness below
		-- that — not half. FloorService builds the slab centred at
		-- `height - deckSize.Y/2`, which spans 20.4 .. 22.0 for today's numbers.
		-- Getting this wrong by 0.8 is a wall that ends inside the floor above it.
		clear = Config.Floors[1].height - Config.Floors[1].deckSize.Y,
	},
	{
		id = "upper",
		floorY = Config.Floors[1].height,
		clear = Config.Structure.UpperClear,
	},
}

--- Storey by id.
function Config.storey(id: string)
	for _, storey in ipairs(Config.Structure.Storeys) do
		if storey.id == id then
			return storey
		end
	end
	return nil
end

--- The underside of the roof. It sits on the top storey that exists: on the
--- ground storey's line before the mezzanine is bought, on the upper storey's
--- after. There is no half-roof state, which is the whole reason the old shrink
--- rule could go.
function Config.roofUnderside(hasFloor: boolean): number
	local storey = hasFloor and Config.storey("upper") or Config.storey("ground")
	return storey.floorY + storey.clear
end

--- One wall of the ring: the axis it runs along, its fixed coordinate on the
--- other axis, and its extent.
---
--- Note the asymmetry, which is how the shell has always been built: the side
--- walls run the FULL plot depth and the front and back walls sit between them.
--- Changing that changes four corners at once.
function Config.wallExtent(side: string)
	local halfX = Config.World.PlotSize.X / 2 - 1
	local halfZ = Config.World.PlotSize.Z / 2 - 1
	if side == "back" then
		return { axis = "X", fixed = -halfZ, from = -halfX, to = halfX, outward = -1 }
	elseif side == "front" then
		return { axis = "X", fixed = halfZ, from = -halfX, to = halfX, outward = 1 }
	elseif side == "left" then
		return { axis = "Z", fixed = -halfX, from = -Config.World.PlotSize.Z / 2,
			to = Config.World.PlotSize.Z / 2, outward = -1 }
	elseif side == "right" then
		return { axis = "Z", fixed = halfX, from = -Config.World.PlotSize.Z / 2,
			to = Config.World.PlotSize.Z / 2, outward = 1 }
	end
	return nil
end

Config.Structure.Sides = { "back", "front", "left", "right" }

--- Every opening in one wall of one storey, in order along the wall.
function Config.openingsIn(side: string, storey: string)
	local found = {}
	for _, opening in ipairs(Config.Structure.Openings) do
		if opening.side == side and opening.storey == storey then
			table.insert(found, opening)
		end
	end
	table.sort(found, function(a, b)
		return a.centre < b.centre
	end)
	return found
end

--- THE WALL, AS A LIST OF SPANS. Solid runs and openings, in order, covering
--- the whole extent with no gap and no overlap.
---
--- This is the function the builder emits from, the verifier sums, and a runtime
--- spec exercises. A wall that does not account for its own span is now a failed
--- check rather than a seven-stud band of daylight nobody measured.
function Config.wallSegments(side: string, storey: string)
	local extent = Config.wallExtent(side)
	local segments = {}
	local cursor = extent.from
	for _, opening in ipairs(Config.openingsIn(side, storey)) do
		local left = opening.centre - opening.width / 2
		local right = opening.centre + opening.width / 2
		if left > cursor then
			table.insert(segments, { kind = "solid", from = cursor, to = left })
		end
		table.insert(segments, { kind = "opening", from = left, to = right, opening = opening })
		cursor = right
	end
	if cursor < extent.to then
		table.insert(segments, { kind = "solid", from = cursor, to = extent.to })
	end
	return segments, extent
end

--- The bay course of one solid run: alternating piers and glass panes, starting
--- and ending on a pier. A run too short for a single pane is all pier.
function Config.wallBays(from: number, to: number)
	local w = Config.Structure.Window
	local length = to - from
	local panes = math.floor((length - w.pier) / (w.pane + w.pier))
	if panes < 1 then
		return { { kind = "pier", from = from, to = to } }
	end
	-- Spread the leftover across the piers so the bays stay centred in the run
	-- rather than all the slack landing on the last pier.
	local pier = (length - panes * w.pane) / (panes + 1)
	local bays = {}
	local cursor = from
	for index = 1, panes do
		table.insert(bays, { kind = "pier", from = cursor, to = cursor + pier })
		cursor += pier
		table.insert(bays, { kind = "pane", from = cursor, to = cursor + w.pane })
		cursor += w.pane
		if index == panes then
			table.insert(bays, { kind = "pier", from = cursor, to = to })
		end
	end
	return bays
end

--- How many parts one plot's shell costs, modelled from the spec above so the
--- verifier can hold it to Config.Structure.PartBudget.
---
--- Per solid run: a sill course, a head course, and the bay course's piers and
--- panes. Per opening: a lintel course over it, plus its leaves. Per side, per
--- storey: a trim cap and an interior light strip. Plus the roof slab, its four
--- columns and its sign anchor. `hasFloor` because the upper storey only exists
--- once the mezzanine is bought — the budget is asserted against the full build.
---
--- IT MUST COUNT WHAT THE BUILDER EMITS, not what the wall spec implies. Its
--- first version left out the trim, the light strip and the sign anchor, so it
--- reported 59 against 68 actually built and 107 against 124 — a budget asserted
--- 13% under the truth, which is a budget that passes right up until it matters.
--- Both numbers were reconciled against a count taken from the real builder.
function Config.shellPartCount(hasFloor: boolean): number
	local total = 0
	local storeys = hasFloor and { "ground", "upper" } or { "ground" }
	for _, storey in ipairs(storeys) do
		for _, side in ipairs(Config.Structure.Sides) do
			-- the neon cap along this wall's top, and the light strip inside it
			total += 2
			for _, segment in ipairs(Config.wallSegments(side, storey)) do
				if segment.kind == "solid" then
					total += 2   -- sill course + head course
					for _, _bay in ipairs(Config.wallBays(segment.from, segment.to)) do
						total += 1
					end
				else
					total += 1 + segment.opening.leaves   -- lintel + gate leaves
				end
			end
		end
	end
	-- the roof slab, its four columns, and the invisible anchor its sign hangs on
	return total + 6
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PROTOTYPES, and the graduates that used to be here
--
-- A flag in Config.Prototypes gates something UNSHIPPED, and every one of them
-- defaults to OFF, so a build with all the flags false is byte-for-byte the game
-- that ships today. That is the whole contract: a prototype you cannot turn off
-- is not a prototype, it is a half-finished feature you have to finish before
-- you can ship anything else.
--
-- The tables BELOW the flag table are a mix now. Config.PlayerUpgrades,
-- Config.Utilities and Config.RebirthPerks are still prototype data; the offline
-- and session families under them ship, and are ordinary Config like
-- Config.Economy.
--
-- The rationale for each of these — what shipped where, and what players said
-- about it — is in IDEAS.md. Numbers here are first drafts, not balance.
-- ─────────────────────────────────────────────────────────────────────────────

-- GRADUATING DELETES THE FLAG, IT DOES NOT SET IT TRUE. The check in
-- tools/verify_config.lua asserts every prototype flag ships off, so a feature
-- that ships stops being a prototype rather than becoming the exception to the
-- rule. `Floors`, `Offline` and `Sessions` all left this table that way, and the
-- verifier now asserts by name that they do not come back.
--
--   Floors    the second floor is a purchase on the factory track, gated by
--             owning its button like everything else.
--   Offline   offline earnings, the welcome-back panel and the Vault Timer.
--   Sessions  the daily streak, the playtime ladder, the boost button and the
--             weekend bonus.
Config.Prototypes = {
	PlayerUpgrades = false,-- walkspeed / magnet / cash multiplier shop
	Utilities = false,     -- a second weapon slot holding a verb, not a stat
	RebirthPerks = false,  -- rebirth grants four things instead of one number
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
	-- Milestone unlocks: rebirth -> what opens up. A milestone must name
	-- something NOTHING ELSE SELLS, and the verifier asserts that against both
	-- Config.Floors and Config.Buttons.
	--
	-- `[2] = { unlock = "mezzanine" }` used to sit at the top of this table and
	-- was stale from the day the second floor graduated: the mezzanine became
	-- the floor2 button on the factory track, so the milestone was either a
	-- second way to get something you had already bought or a promise of
	-- something you could not be given. Rebirth 2 grants the multiplier and the
	-- starting cash, and no unlock, until there is a real thing to unlock there.
	Milestones = {
		[4] = { unlock = "utility2", label = "Utility slot II" },
		[8] = { unlock = "goldplot", label = "Golden plot theme" },
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SHIPPED: offline earnings and the session loops
--
-- These two families used to be Config.Prototypes.Offline and .Sessions. They
-- are ordinary config now — SessionService reads them unconditionally and every
-- number below is live in front of players.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── offline earnings ─────────────────────────────────────────────────────────
Config.Offline = {
	Rate = 0.25,             -- fraction of your live income per second
	CapHours = 8,
	-- Extending the cap is a PURCHASE — the Vault Timer — which turns the cap
	-- into a goal rather than a wall you resent. Priced like a side-track rung:
	-- the verifier checks each tier against the income the factory has at the
	-- moment it can first bank that many tung.
	CapUpgradeHours = { 12, 16, 24 },
	CapUpgradeCost = { 250000, 5000000, 120000000 },
	MinimumSeconds = 120,    -- below this, don't bother with the panel

	-- THE VAULT GAUGE — offline earnings made VISIBLE ON THE WAY OUT.
	--
	-- The panel on the way back in was never the missing half. A player who has
	-- not yet been away has no reason to believe that being away pays, and a
	-- popup at logout is read by nobody: it appears at the exact moment
	-- attention has already left. So the vault wears the number instead, all
	-- session, as a column you watch and a headline you read walking off the
	-- plot — "leaving now banks X over 8h", which grows with every dropper.
	--
	-- Two modes out of one formula. Online, banked is zero, the column reads
	-- empty and the headline is the PROMISE. On return, banked is the pending
	-- offline grant, the column is full and the headline is what is WAITING.
	Vault = {
		-- Roblox will not accept a zero-height part, and a gauge that vanishes
		-- when empty reads as "broken" rather than as "nothing yet". The empty
		-- column keeps a visible sliver.
		FillMin = 0.02,
		-- The headline is the plot's own number, read from the arena; the small
		-- print resolves only when you walk up to it. Names, not studs — the
		-- numbers behind them belong to Config.Style.Distance.
		Distance = "plot",
		NearDistance = "prop",
		-- How long the column takes to drain after a claim. It has to be long
		-- enough to WATCH: the drain is the counter ticking, and a gauge that
		-- snaps to empty shows nothing at all.
		PulseSeconds = 2.0,
		-- ProximityPrompt reach. Deliberately short and unrelated to the label
		-- tiers above: a prompt you can trigger from across the plot is a
		-- prompt you trigger by accident.
		PromptDistance = 12,
		PromptHoldSeconds = 0.4,
	},
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
	--
	-- The rungs are claimed once per UTC DAY, not once per session, so these
	-- rewards are a recurring daily income rather than a one-off. The verifier
	-- checks the ladder's running total against what the factory produces over
	-- the same minutes: it must supplement the plot, never out-earn it.
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
-- minutes, and it is why they arrive on a gate rather than on claim.
--
-- THE GATE IS THE FOURTH FACTORY RUNG, NOT THE FLOOR. It was `floor2` for two
-- rounds, and that was only ever a proxy: the cabinets stood on the deck, so
-- the deck's button was the thing that could open them. With the cases back
-- downstairs (Layout.Tracks) the deck has nothing to do with it, and leaving
-- the gate on `floor2` would mean two cabinets on the ground floor appearing
-- when a storey lands above them — a coupling with no argument behind it.
--
-- `dropper3` is the fourth thing you buy, about three minutes in: late enough
-- that the opening minutes are the line and nothing else, early enough that
-- the first bat is a purchase you make during the first raid rather than after
-- it. TODO.md item 2, "after the 4th conveyor upgrade".
--
-- It must name a FACTORY button — the verifier asserts that, because a side
-- track gating a side track can deadlock — and the gate is sticky, so a rebirth
-- that wipes `dropper3` does not take both cabinets with it.
Config.TrackUnlock = { weapons = "dropper3", armor = "dropper3" }

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

-- ─────────────────────────────────────────────────────────────────────────────
-- ANALYTICS
--
-- The schema lives in Config for the same reason the fonts do: the verifier can
-- only check what it can see, and EVERY limit below is a silent counting
-- failure. Roblox does not error, warn, or drop a line in the output window when
-- you exceed one — the event is accepted, the field is discarded, and the chart
-- you look at three weeks later is simply wrong in a way that looks like data.
--
-- The four that bite, verbatim from the reference:
--
--   * THREE custom fields per event, and only under the keys
--     Enum.AnalyticsCustomFieldKeys.CustomField01/02/03. A fourth key of any
--     name is ignored.
--   * Field values must be STRINGS. A number is dropped.
--   * 8,000 unique combinations of field values PER EXPERIENCE — one shared
--     budget across every event, not a per-event allowance. This is the limit
--     that a well-meaning "let's also break it down by button" blows through,
--     and it is why nothing continuous is ever allowed into a field.
--   * 100 custom event names per experience.
--
-- The consequence of the third is the single rule this schema is built on:
-- EVERYTHING CONTINUOUS GOES IN `value`, NEVER IN A FIELD. `value` is a real
-- number Roblox aggregates for you and costs nothing from the combination
-- budget. A field is a facet, and a facet with a thousand values is a facet you
-- cannot afford.
-- ─────────────────────────────────────────────────────────────────────────────

Config.Analytics = {
	-- The kill switch. Analytics.lua ANDs this with "is a server" and "is not
	-- Studio", because the API silently no-ops on the client and in Studio.
	Enabled = true,

	-- Platform limits. Named rather than written as literals in the verifier so
	-- the failure message can quote the number that was exceeded.
	MaxFields = 3,
	MaxFieldValues = 40,      -- widest single value set we will allow ourselves
	MaxCombinations = 8000,
	MaxEventNames = 100,
	MaxEconomySkus = 100,
	MaxTransactionTypes = 20,
	MaxCurrencyTypes = 5,

	-- THE RATE LIMIT IS NOT IN THE REFERENCE DOCS. A Roblox staff forum post
	-- gives roughly 120 + 20 x CCU service calls per minute; nothing in the
	-- published documentation confirms it. Treat these two numbers as a design
	-- budget we chose, not as a contract Roblox has stated — if the real ceiling
	-- is lower we will find out by losing events silently, which is exactly why
	-- Analytics.lua counts its drops instead of assuming there are none.
	RateBurst = 120,
	RatePerPlayerPerMinute = 20,

	-- How long the join waits for the client's platform before giving up and
	-- logging "unknown". There is no edit path on a logged event, so a session
	-- that fires early with a wrong platform is wrong forever.
	HelloTimeoutSeconds = 10,
	-- Last N events kept in memory for `Analytics.tail`, which is the only way
	-- to answer "what did the server actually send" without a dashboard.
	TailSize = 64,

	-- The currency name Roblox aggregates economy events under. One currency, so
	-- the 5-type limit is not in play, but it is named so the verifier can see it.
	Currency = "Tung",
	-- Every transaction type we ever pass to LogEconomyEvent. Limit is 20 per
	-- experience and they are strings, so a typo is a new type, not an error.
	TransactionTypes = { "Shop", "Gameplay", "TimedReward" },
}

--- A FIELD is a named, CLOSED set of strings. Two shapes:
---
---   * a plain `values` list — a label per state, e.g. clipped / within_cap
---   * `bounds` + `values`, which is a bucket ladder: #values == #bounds + 1,
---     and Analytics.bucket() picks values[i] for the first bound the number
---     does not exceed. Bounds are what turn a continuous quantity into a facet
---     the combination budget can afford; the quantity itself still goes in
---     `value`, so no resolution is lost.
---
--- Two of these are DERIVED from the ladder below rather than hand-listed, so a
--- new button cannot drift out of the schema: a hand-typed button list would go
--- stale the first time someone adds a dropper, and the symptom would be a
--- purchase logged under the wrong facet rather than an error.
Config.Analytics.Fields = {
	platform = { values = { "desktop", "mobile", "tablet", "console", "vr", "unknown" } },
	-- `unknown` is the sixth entry because GetJoinData is a network call in a
	-- pcall: it can fail, and a failed read is not a direct join.
	entry = { values = { "direct", "follow_friend", "referral", "teleport", "private_server", "unknown" } },

	sessionIndex = {
		bounds = { 1, 2, 5, 20 },
		values = { "1", "2", "3-5", "6-20", "21+" },
	},
	-- Time to the first purchase of the account. The first two buckets are
	-- narrow on purpose: onboarding either lands in the first minute or it is a
	-- different conversation.
	secondsBucket = {
		bounds = { 30, 60, 180, 600 },
		values = { "0-30s", "30-60s", "1-3m", "3-10m", "10m+" },
	},
	rebirthBand = {
		bounds = { 0, 1, 3, 9 },
		values = { "0", "1", "2-3", "4-9", "10+" },
	},
	-- Time away, both for `returned` and for what the offline vault was paying
	-- against. The 6-24h bucket straddles Offline.CapHours 8 deliberately: the
	-- `clipped` field on offline_claim is what answers the cap question, and
	-- splitting this set to answer it twice would cost combinations for nothing.
	awayBucket = {
		bounds = { 600, 3600, 21600, 86400, 604800 },
		values = { "<10m", "10m-1h", "1-6h", "6-24h", "1-7d", "7d+" },
	},
	-- Minutes into the session when a rebirth landed.
	minutesBucket = {
		bounds = { 10, 30, 60, 180, 480 },
		values = { "<10m", "10-30m", "30-60m", "1-3h", "3-8h", "8h+" },
	},
	clipped = { values = { "within_cap", "clipped" } },
	friendCount = {
		bounds = { 1, 2, 3 },
		values = { "1", "2", "3", "4+" },
	},
	serverKind = { values = { "public", "private" } },

	-- DERIVED below from Config.Tracks.factory and Config.Buttons.
	buttonId = { values = {} },
	milestone = { values = {} },
}

-- The factory track and nothing else: a first purchase is an ONBOARDING signal,
-- and the side tracks are gated behind floor2 forty minutes in, so they cannot
-- be anybody's first button. Adding a fifth factory rung widens this set by one
-- and the verifier re-prices the combination budget on the next run.
for _, def in ipairs(Config.Tracks.factory) do
	table.insert(Config.Analytics.Fields.buttonId.values, def.id)
end

-- Every button on every track, plus "none" for a session that bought nothing.
-- "How far did they get before they stopped" is the whole question `session_end`
-- exists to answer, and it has to be able to answer "nowhere".
for _, def in ipairs(Config.Buttons) do
	table.insert(Config.Analytics.Fields.milestone.values, def.id)
end
table.insert(Config.Analytics.Fields.milestone.values, "none")

--- THE SEVEN EVENTS. `value` is prose: it names the number, because the number
--- is the part a dashboard cannot label for you.
---
--- `friends_in_server` is deliberately NOT called `friend_bonus_active`. There
--- is no friend bonus in this game, and an event named after a feature that does
--- not exist reads as a bug six months from now. Named for what it measures, it
--- also gives the co-play baseline BEFORE any bonus ships, which is the only
--- thing that will make the bonus's effect readable.
Config.Analytics.Events = {
	{
		name = "session_start", value = "session number",
		fields = { "platform", "entry", "sessionIndex" },
	},
	{
		name = "first_button_purchased", value = "seconds since join",
		fields = { "platform", "buttonId", "secondsBucket" },
	},
	{
		name = "session_end", value = "session seconds",
		fields = { "platform", "milestone", "rebirthBand" },
	},
	{
		name = "returned", value = "hours since last seen",
		fields = { "platform", "awayBucket", "sessionIndex" },
	},
	{
		name = "rebirth", value = "rebirth number",
		fields = { "platform", "minutesBucket", "rebirthBand" },
	},
	{
		name = "offline_claim", value = "Tung claimed",
		fields = { "platform", "clipped", "awayBucket" },
	},
	{
		name = "friends_in_server", value = "friends in server",
		fields = { "platform", "friendCount", "serverKind" },
	},
}

--- What this schema costs of the 8,000 combinations the whole EXPERIENCE gets.
---
--- Summed across events rather than maxed, because the budget is shared: two
--- events with disjoint facets each spend their own product. One function, called
--- by the verifier, by the specs and by anyone about to add a field, so nobody
--- has to re-derive the arithmetic and get it wrong in the optimistic direction.
function Config.analyticsCombinations(): number
	local total = 0
	for _, event in ipairs(Config.Analytics.Events) do
		local product = 1
		for _, field in ipairs(event.fields) do
			local set = Config.Analytics.Fields[field]
			product *= set and #set.values or 0
		end
		total += product
	end
	return total
end

--- Where a side track's buy button `slot` stands, in plot-local coordinates.
---
--- Component arithmetic on purpose: tools/verify_config.lua stubs Vector3 as a
--- plain table with no operators, so anything that adds or scales a Vector3 at
--- require time takes the whole verifier down.
--- The top face a floor's furniture stands on, plot-local. 0 for the ground
--- floor, the deck's top for anything naming a Config.Floors id.
---
--- A SCALAR, because the verifier's Vector3 has no arithmetic and the three
--- helpers below have to add this to a component. It is also why `floor` is an
--- id rather than a height: a height in Layout.Tracks would be a second copy of
--- Config.Floors[n].height, and the two would disagree the first time the deck
--- moved.
--- AN UNKNOWN ID RAISES, it does not fall back to 0.
---
--- `floor = nil` means the ground floor and is a legitimate answer. `floor =
--- "mezanine"` is a typo, and returning 0 for it would put the entire armoury
--- back on the ground floor — the exact defect this round exists to fix — with
--- nothing warned, nothing logged, and every verifier check still passing,
--- because 0 == 0. A silent fallback to the safe-looking value is how the
--- generator multiplied by one for two rounds.
---
--- Style.distance(tier) sets the precedent: an unknown tier is a programming
--- mistake, so it errors at the call site rather than picking something.
function Config.floorTopY(floorId: string?): number
	if not floorId then
		return 0
	end
	for _, floor in ipairs(Config.Floors) do
		if floor.id == floorId then
			return floor.height
		end
	end
	error(("[Tung] Config.floorTopY: no floor with id %q"):format(tostring(floorId)), 2)
end

--- The floor a `Line` button builds the conveyor on, or nil.
function Config.floorForLineButton(id: string)
	for _, floor in ipairs(Config.Floors) do
		if floor.lineButton == id then
			return floor
		end
	end
	return nil
end

--- Where that button's pedestal stands: on the deck it belongs to.
function Config.floorLineButtonPosition(floor): Vector3
	local at = floor.lineButtonAt
	return Vector3.new(at.X, Config.floorTopY(floor.id), at.Z)
end

--- Whether `floor`'s conveyor should be standing on a plot that owns `owned`.
---
--- STICKY, and derived rather than stored, for the same reason
--- Config.trackUnlocked is: a save written before the line was a purchase holds
--- `mezz_dropper1` and no `mezz_line`, and installing that dropper onto a path
--- with no conveyor under it drops its output through the deck. Owning anything
--- pinned to this floor's belt counts as owning the belt.
---
--- It costs no persisted field and no migration, which is the whole argument —
--- DataService already carries LEGACY_BAT_TIERS, so live saves are a real thing
--- to be careful of rather than a hypothetical.
function Config.floorLineBuilt(floor, owned): boolean
	if not floor.lineButton then
		return true
	end
	if owned[floor.lineButton] then
		return true
	end
	for _, def in ipairs(Config.Buttons) do
		if def.path == floor.id and owned[def.id] then
			return true
		end
	end
	return false
end

function Config.trackButtonPosition(track: string, slot: number): Vector3
	local t = Config.Layout.Tracks[track]
	return Vector3.new(t.buttonX, Config.floorTopY(t.floor), t.firstZ + (slot - 1) * t.spacing)
end

--- The cabinet body behind that column: centre, then size. Its long axis is Z,
--- running the length of its own button column with four studs of overhang at
--- each end so the case reads as containing the buttons rather than starting
--- level with them.
function Config.trackCabinet(track: string): (Vector3, Vector3)
	local t = Config.Layout.Tracks[track]
	local length = (t.slots - 1) * t.spacing + 8
	return Vector3.new(t.cabinetX, Config.floorTopY(t.floor),
			t.firstZ + (t.slots - 1) * t.spacing / 2),
		Vector3.new(t.depth, t.height, length)
end

--- Shelf slot `slot` on the cabinet — where the display for a bought tier
--- stands, so the case visibly fills up as you climb the track.
function Config.trackShelfPosition(track: string, slot: number): Vector3
	local t = Config.Layout.Tracks[track]
	return Vector3.new(t.cabinetX, Config.floorTopY(t.floor) + 5,
		t.firstZ + (slot - 1) * t.spacing)
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
