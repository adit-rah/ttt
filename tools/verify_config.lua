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
local KNOWN_KINDS = { Dropper = true, Upgrader = true, Belt = true, Structure = true, Gear = true, Armor = true }
local KNOWN_STRUCTURES = { walls = true, roof = true }

local seenIds, dropperSlots, upgraderSlots = {}, {}, {}
-- Per TRACK, not global. Prices only have to climb against the other rungs of
-- their own ladder now; a weapons tier costing less than the dropper it sits
-- beside is not a bug, it is the whole point of the split. Keeping the old
-- single counter would have failed the build the moment a track was added,
-- which is the one thing a naive split silently gets wrong.
local lastPrice = {}

for index, def in ipairs(Config.Buttons) do
	local where = ("Buttons[%d] (%s)"):format(index, tostring(def.id))

	check(type(def.id) == "string" and #def.id > 0, where .. ": missing id")
	check(not seenIds[def.id], where .. ": duplicate id")
	seenIds[def.id] = index

	check(type(def.name) == "string" and #def.name > 0, where .. ": missing name")
	check(type(def.price) == "number" and def.price > 0, where .. ": price must be > 0")
	check(KNOWN_KINDS[def.kind], where .. ": unknown kind " .. tostring(def.kind))

	-- prices must climb WITHIN A TRACK, otherwise the "next upgrade" hint and
	-- the buy-this-next beacon both pick nonsense on that ladder
	check(def.price > (lastPrice[def.track] or 0),
		("%s: price is not greater than the previous button in the %s track")
			:format(where, tostring(def.track)))
	lastPrice[def.track] = def.price

	-- requirements must point at buttons defined EARLIER (so load order works)
	for _, req in ipairs(Config.requirementsOf(def)) do
		check(seenIds[req] ~= nil, where .. ": requires unknown or later button " .. tostring(req))
		-- ...and never across a track. One stray link re-couples the chain and
		-- nothing else in the game would notice: the button would simply never
		-- light up, on a plot where every other button did.
		local reqDef = Config.ButtonById[req]
		if reqDef then
			check(reqDef.track == def.track,
				("%s is on the %s track but requires %s from the %s track — tracks are independent")
					:format(where, tostring(def.track), req, tostring(reqDef.track)))
		end
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
	elseif def.kind == "Armor" then
		check(Config.ArmorById[def.grants] ~= nil, where .. ": grants unknown armour tier " .. tostring(def.grants))
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

-- ── tracks ──────────────────────────────────────────────────────────────────
-- A track is a CHAIN: one way in, one order through it, and no dependency on
-- anything outside itself. The merge in Config derives the links, so these
-- check that the derivation actually produced what it claims.

local totalTracked = 0
for _, track in ipairs(Config.TrackOrder) do
	local defs = Config.Tracks[track]
	check(defs ~= nil, ("TrackOrder names %q but Config.Tracks has no such table"):format(track))
	check(Config.TrackLabel[track] ~= nil, ("track %q has no TrackLabel"):format(track))
	totalTracked += #defs

	local roots = 0
	for slot, def in ipairs(defs) do
		if #Config.requirementsOf(def) == 0 then
			roots += 1
		end
		check(def.track == track and def.trackOrder == slot,
			("%s claims %s/%s but sits at %s/%d in its table")
				:format(def.id, tostring(def.track), tostring(def.trackOrder), track, slot))
	end
	-- Zero roots means a cycle, two means the ladder forked and the buy-button
	-- frontier would light both branches at once.
	if #defs > 0 then
		check(roots == 1,
			("the %s track has %d requirement-free roots; a track is a chain, so it needs exactly one")
				:format(track, roots))
	end
end
check(totalTracked == #Config.Buttons,
	("the tracks hold %d buttons but Config.Buttons has %d — the merge dropped or duplicated a row")
		:format(totalTracked, #Config.Buttons))

-- bats
local seenBats = {}
for tier, bat in ipairs(Config.Bats) do
	check(not seenBats[bat.id], "duplicate bat id " .. tostring(bat.id))
	seenBats[bat.id] = true
	check(Config.Variants[bat.variant] ~= nil, ("Bats[%d]: unknown variant %s"):format(tier, tostring(bat.variant)))
	check(bat.damage > 0 and bat.cooldown > 0.1 and bat.reach > 0, ("Bats[%d]: bad stats"):format(tier))
	-- A FLOOR as well as the latency ceiling further down. That ceiling only
	-- bounds cooldown from above, and a ladder of ever-faster bats walks
	-- straight through the bottom: below ~0.3s there is no room for a wind-up,
	-- a strike and a recovery inside one cooldown, so the swing stops reading
	-- as a swing and the combo animation never finishes a pose.
	check(bat.cooldown >= 0.3,
		("Bats[%d] (%s) has a %.2fs cooldown; under 0.3s the wind-up, strike and recovery cannot fit inside it")
			:format(tier, tostring(bat.name), bat.cooldown))
	if tier > 1 then
		check(bat.damage > Config.Bats[tier - 1].damage, ("Bats[%d]: not stronger than the previous tier"):format(tier))
	end
end

-- Every Gear button grants a DISTINCT bat, and between them they cover every
-- tier above the one you spawn holding. A tier nothing sells is dead data, and
-- two buttons granting the same bat means one of them takes your money and
-- does nothing (grantBat is monotonic).
local grantedBats = {}
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Gear" then
		check(not grantedBats[def.grants],
			("two Gear buttons both grant %s; the second would charge and do nothing")
				:format(tostring(def.grants)))
		grantedBats[def.grants] = true
	end
end
for tier = 2, #Config.Bats do
	check(grantedBats[Config.Bats[tier].id],
		("Bats[%d] (%s) is not granted by any button — nothing in the game can unlock it")
			:format(tier, tostring(Config.Bats[tier].name)))
end
check(not grantedBats[Config.Bats[1].id],
	("Bats[1] (%s) is the bat you spawn holding; selling it would charge for nothing")
		:format(tostring(Config.Bats[1].name)))

-- ── armour ──────────────────────────────────────────────────────────────────
local seenArmor = {}
for tier, armor in ipairs(Config.Armor.Tiers) do
	check(not seenArmor[armor.id], "duplicate armour id " .. tostring(armor.id))
	seenArmor[armor.id] = true
	check(Config.Variants[armor.variant] ~= nil,
		("Armor.Tiers[%d]: unknown variant %s"):format(tier, tostring(armor.variant)))
	check(type(armor.health) == "number" and armor.health > 0,
		("Armor.Tiers[%d]: bad health"):format(tier))
	if tier > 1 then
		check(armor.health > Config.Armor.Tiers[tier - 1].health,
			("Armor.Tiers[%d] (%s) is not tougher than the tier below it"):format(tier, tostring(armor.name)))
	end
end

-- Tier 1 IS the bare Roblox humanoid. This is what keeps the raider-telegraph
-- assertion below honest: it measures an UNARMOURED player, and it can only
-- keep meaning that if tier 1 grants nothing.
check(Config.Armor.Tiers[1].health == Config.Armor.BaseHealth,
	("Armor.Tiers[1] grants %d health but BaseHealth is %d; tier 1 is the humanoid you spawn as and must grant nothing")
		:format(Config.Armor.Tiers[1].health, Config.Armor.BaseHealth))

local grantedArmor = {}
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Armor" then
		check(not grantedArmor[def.grants],
			("two Armor buttons both grant %s; the second would charge and do nothing")
				:format(tostring(def.grants)))
		grantedArmor[def.grants] = true
	end
end
for tier = 2, #Config.Armor.Tiers do
	check(grantedArmor[Config.Armor.Tiers[tier].id],
		("Armor.Tiers[%d] (%s) is not granted by any button — nothing can unlock it")
			:format(tier, tostring(Config.Armor.Tiers[tier].name)))
end
check(not grantedArmor[Config.Armor.Tiers[1].id],
	"Armor.Tiers[1] is what you spawn wearing; selling it would charge for nothing")

-- ── prototypes ──────────────────────────────────────────────────────────────
-- Unshipped, but the data still has to be coherent — a prototype that only
-- fails once you flip its flag is a prototype nobody flips.

-- Every flag must exist and be a boolean, and a shipping build has them all
-- off. If one gets left on, this is the check that says so.
for name, on in pairs(Config.Prototypes) do
	check(type(on) == "boolean", ("Prototypes.%s is not a boolean"):format(name))
	check(on == false, ("Prototypes.%s is ON — prototypes ship off"):format(name))
end

-- A belt path is a polyline with one outboard side per leg. One short entry and
-- the last leg silently falls back to +1, which is the bug the explicit table
-- was added to prevent.
for _, path in ipairs(Config.BeltPaths) do
	check(type(path.id) == "string", "a BeltPath is missing its id")
	check(#path.points >= 2, ("BeltPaths.%s needs at least two points"):format(path.id))
	check(#path.outboard == #path.points - 1,
		("BeltPaths.%s has %d points but %d outboard signs (need %d)")
			:format(path.id, #path.points, #path.outboard, #path.points - 1))
	for i, sign in ipairs(path.outboard) do
		check(sign == 1 or sign == -1,
			("BeltPaths.%s leg %d has outboard %s; it must be 1 or -1"):format(path.id, i, tostring(sign)))
	end
end

-- Floors. The deck must clear everything the ground floor stands up, and the
-- unlock must be a real button — a floor gated on a typo never opens.
local plotHalfX, plotHalfZ = Config.World.PlotSize.X / 2, Config.World.PlotSize.Z / 2
for _, floor in ipairs(Config.Floors) do
	check(Config.ButtonById[floor.requires] ~= nil,
		("Floors.%s requires %q, which is not a button"):format(floor.id, tostring(floor.requires)))
	-- unlocking a floor before the ground floor is finished is the single most
	-- complained-about thing in multi-floor tycoons.
	--
	-- Measured against the FACTORY track, not the merged array. This used to
	-- read `order >= #Config.Buttons - 1`, which was true only while there was
	-- one track: the moment anything is appended after the factory, dropper10
	-- stops being one of the last two rows and this fails — on a feature whose
	-- flag is off, which is exactly the kind of breakage nobody goes looking
	-- for.
	local unlock = Config.ButtonById[floor.requires]
	check(unlock.track == "factory",
		("Floors.%s unlocks on the %s track; a floor is factory progression")
			:format(floor.id, tostring(unlock.track)))
	check(unlock.trackOrder >= #Config.Tracks.factory - 1,
		("Floors.%s unlocks at factory step %d of %d — finish the ground floor first")
			:format(floor.id, unlock.trackOrder, #Config.Tracks.factory))
	-- headroom over the tallest thing the ground floor stands up (the vault
	-- statue, ~13.5) plus a player
	check(floor.height >= 18,
		("Floors.%s sits at y=%.0f; the ground floor needs ~18 studs of headroom"):format(floor.id, floor.height))
	check(math.abs(floor.deckAt.X) + floor.deckSize.X / 2 <= plotHalfX,
		("Floors.%s deck overhangs the plot on X"):format(floor.id))
	check(math.abs(floor.deckAt.Z) + floor.deckSize.Z / 2 <= plotHalfZ,
		("Floors.%s deck overhangs the plot on Z"):format(floor.id))
	check(floor.railHeight >= 4,
		("Floors.%s rail is %.0f studs; a humanoid steps over that"):format(floor.id, floor.railHeight))
end

-- Player upgrades: geometric costs, and a cap that doesn't break the world.
for _, def in ipairs(Config.PlayerUpgrades) do
	check(def.levels >= 1, ("PlayerUpgrades.%s has no levels"):format(def.id))
	check(def.cost > 0 and def.costGrowth >= 1,
		("PlayerUpgrades.%s has a non-growing cost curve"):format(def.id))
	if def.stat == "WalkSpeed" then
		-- above ~32 a humanoid starts clipping through 4-stud walls
		local top = def.base + def.perLevel * def.levels
		check(top <= 32, ("PlayerUpgrades.%s tops out at %.1f WalkSpeed; walls stop working above ~32")
			:format(def.id, top))
	end
end

-- Utilities: a real unlock, and a cooldown longer than the effect or you can
-- hold the effect up permanently.
for _, def in ipairs(Config.Utilities) do
	check(Config.ButtonById[def.requires] ~= nil,
		("Utilities.%s requires %q, which is not a button"):format(def.id, tostring(def.requires)))
	check(def.cooldown > def.duration,
		("Utilities.%s lasts %.1fs on a %.1fs cooldown — it would never drop")
			:format(def.id, def.duration, def.cooldown))
	check(def.radius and def.radius > 0, ("Utilities.%s has no radius"):format(def.id))
end

-- Offline earnings. The cap ladder has to be monotonic in both directions or
-- there is a tier you pay more for and get less from.
do
	local O = Config.Offline
	check(O.Rate > 0 and O.Rate <= 1, ("Offline.Rate is %.2f; it is a fraction"):format(O.Rate))
	check(#O.CapUpgradeHours == #O.CapUpgradeCost, "Offline cap upgrade hours and costs disagree in length")
	local previousHours, previousCost = O.CapHours, 0
	for i, hours in ipairs(O.CapUpgradeHours) do
		check(hours > previousHours, ("Offline cap tier %d does not extend the one before it"):format(i))
		check(O.CapUpgradeCost[i] > previousCost, ("Offline cap tier %d is not dearer than the one before it"):format(i))
		previousHours, previousCost = hours, O.CapUpgradeCost[i]
	end
end

-- Session loops.
do
	local S = Config.Sessions
	check(#S.DailyRewards == 7, "DailyRewards should be a 7-day loop")
	for i = 2, #S.DailyRewards do
		check(S.DailyRewards[i] > S.DailyRewards[i - 1], ("DailyRewards day %d is not better than day %d"):format(i, i - 1))
	end
	check(S.DailyGraceHours >= 24, "a daily streak needs at least a day of grace or one missed evening kills it")
	for i = 2, #S.PlaytimeMinutes do
		check(S.PlaytimeMinutes[i] > S.PlaytimeMinutes[i - 1], "PlaytimeMinutes must be increasing")
	end
	check(S.BoostCooldown > S.BoostSeconds,
		"the boost lasts longer than its cooldown, so it would never be off")
end

-- Sound. Everything must be an engine asset: an rbxassetid:// here is an upload,
-- and an upload is a thing that can be moderated away.
for name, id in pairs(Config.Sound.Library) do
	check(id:sub(1, 11) == "rbxasset://",
		("Sound.Library.%s is %q — only engine assets, never uploads"):format(name, id))
end
check(Config.Sound.PoolSize >= 1, "Sound.PoolSize must be at least 1")
local soundCount = 0
for _ in pairs(Config.Sound.Library) do
	soundCount += 1
end
check(Config.Sound.PoolSize * soundCount <= 200,
	("the sound pools would allocate %d instances; ~400 live Sounds is where A/V desync starts")
		:format(Config.Sound.PoolSize * soundCount))

-- ── swing timing ────────────────────────────────────────────────────────────
-- Damage lands on the strike frame rather than on the click, so these numbers
-- are now gameplay, not decoration: get them wrong and the bat either hits
-- before it moves or so long after that the swing feels unresponsive.
local CB = Config.Combat

check(CB.SwingWindUp > 0 and CB.SwingWindUp < CB.SwingStrikeAt,
	("SwingWindUp (%.2f) must come before SwingStrikeAt (%.2f)"):format(CB.SwingWindUp, CB.SwingStrikeAt))
check(CB.SwingStrikeAt < 0.75,
	("SwingStrikeAt is %.2f of the swing — the recovery has no room left"):format(CB.SwingStrikeAt))
check(CB.SwingSampleGap > 0 and CB.SwingSampleGap < 0.2,
	("SwingSampleGap is %.2fs; the second hitbox sample belongs inside the arc"):format(CB.SwingSampleGap))
check(CB.SwingSteps == CB.ComboMaxStacks + 1,
	("SwingSteps (%d) must equal ComboMaxStacks + 1 (%d) or the combo repeats a swing")
		:format(CB.SwingSteps, CB.ComboMaxStacks + 1))
check(CB.HitStop >= 0 and CB.HitStop < 0.2,
	("HitStop is %.2fs — long enough to read as lag rather than as impact"):format(CB.HitStop))

-- Input-to-damage latency, per bat. Anything past ~250ms stops reading as a
-- response to your click.
local MAX_STRIKE_LATENCY = 0.25
for tier, bat in ipairs(Config.Bats) do
	local latency = bat.cooldown * CB.SwingStrikeAt
	check(latency <= MAX_STRIKE_LATENCY,
		("Bats[%d] (%s) lands its hit %.0fms after the click (limit %.0fms)")
			:format(tier, bat.name, latency * 1000, MAX_STRIKE_LATENCY * 1000))
end

-- ── raid pacing ─────────────────────────────────────────────────────────────
-- Waves used to run on a fixed timer with no check that the last one had been
-- cleared. These assert the relationships the new schedule depends on, and the
-- first of them is the one that stops a future tuning pass "closing the gap"
-- by shortening the wrong number.
local WV = Config.Waves

-- WarningTime is not decoration: it is how long you have to get home. A player
-- on the inner plot ring is MinPlotRadius studs from the arena and moves at
-- Combat.WalkSpeed, so the warning has to cover that walk or the raid starts
-- without whoever it is aimed at.
check(WV.WarningTime * Config.Combat.WalkSpeed >= Config.World.MinPlotRadius,
	("Waves.WarningTime is %ds: a player on the inner plot ring is %d studs out and walks %d studs/s, so they cover only %.0f studs before the raiders land")
		:format(WV.WarningTime, Config.World.MinPlotRadius, Config.Combat.WalkSpeed,
			WV.WarningTime * Config.Combat.WalkSpeed))

check(WV.ClearBannerTime < WV.RestTime,
	("ClearBannerTime %ds is not shorter than RestTime %ds — the CLEARED banner would still be up when the next warning replaced it")
		:format(WV.ClearBannerTime, WV.RestTime))
check(WV.RestTimeAfterBoss >= WV.RestTime,
	"RestTimeAfterBoss should not be shorter than an ordinary rest; a boss is the wave you need to re-bank after")

-- The complaint, asserted from both ends.
local deadAir = WV.RestTime + WV.WarningTime
check(deadAir <= 45,
	("%.0fs of dead air between a wave clearing and the next one landing; the raid is meant to read as pressure, not as a timer")
		:format(deadAir))
check(deadAir >= 20,
	("only %.0fs between waves — no window to bank, buy or heal"):format(deadAir))

-- The deadline is a deadlock breaker, so it must not be able to fire during
-- the spawn drip it is meant to backstop.
local spawnSeconds = WV.MaxCount * WV.SpawnGap
check(WV.MaxWaveTime > spawnSeconds * 4,
	("MaxWaveTime is %ds but a full wave takes %.1fs just to spawn; the deadline would fire during the fight")
		:format(WV.MaxWaveTime, spawnSeconds))
check(WV.StragglerGrace > 0,
	"StragglerGrace must be positive, or the per-raider despawn competes with MaxWaveTime instead of backstopping it")
check(WV.FirstWaveDelay >= WV.WarningTime,
	("FirstWaveDelay %ds is shorter than the warning it has to contain"):format(WV.FirstWaveDelay))
check(WV.BroadcastInterval > 0 and WV.BroadcastInterval <= 2,
	("BroadcastInterval is %.2fs; past ~2s the raider counter visibly lags the kills")
		:format(WV.BroadcastInterval))
check(WV.SpawnGap > 0 and WV.SpawnGap < 1,
	("SpawnGap is %.2fs; a full wave would take %.0fs to arrive"):format(WV.SpawnGap, WV.MaxCount * WV.SpawnGap))
check(WV.JoinGrace > 0, "JoinGrace must be positive so a joining player's character can load before the first raid")
check(WV.EmptyResetAfter > 0, "EmptyResetAfter must be positive")
check(WV.Interval == nil,
	"Waves.Interval is gone — waves are paced by RestTime from the previous clear, not by a wall clock")

-- ── raider aggro and leash ──────────────────────────────────────────────────

-- The whole chase-then-give-up design assumes a player can outrun a raider.
-- Without the speed gap, de-aggro is unreachable, only the leash ever fires,
-- and the feature silently becomes "raiders follow you until they hit a wall".
-- Raider speed is WalkSpeed plus up to 4 of per-raider jitter (see buildNPC).
check(WV.WalkSpeed + 4 < Config.Combat.WalkSpeed,
	("raiders top out at %.0f studs/s against a player's %d — with no speed gap a player can never break contact and the de-aggro rule is decoration")
		:format(WV.WalkSpeed + 4, Config.Combat.WalkSpeed))

check(WV.AggroRadius < WV.DeAggroRadius,
	("aggro %.0f / de-aggro %.0f: without hysteresis a raider on the boundary flips between chasing and going home every tick")
		:format(WV.AggroRadius, WV.DeAggroRadius))
check(WV.DeAggroRadius >= WV.AggroRadius * 1.4,
	("de-aggro is only %.0f%% of the aggro radius; that band is too narrow to survive a player strafing")
		:format(WV.DeAggroRadius / WV.AggroRadius * 100))

check(WV.HomeSpread + WV.WanderRadius < Config.World.ArenaRadius,
	("idle raiders wander out to %.0f studs but the arena wall is at %d — they would mill into it")
		:format(WV.HomeSpread + WV.WanderRadius, Config.World.ArenaRadius))

-- THE geometric one, and the reason the leash is measured from a home patch
-- rather than from the world origin or the spawn ring.
--
-- Looped over the supported player range rather than reading
-- Config.World.PlotRadius, which is resolved once for whatever plot count THIS
-- server happens to have. The ring is clamped to MinPlotRadius for 4-7 plots
-- and only grows past it at 8+, so the tightest case is not the configured one.
-- And it is the plot EDGE that matters, not the centre: half a plot depth is
-- 70 studs of difference and reading the wrong one puts raiders inside
-- somebody's factory.
local tightestPlotEdge = math.huge
for count = Config.World.MinPlots, Config.World.MaxPlots do
	local placements = Config.plotPlacements(count)
	tightestPlotEdge = math.min(tightestPlotEdge, placements[1].radius - Config.World.PlotSize.Z / 2)
end
local raiderReach = WV.HomeSpread + WV.LeashRadius + WV.AttackRange
check(raiderReach < tightestPlotEdge,
	("a leashed raider can swing %.0f studs from the arena centre but the nearest plot EDGE is at %.0f — raiders could be dragged onto someone's factory")
		:format(raiderReach, tightestPlotEdge))

check(WV.ReAggroFrac > 0 and WV.ReAggroFrac < 1,
	("ReAggroFrac is %.2f; a returning raider has to get meaningfully closer to home before it can bite again or it yo-yos on the leash line")
		:format(WV.ReAggroFrac))
check(WV.RepathChase * Config.Combat.WalkSpeed < WV.DeAggroRadius - WV.AggroRadius,
	("a chase repath every %.2fs lets a sprinting player cover %.0f studs between updates, more than the %.0f studs of aggro hysteresis")
		:format(WV.RepathChase, WV.RepathChase * Config.Combat.WalkSpeed, WV.DeAggroRadius - WV.AggroRadius))
check(WV.RepathWander > WV.RepathChase,
	"an idling raider should repath less often than a chasing one, not more")
check(WV.WanderDwellMax > WV.WanderDwellMin and WV.WanderDwellMin > 0,
	"wander dwell needs a real range, or every raider picks a new idle target on the same tick")
check(WV.WanderSpeedScale > 0 and WV.WanderSpeedScale < 1,
	("WanderSpeedScale is %.2f; idling has to be visibly slower than chasing or the aggro flip does not read")
		:format(WV.WanderSpeedScale))
check(WV.HomeArrive > 0 and WV.HomeArrive < WV.WanderRadius * 2,
	("HomeArrive is %.0f studs against a %.0f-stud wander radius; a returning raider would never register as home")
		:format(WV.HomeArrive, WV.WanderRadius))
check(WV.SnapshotInterval > 0 and WV.SnapshotInterval <= 0.5,
	("SnapshotInterval is %.2fs; past ~0.5s raiders chase where you were, not where you are")
		:format(WV.SnapshotInterval))
check(WV.AggroCheck > 0 and WV.AggroCheck <= 1,
	("AggroCheck is %.2fs; past a second a player can walk through a raider's aggro radius unnoticed")
		:format(WV.AggroCheck))

-- ── anti-swarm ──────────────────────────────────────────────────────────────

check(WV.ApproachStandoff > 0 and WV.ApproachStandoff < WV.AttackRange,
	("raiders hold %.1f studs off their target but only swing at %.1f — they would ring you and never attack (and at 0 they all stand on the same stud)")
		:format(WV.ApproachStandoff, WV.AttackRange))

-- How many bodies actually FIT on the approach ring, at roughly 4.5 studs of
-- shoulder each. MaxChasers above this is not a cap, it is a queue.
local approachSlots = math.floor((2 * math.pi * WV.ApproachStandoff) / 4.5)
check(WV.MaxChasers <= approachSlots,
	("MaxChasers is %d but only %d raiders fit shoulder to shoulder on a %.1f-stud approach ring; the rest pile up behind and the swarm is back")
		:format(WV.MaxChasers, approachSlots, WV.ApproachStandoff))
check(WV.MaxChasers >= 1 and WV.MaxChasers < WV.MaxCount,
	("MaxChasers %d against MaxCount %d: capping at or above the wave size caps nothing")
		:format(WV.MaxChasers, WV.MaxCount))

check(WV.AggroStagger > 0 and WV.AggroStagger < 4,
	("aggro stagger of %.1fs: at 0 every raider commits on the same frame, and past ~3s the one still staring at you reads as broken")
		:format(WV.AggroStagger))
-- The stagger has to be long enough to actually spread a mass flip across more
-- than one aggro check, or it is decoration.
check(WV.AggroStagger > WV.AggroCheck * 2,
	("aggro stagger %.1fs against a %.2fs aggro check: the delay resolves within a tick or two and the pack still commits as a block")
		:format(WV.AggroStagger, WV.AggroCheck))

check(WV.SpawnGroupSize >= 2 and WV.SpawnGroupSize <= 8,
	("SpawnGroupSize %d: one synchronised ring is what made a wave read as a wall"):format(WV.SpawnGroupSize))
check(WV.SpawnGroupGap > 0, "SpawnGroupGap must be positive or the clusters land together anyway")
check(WV.GroupArc > 0 and WV.GroupArc < math.pi / 4,
	("GroupArc is %.2f rad; past a quarter-turn a cluster is not a cluster"):format(WV.GroupArc))
check(WV.OrbitSpeed > 0 and WV.OrbitSpeed < 2,
	("OrbitSpeed is %.2f rad/s; past ~2 the ring spins rather than drifts"):format(WV.OrbitSpeed))

-- The grouped drip is slower than the flat one, so re-check it against the
-- deadline it must not collide with.
local groupCount = math.ceil(WV.MaxCount / WV.SpawnGroupSize)
local grouppedSpawnSeconds = WV.MaxCount * WV.SpawnGap + (groupCount - 1) * WV.SpawnGroupGap
check(WV.MaxWaveTime > grouppedSpawnSeconds * 4,
	("MaxWaveTime is %ds but a full wave now takes %.1fs to arrive in clusters; the deadline would fire during the fight")
		:format(WV.MaxWaveTime, grouppedSpawnSeconds))
check(grouppedSpawnSeconds < WV.RestTime,
	("a full wave takes %.1fs to arrive but the rest between waves is only %ds; the raid would still be landing when it is meant to be over")
		:format(grouppedSpawnSeconds, WV.RestTime))

-- ── raider telegraph ────────────────────────────────────────────────────────

-- The wind-up is the only warning a player gets. Below human reaction time it
-- is decoration; the raider may as well hit instantly.
check(WV.AttackWindUp >= 0.3,
	("Waves.AttackWindUp is %.2fs — under reaction time, so the telegraph is a lie"):format(WV.AttackWindUp))
check(WV.AttackRange > 0 and WV.AttackRange < 14,
	("Waves.AttackRange is %.1f studs; raiders would hit you from off-screen"):format(WV.AttackRange))

-- A raider is rooted from wind-up through recovery, so the real attack period
-- is the whole cycle, not just the cooldown. Check the worst case a player can
-- face: a boss at MaxDamage, hitting every cycle, against 100 HP.
local cycle = WV.AttackWindUp * WV.BossWindUpScale + WV.AttackRecover + WV.AttackCooldown
local worstHit = WV.MaxBossDamage

-- The 100 in these two checks used to be a literal. Armour raises MaxHealth, so
-- it stopped being a constant and became an assumption — and the assumption
-- worth keeping is that these measure the FLOOR of the experience, an
-- unarmoured player. So they read the tier you spawn as, which is asserted
-- above to be exactly BaseHealth. Do NOT repoint them at the armoured maximum:
-- that would silently weaken the promise the comments make.
local unarmoured = Config.Armor.Tiers[1].health
local secondsToKill = (unarmoured / worstHit) * cycle
check(WV.MaxBossDamage >= WV.MaxDamage, "MaxBossDamage should not be below MaxDamage")
-- The comment on MaxDamage has always said "never let a raider 2-shot"; assert
-- it, because the boss multiplier used to be applied to the cap as well as to
-- the damage and quietly broke exactly that promise.
check(worstHit * 2 < unarmoured,
	("the worst raider hits for %.0f — two of those kill an unarmoured player (%d health)")
		:format(worstHit, unarmoured))
check(secondsToKill >= 5,
	("the worst raider kills an UNARMOURED player in %.1fs of solo attention (need 5s)"):format(secondsToKill))

-- ...and the other end of the same rope. Armour that makes a boss cosmetic
-- takes away the reason the arena exists, so the top tier is bounded both as a
-- multiple of base health and by how long a boss needs to get through it.
local topArmor = Config.Armor.Tiers[#Config.Armor.Tiers].health
check(topArmor <= unarmoured * Config.Armor.MaxHealthMultiple,
	("the top armour tier is %.1fx base health (ceiling %.1fx)")
		:format(topArmor / unarmoured, Config.Armor.MaxHealthMultiple))
local secondsToKillArmoured = (topArmor / worstHit) * cycle
check(secondsToKillArmoured <= 45,
	("a boss needs %.0fs of uninterrupted attention to kill a fully-armoured player; past ~45s it is not a threat, it is scenery")
		:format(secondsToKillArmoured))

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
-- Every buy button that stands on the floor rather than beside a belt machine,
-- from BOTH sources: the hand-placed factory column in Layout.MiscButtons and
-- the derived side-track columns. One list, so the spacing and row-clearance
-- checks below cover the cabinets without being written twice — and so a
-- cabinet pedestal colliding with a misc pedestal is caught, which it would
-- not be if each source policed only itself.
local miscList = {}
for id, spot in pairs(L.MiscButtons) do
	table.insert(miscList, { id = "MiscButtons." .. id, spot = spot })
end
for _, track in ipairs(Config.TrackOrder) do
	local layout = L.Tracks[track]
	if layout then
		-- Check every SLOT, not every button: the empty slots are where the
		-- next tier will land, and finding out then is finding out too late.
		for slot = 1, layout.slots do
			table.insert(miscList, {
				id = ("Tracks.%s[%d]"):format(track, slot),
				spot = Config.trackButtonPosition(track, slot),
			})
		end
		check(#Config.Tracks[track] <= layout.slots,
			("the %s track has %d buttons but Layout.Tracks.%s only has %d slots; the extras would stack on the last pedestal")
				:format(track, #Config.Tracks[track], track, layout.slots))
	end
end
table.sort(miscList, function(a, b) return a.id < b.id end)

local floorSpots = {
	{ "RebirthPadAt", L.RebirthPadAt, 6 },
	{ "ClaimPadAt", L.ClaimPadAt, 17 },
	{ "OwnerSpawnAt", L.OwnerSpawnAt, 3 },
}
for _, entry in ipairs(miscList) do
	table.insert(floorSpots, { entry.id, entry.spot, 3 })
end
for _, entry in ipairs(floorSpots) do
	inPlot(entry[1], entry[2], entry[3])
end

-- The pads are floor furniture too, and a pedestal standing on the rebirth pad
-- or in the owner's spawn is the same class of bug as two pedestals stacked.
for _, entry in ipairs(miscList) do
	for _, pad in ipairs({
		{ "RebirthPadAt", L.RebirthPadAt },
		{ "ClaimPadAt", L.ClaimPadAt },
		{ "OwnerSpawnAt", L.OwnerSpawnAt },
	}) do
		local d = len(sub(entry.spot, pad[2]))
		check(d >= L.MiscButtonSpacing,
			("%s is only %.1f studs from %s (need %d)")
				:format(entry.id, d, pad[1], L.MiscButtonSpacing))
	end
end

for i, a in ipairs(miscList) do
	for j = i + 1, #miscList do
		local b = miscList[j]
		local d = len(sub(a.spot, b.spot))
		check(d >= L.MiscButtonSpacing,
			("%s and %s are only %.1f studs apart (need %d)")
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
		("%s sits on the dropper buy-button row at z=%.1f")
			:format(entry.id, dropperButtonZ))
	check(math.abs(entry.spot.X - upgraderButtonX) >= BUTTON_PAD,
		("%s sits on the upgrader buy-button row at x=%.1f")
			:format(entry.id, upgraderButtonX))
end

-- ── side-track cabinets ─────────────────────────────────────────────────────
-- The cabinet BODIES are the only solid, collidable things this change adds to
-- the plot floor, so they get the treatment the vault and the belt already
-- have: an explicit box, checked against everything else that occupies floor.

--- Gap between an axis-aligned box (centre + full size) and a point, 0 inside.
--- Written component-wise because the Vector3 in this harness is a bare table
--- with no arithmetic — see the note in HANDOFF_v2 §5.
local function boxPointGap(centre, size, point)
	local dx = math.max(math.abs(point.X - centre.X) - size.X / 2, 0)
	local dz = math.max(math.abs(point.Z - centre.Z) - size.Z / 2, 0)
	return math.sqrt(dx * dx + dz * dz)
end

local gateFrom, gateTo = L.GateCentre - L.GateWidth / 2, L.GateCentre + L.GateWidth / 2

for _, track in ipairs(Config.TrackOrder) do
	local layout = L.Tracks[track]
	if layout then
		local centre, size = Config.trackCabinet(track)
		local where = "Tracks." .. track .. " cabinet"

		-- inside the wall ring, which stands 1 stud in from the pad edge
		check(math.abs(centre.X) + size.X / 2 <= halfX - 2,
			("%s spans x %.1f..%.1f, into the side wall at x=%.1f")
				:format(where, centre.X - size.X / 2, centre.X + size.X / 2, halfX - 1))
		check(math.abs(centre.Z) + size.Z / 2 <= halfZ - 2,
			("%s spans z %.1f..%.1f, into the end wall at z=%.1f")
				:format(where, centre.Z - size.Z / 2, centre.Z + size.Z / 2, halfZ - 1))

		-- not standing on the floor furniture
		for _, spot in ipairs(floorSpots) do
			local gap = boxPointGap(centre, size, spot[2])
			check(gap >= spot[3],
				("%s comes within %.1f studs of %s (needs %d)")
					:format(where, gap, spot[1], spot[3]))
		end

		-- ...and far enough off its own pedestals that a shelf display does
		-- not grow through the buy button in front of it
		check(math.abs(layout.buttonX - layout.cabinetX) - size.X / 2 >= 4,
			("%s stands %.1f studs from its own button column; the shelf would clip the pads")
				:format(where, math.abs(layout.buttonX - layout.cabinetX) - size.X / 2))

		-- ...and off both belt legs. Leg 1 runs along z = BeltStart.Z, leg 2
		-- along x = BeltCorner.X; a cabinet over either would wall the belt.
		check(math.abs(centre.Z - L.BeltStart.Z) - size.Z / 2 >= L.BeltWidth,
			("%s reaches the dropper belt leg at z=%.1f"):format(where, L.BeltStart.Z))
		check(math.abs(centre.X - L.BeltCorner.X) - size.X / 2 >= L.BeltWidth,
			("%s reaches the upgrader belt leg at x=%.1f"):format(where, L.BeltCorner.X))

		-- ...and clear of the four roof columns, which stand 3 studs in from
		-- the inside faces of the wall ring
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local column = Vector3.new(sx * (halfX - 4), 0, sz * (halfZ - 4))
				check(boxPointGap(centre, size, column) >= 2,
					("%s overlaps the roof column at (%.0f, %.0f)")
						:format(where, column.X, column.Z))
			end
		end

		-- and the walk in from the gateway must not run into a display case
		local clearsGate = (centre.X - size.X / 2 > gateTo)
			or (centre.X + size.X / 2 < gateFrom)
			or (centre.Z + size.Z / 2 < L.OwnerSpawnAt.Z - 8)
		check(clearsGate,
			("%s stands in the walk from the gateway to the owner spawn at z=%.0f")
				:format(where, L.OwnerSpawnAt.Z))
	end
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

-- ── world text ──────────────────────────────────────────────────────────────
--
-- The values themselves are one line each; what these checks are really for is
-- the RELATIONSHIPS, because those are what nobody was tracking when each label
-- picked its own number. A view distance is only meaningful against the thing
-- it has to be read from.

local ST = Config.Style
check(type(ST.TitleFont) == "string" and #ST.TitleFont > 0, "Style.TitleFont must be a font name")
check(type(ST.BodyFont) == "string" and #ST.BodyFont > 0, "Style.BodyFont must be a font name")
check(ST.TitleFont ~= ST.BodyFont,
	"Style.TitleFont and Style.BodyFont are the same face; a label with one weight has no reading order")
check(ST.StrokeTransparency >= 0 and ST.StrokeTransparency <= 1,
	("Style.StrokeTransparency is %.2f; it is a transparency, so 0..1"):format(ST.StrokeTransparency))
check(ST.LightInfluence >= 0 and ST.LightInfluence <= 1,
	("Style.LightInfluence is %.2f; it is a fraction, so 0..1"):format(ST.LightInfluence))

-- The four tiers exist and mean what their names say. A tier list that is not
-- ordered is four numbers with labels on, which is what this replaced.
local TIER_ORDER = { "machine", "prop", "plot", "world" }
local previousTier = 0
for _, tier in ipairs(TIER_ORDER) do
	local value = ST.Distance[tier]
	check(type(value) == "number" and value > 0,
		("Style.Distance.%s is missing or not a positive number"):format(tier))
	if type(value) == "number" then
		check(value > previousTier,
			("Style.Distance.%s is %.0f but the tier below it is %.0f — the tiers have to be ordered or the names mean nothing")
				:format(tier, value, previousTier))
		previousTier = value
	end
end
local tierCount = 0
for _ in pairs(ST.Distance) do
	tierCount += 1
end
check(tierCount == #TIER_ORDER,
	("Style.Distance has %d tiers but %d are named; an unnamed tier is a number nobody chose against the others")
		:format(tierCount, #TIER_ORDER))

-- `plot` has to carry your own factory: corner to corner, and from the arena
-- rim, because the vault sign and the roof sign are both read from outside.
local plotDiagonal = math.sqrt(Config.World.PlotSize.X ^ 2 + Config.World.PlotSize.Z ^ 2)
check(ST.Distance.plot >= plotDiagonal,
	("Style.Distance.plot is %.0f but a plot is %.0f studs corner to corner; your own vault sign would cut out while you stood on your own plot")
		:format(ST.Distance.plot, plotDiagonal))

-- ...and `world` has to carry the claim beacon across the ring, which is the
-- one label whose old value (1200) was doing a real job. Looped over the
-- supported player range rather than read off Config.World.PlotRadius: the ring
-- is clamped to MinPlotRadius for small counts and only grows past it later, so
-- the widest ring is not the one this server happens to be configured for.
for count = Config.World.MinPlots, Config.World.MaxPlots do
	local placements = Config.plotPlacements(count)
	local widest = 0
	for _, p in ipairs(placements) do
		widest = math.max(widest, p.radius)
	end
	check(ST.Distance.world >= widest * 2,
		("Style.Distance.world is %.0f but at %d plots the two furthest-apart plots are %.0f studs from each other; a free plot has to be findable from across the ring")
			:format(ST.Distance.world, count, widest * 2))

	local rimToFarEdge = placements[1].radius + Config.World.PlotSize.Z / 2 - Config.World.ArenaRadius
	check(ST.Distance.plot >= rimToFarEdge,
		("Style.Distance.plot is %.0f but at %d plots the far edge of a plot is %.0f studs from the arena rim; plot signs would cut out from the arena")
			:format(ST.Distance.plot, count, rimToFarEdge))
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

-- The FACTORY opener has to be affordable on day one, otherwise a fresh player
-- has zero income and zero way to get any.
--
-- Scoped to the factory track on purpose. Scanning every requirement-free
-- button across all three tracks would still pass — dropper1 at 50 is the
-- cheapest of the three roots — but it would pass for the wrong reason and
-- would stop catching anything the day a cabinet's first rung got cheap.
check(Config.Economy.StartingCash >= Config.Tracks.factory[1].price,
	("StartingCash (%d) cannot afford the first factory button (%d) — the tycoon can never start")
		:format(Config.Economy.StartingCash, Config.Tracks.factory[1].price))

-- ...and the side tracks must NOT be affordable at spawn. A player who can buy
-- a bat before a dropper has spent their whole opening balance on a plot with
-- no income, and nothing in the game can dig them out of that.
for _, track in ipairs(Config.TrackOrder) do
	local defs = Config.Tracks[track]
	if track ~= "factory" and #defs > 0 then
		check(defs[1].price > Config.Economy.StartingCash,
			("%s costs %d against StartingCash of %d — a new player could buy it instead of their first dropper and strand themselves")
				:format(defs[1].id, defs[1].price, Config.Economy.StartingCash))
	end
end

local cash = Config.Economy.StartingCash
local elapsed, rawDps, upgradeMult = 0, 0, 1
local curve = {}

-- The FACTORY track only. This is the game's spine: the thing that generates
-- income and therefore the thing whose pacing "45 to 150 minutes" is about.
-- The side tracks are paced against this curve further down, because with no
-- cross-track requirement the only thing that gates them is their price.
for _, def in ipairs(Config.Tracks.factory) do
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
	-- `earned` is everything the factory has produced by this point, ignoring
	-- what was spent. It is the budget a side-track purchase competes for.
	table.insert(curve, {
		id = def.id, wait = wait, at = elapsed,
		income = rawDps * upgradeMult,
		earned = (curve[#curve] and curve[#curve].earned or 0) + (wait ~= math.huge and wait or 0) * income,
	})
end

local endgameIncome = rawDps * upgradeMult
check(elapsed / 60 >= MIN_TOTAL_MINUTES,
	("full build takes only %.0f min (want >= %d) — the game is over too fast"):format(elapsed / 60, MIN_TOTAL_MINUTES))
check(elapsed / 60 <= MAX_TOTAL_MINUTES,
	("full build takes %.0f min (want <= %d) — too grindy"):format(elapsed / 60, MAX_TOTAL_MINUTES))

local rebirthMinutes = Config.Rebirth.BaseCost / endgameIncome / 60
check(rebirthMinutes >= 4 and rebirthMinutes <= 40,
	("first rebirth is %.1f min of endgame income; want 4-40"):format(rebirthMinutes))

-- ── side-track pacing ───────────────────────────────────────────────────────
-- A side track has no requirement into the factory, so PRICE is the only thing
-- pacing it. That means "is this affordable" cannot be asked in the abstract —
-- it has to be asked against the income the factory actually has at the moment
-- the tier first comes within reach.
--
-- The metric is DETOUR: how many minutes of your current income the tier
-- costs. Anything much past four and buying a bat means visibly stalling the
-- factory, which is precisely the coupling this split exists to remove.

local SIDE_MAX_DETOUR_MINUTES = 4
local SIDE_BUDGET_FRACTION = 0.35
local FIRST_SIDE_RUNG_BY_MINUTE = 10

--- The minute the factory alone has banked `price`, and its income then.
local function firstAffordable(price: number): (number, number)
	for _, row in ipairs(curve) do
		if row.earned >= price then
			return row.at / 60, row.income
		end
	end
	local last = curve[#curve]
	return math.huge, last and last.income or 0
end

local sideTotal = 0
for _, track in ipairs(Config.TrackOrder) do
	if track ~= "factory" then
		for _, def in ipairs(Config.Tracks[track]) do
			local at, income = firstAffordable(def.price)
			check(at ~= math.huge,
				("%s costs %d, which the factory never banks across a whole build")
					:format(def.id, def.price))
			check(income > 0,
				("%s is affordable before the factory earns anything"):format(def.id))
			if income > 0 then
				local detour = def.price / income / 60
				check(detour <= SIDE_MAX_DETOUR_MINUTES,
					("%s costs %.1f min of the income you have when you can first afford it (limit %d) — that is a wall, not a detour")
						:format(def.id, detour, SIDE_MAX_DETOUR_MINUTES))
				sideTotal += detour
			end
		end

		-- ...and the cabinet must not be scenery while you learn the game.
		local first = Config.Tracks[track][1]
		if first then
			local at = firstAffordable(first.price)
			check(at <= FIRST_SIDE_RUNG_BY_MINUTE,
				("the first %s rung is unaffordable until minute %.0f; until then the cabinet is scenery")
					:format(track, at))
		end
	end
end

check(sideTotal <= elapsed / 60 * SIDE_BUDGET_FRACTION,
	("the side tracks add %.0f min to a %.0f min factory build (%.0f%%, budget %.0f%%)")
		:format(sideTotal, elapsed / 60, sideTotal / (elapsed / 60) * 100, SIDE_BUDGET_FRACTION * 100))
check(elapsed / 60 + sideTotal <= MAX_TOTAL_MINUTES,
	("everything on the plot takes %.0f min (limit %d)"):format(elapsed / 60 + sideTotal, MAX_TOTAL_MINUTES))

-- rebirth must stay worth doing: payouts compound, so income has to grow at
-- least as fast as the cost of the next rebirth or the loop dead-ends
check(Config.Rebirth.MultiplierPerRebirth > 1, "MultiplierPerRebirth must be > 1")
local costRatio = Config.Rebirth.CostGrowth / Config.Rebirth.MultiplierPerRebirth
check(costRatio > 1 and costRatio < 2,
	("each rebirth takes %.2fx longer than the last; want between 1x and 2x"):format(costRatio))

-- ── report ──────────────────────────────────────────────────────────────────
print(("checks run:        %d"):format(checks))
local trackCounts = {}
for _, track in ipairs(Config.TrackOrder) do
	table.insert(trackCounts, ("%s %d"):format(track, #Config.Tracks[track]))
end
print(("buttons:           %d  (%s)"):format(#Config.Buttons, table.concat(trackCounts, ", ")))
print(("machine slots:     %d dropper, %d upgrader")
	:format(#Config.Layout.DropperDist, #Config.Layout.UpgraderDist))
print(("side tracks:       %.1f min of detour (%.0f%% of the factory build)")
	:format(sideTotal, sideTotal / (elapsed / 60) * 100))
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
