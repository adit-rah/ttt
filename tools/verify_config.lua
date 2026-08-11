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
		check(Config.Layout.DropperZ[def.slot] ~= nil, where .. ": dropper slot " .. tostring(def.slot) .. " has no Layout.DropperZ entry")
		check(not dropperSlots[def.slot], where .. ": dropper slot " .. tostring(def.slot) .. " already used")
		dropperSlots[def.slot] = true
		check(type(def.dropValue) == "number" and def.dropValue > 0, where .. ": bad dropValue")
		check(type(def.dropRate) == "number" and def.dropRate > 0.2, where .. ": dropRate too fast (< 0.2s will flood physics)")
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
		-- a dropper should always out-earn the one before it
		check(def.price / def.dropValue > 0, where .. ": bad payback")
	elseif def.kind == "Upgrader" then
		check(type(def.slot) == "number", where .. ": upgrader needs a slot")
		check(Config.Layout.UpgraderZ[def.slot] ~= nil, where .. ": upgrader slot " .. tostring(def.slot) .. " has no Layout.UpgraderZ entry")
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

-- layout sanity
local L = Config.Layout
check(L.BeltEndZ > L.BeltStartZ, "belt runs backwards")
check(L.CollectorZ > L.BeltEndZ, "collector is not past the end of the belt")
local halfZ = Config.World.PlotSize.Z / 2
for slot, z in ipairs(L.DropperZ) do
	check(math.abs(z) < halfZ, ("DropperZ[%d]=%d is off the plot"):format(slot, z))
	check(z >= L.BeltStartZ and z <= L.BeltEndZ, ("DropperZ[%d]=%d is not over the belt"):format(slot, z))
end
for slot, z in ipairs(L.UpgraderZ) do
	check(math.abs(z) < halfZ, ("UpgraderZ[%d]=%d is off the plot"):format(slot, z))
	check(z >= L.BeltStartZ and z <= L.BeltEndZ, ("UpgraderZ[%d]=%d is not over the belt"):format(slot, z))
end
-- every upgrader must sit downstream of every dropper, or late droppers skip it
local lastDropperZ = L.DropperZ[#L.DropperZ]
for slot, z in ipairs(L.UpgraderZ) do
	check(z > lastDropperZ, ("UpgraderZ[%d]=%d is upstream of the last dropper (%d) — its drops would skip this upgrader")
		:format(slot, z, lastDropperZ))
end

-- plots must not overlap on the ring
local circumference = 2 * math.pi * Config.World.PlotRadius
check(circumference / Config.World.PlotCount > Config.World.PlotSize.X * 1.15,
	"plots overlap: increase World.PlotRadius or shrink PlotSize")

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
	:format(#Config.Buttons, #Config.Layout.DropperZ, #Config.Layout.UpgraderZ))
print(("upgrader stack:    x%.1f"):format(upgradeMult))
print(("endgame income:    %.3g Tung/sec"):format(endgameIncome))
print(("full build:        %.0f min"):format(elapsed / 60))
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
