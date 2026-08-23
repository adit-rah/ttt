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
	  BELT PATHS           Config.BeltPaths (the ground line, derived from Layout
	                       so the two cannot drift). Expansion sub-belts arrive
	                       with #109.
	  LAND                 Config.LandLButtons/LandRButtons and the land helpers
	                       — the ground a plot grows into, outward from the
	                       centre.
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
	-- 2000 since #88: the ring packs maxed plots, and the furthest generator
	-- yard reaches ~918 studs out. Asserted against the packing.
	BaseplateSize = 2000,
	ArenaRadius = 70,
	ArenaWallHeight = 22,
	-- Where fresh players land: outside the outermost mob band's reach and
	-- inside the plot belt, in the quiet strip of grass. The bearing is picked
	-- by MapBuilder to sit between two plots.
	SpawnRadius = 660,
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

--- The plot belt's radius: where the belt sits for EVERY server, solved so a
--- full server's chord between neighbouring plot centres fits the MAXED
--- footprint plus the gap (land is acquired rather than reserved, so the belt
--- holds every plot fully grown). Fixed rather than sized to this server's
--- count — design:D-04, via #89: the mob bands, the spawn and every
--- plot-safety proof are static distances from the centre, and a 4-player
--- belt that contracted inward would put homes inside the mid band.
function Config.beltRadius(): number
	local pitch = (Config.World.PlotMaxWidth or Config.World.PlotSize.X) + Config.World.PlotGap
	local radius = pitch / (2 * math.sin(math.pi / Config.World.MaxPlots))
	return math.max(radius, Config.World.MinPlotRadius)
end

--- Where each plot sits: { radius, angle, ring }. One belt at the fixed
--- radius, plots spread evenly for whatever count this server built — fewer
--- plots sit further apart on the same circle, and everyone meets in the
--- middle, where the bands and the central wave are.
---
--- Note the full-server spacing is a chord, not an arc: neighbouring plot
--- centres are `2r·sin(π/n)` apart, and using the arc length instead (the old
--- `2πr/pitch` capacity formula) silently under-spaces the belt.
function Config.plotPlacements(count: number)
	local radius = Config.beltRadius()
	local placements = {}
	for i = 1, count do
		table.insert(placements, {
			radius = radius,
			angle = (i - 1) * (2 * math.pi / count),
			ring = 1,
		})
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

-- mechanism: plot-local layout. Plot origin = centre of the pad, floor top at
-- y = 0. +Z is "front" (faces the arena), -Z is the back where droppers live.
--
-- The belt runs as an L around the back and left edges rather than straight
-- through the middle, which is what puts every machine against a wall and lines
-- the buy buttons up along the inside of the run. design:D-02 for what the open
-- centre is for, and why every upgrader is downstream of every dropper.
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

	-- HOW FAR PROUD OF ITS RUNNING SURFACE THE BELT'S SOLID SLAB STANDS.
	--
	-- Belt.lua builds `BeltBase` at BeltWidth + this, so the surface is 8 studs
	-- and the collidable thing under it is 9.2. It was a literal in the builder
	-- and a MIRRORED literal in tools/verify_config, which is the coupling that
	-- put the mezzanine's hatch guard 0.1 studs inside the belt base while every
	-- check said it cleared by a stud — HANDOFF_v7 lists it as one of two
	-- builder literals wanting to become Config keys. This is that move.
	BeltBaseProud = 1.2,

	-- invariant: A RAIL IS A RUN ON ONE LEG, SET BACK FROM BOTH OF THAT LEG'S
	-- ENDS — not "a wall down the side of the belt". `corner` is the setback and
	-- is the whole of the rule. Set it to 0 and leg 2's inboard rail crosses
	-- leg 1's path and vice versa: two solid walls straight across the conveyor
	-- plus a corner block on the bend, which is what drops piled up against the
	-- first time rails existed here. The verifier asserts the property directly
	-- — a leg's rail box may not overlap any OTHER leg's running surface.
	--
	-- NOT COLLIDABLE. Drops ride a LinearVelocity in Plane mode, which pins
	-- lateral velocity to exactly zero, so nothing pushes a drop sideways and a
	-- solid rail catches nothing that would otherwise escape. It could only
	-- catch what should not be caught: INVARIANTS.md's "nothing collidable may
	-- sit near the belt except the running surface", the buy-button walk across
	-- the belt that BeltY = 1.4 exists to allow, and a 0.8-stud slot between the
	-- rail and the machine row for a raider to wedge into. design:D-03 for what
	-- the rails are there to do, which is visual.
	BeltGuard = {
		thickness = 0.8,   -- across the belt
		bite = 0.1,        -- how far the inner face is buried in the surface, so
		                   -- there are never two coplanar faces to z-fight
		kick = 0.7,        -- underside of the solid kick plate, over the surface
		height = 1.9,      -- the neon top rail's centre, over the surface
		bar = 0.35,        -- that rail's section
		-- SETBACK FROM EACH END OF A LEG, along it. Big enough to clear the
		-- corner square the surfaces overrun by half a belt width, and to clear
		-- the turn sensor's leading face.
		corner = 8,
	},
	ButtonHeight = 1.4,      -- total button height; must be low enough to run over
	MachineFootprint = 5,    -- machines are this deep along the belt

	-- distance along leg 1 (back edge) for dropper slot 1..10
	DropperDist  = { 5, 14, 23, 32, 41, 50, 59, 68, 77, 86 },
	-- distance along leg 2 (left edge) for upgrader slot 1..6
	UpgraderDist = { 14, 30, 46, 62, 78, 94 },

	-- mechanism: buttons with no machine on the belt stand in a row down the
	-- middle of the open floor, in purchase order. design:D-03 for why the aisle
	-- reads as a queue.
	--
	-- THE COLUMN IS BOUNDED AT BOTH ENDS and currently runs six pedestals deep.
	-- Belt leg 1's buy-button row occupies z -47.5..-42.5 at every x from -46.5
	-- to 48.5, so nothing can go behind z = -38; six at the 14-stud pitch then
	-- reaches z = 36. x = 0 is what keeps the far pedestal 16.1 studs clear of
	-- OwnerSpawnAt (14, 44). At x = 8 it lands 10 studs away and you respawn
	-- standing on the button that buys the storey.
	MiscButtons = {
		walls     = Vector3.new(0, 0, -34),
		gates     = Vector3.new(0, 0, -20),
		windows   = Vector3.new(0, 0,  -6),
		belt1     = Vector3.new(0, 0,   8),
		roof      = Vector3.new(0, 0,  22),
		-- The column runs in purchase order with the later steps nearer the
		-- gate, so the floor goes at the near end. A button with no entry here
		-- gets built at the plot origin, on top of the belt — buttonPosition
		-- falls back to (0,0,0) and says nothing about it.
	},
	MiscButtonSpacing = 14,  -- asserted minimum gap between two MiscButtons


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
	-- The guide (#100): a small Tung standing beside the owner's spawn aisle,
	-- inside the gateway, where every session walks past it.
	GuideAt = Vector3.new(24, 0, 40),

	-- The front wall's gateway. It sits over the open aisle on the right, NOT
	-- at x = 0: the belt and the vault occupy the left half of the plot, and a
	-- centred gate would open onto machinery.
	GateCentre = 14,
	GateWidth = 22,
}

--- invariant: HOW FAR THE BELT PHYSICALLY REACHES FROM ITS CENTRE LINE, rails
--- included. ONE DERIVATION, READ BY THE BUILDER AND BY THE VERIFIER.
---
--- The base's width was a literal in Belt.lua mirrored by a second literal in
--- tools/verify_config, and the two agreeing was luck rather than structure —
--- that is the coupling that put the mezzanine's hatch guard 0.1 studs inside
--- the belt base while every clearance check reported a stud of daylight.
---
--- The guard rails widen the belt too, so this is also what makes every
--- existing clearance check — the hatch, the pillars, the misc pedestals, the
--- zone containment, both cabinets — measure against the real object for free.
function Config.beltHalfWidth(): number
	local L = Config.Layout
	local guard = L.BeltGuard
	local base = L.BeltWidth / 2 + L.BeltBaseProud / 2
	local rail = L.BeltWidth / 2 - guard.bite + guard.thickness
	return math.max(base, rail)
end

-- The top of the tallest thing standing beside the belt: the dropper's arm,
-- whose centre MACHINE_MASSES puts at BeltY + 5, with half a stud of body above
-- that. Written here rather than measured inside Tycoon.lua because it is what
-- the buy-button label has to clear, and the verifier can only check a
-- relationship it can see. If you raise the arm, raise this.
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

-- THE ROOF AND THE WALLS LIVE IN Config.Structure, near the bottom of this
-- file, with the rest of the shell's spec.
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
	-- mechanism: A SMALL CHUNK IN THE CORNER, not a second plot. 28 x 28 is
	-- sized for what actually stands there — one generator and one pad in front
	-- of it — rather than for four of something. design:D-03 for why it shrank.
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

	-- mechanism: FOUR NAMED VIEW DISTANCES. Every label picks one of these by
	-- name, so the question at each site is "how far away does this stop
	-- mattering" rather than "what number did the last one use".
	--
	--   machine  a plate on the machine you are standing at
	--   prop     something you walk up to and use: buttons, pads, cabinets
	--   plot     your factory, read from anywhere on it or from the arena
	--   world    the arena, and finding a free plot from across the ring
	--
	-- `world` is not decoration: the two plots furthest apart on the ring are
	-- 2 * PlotRadius apart, and the claim beacon has to be findable across that
	-- gap. The verifier asserts it against the ring rather than trusting 1200.
	-- plot and world grew with the ring (#88): the pitch reserves a maxed
	-- plot's footprint, so the far side of the world moved out and a sign
	-- that cuts out before the thing it labels is a sign that lies. The
	-- verifier derives the floors these have to clear from the packing.
	Distance = {
		machine = 140,
		prop    = 220,
		plot    = 800,
		world   = 1600,
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
-- invariant: SCREEN UI. design:D-05 for what it is protecting.
--
-- Four out of five Roblox sessions are on a phone, and until this table existed
-- not one number in this file described the screen. Every panel size, margin
-- and button height was a literal in src/client/ — the one directory the
-- verifier cannot see — which is how "the upgrade shop sits on top of the NEXT
-- UPGRADE panel below 638 design pixels" became a defect with no owner: HUD.lua
-- held one of the two numbers and UpgradeUI.lua held the other, and nothing in
-- the repo could read both at once. Now something can.
--
-- invariant: PLAIN NUMBERS ONLY. tools/verify_config.lua stubs Color3, Vector3 and Enum
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
-- design:D-05 for what the canvas is protecting, and the open question about
-- whether the short-landscape band is supported at all.
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

	-- invariant: WHAT IS RESERVED FOR ROBLOX'S OWN CONTROLS, and the one number
	-- in this table that is about a rectangle nothing in this repo draws.
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

	-- mechanism: THE TOP-LEFT COLUMN. The status card, then the session panel,
	-- both one width, stacked from the top margin down.
	--
	-- THE Y OF EACH PANEL IS NOT A NUMBER. A UIListLayout in HUD.column() owns
	-- it, so the two panels cannot disagree about where the column starts
	-- because neither of them is told. What lives here is ColumnBottom —
	-- derived below, and the budget the verifier holds the column to, since a
	-- list layout will happily lay a panel out past the bottom of the screen.
	ColumnWidth = 280,

	-- mechanism: ONE STATUS CARD — what you have, then what you are saving for.
	-- design:D-05 for why that is one card rather than two.
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
		-- THE CARD CARRIES NO CONTROL. design:D-05. The invite is a rail item
		-- (see UI.Rail); the friend bonus appears here only as a term on the
		-- terms line, which is what it always was arithmetically.
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

	-- mechanism: THE SESSION PANEL, ROW BY ROW. BOTH ITS HEIGHTS ARE DERIVED.
	--
	-- Height is the ordinary panel; TallHeight is the panel with its whole
	-- optional tail showing. OptionalRows is the input and both come out of it —
	-- there are two optional rows (the Vault Timer, gone at the top of the
	-- ladder, and the pending-offline row) and both are visible at once for any
	-- returning player who has not maxed the vault. A hand-typed TallHeight
	-- describes the one-optional-row case and is short by a row.
	PartyPanel = {
		-- Row heights only; HUD.column() places the panel and sets its width.
		HeaderHeight = 22,
		RowHeight = 24,
		LayoutOrder = 3,
	},

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
	-- design:D-02 — income is Config.incomeRate added on this cadence, by
	-- Tycoon:startIncomeLoop. Longer than Economy's 0.1s replication
	-- coalescer, short enough that the counter visibly moves.
	IncomeTickSeconds = 1,
	DropLifetime = 45,          -- seconds before an orphaned drop despawns
	-- The VISUAL budget: drops are cosmetic, so past this cap a drop simply
	-- is not drawn and nothing is lost. Still a hard cap — a mega-tycoon's
	-- parts in flight is a server cost whatever the drops are worth. 80
	-- since #109: eleven belts share it, and the strips' slow spawners put
	-- the modelled peak at 75.
	MaxDropsPerPlot = 80,
	OfflineGraceSeconds = 180,  -- keep a plot reserved this long after a disconnect
}

-- design:D-02, via #93 — the vault body is the storage unit: health, a repair
-- that needs the owner present, and (with #98) the plot's overflow cap.
-- tycoon/Storage.lua is the state machine; #94 and #124 are the callers that
-- will damage it.
Config.Storage = {
	MaxHealth = 100,
	-- design:D-02, via #98 — THE CAP IS MINUTES, NOT A NUMBER. The unit holds
	-- CapMinutes of the plot's own income (rebirth term included), so it
	-- scales with progression by construction and the issue's two live KPIs
	-- fall out: it cannot be the reason the next rung is unaffordable (every
	-- single wait is under 15 minutes of income, and the cap holds 30), and
	-- it always binds on a player who stops spending (idling fills it in
	-- CapMinutes flat, inside one sitting). The third KPI — raid exposure —
	-- is #94's, measured against this same number.
	CapMinutes = 30,
	-- The floor a fresh plot gets before it earns anything: room for the
	-- opening purchases, small enough that the cap is real by minute two.
	CapFloor = 1000,
	-- A broken unit cannot bank overflow (#93's promise): while broken the
	-- cap collapses to the floor, and everything above it is lost until the
	-- owner repairs. The repair loop has stakes now.
	BrokenCapFloor = 1000,
	-- Quick and manual: long enough to be an action, short enough to finish
	-- inside a raid's warning window (asserted against Waves.WarningTime).
	RepairHoldSeconds = 2,
	-- Damage multiplier at full overflow: a stuffed unit takes double, an
	-- empty one takes base. Reads storedOverflowFraction, which is 0 until
	-- #98 gives the unit a cap.
	DamagePerOverflowFraction = 1,
}

-- mechanism: ADMIN CHAT COMMANDS. See src/server/AdminService.lua.
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
	-- design:D-03 — the pad is priced as a RUNG, not as a number, so that five
	-- spine rungs are provably still unbought when it lights up.
	--
	-- PriceRung = 10 means BaseCost is the 10th most expensive spine price;
	-- Config.rebirthBaseCost() fills it in once the spine exists, and every
	-- consumer reads it as a plain number. spinePricesDescending() derives the
	-- list from `paced`, so re-parenting a track changes what this ranks over.
	--
	-- THE RANK IS THE THING TO PRESERVE, not the number — and since #90 the
	-- rank is DEEP on purpose: the pad is a mid-arc move the player takes two
	-- or three times inside the week, and the week walk's first-rebirth-day
	-- floor is what keeps it out of the early game. Rank 10 currently prices
	-- the pad at 1.9e9 against a 1.08e12 dropper10.
	PriceRung = 10,
	CostGrowth = 2.8,            -- cost multiplier per rebirth
	MultiplierPerRebirth = 2.25, -- payout multiplier is this ^ rebirths
	MaxRebirths = 25,
	-- BaseCost is assigned below, once Config.Tracks exists. Every consumer
	-- reads it as a plain number and does not care where it came from.
}

-- ─────────────────────────────────────────────────────────────────────────────
-- invariant: PERSISTENCE — the numbers behind DataService's session lock. The
-- three relationships below are asserted, and INVARIANTS.md §1 carries them.
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
-- mechanism: SOCIAL. design:D-01 for what the friend bonus is for and why it
-- is small.
--
-- A friend in your server is +10% income each, capped at three. The cap is
-- asserted against MultiplierPerRebirth: a friend bonus that out-earns a
-- prestige has changed what the prestige is.
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

-- design:D-04, via #102 — THE PARTY. Deliberate grouping: invite, accept,
-- leave, dissolved when one member remains. A party is a trust boundary as
-- much as a bonus: partymates cannot damage each other, cannot raid each
-- other's plots, and open each other's gates — the door #89's owner-only
-- gates promised invited guests. Session-scoped; the tower (#95) enters
-- through it.
Config.Party = {
	-- Tower group size (#95) is what this number serves.
	MaxSize = 4,
	-- The income bonus per partymate in the server. A named multiplier hook
	-- ("party"), composing with the friend bonus and the help boost; the
	-- verifier bounds the full stack so the three together stay under 2x.
	BonusPerMate = 0.05,
	-- An unanswered invite dies quietly after this long.
	InviteTimeoutSeconds = 45,
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
-- mechanism: THE BUTTON TABLES — these ARE the tycoon. One per track, each a
-- chain ordered only against ITSELF. design:D-03 for what a track is and why no
-- requirement crosses one.
--
-- THE COUNT IN THIS BANNER HAS BEEN WRONG BEFORE. It said THREE for two rounds
-- after `power` was added, because a prose count is a fact stored in the one
-- place nothing reads. Config.TrackOrder is the list; this sentence is a
-- courtesy, and if the two disagree the list is right.
--
--  id        unique key, also used as the save key
--  name      shown on the button billboard
--  price     cost in Tung
--  kind      "Dropper" | "Upgrader" | "Belt" | "Power" | "Structure"
--            | "Gear" | "Armor" | "Land"
--            Tycoon.INSTALLERS is the list; KNOWN_KINDS in verify_config.lua
--            is checked against it. This line is checked by nobody.
--  requires  id (or list of ids) that must be owned first.
--            OMIT IT on a track table and the loader derives it from the row
--            above — a chain should not have to restate that it is a chain,
--            and a hand-typed `requires` is the most error-prone field here.
--  slot      position index into Layout.DropperDist / Layout.UpgraderDist
--
--  Dropper:   variant, dropValue, dropRate (seconds between drops)
--  Upgrader:  variant, multiplier
--  Belt:      speedBonus
--  Power:     factor (cumulative, not a step), variant. No slot.
--  Structure: structure ("walls" | "gates" | "windows" | "roof")
--  Gear:      grants (a Config.Bats id)
--  Armor:     grants (a Config.Armor.Tiers id)
--  Land:      side ("left" | "right"), width (studs of X; depth is the plot's)
--
-- The tables are merged into a single Config.Buttons at the bottom of this
-- file, in track order, so every consumer still iterates one array.
-- ─────────────────────────────────────────────────────────────────────────────

-- invariant: NO `requires` FIELD APPEARS BELOW, and that is the point. Table
-- order IS dependency order; the loader derives the link from the row above.
--
-- A hand-typed `requires` does not merely restate the chain, it can FORK it,
-- and a fork downstream of the root is invisible to the chain check — which
-- counts requirement-free roots. That is how the mezzanine spent two rounds as
-- a dead-end branch nothing downstream needed: you could finish the whole
-- ground floor without ever buying the floor, and both cabinets were gated on
-- it at the time. One root, no forks, and the order you read is the order you
-- buy.
--
-- THE COUNT USED TO BE HERE TOO ("twenty links"), AND IT IS GONE ON PURPOSE.
-- This table has been 21, 24 and now 20 rows long across three rounds and the
-- sentence was re-typed wrong twice. `#Config.Tracks.factory` is the number;
-- a hand-maintained copy of a length is the same defect as a hand-maintained
-- copy of a requirement, which is the entire subject of the paragraph above.
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
	-- THE SHELL USED TO BE THE NEXT THREE ROWS. It is Config.StructureButtons
	-- now — see the banner there for why the building stopped being a rung on
	-- the ladder that pays for it.
	{
		id = "dropper4", name = "Golden Tung", price = 1990,
		kind = "Dropper", slot = 4, variant = "golden",
		dropValue = 40, dropRate = 1.4,
		blurb = "Sahur, but expensive.",
	},
	{
		id = "upgrader2", name = "Sahur Bat Upgrader", price = 7420,
		kind = "Upgrader", slot = 2, variant = "golden",
		multiplier = 1.85,
		blurb = "Whacks value into them. x1.85",
	},
	{
		id = "dropper5", name = "Crimson Tung", price = 20200,
		kind = "Dropper", slot = 5, variant = "crimson",
		dropValue = 150, dropRate = 1.3,
		blurb = "It has seen things.",
	},
	{
		id = "belt1", name = "Belt Overdrive", price = 96300,
		kind = "Belt", speedBonus = 9,
		blurb = "Conveyor goes brrrr.",
	},
	{
		id = "upgrader3", name = "Tralalero Refiner", price = 107000,
		kind = "Upgrader", slot = 3, variant = "crimson",
		multiplier = 2.1,
		blurb = "Sharks approve. x2.1",
	},
	{
		id = "dropper6", name = "Neon Tung", price = 304000,
		kind = "Dropper", slot = 6, variant = "neon",
		dropValue = 620, dropRate = 1.25,
		blurb = "3am energy drink sahur.",
	},
	{
		id = "dropper7", name = "Void Tung", price = 4170000,
		kind = "Dropper", slot = 7, variant = "void",
		dropValue = 2600, dropRate = 1.2,
		blurb = "tung from beyond.",
	},
	{
		id = "upgrader4", name = "Void Furnace", price = 48100000,
		kind = "Upgrader", slot = 4, variant = "void",
		multiplier = 2.4,
		blurb = "Melts them into money. x2.4",
	},
	{
		id = "dropper8", name = "Eclipse Tung", price = 209000000,
		kind = "Dropper", slot = 8, variant = "eclipse",
		dropValue = 11000, dropRate = 1.15,
		blurb = "Sahur at the end of the night.",
	},
	{
		id = "upgrader5", name = "Eclipse Ascension", price = 1890000000,
		kind = "Upgrader", slot = 5, variant = "eclipse",
		multiplier = 2.8,
		blurb = "Ascends the tung. x2.8",
	},
	{
		id = "dropper9", name = "Galaxy Tung", price = 9440000000,
		kind = "Dropper", slot = 9, variant = "galaxy",
		dropValue = 48000, dropRate = 1.1,
		blurb = "tung tung tung across the stars.",
	},
	{
		id = "upgrader6", name = "Tung Singularity", price = 141000000000,
		kind = "Upgrader", slot = 6, variant = "galaxy",
		multiplier = 3.4,
		blurb = "Do not look directly at it. x3.4",
	},
	{
		id = "dropper10", name = "INFINITY TUNG TUNG TUNG SAHUR", price = 1080000000000,
		kind = "Dropper", slot = 10, variant = "infinity",
		dropValue = 240000, dropRate = 1.0,
		blurb = "TUNG TUNG TUNG TUNG TUNG TUNG SAHUR",
	},
}

-- design:D-03 — the building is a PARALLEL track gated on `dropper1`, so it is
-- something you buy alongside the line rather than instead of it.
--
-- mechanism: WALLS, THEN GATES, THEN WINDOWS — each is only worth anything
-- once the one before it is standing. The wall arrives SOLID and CLOSED, bays
-- included, glazed later. INSTALLERS.Structure builds a bay as a box either
-- way, so glazing is a material change on a part that already exists rather
-- than sixty new ones; the part count does not move across the first three.
--
-- THE ROOF IS ON THIS TRACK AND STILL GATES THE MEZZANINE. It is the one place
-- the shell reached back into the spine while the storey lived. Being last
-- here is load-bearing twice over: buildRoofModel derives its column positions
-- from Config.wallExtent, so a roof with no wall under it is four columns and a
-- slab standing in a field.
Config.StructureButtons = {
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
		id = "windows", name = "Glazed Bays", price = 1900,
		kind = "Structure", structure = "windows",
		blurb = "Let the neighbours watch.",
	},
	{
		id = "roof", name = "Sahur Roof + Sign", price = 690000,
		kind = "Structure", structure = "roof",
		blurb = "Now it's a real business.",
	},
}

-- design:D-02, via #88 — LAND, bought outward from the centre. Five expansions
-- a side, each narrower than the one before, so the centre pad stays the
-- largest piece and a maxed plot is 3-4x the starting footprint. Depth never
-- changes: a strip is `width` studs of X and the full PlotSize.Z of Z.
--
-- TWO TRACKS, ONE PER SIDE. Geometry forces the order within a side (L2 has
-- no meaning without L1), so each side is an ordinary chain with one
-- requirement-free root and every track assertion applies unchanged.
-- Alternation is PRICING: each pair interleaves (Ln just under Rn) with a
-- large step between pairs, so the cheapest available land purchase always
-- swings sides. A player determined to go lopsided pays the pair step for it;
-- nothing forbids it. The simulation demonstrates the alternation and the
-- verifier asserts it.
--
-- `width` on the row rather than in a second geometry table, the same way a
-- Dropper row carries dropValue: one row is the whole fact of one expansion.
-- design:D-02, via #88 and #109 — a land row is the strip; the dropper and
-- upgrader rows after it are what an expansion DELIVERS, in the strict
-- order the chain enforces: ground, then its machines, then more ground.
-- The upgrader is #93's "one additional upgrade level for every dropper
-- the plot already has", made literal: Config.incomeRate multiplies every
-- dropper by every owned upgrader, wherever either stands.
Config.LandLButtons = {
	{
		id = "landL1", name = "West Lot I", price = 197000,
		kind = "Land", side = "left", width = 44,
		blurb = "Ground to grow on.",
	},
	{
		id = "landL1_d1", name = "West Tung I", price = 295000,
		kind = "Dropper", variant = "golden",
		path = "landL1", legIndex = 1, legDistance = 20,
		dropValue = 1600, dropRate = 2.3,
		blurb = "tung, further out.",
	},
	{
		id = "landL1_u1", name = "West Refiner I", price = 431000,
		kind = "Upgrader", variant = "golden",
		path = "landL1", legIndex = 1, legDistance = 55,
		multiplier = 1.18,
		blurb = "Every dropper, a level up. x1.18",
	},
	{
		id = "landL2", name = "West Lot II", price = 4180000,
		kind = "Land", side = "left", width = 36,
		blurb = "The factory spreads west.",
	},
	{
		id = "landL2_d1", name = "West Tung II", price = 7150000,
		kind = "Dropper", variant = "crimson",
		path = "landL2", legIndex = 1, legDistance = 20,
		dropValue = 5600, dropRate = 2.2,
		blurb = "tung, further out.",
	},
	{
		id = "landL2_u1", name = "West Refiner II", price = 12000000,
		kind = "Upgrader", variant = "crimson",
		path = "landL2", legIndex = 1, legDistance = 55,
		multiplier = 1.2,
		blurb = "Every dropper, a level up. x1.2",
	},
	{
		id = "landL3", name = "West Lot III", price = 35300000,
		kind = "Land", side = "left", width = 28,
		blurb = "Further west.",
	},
	{
		id = "landL3_d1", name = "West Tung III", price = 62200000,
		kind = "Dropper", variant = "neon",
		path = "landL3", legIndex = 1, legDistance = 20,
		dropValue = 21000, dropRate = 2.1,
		blurb = "tung, further out.",
	},
	{
		id = "landL3_u1", name = "West Refiner III", price = 104000000,
		kind = "Upgrader", variant = "neon",
		path = "landL3", legIndex = 1, legDistance = 55,
		multiplier = 1.22,
		blurb = "Every dropper, a level up. x1.22",
	},
	{
		id = "landL4", name = "West Lot IV", price = 353000000,
		kind = "Land", side = "left", width = 23,
		blurb = "The neighbours moved out.",
	},
	{
		id = "landL4_d1", name = "West Tung IV", price = 616000000,
		kind = "Dropper", variant = "void",
		path = "landL4", legIndex = 1, legDistance = 20,
		dropValue = 80000, dropRate = 2.0,
		blurb = "tung, further out.",
	},
	{
		id = "landL4_u1", name = "West Refiner IV", price = 1040000000,
		kind = "Upgrader", variant = "void",
		path = "landL4", legIndex = 1, legDistance = 55,
		multiplier = 1.24,
		blurb = "Every dropper, a level up. x1.24",
	},
	{
		id = "landL5", name = "West Lot V", price = 124000000000,
		kind = "Land", side = "left", width = 19,
		blurb = "The western frontier.",
	},
	{
		id = "landL5_d1", name = "West Tung V", price = 233000000000,
		kind = "Dropper", variant = "galaxy",
		path = "landL5", legIndex = 1, legDistance = 20,
		dropValue = 230000, dropRate = 1.9,
		blurb = "tung, further out.",
	},
	{
		id = "landL5_u1", name = "West Refiner V", price = 440000000000,
		kind = "Upgrader", variant = "galaxy",
		path = "landL5", legIndex = 1, legDistance = 55,
		multiplier = 1.26,
		blurb = "Every dropper, a level up. x1.26",
	},
}

Config.LandRButtons = {
	{
		id = "landR1", name = "East Lot I", price = 217000,
		kind = "Land", side = "right", width = 44,
		blurb = "Ground to grow on.",
	},
	{
		id = "landR1_d1", name = "East Tung I", price = 324000,
		kind = "Dropper", variant = "golden",
		path = "landR1", legIndex = 1, legDistance = 20,
		dropValue = 1700, dropRate = 2.3,
		blurb = "tung, further out.",
	},
	{
		id = "landR1_u1", name = "East Refiner I", price = 474000,
		kind = "Upgrader", variant = "golden",
		path = "landR1", legIndex = 1, legDistance = 55,
		multiplier = 1.18,
		blurb = "Every dropper, a level up. x1.18",
	},
	{
		id = "landR2", name = "East Lot II", price = 4600000,
		kind = "Land", side = "right", width = 36,
		blurb = "The factory spreads east.",
	},
	{
		id = "landR2_d1", name = "East Tung II", price = 7870000,
		kind = "Dropper", variant = "crimson",
		path = "landR2", legIndex = 1, legDistance = 20,
		dropValue = 6000, dropRate = 2.2,
		blurb = "tung, further out.",
	},
	{
		id = "landR2_u1", name = "East Refiner II", price = 13200000,
		kind = "Upgrader", variant = "crimson",
		path = "landR2", legIndex = 1, legDistance = 55,
		multiplier = 1.2,
		blurb = "Every dropper, a level up. x1.2",
	},
	{
		id = "landR3", name = "East Lot III", price = 38800000,
		kind = "Land", side = "right", width = 28,
		blurb = "Further east.",
	},
	{
		id = "landR3_d1", name = "East Tung III", price = 68400000,
		kind = "Dropper", variant = "neon",
		path = "landR3", legIndex = 1, legDistance = 20,
		dropValue = 23000, dropRate = 2.1,
		blurb = "tung, further out.",
	},
	{
		id = "landR3_u1", name = "East Refiner III", price = 114000000,
		kind = "Upgrader", variant = "neon",
		path = "landR3", legIndex = 1, legDistance = 55,
		multiplier = 1.22,
		blurb = "Every dropper, a level up. x1.22",
	},
	{
		id = "landR4", name = "East Lot IV", price = 388000000,
		kind = "Land", side = "right", width = 23,
		blurb = "The neighbours moved out.",
	},
	{
		id = "landR4_d1", name = "East Tung IV", price = 678000000,
		kind = "Dropper", variant = "void",
		path = "landR4", legIndex = 1, legDistance = 20,
		dropValue = 88000, dropRate = 2.0,
		blurb = "tung, further out.",
	},
	{
		id = "landR4_u1", name = "East Refiner IV", price = 1140000000,
		kind = "Upgrader", variant = "void",
		path = "landR4", legIndex = 1, legDistance = 55,
		multiplier = 1.24,
		blurb = "Every dropper, a level up. x1.24",
	},
	{
		id = "landR5", name = "East Lot V", price = 136000000000,
		kind = "Land", side = "right", width = 19,
		blurb = "The eastern frontier.",
	},
	{
		id = "landR5_d1", name = "East Tung V", price = 256000000000,
		kind = "Dropper", variant = "galaxy",
		path = "landR5", legIndex = 1, legDistance = 20,
		dropValue = 250000, dropRate = 1.9,
		blurb = "tung, further out.",
	},
	{
		id = "landR5_u1", name = "East Refiner V", price = 484000000000,
		kind = "Upgrader", variant = "galaxy",
		path = "landR5", legIndex = 1, legDistance = 55,
		multiplier = 1.26,
		blurb = "Every dropper, a level up. x1.26",
	},
}

--- The LAND rows for one side, in purchase order, outward. The tables also
--- carry each strip's machine rows (#109), so everything geometric filters to
--- kind Land — the strips are the ground, the machines just stand on it.
function Config.landRows(side: string)
	local rows = {}
	for _, def in ipairs(side == "left" and Config.LandLButtons or Config.LandRButtons) do
		if def.kind == "Land" then
			table.insert(rows, def)
		end
	end
	return rows
end

--- Cumulative outer |x| after each expansion on one side: one entry per row,
--- starting from the centre pad's half-width. Component arithmetic only — the
--- verifier's Vector3 is a bare table with no operators.
function Config.landSteps(side: string): { number }
	local steps = {}
	local x = Config.World.PlotSize.X / 2
	for _, def in ipairs(Config.landRows(side)) do
		x += def.width
		table.insert(steps, x)
	end
	return steps
end

--- The plot's ground extents when it owns `left`/`right` expansions per side:
--- signed plot-local x, min and max.
function Config.landExtents(left: number, right: number)
	local halfX = Config.World.PlotSize.X / 2
	local leftSteps, rightSteps = Config.landSteps("left"), Config.landSteps("right")
	local minX = (left > 0) and -leftSteps[math.min(left, #leftSteps)] or -halfX
	local maxX = (right > 0) and rightSteps[math.min(right, #rightSteps)] or halfX
	return { minX = minX, maxX = maxX }
end

--- One expansion's ground slab, as signed plot-local x bounds. The strip runs
--- the plot's full depth; only x varies.
function Config.landRect(id: string)
	for _, side in ipairs({ "left", "right" }) do
		local steps = Config.landSteps(side)
		for index, def in ipairs(Config.landRows(side)) do
			if def.id == id then
				local inner = (index == 1) and Config.World.PlotSize.X / 2 or steps[index - 1]
				local outer = steps[index]
				if side == "left" then
					return { fromX = -outer, toX = -inner, side = side, index = index }
				end
				return { fromX = inner, toX = outer, side = side, index = index }
			end
		end
	end
	return nil
end

--- How many expansions each side of a plot owns. The chains make ownership a
--- prefix, so a count is the whole state.
function Config.landCounts(owned): { left: number, right: number }
	local counts = { left = 0, right = 0 }
	for _, side in ipairs({ "left", "right" }) do
		for _, def in ipairs(Config.landRows(side)) do
			if owned[def.id] == true then
				counts[side] += 1
			end
		end
	end
	return counts
end

--- Where a side's land pedestal stands, on the centre pad — always-owned
--- ground, whatever else is bought. One pedestal per side: every rung of a
--- side resolves here, which is why the land tracks preview 0 rungs (the
--- power-track precedent — a previewed pad would be built inside the lit one).
function Config.landButtonPosition(track: string): Vector3
	if track == "landL" then
		return Vector3.new(-16, 0, 30)
	end
	return Vector3.new(16, 0, 30)
end

-- design:D-02, via #109 — the sub-belt every strip arrives with. One leg,
-- running frontward down the strip, inset from the strip's INNER edge so the
-- narrowest lots still hold their machines: machines stand outboard (toward
-- the plot's outer wall), buy pedestals inboard on the aisle side.
Config.Land = {
	StripBeltInset = 5,    -- belt centre line, in from the strip's inner edge
	BeltFrom = -50,        -- the leg's start (z), back of the strip
	BeltTo = 40,           -- the leg's end (z); the collector sits past it
	CollectorZ = 52,
	DropperDistance = 20,  -- along the leg, matching the machine rows' pins
	UpgraderDistance = 55,
}

--- A strip's belt, as a Config.BeltPaths entry. Registered for every strip at
--- plot construction — a path is pure maths, and the buy buttons standing on
--- an unbought strip need it to exist to know their own place — while the
--- strip's PARTS wait for the purchase (ensureLand). Component arithmetic
--- only: the verifier's Vector3 has no operators.
function Config.landBeltPath(def)
	local rect = Config.landRect(def.id)
	local inner = (rect.side == "left") and rect.toX or rect.fromX
	local outward = (rect.side == "left") and -1 or 1
	local x = inner + outward * Config.Land.StripBeltInset
	-- resolvePath's normal for a +z leg is (-1, 0, 0) x sign, so +1 points
	-- the machines west and -1 east; either way, toward the outer wall.
	local outboardSign = (rect.side == "left") and 1 or -1
	return {
		id = def.id,
		y = 0,
		points = {
			Vector3.new(x, 0, Config.Land.BeltFrom),
			Vector3.new(x, 0, Config.Land.BeltTo),
		},
		outboard = { outboardSign },
		collectorAt = Vector3.new(x, 0, Config.Land.CollectorZ),
	}
end

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
		id = "batforge_ash", name = "Ash Bat Forge", price = 45000,
		kind = "Gear", grants = "ash",
		blurb = "Unlocks the Ash Sahur Bat.",
	},
	{
		id = "batforge_crimson", name = "Crimson Bat Forge", price = 2600000,
		kind = "Gear", grants = "crimson",
		blurb = "Unlocks the Crimson Sahur Bat.",
	},
	{
		id = "batforge2", name = "Void Bat Forge", price = 5200000,
		kind = "Gear", grants = "void",
		blurb = "Unlocks the Void Sahur Bat.",
	},
	{
		id = "batforge_eclipse", name = "Eclipse Bat Forge", price = 2500000000,
		kind = "Gear", grants = "eclipse",
		blurb = "Unlocks the Eclipse Sahur Bat.",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- design:D-04 — a tier grants MaxHealth and nothing else, and why damage
-- reduction was rejected.
--
-- invariant: ONE MONOTONE STAT KEEPS THE BOSS ASSERTION ONE LINE OF
-- ARITHMETIC. Effective HP under health AND reduction is health/(1-dr) — two
-- variables multiplying into the single check that guarantees a boss cannot
-- burst you down, which currently passes with 0.13s of margin.
--
-- Reduction stays cheap to add later: CombatService.damage holds the only
-- TakeDamage call in the repo, so there is exactly one place to put it.
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
		-- design:D-03 — a detour rung is priced against WHAT IT DOES, not as a
		-- toll on the factory. `batforge` is 2500, so a first vest at a shade
		-- under twice a first bat is the shape.
		--
		-- THE TWO SIDE-TRACK BOUNDS SQUEEZE FROM OPPOSITE ENDS, which is why
		-- this number is not free. FIRST_SIDE_RUNG_BY_MINUTE measures from when
		-- the cabinet APPEARS and refuses a case you cannot buy from for
		-- eleven minutes; SIDE_MAX_DETOUR_MINUTES measures price against the
		-- income you have the moment you can first afford it, and dropping the
		-- price makes that one worse because minute-three income is small
		-- (10000 costs 5.8 minutes of it, 8000 costs 7.0, against a limit of 4).
		-- At 4500 the detour is 3.6 minutes and the cabinet opens with one of
		-- four rungs in reach.
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
		id = "armor_void", name = "Void Carapace", price = 1000000,
		kind = "Armor", grants = "void",
		blurb = "It absorbs the tung.",
	},
	{
		id = "armor_eclipse", name = "Eclipse Aegis", price = 28000000,
		kind = "Armor", grants = "eclipse",
		blurb = "Sahur cannot reach you here.",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- invariant: THE GENERATOR SPEEDS THE DROPPERS AND THE BELT TOGETHER, at the
-- same rate, and that pairing is the only way the feature works at all.
--
-- Income is dropValue/dropRate and does not depend on belt speed; what belt
-- speed decides is how CROWDED the belt is. Drops in flight are
-- peakRate x length / speed, so scaling rate alone is a straight multiplier on
-- how many are on the belt at once — and the plot is already at 88% of
-- MaxDropsPerPlot. A x1.4 generator on the droppers alone puts it over the cap,
-- at which point spawnDrop starts silently eating the income you just paid for.
-- Scaling both leaves the number in flight exactly where it was.
--
-- design:D-02 for the drop budget this is bounded by.
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
		id = "power1", name = "Diesel Generator", price = 14000,
		kind = "Power", factor = 1.19, variant = "golden",
		blurb = "The whole line runs 19% faster.",
	},
	{
		id = "power2", name = "Twin Turbine", price = 550000,
		kind = "Power", factor = 1.42, variant = "crimson",
		blurb = "The whole line runs 42% faster.",
	},
	{
		id = "power3", name = "Sahur Reactor", price = 3000000,
		kind = "Power", factor = 1.68, variant = "void",
		blurb = "The whole line runs 68% faster.",
	},
	{
		id = "power4", name = "Tung Fusion Core", price = 300000000,
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

--- design:D-02 — THE income model, in the one file all three readers reach.
--- Tung/sec for a factory owning `has(id)`: dropper value over rate, summed,
--- times every owned upgrader, times the generator. Per-player terms (rebirth,
--- session multipliers) belong to the callers — Tycoon:incomePerSecond adds
--- the live multiplier stack, SessionService.incomePerSecondFor adds the
--- rebirth term from a saved profile, and the verifier's progression
--- simulation uses this number raw. Pure arithmetic, like Config.powerFactor,
--- so the verifier can execute it.
function Config.incomeRate(has: (string) -> boolean): number
	local total, upgradeMult = 0, 1
	for id, def in pairs(Config.ButtonById) do
		if has(id) then
			if def.kind == "Dropper" then
				total += def.dropValue / def.dropRate
			elseif def.kind == "Upgrader" then
				upgradeMult *= def.multiplier
			end
		end
	end
	return total * upgradeMult * Config.powerFactor(has)
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

-- design:D-04, via #94 — RAIDING. A safe amount is untouchable; only the
-- overflow above it is ever at risk, and every number here is a KPI made
-- config: a raid never costs more than a few minutes of the victim's income
-- (recovered inside one sitting), an empty unit still pays the raider
-- (minted — the defender loses nothing), and camping one target halves its
-- spoils per repeat until it is worthless. The loot is CARRIED until the
-- raider reaches their own plot, and killing the carrier returns it.
Config.Raid = {
	-- The untouchable fraction of the storage cap. Overflow = cash above it,
	-- and overflow is the only Tung any raid mechanism can reach.
	SafeFraction = 0.5,
	-- What one storage-unit break takes, as a fraction of overflow. With the
	-- cap at 30 minutes of income, a full-worst-case raid costs
	-- 0.35 x 0.5 x 30 = 5.25 minutes — asserted under RecoveryMinutes.
	SpillFraction = 0.35,
	-- Breaking an EMPTY unit mints this fraction of the victim's cap for the
	-- raider; the defender loses nothing. Raiding always rewards the raider.
	EmptyBountyFraction = 0.05,
	-- A player kill takes this fraction of the victim's overflow, wherever
	-- combat is legal — the smaller vector, available everywhere.
	KillStealFraction = 0.1,
	-- Repeat spoils from the same victim halve per break inside the window.
	CampingHalving = 0.5,
	CampingWindowSeconds = 1800,
	-- The KPI ceiling the spill arithmetic is asserted under: a raid's worst
	-- case must be re-earnable inside one sitting.
	RecoveryMinutes = 8,
}

-- design:D-04, via #89 — THE OPEN WORLD. The plots hold the belt at the rim
-- and danger concentrates inward: three fixed bands of roaming mobs between
-- the belt and the centre, strongest in the middle, so difficulty is
-- geography a player walks toward and a fresh player meets only what suits
-- them near home. Fixed bands rather than levels scaled to the nearest
-- player, so the world is learnable and every safety line is assertable.
Config.Mobs = {
	Enabled = true,
	-- The bands, inmost first: annuli by flat distance from the world centre.
	-- `level` feeds the same growth curves as the central wave (BaseHealth x
	-- HealthGrowth^(level-1), damage capped at MaxDamage), and `count` is the
	-- band's standing population.
	Bands = {
		{ name = "core",      inner = 0,   outer = 150, level = 15, count = 8 },
		{ name = "mid",       inner = 150, outer = 400, level = 8,  count = 8 },
		{ name = "outskirts", inner = 400, outer = 560, level = 2,  count = 8 },
	},
	-- Home patches keep this clear of their band's edges, so a roamer's
	-- wander never straddles a boundary.
	HomeMargin = 20,
	-- The census: how often a short band is refilled, one body at a time.
	RespawnSeconds = 18,
	MaintainInterval = 3,
}

-- design:D-04, via #89 — THE PLOT WAVE. The server-wide climbing raid is
-- gone; it is the stated problem (a fresh player joining a busy server walked
-- into wave 40). Each plot now runs its own small cycle: raiders spawn in the
-- grass outside YOUR gate at a level set by YOUR plot's progression, press
-- the gate (#124's mobs, finally arrived), and stream in when it breaks. The
-- central wave at the dais is the one shared event, and it may still climb —
-- nobody stands in the core by accident.
Config.PlotWave = {
	Enabled = true,
	-- Quiet time between one plot raid clearing and the next warning, plus a
	-- jitter so ten plots' sirens do not sound in chorus.
	RestSeconds = 240,
	RestJitter = 60,
	-- Wave size by plot level, capped WELL under MaxChasers — a plot wave is
	-- pressure to come home, never the wall a central wave is.
	BaseCount = 3,
	MaxCount = 6,
	-- How many raiders press the gate at once; the rest mill. This is the
	-- breach-floor arithmetic's input, so the verifier can promise how long
	-- the gate holds.
	GateSlots = 3,
	-- The whole siege despawns after this long, cleared or not.
	MaxSiegeSeconds = 150,
	-- At most this many plots under siege at once. The stagger is what keeps
	-- the world part budget bounded with ten plots occupied.
	MaxConcurrent = 3,
}

-- The whole world's NPC ceiling: the central wave's worst case, every band's
-- standing population and every concurrent plot siege, all alive at once.
-- The verifier sums the real worst case against this.
-- Raised for the tower (#95): its platforms fight far above the world but
-- their bodies still count. Central wave + bands + sieges + concurrent runs.
Config.Mobs.MaxWorldNPCParts = 3600

--- The plot wave's level: the plot's own progression, never the server's
--- lifetime. Expansions are the plot's size and rebirths its age; the cap
--- keeps a maxed veteran's raid inside the damage ceilings.
function Config.plotWaveLevel(expansions: number, rebirths: number): number
	return math.min(1 + expansions + rebirths * 2, 12)
end

-- design:D-04, via #123 — HELPING PAYS. The counterweight to raiding: a
-- server where everyone is prey loses its new players, so kindness earns a
-- persistent reputation stat and a short income boost, weighted toward
-- helping someone earlier in the game than you. The boost is minutes of a
-- small multiplier — two accounts farming each other at this scale is
-- acceptable, which is what removes the need for an abuse system.
Config.Help = {
	-- The income multiplier a fresh act of help grants, and for how long.
	-- Deliberately small: the reward must never be the point of the game.
	BoostMultiplier = 1.2,
	BoostMinutes = 2,
	-- Repeated help extends the boost, to at most this far ahead.
	MaxBoostMinutes = 10,
	-- The progression-gap weighting: each rebirth the helper has over the
	-- helped adds this to the credit's weight, up to MaxWeight. A veteran
	-- pulling a new player up comes out ahead of two peers pairing.
	GapWeightPerRebirth = 0.5,
	MaxWeight = 3,
	-- One helper-helped pair earns credit at most this often. Longer than
	-- the boost it grants, so one tame pair cannot hold a boost forever.
	PairCooldownSeconds = 300,
}

-- design:D-01, via #97 — DAILY OBJECTIVES AND THE HINT LINE. A short list of
-- things to do today, paid in MINUTES OF YOUR OWN INCOME on completion (the
-- tower's denomination — it scales with the player and structurally cannot
-- out-earn the plot for long, and the verifier bounds the day's total).
-- Objectives are per-account per-day: progress is a baseline snapshot taken
-- at the day's first beat, measured against live profile stats, and the
-- daily reset is the same day-number arithmetic the tower uses. The draw is
-- the tower's seeded deal, so every server offers the same three that day.
Config.Objectives = {
	PerDay = 3,
	-- What one day's objectives may pay IN TOTAL, in minutes of income. The
	-- streak and the offline grant are why players log in; this is a nudge.
	MaxDayMinutes = 12,
	Pool = {
		{ id = "kills5", name = "Knock down 5 Sahur", stat = "kills", count = 5, rewardMinutes = 3 },
		{ id = "kills12", name = "Knock down 12 Sahur", stat = "kills", count = 12, rewardMinutes = 4 },
		{ id = "buys3", name = "Buy 3 upgrades", stat = "buys", count = 3, rewardMinutes = 2 },
		{ id = "buys7", name = "Buy 7 upgrades", stat = "buys", count = 7, rewardMinutes = 4 },
		{ id = "kind1", name = "Do somebody a kindness", stat = "reputation", count = 1, rewardMinutes = 3 },
		{ id = "tower3", name = "Clear 3 tower floors", stat = "towerBest", count = 3, rewardMinutes = 4 },
	},
}

--- The day's draw: PerDay distinct pool rows, dealt by the same seeded LCG
--- the tower uses, identical on every server that day.
function Config.objectivesFor(daySeed: number)
	local pool = Config.Objectives.Pool
	local state = daySeed * 668265263 + 374761393
	local function nextRandom(n: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return (state % n) + 1
	end
	local indices = {}
	for i = 1, #pool do
		indices[i] = i
	end
	for i = #indices, 2, -1 do
		local swap = nextRandom(i)
		indices[i], indices[swap] = indices[swap], indices[i]
	end
	local drawn = {}
	for i = 1, math.min(Config.Objectives.PerDay, #pool) do
		drawn[i] = pool[indices[i]]
	end
	return drawn
end

-- The hint line: the first of these the player has not done yet, shown on
-- the objectives card and spoken by the guide (#100). Non-purchase
-- milestones only — the beacon and the NEXT card already own purchases.
Config.Hints = {
	{ id = "firstKill", text = "Sahur roam the grass outside. Knock one down — kills pay.", stat = "kills", atLeast = 1 },
	{ id = "firstKindness", text = "Repair a stranger's wall, or down a thief. Kindness pays Rep and a boost.", stat = "reputation", atLeast = 1 },
	{ id = "firstRebirth", text = "The rebirth pad multiplies everything after it. The re-climb is fast.", stat = "rebirths", atLeast = 1 },
}

-- design:D-05, via #96 — PROGRESSIVE DISCLOSURE. The game starts small and
-- grows its own interface: a surface takes up space only once the player can
-- use it, every arrival is earned by something they just did, and nothing
-- ever disappears once shown. The high-water lives in profile.disclosed, so
-- a returning player sees what they earned and is never re-onboarded.
--
-- `after` is a Config.Buttons id; owning it (or the rebirth count, for the
-- rebirths form) is the earn. A row with no `after` is on from the first
-- second — that set IS the sixty-second screen, and the verifier prints it.
-- `gate = true` rows gate GAMEPLAY as well as pixels: the plot siege waits
-- for its row, because a raid siren in your first minute is the overload
-- this whole system exists to prevent.
Config.Disclosure = {
	{ id = "hud", name = "Your factory", help = "Buy droppers, follow the gold beacon. The vault banks what the machines earn." },
	{ id = "movement", name = "Sprint and dash", help = "Hold Shift to sprint, Q to dash. On touch: RUN and DASH, bottom left." },
	{ id = "terms", after = "dropper2", name = "Multipliers", help = "The line under your cash names every bonus you hold." },
	{ id = "session", after = "dropper3", name = "Streaks and boosts", help = "The session panel: daily streak, playtime ladder, the boost button." },
	{ id = "social", after = "dropper4", name = "Friends pay", help = "Every friend in the server is +10% income. Invite from the status card." },
	{ id = "world", after = "dropper5", name = "The world outside", help = "Sahur roam the grass — weakest near the plots, strongest in the middle. Kills pay." },
	{ id = "siege", after = "walls", gate = true, name = "Raids on your plot", help = "Sahur press your gate now and then. The siren gives you time to run home; repair what breaks." },
	{ id = "party", after = "walls", name = "Parties", help = "Party up from the left card: no friendly fire, shared gates, +5% income each." },
	{ id = "recall", after = "walls", name = "Recall", help = "H (or HOME on touch) walks you home after six still seconds. Never with stolen Tung." },
	{ id = "objectives", after = "upgrader1", name = "Daily objectives", help = "Three things to do today, on the left card. Each pays minutes of your income." },
	{ id = "shop", after = "dropper3", name = "The shop", help = "Bats and armour live in the SHOP now — the rail button, or the merchant by the spawn." },
	{ id = "raiding", after = "gates", name = "Raiding", help = "Break a storage unit, carry the spill home. Half their cap is always safe; camping pays half each repeat." },
	{ id = "tower", after = "power1", name = "The tower", help = "The spire at the core's edge. A new deck of floors every day; each floor pays minutes of your income." },
}

--- Whether one disclosure row is earned. `has` answers ownership, the same
--- shape incomeRate reads.
function Config.disclosureEarned(row, has: (string) -> boolean): boolean
	if not row.after then
		return true
	end
	return has(row.after)
end

-- design:D-04, via #95 — THE TOWER. Combat with a shape: floors of waves,
-- bosses, timed kills and survival, composed fresh each UTC day from the day
-- seed so a run cannot be memorised, climbed by a party (#102) or alone.
-- Rewards are paid PER FLOOR, on the spot, in MINUTES OF YOUR OWN INCOME —
-- which makes "fighting beats waiting" a line of arithmetic the verifier
-- holds at every progression stage, and makes a wipe keep what it cleared.
Config.Tower = {
	Floors = 8,
	-- Enemy level by floor: BaseLevel + LevelPerFloor x floor, on the same
	-- growth curves every other Sahur uses.
	BaseLevel = 2,
	LevelPerFloor = 1.5,
	-- What one floor pays each member: minutes of their OWN income rate.
	FloorRewardMinutes = 2,
	-- The pacing estimate a floor is tuned around; the run-length and the
	-- fighting-beats-waiting assertions both read it.
	FloorNominalSeconds = 90,
	-- Archetype knobs.
	WaveCount = 6,          -- bodies in a wave floor, plus one per partymate
	TimedSeconds = 45,      -- kill the pack before this runs out
	SurvivalSeconds = 30,   -- stay alive this long
	-- Concurrency and the platform in the sky the floors fight on.
	MaxConcurrentRuns = 2,
	PlatformY = 500,
	PlatformSize = 90,
	-- Where the entrance spire stands: on the core's edge, opposite the
	-- spawn, in plain sight of anyone walking inward.
	EntranceRadius = 150,
}

-- The archetype deck. towerFloors deals it by day seed.
Config.TowerArchetypes = { "wave", "timed", "survival", "boss" }

--- The day's tower: a deterministic composition of Floors archetypes from
--- the UTC day number, the same for every server and every party that day.
--- Every archetype appears; a boss holds the top floor; the shuffle is a
--- seeded LCG so the verifier can walk any seed it likes.
function Config.towerFloors(daySeed: number): { string }
	local deck = {}
	local state = daySeed * 747796405 + 2891336453
	local function nextRandom(n: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return (state % n) + 1
	end
	for f = 1, Config.Tower.Floors - 1 do
		-- guarantee coverage: the first pass deals each archetype once, the
		-- rest draw freely
		local archetypes = Config.TowerArchetypes
		if f <= #archetypes then
			deck[f] = archetypes[f]
		else
			deck[f] = archetypes[nextRandom(#archetypes)]
		end
	end
	-- seeded shuffle of everything below the top
	for f = #deck, 2, -1 do
		local swap = nextRandom(f)
		deck[f], deck[swap] = deck[swap], deck[f]
	end
	-- the top floor is always the boss: a run ends on a fight worth talking
	-- about, whatever the deal dealt
	deck[Config.Tower.Floors] = "boss"
	return deck
end

--- Enemy level on one floor.
function Config.towerLevel(floor: number): number
	return math.floor(Config.Tower.BaseLevel + Config.Tower.LevelPerFloor * floor)
end

-- design:D-04, via #103 — RECALL. The open world makes the trip home a
-- recurring tax; recall pays it with TIME STANDING STILL instead of a walk.
-- The stillness is the anti-escape: a caster is a free hit for anything
-- already on them, moving or taking damage cancels the cast, and a raider's
-- carry blocks it outright — stolen Tung walks home. One direction only:
-- coming back. Going out is the walk (#101's sprint; mounts wait for later).
Config.Recall = {
	CastSeconds = 6,
	CooldownSeconds = 45,
	-- Drifting further than this from where the cast began cancels it.
	CancelMoveStuds = 4,
}

-- design:D-04, via #101 — MOVEMENT. Sprint and dash ship now, as BASELINE
-- capabilities everyone has: legibility first, and a movement axis nobody can
-- buy is a movement axis nobody falls behind on. Mounts and waypoints wait
-- for #89 — there is no world to cross yet.
Config.Movement = {
	-- 32 is the wall-clip bound: above it a humanoid starts passing through
	-- 2-stud walls, and the PlayerUpgrades check has always held that line.
	-- Sprinting RAISES the defender's run home, so the siren guarantee
	-- (WarningTime x Combat.WalkSpeed >= MinPlotRadius) keeps its
	-- conservative walking form and sprint is pure margin.
	SprintSpeed = 32,
	-- The dash: a short burst that is also a dodge. Client-applied — the
	-- client owns its character's physics — with the cooldown enforced
	-- server-side so combat systems can trust the cadence.
	DashSpeed = 70,
	DashSeconds = 0.25,
	DashCooldown = 4,
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

	-- design:D-04 — the boss is the one thing in this game that couples two
	-- players' outcomes. Everything above this line describes a raid six people
	-- can play in six separate boxes.
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
-- mechanism: BELT PATHS AND FLOORS. Shipped data — Tycoon.new consumes
-- BeltPaths[1] unconditionally to build the ground floor's conveyor.
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

-- ─────────────────────────────────────────────────────────────────────────────
-- invariant: THE BUILDING SHELL — walls, windows, gates and the roof.
--
-- ONE STRUCTURAL LINE. Config.Structure.WallHeight is the wall's top and the
-- roof's underside, and everything at ceiling height derives from it.
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
		sill = 6,
		height = 9,
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
			id = "gateway", side = "front",
			centre = Config.Layout.GateCentre, width = Config.Layout.GateWidth,
			height = 13, leaves = 2,
			-- Which face the leaves hang on and slide along. INBOARD here: the
			-- front wall's inside is the open aisle, and a leaf out on the grass
			-- in front of the gateway would be the first thing you see.
			face = "inboard",
		},
		{
			id = "yardDoor", side = "back",
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

	-- invariant: A BUDGET. The shell was ~10 parts; windows and gates take it to ~115,
	-- times ten plots. Config.shellPartCount() models it from this spec and the
	-- verifier asserts the result. Whether it holds at full scale in a real
	-- server is open — design:D-03.
	-- invariant: LIGHT, BECAUSE A STOREY WITH A CEILING IS INDOORS.
	-- Lighting.Ambient is (0,0,0) and the mezzanine deck spans wall face to wall
	-- face, so from the minute the storey lands the ground floor has no sky.
	--
	-- Material.Neon ILLUMINATES NOTHING in Roblox. The wall's "light strip" is a
	-- look, not a light, and the variant glow on machine cores is too — classic,
	-- oak and ash carry none at all, so the first three droppers and the first
	-- upgrader emit nothing.
	--
	-- SurfaceLight ON THE BOTTOM FACE, and that is the whole design. Every light
	-- here runs Shadows = false — at 8 fixtures x 2 storeys x 10 plots it has
	-- to — and a Roblox light with shadows off IGNORES OCCLUDERS ENTIRELY. A
	-- PointLight bolted under the deck would shine straight through a 1.6-stud
	-- slab and light the mezzanine floor above it. A SurfaceLight emits from one
	-- face into a cone and cannot leak upward at all. SpotLight makes a pool on
	-- the floor and leaves the walls black.
	--
	-- A GRID, DERIVED FROM THE WALL RING, exactly like the wall spans are.
	-- Hand-listed coordinates are coordinates that stop being under the ceiling
	-- the first time the plot changes size.
	--
	-- 3x4 AT AN INSET OF 20, and the coverage assertion chose all three numbers.
	-- 2x4 at an inset of 30 was the first guess and it fails: it puts the
	-- darkest floor sample 46.8 studs from its nearest fixture against a range
	-- of 55, and a light's falloff is not a cliff. The binding point is not the
	-- corner — it is the MIDDLE OF THE BACK WALL, which two columns leave 47
	-- studs from either of them. A third column down the centre line fixes it.
	--
	-- `inset` is also what keeps the +X column off the armoury: a batten at
	-- x = 38 spans 36.5..39.5 against a cabinet at 46..50. Asserted, not
	-- remembered.
	Lights = {
		columns = 3,
		rows = 4,
		inset = 20,
		batten = { width = 3, length = 24, thickness = 0.6 },
		drop = 0.3,              -- top face sunk this far into the ceiling above
		brightness = 2,
		-- Roblox CLAMPS a light's Range at 60 and says nothing about it, so a
		-- number above that reads as set and is not. Asserted below.
		range = 55,
		angle = 150,
	},

	PartBudget = 200,
}

-- design:D-02, via #124 — the walls and gate are breakable, and their
-- toughness arrives with the land: level = expansions owned + 1, so a grown
-- plot is a harder target with no separate wall ladder to climb. The state
-- machine is tycoon/Siege.lua; players land damage through CombatService's
-- structure observer, mobs will land theirs when #89 lets them reach a wall.
Config.Structure.Health = {
	WallBase = 600,
	WallPerLevel = 150,
	-- The gate is the door a raider is MEANT to break (#94): cheaper than a
	-- wall, and the verifier holds it to "never one swing, never a siege" for
	-- every bat at every level.
	GateBase = 300,
	GatePerLevel = 75,
	-- Same shape as the storage unit's repair: quick, manual, owner-present,
	-- and it has to finish inside the raid's warning window (asserted).
	RepairSeconds = 3,
	PlayerDamageScale = 1,
	-- #89's mobs hit masonry at half a player's weight: the plot-wave breach
	-- floors (warning + time-to-breach covers the run home) are asserted
	-- against this, and at 1 a bare plot's storage fell before its owner
	-- could sprint back from the mid band.
	MobDamageScale = 0.5,
}

--- design:D-02, via #98 — what the storage unit can hold, in Tung: CapMinutes
--- of the plot's income with the rebirth term, floored for a fresh plot, and
--- collapsed to the broken floor while the unit is smashed. Pure arithmetic;
--- the verifier walks the whole curve against it.
function Config.storageCap(has: (string) -> boolean, rebirths: number?, intact: boolean?): number
	if intact == false then
		return Config.Storage.BrokenCapFloor
	end
	local rate = Config.incomeRate(has)
		* Config.Rebirth.MultiplierPerRebirth ^ math.max(0, rebirths or 0)
	return math.max(Config.Storage.CapFloor, rate * Config.Storage.CapMinutes * 60)
end

--- A wall's full health at `level` = expansions owned + 1.
function Config.wallMaxHealth(level: number): number
	local H = Config.Structure.Health
	return H.WallBase + H.WallPerLevel * (level - 1)
end

--- A gate's full health at the same level.
function Config.gateMaxHealth(level: number): number
	local H = Config.Structure.Health
	return H.GateBase + H.GatePerLevel * (level - 1)
end

-- The one structural line: floor top to the wall's top, which is also the
-- roof's underside. It was Storeys[1].clear, derived from the mezzanine
-- deck's underside; the storey system retired with #88 and the shipped number
-- stays, verbatim, so the roof line, the trim, the light plane and every
-- label assertion hold still.
Config.Structure.WallHeight = 20.4

--- The underside of the roof: the wall's top. One line, one reader each side.
function Config.roofUnderside(): number
	return Config.Structure.WallHeight
end

--- One wall of the ring: the axis it runs along, its fixed coordinate on the
--- other axis, and its extent — for a plot owning `left`/`right` expansions a
--- side (both default 0, the bare centre).
---
--- Note the asymmetry, which is how the shell has always been built: the side
--- walls run the FULL plot depth and the front and back walls sit between them.
--- Changing that changes four corners at once. Land grows the ring along X
--- only: the front and back walls lengthen, the side walls MOVE outward, and
--- depth never changes — which is what keeps the leash, gate-trap and
--- warning-walk arithmetic still about the same distances.
function Config.wallExtent(side: string, left: number?, right: number?)
	local extents = Config.landExtents(left or 0, right or 0)
	local minX, maxX = extents.minX + 1, extents.maxX - 1
	local halfZ = Config.World.PlotSize.Z / 2 - 1
	if side == "back" then
		return { axis = "X", fixed = -halfZ, from = minX, to = maxX, outward = -1 }
	elseif side == "front" then
		return { axis = "X", fixed = halfZ, from = minX, to = maxX, outward = 1 }
	elseif side == "left" then
		return { axis = "Z", fixed = minX, from = -Config.World.PlotSize.Z / 2,
			to = Config.World.PlotSize.Z / 2, outward = -1 }
	elseif side == "right" then
		return { axis = "Z", fixed = maxX, from = -Config.World.PlotSize.Z / 2,
			to = Config.World.PlotSize.Z / 2, outward = 1 }
	end
	return nil
end

Config.Structure.Sides = { "back", "front", "left", "right" }

--- Every opening in one wall, in order along the wall.
function Config.openingsIn(side: string)
	local found = {}
	for _, opening in ipairs(Config.Structure.Openings) do
		if opening.side == side then
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
---
--- ON A GROWN PLOT the front and back walls also split their solid runs at
--- every land boundary, so each expansion's frontage is its own span. The
--- centre's boxes never change size when land arrives — an expansion ADDS
--- spans — and every opening stays on the centre span, which is what keeps
--- "gates and windows are never rebuilt" true whatever the plot owns.
function Config.wallSegments(side: string, left: number?, right: number?)
	local extent = Config.wallExtent(side, left, right)
	local segments = {}

	-- The split points: the centre pad's edges and each owned expansion's
	-- outer boundary, where they fall strictly inside the extent.
	local splits = {}
	if extent.axis == "X" then
		-- The centre/expansion boundary sits at the wall's INSET edge, the
		-- same 1 stud in from the ground joint the bare ring has always used,
		-- so the centre's spans are byte-identical at every land state and
		-- the first expansion adds a span without resizing a standing box.
		local halfX = Config.World.PlotSize.X / 2 - 1
		for _, boundary in ipairs({ -halfX, halfX }) do
			if boundary > extent.from and boundary < extent.to then
				table.insert(splits, boundary)
			end
		end
		for _, sideName in ipairs({ "left", "right" }) do
			local count = (sideName == "left") and (left or 0) or (right or 0)
			local steps = Config.landSteps(sideName)
			local sign = (sideName == "left") and -1 or 1
			for index = 1, math.min(count, #steps) do
				local boundary = sign * steps[index]
				if boundary > extent.from and boundary < extent.to then
					table.insert(splits, boundary)
				end
			end
		end
		table.sort(splits)
	end

	local function pushSolid(from, to)
		if to <= from then
			return
		end
		local cursor = from
		for _, split in ipairs(splits) do
			if split > cursor and split < to then
				table.insert(segments, { kind = "solid", from = cursor, to = split })
				cursor = split
			end
		end
		table.insert(segments, { kind = "solid", from = cursor, to = to })
	end

	local cursor = extent.from
	for _, opening in ipairs(Config.openingsIn(side)) do
		local openFrom = opening.centre - opening.width / 2
		local openTo = opening.centre + opening.width / 2
		pushSolid(cursor, openFrom)
		table.insert(segments, { kind = "opening", from = openFrom, to = openTo, opening = opening })
		cursor = openTo
	end
	pushSolid(cursor, extent.to)
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

--- invariant: how many parts one plot's shell costs, modelled from the spec
--- above so the verifier can hold it to Config.Structure.PartBudget.
---
--- Per solid run: a sill course, a head course, and the bay course's piers and
--- panes. Per opening: a lintel course over it, plus its leaves. Per side: a
--- trim cap and an interior light strip. Plus the roof slab, its four columns
--- and its sign anchor.
---
--- IT MUST COUNT WHAT THE BUILDER EMITS, not what the wall spec implies. Its
--- first version left out the trim, the light strip and the sign anchor, so it
--- reported 59 against 68 actually built and 107 against 124 — a budget asserted
--- 13% under the truth, which is a budget that passes right up until it matters.
--- Both numbers were reconciled against a count taken from the real builder.
--- mechanism: WHERE THE CEILING FIXTURES HANG, in plot-local coordinates.
---
--- Derived from the wall ring, so a fixture cannot end up outside the room or
--- below the machines. Component arithmetic only: the verifier's Vector3 is a
--- bare table with no operators.
--- The room grows along X with the land, so the COLUMN COUNT grows with it:
--- a fixed grid stretched over a maxed plot leaves the middle of each wing
--- past the fixtures' range, and the sampled coverage check is what chose
--- the divisor.
function Config.lightColumnsFor(left: number?, right: number?): number
	local L = Config.Structure.Lights
	local extents = Config.landExtents(left or 0, right or 0)
	local width = extents.maxX - extents.minX
	return math.max(L.columns, math.ceil(width / 42))
end

function Config.storeyLightPositions(left: number?, right: number?): { Vector3 }
	local L = Config.Structure.Lights
	local extents = Config.landExtents(left or 0, right or 0)
	local inset = 1 + Config.Structure.WallThickness / 2 + L.inset
	local fromX, toX = extents.minX + inset, extents.maxX - inset
	local halfZ = Config.World.PlotSize.Z / 2 - 1 - Config.Structure.WallThickness / 2
	local y = Config.Structure.WallHeight - L.drop - L.batten.thickness / 2
	local columns = Config.lightColumnsFor(left, right)

	local spots = {}
	local spanZ = halfZ - L.inset
	for column = 1, columns do
		local x = fromX
		if columns > 1 then
			x += (column - 1) * (toX - fromX) / (columns - 1)
		else
			x = (fromX + toX) / 2
		end
		for row = 1, L.rows do
			local z = -spanZ
			if L.rows > 1 then
				z += (row - 1) * (2 * spanZ) / (L.rows - 1)
			else
				z = 0
			end
			table.insert(spots, Vector3.new(x, y, z))
		end
	end
	return spots
end

function Config.shellPartCount(left: number?, right: number?): number
	local total = 0
	-- the ceiling fixtures. They are Parts; the Lights themselves are not, so
	-- this counts battens and not lights.
	total += #Config.storeyLightPositions(left, right)
	for _, side in ipairs(Config.Structure.Sides) do
		-- the neon cap along this wall's top, and the light strip inside it
		total += 2
		for _, segment in ipairs(Config.wallSegments(side, left, right)) do
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
	-- the roof slab, its four columns, and the invisible anchor its sign hangs on
	return total + 6
end

-- ─────────────────────────────────────────────────────────────────────────────
-- invariant: PROTOTYPES, and the graduates that used to be here
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
-- The sourcing for these is docs/design/research/IDEAS.md. Numbers here are
-- first drafts, not balance.
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
	-- something NOTHING ELSE SELLS, and the verifier asserts that against
	-- Config.Buttons.
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
	CapUpgradeCost = { 250000, 5000000, 5500000000 },
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
-- The widest a plot can get: the centre plus every expansion on both sides.
-- Derived here, after the land tables exist. Ring packing reserves this — a
-- plot can max out, so the world has to hold the maxed chord.
do
	local width = Config.World.PlotSize.X
	for _, side in ipairs({ "left", "right" }) do
		for _, def in ipairs(Config.landRows(side)) do
			width += def.width
		end
	end
	Config.World.PlotMaxWidth = width
end

-- Every strip's sub-belt joins Config.BeltPaths here, after the land tables
-- and the path derivation both exist. Registered data, built parts: the belt
-- assertions and the drop budget see all eleven paths, and ensureLand builds
-- each strip's surfaces only when the strip is standing.
for _, side in ipairs({ "left", "right" }) do
	for _, def in ipairs(Config.landRows(side)) do
		table.insert(Config.BeltPaths, Config.landBeltPath(def))
	end
end

Config.World.PlotCount = Config.plotCountFor()
Config.World.PlotPlacements = Config.plotPlacements(Config.World.PlotCount)
Config.World.PlotRadius = Config.World.PlotPlacements[1].radius   -- inner ring

-- invariant: THE MERGE. The five track tables become one Config.Buttons, in
-- track order, so every consumer downstream iterates a single array.
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
-- POWER WENT LAST FOR THIS REASON: appending leaves every existing button's
-- `order` exactly where it was, so no save's install replay changes sequence.
--
-- STRUCTURE DOES NOT GO LAST, AND THAT BREAKS THE CONVENTION DELIBERATELY.
-- Two things make it the right call anyway. The first is that the convention
-- is already spent: pulling four rows out of FactoryButtons renumbers the
-- merged array from index 5 onwards no matter where the new track is spliced
-- in, so there is no placement that preserves the old `order` values. The
-- second is that `order` is not a saved field. A profile stores
-- `owned = { [id] = true }` and Tycoon:assign sorts those ids against the
-- CURRENT Config every time it replays them, so renumbering costs nothing as
-- long as ids never change — which is a rule this file already enforces for
-- other reasons (see the WeaponButtons banner).
--
-- design:D-03, design:D-05 — POSITION IN THIS LIST IS THE BEACON.
-- Config.TrackRank is the TrackOrder index, and both Tycoon:pointAt and the HUD
-- card rank candidates by (rank, price). Nothing in the verifier can catch a
-- beacon that points somewhere useless; it is a property of this list and it
-- has to be decided here.
Config.TrackOrder = { "factory", "structure", "weapons", "armor", "power", "landL", "landR" }
Config.Tracks = {
	factory   = Config.FactoryButtons,
	structure = Config.StructureButtons,
	weapons   = Config.WeaponButtons,
	armor     = Config.ArmorButtons,
	power     = Config.PowerButtons,
	landL     = Config.LandLButtons,
	landR     = Config.LandRButtons,
}

-- invariant: EVERYTHING THAT IS TRUE OF A TRACK RATHER THAN OF A BUTTON, in
-- one table.
--
-- Adding a fourth track is mostly an exercise in finding the per-track facts,
-- because they were scattered across five tables in three files and one of them
-- existed TWICE.
--
-- invariant: A MISSING ROW IN EACH FAILS DIFFERENTLY AND NONE FAIL LOUDLY:
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
	-- design:D-05, via #125 — THE PURCHASE SURFACE IS THREE CATEGORIES:
	-- conveyor (everything that makes the line earn more), generator, and
	-- plot (the ground and the shell on it). `category` is the label a pad
	-- and the HUD card wear; the TRACKS underneath stay chains, because the
	-- chains carry the orderings geometry forces (no L2 without L1) and the
	-- categories are what the player is asked to hold. The cabinet tracks
	-- keep their own labels until #108 moves them off the plot.
	--
	-- The conveyor outranks everything by TrackOrder POSITION, which is what
	-- "the conveyor's label sits highest" already means to the card and the
	-- beacon: both rank by (TrackRank, price).
	factory = { label = "CONVEYOR", category = "conveyor", preview = 3, keepOnRebirth = false, paced = "spine", furniture = "misc" },
	-- invariant: THE SHELL. Three of its five facts are FORCED rather than
	-- chosen; preview is design:D-03.
	--
	-- paced = "spine" because the detour model prices a track against a curve it
	-- does not change AND assumes you can decline it. The second half stopped
	-- being true when a cross-ladder gate once put `roof` between the player and the
	-- mezzanine. Measured as a detour the build reads 46 minutes against a
	-- MIN_TOTAL_MINUTES of 45 — the four purchases did not stop happening, the
	-- verifier just stopped counting them.
	--
	-- keepOnRebirth = false because rebirth() clears self.machines
	-- unconditionally and the wall ring lives there, not in self.props. Set it
	-- true and the ring is destroyed while `owned.walls` survives, so
	-- refreshButtons hides a pad for a building that is not standing and the
	-- plot has no shell for the rest of that owner's life. The cabinets get to
	-- be true because their props are the exempt folder; this track is not.
	--
	-- furniture = "misc" because these four already have hand-placed positions
	-- in Layout.MiscButtons and they are exactly the case that table is for:
	-- unrelated purchases in a line down an open floor.
	--
	-- preview = 2 is the one real choice. At 3 the whole four-rung track is
	-- visible from the moment you claim, which puts a 690000 price tag on the
	-- plot at minute three; at 2 the roof stays hidden until `gates` is owned.
	structure = { label = "PLOT", category = "plot", preview = 2, keepOnRebirth = false, paced = "spine", furniture = "misc" },
	weapons = { label = "WEAPONS", category = "weapons", preview = 2, keepOnRebirth = true,  paced = "side",  furniture = "shop" },
	armor   = { label = "ARMORY",  category = "armor",  preview = 2, keepOnRebirth = true,  paced = "side",  furniture = "shop" },
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
	power   = { label = "GENERATOR", category = "generator", preview = 0, keepOnRebirth = false, paced = "spine", furniture = "yard" },
	-- design:D-03 — LAND SURVIVES A REBIRTH (#88, via #78: rebirth raises the
	-- ceiling on what can exist; the ground is the ceiling). keepOnRebirth
	-- works here because ensureLand rebuilds the slabs from `owned` on the
	-- refreshButtons beat, so land needs no exempt props folder — the
	-- cabinet-only argument the verifier states is widened to name land.
	--
	-- preview = 0 for the power track's reason, which is load-bearing: every
	-- rung of a side resolves to ONE pedestal, so a preview pad would be built
	-- inside the lit one.
	--
	-- paced = "spine": land is the plot's own growth and the simulation walks
	-- it; priced as a detour it would stop counting toward the build.
	landL   = { label = "PLOT", category = "plot", preview = 0, keepOnRebirth = true, paced = "spine", furniture = "land" },
	landR   = { label = "PLOT", category = "plot", preview = 0, keepOnRebirth = true, paced = "spine", furniture = "land" },
}

Config.TrackLabel = {}
Config.TrackRank = {}
for rank, track in ipairs(Config.TrackOrder) do
	Config.TrackRank[track] = rank
	Config.TrackLabel[track] = Config.TrackInfo[track] and Config.TrackInfo[track].label or track:upper()
end

-- design:D-03 — WHAT A WHOLE LADDER WAITS ON, why the cabinets arrive on a gate
-- rather than on claim, and why `structure` opens on the very first rung.
--
-- invariant: DELIBERATELY NOT A `requires` ON EACH TRACK'S FIRST RUNG. The
-- loader derives requirements within a track and the verifier asserts none ever
-- crosses one; that guarantee is worth more than the convenience, and a
-- precondition on an entire ladder is a different kind of thing from a link
-- inside one.
--
-- A GATE MUST NAME A FACTORY BUTTON — asserted, because a side track gating a
-- side track can deadlock. The gate is STICKY, so a rebirth that wipes
-- `dropper3` does not take both cabinets with it.
--
-- `structure` opening on the first rung is also what keeps the "no side track's
-- first rung is affordable at spawn" check meaningful for it — you cannot buy
-- walls at minute zero at any price.
Config.TrackUnlock = {
	weapons = "dropper3", armor = "dropper3", structure = "dropper1",
	-- Land opens once the centre pad is earning properly: mid-build, when the
	-- line is established and the next thing to want is room.
	landL = "dropper5", landR = "dropper5",
}

-- design:D-03, via #125 — Config.ButtonUnlock and its helper are GONE. The
-- one entry ever shipped gated the mezzanine on the roof, and the mechanism
-- retired with the storey system: three categories and per-track chains need
-- nothing that gates ONE purchase across a ladder, and a mechanism nothing
-- uses is a mechanism that silently rots. TrackUnlock is the surviving gate
-- shape — a precondition on a whole ladder — and the reachability fixpoint
-- still counts it.

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

--- Whether one row survives a rebirth. Per-track via TrackInfo, with one
--- carve-out: on a land track the GROUND survives (design:D-03 — rebirth
--- raises the ceiling, and the ground is the ceiling) while the machines
--- standing on it reset — an upgrader that outlived the wipe would multiply
--- the next build from minute zero, which is the generator's argument one
--- track over.
function Config.keptOnRebirth(def): boolean
	local info = Config.TrackInfo[def.track]
	if not info or not info.keepOnRebirth then
		return false
	end
	if info.furniture == "land" then
		return def.kind == "Land"
	end
	return true
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

-- design:D-05, via #125 — the category ordinals the pads and the card count
-- by. A pad says "PLOT 20/34" rather than naming one of three internal
-- chains: the categories are what the player is asked to hold, and the
-- count's width is the category's whole size.
Config.CategoryCount = {}
for _, def in ipairs(Config.Buttons) do
	local info = Config.TrackInfo[def.track]
	def.category = info and info.category or def.track
	Config.CategoryCount[def.category] = (Config.CategoryCount[def.category] or 0) + 1
	def.categoryOrder = Config.CategoryCount[def.category]
end

--- Every price on the SPINE, highest first.
---
--- The spine is what the progression simulation walks and what the build time
--- is measured against. Weapons and armour are deliberately excluded: they are
--- side tracks, priced against the factory rather than pacing it, and a bat
--- costing more than a dropper is the entire point of that split.
---
--- READS `paced` RATHER THAN NAMING THE TRACKS. It listed factory and power by
--- hand while its own comment argued from "what the simulation walks", which is
--- two statements of one fact with a list as the tiebreak — the same shape as
--- the two hand-kept copies of the beacon ranking that TrackRank replaced. A
--- third spine track had to be added in two places or it would have been
--- half-counted, and the half that got missed would have been this one, silently,
--- because nothing downstream of here fails loudly on a slightly short list.
function Config.spinePricesDescending(): { number }
	local prices = {}
	for _, track in ipairs(Config.TrackOrder) do
		if Config.TrackInfo[track].paced == "spine" then
			for _, def in ipairs(Config.Tracks[track]) do
				table.insert(prices, def.price)
			end
		end
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
-- invariant: ANALYTICS
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
	-- Raised from 40 when the land rows joined the milestone set (48, then 72
	-- when #109 put each strip's machines on the chain): the set is every
	-- button plus "none", and the binding budget is MaxCombinations, which is
	-- asserted separately.
	MaxFieldValues = 72,      -- widest single value set we will allow ourselves
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
-- and no other track can supply one. Adding a factory rung widens this set by
-- one and the verifier re-prices the combination budget on the next run.
--
-- THE REASON HAS BEEN RESTATED TWICE AND WAS WRONG BOTH TIMES IN BETWEEN. It
-- read "the side tracks are gated behind floor2 forty minutes in" for a round
-- after round 8 moved that gate to `dropper3` at minute three. The durable form
-- is the one that does not name a button: EVERY other track is gated on a
-- factory rung (Config.TrackUnlock), and `power`, which is not, opens at 14000
-- against a StartingCash of 100. So the first purchase is always a factory
-- purchase, and it is `dropper1` in particular.
--
-- This set SHRANK by four when the shell moved to its own track, which is the
-- derivation working: walls/gates/windows/roof were never reachable as a first
-- buy and were costing combinations for a state that could not happen.
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


--- The cabinet body behind that column: centre, then size. Its long axis is Z,
--- running the length of its own button column with four studs of overhang at
--- each end so the case reads as containing the buttons rather than starting
--- level with them.

--- Shelf slot `slot` on the cabinet — where the display for a bought tier
--- stands, so the case visibly fills up as you climb the track.

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
