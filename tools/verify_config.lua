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
local KNOWN_KINDS = { Dropper = true, Upgrader = true, Belt = true, Structure = true, Gear = true, Armor = true, Floor = true, Power = true }
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

	-- A BELT MACHINE IS EITHER SLOTTED OR PINNED.
	--
	-- `slot` indexes Layout.DropperDist / UpgraderDist, which describe the
	-- GROUND floor's two legs and nothing else. A machine on any other floor
	-- names its path and its distance along a leg of it instead — which is what
	-- Tycoon:legOf has always accepted, and what the slot tables could never
	-- express. One or the other, never both and never neither.
	local function checkPlacement(kind, distances, used)
		if def.path then
			check(def.slot == nil,
				("%s carries both a slot and a path; a slot means the ground floor's %s"):format(where, kind))
			local known = false
			for _, path in ipairs(Config.BeltPaths) do
				known = known or path.id == def.path
			end
			check(known, ("%s names belt path %q, which is not in Config.BeltPaths"):format(where, tostring(def.path)))
			check(type(def.legIndex) == "number" and def.legIndex >= 1,
				where .. ": a pinned machine needs a legIndex")
			check(type(def.legDistance) == "number" and def.legDistance >= 0,
				where .. ": a pinned machine needs a legDistance")
		else
			check(type(def.slot) == "number", where .. ": " .. kind .. " needs a slot or a path")
			check(distances[def.slot] ~= nil,
				where .. ": " .. kind .. " slot " .. tostring(def.slot) .. " has no distance entry")
			check(not used[def.slot], where .. ": " .. kind .. " slot " .. tostring(def.slot) .. " already used")
			used[def.slot] = true
		end
	end

	if def.kind == "Dropper" then
		checkPlacement("dropper", Config.Layout.DropperDist, dropperSlots)
		check(type(def.dropValue) == "number" and def.dropValue > 0, where .. ": bad dropValue")
		check(type(def.dropRate) == "number" and def.dropRate > 0.2, where .. ": dropRate too fast (< 0.2s will flood physics)")
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
		-- a dropper should always out-earn the one before it
		check(def.price / def.dropValue > 0, where .. ": bad payback")
	elseif def.kind == "Upgrader" then
		checkPlacement("upgrader", Config.Layout.UpgraderDist, upgraderSlots)
		check(type(def.multiplier) == "number" and def.multiplier > 1, where .. ": multiplier must be > 1")
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
	elseif def.kind == "Floor" then
		local floor
		for _, entry in ipairs(Config.Floors) do
			if entry.button == def.id then
				check(floor == nil,
					("two Floor buttons both build %s; the second would charge and do nothing"):format(entry.id))
				floor = entry
			end
		end
		check(floor ~= nil,
			("%s is a Floor button but no Config.Floors entry names it; it would charge and build nothing"):format(where))
		check(def.floor == nil or (floor and floor.id == def.floor),
			("%s says it builds floor %q but Config.Floors disagrees"):format(where, tostring(def.floor)))
	elseif def.kind == "Belt" then
		check(type(def.speedBonus) == "number" and def.speedBonus > 0, where .. ": bad speedBonus")
	elseif def.kind == "Structure" then
		check(KNOWN_STRUCTURES[def.structure], where .. ": unknown structure " .. tostring(def.structure))
	elseif def.kind == "Power" then
		-- `factor` is CUMULATIVE, so the ladder is checked as a ladder: each
		-- rung must actually grant more than the one below it, and the step
		-- between them has to stay inside the band that makes the yard four
		-- even rungs rather than three decorations and one big one.
		check(type(def.factor) == "number" and def.factor > 1,
			("%s: factor must be > 1; a rung that speeds nothing up is a rung that charges for nothing"):format(where))
		-- THE INVERSE OF WHAT USED TO BE HERE, which asserted a unique slot per
		-- rung in 1..Yard.Slots. A per-rung slot is exactly how the yard came to
		-- grow four generators and four buy pads on a plot that had bought none
		-- of them — the defect this whole change exists for. There is one stand
		-- now, and every rung upgrades the machine on it.
		check(def.slot == nil,
			("%s carries a yard slot; there is one generator, and a second position would build a second machine behind the plot")
				:format(where))
		check(Config.Variants[def.variant] ~= nil, where .. ": unknown variant " .. tostring(def.variant))
		if def.trackOrder > 1 then
			local below = Config.Tracks.power[def.trackOrder - 1]
			check(def.factor > below.factor,
				("%s grants %.2fx but %s already grants %.2fx — the rung would charge and do nothing")
					:format(where, def.factor, below.id, below.factor))
			local step = def.factor / below.factor
			check(step >= Config.Power.StepMin and step <= Config.Power.StepMax,
				("%s steps production by %.2fx (want %.2f-%.2f); the yard is four even rungs, not one big one")
					:format(where, step, Config.Power.StepMin, Config.Power.StepMax))
		end
		if def.trackOrder == #Config.Tracks.power then
			check(math.abs(def.factor - Config.Power.MaxFactor) < 1e-9,
				("the top power rung grants %.2fx but Power.MaxFactor is %.2f — the yard's headline number and its data disagree")
					:format(def.factor, Config.Power.MaxFactor))
		end
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

-- A PATH STATES THE HEIGHT IT RUNS AT, and the ground floor runs at zero.
--
-- These are the config half of "a buy button honours its own height". The other
-- half - whether the part that got built is where buttonPosition said - is a
-- Studio-only self-test in Tycoon:buildButtons, because the verifier sees data
-- and this is a question about instances. Until the mezzanine's path is data
-- these are trivially true, which is the point: they are the regression guard
-- for the moment it stops being trivial.
for index, path in ipairs(Config.BeltPaths) do
	check(type(path.y) == "number",
		("BeltPaths.%s has no y; a path that does not state its height gets built at 0")
			:format(tostring(path.id)))
	if index == 1 then
		check(path.y == 0,
			("BeltPaths.%s is the ground floor and must run at y=0, not %.1f"):format(path.id, path.y))
	end
end

-- PER-TRACK METADATA. The fourth track's most likely bug is a per-track table
-- that only got three of its four rows, and every one of those tables fails
-- differently and none of them fail loudly — the rebirth one fails OPEN. So the
-- facts live in one table and this asserts it is complete.
local TRACK_FIELDS = { "label", "preview", "keepOnRebirth", "paced", "furniture" }
for _, track in ipairs(Config.TrackOrder) do
	local info = Config.TrackInfo[track]
	check(info ~= nil,
		("track %q has no TrackInfo entry; the fourth track's most likely bug is a per-track table that only got three of its four rows")
			:format(track))
	if info then
		for _, field in ipairs(TRACK_FIELDS) do
			check(info[field] ~= nil, ("TrackInfo.%s is missing %q"):format(track, field))
		end
		check(info.paced == "spine" or info.paced == "side",
			("TrackInfo.%s.paced is %q; it is either the spine the build time is measured on, or a detour from it")
				:format(track, tostring(info.paced)))
	end
	check(Config.TrackRank[track] ~= nil, ("track %q has no rank"):format(track))
end
for track in pairs(Config.TrackInfo) do
	check(Config.Tracks[track] ~= nil,
		("TrackInfo names track %q, which has no button table"):format(track))
end
check(Config.TrackOrder[1] == "factory",
	"TrackOrder no longer starts with the factory — `order` is the install-replay key, and every factory button's order would shift")
check(Config.TrackInfo.factory.keepOnRebirth == false,
	"TrackInfo.factory.keepOnRebirth is true; a rebirth is a factory reset by definition")
check(Config.TrackInfo.factory.paced == "spine",
	"the factory is the spine the build time is measured on")
for rank, track in ipairs(Config.TrackOrder) do
	check(Config.TrackRank[track] == rank,
		("TrackRank disagrees with TrackOrder for %q; the beacon on the plot and the panel in the HUD would name different purchases")
			:format(track))
end

-- TRACK GATES. A precondition on a whole ladder, not a link inside one — so the
-- failures worth naming are the ones that would quietly turn it back into a
-- link, or into a cycle.
for track, gate in pairs(Config.TrackUnlock) do
	check(Config.Tracks[track] ~= nil,
		("TrackUnlock names track %q, which does not exist"):format(track))
	local def = Config.ButtonById[gate]
	check(def ~= nil,
		("TrackUnlock.%s is gated on %q, which is not a button"):format(track, tostring(gate)))
	if def then
		check(def.track ~= track,
			("TrackUnlock.%s is gated on %s, which is on the %s track itself — that is a chain link, not a gate")
				:format(track, gate, track))
		check(def.track == "factory",
			("TrackUnlock.%s is gated on a %s-track button; a side track cannot gate another side track, or two of them can deadlock each other")
				:format(track, tostring(def.track)))
	end
end
check(Config.TrackUnlock.factory == nil,
	"the factory track cannot be gated — it is the thing that pays for everything else")

-- ── analytics ───────────────────────────────────────────────────────────────
--
-- EVERY LIMIT IN THIS SECTION FAILS SILENTLY IN ROBLOX. Not one of them raises,
-- warns or shows up in the output window: exceed the field cap and the fourth
-- field is discarded, pass a number and the value is discarded, exceed the
-- combination budget and the extra combinations are simply not counted. There is
-- no runtime symptom at all — only a chart, weeks later, that is wrong in a way
-- that looks exactly like data.
--
-- So this block is the ONLY place any of it is checkable, and that is why the
-- schema was put in Config where the verifier can see it instead of being
-- written inline at each call site.

local AN = Config.Analytics

check(AN.MaxFields == 3,
	("Analytics.MaxFields is %s; Roblox reads exactly three custom fields per event and drops the rest without saying so")
		:format(tostring(AN.MaxFields)))
check(AN.MaxCombinations <= 8000,
	"Analytics.MaxCombinations is above the 8,000 the whole experience gets; the surplus combinations are counted by nothing")
check(AN.MaxEventNames <= 100,
	"Analytics.MaxEventNames is above the 100 custom event names an experience gets")
check(type(AN.Enabled) == "boolean",
	"Analytics.Enabled is not a boolean; the kill switch has to be a switch")
check(AN.HelloTimeoutSeconds > 0 and AN.HelloTimeoutSeconds <= 30,
	("the join waits %s seconds for the client's platform; longer than 30 and a short session logs its start after it has already ended")
		:format(tostring(AN.HelloTimeoutSeconds)))
check(AN.TailSize >= 1, "Analytics.TailSize below 1 leaves no way to see what the server actually sent")
check(AN.RateBurst > 0 and AN.RatePerPlayerPerMinute > 0,
	"a token bucket with no tokens sends nothing, and it does so silently")

-- FIELDS. A field is a CLOSED set of strings. Closed, because an open one
-- spends a fresh combination out of the experience-wide budget every time a new
-- value appears; strings, because Roblox drops a numeric field value.
local usedFields = {}
for name, field in pairs(AN.Fields) do
	local where = ("Analytics.Fields.%s"):format(name)

	check(type(field.values) == "table" and #field.values > 0,
		("%s has no values; an event carrying it would log a field Roblox discards"):format(where))
	check(#field.values <= AN.MaxFieldValues,
		("%s has %d values against a ceiling of %d — a set this wide multiplies through every event that carries it and eats the shared 8,000-combination budget")
			:format(where, #field.values, AN.MaxFieldValues))

	local seen = {}
	for index, value in ipairs(field.values) do
		check(type(value) == "string",
			("%s[%d] is a %s; Roblox drops a custom field value that is not a string, and logs the event anyway")
				:format(where, index, type(value)))
		check(not seen[value],
			("%s lists %s twice; the duplicate is invisible in the data and makes the combination count a lie")
				:format(where, tostring(value)))
		seen[value] = true
	end

	-- A BUCKET LADDER. #values must be #bounds + 1 exactly: one label per band
	-- plus the open-ended top. One short and the top band silently reports as
	-- the band below it.
	if field.bounds then
		check(#field.values == #field.bounds + 1,
			("%s has %d bounds and %d labels; a ladder needs one label per band plus one for the open top, or the top band reports as the band below it")
				:format(where, #field.bounds, #field.values))
		local previous = nil
		for index, bound in ipairs(field.bounds) do
			check(type(bound) == "number",
				("%s.bounds[%d] is not a number; the bucket it names can never be reached"):format(where, index))
			if previous ~= nil then
				check(type(bound) == "number" and bound > previous,
					("%s.bounds are not ascending at index %d; every value past this point lands in the earlier bucket")
						:format(where, index))
			end
			previous = bound
		end
	end
end

-- The two sets that are DERIVED must actually match the ladder they are derived
-- from. A hand-edit here would go stale at the next button and log purchases
-- under a facet that no longer names them.
check(#AN.Fields.buttonId.values == #Config.Tracks.factory,
	("Analytics buttonId lists %d ids against %d factory buttons; a first purchase of a missing id gets filed under someone else's button")
		:format(#AN.Fields.buttonId.values, #Config.Tracks.factory))
for _, id in ipairs(AN.Fields.buttonId.values) do
	check(Config.ButtonById[id] ~= nil,
		("Analytics buttonId names %q, which is not a button; nothing will ever be logged under it"):format(tostring(id)))
end
check(#AN.Fields.milestone.values == #Config.Buttons + 1,
	("Analytics milestone lists %d values against %d buttons plus \"none\"; a session that stopped at a missing rung is filed at the wrong one")
		:format(#AN.Fields.milestone.values, #Config.Buttons))
local milestoneHasNone = false
for _, id in ipairs(AN.Fields.milestone.values) do
	milestoneHasNone = milestoneHasNone or id == "none"
	check(id == "none" or Config.ButtonById[id] ~= nil,
		("Analytics milestone names %q, which is not a button"):format(tostring(id)))
end
check(milestoneHasNone,
	"Analytics milestone has no \"none\"; a session that bought nothing is the single most important row on session_end and it would be snapped onto a button they never touched")

-- The two fallbacks the runtime reaches for when it has no answer.
local function setHas(field, value)
	for _, entry in ipairs(field.values) do
		if entry == value then
			return true
		end
	end
	return false
end
check(setHas(AN.Fields.platform, "unknown"),
	"Analytics platform has no \"unknown\"; a session whose client never answered would be filed as a real device")
check(setHas(AN.Fields.entry, "unknown"),
	"Analytics entry has no \"unknown\"; a failed GetJoinData would be filed as a direct join")

-- EVENTS.
check(#AN.Events <= AN.MaxEventNames,
	("%d event names against a ceiling of %d for the whole experience"):format(#AN.Events, AN.MaxEventNames))
local seenEvents = {}
for _, event in ipairs(AN.Events) do
	local where = ("Analytics.Events %s"):format(tostring(event.name))

	-- lower_snake_case, spelled out rather than as one pattern: Lua patterns
	-- cannot repeat a group, so `^[a-z][a-z0-9]*(_[a-z0-9]+)*$` does not mean
	-- what it looks like it means and matches nothing.
	local name = type(event.name) == "string" and event.name or ""
	local snake = #name > 0
		and name:find("[^a-z0-9_]") == nil
		and name:match("^[a-z]") ~= nil
		and name:match("[a-z0-9]$") ~= nil
		and name:find("__") == nil
	check(snake,
		("%s is not lower_snake_case; Roblox groups events by exact name, so a stray capital or space becomes a second chart nobody looks at")
			:format(where))
	check(not seenEvents[event.name],
		("%s is declared twice; the two would silently merge into one chart with both meanings in it"):format(where))
	seenEvents[event.name] = true

	check(type(event.value) == "string" and #event.value > 0,
		("%s does not say what its `value` number means; an unlabelled aggregate is unreadable six months later"):format(where))

	check(type(event.fields) == "table" and #event.fields >= 1 and #event.fields <= AN.MaxFields,
		("%s carries %s fields; Roblox reads %d and discards the rest without a word")
			:format(where, tostring(event.fields and #event.fields), AN.MaxFields))

	local seenOnEvent = {}
	for _, fieldName in ipairs(event.fields or {}) do
		check(AN.Fields[fieldName] ~= nil,
			("%s names field %q, which has no declared value set — its values would be unbounded and would eat the combination budget")
				:format(where, tostring(fieldName)))
		check(not seenOnEvent[fieldName],
			("%s carries %q twice, so one of its three field slots reports nothing new"):format(where, tostring(fieldName)))
		seenOnEvent[fieldName] = true
		usedFields[fieldName] = true
	end
end

-- A field nobody carries is a set that will drift out of date unnoticed and
-- then be wrong the day somebody does carry it.
for name in pairs(AN.Fields) do
	check(usedFields[name],
		("Analytics.Fields.%s is declared but no event carries it"):format(name))
end

-- THE SHARED BUDGET. Summed across events, not maxed: two events with entirely
-- different facets each spend their own product out of one experience-wide pool
-- of 8,000. This is the check that a well-meaning "let's also break it down by
-- button" fails, and it is the only warning anyone will get.
local analyticsCombinations = Config.analyticsCombinations()
check(analyticsCombinations <= AN.MaxCombinations,
	("the schema spends %d of the experience's %d field-value combinations; past the limit Roblox stops counting new ones and the charts flatten out with no error anywhere")
		:format(analyticsCombinations, AN.MaxCombinations))

-- ECONOMY EVENTS have their own three limits, and the SKU one is the one this
-- game will actually reach: every button is a SKU.
check(#Config.Buttons <= AN.MaxEconomySkus,
	("%d buttons against a %d-SKU ceiling per experience; a fifth track reaches this, and the SKUs past it are dropped from every economy event silently")
		:format(#Config.Buttons, AN.MaxEconomySkus))
check(#AN.TransactionTypes <= AN.MaxTransactionTypes,
	("%d transaction types against a ceiling of %d per experience"):format(#AN.TransactionTypes, AN.MaxTransactionTypes))
local seenTransactions = {}
for _, transaction in ipairs(AN.TransactionTypes) do
	check(type(transaction) == "string" and #transaction > 0,
		"a transaction type that is not a string is dropped from the economy event that carries it")
	check(not seenTransactions[transaction],
		("transaction type %q is listed twice, so the budget of 20 is being counted wrong"):format(tostring(transaction)))
	seenTransactions[transaction] = true
end
check(type(AN.Currency) == "string" and #AN.Currency > 0,
	"Analytics.Currency is empty; every economy event would aggregate under a nameless currency")
check(AN.MaxCurrencyTypes >= 1,
	"Analytics.MaxCurrencyTypes below 1 leaves no currency for an economy event to be denominated in")

-- ...and a hand-placed button coordinate is a FLOOR coordinate. Its height
-- comes from the pedestal it stands on, not from the table, so a stray Y here
-- would be a button hovering for no stated reason.
for id, spot in pairs(Config.Layout.MiscButtons) do
	check(spot.Y == 0,
		("Layout.MiscButtons.%s carries y=%.1f; misc buttons stand on the plot floor and take their height from the pedestal")
			:format(id, spot.Y))
end

-- Floors. The deck must clear everything the ground floor stands up, and the
-- button that builds it must be a real one — a floor gated on a typo never
-- opens.
--
-- WHERE the floor lands in the build is asserted separately, below the
-- progression simulation, because it is a question about MINUTES and this block
-- runs before the curve exists. It used to live here as
-- `trackOrder >= #factory - 1` — "finish the ground floor first" — which is
-- index-based, so it could express "at the end" and could not express "halfway"
-- at all. HANDOFF_v4 predicted this exact break: an assertion written against a
-- global that quietly became a per-track one, and now a positional one that
-- had to become a measured one.
local plotHalfX, plotHalfZ = Config.World.PlotSize.X / 2, Config.World.PlotSize.Z / 2
for _, floor in ipairs(Config.Floors) do
	local unlock = Config.ButtonById[floor.button]
	check(unlock ~= nil,
		("Floors.%s is built by %q, which is not a button"):format(floor.id, tostring(floor.button)))
	if unlock then
		check(unlock.kind == "Floor",
			("Floors.%s is built by %s, which is a %s button — a floor needs a Floor button so the installer knows what it is")
				:format(floor.id, unlock.id, tostring(unlock.kind)))
		check(unlock.track == "factory",
			("Floors.%s is bought on the %s track; a floor is factory progression")
				:format(floor.id, tostring(unlock.track)))
		-- Without a MiscButtons entry buttonPosition falls back to (0,0,0) and
		-- says nothing about it: the button gets built at the plot origin, on
		-- top of the belt.
		check(Config.Layout.MiscButtons[unlock.id] ~= nil,
			("Floors.%s's buy button %s has no Layout.MiscButtons position — it would be built at the plot origin, on the belt")
				:format(floor.id, unlock.id))
	end
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

-- ── wave size ───────────────────────────────────────────────────────────────
--
-- Two things a bigger wave can break that nothing else here was watching: what
-- it costs the server, and whether anyone can still finish one.

-- The wave where the count stops climbing. Everything past it is the same size,
-- so it is the only wave whose cost has to be checked.
local saturationWave = math.ceil((WV.MaxCount - WV.BaseCount) / WV.CountPerWave) + 1
check(saturationWave >= 3,
	("the wave count saturates at wave %d; the ramp is the pacing, and skipping it lands a full-size raid on somebody's third minute")
		:format(saturationWave))

-- PART BUDGET. The verifier cannot see TungModels, so Waves.PartsPerRaider is
-- the only handle it has on this at all — and a wave cap is exactly the number
-- someone raises without asking what it costs on a ten-player server.
local waveParts = WV.MaxCount * WV.PartsPerRaider
check(waveParts <= WV.MaxRaiderParts,
	("a full wave is %d raiders x %d parts = %d, against a budget of %d — this is the number that decides what a full server looks like at full scale")
		:format(WV.MaxCount, WV.PartsPerRaider, waveParts, WV.MaxRaiderParts))

-- REINFORCEMENTS, NOT A BIGGER BLOB. The anti-swarm work caps how many raiders
-- may engage one player; raising MaxCount is only safe while that cap stays far
-- enough below it that the extras read as arriving rather than as queueing. If
-- the two ever become comparable, a bigger wave IS a bigger pile-up and the
-- two changes really are fighting each other.
check(WV.MaxCount >= WV.MaxChasers * 3,
	("MaxCount %d against MaxChasers %d: a bigger wave is meant to be more reinforcements, not more raiders hitting you at once")
		:format(WV.MaxCount, WV.MaxChasers))

-- CAN ANYONE STILL FINISH ONE? A wave that cannot be cleared inside MaxWaveTime
-- does not fail loudly — it times out, kills its own survivors, and pays
-- nothing for the ones you never reached. Model the damage a player actually
-- does: the bat's rate, plus crit, plus the average of the combo ladder (stacks
-- 0..ComboMaxStacks cycle, so the mean bonus is half the top one).
local function playerDps(bat)
	local perSwing = bat.damage * (1 + bat.crit * (Config.Combat.CritMultiplier - 1))
	local combo = 1 + Config.Combat.ComboDamagePerStack * Config.Combat.ComboMaxStacks / 2
	return perSwing * combo / bat.cooldown
end

local satCount = math.min(WV.BaseCount + (saturationWave - 1) * WV.CountPerWave, WV.MaxCount)
local satRaiderHealth = WV.BaseHealth * WV.HealthGrowth ^ (saturationWave - 1)
local satWaveHealth = satCount * satRaiderHealth
if saturationWave % WV.BossEvery == 0 then
	satWaveHealth += satRaiderHealth * WV.BossHealthMultiplier
end

local topBat = Config.Bats[#Config.Bats]
local startBat = Config.Bats[1]
local clearTop = satWaveHealth / playerDps(topBat)
local clearStart = satWaveHealth / playerDps(startBat)

-- Solo, with the best bat in the game, a full-size wave has to be finishable
-- with real room to spare. Without margin the endgame raid is a coin flip
-- against the deadlock breaker rather than a fight.
check(clearTop * 2 <= WV.MaxWaveTime,
	("a full wave is %.0f health and the top bat does %.0f/sec, so a solo clear takes %.0fs against a MaxWaveTime of %d — the deadline is meant to break deadlocks, not to end fights")
		:format(satWaveHealth, playerDps(topBat), clearTop, WV.MaxWaveTime))

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
--
-- MaxDropsPerPlot is a WHOLE-PLOT budget — spawnDrop's counter is per plot, not
-- per belt — so the cap is checked against the sum over every floor while the
-- occupancy check stays per-belt, which is where jamming actually happens. This
-- used to be one belt's arithmetic because there was only ever one belt whose
-- machines were in Config; the mezzanine's dropper spent the same budget and
-- was invisible here.
local DROP_LENGTH = 1.5   -- longest variant, standing upright
local groundId = Config.BeltPaths[1].id
local totalInFlight = 0
local beltLength, transit, inFlight = 0, 0, 0

for _, path in ipairs(Config.BeltPaths) do
	local pathRate = 0
	for _, def in ipairs(Config.Buttons) do
		if def.kind == "Dropper" and (def.path or groundId) == path.id then
			pathRate += 1 / def.dropRate
		end
	end

	local length = len(sub(path.collectorAt, path.points[#path.points]))
	for leg = 1, #path.points - 1 do
		length += len(sub(path.points[leg + 1], path.points[leg]))
	end
	local pathTransit = length / L.BeltSpeed
	local pathInFlight = pathRate * pathTransit
	totalInFlight += pathInFlight

	check(pathInFlight * DROP_LENGTH <= length * 0.75,
		("the %s belt would run at %.0f%% occupancy at peak — drops will jam into each other; raise Layout.BeltSpeed")
			:format(path.id, pathInFlight * DROP_LENGTH / length * 100))

	if path.id == groundId then
		beltLength, transit, inFlight = length, pathTransit, pathInFlight
	end
end

-- TRIGGER DWELL. Everything that happens to a drop happens in a Touched
-- handler on a volume it passes through — the upgrader that multiplies it, the
-- corner that turns it, the collector that pays it — and it is only seen if a
-- physics step lands inside the window it spends crossing that volume.
--
-- Roblox demotes an unattended assembly to 60 Hz and then to 30 Hz, and an
-- unattended plot is the COMMON case on a ten-player server: nine of the ten
-- people are standing somewhere else. So the window has to clear a 30 Hz step
-- with margin, not an ideal 240 Hz one.
--
-- This is the check that says the 1-stud scanner was already too thin at
-- shipped speeds, never mind faster ones.
local PHYSICS_STEP_DEMOTED = 1 / 30
local maxSpeedBonus = 0
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Belt" then
		maxSpeedBonus += def.speedBonus
	end
end
-- ...times whatever the generator grants, since it multiplies belt speed.
-- This is why the trigger fix had to land before the generator did: at the top
-- rung the 1-stud scanner would have been 13.5ms, under HALF a demoted step.
local maxBeltSpeed = (L.BeltSpeed + maxSpeedBonus) * Config.Tracks.power[#Config.Tracks.power].factor
local dwell = L.TriggerThickness / maxBeltSpeed
check(dwell >= PHYSICS_STEP_DEMOTED * 2,
	("a drop crosses a %.1f-stud trigger in %.0f ms at the top belt speed of %.0f studs/s; Roblox demotes an unattended assembly to 30 Hz (%.0f ms steps), so under two of those an upgrader can be tunnelled through and the drop pays out unrefined")
		:format(L.TriggerThickness, dwell * 1000, maxBeltSpeed, PHYSICS_STEP_DEMOTED * 1000))

-- THE COUPLING, which is the entire point of the generator.
--
-- inFlight is peakRate x length / speed. The generator multiplies peakRate (by
-- dividing every dropRate) and beltSpeed by the SAME factor, so the two cancel
-- and the number of drops on the belt is unchanged at every tier. Scale the
-- droppers alone and it is a straight multiplier on a plot already at 88% of
-- its cap, at which point spawnDrop starts silently eating the income you just
-- paid for.
--
-- Asserted per tier rather than once, so a rung that ever grants an asymmetric
-- pair is caught on the rung rather than at the top.
for _, def in ipairs(Config.Tracks.power) do
	local scaled = 0
	for _, path in ipairs(Config.BeltPaths) do
		local pathRate = 0
		for _, button in ipairs(Config.Buttons) do
			if button.kind == "Dropper" and (button.path or groundId) == path.id then
				-- rate goes UP by the factor: dropRate is divided by it
				pathRate += def.factor / button.dropRate
			end
		end
		local length = len(sub(path.collectorAt, path.points[#path.points]))
		for leg = 1, #path.points - 1 do
			length += len(sub(path.points[leg + 1], path.points[leg]))
		end
		-- ...and so does belt speed, by the same factor
		scaled += pathRate * (length / (L.BeltSpeed * def.factor))
	end
	check(math.abs(scaled - totalInFlight) < 0.01,
		("power tier %s puts %.0f drops in flight against %.0f ungoverned; the generator must multiply belt speed by exactly the factor it multiplies drop rate by, or the drop cap silently eats the income you just bought")
			:format(def.id, scaled, totalInFlight))
end

-- ...and the other end of the same rope: a dropper cannot be sped up past the
-- point where it floods physics, however much power you buy.
local topFactor = Config.Tracks.power[#Config.Tracks.power].factor
local fastest = math.huge
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Dropper" then
		fastest = math.min(fastest, def.dropRate / topFactor)
	end
end
check(fastest >= 0.2,
	("at %.2fx power the fastest dropper fires every %.2fs; under 0.2s it floods physics")
		:format(topFactor, fastest))

check(totalInFlight <= Config.Economy.MaxDropsPerPlot,
	("the plot carries %.0f drops at peak across %d belts but MaxDropsPerPlot is %d — the cap would silently eat income; raise BeltSpeed or thin a dropper")
		:format(totalInFlight, #Config.BeltPaths, Config.Economy.MaxDropsPerPlot))

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

-- ── the mezzanine, on the ground floor's terms ──────────────────────────────
--
-- None of this was checkable until now. FloorService built the deck's belt in
-- code, so the belt-path assertions never saw it; its teleport pads were never
-- in miscList, so nothing cross-checked them against the plot furniture; and
-- the roof already shrinks itself when the floor is on, which is the kind of
-- arrangement that breaks quietly when either side moves.

--- Gap between two axis-aligned boxes in plan, 0 if they overlap. The pads are
--- 9x9 against 5x5 pedestals, so the centre-distance rule miscList uses is the
--- wrong instrument for them: two boxes can be 14 studs apart centre to centre
--- and still interpenetrate.
local function boxBoxGap(aCentre, aSize, bCentre, bSize)
	local dx = math.max(math.abs(aCentre.X - bCentre.X) - (aSize.X + bSize.X) / 2, 0)
	local dz = math.max(math.abs(aCentre.Z - bCentre.Z) - (aSize.Z + bSize.Z) / 2, 0)
	return math.sqrt(dx * dx + dz * dz)
end

local PEDESTAL = Vector3.new(5, 1, 5)

for _, floor in ipairs(Config.Floors) do
	local where = "Floors." .. floor.id
	local deck, deckAt = floor.deckSize, floor.deckAt
	local deckHalfX, deckHalfZ = deck.X / 2, deck.Z / 2

	-- THE LADDER IS FLOOR FURNITURE. It stands on the plot floor exactly like a
	-- buy-button pedestal, and its predecessor was the one piece of floor
	-- furniture nothing checked: the ground teleport pad at (40, -14)
	-- interpenetrated the armour cabinet's slot-2 pedestal by three studs by
	-- one, latent only because the floor was behind a flag and invisible
	-- because the pads were never in this list.
	--
	-- The ladder's footprint is far smaller than the 9x9 pad's, which is most
	-- of why x = 14 works at all: it clears belt1's pedestal by 2.5 studs and
	-- the weapons cabinet by 3, and there was no clean 9x9 anywhere on that
	-- edge. Falsify by moving Floors.ladder.at.X to 10 and watching belt1 fire.
	local ladder = floor.ladder
	local ladderBox = Vector3.new(ladder.width, 1, ladder.width)
	for _, entry in ipairs(miscList) do
		local gap = boxBoxGap(ladder.at, ladderBox, entry.spot, PEDESTAL)
		check(gap >= 2,
			("%s's ladder comes within %.1f studs of %s (need 2)")
				:format(where, gap, entry.id))
	end
	for _, pad in ipairs({
		{ "RebirthPadAt", L.RebirthPadAt, Vector3.new(12, 1, 12) },
		{ "ClaimPadAt", L.ClaimPadAt, Vector3.new(14, 1, 14) },
	}) do
		local gap = boxBoxGap(ladder.at, ladderBox, pad[2], pad[3])
		check(gap >= 2,
			("%s's ladder comes within %.1f studs of %s (need 2)")
				:format(where, gap, pad[1]))
	end
	for _, track in pairs(L.Tracks) do
		local cabinetGap = boxBoxGap(ladder.at, ladderBox,
			Vector3.new(track.cabinetX, 0, track.firstZ + (track.slots - 1) * track.spacing / 2),
			Vector3.new(track.depth, 1, (track.slots - 1) * track.spacing + 8))
		check(cabinetGap >= 2,
			("%s's ladder comes within %.1f studs of a side-track cabinet (need 2)")
				:format(where, cabinetGap))
	end

	-- IN FRONT OF THE DECK, NOT UNDER IT. Coming up through the slab needs a
	-- hatch in the deck and a hole in the guard; standing clear of the front
	-- edge needs neither. A ladder that ends up inside the deck's footprint is
	-- a climb into the underside of a floor.
	check(ladder.at.Z > deckAt.Z + deckHalfZ,
		("%s's ladder is at z=%.1f, inside the deck's footprint (front edge is z=%.1f) — it would climb into the underside of the floor")
			:format(where, ladder.at.Z, deckAt.Z + deckHalfZ))
	check(ladder.at.Z - ladder.width / 2 <= deckAt.Z + deckHalfZ + 2,
		("%s's ladder is %.1f studs clear of the deck edge; you cannot step off it onto the floor it serves")
			:format(where, ladder.at.Z - ladder.width / 2 - (deckAt.Z + deckHalfZ)))

	-- ...AND THE GUARD HAS TO BE OPEN WHERE IT ARRIVES. buildDeck cuts the
	-- front run in two around ladder.at.X; if the gap were not over the ladder
	-- you would climb twenty-two studs into an invisible wall, which is the
	-- worst kind of geometry bug because there is nothing to see.
	check(math.abs(ladder.at.X - deckAt.X) + ladder.gate / 2 <= deckHalfX,
		("%s's railing gap runs past the end of the deck's front edge"):format(where))
	check(ladder.gate >= ladder.width + 2,
		("%s's railing gap is %.1f studs for a %.1f-stud ladder; you would arrive against the jamb")
			:format(where, ladder.gate, ladder.width))
	check(ladder.rise > 0,
		("%s's ladder stops level with the deck; it has to overshoot to step off")
			:format(where))

	-- THE DECK'S BELT STAYS ON THE DECK — legs, the machine row outboard of
	-- each leg, and the buy-button row inboard of it. This is the check that
	-- catches a belt margin too small for the machines that stand on it, which
	-- is what `side = 10` was: it needed 11.5 and overshot by a stud and a half.
	local path = Config.floorBeltPath(floor)
	local reach = L.MachineOffset + L.MachineFootprint / 2 + floor.rail.thickness
	for index, point in ipairs(path.points) do
		check(math.abs(point.X - deckAt.X) + reach <= deckHalfX,
			("%s belt corner %d is at x=%.1f; its machine row reaches %.1f studs past the deck rail")
				:format(where, index, point.X,
					math.abs(point.X - deckAt.X) + reach - deckHalfX))
		check(math.abs(point.Z - deckAt.Z) + reach <= deckHalfZ,
			("%s belt corner %d is at z=%.1f; its machine row reaches %.1f studs past the deck rail")
				:format(where, index, point.Z,
					math.abs(point.Z - deckAt.Z) + reach - deckHalfZ))
	end

	-- The hopper has to clear where you arrive, or you land on top of the
	-- collector. Measured against the LANDING — the point on the deck the
	-- ladder delivers you to — rather than against the ladder itself, which is
	-- outboard of the deck and would always be far away by construction.
	local landing = Vector3.new(ladder.at.X, 0, deckAt.Z + deckHalfZ)
	local hopperGap = len(sub(path.collectorAt, landing))
	check(hopperGap >= floor.belt.ladderClearance,
		("%s's collector is %.1f studs from where the ladder lands you (need %d)")
			:format(where, hopperGap, floor.belt.ladderClearance))

	-- THE DECK AGAINST THE PLOT IT SITS IN. Its back edge is flush to the wall
	-- and it clears the roof columns by less than a stud; both sides are now
	-- named numbers, so moving either one is a build failure rather than a
	-- thing somebody notices in Studio.
	local wallInner = halfZ - 1
	check(deckAt.Z - deckHalfZ >= -wallInner,
		("%s's back edge is at z=%.1f and the wall's inner face is at z=%.1f — the deck would grow through the wall")
			:format(where, deckAt.Z - deckHalfZ, -wallInner))
	local deckUnderside = floor.height - deck.Y
	check(deckUnderside >= L.RoofY,
		("%s's underside is at y=%.1f and the roof columns top out at y=%.1f — they interpenetrate")
			:format(where, deckUnderside, L.RoofY))
	-- ...and the shortened roof has to stop short of the deck, not meet it.
	local roofBack = deckAt.Z + deckHalfZ + 2
	check(roofBack > deckAt.Z + deckHalfZ,
		("%s: the shortened roof starts at z=%.1f, inside the deck"):format(where, roofBack))

	-- THE DECK'S PILLARS STAND ON THE GROUND FLOOR, among the machines. They
	-- miss the upgrader row today only because no UpgraderDist slot happens to
	-- land at z = -16, which is not a reason, it is a coincidence.
	local pillarX = deckHalfX - floor.pillar.insetSide
	local pillarZ = {
		deckAt.Z - deckHalfZ + floor.pillar.insetBack,
		deckAt.Z + deckHalfZ - floor.pillar.insetFront,
	}
	local pillarSize = Vector3.new(floor.pillar.size, 1, floor.pillar.size)
	for _, sx in ipairs({ -1, 1 }) do
		for _, pz in ipairs(pillarZ) do
			local at = Vector3.new(deckAt.X + sx * pillarX, 0, pz)

			-- leg 2 runs BeltCorner -> BeltEnd, i.e. along +Z from z = BeltCorner.Z,
			-- with the machines outboard at -X
			for slot, distance in ipairs(L.UpgraderDist) do
				local machine = Vector3.new(L.BeltCorner.X - L.MachineOffset, 0, L.BeltCorner.Z + distance)
				local gap = boxBoxGap(at, pillarSize, machine,
					Vector3.new(L.MachineFootprint, 1, L.MachineFootprint))
				check(gap >= 2,
					("%s's pillar at (%.0f, %.0f) is %.1f studs from upgrader slot %d's machine (need 2)")
						:format(where, at.X, at.Z, gap, slot))
			end

			for slot, distance in ipairs(L.DropperDist) do
				local machine = Vector3.new(L.BeltStart.X - distance, 0, L.BeltStart.Z - L.MachineOffset)
				local gap = boxBoxGap(at, pillarSize, machine,
					Vector3.new(L.MachineFootprint, 1, L.MachineFootprint))
				check(gap >= 2,
					("%s's pillar at (%.0f, %.0f) is %.1f studs from dropper slot %d's machine (need 2)")
						:format(where, at.X, at.Z, gap, slot))
			end
		end
	end
end

-- ── the generator yard ──────────────────────────────────────────────────────
--
-- The first thing this game builds OUTSIDE a plot, so it gets its own
-- containment rule rather than borrowing inPlot — which would reject it on
-- purpose. What it has to clear instead is the plot in front of it, the wall
-- between them, and the neighbours either side.

local Y = L.Yard
local yardHalfX, yardHalfZ = Y.Size.X / 2, Y.Size.Z / 2
local function inYard(label, point, margin)
	check(math.abs(point.X - Y.Centre.X) <= yardHalfX - (margin or 0),
		("%s sits at x=%.1f, off the yard slab (half-width %.1f, centred on %.1f)")
			:format(label, point.X, yardHalfX, Y.Centre.X))
	check(math.abs(point.Z - Y.Centre.Z) <= yardHalfZ - (margin or 0),
		("%s sits at z=%.1f, off the yard slab (half-depth %.1f, centred on %.1f)")
			:format(label, point.Z, yardHalfZ, Y.Centre.Z))
end

-- FOUR PEDESTALS SHARE ONE POSITION, and this is the check that keeps that
-- honest. Only the frontier rung is ever parented — refreshButtons hides the
-- rest — which is what lets one pad in front of the generator sell four rungs
-- in sequence. Preview depth is the only thing that can break it: at 2 the yard
-- grew three pads on a plot that owned none of them, and at 1 a dimmed pad
-- would be built INSIDE the lit one at the same coordinate.
--
-- It replaces `#Config.Tracks.power <= Y.Slots`, which counted rungs against a
-- capacity that no longer exists.
check(Config.TrackInfo.power.preview == 0,
	("TrackInfo.power.preview is %s; every power rung stands on one pedestal spot, so anything but 0 builds a preview pad inside the frontier pad")
		:format(tostring(Config.TrackInfo.power.preview)))

local yardMachine, yardButton = Config.yardMachinePosition(), Config.yardButtonPosition()
inYard("the generator", yardMachine, Y.MachineSize.X / 2)
inYard("the generator's pad", yardButton, 3)
check(yardMachine.X == Y.Centre.X and yardButton.X == Y.Centre.X,
	"the generator and its pad stand on the yard's centre line; anything else is a slot table growing back")
local buttonToMachine = math.abs(Y.ButtonZ - Y.MachineZ) - Y.MachineSize.Z / 2
check(buttonToMachine >= 3,
	("the yard's buy pad is %.1f studs clear of the generator (need 3)"):format(buttonToMachine))

-- BEHIND the plot, not on it. A yard that reaches onto the pad is a plot resize
-- wearing a disguise, and a plot resize moves every other plot in the game.
local yardFront = Y.Centre.Z + yardHalfZ
check(yardFront <= -halfZ + 1,
	("the yard's front face is at z=%.1f but the plot's back edge is at z=%.1f — a yard that reaches onto the pad is a plot resize wearing a disguise")
		:format(yardFront, -halfZ))
check(Y.Size.X <= Config.World.PlotSize.X,
	("the yard is %d studs wide against a %d-stud plot; anything wider re-solves the ring, which is the one thing growing backwards was meant to avoid")
		:format(Y.Size.X, Config.World.PlotSize.X))

-- ...AND WIDTH ALONE STOPPED BEING ENOUGH once the yard moved off-centre. A
-- 28-stud slab is comfortably narrower than the plot and can still hang over
-- its edge, which eats the ring gap the packing checks below solved for without
-- changing Size.X at all. The old yard was centred, so this could not happen
-- and was never asked.
local plotHalfWidth = Config.World.PlotSize.X / 2
check(Y.Centre.X + yardHalfX <= plotHalfWidth and Y.Centre.X - yardHalfX >= -plotHalfWidth,
	("the yard spans x %.0f..%.0f, past the %d-stud plot it hangs off the back of")
		:format(Y.Centre.X - yardHalfX, Y.Centre.X + yardHalfX, Config.World.PlotSize.X))

-- THE DOOR. The back edge of the plot is the dropper row, so there is exactly
-- one span of wall with nothing behind it.
local farthestDropper = L.BeltStart.X - L.DropperDist[1] + L.MachineFootprint / 2
check(Y.DoorFrom >= farthestDropper + 2,
	("the yard doorway starts at x=%.1f but dropper slot 1 stands out to x=%.1f — the door opens onto a machine")
		:format(Y.DoorFrom, farthestDropper))
local doorWidth = (Config.World.PlotSize.X / 2 - 1) - Y.DoorFrom
check(doorWidth >= 8,
	("the yard doorway is %.1f studs wide; a humanoid plus its hitbox needs 8"):format(doorWidth))
-- THE WHOLE DOORWAY HAS TO BE OVER THE SLAB, not just its left jamb. This
-- checked one point, which was enough while the yard was 108 studs wide and
-- spanned the plot — the door could not miss it. A 28-stud corner chunk can sit
-- entirely clear of the door it is supposed to be reached through, and you
-- would walk out of the back wall onto grass.
local doorTo = Config.World.PlotSize.X / 2 - 1
check(Y.Centre.X - yardHalfX <= Y.DoorFrom and Y.Centre.X + yardHalfX >= doorTo,
	("the doorway spans x %.0f..%.0f but the yard slab spans %.0f..%.0f; you would step out of the back wall onto grass")
		:format(Y.DoorFrom, doorTo, Y.Centre.X - yardHalfX, Y.Centre.X + yardHalfX))

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

	-- THE YARD EXTENDS EVERY ONE OF THESE. It hangs off the back of each plot,
	-- so it pushes the outermost thing in the world further out, brings
	-- neighbours closer at their corners, and lengthens the walk. Checked over
	-- the supported range rather than at the configured count, because the ring
	-- is clamped to MinPlotRadius at low counts and only grows past it later —
	-- the tightest case is not this server's.
	local yardBack = Config.World.PlotSize.Z / 2 - (L.Yard.Centre.Z - L.Yard.Size.Z / 2)
	local yardFarthest = 0
	for _, a in ipairs(placements) do
		yardFarthest = math.max(yardFarthest, a.radius + yardBack)
	end
	check(yardFarthest * 2 < Config.World.BaseplateSize,
		("%d plots put the furthest generator yard %.0f studs out, past the %d-stud ground plane")
			:format(count, yardFarthest, Config.World.BaseplateSize))
	check(yardFarthest - Config.World.ArenaRadius <= MAX_WALK,
		("%d plots put the furthest generator yard %.0f studs from the arena rim (limit %d)")
			:format(count, yardFarthest - Config.World.ArenaRadius, MAX_WALK))
	for i, a in ipairs(placements) do
		for j = i + 1, #placements do
			local b = placements[j]
			if a.ring == b.ring then
				local yardRadius = a.radius + yardBack
				local corner = math.sqrt(2 * yardRadius * yardRadius * (1 - math.cos(a.angle - b.angle)))
				check(corner >= L.Yard.Size.X,
					("%d plots: plot %d's generator yard comes within %.0f studs of plot %d's (need %d)")
						:format(count, i, corner, j, L.Yard.Size.X))
			end
		end
	end
	-- ...and a leashed raider must not reach it. The yard sits FURTHER from the
	-- arena than the plot does, so this is slack today — which is exactly why it
	-- wants asserting: a yard that ever moves forward walks into range with
	-- nothing saying so.
	local yardNearest = placements[1].radius + Config.World.PlotSize.Z / 2 - 1
	check(yardNearest > raiderReach,
		("%d plots: the generator yard's nearest point is %.0f studs from the arena centre but a leashed raider reaches %.0f")
			:format(count, yardNearest, raiderReach))

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

-- THE BUY BUTTON'S TWO VOICES.
--
-- The locked state has to be quieter than the buyable one on every axis it
-- moves, not just on the one somebody remembered. These are cheap and they are
-- the difference between "the locked pads recede" and "the locked pads recede
-- except for their outline, which somebody bumped".
local BTN, LOCKED = ST.Button, ST.ButtonLocked
check(LOCKED.scale > 0 and LOCKED.scale < 1,
	("Style.ButtonLocked.scale is %.2f; a locked label must be SMALLER than a buyable one"):format(LOCKED.scale))
check(LOCKED.panelAlpha > BTN.panelAlpha,
	("locked panels are %.2f transparent against %.2f for buyable ones — the locked pads are meant to be the wall the buyable one stands out from")
		:format(LOCKED.panelAlpha, BTN.panelAlpha))
check(LOCKED.strokeThickness < BTN.strokeThickness,
	("locked outlines are %.1f thick against %.1f for buyable ones; thinner is the whole idea")
		:format(LOCKED.strokeThickness, BTN.strokeThickness))
check(LOCKED.textAlpha > 0 and LOCKED.textAlpha < 1,
	("Style.ButtonLocked.textAlpha is %.2f; 0 is not faded at all and 1 is invisible"):format(LOCKED.textAlpha))
check(ST.Distance[LOCKED.distance] <= ST.Distance[BTN.distance],
	("locked labels draw to %.0f studs against %.0f for buyable ones; a locked pad should give up FIRST")
		:format(ST.Distance[LOCKED.distance], ST.Distance[BTN.distance]))

-- THE ONE THAT MAKES TURNING OFF AlwaysOnTop SAFE.
--
-- The buy-button label used to draw through everything, which hid the fact that
-- it sat low enough for the dropper beside it to eat its lower half. With the
-- x-ray gone the label has to clear the machinery by standing above it — so
-- assert the bottom edge of the billboard against the top of the tallest
-- machine, with a stud of daylight. Hiding behind a wall is correct; hiding
-- behind a machine two feet away is the bug this replaced.
local labelBottom = BTN.lift - BTN.height / 2
check(labelBottom >= L.MachineTopY + 0.5,
	("the buy-button label's bottom edge is at y=%.1f and the tallest machine tops out at y=%.1f — the dropper next to a button would cover its label, which is what AlwaysOnTop used to hide")
		:format(labelBottom, L.MachineTopY))
-- ...and the locked one is smaller, so its bottom edge is HIGHER. Assert it
-- anyway: the day somebody makes the locked state bigger instead of smaller,
-- this is the check that explains why that is not just a taste decision.
check(BTN.lift - (BTN.height * LOCKED.scale) / 2 >= L.MachineTopY + 0.5,
	("a locked buy-button label's bottom edge is at y=%.1f against machines at y=%.1f")
		:format(BTN.lift - (BTN.height * LOCKED.scale) / 2, L.MachineTopY))
-- A label you have to crane at is its own problem. The plot's roof sits at 20.
check(BTN.lift + BTN.height / 2 <= 20,
	("the buy-button label's top edge is at y=%.1f, which is through the roof at y=20")
		:format(BTN.lift + BTN.height / 2))

-- THE TWO SIGNS OVER THE ARENA STATUE. The raid line takes the head height and
-- the game's own name sits above it; the failure this guards is the two of them
-- ending up on top of each other, which is exactly what the title was doing to
-- the statue before it moved.
check(ST.RaidSignY > Config.World.ArenaWallHeight,
	("the raid sign is at y=%.0f and the arena wall is %d tall — the sign has to clear it or half the arena cannot read it")
		:format(ST.RaidSignY, Config.World.ArenaWallHeight))
local raidTop = ST.RaidSignY + ST.RaidSignHeight / 2
local titleBottom = ST.ArenaTitleY - ST.ArenaTitleHeight / 2
check(titleBottom >= raidTop,
	("the arena title's bottom edge is at y=%.0f and the raid sign's top edge is at y=%.0f — they would overlap over the statue")
		:format(titleBottom, raidTop))

-- ...and the raid sign has to be readable from every plot, because that is the
-- reason it stands over the statue rather than on your screen. Measured from
-- the arena centre to the far edge of the furthest plot, over the supported
-- player range.
for count = Config.World.MinPlots, Config.World.MaxPlots do
	local placements = Config.plotPlacements(count)
	local farthest = 0
	for _, p in ipairs(placements) do
		farthest = math.max(farthest, p.radius + Config.World.PlotSize.Z / 2)
	end
	check(ST.Distance.world >= farthest,
		("the raid sign draws to %.0f studs but at %d plots the far edge of a plot is %.0f studs from the arena centre; the raid would be invisible from the plots it is warning")
			:format(ST.Distance.world, count, farthest))
end

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

-- ── screen ui ───────────────────────────────────────────────────────────────
--
-- Four out of five sessions are on a phone. Everything below is a relationship
-- between two numbers that used to live in two different files in src/client,
-- which is the one directory this harness cannot see — so none of it had an
-- owner, and the way you found out was by opening the game on a phone.
--
-- The scaling contract these all lean on: the client mounts one UIScale of
-- clamp(min(vx/ReferenceWidth, vy/ReferenceHeight), MinScale, MaxScale), so the
-- canvas the layout is measured in is at least ReferenceWidth x ReferenceHeight
-- design pixels except where MinScale clamps, and the physical size of anything
-- is its design size times a scale of at worst MinScale.

local UI = Config.UI

check(UI.MinScale > 0 and UI.MinScale <= UI.MaxScale,
	("UI.MinScale is %.2f and MaxScale is %.2f; a floor above the ceiling is not a clamp")
		:format(UI.MinScale, UI.MaxScale))
check(UI.MaxScale <= 1,
	("UI.MaxScale is %.2f; scaling the HUD UP to fill a 4K monitor is not wanted"):format(UI.MaxScale))
check(UI.MinScale >= 0.5,
	("UI.MinScale is %.2f — below half size the HUD stops being legible before it stops fitting")
		:format(UI.MinScale))
check(UI.ReferenceWidth > UI.ReferenceHeight,
	"the reference frame has to be landscape; the HUD is a left column, a right column and the game in between")

-- THE TWO FLOORS, IN PHYSICAL PIXELS. A design-pixel minimum means nothing on
-- its own: it is worth MinScale of itself on the smallest screen that still
-- gets a full-size layout, and that is the number a thumb and an eye actually
-- meet. 26px is roughly where a tap target stops being reliable; 8px is roughly
-- where small print stops being readable at arm's length.
check(UI.MinTouchPx * UI.MinScale >= 26,
	("the smallest touch target is %.0f design px, which is %.0f physical px at MinScale — under the ~26 px a thumb can hit")
		:format(UI.MinTouchPx, UI.MinTouchPx * UI.MinScale))
check(UI.MinTextPx * UI.MinScale >= 8,
	("the smallest text is %.0f design px, which is %.1f physical px at MinScale — small print nobody can read is decoration")
		:format(UI.MinTextPx, UI.MinTextPx * UI.MinScale))

-- Every button height in the game comes from UI.Button, so asserting the
-- smallest of the three asserts all of them.
check(UI.Button.pill >= UI.MinTouchPx,
	("UI.Button.pill is %d and the touch floor is %d; the pill is the SMALLEST button the game draws, so it is the one that decides")
		:format(UI.Button.pill, UI.MinTouchPx))
check(UI.Button.secondary >= UI.Button.pill and UI.Button.primary >= UI.Button.secondary,
	("the button ladder is primary %d, secondary %d, pill %d — it has to be ordered or the names mean nothing")
		:format(UI.Button.primary, UI.Button.secondary, UI.Button.pill))
check(UI.Action.Height >= UI.Button.primary + UI.Gap + UI.Button.secondary,
	("the bottom-right action stack is %d tall but holds a %d button, a %d gap and a %d button")
		:format(UI.Action.Height, UI.Button.primary, UI.Gap, UI.Button.secondary))
-- The shop rows are one big TextButton each, which is the whole point of them.
check(UI.ShopPanel.RowHeight >= UI.MinTouchPx,
	("an upgrade row is %d design px tall against a touch floor of %d"):format(UI.ShopPanel.RowHeight, UI.MinTouchPx))

-- THE TOP-LEFT COLUMN AND THE UPGRADE SHOP.
--
-- This is the check that had no owner. HUD.lua stacks cash, next-up and (via
-- SessionUI) the session panel down the left edge; UpgradeUI.lua hangs the shop
-- off the BOTTOM edge with a proportional height, so on a short screen the shop
-- grows upwards into the column. It overlapped the NEXT UPGRADE panel below 638
-- design px, and with the utility chip on it overlapped at the reference height
-- itself. Neither file could see it: each held one of the two edges.
--
-- Two axes, because either one separates them. Vertical clearance is the fit
-- the layout would need if the shop stayed in the column; horizontal clearance
-- is what it does instead, and is the stronger property — it holds at EVERY
-- viewport height rather than at heights above some threshold.
local column = { UI.CashPanel, UI.NextPanel, UI.SessionPanel }
for index, entry in ipairs(column) do
	check(entry.Width == UI.ColumnWidth,
		("panel %d of the left column is %d wide but the column is %d; a column of three widths is three panels")
			:format(index, entry.Width, UI.ColumnWidth))
end
check(UI.SessionPanel.TallHeight >= UI.SessionPanel.Height
		and UI.SessionPanel.Height >= UI.SessionPanel.CompactHeight,
	"the session panel's three heights are out of order")
check(UI.ColumnBottom + UI.Margin <= UI.ReferenceHeight,
	("the left column ends at y=%d, past the bottom of a %d-tall reference screen")
		:format(UI.ColumnBottom, UI.ReferenceHeight))

-- Asserted BEFORE the clamp below, and the clamp is spelled out with min/max
-- rather than math.clamp, which ERRORS when its floor is above its ceiling. A
-- bad pair of numbers here should cost one failed check with a sentence on it,
-- not take all of these down at once with a stack trace about math.clamp.
check(UI.ShopPanel.MinHeight <= UI.ShopPanel.MaxHeight,
	("the shop panel's size constraint runs %d..%d; the floor is above the ceiling")
		:format(UI.ShopPanel.MinHeight, UI.ShopPanel.MaxHeight))

local shopHeight = math.min(
	math.max(UI.ShopPanel.HeightScale * UI.ReferenceHeight, UI.ShopPanel.MinHeight),
	math.max(UI.ShopPanel.MaxHeight, UI.ShopPanel.MinHeight))
local shopTop = UI.ReferenceHeight - UI.ShopPanel.BottomGap - shopHeight
local clearsAbove = shopTop >= UI.ColumnBottom + UI.Gap
local clearsBeside = UI.ShopPanel.X >= UI.Margin + UI.ColumnWidth + UI.Gap
check(clearsAbove or clearsBeside,
	("the upgrade shop starts at y=%.0f, x=%d and the top-left column runs to y=%d, x=%d — at the %dx%d reference they overlap, and every viewport shorter than that is worse")
		:format(shopTop, UI.ShopPanel.X, UI.ColumnBottom, UI.Margin + UI.ColumnWidth,
			UI.ReferenceWidth, UI.ReferenceHeight))
check(UI.ShopPanel.MinHeight >= UI.ShopPanel.RowHeight * 2,
	("the shop can shrink to %d design px, which is less than two %d-px rows and a header — a list you cannot see two of is a menu")
		:format(UI.ShopPanel.MinHeight, UI.ShopPanel.RowHeight))
-- ...and it must not run into the bottom-right action stack on the way across.
check(UI.ShopPanel.X + UI.ShopPanel.Width <= UI.ReferenceWidth - UI.Margin - UI.Action.Width - UI.Gap,
	("the shop's right edge is at x=%d and the rebirth stack starts at x=%d")
		:format(UI.ShopPanel.X + UI.ShopPanel.Width, UI.ReferenceWidth - UI.Margin - UI.Action.Width))
-- The toast column comes in from the other side and has to clear it too.
check(UI.ShopPanel.X + UI.ShopPanel.Width <= UI.ReferenceWidth - UI.Margin - UI.Toast.Width - UI.Gap,
	("the shop's right edge is at x=%d and the toast column starts at x=%d")
		:format(UI.ShopPanel.X + UI.ShopPanel.Width, UI.ReferenceWidth - UI.Margin - UI.Toast.Width))

-- MODALS FIT THE REFERENCE FRAME. They are centred and unscaled relative to the
-- design canvas, so a card wider than the canvas is a card with its buttons off
-- both sides of the screen — on every device, not just a phone.
for name, card in pairs(UI.Modal) do
	if type(card) == "table" then
		check(card.Width >= UI.Modal.MinWidth,
			("the %s modal is %d wide, under the %d a two-button row needs")
				:format(name, card.Width, UI.Modal.MinWidth))
		check(card.Width <= UI.Modal.MaxWidth and card.Height <= UI.Modal.MaxHeight,
			("the %s modal is %dx%d, over the %dx%d ceiling")
				:format(name, card.Width, card.Height, UI.Modal.MaxWidth, UI.Modal.MaxHeight))
		check(card.Width + 2 * UI.Margin <= UI.ReferenceWidth
				and card.Height + 2 * UI.Margin <= UI.ReferenceHeight,
			("the %s modal is %dx%d, which does not fit a %dx%d reference frame with margins")
				:format(name, card.Width, card.Height, UI.ReferenceWidth, UI.ReferenceHeight))
	end
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
--
-- BY NAME, NOT BY VALUE, and that is a bug fix rather than a style change.
-- This was a map literal containing `PathTopY = Config.World.PathTopY` — a key
-- that does not exist anywhere in Config. The value was nil, so the entry was
-- simply absent from the table and pairs() never visited it: the check silently
-- covered three surfaces while appearing to cover four, and its `type(y) ==
-- "number"` guard could never fire because a nil never arrived.
--
-- YardTopY was missing from the list at the same time. #32 said the yard got
-- "its own surface height, so the existing distinct-heights check picks it up";
-- it did not, and has not since. Iterating names makes a missing key fail
-- loudly instead of vanishing.
local surfaceNames = { "GroundTopY", "ArenaFloorTopY", "YardTopY", "PlotSurfaceY" }
local seenHeights = {}
for _, name in ipairs(surfaceNames) do
	local y = Config.World[name]
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

-- THE SPINE, which is now two interleaved ladders.
--
-- The factory is the thing that generates income and therefore the thing whose
-- "45 to 150 minutes" pacing is about. The generator belongs in here with it
-- rather than in the side-track model below, because that model prices a track
-- against a curve it does not change — true of a bat, false of anything that
-- multiplies production. A power rung bought at minute 12 moves every row after
-- it.
--
-- The policy is BUY WHICHEVER OF THE TWO NEXT RUNGS IS CHEAPER. Deterministic,
-- one line, and it makes the price the control: put a rung between dropper6 and
-- roof and the sim buys it exactly there, visibly, in the printed curve. A
-- payback heuristic would model a player nobody is.
local power = 1
local factoryIndex, powerIndex = 1, 1
local factoryTrack, powerTrack = Config.Tracks.factory, Config.Tracks.power

while factoryIndex <= #factoryTrack or powerIndex <= #powerTrack do
	local nextFactory, nextPower = factoryTrack[factoryIndex], powerTrack[powerIndex]
	local takePower = nextPower ~= nil and (nextFactory == nil or nextPower.price <= nextFactory.price)
	local def = takePower and nextPower or nextFactory

	local income = rawDps * upgradeMult * power
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
	local previousPower = power
	if takePower then
		power = def.factor
		powerIndex += 1
	else
		if def.kind == "Dropper" then rawDps += def.dropValue / def.dropRate end
		if def.kind == "Upgrader" then upgradeMult *= def.multiplier end
		factoryIndex += 1
	end

	-- `earned` is everything the plot has produced by this point, ignoring what
	-- was spent. It is the budget a side-track purchase competes for.
	table.insert(curve, {
		id = def.id, wait = wait, at = elapsed,
		income = rawDps * upgradeMult * power,
		earned = (curve[#curve] and curve[#curve].earned or 0) + (wait ~= math.huge and wait or 0) * income,
		isPower = takePower, price = def.price,
		previousPower = previousPower, power = power,
	})
end

local endgameIncome = rawDps * upgradeMult * power
check(elapsed / 60 >= MIN_TOTAL_MINUTES,
	("full build takes only %.0f min (want >= %d) — the game is over too fast"):format(elapsed / 60, MIN_TOTAL_MINUTES))
check(elapsed / 60 <= MAX_TOTAL_MINUTES,
	("full build takes %.0f min (want <= %d) — too grindy"):format(elapsed / 60, MAX_TOTAL_MINUTES))

-- ── the sixty-minute credit cap ─────────────────────────────────────────────
--
-- Roblox's `7 Day Playtime Per User` signal counts "a maximum of 60 minutes per
-- user, per experience, per day". Everything past minute sixty of one sitting
-- is work the ranking system cannot see. When this file was written the build
-- was 88 minutes, which meant the last three purchases — a third of the ladder
-- — were worth exactly zero to discovery.
--
-- TWO CHECKS, NOT ONE, and deliberately so. MAX_BUILD_MINUTES is an opinion
-- someone may legitimately want to widen; CREDIT_CAP_MINUTES is a platform fact
-- that has to keep refusing when they do.
local CREDIT_CAP_MINUTES = 60
local buildMinutes = elapsed / 60

check(buildMinutes <= CREDIT_CAP_MINUTES,
	("the full build takes %.0f min, but Roblox credits a maximum of %d minutes per user " ..
		"per experience per day — the last %.0f minutes of the ladder are work the ranking " ..
		"signal cannot see"):format(buildMinutes, CREDIT_CAP_MINUTES, buildMinutes - CREDIT_CAP_MINUTES))

-- ── when the rebirth pad actually lights up ─────────────────────────────────
--
-- REPLACES `BaseCost / endgameIncome`, which asked how many minutes of FULLY
-- BUILT income the pad costs. That is a reasonable-sounding question and it is
-- the wrong one: a pad priced at a perfectly sensible 10 minutes of endgame
-- income lands at minute 77 of a 67-minute build, and the old check passed
-- while nobody ever saw a rebirth. It measured the price and called it pacing.
--
-- This walks the curve instead, over every point where a player might stop
-- buying and start saving, and takes the earliest wall-clock minute the pad
-- could be pressed. Cash is ~0 after each purchase, so the money for the pad
-- has to be earned from that point at that point's income.
local MIN_FIRST_REBIRTH_MINUTES = 25
local MAX_FIRST_REBIRTH_MINUTES = 50
local MIN_REBIRTH_LEFTOVER = 2

local rebirthAt, rebirthStop, rebirthStopIndex = math.huge, nil, 0
for index, row in ipairs(curve) do
	if row.income > 0 then
		local minute = row.at / 60 + Config.Rebirth.BaseCost / row.income / 60
		if minute < rebirthAt then
			rebirthAt, rebirthStop, rebirthStopIndex = minute, row.id, index
		end
	end
end

check(rebirthAt <= MAX_FIRST_REBIRTH_MINUTES,
	("the first rebirth is not affordable until minute %.0f (want <= %d) — rebirth is what " ..
		"makes this game repeatable, and past the credit cap almost nobody will ever see one")
		:format(rebirthAt, MAX_FIRST_REBIRTH_MINUTES))
check(rebirthAt >= MIN_FIRST_REBIRTH_MINUTES,
	("the first rebirth is affordable at minute %.0f (want >= %d) — there is no factory to " ..
		"have prestiged out of yet, so the multiplier is paying for nothing")
		:format(rebirthAt, MIN_FIRST_REBIRTH_MINUTES))

-- SOMETHING OBVIOUSLY WAITING. The brief asks for "one satisfying run that
-- finishes in about 50 minutes, and then something obviously waiting that they
-- can't get to tonight. End on wanting more, not on being done."
--
-- This is that sentence as a property of the config rather than as a hope. It
-- has margin rather than sitting on a knife edge, because PriceRung = 4 makes a
-- leftover of 3 structural.
local rebirthLeftover = #curve - rebirthStopIndex
check(rebirthLeftover >= MIN_REBIRTH_LEFTOVER,
	("the first rebirth is affordable at minute %.0f with only %d spine rung(s) unbought " ..
		"(want >= %d) — the session ends on being finished rather than on a choice")
		:format(rebirthAt, rebirthLeftover, MIN_REBIRTH_LEFTOVER))

-- The pad must not be a mid-game button. If it costs less than the eighth most
-- expensive thing on the spine it stops being a fork and becomes a rung.
local spinePrices = Config.spinePricesDescending()
check(Config.Rebirth.BaseCost >= (spinePrices[8] or 0),
	("the rebirth pad costs %.3g, less than the eighth-most-expensive spine rung (%.3g) — " ..
		"at that price it is a purchase on the ladder rather than the choice that ends the run")
		:format(Config.Rebirth.BaseCost, spinePrices[8] or 0))

-- WHAT EACH GENERATOR RUNG ACTUALLY EARNS YOU BEFORE THE BUILD ENDS.
--
-- Vacuous on the early rungs by construction — the curve is exponential, so a
-- rung bought at minute twelve returns tens of thousands of times its price and
-- no threshold could fail. It bites on the LAST rung, which is exactly where a
-- generator stops being an upgrade and becomes a trophy you buy after it can
-- pay for itself.
local POWER_MIN_RETURN = 2.0
for index, row in ipairs(curve) do
	if row.isPower then
		local share = 1 - row.previousPower / row.power
		local returned = 0
		for j = index + 1, #curve do
			returned += curve[j].wait * curve[j - 1].income * share
		end
		check(returned >= row.price * POWER_MIN_RETURN,
			("%s costs %.3g but only earns %.3g extra before the build ends (%.1fx, need %.1fx) — the top rung is a trophy, not an upgrade")
				:format(row.id, row.price, returned, returned / row.price, POWER_MIN_RETURN))
	end
end

-- ── where the second floor lands ────────────────────────────────────────────
--
-- This replaces `unlock.trackOrder >= #Config.Tracks.factory - 1`, which said
-- "at the end" in the only vocabulary it had: an index. Halfway is not a
-- position in a list, it is a fraction of the minutes the list takes, so the
-- check has to live down here where the curve exists.
local function curveRow(id: string)
	for _, row in ipairs(curve) do
		if row.id == id then
			return row
		end
	end
	return nil
end

-- buildMinutes is declared with the credit-cap check above, where it is first
-- needed; the floor's own checks read the same one.
local floorReport = nil
for _, floor in ipairs(Config.Floors) do
	local row = curveRow(floor.button)
	if row then
		local at = row.at / 60
		local fraction = at / buildMinutes
		-- WHERE THE FLOOR LANDS, now that it is early expansion space.
		--
		-- This replaces `fraction >= 0.35 and fraction <= 0.65`, which said
		-- "the floor is the halfway prize". That premise is deliberately
		-- overturned. The floor is what the walls make room for, it is bought
		-- with the walls' money, and — the deciding fact — it is the gate on
		-- BOTH side-track cabinets. Parking it at the halfway mark parked the
		-- weapons and armour ladders there too, which is GROWTH-TODO item 1's
		-- complaint about the back third of the build in its purest form: a
		-- forty-minute button standing in front of nine other buttons.
		--
		-- What is still true, still falsifiable, and is now the actual defect
		-- to guard against, is EARLY BUT NOT FIRST.
		--
		-- Not first is the sharper half. A deck bought before the ground line
		-- works is a bill for empty scenery, and it invites an opener a new
		-- player can strand themselves on — the same defect the "side tracks
		-- must not be affordable at spawn" check above exists for, one track
		-- over. Anchoring to `walls` names the purchase it must follow instead
		-- of guessing at a percentage that happens to sit after it today.
		local wallsRow = curveRow("walls")
		check(wallsRow ~= nil and row.at > wallsRow.at,
			("Floors.%s is bought at minute %.1f, at or before the walls at minute %.1f — the deck is the expansion the walls enclose, and a floor you can buy before the plot is enclosed is scenery you are billed for")
				:format(floor.id, at, wallsRow and wallsRow.at / 60 or -1))
		check(fraction >= 0.06,
			("Floors.%s opens at %.0f%% of the build — that is inside the opening minutes, before the ground floor is a line worth extending")
				:format(floor.id, fraction * 100))
		check(fraction <= 0.20,
			("Floors.%s opens at %.0f%% of the build; past a fifth in it slides back toward being the mid-build wall it used to be, and it drags both cabinets it gates along with it")
				:format(floor.id, fraction * 100))
		-- Roblox credits the first 60 minutes of a session and nothing after.
		-- `at <= 50` was the version of this rule that only had to cover the
		-- floor itself. The floor gates the weapons and armour tracks now, so
		-- this is the deadline for THREE ladders, and the question stopped
		-- being "inside the session" and became "with a session left after it".
		check(at <= 10,
			("Floors.%s opens %.0f minutes in; it gates both cabinets, so past ~10 the side tracks have no session left to be climbed in")
				:format(floor.id, at))

		-- HOW MUCH THE FLOOR IS WORTH THE MINUTE YOU BUY IT. The upstairs
		-- machines are refined by the plot's upgrade stack (see
		-- Tycoon:refineryMultiplierFor), so this share is a constant for the
		-- rest of the build rather than something that decays — which is the
		-- entire reason for that decision, and the reason to keep measuring it.
		local floorDps, groundDps = 0, 0
		for _, def in ipairs(Config.Tracks.factory) do
			if def.kind == "Dropper" then
				local defRow = curveRow(def.id)
				if defRow and defRow.at <= row.at + 1e-9 then
					groundDps += def.dropValue / def.dropRate
				end
			end
		end
		for _, def in ipairs(Config.Tracks.factory) do
			if def.kind == "Dropper" and def.path == floor.id then
				floorDps += def.dropValue / def.dropRate
			end
		end
		local share = floorDps / (groundDps + floorDps)
		floorReport = ("floor %s:        opens at %.0f min (%.0f%% of build), worth %.0f%% of income")
			:format(floor.id, at, fraction * 100, share * 100)
		-- THE BAND MOVED WITH THE FLOOR, because the denominator did. This is
		-- measured against the droppers owned AT THE MOMENT OF PURCHASE, and at
		-- minute six that is three of them rather than the seven a minute-forty
		-- floor stood on. Holding 10-30% here would force the upstairs machine
		-- below dropper2 — which is the "floor is scenery" defect the lower
		-- bound exists to catch, arrived at by way of the lower bound itself.
		--
		-- A third is the shape being asserted: the first upstairs machine is a
		-- PEER of the ground floor's newest dropper, not a replacement for the
		-- ground floor and not a decoration on top of it. Split into two checks
		-- so each failure names the defect it is about.
		check(share >= 0.25,
			("Floors.%s's own machines are %.0f%% of plot income the minute you buy it (want 25-45%%) — below that the deck is a viewing platform and its dropper is a decoration")
				:format(floor.id, share * 100))
		check(share <= 0.45,
			("Floors.%s's own machines are %.0f%% of plot income the minute you buy it (want 25-45%%) — above that the ground slots you have not filled yet stop being what you are playing for")
				:format(floor.id, share * 100))
	end
end

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

--- The minute a track's cabinet actually appears. Ungated tracks open at zero;
--- a gated one opens when its gate button is bought.
---
--- This is what "affordable by minute 10" had to become. The rule was written
--- when the cabinets stood on the plot from the moment you claimed it, so
--- minute 10 of the BUILD and minute 10 of the cabinet's existence were the
--- same number. With the cabinets behind a forty-minute button they are not,
--- and the old form is false by construction rather than by any fault of the
--- prices.
local function trackOpensAt(track: string): number
	local gate = Config.TrackUnlock[track]
	if not gate then
		return 0
	end
	local row = curveRow(gate)
	return row and row.at / 60 or math.huge
end

local sideTotal = 0
for _, track in ipairs(Config.TrackOrder) do
	-- "side" rather than "not factory". A track that MULTIPLIES income cannot
	-- be priced as a detour from the spine — the detour model assumes buying
	-- one does not change the curve it is measured against, and a generator
	-- rung changes every row after it. Power is walked in the spine instead.
	if Config.TrackInfo[track].paced == "side" then
		local opensAt = trackOpensAt(track)
		check(opensAt ~= math.huge,
			("the %s track is gated on %q, which the factory never buys")
				:format(track, tostring(Config.TrackUnlock[track])))

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

		-- ...and the cabinet must not be scenery once it is standing there.
		-- Measured from when the track OPENS, not from the start of the build.
		local first = Config.Tracks[track][1]
		if first and opensAt ~= math.huge then
			local at = firstAffordable(first.price)
			local afterOpen = math.max(0, at - opensAt)
			check(afterOpen <= FIRST_SIDE_RUNG_BY_MINUTE,
				("the first %s rung is unaffordable until %.0f minutes after its cabinet opens; until then the cabinet is scenery")
					:format(track, afterOpen))
		end
	end
end

-- HOW FAST A CABINET EMPTIES ONCE IT OPENS, and it is an assertion now.
--
-- Gating a track behind a forty-minute button inverted its old risk. It could
-- no longer be scenery you stare at for half an hour; it arrived instead with
-- almost every rung already affordable, which makes a ladder into a vending
-- machine — you empty it in one pass and five tiers were one purchase.
--
-- The comment that stood here said this "becomes an assertion in the round that
-- retunes the curve", and left it printed because landing it then would have
-- forced that retune through the back door. THIS IS THAT ROUND. It went from
-- 4 of 5 weapon rungs and 4 of 4 armour rungs to 1 of 5 and 0 of 4 without a
-- cabinet price moving, purely because the gate button moved from minute 41 to
-- minute 6 — so keeping it printed would now be the back-door move in the other
-- direction.
local VENDING_MACHINE_RUNGS = 2
for _, track in ipairs(Config.TrackOrder) do
	local gate = Config.TrackUnlock[track]
	if gate then
		local opensAt = trackOpensAt(track)
		local ready = 0
		for _, def in ipairs(Config.Tracks[track]) do
			local at = firstAffordable(def.price)
			if at <= opensAt + 5 then
				ready += 1
			end
		end
		print(("%s cabinet:%s opens at %.0f min with %d of %d rungs already affordable")
			:format(track, (" "):rep(math.max(1, 12 - #track)), opensAt, ready, #Config.Tracks[track]))
		check(ready <= VENDING_MACHINE_RUNGS,
			("the %s cabinet opens at minute %.0f with %d of %d rungs already affordable; a ladder you can empty in one pass is a vending machine, not a track")
				:format(track, opensAt, ready, #Config.Tracks[track]))
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
-- TIGHTENED from (1, 2). That band was wide enough to admit both a ladder that
-- is over in an afternoon and one whose top half nobody will ever see, which is
-- most of the range it was supposed to be ruling out. Now that the pad is priced
-- as a rung rather than as a constant, this is the number that decides whether
-- MaxRebirths = 25 means anything.
local costRatio = Config.Rebirth.CostGrowth / Config.Rebirth.MultiplierPerRebirth
check(costRatio >= 1.2 and costRatio <= 1.7,
	("each rebirth takes %.2fx as long as the last; want 1.2-1.7. Under 1.2 the whole " ..
		"25-rung ladder is an afternoon; over 1.7 the top of it is a number nobody will see")
		:format(costRatio))

-- ── persistence and the session lock ────────────────────────────────────────
-- DataService's lock lives INSIDE the profile record, so the check and the
-- write are one UpdateAsync and no timing can produce two simultaneous writers
-- by itself. What timing CAN do is produce a server that gives up too early, or
-- one that declares a live lock dead. These three are those two failures, in
-- both directions, and they are the only reason these numbers are in Config at
-- all rather than being literals in a file the verifier cannot see.
local PS = Config.Persistence

for _, field in ipairs({ "AutosaveSeconds", "ShutdownDrainSeconds", "LockStaleSeconds",
	"AcquireAttempts", "AcquireRetrySeconds" }) do
	check(type(PS[field]) == "number" and PS[field] > 0,
		("Persistence.%s is %s; DataService multiplies it into a retry budget and a non-number lands as an error inside an UpdateAsync transform")
			:format(field, tostring(PS[field])))
end
check(PS.AcquireAttempts == math.floor(PS.AcquireAttempts),
	("Persistence.AcquireAttempts is %.2f; it is a loop bound, and a fractional one silently truncates the window a joining player gets")
		:format(PS.AcquireAttempts))

-- The acquire window is the worst-case time a joining server will keep trying
-- before it kicks. The soft shutdown it has to outlast is the COMMON case:
-- the source server is draining while the player is already on the destination.
local acquireWindow = PS.AcquireAttempts * PS.AcquireRetrySeconds
check(acquireWindow > PS.ShutdownDrainSeconds,
	("a joining server gives up on a held lock after %ds but a shutting-down one has %ds to drain and release it, so every soft shutdown would kick the players teleporting off it")
		:format(acquireWindow, PS.ShutdownDrainSeconds))

-- The heartbeat rides the autosave, so a lock is only refreshed that often.
check(PS.LockStaleSeconds > 3 * PS.AutosaveSeconds,
	("a lock is called dead after %ds but its heartbeat only lands with the autosave every %ds, so a healthy server that hits %.1f autosaves' worth of DataStore throttling has its player's save stolen out from under it")
		:format(PS.LockStaleSeconds, PS.AutosaveSeconds, PS.LockStaleSeconds / PS.AutosaveSeconds))

-- A whole handover is a drain plus the acquire window that overlaps it.
check(PS.LockStaleSeconds > PS.ShutdownDrainSeconds + acquireWindow,
	("a lock goes stale in %ds but a full handover takes up to %ds (%ds draining plus %ds of retries), so the joining server could declare the lock dead and start writing while the server holding it is still legitimately saving — two writers, which is the whole thing the lock exists to prevent")
		:format(PS.LockStaleSeconds, PS.ShutdownDrainSeconds + acquireWindow,
			PS.ShutdownDrainSeconds, acquireWindow))

-- ── report ──────────────────────────────────────────────────────────────────
print(("checks run:        %d"):format(checks))
local trackCounts = {}
for _, track in ipairs(Config.TrackOrder) do
	table.insert(trackCounts, ("%s %d"):format(track, #Config.Tracks[track]))
end
print(("buttons:           %d  (%s)"):format(#Config.Buttons, table.concat(trackCounts, ", ")))
print(("machine slots:     %d dropper, %d upgrader")
	:format(#Config.Layout.DropperDist, #Config.Layout.UpgraderDist))
print(("analytics:         %d events of %d, %d combinations of %d, %d SKUs of %d")
	:format(#AN.Events, AN.MaxEventNames, analyticsCombinations, AN.MaxCombinations,
		#Config.Buttons, AN.MaxEconomySkus))
print(("side tracks:       %.1f min of detour (%.0f%% of the factory build)")
	:format(sideTotal, sideTotal / (elapsed / 60) * 100))
print(("upgrader stack:    x%.1f"):format(upgradeMult))
print(("endgame income:    %.3g Tung/sec"):format(endgameIncome))
print(("full build:        %.0f min"):format(elapsed / 60))
-- Printed rather than asserted, because the number that matters here is the one
-- the STARTER bat produces and there is no threshold it can pass. It is what
-- gating the cabinets costs, in seconds, and it wants reading every time either
-- the wave curve or the cabinet gate moves.
print(("waves:             saturate at wave %d (%d raiders, %.0f health, %d parts)")
	:format(saturationWave, satCount, satWaveHealth, waveParts))
print(("solo clear:        %.0fs with %s, %.0fs with %s (deadline %ds)")
	:format(clearTop, topBat.name, clearStart, startBat.name, WV.MaxWaveTime))
print(("belt:              %.0f studs, %.1fs transit, %.0f drops in flight at peak (%.0f%% full)")
	:format(beltLength, transit, inFlight, inFlight * DROP_LENGTH / beltLength * 100))
if floorReport then print(floorReport) end
print(("trigger dwell:     %.0f ms at %.0f studs/s (30 Hz step is %.0f ms)")
	:format(dwell * 1000, maxBeltSpeed, PHYSICS_STEP_DEMOTED * 1000))
print(("plot drop budget:  %.0f in flight across %d belts, cap %d (%.0f%%)")
	:format(totalInFlight, #Config.BeltPaths, Config.Economy.MaxDropsPerPlot,
		totalInFlight / Config.Economy.MaxDropsPerPlot * 100))
print(("first rebirth:     %.3g at minute %.0f (save from %s), %d spine rung(s) still unbought")
	:format(Config.Rebirth.BaseCost, rebirthAt, tostring(rebirthStop), rebirthLeftover))
print(("credit cap:        build ends at %.0f min, %.0f min of the %d-minute daily window unused")
	:format(buildMinutes, CREDIT_CAP_MINUTES - buildMinutes, CREDIT_CAP_MINUTES))
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
