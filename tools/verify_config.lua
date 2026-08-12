--!nolint
--[[
	verify_config.lua — runs Config.lua outside Roblox against tiny stubs and
	asserts the tycoon data is internally consistent.

		python3 tools/verify.py

	(the runner inlines src/shared/Config.lua at the @INJECT marker below,
	because the standalone luau CLI has no `io` library to read files with)

	Catches: duplicate ids, dangling `requires`, slot collisions, slots that
	overflow the layout tables, missing variants, non-monotonic pricing, and
	kinds that Tycoon.lua has no installer for.
]]

-- ── Roblox stubs ────────────────────────────────────────────────────────────
Color3 = { fromRGB = function(r, g, b) return { r = r, g = g, b = b } end }
Vector3 = {
	new = function(x, y, z) return { X = x, Y = y, Z = z } end,
	one = { X = 1, Y = 1, Z = 1 },
}
Enum = setmetatable({}, {
	__index = function(_, group)
		return setmetatable({}, { __index = function(_, name) return group .. "." .. name end })
	end,
})

local Config = (function()
	--@INJECT src/shared/Config.lua
end)()

-- ── assertions ──────────────────────────────────────────────────────────────
local failures = {}
local checks = 0

local function check(condition, message)
	checks += 1
	if not condition then
		table.insert(failures, message)
	end
end

-- installers that Tycoon.lua actually implements
local KNOWN_KINDS = { Dropper = true, Upgrader = true, Belt = true, Structure = true, Gear = true }
local KNOWN_STRUCTURES = { walls = true, roof = true }

local seenIds, dropperSlots, upgraderSlots = {}, {}, {}
local lastPrice = 0

for index, def in ipairs(Config.Buttons) do
	local where = ("Buttons[%d] (%s)"):format(index, tostring(def.id))

	check(type(def.id) == "string" and #def.id > 0, where .. ": missing id")
	check(not seenIds[def.id], where .. ": duplicate id")
	seenIds[def.id] = index

	check(type(def.name) == "string" and #def.name > 0, where .. ": missing name")
	check(type(def.price) == "number" and def.price > 0, where .. ": price must be > 0")
	check(KNOWN_KINDS[def.kind], where .. ": unknown kind " .. tostring(def.kind))

	-- prices must climb, otherwise the "next upgrade" HUD hint picks nonsense
	check(def.price > lastPrice, where .. ": price is not greater than the previous button's")
	lastPrice = def.price

	-- requirements must point at buttons defined EARLIER (so load order works)
	for _, req in ipairs(Config.requirementsOf(def)) do
		check(seenIds[req] ~= nil, where .. ": requires unknown or later button " .. tostring(req))
	end

	if def.kind == "Dropper" then
		check(type(def.slot) == "number", where .. ": dropper needs a slot")
		check(Config.Layout.DropperDist[def.slot] ~= nil, where .. ": dropper slot " .. tostring(def.slot) .. " has no Layout.DropperDist entry")
		check(not dropperSlots[def.slot], where .. ": dropper slot " .. tostring(def.slot) .. " already used")
		dropperSlots[def.slot] = true
		check(type(def.dropValue) == "number" and def.dropValue > 0, where .. ": bad dropValue")
		check(type(def.dropRate) == "number" and def.dropRate > 0.2, where .. ": dropRate too fast (< 0.2s will flood physics)")
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
		-- a dropper should always out-earn the one before it
		check(def.price / def.dropValue > 0, where .. ": bad payback")
	elseif def.kind == "Upgrader" then
		check(type(def.slot) == "number", where .. ": upgrader needs a slot")
		check(Config.Layout.UpgraderDist[def.slot] ~= nil, where .. ": upgrader slot " .. tostring(def.slot) .. " has no Layout.UpgraderDist entry")
		check(not upgraderSlots[def.slot], where .. ": upgrader slot " .. tostring(def.slot) .. " already used")
		upgraderSlots[def.slot] = true
		check(type(def.multiplier) == "number" and def.multiplier > 1, where .. ": multiplier must be > 1")
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
	elseif def.kind == "Belt" then
		check(type(def.speedBonus) == "number" and def.speedBonus > 0, where .. ": bad speedBonus")
	elseif def.kind == "Structure" then
		check(KNOWN_STRUCTURES[def.structure], where .. ": unknown structure " .. tostring(def.structure))
	elseif def.kind == "Gear" then
		check(Config.BatById[def.grants] ~= nil, where .. ": grants unknown bat " .. tostring(def.grants))
	end
end

-- every button must be reachable from the root of the dependency graph
local reachable = {}
local function walk(id)
	if reachable[id] then return end
	reachable[id] = true
	for _, def in ipairs(Config.Buttons) do
		for _, req in ipairs(Config.requirementsOf(def)) do
			if req == id then walk(def.id) end
		end
	end
end
for _, def in ipairs(Config.Buttons) do
	if #Config.requirementsOf(def) == 0 then walk(def.id) end
end
for _, def in ipairs(Config.Buttons) do
	check(reachable[def.id], ("Buttons %s is unreachable — nothing unlocks it"):format(def.id))
end

-- bats
local seenBats = {}
for tier, bat in ipairs(Config.Bats) do
	check(not seenBats[bat.id], "duplicate bat id " .. tostring(bat.id))
	seenBats[bat.id] = true
	check(Config.Variants[bat.variant] ~= nil, ("Bats[%d]: unknown variant %s"):format(tier, tostring(bat.variant)))
	check(bat.damage > 0 and bat.cooldown > 0.1 and bat.reach > 0, ("Bats[%d]: bad stats"):format(tier))
	if tier > 1 then
		check(bat.damage > Config.Bats[tier - 1].damage, ("Bats[%d]: not stronger than the previous tier"):format(tier))
	end
end

-- ── belt layout ─────────────────────────────────────────────────────────────
-- The belt is an L: leg 1 (BeltStart -> BeltCorner) carries the droppers,
-- leg 2 (BeltCorner -> BeltEnd) carries the upgraders.
local L = Config.Layout

local function sub(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function len(v) return math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2) end

local leg1 = len(sub(L.BeltCorner, L.BeltStart))
local leg2 = len(sub(L.BeltEnd, L.BeltCorner))
check(leg1 > 0 and leg2 > 0, "belt legs must have non-zero length")

-- ergonomics: you should be able to run over a buy button, not jump onto it.
-- A Roblox humanoid steps over about 2 studs unaided.
check(L.ButtonHeight <= 2,
	("Layout.ButtonHeight is %.1f — over 2 studs means players have to jump onto buy buttons"):format(L.ButtonHeight))
check(L.BeltY <= 2.5,
	("Layout.BeltY is %.1f — the belt should be low enough to see over and step onto"):format(L.BeltY))

-- machines must not overlap their neighbours along the belt
local function checkSpacing(name, distances, legLength)
	for i, d in ipairs(distances) do
		check(d >= 0 and d <= legLength,
			("%s[%d] = %.1f is off the end of its leg (length %.1f)"):format(name, i, d, legLength))
		if i > 1 then
			local gap = d - distances[i - 1]
			check(gap >= L.MachineFootprint,
				("%s[%d] is only %.1f studs from its neighbour; machines are %.1f deep and would overlap")
					:format(name, i, gap, L.MachineFootprint))
		end
	end
end
checkSpacing("DropperDist", L.DropperDist, leg1)
checkSpacing("UpgraderDist", L.UpgraderDist, leg2)

-- THROUGHPUT: the belt has to physically fit the drops it carries. If the
-- peak spawn rate times the transit time exceeds the drop cap, the belt runs
-- bumper-to-bumper, drops shove each other, and the cap silently eats income.
local peakRate = 0
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Dropper" then
		peakRate += 1 / def.dropRate
	end
end
local runOffLen = len(sub(L.CollectorAt, L.BeltEnd))
local beltLength = leg1 + leg2 + runOffLen
local transit = beltLength / L.BeltSpeed
local inFlight = peakRate * transit
local DROP_LENGTH = 1.5   -- longest variant, standing upright

check(inFlight <= Config.Economy.MaxDropsPerPlot,
	("belt carries %.0f drops at peak but MaxDropsPerPlot is %d — the cap would silently eat income; raise BeltSpeed")
		:format(inFlight, Config.Economy.MaxDropsPerPlot))
check(inFlight * DROP_LENGTH <= beltLength * 0.75,
	("belt would run at %.0f%% occupancy at peak — drops will jam into each other; raise Layout.BeltSpeed")
		:format(inFlight * DROP_LENGTH / beltLength * 100))

-- everything the belt places has to stay inside the plot
local halfX, halfZ = Config.World.PlotSize.X / 2, Config.World.PlotSize.Z / 2
local function inPlot(label, point, margin)
	check(math.abs(point.X) <= halfX - (margin or 0),
		("%s sits at x=%.1f, outside the plot (half-width %.1f)"):format(label, point.X, halfX))
	check(math.abs(point.Z) <= halfZ - (margin or 0),
		("%s sits at z=%.1f, outside the plot (half-depth %.1f)"):format(label, point.Z, halfZ))
end
inPlot("BeltStart", L.BeltStart, L.BeltWidth / 2)
inPlot("BeltCorner", L.BeltCorner, L.BeltWidth / 2)
inPlot("BeltEnd", L.BeltEnd, L.BeltWidth / 2)
inPlot("CollectorAt", L.CollectorAt, 6)

-- droppers sit outboard of leg 1 (toward -Z), upgraders outboard of leg 2 (-X)
inPlot("furthest dropper machine",
	Vector3.new(L.BeltCorner.X, 0, L.BeltStart.Z - L.MachineOffset), L.MachineFootprint / 2)
inPlot("furthest upgrader machine",
	Vector3.new(L.BeltCorner.X - L.MachineOffset, 0, L.BeltEnd.Z), L.MachineFootprint / 2)

-- the vault must clear the end of the belt or it walls the conveyor off
local runOff = len(sub(L.CollectorAt, L.BeltEnd))
check(runOff > 8, ("collector is only %.1f studs past the belt end; the vault would block it"):format(runOff))
-- ...and still fit inside the plot behind it. The vault shell is 10 deep and
-- the wall ring stands 1 stud in from the pad edge.
check(L.BeltEnd.Z + runOff + 5 <= halfZ - 2,
	("the vault's far face lands at z=%.1f, into the front wall at z=%.1f")
		:format(L.BeltEnd.Z + runOff + 5, halfZ - 1))

-- FLOOR FURNITURE. Everything that isn't on the belt is placed by absolute
-- plot-local coordinate, so growing the plot silently leaves these behind (or
-- growing the belt runs them over). Each one is 12 studs wide at most.
local floorSpots = {
	{ "RebirthPadAt", L.RebirthPadAt, 6 },
	{ "ClaimPadAt", L.ClaimPadAt, 17 },
	{ "OwnerSpawnAt", L.OwnerSpawnAt, 3 },
}
for id, spot in pairs(L.MiscButtons) do
	table.insert(floorSpots, { "MiscButtons." .. id, spot, 3 })
end
for _, entry in ipairs(floorSpots) do
	inPlot(entry[1], entry[2], entry[3])
end

-- The misc button column has to stay a column: two pedestals at the same spot
-- read as one button and the second purchase looks like it did nothing.
local miscList = {}
for id, spot in pairs(L.MiscButtons) do
	table.insert(miscList, { id = id, spot = spot })
end
table.sort(miscList, function(a, b) return a.id < b.id end)
for i, a in ipairs(miscList) do
	for j = i + 1, #miscList do
		local b = miscList[j]
		local d = len(sub(a.spot, b.spot))
		check(d >= L.MiscButtonSpacing,
			("MiscButtons.%s and MiscButtons.%s are only %.1f studs apart (need %d)")
				:format(a.id, b.id, d, L.MiscButtonSpacing))
	end
end

-- ...and stay clear of the buy buttons attached to belt machines, which sit
-- ButtonOffset studs INBOARD of each leg. Overlapping pedestals were already
-- shipped once and only stayed invisible because the unlock chain happened to
-- hide one before the other appeared.
local BUTTON_PAD = 5
local dropperButtonZ = L.BeltStart.Z + L.ButtonOffset      -- leg 1 runs along -Z
local upgraderButtonX = L.BeltCorner.X + L.ButtonOffset    -- leg 2 runs along -X
for _, entry in ipairs(miscList) do
	check(math.abs(entry.spot.Z - dropperButtonZ) >= BUTTON_PAD,
		("MiscButtons.%s sits on the dropper buy-button row at z=%.1f")
			:format(entry.id, dropperButtonZ))
	check(math.abs(entry.spot.X - upgraderButtonX) >= BUTTON_PAD,
		("MiscButtons.%s sits on the upgrader buy-button row at x=%.1f")
			:format(entry.id, upgraderButtonX))
end

-- The gateway in the front wall has to open onto the aisle the player actually
-- walks, not onto the vault.
local gateLeft, gateRight = L.GateCentre - L.GateWidth / 2, L.GateCentre + L.GateWidth / 2
check(L.GateWidth >= 12, ("the front gateway is only %d studs wide"):format(L.GateWidth))
check(gateLeft > -halfX and gateRight < halfX,
	("the gateway spans x %.0f..%.0f, off the %d-stud front wall"):format(gateLeft, gateRight, halfX * 2))
check(L.OwnerSpawnAt.X > gateLeft and L.OwnerSpawnAt.X < gateRight,
	("the owner spawns at x=%.0f but the gateway is x %.0f..%.0f — they'd land behind a wall")
		:format(L.OwnerSpawnAt.X, gateLeft, gateRight))
check(gateLeft > L.BeltEnd.X + L.BeltWidth / 2,
	("the gateway starts at x=%.0f, over the belt/vault side of the plot"):format(gateLeft))

-- every upgrader is downstream of every dropper by construction (leg 2 comes
-- after leg 1), which is what makes the upgrade stack apply to all droppers
check(#L.UpgraderDist >= 1 and #L.DropperDist >= 1, "need at least one dropper and one upgrader slot")

-- Plots must not overlap at ANY supported player count, since the layout is
-- derived from the place's MaxPlayers at runtime. Checked pairwise rather
-- than by formula, so a change to the packing logic can't slip through.
local MAX_WALK = 420   -- studs from the arena rim to the furthest plot edge
for count = Config.World.MinPlots, Config.World.MaxPlots do
	local placements = Config.plotPlacements(count)
	check(#placements == count, ("plotPlacements(%d) returned %d entries"):format(count, #placements))

	local farthest = 0
	for i, a in ipairs(placements) do
		farthest = math.max(farthest, a.radius + Config.World.PlotSize.Z / 2)
		for j = i + 1, #placements do
			local b = placements[j]
			if a.ring == b.ring then
				-- chord between two plot centres on the same ring
				local d = math.sqrt(a.radius ^ 2 + b.radius ^ 2
					- 2 * a.radius * b.radius * math.cos(a.angle - b.angle))
				check(d >= Config.World.PlotSize.X,
					("%d plots: ring %d plots %d and %d are only %.0f studs apart (need %d)")
						:format(count, a.ring, i, j, d, Config.World.PlotSize.X))
			else
				check(math.abs(a.radius - b.radius) >= Config.World.PlotSize.Z,
					("%d plots: rings %d and %d are only %.0f studs apart radially (need %d)")
						:format(count, a.ring, b.ring, math.abs(a.radius - b.radius), Config.World.PlotSize.Z))
			end
		end
	end

	check(farthest * 2 < Config.World.BaseplateSize,
		("%d plots overflow the %d-stud ground plane"):format(count, Config.World.BaseplateSize))
	check(placements[1].radius - Config.World.PlotSize.Z / 2 > Config.World.ArenaRadius,
		("%d plots: the inner ring overlaps the arena"):format(count))
	-- keep the map walkable: nobody should be a marathon from the arena
	check(farthest - Config.World.ArenaRadius <= MAX_WALK,
		("%d plots put the furthest plot %.0f studs from the arena rim (limit %d)")
			:format(count, farthest - Config.World.ArenaRadius, MAX_WALK))
end

check(Config.plotCountFor(50) == Config.World.MaxPlots, "plot count should clamp up to MaxPlots")
check(Config.plotCountFor(2) == Config.World.MinPlots, "plot count should clamp down to MinPlots")
local midCount = math.floor((Config.World.MinPlots + Config.World.MaxPlots) / 2)
check(Config.plotCountFor(midCount) == midCount, "plot count should track MaxPlayers in range")

-- Plots are meant to read as separate buildings on open ground, not as one
-- continuous estate. Assert the actual clearance rather than trusting PlotGap:
-- neighbouring centres are a CHORD apart, not an arc, so the arc-based spacing
-- you would naively compute overstates the gap on a small ring.
for count = Config.World.MinPlots, Config.World.MaxPlots do
	local placements = Config.plotPlacements(count)
	local onInnerRing = 0
	for _, p in ipairs(placements) do
		if p.ring == 1 then
			onInnerRing += 1
		end
	end
	if onInnerRing > 1 then
		local chord = 2 * placements[1].radius * math.sin(math.pi / onInnerRing)
		local gap = chord - Config.World.PlotSize.X
		check(gap >= Config.World.PlotGap * 0.9,
			("%d plots leave only %.0f studs between neighbours (PlotGap asks for %d)")
				:format(count, gap, Config.World.PlotGap))
	end
end

-- Every horizontal surface needs its own Y. Two coplanar faces at the same
-- height is what produces the shimmering/tearing artefact, and it is very easy
-- to reintroduce by hand-placing one more slab.
local surfaces = {
	GroundTopY = Config.World.GroundTopY,
	PathTopY = Config.World.PathTopY,
	ArenaFloorTopY = Config.World.ArenaFloorTopY,
	PlotSurfaceY = Config.World.PlotSurfaceY,
}
local seenHeights = {}
for name, y in pairs(surfaces) do
	check(type(y) == "number", ("World.%s must be a number"):format(name))
	local clash = seenHeights[y]
	check(clash == nil,
		("World.%s and World.%s are both at y=%s — coplanar faces will z-fight")
			:format(name, tostring(clash), tostring(y)))
	seenHeights[y] = name
end
check(Config.World.PlotSurfaceY > Config.World.GroundTopY,
	"plot pads must sit above the ground plane, not level with it")

-- ── progression simulation ──────────────────────────────────────────────────
-- Walks the real purchase order and works out how long each buy takes at the
-- income the player actually has at that moment. This is what catches an
-- unbuyable first dropper or a 40-minute wall in the mid game.

local MIN_TOTAL_MINUTES = 45
local MAX_TOTAL_MINUTES = 150
local MAX_SINGLE_WAIT_MINUTES = 15

-- the cheapest button with no prerequisites has to be affordable on day one,
-- otherwise a fresh player has zero income and zero way to get any
local cheapestOpener = math.huge
for _, def in ipairs(Config.Buttons) do
	if #Config.requirementsOf(def) == 0 then
		cheapestOpener = math.min(cheapestOpener, def.price)
	end
end
check(Config.Economy.StartingCash >= cheapestOpener,
	("StartingCash (%d) cannot afford the cheapest opening button (%d) — the tycoon can never start")
		:format(Config.Economy.StartingCash, cheapestOpener))

local cash = Config.Economy.StartingCash
local elapsed, rawDps, upgradeMult = 0, 0, 1
local curve = {}

for _, def in ipairs(Config.Buttons) do
	local income = rawDps * upgradeMult
	local shortfall = math.max(0, def.price - cash)
	local wait = 0
	if shortfall > 0 then
		wait = income > 0 and (shortfall / income) or math.huge
	end
	check(wait ~= math.huge,
		("%s costs %d but income is 0 at that point — progression deadlocks here"):format(def.id, def.price))
	if wait ~= math.huge then
		check(wait / 60 <= MAX_SINGLE_WAIT_MINUTES,
			("%s is a %.0f minute wall (limit %d) — lower its price or raise the dropper before it")
				:format(def.id, wait / 60, MAX_SINGLE_WAIT_MINUTES))
		elapsed += wait
	end

	cash = math.max(cash, def.price) - def.price
	if def.kind == "Dropper" then rawDps += def.dropValue / def.dropRate end
	if def.kind == "Upgrader" then upgradeMult *= def.multiplier end
	table.insert(curve, { id = def.id, wait = wait, at = elapsed })
end

local endgameIncome = rawDps * upgradeMult
check(elapsed / 60 >= MIN_TOTAL_MINUTES,
	("full build takes only %.0f min (want >= %d) — the game is over too fast"):format(elapsed / 60, MIN_TOTAL_MINUTES))
check(elapsed / 60 <= MAX_TOTAL_MINUTES,
	("full build takes %.0f min (want <= %d) — too grindy"):format(elapsed / 60, MAX_TOTAL_MINUTES))

local rebirthMinutes = Config.Rebirth.BaseCost / endgameIncome / 60
check(rebirthMinutes >= 4 and rebirthMinutes <= 40,
	("first rebirth is %.1f min of endgame income; want 4-40"):format(rebirthMinutes))

-- rebirth must stay worth doing: payouts compound, so income has to grow at
-- least as fast as the cost of the next rebirth or the loop dead-ends
check(Config.Rebirth.MultiplierPerRebirth > 1, "MultiplierPerRebirth must be > 1")
local costRatio = Config.Rebirth.CostGrowth / Config.Rebirth.MultiplierPerRebirth
check(costRatio > 1 and costRatio < 2,
	("each rebirth takes %.2fx longer than the last; want between 1x and 2x"):format(costRatio))

-- ── report ──────────────────────────────────────────────────────────────────
print(("checks run:        %d"):format(checks))
print(("buttons:           %d  (%d dropper slots, %d upgrader slots)")
	:format(#Config.Buttons, #Config.Layout.DropperDist, #Config.Layout.UpgraderDist))
print(("upgrader stack:    x%.1f"):format(upgradeMult))
print(("endgame income:    %.3g Tung/sec"):format(endgameIncome))
print(("full build:        %.0f min"):format(elapsed / 60))
print(("belt:              %.0f studs, %.1fs transit, %.0f drops in flight at peak (%.0f%% full)")
	:format(beltLength, transit, inFlight, inFlight * DROP_LENGTH / beltLength * 100))
print(("first rebirth:     %.3g  (+%.0f min after full build)"):format(Config.Rebirth.BaseCost, rebirthMinutes))
print(("rebirth pacing:    each one takes %.2fx as long as the last"):format(costRatio))
print("\nprogression curve (minutes of grind per purchase):")
for _, row in ipairs(curve) do
	local bar = string.rep("=", math.floor(row.wait / 60 * 3))
	print(("  %-11s %5.1fm  %-34s @ %5.1fm"):format(row.id, row.wait / 60, bar, row.at / 60))
end

if #failures > 0 then
	print("\nFAILURES:")
	for _, message in ipairs(failures) do
		print("  ! " .. message)
	end
	error(("%d config check(s) failed"):format(#failures))
end

print("\nAll config checks passed.")
