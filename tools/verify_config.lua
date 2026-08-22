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
local KNOWN_KINDS = { Dropper = true, Upgrader = true, Belt = true, Structure = true, Gear = true, Armor = true, Floor = true, Line = true, Power = true }
local KNOWN_STRUCTURES = { walls = true, gates = true, windows = true, roof = true }

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
	elseif def.kind == "Line" then
		-- THE CONVEYOR ON A FLOOR, which is a different purchase from the floor
		-- (TODO.md item 4). Same shape of contract as Floor and for the same
		-- reason: the installer is a documented no-op and FloorService builds it
		-- off onOwnedChanged, so a row that no Config.Floors entry claims charges
		-- money and builds nothing, silently, forever.
		local floor
		for _, entry in ipairs(Config.Floors) do
			if entry.lineButton == def.id then
				check(floor == nil,
					("two Line buttons both build %s's conveyor; the second would charge and do nothing"):format(entry.id))
				floor = entry
			end
		end
		check(floor ~= nil,
			("%s is a Line button but no Config.Floors entry names it as its lineButton; it would charge and build nothing"):format(where))
		check(def.floor == nil or (floor and floor.id == def.floor),
			("%s says it builds the line on floor %q but Config.Floors disagrees"):format(where, tostring(def.floor)))
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

-- ...AND REACHABLE ONCE THE GATES ARE COUNTED TOO, which is a strictly harder
-- question than the walk above answers.
--
-- That walk follows `requires` and nothing else. It was SAFE rather than
-- correct: `requires` never crosses a track, and the only other precondition in
-- the game was Config.TrackUnlock, which is asserted to name a button on a
-- track that is itself ungated — so the gate was always satisfiable and
-- following the chains alone could not miss anything.
--
-- Config.ButtonUnlock removes that guarantee, because now a track can be gated
-- on a button that is itself waiting on the gated track. Nothing in the two
-- structural checks further down refuses this pair:
--
--     TrackUnlock.structure = "dropper8"   -- a plausible-looking retune
--     ButtonUnlock.floor2   = "roof"       -- shipped
--
-- floor2 waits on roof, roof is on the structure track, the structure track
-- waits on dropper8, and dropper8 is behind floor2 in the factory chain. Every
-- id exists, every track differs, every gate points at a spine track, and the
-- plot deadlocks four rungs from the end with no message.
--
-- So this is a FIXPOINT rather than a walk: start owning nothing, repeatedly
-- buy anything whose requirements, track gate and button gate are all already
-- owned, and stop when a pass buys nothing. Whatever is left cannot be reached
-- from an empty save by any route, which is the actual property. It is stated
-- as a closure and not as a cycle search because unreachable-and-acyclic fails
-- the same way for the player and deserves the same message.
do
	local owned, buyable = {}, 0
	repeat
		local bought = 0
		for _, def in ipairs(Config.Buttons) do
			if not owned[def.id] then
				local ok = true
				for _, req in ipairs(Config.requirementsOf(def)) do
					if not owned[req] then ok = false end
				end
				local trackGate = Config.TrackUnlock[def.track]
				if trackGate and not owned[trackGate] then ok = false end
				local buttonGate = Config.ButtonUnlock[def.id]
				if buttonGate and not owned[buttonGate] then ok = false end
				if ok then
					owned[def.id] = true
					bought += 1
				end
			end
		end
		buyable += bought
	until bought == 0

	for _, def in ipairs(Config.Buttons) do
		local trackGate = Config.TrackUnlock[def.track]
		local buttonGate = Config.ButtonUnlock[def.id]
		check(owned[def.id],
			("%s can never be bought from a fresh save: it requires %s, its %s track waits on %s and the button itself waits on %s. Some loop among those is closed — a gate is waiting on something behind the gate")
				:format(def.id,
					#Config.requirementsOf(def) > 0 and table.concat(Config.requirementsOf(def), "+") or "nothing",
					def.track, tostring(trackGate), tostring(buttonGate)))
	end
	check(buyable == #Config.Buttons,
		("only %d of %d buttons are reachable once track gates and button gates are counted"):format(buyable, #Config.Buttons))
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

-- ── NO ROW MAY RESTATE THE CHAIN THE LOADER DERIVES ─────────────────────────
--
-- The loader sets `def.requires` from the row above when the row does not carry
-- one, so by the time this file runs every row has the field and a hand-typed
-- one is indistinguishable from a derived one — UNLESS it disagrees with the
-- row above, which is exactly the case that matters.
--
-- This is INVARIANTS.md's oldest `[nothing]` entry and it has a shipped defect
-- behind it. Every row used to restate its own requirement, and the restating
-- hid a fork: `dropper8` required `upgrader4` while `floor2 -> mezz_dropper1`
-- hung off `upgrader4` too, so the mezzanine was a dead-end branch you could
-- skip entirely — and with the cabinets gated on `floor2` at the time, you
-- could finish the whole ground floor without ever seeing a weapon or a suit of
-- armour. The root-count check above cannot see a fork BELOW the root, so
-- nothing caught it.
--
-- Round 8 is the round that makes reordering routine — six rows moved and three
-- arrived — so this is the round that owes the check. Written as "the chain is
-- exactly the table order" rather than "no row has a requires field", because
-- the field always exists by now and the property worth having is the one the
-- convention actually claims.
for _, track in ipairs(Config.TrackOrder) do
	local defs = Config.Tracks[track] or {}
	for slot, def in ipairs(defs) do
		local want = slot > 1 and defs[slot - 1].id or nil
		local got = def.requires
		if want == nil then
			check(got == nil,
				("%s is the first rung of the %s track but requires %s; a track's root is requirement-free, and a root with a requirement is a track nothing can start")
					:format(def.id, track, tostring(got)))
		else
			check(got == want,
				("%s requires %s, but the row above it in the %s table is %s. The loader derives the chain from table order and a hand-typed requirement silently overrides it — that is how the mezzanine became a branch you could skip. Move the row instead.")
					:format(def.id, tostring(got), track, want))
		end
	end
end

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

-- ── social ──────────────────────────────────────────────────────────────────
-- A friend in your server is worth income, which makes this a BALANCE lever
-- wearing a growth feature's clothes. Four of these five bound it against
-- numbers that already exist elsewhere in this file, because the failure mode
-- is not "the bonus is wrong", it is "the bonus quietly became the best thing
-- in the game" or "the number on screen is still zero when the raid lands".
do
	local S = Config.Social

	check(type(S.BonusPerFriend) == "number" and S.BonusPerFriend > 0 and S.BonusPerFriend <= 0.25,
		("Social.BonusPerFriend is %s; a friend is worth between 0 and 25%% income — at zero the hook is never registered and the feature does not exist, above 25%% one friend beats a whole track")
			:format(tostring(S.BonusPerFriend)))

	-- MaxPlots IS the player cap (World.MaxPlots, with MaxPlayers set to match),
	-- so there can never be more than MaxPlots - 1 other people in the server.
	check(type(S.MaxFriends) == "number" and S.MaxFriends >= 1 and S.MaxFriends < Config.World.MaxPlots,
		("Social.MaxFriends is %s; it must be at least 1 and under World.MaxPlots (%d), because MaxPlots is the player cap and you cannot cap the bonus above the number of other people who can be in the server")
			:format(tostring(S.MaxFriends), Config.World.MaxPlots))

	local stacked = 1 + S.MaxFriends * S.BonusPerFriend
	check(stacked <= Config.Rebirth.MultiplierPerRebirth,
		("a full friend bonus pays x%.2f against a rebirth's x%.2f — the social lever must not out-earn a prestige, or the cheapest route to the top of the curve is a group chat")
			:format(stacked, Config.Rebirth.MultiplierPerRebirth))

	-- One joining player costs MaxPlots - 1 pairwise IsFriendsWith calls,
	-- serialised ResolveGap apart. They must all land before the first raid that
	-- player sees, or the multiplier on their HUD is wrong at the one moment it
	-- is being read.
	local fanOut = S.ResolveGap * (Config.World.MaxPlots - 1)
	local firstRaid = Config.Waves.WarningTime + Config.Waves.FirstWaveDelay
	check(type(S.ResolveGap) == "number" and S.ResolveGap > 0 and fanOut < firstRaid,
		("resolving every pair for one joining player takes %.2fs (%d calls at %s apart) but the first raid warning is up at %.0fs — the friend count would still be settling when the number first matters")
			:format(fanOut, Config.World.MaxPlots - 1, tostring(S.ResolveGap), firstRaid))

	check(type(S.RetrySeconds) == "number" and S.RetrySeconds > S.ResolveGap,
		("Social.RetrySeconds is %s against a ResolveGap of %s; a retry faster than the stagger re-fires a failing web call into the throttle that just refused it")
			:format(tostring(S.RetrySeconds), tostring(S.ResolveGap)))

	check(type(S.InviteCooldown) == "number" and S.InviteCooldown > 0,
		("Social.InviteCooldown is %s; RequestInvite is an untrusted remote and a remote that can be spammed is a remote that will be")
			:format(tostring(S.InviteCooldown)))
end

-- ── prototypes ──────────────────────────────────────────────────────────────
-- Unshipped, but the data still has to be coherent — a prototype that only
-- fails once you flip its flag is a prototype nobody flips.

-- Every flag must exist and be a boolean, and a shipping build has them all
-- off. If one gets left on, this is the check that says so.
for name, on in pairs(Config.Prototypes) do
	check(type(on) == "boolean", ("Prototypes.%s is not a boolean"):format(name))
	check(on == false, ("Prototypes.%s is ON — prototypes ship off"):format(name))
end

-- ...and the other half of that rule, which the check above cannot state.
--
-- "Every flag must be false" has exactly one legal way to ship a feature:
-- DELETE the flag. Setting it true fails the build, so a graduated feature stops
-- being a prototype rather than becoming the exception. That leaves one way to
-- undo a graduation by accident — re-adding the name as `false`, which reads as
-- housekeeping and silently switches a shipped feature back off, in a table
-- whose whole contract is that everything in it is unshipped.
local GRADUATED = {
	Floors = "the second floor is a factory-track purchase (Config.Floors)",
	Offline = "offline earnings and the Vault Timer ship (Config.Offline)",
	Sessions = "the streak, ladder, boost and weekend bonus ship (Config.Sessions)",
}
for name, why in pairs(GRADUATED) do
	check(Config.Prototypes[name] == nil,
		("Prototypes.%s is back in the flag table — %s. A graduated feature has no flag; setting it false switches a shipped feature off and setting it true fails the check above")
			:format(name, why))
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

-- SURVIVING A REBIRTH IS A CONSEQUENCE OF WHERE THE MODELS LIVE, NOT A TASTE
-- CALL, and until now only the factory's row had its VALUE checked — power's
-- was checked for presence, which INVARIANTS.md carries as a [nothing].
--
-- Tycoon:rebirth clears self.machines unconditionally and deliberately spares
-- self.props. Cabinet tracks build their shelf displays into props, so their
-- purchases can honestly outlive the reset; every other track builds into
-- machines, so a kept `owned` entry there means a button hidden as bought for a
-- model that has just been destroyed — the pad never comes back and the plot
-- keeps the hole for the rest of that owner's session. `furniture` is the field
-- that already records which folder a track builds into, so the two cannot be
-- set independently and this says so.
for _, track in ipairs(Config.TrackOrder) do
	local info = Config.TrackInfo[track]
	if info then
		check(info.keepOnRebirth == (info.furniture == "cabinet"),
			("TrackInfo.%s has keepOnRebirth=%s and furniture=%q; only cabinet tracks build into self.props, and rebirth() clears self.machines unconditionally — so a non-cabinet track that survives is a bought button with no model, and a cabinet track that does not is a shelf of tiers you paid for and lost")
				:format(track, tostring(info.keepOnRebirth), tostring(info.furniture)))
	end
end
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
		-- WIDENED FROM `== "factory"`, because the rule and its reason had come
		-- apart. The reason is that the gate must stand on a ladder the player
		-- is walked through anyway, so it is certainly reached; "factory" was
		-- the only vocabulary available for that when the factory was the only
		-- such ladder. With a second spine track the old form refuses a gate on
		-- `walls` — which is perfectly safe — and refuses it with a message
		-- calling structure a side track, which it is not. `paced` is the
		-- property that was always meant.
		check(Config.TrackInfo[def.track].paced == "spine",
			("TrackUnlock.%s is gated on %s, which is on the %s track — that track is paced as a detour, and a detour gating a ladder can deadlock it, because nothing guarantees a detour is ever taken")
				:format(track, gate, tostring(def.track)))
	end
end
check(Config.TrackUnlock.factory == nil,
	"the factory track cannot be gated — it is the thing that pays for everything else")

-- SINGLE-BUTTON GATES, the same shape one level down. Config.ButtonUnlock says
-- a purchase waits on something that is not upstream of it in its own chain,
-- which the loader structurally cannot express and the `requires` checks
-- structurally must refuse.
for id, gate in pairs(Config.ButtonUnlock) do
	local def = Config.ButtonById[id]
	local gateDef = Config.ButtonById[gate]
	check(def ~= nil,
		("ButtonUnlock names %q, which is not a button"):format(tostring(id)))
	check(gateDef ~= nil,
		("ButtonUnlock.%s waits on %q, which is not a button"):format(tostring(id), tostring(gate)))
	if def and gateDef then
		check(def.track ~= gateDef.track,
			("ButtonUnlock.%s waits on %s and both are on the %s track — within a track the loader derives the chain from table order, so this is a link pretending to be a gate. Move the row instead")
				:format(id, gate, def.track))
		check(Config.TrackInfo[gateDef.track].paced == "spine",
			("ButtonUnlock.%s waits on %s, which is on the %s track — that track is paced as a detour, so this puts an optional purchase between the player and a spine rung")
				:format(id, gate, gateDef.track))
	end
end

-- THE GATE EXISTS BECAUSE OF A FACT ABOUT THE BUILDING, so assert it against
-- that fact rather than against the pair of ids. FloorService stands each
-- storey's own wall ring up and nothing roofs it, so a storey is buyable only
-- once something has bought a roof. Written this way it fires if someone
-- deletes the ButtonUnlock row while keeping the floor, which is the way this
-- gets lost — the row looks like a special case until you know why it is there.
for _, floor in ipairs(Config.Floors) do
	local gate = Config.ButtonUnlock[floor.button]
	local gateDef = gate and Config.ButtonById[gate]
	check(gateDef ~= nil and gateDef.kind == "Structure" and gateDef.structure == "roof",
		("Floors.%s is built by %s and nothing in ButtonUnlock makes it wait for a roof; FloorService stands this storey's own wall ring up and nothing else ever roofs it, so the storey would be open to the sky")
			:format(floor.id, tostring(floor.button)))
end

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

-- Rebirth perks. Still a prototype, but its ONE table of content is the sort
-- that goes stale without anyone touching it: a milestone names a thing by id,
-- and the rest of the game is free to start selling that thing.
--
-- Which is exactly what happened. `[2] = { unlock = "mezzanine" }` sat here from
-- before the second floor graduated onto the factory track, so rebirth 2
-- promised something you had already bought with tung — and because the grant
-- was written into the save, it would have kept promising it forever. Nothing
-- could have caught that except a check that knows what the rest of Config
-- sells.
do
	local RP = Config.RebirthPerks
	check(RP.SlotEveryRebirths >= 1, "RebirthPerks.SlotEveryRebirths must be at least 1")
	check(RP.StartingCashGrowth >= 1, "RebirthPerks.StartingCashGrowth must not shrink with each rebirth")

	local floorById = {}
	for _, floor in ipairs(Config.Floors) do
		floorById[floor.id] = floor.button
	end

	for at, milestone in pairs(RP.Milestones) do
		local where = ("RebirthPerks.Milestones[%s]"):format(tostring(at))
		check(type(at) == "number" and at >= 1 and at <= Config.Rebirth.MaxRebirths,
			("%s is not a reachable rebirth count (1..%d)"):format(where, Config.Rebirth.MaxRebirths))
		check(type(milestone.unlock) == "string" and #milestone.unlock > 0,
			("%s has no unlock id"):format(where))
		check(type(milestone.label) == "string" and #milestone.label > 0,
			("%s has no label, so the rebirth notification would name nothing"):format(where))
		check(floorById[milestone.unlock] == nil,
			("%s grants %q, which is Floors.%s — bought with %s on the factory track. A rebirth cannot unlock something the game already sells")
				:format(where, tostring(milestone.unlock), tostring(milestone.unlock),
					tostring(floorById[milestone.unlock])))
		check(Config.ButtonById[milestone.unlock] == nil,
			("%s grants %q, which is a buy button — a rebirth cannot unlock something the game already sells")
				:format(where, tostring(milestone.unlock)))
	end
end

-- ── offline earnings (SHIPPED) ──────────────────────────────────────────────
-- The cap ladder has to be monotonic in both directions or there is a tier you
-- pay more for and get less from. The ladder is a PURCHASE now, so its prices
-- are checked against the income curve as well — down where the curve exists.
do
	local O = Config.Offline
	check(O.Rate > 0 and O.Rate <= 1, ("Offline.Rate is %.2f; it is a fraction"):format(O.Rate))
	check(O.CapHours > 0, "Offline.CapHours must bank something")
	-- Below this an absence pays nothing and the panel does not open. At zero
	-- every join would open a welcome-back modal for four seconds of being away.
	check(O.MinimumSeconds > 0, "Offline.MinimumSeconds must be positive or every join opens the panel")
	check(O.MinimumSeconds < O.CapHours * 3600,
		"Offline.MinimumSeconds is longer than the cap, so nothing between them is payable")
	check(#O.CapUpgradeHours == #O.CapUpgradeCost, "Offline cap upgrade hours and costs disagree in length")
	local previousHours, previousCost = O.CapHours, 0
	for i, hours in ipairs(O.CapUpgradeHours) do
		check(hours > previousHours, ("Offline cap tier %d does not extend the one before it"):format(i))
		check(O.CapUpgradeCost[i] > previousCost, ("Offline cap tier %d is not dearer than the one before it"):format(i))
		previousHours, previousCost = hours, O.CapUpgradeCost[i]
	end
end

-- ── session loops (SHIPPED) ─────────────────────────────────────────────────
do
	local S = Config.Sessions
	check(#S.DailyRewards == 7, "DailyRewards should be a 7-day loop")
	for i = 2, #S.DailyRewards do
		check(S.DailyRewards[i] > S.DailyRewards[i - 1], ("DailyRewards day %d is not better than day %d"):format(i, i - 1))
	end
	check(S.DailyGraceHours >= 24, "a daily streak needs at least a day of grace or one missed evening kills it")
	for streak, bonus in pairs(S.DailyMilestones) do
		check(type(streak) == "number" and streak >= 1 and streak % 1 == 0,
			("DailyMilestones is keyed on %s; the key is a whole streak count"):format(tostring(streak)))
		check(bonus > 0, ("DailyMilestones[%s] pays nothing"):format(tostring(streak)))
	end
	for i = 2, #S.PlaytimeMinutes do
		check(S.PlaytimeMinutes[i] > S.PlaytimeMinutes[i - 1], "PlaytimeMinutes must be increasing")
	end
	check(S.PlaytimeMinutes[1] > 0, "the first playtime rung must take longer than no time at all")
	check(S.PlaytimeRewardGrowth >= 1,
		"PlaytimeRewardGrowth is below 1, so every rung of the ladder pays less than the one before it")
	-- THE CLAIMED RUNGS ARE A BIT32 MASK. They have to be a number rather than a
	-- { [index] = true } set, because a sparse numeric-keyed table round-trips
	-- through the DataStore's JSON as an object with STRING keys and stops
	-- matching the index — which silently re-opens the ladder on every load. A
	-- 33rd rung would fall off the top of that number just as silently.
	check(#S.PlaytimeMinutes <= 32,
		("PlaytimeMinutes has %d rungs; the claimed set is a bit32 mask and holds 32")
			:format(#S.PlaytimeMinutes))
	check(S.BoostCooldown > S.BoostSeconds,
		"the boost lasts longer than its cooldown, so it would never be off")
	check(S.BoostMultiplier > 1, "the boost button pays no more than not pressing it")
	check(S.WeekendMultiplier > 1, "the weekend bonus pays no more than a Tuesday")
	-- os.date("!*t").wday is 1..7, Sunday first. A key outside that range is a
	-- weekend that never arrives, and nothing at runtime would ever say so.
	local weekendDays = 0
	for wday, on in pairs(S.WeekendDays) do
		check(type(wday) == "number" and wday >= 1 and wday <= 7,
			("Sessions.WeekendDays[%s] is not an os.date wday (1=Sunday .. 7=Saturday)"):format(tostring(wday)))
		check(on == true, ("Sessions.WeekendDays[%s] is not true; the lookup tests == true"):format(tostring(wday)))
		weekendDays += 1
	end
	check(weekendDays >= 1 and weekendDays < 7,
		("Sessions.WeekendDays covers %d days; a weekend is neither never nor always"):format(weekendDays))
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
local satBossHealth = satRaiderHealth * WV.BossHealthMultiplier
if saturationWave % WV.BossEvery == 0 then
	-- Scaled to a FULL server, because that is the heaviest this wave can ever
	-- be: the boss's health is fixed from the headcount at the moment the wave
	-- is minted, and nothing promises those people are still swinging at it.
	-- Leaving the unscaled boss in here would have quietly let the shared-boss
	-- work walk the endgame wave into the deadlock breaker.
	satWaveHealth += satBossHealth * Config.bossHealthFactor(Config.World.MaxPlots)
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

-- ── the boss as a shared objective ──────────────────────────────────────────
--
-- The boss is the only thing in this game that needs another human being, and
-- everything below is the arithmetic that keeps it worth showing up for without
-- making a busy server a wall. Three pure functions in Config carry it, so these
-- checks and the server run the same formula rather than two copies of it.

local MP = Config.World.MaxPlots

-- THE SOLO GUARANTEE, in two lines. At one player both factors are exactly 1
-- and the split is algebraically the identity, so a 1-player server gets
-- byte-for-byte the boss it got before any of this shipped — with no branch
-- anywhere in the code, which is the only reason it can be trusted to stay true.
check(Config.bossHealthFactor(1) == 1 and Config.bossRewardFactor(1) == 1,
	("a solo boss is scaled %.2fx in health and %.2fx in reward; at one player both have to be exactly 1 or the solo game changed underneath a feature that was for groups")
		:format(Config.bossHealthFactor(1), Config.bossRewardFactor(1)))
check(math.abs(Config.bossShare(1234, 1234, 1, 5000) - 5000) < 1e-9,
	("one eligible player takes %.2f of a 5000 pot; the floor share and the damage share have to sum to the whole pot or a solo kill silently pays less than it used to")
		:format(Config.bossShare(1234, 1234, 1, 5000)))

-- NEITHER LEAKED NOR MINTED. Summed over the eligible, the split is exactly the
-- pot at every player count — once with equal contributors, and once with a
-- lopsided fight, because the floor share and the damage share are different
-- fractions and it is only their sum that is one.
for n = 1, MP do
	local pot = 1e6
	local evenSum, unevenSum = 0, 0
	local evenTotal, unevenTotal = 0, 0
	for i = 1, n do
		evenTotal += 250
		unevenTotal += i * 37
	end
	for i = 1, n do
		evenSum += Config.bossShare(250, evenTotal, n, pot)
		unevenSum += Config.bossShare(i * 37, unevenTotal, n, pot)
	end
	check(math.abs(evenSum - pot) <= pot * 1e-9,
		("%d equal contributors split a %.0f pot into %.4f"):format(n, pot, evenSum))
	check(math.abs(unevenSum - pot) <= pot * 1e-9,
		("%d uneven contributors split a %.0f pot into %.4f"):format(n, pot, unevenSum))
end

-- JOINING A BUSY SERVER IS NOT A PUNISHMENT, and it is not a payday either.
-- The pot has to grow SLOWER than the health — otherwise the boss is a reward
-- for standing near it — but not so much slower that the ninth person to arrive
-- is worse off for the other eight being there.
for n = 1, MP do
	local health = Config.bossHealthFactor(n)
	local reward = Config.bossRewardFactor(n)
	check(reward / health >= 0.6,
		("at %d players the boss is %.2fx health for %.2fx reward (%.0f%%); past this the arena punishes you for having company")
			:format(n, health, reward, reward / health * 100))
	check(reward <= health + 1e-9,
		("at %d players the pot grows faster than the health (%.2fx against %.2fx); the boss stops being a fight and becomes a payout for turning up")
			:format(n, reward, health))
end

-- CAN THE PEOPLE WHO SHOWED UP STILL FINISH IT? The scaling is sampled once,
-- from the headcount at the moment the wave is minted, so the honest worst case
-- is a boss built for a full server and fought by whoever stayed. Checked
-- against a lone player, because that is who pays for this number being wrong.
for n = 1, MP do
	local seconds = satBossHealth * Config.bossHealthFactor(n) / playerDps(topBat)
	check(seconds <= WV.MaxWaveTime,
		("a boss scaled for %d players is %.0f health, and one player with the best bat in the game needs %.0fs of it against a MaxWaveTime of %d")
			:format(n, satBossHealth * Config.bossHealthFactor(n), seconds, WV.MaxWaveTime))
end

-- ...and the same question asked from the FLOOR of the experience, which is the
-- convention the raider-damage checks above already use: the one player left
-- holding the starting bat after everyone else went back to their plot. This is
-- the check that actually binds BossMaxHealthFactor, and it is the reason that
-- number is 4 rather than whatever looked generous — the boss must still be a
-- fight somebody can finish, not a health bar that outlives the wave.
local soloFloor = satBossHealth * Config.bossHealthFactor(MP) / playerDps(startBat)
check(soloFloor <= WV.MaxWaveTime,
	("a boss scaled for a full %d-player server takes %.0fs for a player on the starting bat, against a MaxWaveTime of %d — raising BossMaxHealthFactor costs exactly this person")
		:format(MP, soloFloor, WV.MaxWaveTime))

-- THE SPLIT'S OWN BOUNDS.
check(WV.BossFloorShare > 0 and WV.BossFloorShare < 1,
	("BossFloorShare is %.2f; at 0 nobody but the top damage sees a coin and at 1 the fight pays the same whatever you do")
		:format(WV.BossFloorShare))
check(WV.BossMinDamageFrac > 0 and WV.BossMinDamageFrac < 0.1,
	("BossMinDamageFrac is %.3f of the boss's health; at 0 a single stray swing dilutes the even split and past ~10%% a real contributor is refused")
		:format(WV.BossMinDamageFrac))
-- With everyone at exactly the floor, the eligible set is at most this big. It
-- has to be able to hold a full server, or the last people to land a hit on a
-- boss they helped kill are arithmetically excluded from it.
check(1 / WV.BossMinDamageFrac >= MP,
	("at a %.3f damage floor only %.0f players can ever qualify, on a server of %d")
		:format(WV.BossMinDamageFrac, 1 / WV.BossMinDamageFrac, MP))

-- WHERE IT LANDS. A shared objective goes in one findable place, so the boss
-- spawns on a fixed bearing by the dais rather than on a random rim bearing —
-- and it is a 2.1x body, so "by the dais" has to clear the dais.
local bossHalfWidth = 2 * WV.BossBodyScale
check(WV.BossSpawnRadius >= Config.World.DaisRadius + bossHalfWidth,
	("the boss spawns %.0f studs from the centre and is %.1f studs half-wide, against a dais of radius %d — it would spawn inside the plinth the statue stands on")
		:format(WV.BossSpawnRadius, bossHalfWidth, Config.World.DaisRadius))
check(WV.BossSpawnRadius + bossHalfWidth < Config.World.ArenaRadius,
	("the boss spawns %.0f studs out and is %.1f wide, against an arena wall at %d")
		:format(WV.BossSpawnRadius, bossHalfWidth, Config.World.ArenaRadius))

-- IT ALSO HAS TO STAY THERE. A boss kited to the far side of the arena is a
-- boss eleven people spend the fight looking for, so its leash is tighter than
-- an ordinary raider's — and its home patch is the dais, not the whole
-- HomeSpread disc, so the geometric plot-safety check above is only slacker for
-- it, never tighter.
check(WV.BossLeashRadius < WV.LeashRadius,
	("BossLeashRadius %.0f is not tighter than the raider leash of %.0f; the point of the shared objective is that it stays where everyone is walking")
		:format(WV.BossLeashRadius, WV.LeashRadius))
check(WV.BossSpawnRadius + WV.BossLeashRadius + WV.AttackRange < raiderReach,
	("a leashed boss can swing %.0f studs from the arena centre against a raider's %.0f; the plot-safety proof above is written for the raider figure")
		:format(WV.BossSpawnRadius + WV.BossLeashRadius + WV.AttackRange, raiderReach))
-- The leash has to be wider than the patch it is measured from, or the boss is
-- born outside its own leash and walks home before it will look at anybody.
check(WV.BossLeashRadius > WV.BossSpawnRadius,
	("BossLeashRadius %.0f against a boss home patch of %.0f studs")
		:format(WV.BossLeashRadius, WV.BossSpawnRadius))

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
-- ...and still fit inside the plot behind it. The shell's half-depth was a
-- literal 5 here and a literal 10 in Tycoon:buildCollector, which is two copies
-- of one number in two files and no way for either to notice the other moving.
-- Both read Layout.Vault now.
local vaultFar = L.BeltEnd.Z + runOff + L.Vault.bodyDepth / 2
check(vaultFar <= halfZ - 2,
	("the vault's far face lands at z=%.1f, into the front wall at z=%.1f")
		:format(vaultFar, halfZ - 1))

-- THE VAULT'S OWN FURNITURE. Everything below used to be a literal inside
-- Tycoon:buildCollector, which meant the verifier could see where the vault
-- STOOD but nothing about what was bolted to it — and the lid is the most
-- crowded 6 studs on the plot: trim, a 20x6 board and a statue inside 5 studs
-- of each other. The fill gauge is the first thing added to this object since,
-- and it is added to a face rather than to the lid for exactly that reason.
do
	local V = L.Vault
	local w = V.window

	-- WHICH AXIS THE WINDOW IS BOUNDED BY. The gauge lies on a LATERAL face,
	-- and a lateral face of an 18-wide, 10-deep box measures 10 x 9 — so the
	-- window's horizontal extent is bounded by the body's DEPTH, not its width.
	-- Checking it against bodyWidth would pass anything up to 16 studs and let
	-- a 12-stud pane hang 2 studs off each end of a 10-stud face.
	check(w.width + 2 <= V.bodyDepth,
		("the fill window is %.1f wide on a face only %.1f deep; it would overhang the vault")
			:format(w.width, V.bodyDepth))
	check(w.height + 2 <= V.bodyHeight,
		("the fill window is %.1f tall on a %.1f-tall shell; it would break the top and bottom edges")
			:format(w.height, V.bodyHeight))
	-- ...and it has to be half-sunk into that face rather than floating off it
	-- or buried in it: two coplanar faces z-fight, and a pane inside the wood
	-- is a gauge nobody can read.
	check(w.lateral > V.bodyWidth / 2 and w.lateral < V.bodyWidth / 2 + w.thickness / 2,
		("the fill window sits at |x| = %.2f against a face at %.1f; it must straddle the face, not float off it or sink behind it")
			:format(w.lateral, V.bodyWidth / 2))

	-- The small print hangs off the SAME face, outboard of the shell, or it
	-- renders inside solid wood.
	check(V.detailLateral >= V.bodyWidth / 2,
		("the detail board sits at |x| = %.1f, inside a shell %.1f wide — it would be buried in the vault")
			:format(V.detailLateral, V.bodyWidth))
	-- ...and clear of the headline board above it. Two billboards overlapping
	-- in world space do not stack, they smear: one draws over the other at
	-- whatever angle you happen to be standing.
	check(V.detailSignY + V.detailHeight / 2 <= V.signY - V.signHeight / 2,
		("the detail board's top edge is at y=%.1f and the headline board's bottom edge is at y=%.1f; they overlap")
			:format(V.detailSignY + V.detailHeight / 2, V.signY - V.signHeight / 2))

	-- The statue stands ON the sign, not in it.
	check(V.statueY > V.signY,
		("the statue sits at y=%.1f and the sign at y=%.1f; the statue would stand in front of the number")
			:format(V.statueY, V.signY))
end

-- WHAT THE EXIT HOOK IS ALLOWED TO PROMISE. The sign on the vault reads
-- "leaving now banks X over Nh", and the only thing that makes that worth
-- walking away from is that X is a meaningful fraction of an evening. At
-- CapHours x Rate the offline vault is worth that many hours of live play; if
-- the product ever fell under two, the honest sign would read "come back
-- tomorrow for ninety seconds of income" and the feature would be a lie told
-- in gold.
do
	local O = Config.Offline
	check(O.CapHours * O.Rate >= 2,
		("a full offline vault is worth %.1f hours of live play; under 2 the exit hook is not worth reading")
			:format(O.CapHours * O.Rate))
end

-- ── floors, boxes and belt legs ─────────────────────────────────────────────
--
-- WHAT THE FLOOR KEY IS FOR. Everything below here used to be able to assume
-- that "on the plot" meant "on one floor", because it did: the deck covered the
-- back 60 studs and nothing was ever bought on it. The deck spans the plot now
-- and both side-track cabinets stand on it, so two pieces of furniture four
-- studs apart in plan can be twenty-two studs apart in Y and never touch. Every
-- piece of furniture carries the floor it stands on, and a collision check
-- compares that before it compares geometry.
--
-- The key is deliberately also a Config.BeltPaths id — the plot floor's path is
-- `"ground"` and a Config.Floors path is that floor's own id — which is what
-- lets a piece of furniture find the belt it has to stay off without a second
-- table mapping one to the other.
local GROUND = "ground"
local floorsById = {}
for _, floor in ipairs(Config.Floors) do
	floorsById[floor.id] = floor
end
local beltPathById = {}
for _, path in ipairs(Config.BeltPaths) do
	beltPathById[path.id] = path
end
check(beltPathById[GROUND] ~= nil,
	("no belt path is called %q, so the plot floor's furniture has no belt row to be checked against")
		:format(GROUND))

--- A buy-button pedestal, in plan. The one box every piece of furniture in the
--- lists below shares.
local PEDESTAL = Vector3.new(5, 1, 5)

--- Gap between an axis-aligned box (centre + full size) and a point, 0 inside.
--- Written component-wise because the Vector3 in this harness is a bare table
--- with no arithmetic — see the note in HANDOFF_v2 §5.
local function boxPointGap(centre, size, point)
	local dx = math.max(math.abs(point.X - centre.X) - size.X / 2, 0)
	local dz = math.max(math.abs(point.Z - centre.Z) - size.Z / 2, 0)
	return math.sqrt(dx * dx + dz * dz)
end

--- Gap between two axis-aligned boxes in plan, 0 if they overlap. The deleted
--- teleport pads were 9x9 against 5x5 pedestals, so the centre-distance rule the
--- furniture list uses is the wrong instrument for them: two boxes can be 14
--- studs apart centre to centre and still interpenetrate.
local function boxBoxGap(aCentre, aSize, bCentre, bSize)
	local dx = math.max(math.abs(aCentre.X - bCentre.X) - (aSize.X + bSize.X) / 2, 0)
	local dz = math.max(math.abs(aCentre.Z - bCentre.Z) - (aSize.Z + bSize.Z) / 2, 0)
	return math.sqrt(dx * dx + dz * dz)
end

--- How much two axis-aligned boxes interpenetrate in plan: 0 if they are clear
--- of each other. The complement of boxBoxGap, and needed because that function
--- saturates at 0 — it can say "they overlap" but not "by how much", and a
--- message that reads "0.0 studs" tells you nothing about how far to move.
local function boxBoxOverlap(aCentre, aSize, bCentre, bSize)
	local dx = (aSize.X + bSize.X) / 2 - math.abs(aCentre.X - bCentre.X)
	local dz = (aSize.Z + bSize.Z) / 2 - math.abs(aCentre.Z - bCentre.Z)
	if dx <= 0 or dz <= 0 then
		return 0
	end
	return math.min(dx, dz)
end

--- How far inside an outer box an inner box sits, in plan: the smallest clearance
--- from any of the outer box's four edges. Negative when the inner box hangs
--- over one of them, and the magnitude is the overhang, so a message can say
--- which way to move and by how much.
local function boxInsetBy(outerAt, outerSize, innerAt, innerSize)
	local dx = (outerSize.X - innerSize.X) / 2 - math.abs(innerAt.X - outerAt.X)
	local dz = (outerSize.Z - innerSize.Z) / 2 - math.abs(innerAt.Z - outerAt.Z)
	return math.min(dx, dz)
end

-- HOW FAR THE BELT'S SOLID SLAB STANDS PROUD OF ITS RUNNING SURFACE. Mirrored
-- from Belt.lua, where `BeltBase` is built `BeltWidth + 1.2` wide — the surface
-- is 8 studs but the collidable thing under it is 9.2, so the belt reaches 0.6
-- further each side than BeltWidth says. Config already reasons in those terms in
-- two places (the mezzanine hatch's back lip, and the pillar note's "leg 2 reaches
-- x = -48.6", which is -44 less 4.6), and measuring against the surface instead is
-- how the stairwell's guard came to be 0.1 studs inside the belt base while
-- looking like it cleared by a stud.
--
-- THE MIRRORED LITERAL IS GONE. It was `local BELT_BASE_PROUD = 1.2` here and
-- `width + 1.2` in Belt.lua, and the two agreeing was luck rather than
-- structure — HANDOFF_v7 named it as one of two builder literals wanting to
-- become Config keys. Config.beltHalfWidth is that key's derivation, read by
-- both, and it now also carries the guard rails: every clearance check in this
-- file measures against the belt's REAL reach for free.
local BELT_REACH = Config.beltHalfWidth()

--- The three rectangles one belt leg occupies in plan: the collidable base, the
--- machine row OUTBOARD of it, and the buy-button row INBOARD of it.
---
--- The outboard normal is `sign * (-dir.Z, 0, dir.X)`, which is the expression
--- Belt.lua's resolvePath uses, read from the path's own `outboard` table. That
--- matters more here than anywhere else: the mezzanine's return leg runs back
--- across the middle of its own zone, which is exactly where the old
--- "point away from the plot origin" heuristic inverts. A check that guessed the
--- side would reserve the machine strip on the empty side of that leg and pass
--- anything standing on the occupied one.
local function legBoxes(path)
	local boxes = {}
	for index = 1, #path.points - 1 do
		local a, b = path.points[index], path.points[index + 1]
		local dirX = (b.X > a.X and 1) or (b.X < a.X and -1) or 0
		local dirZ = (b.Z > a.Z and 1) or (b.Z < a.Z and -1) or 0
		local sign = (path.outboard and path.outboard[index]) or 1
		local nX, nZ = -dirZ * sign, dirX * sign
		local midX, midZ = (a.X + b.X) / 2, (a.Z + b.Z) / 2
		local along = math.abs(b.X - a.X) + math.abs(b.Z - a.Z)
		-- `pad` extends the strip ALONG the leg, because a machine or a pedestal at
		-- the last distance on a leg is centred on the endpoint and half of it
		-- hangs past it. The running surface gets none: the belt ends where the
		-- corner is.
		local function strip(offset, cross, pad)
			return {
				centre = Vector3.new(midX + nX * offset, 0, midZ + nZ * offset),
				size = Vector3.new(
					math.abs(dirX) * (along + pad) + math.abs(nX) * cross, 1,
					math.abs(dirZ) * (along + pad) + math.abs(nZ) * cross),
			}
		end
		table.insert(boxes, {
			index = index,
			belt = strip(0, BELT_REACH * 2, 0),
			machines = strip(L.MachineOffset, L.MachineFootprint, L.MachineFootprint),
			buttons = strip(-L.ButtonOffset, PEDESTAL.X, PEDESTAL.X),
		})
	end
	return boxes
end

-- ── the guard walls, and the bug they must not repeat ───────────────────────
--
-- NEW. TODO.md item 5 asks for prominent guard walls on both belts. There were
-- rails once and they were deleted, and this is the check that would have made
-- deleting them unnecessary.
--
-- THE DEFECT, AS GEOMETRY. Each leg's rails ran its FULL length. Every leg's
-- running surface deliberately overruns its bend by half a belt width so the
-- two surfaces share a face rather than seaming, so a rail that followed its
-- leg's full span crossed the NEIGHBOURING leg's surface — two solid walls
-- straight across the conveyor, plus an 11x11 block on the bend. Drops piled up
-- against them.
--
-- Stated directly: a leg's rail run may not overlap any OTHER leg's running
-- surface. BeltGuard.corner is what makes that true, and setting it to 0
-- reproduces the original bug exactly.
do
	local GUARD = L.BeltGuard
	local railLateral = L.BeltWidth / 2 - GUARD.bite + GUARD.thickness / 2

	for _, path in ipairs(Config.BeltPaths) do
		local legs = {}
		for index = 1, #path.points - 1 do
			local a, b = path.points[index], path.points[index + 1]
			local dirX = (b.X > a.X and 1) or (b.X < a.X and -1) or 0
			local dirZ = (b.Z > a.Z and 1) or (b.Z < a.Z and -1) or 0
			local along = math.abs(b.X - a.X) + math.abs(b.Z - a.Z)
			legs[index] = { a = a, b = b, dirX = dirX, dirZ = dirZ, along = along }
		end

		for index, leg in ipairs(legs) do
			-- A leg shorter than two setbacks plus a usable run has no rail at
			-- all, which is a silent hole rather than a crash: Belt.lua drops the
			-- part rather than emitting a negative-length one, and Roblox would
			-- otherwise keep the previous size.
			-- Counted per END rather than doubled: an open end takes no setback, so
			-- a short first or last leg is legal where a short middle one is not.
			local setbacks = ((index > 1) and 1 or 0) + ((index < #legs) and 1 or 0)
			check(leg.along > setbacks * GUARD.corner + 6,
				("BeltPaths.%s leg %d is %.0f studs with %d setback(s) of %d; under %d there is no rail left to build and the leg silently gets none")
					:format(path.id, index, leg.along, setbacks, GUARD.corner, setbacks * GUARD.corner + 6))

			-- The rail's own box, derived from THE SAME LEG-LOCAL SPAN Belt.lua
			-- builds from rather than from an approximation of it.
			--
			-- This used to be the leg's length minus two setbacks, centred on the
			-- leg's own midpoint. That was two departures from the built object at
			-- once: the surface a rail is pulled back from is not the leg — it
			-- starts a stud early on leg 1 and overruns its bend by half a belt
			-- width on every leg but the last — and the setback is not applied at
			-- both ends any more. A check that models the rail differently from
			-- the builder is measuring a rail nobody builds, which is the whole
			-- family of defect Config.beltHalfWidth was written to end.
			local half = L.BeltWidth / 2
			local fromDist = (index == 1) and -1 or (half - 0.6)
			local toDist = (index == #legs) and leg.along or (leg.along + half)
			-- Pulled back only where the leg meets another one; see Belt.lua.
			local guardFrom = fromDist + (index > 1 and GUARD.corner or 0)
			local guardTo = toDist - (index < #legs and GUARD.corner or 0)
			local run = math.max(guardTo - guardFrom, 0)
			local alongMid = (guardFrom + guardTo) / 2
			local midX = leg.a.X + leg.dirX * alongMid
			local midZ = leg.a.Z + leg.dirZ * alongMid
			for _, side in ipairs({ -1, 1 }) do
				local nX, nZ = -leg.dirZ * side, leg.dirX * side
				local railAt = Vector3.new(midX + nX * railLateral, 0, midZ + nZ * railLateral)
				local railSize = Vector3.new(
					math.abs(leg.dirX) * run + math.abs(nX) * GUARD.thickness, 1,
					math.abs(leg.dirZ) * run + math.abs(nZ) * GUARD.thickness)

				for other, otherLeg in ipairs(legs) do
					if other ~= index then
						-- The other leg's surface, INCLUDING the corner overrun,
						-- because the overrun is the part the old rails crossed.
						local overrun = (other == #legs) and 0 or L.BeltWidth / 2
						local oMidX = (otherLeg.a.X + otherLeg.b.X) / 2 + otherLeg.dirX * overrun / 2
						local oMidZ = (otherLeg.a.Z + otherLeg.b.Z) / 2 + otherLeg.dirZ * overrun / 2
						local oLen = otherLeg.along + overrun
						local oNX, oNZ = math.abs(otherLeg.dirZ), math.abs(otherLeg.dirX)
						local surfaceAt = Vector3.new(oMidX, 0, oMidZ)
						local surfaceSize = Vector3.new(
							math.abs(otherLeg.dirX) * oLen + oNX * L.BeltWidth, 1,
							math.abs(otherLeg.dirZ) * oLen + oNZ * L.BeltWidth)

						-- TOUCHING IS NOT CROSSING, and at the shipped numbers the
						-- rail lands exactly on the neighbour's edge.
						--
						-- A rail ends `corner - half` short of its bend and the
						-- next leg's surface begins `half` short of the same bend,
						-- so the two meet flush precisely when corner == BeltWidth
						-- — which is what 8 and 8 are. That is the setback doing
						-- its job to the stud: the corner square is completely
						-- clear and the guard is as long as it can be. The bug
						-- this check exists for is a rail lying ACROSS the
						-- conveyor, and a shared face is not one.
						--
						-- The tolerance is for the float, not for the geometry:
						-- the rail's Z max computes to -25.999999999999996 against
						-- a surface edge of -26, so an exact touch arrives here as
						-- 3.6e-15 of overlap. 1e-6 studs is far under anything
						-- that could be a real crossing and far over the noise.
						local TOUCH = 1e-6
						local into = boxBoxOverlap(railAt, railSize, surfaceAt, surfaceSize)
						check(into <= TOUCH,
							("BeltPaths.%s leg %d's %s guard rail overlaps leg %d's running surface by %.2f studs — that is a solid wall straight across the conveyor, and it is exactly the bug the old full-length rails shipped. Raise Layout.BeltGuard.corner.")
								:format(path.id, index, side < 0 and "inboard" or "outboard", other, into))
					end
				end
			end
		end
	end

	-- ...AND IT MAY NOT BE SHORTER THAN THE OVERRUN IT IS PULLING BACK FROM.
	-- The setback is measured off the SURFACE's span, and every leg but the last
	-- overruns its bend by half a belt width, so a rail ends `corner - half`
	-- short of the bend while the next leg's surface begins `half` short of it.
	-- Under BeltWidth the rail crosses the neighbour — the deleted-rails bug
	-- exactly — and the overlap loop above would catch it, but only on a path
	-- whose legs happen to bend the wrong way. This says the condition once, on
	-- the number, so it holds for a path nobody has drawn yet.
	check(GUARD.corner >= L.BeltWidth,
		("Layout.BeltGuard.corner is %.1f against a belt %.1f wide; a leg's surface overruns its bend by half that, so under %.1f a rail reaches across the neighbouring leg")
			:format(GUARD.corner, L.BeltWidth, L.BeltWidth))
	-- The setback has to clear the corner square the surfaces overrun...
	check(GUARD.corner >= L.BeltWidth / 2 + GUARD.thickness + 2,
		("Layout.BeltGuard.corner is %.1f against a corner square %.1f deep plus a %.1f rail; a rail that reaches the bend is a rail in the corner the drops turn through")
			:format(GUARD.corner, L.BeltWidth / 2, GUARD.thickness))
	-- ...and the turn sensor's leading face, which sits downstream of the bend.
	check(GUARD.corner >= L.TriggerThickness / 2 + (L.TriggerThickness - 2.5) / 2 + 1,
		("Layout.BeltGuard.corner is %.1f and the turn sensor reaches %.1f past the bend; a rail inside it is a part the sensor's Touched fires on")
			:format(GUARD.corner, L.TriggerThickness / 2 + (L.TriggerThickness - 2.5) / 2))

	-- THE RAIL MAY NOT REACH THE MACHINE ROW. This is the tightest pair in the
	-- design and the reason `thickness` is 0.8 rather than something rounder.
	check(L.MachineOffset - L.MachineFootprint / 2 >= Config.beltHalfWidth() + 0.5,
		("the machine row starts %.1f studs from the belt centre and the belt now reaches %.1f with its rails on; a guard that reaches the machines is a fence built into a dropper")
			:format(L.MachineOffset - L.MachineFootprint / 2, Config.beltHalfWidth()))
	-- ...nor the walkway the buy buttons stand on.
	check(L.ButtonOffset - PEDESTAL.X / 2 >= Config.beltHalfWidth() + 2,
		("the buy-button row starts %.1f studs from the belt centre against a belt reaching %.1f; there has to be floor between the rail and the pads to stand on")
			:format(L.ButtonOffset - PEDESTAL.X / 2, Config.beltHalfWidth()))

	-- Buried in the surface at one end and under the machine arms at the other.
	check(GUARD.bite > 0 and GUARD.bite <= GUARD.thickness / 2,
		("Layout.BeltGuard.bite is %.2f against a %.2f-thick rail; at 0 the rail's inner face is coplanar with the running surface and z-fights, and past half the thickness it swallows the upgrader's scanner plate")
			:format(GUARD.bite, GUARD.thickness))
	check(L.BeltY + GUARD.height + GUARD.bar / 2 <= L.MachineTopY - 1,
		("the guard's top rail reaches y=%.2f and a dropper's arm hangs at %.2f; the rail would be inside the machine")
			:format(L.BeltY + GUARD.height + GUARD.bar / 2, L.MachineTopY))
	check(GUARD.height >= 1.5,
		("Layout.BeltGuard.height is %.2f above the running surface; TODO.md item 5 asked for prominent, and under 1.5 it is the trim it replaced")
			:format(GUARD.height))
end


-- HOW MANY PLAN COMPARISONS THE FURNITURE BLOCK MAKES, printed at the end.
-- Partitioning the furniture by floor removes pairs by construction — a cabinet
-- on the deck against a pad on the plot floor is no longer a comparison worth
-- making — and the honest way to show that the partition did not quietly hollow
-- the block out is to count them.
local furniturePairs = 0

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
-- The side tracks whose `floor` names a floor that exists. Everything below reads
-- a position through Config.floorTopY, which RAISES on an id it does not know, so
-- a track with a broken floor key is reported once (below) and then left out of
-- the geometry rather than taking the whole suite down with a stack trace from
-- inside Config.
local placedTracks = {}
-- EACH ENTRY CARRIES THE SPACING RULE IT IS SUBJECT TO, and the pair check
-- below takes the stricter of the two. One constant used to police both kinds
-- of column, which is one constant doing two jobs: the misc column is five
-- unrelated purchases standing in a line down an open floor, and a cabinet
-- column is nine pads that are deliberately one object in front of one case.
-- See Layout.CabinetSlotSpacing for the argument and the number.
for id, spot in pairs(L.MiscButtons) do
	table.insert(miscList, { id = "MiscButtons." .. id, spot = spot, floor = GROUND, spacing = L.MiscButtonSpacing })
end
for _, track in ipairs(Config.TrackOrder) do
	local layout = L.Tracks[track]
	if layout then
		-- WHICH STOREY THE COLUMN STANDS ON. `floor` names a Config.Floors id, and
		-- this is checked BEFORE anything reads a position, so that a mistyped id
		-- comes out of this file as a named failure rather than as the stack trace
		-- Config.floorTopY now raises from underneath the whole suite. Every
		-- geometric check below would otherwise pass on a typo, consistently,
		-- because they would all be measuring the ground floor and agreeing with
		-- each other.
		local floorKey = layout.floor or GROUND
		local known = layout.floor == nil or floorsById[layout.floor] ~= nil
		placedTracks[track] = known
		check(known,
			("Layout.Tracks.%s stands on floor %q, which is not a Config.Floors id; the whole column has no stated height")
				:format(track, tostring(layout.floor)))
		check(beltPathById[floorKey] ~= nil,
			("Layout.Tracks.%s stands on floor %q, which has no belt path, so its pedestals cannot be checked against the belt they share a storey with")
				:format(track, tostring(floorKey)))
		-- Check every SLOT, not every button: the empty slots are where the
		-- next tier will land, and finding out then is finding out too late.
		for slot = 1, (known and layout.slots or 0) do
			table.insert(miscList, {
				id = ("Tracks.%s[%d]"):format(track, slot),
				spot = Config.trackButtonPosition(track, slot),
				floor = floorKey,
				spacing = L.CabinetSlotSpacing,
			})
		end
		check(#Config.Tracks[track] <= layout.slots,
			("the %s track has %d buttons but Layout.Tracks.%s only has %d slots; the extras would stack on the last pedestal")
				:format(track, #Config.Tracks[track], track, layout.slots))
	end
end
table.sort(miscList, function(a, b) return a.id < b.id end)

-- THE PADS ARE GROUND-FLOOR FURNITURE, all three of them: you claim a plot,
-- rebirth and respawn on the plot floor, and none of the three has an upstairs
-- counterpart. Each carries a point margin (for containment) and a box (for
-- collisions), because a 14x14 claim pad against a 5x5 pedestal is exactly the
-- case a centre-distance rule gets wrong.
local pads = {
	{ id = "RebirthPadAt", spot = L.RebirthPadAt, margin = 6, size = Vector3.new(12, 1, 12), floor = GROUND },
	{ id = "ClaimPadAt", spot = L.ClaimPadAt, margin = 17, size = Vector3.new(14, 1, 14), floor = GROUND },
	-- not a pad: the volume a body occupies where the owner is put down
	{ id = "OwnerSpawnAt", spot = L.OwnerSpawnAt, margin = 3, size = Vector3.new(6, 1, 6), floor = GROUND },
}

-- THE SOLID THINGS ON THE PLOT FLOOR THAT ARE NOT PEDESTALS. Just the vault
-- today, and it is here because the vault is the biggest single object on the
-- ground floor and nothing in this file has ever compared a piece of furniture
-- against it — the checks it has are about the belt reaching it and it reaching
-- the wall. The stairwell is what made that a gap worth closing: the truss now
-- lands in the deck's front-left quarter, which is the vault's corner of the plot
-- 22 studs below, and Config's hatch comment claims it clears it. `bodyDepth` is
-- along Z and `bodyWidth` along X — the same orientation `vaultFar` above uses.
local groundSolids = {
	{
		id = "the vault shell",
		at = L.CollectorAt,
		size = Vector3.new(L.Vault.bodyWidth, 1, L.Vault.bodyDepth),
	},
}

local floorSpots = {}
for _, pad in ipairs(pads) do
	table.insert(floorSpots,
		{ id = pad.id, spot = pad.spot, margin = pad.margin, size = pad.size, floor = pad.floor })
end
for _, entry in ipairs(miscList) do
	table.insert(floorSpots,
		{ id = entry.id, spot = entry.spot, margin = 3, size = PEDESTAL, floor = entry.floor })
end
-- Containment is NOT floor-aware and must not become so: a deck sits inside the
-- plot's wall ring, so anything standing on any floor of it is still inside the
-- plot, and this is the check that says the empty slots a future tier lands in
-- are too.
for _, entry in ipairs(floorSpots) do
	inPlot(entry.id, entry.spot, entry.margin)
end

-- RE-AUTHORED, PREMISE OVERTURNED (see HANDOFF_v6 §3 for the convention).
--
-- The three loops below compared every piece of floor furniture against every
-- other piece, against the three pads, and against both belt buy-button rows, in
-- PLAN and with no notion of height. That was right — and load-bearing — for the
-- plot it was written against, because everything on that plot stood on ONE
-- floor: the deck covered the back 60 studs, nothing could be bought on it, and
-- the deleted teleport pad interpenetrated the armour cabinet's slot-2 pedestal
-- by 3x1 studs precisely because two pieces of furniture were not compared. On a
-- one-floor plot a 2D rule is a complete rule.
--
-- The second floor spans the plot now and both side-track cabinets have moved
-- onto it, so "4 studs apart in plan" no longer implies "touching": the cabinets
-- and their nine pedestals stand 22 studs above the pads they used to share a
-- floor with. Two boxes on DIFFERENT floors cannot collide, so comparing them
-- reports a failure that is not a defect — which is exactly what
-- `Tracks.weapons cabinet comes within 4.0 studs of ClaimPadAt` was. Two boxes on
-- the SAME floor still must not, and that half is untouched and is still the
-- whole reason this block exists.
--
-- The floor key is the only thing added. What it must not do is quietly reduce
-- what is covered, so every pair it stops comparing is replaced by a comparison
-- against something on the pair's own floor: that floor's belt rows below, and
-- the deck, the armoury zone and the hatch in the mezzanine block.
for _, entry in ipairs(miscList) do
	for _, pad in ipairs(pads) do
		if entry.floor == pad.floor then
			furniturePairs += 1
			-- A pad is not a buy button and has no spacing rule of its own, so
			-- the entry's own rule applies.
			local d = len(sub(entry.spot, pad.spot))
			check(d >= entry.spacing,
				("%s is only %.1f studs from %s (need %d)")
					:format(entry.id, d, pad.id, entry.spacing))
		end
	end
end

for i, a in ipairs(miscList) do
	for j = i + 1, #miscList do
		local b = miscList[j]
		if a.floor == b.floor then
			furniturePairs += 1
			-- THE STRICTER OF THE TWO RULES, so a cabinet pedestal beside a misc
			-- one is held to the misc column's 14 rather than the cabinet's 12.
			-- Taking the looser one would let a tighter column drag a wider one
			-- in with it, which is the failure mode of having two numbers at all.
			local need = math.max(a.spacing, b.spacing)
			local d = len(sub(a.spot, b.spot))
			check(d >= need,
				("%s and %s both stand on the %s floor and are only %.1f studs apart (need %d)")
					:format(a.id, b.id, a.floor, d, need))
		end
	end
end

-- ...and stay clear of the belt on their OWN floor: the running surface, the
-- machine row OUTBOARD of each leg, and the buy-button row ButtonOffset studs
-- INBOARD of it. Overlapping pedestals were already shipped once and only stayed
-- invisible because the unlock chain happened to hide one before the other
-- appeared.
--
-- ONE BELT PER FLOOR, found by the floor key. This was two hardcoded scalars —
-- `BeltStart.Z + ButtonOffset` and `BeltCorner.X + ButtonOffset` — which are the
-- GROUND floor's two button rows and nothing else. So the nine side-track
-- pedestals were being measured against a belt on a different storey while the
-- belt they actually share a storey with was not looked at at all, and neither
-- the running surface nor the machine row was looked at on either floor. legBoxes
-- derives all three strips of every leg of the path whose id is the floor key.
for _, entry in ipairs(miscList) do
	local path = beltPathById[entry.floor]
	if path then
		for _, leg in ipairs(legBoxes(path)) do
			for _, strip in ipairs({
				{ "belt base", leg.belt },
				{ "machine row", leg.machines },
				{ "buy-button row", leg.buttons },
			}) do
				furniturePairs += 1
				local into = boxBoxOverlap(strip[2].centre, strip[2].size, entry.spot, PEDESTAL)
				check(into == 0,
					("%s stands %.1f studs into the %s of belt %q's leg %d")
						:format(entry.id, into, strip[1], path.id, leg.index))
			end
		end
	end
end

-- ── side-track cabinets ─────────────────────────────────────────────────────
-- The cabinet BODIES are the only solid, collidable things the side tracks add
-- to the plot, so they get the treatment the vault and the belt already have: an
-- explicit box, checked against everything else that occupies floor — on the
-- floor they stand on.
--
-- THEY ARE ON THE MEZZANINE NOW, which is what pulls the deck, its armoury zone
-- and its stairwell into this loop. Two of the checks below used to be about the
-- ground floor and had to be re-authored for that; the rest are new, and they
-- exist because "inside the plot" stopped being a useful bound for a cabinet the
-- moment the cabinet left the plot floor. A 116x136 deck sits inside a 120x140
-- plot, so a cabinet can pass every containment check in this file and still
-- stand two studs off the edge of the floor it is supposed to be standing on.

local gateFrom, gateTo = L.GateCentre - L.GateWidth / 2, L.GateCentre + L.GateWidth / 2

-- WHAT THE CABINET IS, ABOVE ITS BOX. Mirrored from Props.lua's ensureCabinets,
-- where all four are literals: the trim cap is `size.Y + 0.4` tall and 0.8 thick,
-- the sign anchor stands 2.5 above the body, and a billboard 4 studs tall hangs
-- centred on the anchor. So the tallest part of a cabinet is its LABEL, at
-- `height + 4.5`, and not the case.
--
-- THIS IS A MIRROR, AND SAYING SO IS THE POINT. verify_config reads Config and
-- nothing else, so these four numbers cannot be derived here; the block below
-- asserts Structure.UpperClear against the object's shape and will not notice the
-- BUILDER changing that shape. Config.Structure.Trim exists because
-- shellPartCount had to count a trim cap it could not see, and these want exactly
-- the same treatment — the geometry of a cabinet belongs in Config.Layout.Tracks
-- beside `height`. Until it moves there, this is the coupling, declared.
local CABINET_TRIM_LIFT, CABINET_TRIM_THICK = 0.4, 0.8
local CABINET_SIGN_LIFT, CABINET_SIGN_HEIGHT, CABINET_ANCHOR = 2.5, 4, 1

-- THE FOUR ROOF COLUMNS, derived rather than typed. These were the literals
-- (halfX - 4, halfZ - 4) in the loop below, which is "the wall ring minus
-- Roof.columnInset" for today's numbers and stops tracking the roof the moment
-- the inset moves — the same two-copies-of-one-number arrangement that let the
-- walls sit seven studs under the roof. The wall ring stands 1 stud in from the
-- pad edge; the columns stand `columnInset` in from that. The shell block below
-- asserts these same two numbers against the wall's inner face and against the
-- machine rows they stand among.
local roofColumnX = halfX - 1 - Config.Structure.Roof.columnInset
local roofColumnZ = halfZ - 1 - Config.Structure.Roof.columnInset

-- The gap a piece of furniture has to leave round a hole in the floor it stands
-- on, and round the belt that shares it: enough to walk past, which is the same
-- number the pillars and the pedestals already use.
local FURNITURE_GAP = 2

for _, track in ipairs(Config.TrackOrder) do
	local layout = L.Tracks[track]
	if layout and placedTracks[track] then
		local centre, size = Config.trackCabinet(track)
		local where = "Tracks." .. track .. " cabinet"
		local floorKey = layout.floor or GROUND
		local floor = floorsById[layout.floor]

		-- inside the wall ring, which stands 1 stud in from the pad edge. NOT
		-- floor-aware, and must not become so: the shell is a ring at every
		-- storey, so a cabinet upstairs has the same wall to grow through as one
		-- downstairs.
		check(math.abs(centre.X) + size.X / 2 <= halfX - 2,
			("%s spans x %.1f..%.1f, into the side wall at x=%.1f")
				:format(where, centre.X - size.X / 2, centre.X + size.X / 2, halfX - 1))
		check(math.abs(centre.Z) + size.Z / 2 <= halfZ - 2,
			("%s spans z %.1f..%.1f, into the end wall at z=%.1f")
				:format(where, centre.Z - size.Z / 2, centre.Z + size.Z / 2, halfZ - 1))

		-- RE-AUTHORED, PREMISE OVERTURNED. Not standing on the floor furniture —
		-- on its own floor. This is the check that reported `Tracks.weapons cabinet
		-- comes within 4.0 studs of ClaimPadAt (needs 17)`: a 17-stud bound between
		-- a display case on the deck and the pad you claim the plot on, 22 studs
		-- below it. The bound was right while both stood on the plot floor, and it
		-- is the one that found a 9x9 pad inside a 5x5 pedestal.
		for _, spot in ipairs(floorSpots) do
			if spot.floor == floorKey then
				furniturePairs += 1
				local gap = boxPointGap(centre, size, spot.spot)
				check(gap >= spot.margin,
					("%s comes within %.1f studs of %s on the %s floor (needs %d)")
						:format(where, gap, spot.id, spot.floor, spot.margin))
			end
		end

		-- ...and far enough off its own pedestals that a shelf display does
		-- not grow through the buy button in front of it
		check(math.abs(layout.buttonX - layout.cabinetX) - size.X / 2 >= 4,
			("%s stands %.1f studs from its own button column; the shelf would clip the pads")
				:format(where, math.abs(layout.buttonX - layout.cabinetX) - size.X / 2))

		-- ...and off the belt ON ITS OWN FLOOR. This was two scalars naming the
		-- GROUND floor's two legs — `BeltStart.Z` and `BeltCorner.X` — which is the
		-- belt these cabinets no longer share a storey with. The belt they do share
		-- one with was not checked at all, and it is the one they can reach: the
		-- mezzanine's return leg ends 6 studs from the weapons cabinet.
		local ownBelt = beltPathById[floorKey]
		if ownBelt then
			for _, leg in ipairs(legBoxes(ownBelt)) do
				for _, strip in ipairs({
					{ "belt base", leg.belt },
					{ "machine row", leg.machines },
					{ "buy-button row", leg.buttons },
				}) do
					furniturePairs += 1
					local gap = boxBoxGap(centre, size, strip[2].centre, strip[2].size)
					check(gap >= FURNITURE_GAP,
						("%s comes within %.1f studs of the %s of belt %q's leg %d (need %d) — a display case over a belt walls the conveyor off")
							:format(where, gap, strip[1], ownBelt.id, leg.index, FURNITURE_GAP))
				end
			end
		end

		-- ...and clear of the four roof columns, which stand Roof.columnInset
		-- studs in from the wall ring (see roofColumnX/Z above). Also not
		-- floor-aware: a column runs from the plot floor to the roof and passes
		-- through every storey on the way.
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				furniturePairs += 1
				local column = Vector3.new(sx * roofColumnX, 0, sz * roofColumnZ)
				check(boxPointGap(centre, size, column) >= 2,
					("%s overlaps the roof column at (%.0f, %.0f)")
						:format(where, column.X, column.Z))
			end
		end

		-- RE-AUTHORED, PREMISE OVERTURNED. The walk in from the gateway must not
		-- run into a display case — and the gateway is a hole in the GROUND floor's
		-- front wall, which a cabinet on the deck cannot stand in. This is the
		-- second of the two failures the move produced (`stands in the walk from
		-- the gateway to the owner spawn at z=44`): true of the plan, false of the
		-- building, because the walk it describes is 22 studs underneath.
		--
		-- The upstairs equivalent is not the gateway, it is the stairwell — you
		-- arrive on that floor through the hatch — and that is the check below.
		if floorKey == GROUND then
			local clearsGate = (centre.X - size.X / 2 > gateTo)
				or (centre.X + size.X / 2 < gateFrom)
				or (centre.Z + size.Z / 2 < L.OwnerSpawnAt.Z - 8)
			check(clearsGate,
				("%s stands in the walk from the gateway to the owner spawn at z=%.0f")
					:format(where, L.OwnerSpawnAt.Z))
		end

		-- ── a cabinet on the ground floor, under a deck that spans it ────────
		--
		-- DELETED FROM HERE: the block that bounded a cabinet standing on a floor
		-- ABOVE the plot — against the slab, against its zone, and against the
		-- hole in that slab. #58 wrote it when both cases moved onto the
		-- mezzanine; TODO.md item 2 has brought both back down, so `layout.floor`
		-- is nil for every shipped track and every one of those checks was
		-- unreachable. Nine checks that cannot fail are not nine checks, and this
		-- file's own convention is to delete rather than leave them standing.
		--
		-- What replaces them covers the same class — "a display case standing
		-- through something" — on the floor the cases are actually on. Both of
		-- these are gaps that predate the move: neither the posts nor the yard
		-- door has ever been compared against a piece of floor furniture, and
		-- both are reachable by a case at x 46..50 in a way nothing else on this
		-- plot is.
		local column = {}
		for slot = 1, layout.slots do
			table.insert(column, { id = ("Tracks.%s[%d]"):format(track, slot),
				at = Config.trackButtonPosition(track, slot), size = PEDESTAL })
		end
		table.insert(column, { id = where, at = centre, size = size })

		-- THE MEZZANINE DECK'S POSTS, which are the only solids besides the roof
		-- columns that run the full height of the ground storey. They stand at
		-- deckHalfX - pillar.insetSide, which is x = ±54 for today's deck — three
		-- studs from a case at x 46..50 and directly in the file's line. The deck
		-- is bought late and these appear under a cabinet that has been standing
		-- there for half an hour, which is exactly the kind of arrival nothing
		-- would have caught.
		for _, deck in ipairs(Config.Floors) do
			if deck.pillar and deck.deckAt and deck.deckSize then
				local px = deck.deckSize.X / 2 - deck.pillar.insetSide
				local pz = {
					deck.deckAt.Z - deck.deckSize.Z / 2 + deck.pillar.insetBack,
					deck.deckAt.Z + deck.deckSize.Z / 2 - deck.pillar.insetFront,
				}
				local postSize = Vector3.new(deck.pillar.size, 1, deck.pillar.size)
				for _, sx in ipairs({ -1, 1 }) do
					for _, z in ipairs(pz) do
						local at = Vector3.new(deck.deckAt.X + sx * px, 0, z)
						for _, piece in ipairs(column) do
							furniturePairs += 1
							local gap = boxBoxGap(piece.at, piece.size, at, postSize)
							check(gap >= FURNITURE_GAP,
								("%s is %.1f studs from %s's deck post at (%.0f, %.0f) (need %d) — the post runs from the plot floor to the slab, so it arrives THROUGH anything standing here")
									:format(piece.id, gap, deck.id, at.X, z, FURNITURE_GAP))
						end
					end
				end
			end
		end

		-- THE DOORWAY ONTO THE GENERATOR YARD. `clearsGate` above covers the
		-- front gateway and has since the cabinets were first placed; the back
		-- wall's door has never been covered by anything. It is the only way to
		-- the yard, it is cut at x 46..59 — the same right-hand strip the armoury
		-- now occupies — and a case parked across its threshold is a generator
		-- you can see and cannot reach.
		--
		-- The threshold is modelled as a box the width of the opening reaching
		-- DOORWAY_WALK studs in from the wall — far enough that a case flush to
		-- the wall beside it still fails, which is the shape of the mistake.
		local DOORWAY_WALK = 8
		for _, opening in ipairs(Config.Structure.Openings) do
			if opening.side == "back" and opening.storey == "ground" then
				local mouth = Vector3.new(opening.centre, 0, -Config.World.PlotSize.Z / 2 + DOORWAY_WALK / 2)
				local mouthSize = Vector3.new(opening.width, 1, DOORWAY_WALK)
				-- boxBoxOverlap, NOT boxBoxGap. boxBoxGap saturates at zero — it
				-- can say "these two touch" and never "this one is inside that
				-- one" — so `gap >= 0` is true for every pair of boxes that has
				-- ever existed. Written that way first, and it passed with a
				-- cabinet parked squarely across the doorway.
				for _, piece in ipairs(column) do
					furniturePairs += 1
					local into = boxBoxOverlap(piece.at, piece.size, mouth, mouthSize)
					check(into == 0,
						("%s stands %.1f studs inside the walk-through of the %s opening (x %.0f..%.0f in the back wall) — that doorway is the only way onto the generator yard")
							:format(piece.id, into, opening.id,
								opening.centre - opening.width / 2, opening.centre + opening.width / 2))
				end
			end
		end

		-- ── the storey it stands IN, not the floor it stands ON ──────────────
		--
		-- NEW, and it is the relationship that moved Structure.UpperClear from 16
		-- to 20. A cabinet is not `height` tall: the trim caps the body, the sign
		-- anchor stands above the trim and the billboard hangs on the anchor, so
		-- the tallest part of the object is its LABEL, 4.5 studs over the case. At
		-- 16 the top 1.5 studs of every cabinet sign were inside the ceiling — a
		-- defect found by eye, in Studio, on the one class of relationship this
		-- file exists to hold: two numbers in Config that have to clear each other.
		--
		-- The storey is found by matching the floor it stands on to a
		-- Structure.Storeys `floorY`, because that IS the link between the two
		-- tables — Storeys[2].floorY is Floors[1].height — and nothing else states
		-- it. A floor with no storey over it has no stated headroom at all.
		local floorY = Config.floorTopY(layout.floor)
		local storey
		for _, candidate in ipairs(Config.Structure.Storeys) do
			if math.abs(candidate.floorY - floorY) < 1e-9 then
				storey = candidate
			end
		end
		check(storey ~= nil,
			("%s stands at y=%.1f, which is not the floorY of any Config.Structure.Storeys entry, so nothing states how much headroom it has")
				:format(where, floorY))
		if storey then
			for _, part in ipairs({
				{ "case", size.Y },
				{ "trim cap", size.Y + CABINET_TRIM_LIFT + CABINET_TRIM_THICK / 2 },
				{ "sign anchor", size.Y + CABINET_SIGN_LIFT + CABINET_ANCHOR / 2 },
				{ "sign", size.Y + CABINET_SIGN_LIFT + CABINET_SIGN_HEIGHT / 2 },
			}) do
				check(part[2] <= storey.clear,
					("%s's %s reaches %.1f studs above the %s storey's floor, which has %.1f studs of clear height — the top %.1f studs are inside the ceiling")
						:format(where, part[1], part[2], storey.id, storey.clear, part[2] - storey.clear))
			end
		end
	end
end

-- CABINET AGAINST CABINET, which nothing compared. Both cases are 4 studs deep
-- and up to 64 long, they stand on one storey 34 studs apart in x, and the
-- furniture list only ever saw their PEDESTALS — two 5x5 points 14 studs apart
-- pass the spacing rule while the cases behind them interpenetrate, which is the
-- same 9x9-against-5x5 mistake the pads made from the other direction.
for i, track in ipairs(Config.TrackOrder) do
	local layout = L.Tracks[track]
	for j = i + 1, #Config.TrackOrder do
		local other = Config.TrackOrder[j]
		local otherLayout = L.Tracks[other]
		if layout and otherLayout and placedTracks[track] and placedTracks[other]
				and (layout.floor or GROUND) == (otherLayout.floor or GROUND) then
			local aCentre, aSize = Config.trackCabinet(track)
			local bCentre, bSize = Config.trackCabinet(other)
			furniturePairs += 1
			local gap = boxBoxGap(aCentre, aSize, bCentre, bSize)
			check(gap >= FURNITURE_GAP,
				("the %s and %s cabinets both stand on the %s floor and come within %.1f studs of each other (need %d)")
					:format(track, other, layout.floor or GROUND, gap, FURNITURE_GAP))
		end
	end
end

-- ── the mezzanine, on the ground floor's terms ──────────────────────────────
--
-- None of this was checkable until now. FloorService built the deck's belt in
-- code, so the belt-path assertions never saw it; its teleport pads were never
-- in miscList, so nothing cross-checked them against the plot furniture; and
-- the roof already shrinks itself when the floor is on, which is the kind of
-- arrangement that breaks quietly when either side moves.

for _, floor in ipairs(Config.Floors) do
	local where = "Floors." .. floor.id
	local deck, deckAt = floor.deckSize, floor.deckAt
	local deckHalfX, deckHalfZ = deck.X / 2, deck.Z / 2

	local path = Config.floorBeltPath(floor)
	local legs = legBoxes(path)
	local reach = L.MachineOffset + L.MachineFootprint / 2 + floor.rail.thickness

	-- ── HOW LONG THE STOREY TAKES TO ARRIVE ──────────────────────────────────
	--
	-- NEW. TODO.md item 1: "we need it to happen slower". The build was one
	-- frame, so a purchase you spend two thirds of the build saving for produced
	-- a building that was simply already there.
	--
	-- The verifier cannot watch an animation. What it can check is that the
	-- table describes a coherent one — stages in order with no gap, a stated
	-- total that matches what the stages actually take, and a lift far enough
	-- that a piece has somewhere to fall from.
	local raise = floor.raise
	check(raise ~= nil, ("%s has no `raise` block; the storey would arrive in one frame"):format(where))
	if raise then
		local finish = 0
		local previous = nil
		local count = 0
		for index, stage in ipairs(raise.stages) do
			local stageWhere = ("%s raise stage %d (%s)"):format(where, index, tostring(stage.id))
			check(type(stage.id) == "string" and stage.id ~= "",
				stageWhere .. " has no id; FloorService dispatches on it by name")
			check(stage.time > 0, ("%s takes %s seconds"):format(stageWhere, tostring(stage.time)))
			check(stage.at >= 0, ("%s starts at %s"):format(stageWhere, tostring(stage.at)))
			if previous then
				check(stage.at >= previous.at,
					("%s starts at %.1fs, before the stage above it at %.1fs — the stages are the order the building goes up")
						:format(stageWhere, stage.at, previous.at))
				-- NO DEAD AIR. A gap between one stage finishing and the next
				-- starting is the storey pausing halfway up, which reads as a
				-- hitch rather than as construction.
				check(stage.at <= previous.at + previous.time,
					("%s starts at %.1fs but the stage before it finishes at %.1fs — %.1fs of nothing happening reads as a hitch, not as building")
						:format(stageWhere, stage.at, previous.at + previous.time,
							stage.at - (previous.at + previous.time)))
			end
			finish = math.max(finish, stage.at + stage.time)
			previous = stage
			count += 1
		end
		check(count >= 1, ("%s has no raise stages"):format(where))
		-- THE LADDER IS LAST, and nothing but the order guards it: the climb must
		-- not open until there is a floor at the top of it.
		check(previous == nil or previous.id == "ladder",
			("%s's last raise stage is %q; the ladder has to be last, or the climb opens onto a storey that has not landed")
				:format(where, previous and tostring(previous.id) or "none"))
		check(math.abs(raise.total - finish) < 1e-9,
			("%s claims a raise of %.2fs but its stages finish at %.2fs — a stated total that is not what it takes is a number nobody can trust")
				:format(where, raise.total, finish))
		-- Long enough to read as construction, short enough not to be a loading
		-- screen you paid for.
		check(raise.total >= 3 and raise.total <= 10,
			("%s takes %.1fs to arrive (want 3-10) — under three it is still a pop, and over ten it is a wait for something already bought")
				:format(where, raise.total))
		-- A piece that starts inside its own resting position has nowhere to
		-- descend from, and descending is what stops a slab sweeping through a
		-- player standing under it.
		check(raise.lift > floor.deckSize.Y,
			("%s lifts a piece %.1f studs to descend from, and the slab is %.1f thick — it would start inside where it lands")
				:format(where, raise.lift, floor.deckSize.Y))
		check(raise.fade > 0 and raise.fade < 1,
			("%s descends at transparency %.2f; at 0 the piece is solid on the way down and at 1 it is invisible until it lands")
				:format(where, raise.fade))
	end

	-- ── THE ZONES ────────────────────────────────────────────────────────────
	--
	-- NEW, and the reason the rest of this block could be written at all. A deck
	-- rectangle plus four belt margins could not say that the back of the storey
	-- is a production line and the front is a landing — you had to read
	-- FloorService and Layout.Tracks and hold both in your head. Now that the
	-- floor says it, the zones are what the belt and the cabinets are measured
	-- against instead of the deck, and that is not a stylistic preference:
	--
	--   the deck is 116 x 136 and the line zone is 112 x 60, so `side = 10` — the
	--   exact defect the belt-margin check exists for, a machine strip hanging a
	--   stud and a half over the railing — fits inside the WIDENED deck with half
	--   a stud to spare. The check that caught it stopped being able to catch it
	--   the moment the deck grew. Against the line zone it fails again.
	local line = floor.zones and floor.zones.line
	local landingZone = floor.zones and floor.zones.landing
	check(line ~= nil and landingZone ~= nil,
		("%s does not name both a `line` zone and a `landing` zone; the belt is derived from the first and the stairwell arrives in the second, so a floor without both cannot say where anything on it belongs")
			:format(where))

	if line and landingZone then
		local zoneNames = {}
		for name in pairs(floor.zones) do
			table.insert(zoneNames, name)
		end
		table.sort(zoneNames)

		local zoneArea = 0
		for _, name in ipairs(zoneNames) do
			local zone = floor.zones[name]
			check(zone.size.X > 0 and zone.size.Z > 0,
				("%s zone %q has no extent (%.1f x %.1f); an empty zone silently contains nothing")
					:format(where, name, zone.size.X, zone.size.Z))
			local inset = boxInsetBy(deckAt, deck, zone.at, zone.size)
			check(inset >= 0,
				("%s zone %q spans x %.1f..%.1f z %.1f..%.1f and hangs %.1f studs off the deck — a zone names part of a floor, not the air beside it")
					:format(where, name,
						zone.at.X - zone.size.X / 2, zone.at.X + zone.size.X / 2,
						zone.at.Z - zone.size.Z / 2, zone.at.Z + zone.size.Z / 2, -inset))
			zoneArea += zone.size.X * zone.size.Z
		end

		for i = 1, #zoneNames do
			for j = i + 1, #zoneNames do
				local a, b = floor.zones[zoneNames[i]], floor.zones[zoneNames[j]]
				local into = boxBoxOverlap(a.at, a.size, b.at, b.size)
				check(into == 0,
					("%s zones %q and %q interpenetrate by %.1f studs; one square of floor cannot belong to two zones, or neither of them bounds anything")
						:format(where, zoneNames[i], zoneNames[j], into))
			end
		end

		-- WHAT THE ZONES DO NOT ACCOUNT FOR, asserted rather than left to be
		-- noticed. They deliberately do not tile the deck: Config's claim is that
		-- `line` IS the old deck rectangle to the stud, which leaves it narrower
		-- than the widened deck, while `landing` takes the full width. So the
		-- leftover is exactly two strips down the sides of the line zone, and
		-- these five checks say so — the four edges that must coincide, and then
		-- the area that must be left over given they do. A third zone, or either
		-- of these sliding off an edge, stops matching and has to state its own
		-- leftover.
		local sideStrip = (deck.X - line.size.X) / 2
		local expected = 2 * sideStrip * line.size.Z
		local leftover = deck.X * deck.Z - zoneArea
		check(math.abs((line.at.Z - line.size.Z / 2) - (deckAt.Z - deckHalfZ)) < 1e-9,
			("%s's line zone starts at z=%.1f and the deck's back edge is z=%.1f; the production line is the back of the storey")
				:format(where, line.at.Z - line.size.Z / 2, deckAt.Z - deckHalfZ))
		check(math.abs((line.at.Z + line.size.Z / 2) - (landingZone.at.Z - landingZone.size.Z / 2)) < 1e-9,
			("%s's line zone ends at z=%.1f and its landing starts at z=%.1f; the gap between them is floor that belongs to neither")
				:format(where, line.at.Z + line.size.Z / 2, landingZone.at.Z - landingZone.size.Z / 2))
		check(math.abs((landingZone.at.Z + landingZone.size.Z / 2) - (deckAt.Z + deckHalfZ)) < 1e-9,
			("%s's landing ends at z=%.1f and the deck's front edge is z=%.1f")
				:format(where, landingZone.at.Z + landingZone.size.Z / 2, deckAt.Z + deckHalfZ))
		check(math.abs(landingZone.size.X - deck.X) < 1e-9 and landingZone.at.X == deckAt.X,
			("%s's landing is %.1f wide on a %.1f-wide deck; it is meant to be the full width of the storey")
				:format(where, landingZone.size.X, deck.X))
		check(math.abs(leftover - expected) < 1e-9,
			("%s's zones leave %.0f square studs of deck unaccounted for; the only floor no zone is meant to name is the two %.1f-stud strips down the sides of the line zone, which is %.0f. Say what the rest is for")
				:format(where, leftover, sideStrip, expected))

		-- THE BELT IS DERIVED FROM `line`, NOT FROM THE DECK — the claim that let
		-- the deck grow to span the plot without moving a machine. Recomputed here
		-- from the zone and its margins: if Config.floorBeltPath is ever re-pointed
		-- at deckSize, all four corners move outward, the belt spreads across the
		-- whole storey, and the drop budget, the trigger dwell and the mezzanine
		-- dropper's position go with it. Every one of these numbers is the number
		-- it was when the deck WAS this rectangle, or this fires.
		local b = floor.belt
		local zoneCorners = {
			Vector3.new(line.at.X + line.size.X / 2 - b.side, 0, line.at.Z - line.size.Z / 2 + b.back),
			Vector3.new(line.at.X - line.size.X / 2 + b.side, 0, line.at.Z - line.size.Z / 2 + b.back),
			Vector3.new(line.at.X - line.size.X / 2 + b.side, 0, line.at.Z + line.size.Z / 2 - b.front),
			Vector3.new(b.collectorX - b.collectorRun, 0, line.at.Z + line.size.Z / 2 - b.front),
		}
		check(#path.points == #zoneCorners,
			("%s's belt has %d corners; the line zone plus its four margins describes %d")
				:format(where, #path.points, #zoneCorners))
		for index, want in ipairs(zoneCorners) do
			local got = path.points[index]
			if got then
				check(math.abs(got.X - want.X) < 1e-9 and math.abs(got.Z - want.Z) < 1e-9,
					("%s belt corner %d is at (%.1f, %.1f) but the line zone plus its margins puts it at (%.1f, %.1f) — the belt has to be derived from the zone, or a deck that grows drags every machine on the storey with it")
						:format(where, index, got.X, got.Z, want.X, want.Z))
			end
		end

		-- ...and each margin has to clear the machine row it holds. This is the
		-- scalar form of the check `side = 10` failed, stated against the number
		-- the row actually reaches rather than against whatever rectangle happens
		-- to be around it.
		for _, margin in ipairs({ { "back", b.back }, { "side", b.side }, { "front", b.front } }) do
			check(margin[2] >= reach,
				("%s's %s belt margin is %.1f studs in from the line zone, against a machine row that reaches %.1f — a machine on that leg hangs over the railing")
					:format(where, margin[1], margin[2], reach))
		end

		-- ...and every strip of every leg — the slab, the machine row and the button
		-- row — is inside the zone that is supposed to hold them.
		for _, leg in ipairs(legs) do
			for _, strip in ipairs({
				{ "belt base", leg.belt },
				{ "machine row", leg.machines },
				{ "buy-button row", leg.buttons },
			}) do
				local inset = boxInsetBy(line.at, line.size, strip[2].centre, strip[2].size)
				check(inset >= 0,
					("%s: the %s of belt leg %d hangs %.1f studs outside the line zone that holds %s")
						:format(where, strip[1], leg.index, -inset, tostring(line.holds)))
			end
		end
	end

	-- ── THE STAIRWELL ────────────────────────────────────────────────────────
	--
	-- RE-AUTHORED, PREMISE OVERTURNED (see HANDOFF_v6 §3 for the convention).
	--
	-- This was `ladder.at.Z > deckAt.Z + deckHalfZ` — "the ladder stands in FRONT
	-- of the deck's front edge, not under it", with a companion saying it stood
	-- within stepping distance of that edge. Both were right for the design they
	-- were written against: the deck covered the back 60 studs of the plot, its
	-- front edge at z = -8 had open air in front of it, and a truss anywhere
	-- behind that edge would have climbed into the underside of a slab. Coming up
	-- THROUGH the deck needed a hatch in the slab and a hole in the guard, and
	-- neither existed.
	--
	-- The deck spans the plot now. There is no air in front of it to stand in, so
	-- the premise inverts: the truss must be INSIDE the footprint, in the void
	-- Floors.hatch cuts out of it, and what used to be the defect is the
	-- requirement. The rule is not relaxed by the change, it is bounded harder —
	-- "in front of a 136-stud deck" was one inequality; "inside a hatch that is
	-- itself clear of the belt, the cabinets, the hopper and the ground floor under
	-- it" is a family.
	--
	-- `Floors.ladder.at` is gone with it. It said z = -6.6 while the builder had
	-- started deriving the truss from the hatch at z = -8, so every clearance
	-- check below was measuring a box nothing builds — the sixth thing this round
	-- that read as checked and was not. Both sides read Config.floorLadderAt now.
	local ladder = floor.ladder
	local hatch = floor.hatch
	local ladderBox = Vector3.new(ladder.width, 1, ladder.width)
	check(hatch ~= nil,
		("%s has no hatch; a deck that spans the plot has no front edge to stand a ladder in front of, so without one there is no way up to it")
			:format(where))
	check(ladder.at == nil,
		("%s.ladder still carries `at`; the truss's position is derived from the hatch by Config.floorLadderAt and a second copy of it is the disagreement that made every clearance check below measure a box nothing built")
			:format(where))

	if hatch then
		local truss = Config.floorLadderAt(floor)
		local landing = Config.floorLandingAt(floor)

		-- WHICH LIP YOU ARRIVE OVER has to be one of the four. floorLadderAt and
		-- floorLandingAt both fall through to "+Z" for anything else, so a typo
		-- here is a truss silently against the wrong side of the hole.
		local ARRIVALS = { ["+Z"] = true, ["-Z"] = true, ["+X"] = true, ["-X"] = true }
		check(ARRIVALS[hatch.arrival] == true,
			("%s's hatch arrives over %q, which is not one of +Z/-Z/+X/-X; both position helpers fall through to \"+Z\" and the guard would be cut on a different lip from the one the truss stands against")
				:format(where, tostring(hatch.arrival)))

		-- INSIDE THE VOID. Flush against the arrival lip is correct and expected —
		-- that is what floorLadderAt is for — so this is containment with no
		-- margin, and it is the hatch's SIZE that has to hold the truss and the
		-- guard that runs round the other three sides of it.
		local trussInset = boxInsetBy(hatch.at, hatch.size, truss, ladderBox)
		check(trussInset >= 0,
			("%s's truss spans x %.1f..%.1f z %.1f..%.1f and hangs %.1f studs outside a hatch of %.1f x %.1f — it would climb into the underside of the deck")
				:format(where, truss.X - ladder.width / 2, truss.X + ladder.width / 2,
					truss.Z - ladder.width / 2, truss.Z + ladder.width / 2,
					-trussInset, hatch.size.X, hatch.size.Z))
		local guarded = ladder.width + 2 * floor.rail.thickness
		check(math.min(hatch.size.X, hatch.size.Z) >= guarded,
			("%s's hatch is %.1f x %.1f for a %.1f-stud truss inside a %.1f-stud guard, which needs %.1f")
				:format(where, hatch.size.X, hatch.size.Z, ladder.width,
					floor.rail.thickness, guarded))

		-- THE GUARD HAS TO BE OPEN WHERE YOU ARRIVE, and the gap and the truss have
		-- to be on the same lip: the guard closes three sides and `ladder.gate` is
		-- the opening cut in the fourth, centred on the hatch. If the truss were
		-- not inside that opening you would climb twenty-two studs into an
		-- invisible wall, which is the worst kind of geometry bug because there is
		-- nothing to see.
		--
		-- RE-AUTHORED: this used to bound the gap against the DECK's front run
		-- (`|ladder.at.X - deckAt.X| + gate/2 <= deckHalfX`), because that is the
		-- run it was cut in. The run it is cut in is the hatch guard now, so the
		-- bound is the hatch's own lip.
		local acrossLip = (hatch.arrival == "+X" or hatch.arrival == "-X")
			and hatch.size.Z or hatch.size.X
		local trussAcross = (hatch.arrival == "+X" or hatch.arrival == "-X")
			and math.abs(truss.Z - hatch.at.Z) or math.abs(truss.X - hatch.at.X)
		check(ladder.gate <= acrossLip,
			("%s's guard gap is %.1f studs cut in a %.1f-stud lip; it would run past the corner of the hatch and open the sides the guard is there to close")
				:format(where, ladder.gate, acrossLip))
		check(ladder.gate >= ladder.width + 2,
			("%s's guard gap is %.1f studs for a %.1f-stud truss; you would arrive against the jamb")
				:format(where, ladder.gate, ladder.width))
		check(trussAcross + ladder.width / 2 <= ladder.gate / 2,
			("%s's truss stands %.1f studs off the centre of a %.1f-stud gap; the gap is cut on the hatch's centre line, so the climb would end at the guard beside it")
				:format(where, trussAcross, ladder.gate))
		check(ladder.rise > 0,
			("%s's truss stops level with the deck; it has to overshoot to step off")
				:format(where))

		-- WHERE YOU STAND WHEN YOU STEP OFF has to be slab, not more hole.
		check(boxPointGap(hatch.at, hatch.size, landing) > 0,
			("%s's landing is at (%.1f, %.1f), inside its own hatch; you would step off the truss into the hole you climbed through")
				:format(where, landing.X, landing.Z))
		check(boxPointGap(deckAt, deck, landing) == 0,
			("%s's landing is at (%.1f, %.1f), off the deck entirely"):format(where, landing.X, landing.Z))

		-- THE HATCH INSIDE THE DECK, by the margin Config states. A hole in a slab
		-- needs slab round it, and the margin is what that slab is for: FloorService
		-- builds the deck in PIECES around this rectangle, the deck's perimeter
		-- guard stands on the outer edge and the hatch's guard on the inner one, and
		-- between the two there has to be a piece worth building and somewhere to
		-- stand on it. Six studs, which is the number the hatch's own comment gives
		-- and which is also what the perimeter guard would stand on if the deck ever
		-- pulled back from a wall.
		local HATCH_EDGE = 6
		local hatchInset = boxInsetBy(deckAt, deck, hatch.at, hatch.size)
		check(hatchInset >= HATCH_EDGE,
			("%s's hatch comes within %.1f studs of the edge of its own deck (need %d) — the slab is built in pieces around it, and a piece thinner than that is a strip you can see and cannot stand on")
				:format(where, hatchInset, HATCH_EDGE))

		-- CLEAR OF THE PRODUCTION LINE. The hatch is a hole in the floor the belt
		-- stands on: a leg over it is a conveyor over a void, and a machine or a
		-- buy button in it is one you cannot reach or cannot buy.
		--
		-- Two things this measures that the obvious version does not. The obstacle
		-- is the hatch PLUS ITS GUARD, which stands on the lip and so reaches half
		-- a rail thickness further out on every side — measuring the bare rectangle
		-- against the belt's running surface is what put the guard 0.1 studs inside
		-- the belt base while appearing to clear it by a stud. And each leg's
		-- machine row is placed on the side its `outboard` sign NAMES, not on a
		-- symmetric reach: the mezzanine's return leg carries its row on the armoury
		-- side, which is the side the stairwell is on, and a symmetric test would
		-- have reserved the empty side of it too.
		local guardSize = Vector3.new(hatch.size.X + floor.rail.thickness, 1,
			hatch.size.Z + floor.rail.thickness)
		for _, leg in ipairs(legs) do
			for _, strip in ipairs({
				{ "belt base", leg.belt },
				{ "machine row", leg.machines },
				{ "buy-button row", leg.buttons },
			}) do
				local box = strip[2]
				local into = boxBoxOverlap(hatch.at, guardSize, box.centre, box.size)
				check(into == 0,
					("%s's hatch and guard cut %.1f studs into the %s of belt leg %d (that row runs x %.1f..%.1f z %.1f..%.1f) — the hole in the slab is where the %s goes, and a row that is empty today is where the next machine bought on that leg lands")
						:format(where, into, strip[1], leg.index,
							box.centre.X - box.size.X / 2, box.centre.X + box.size.X / 2,
							box.centre.Z - box.size.Z / 2, box.centre.Z + box.size.Z / 2,
							strip[1]))
			end
		end

		-- ...AND OF THE HOPPER, by the number that names it. Measured from the
		-- LANDING — where the climb puts you down — which is what
		-- belt.ladderClearance has always been about.
		--
		-- RE-AUTHORED: the landing used to be `(ladder.at.X, deckAt.Z + deckHalfZ)`,
		-- the point on the deck's front edge, which was where you arrived while the
		-- deck stopped at z = -8. After the deck grew, that expression returns
		-- (14, 68): 34 studs from where the truss actually stands and 91 from the
		-- hopper. The check passed by construction rather than by measurement, which is
		-- the same failure as the `deckAt.Z + halfZ + 2 > deckAt.Z + halfZ` one this
		-- block already carried a note about — it just took a plausible number with it.
		-- Config.floorLandingAt is the derivation both sides read.
		local hopperGap = len(sub(path.collectorAt, landing))
		check(hopperGap >= floor.belt.ladderClearance,
			("%s's collector is %.1f studs from the landing at (%.1f, %.1f), where the truss puts you down (need %d)")
				:format(where, hopperGap, landing.X, landing.Z, floor.belt.ladderClearance))

		-- THE TRUSS IS THE ONE THING ON THIS PLOT THAT STANDS ON TWO STOREYS. It
		-- runs from the plot floor up through the void to `rise` above the deck, so
		-- it is the single exception to the same-floor rule the furniture block
		-- applies: it is checked against EVERY floor's furniture, not against one.
		-- Its predecessor was the one piece of floor furniture nothing checked at
		-- all — the ground teleport pad at (40, -14) interpenetrated the armour
		-- cabinet's slot-2 pedestal by 3x1 studs, latent only because the floor was
		-- behind a flag.
		--
		-- Note what is NOT asserted here, so nobody adds it later as a bound the
		-- geometry cannot satisfy: the HATCH is not required to clear the ground
		-- floor's misc-button spine, and the aisle position that was tried twice
		-- overlapped it by a stud and a half. A hole in a ceiling twenty-two studs
		-- above a pedestal collides with nothing. What occupies both storeys is the
		-- TRUSS inside the void, and the truss is what these loops measure — against
		-- the ground floor's pedestals, pads and vault, and against the deck's own
		-- cabinets, in one pass. Where it stands now it clears the vault shell by 18
		-- studs, the claim pad by 22 and the weapons cabinet by 33, which is what
		-- moving the stairwell off the aisle bought.
		inPlot(where .. "'s truss", truss, ladder.width / 2)
		for _, entry in ipairs(miscList) do
			furniturePairs += 1
			local gap = boxBoxGap(truss, ladderBox, entry.spot, PEDESTAL)
			check(gap >= FURNITURE_GAP,
				("%s's truss comes within %.1f studs of %s on the %s floor (need %d) — it passes through every storey")
					:format(where, gap, entry.id, entry.floor, FURNITURE_GAP))
		end
		for _, pad in ipairs(pads) do
			furniturePairs += 1
			local gap = boxBoxGap(truss, ladderBox, pad.spot, pad.size)
			check(gap >= FURNITURE_GAP,
				("%s's truss comes within %.1f studs of %s (need %d)")
					:format(where, gap, pad.id, FURNITURE_GAP))
			-- ...and neither does the hole it climbs through: you would drop out of
			-- the ceiling onto the pad you claim the plot on.
			furniturePairs += 1
			local hatchGap = boxBoxGap(hatch.at, hatch.size, pad.spot, pad.size)
			check(hatchGap >= FURNITURE_GAP,
				("%s's hatch is %.1f studs from %s directly below it (need %d)")
					:format(where, hatchGap, pad.id, FURNITURE_GAP))
		end
		for _, solid in ipairs(groundSolids) do
			furniturePairs += 2
			local trussGap = boxBoxGap(truss, ladderBox, solid.at, solid.size)
			check(trussGap >= FURNITURE_GAP,
				("%s's truss comes within %.1f studs of %s on the plot floor (need %d)")
					:format(where, trussGap, solid.id, FURNITURE_GAP))
			local hatchGap = boxBoxGap(hatch.at, hatch.size, solid.at, solid.size)
			check(hatchGap >= FURNITURE_GAP,
				("%s's hatch is %.1f studs from %s directly below it (need %d) — you would drop out of the ceiling onto it")
					:format(where, hatchGap, solid.id, FURNITURE_GAP))
		end
		for _, track in ipairs(Config.TrackOrder) do
			if L.Tracks[track] and placedTracks[track] then
				local cabinetAt, cabinetSize = Config.trackCabinet(track)
				furniturePairs += 1
				local gap = boxBoxGap(truss, ladderBox, cabinetAt, cabinetSize)
				check(gap >= FURNITURE_GAP,
					("%s's truss comes within %.1f studs of the %s cabinet (need %d)")
						:format(where, gap, track, FURNITURE_GAP))
			end
		end
	end

	-- THE DECK'S BELT STAYS ON THE DECK — legs, the machine row outboard of
	-- each leg, and the buy-button row inboard of it. Kept, and now the LOOSER of
	-- the two: the line-zone version above is the one that still catches
	-- `side = 10`. This one is what says the zone the belt lives in is on the slab
	-- rather than beside it.
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

	-- THE DECK AGAINST THE PLOT IT SITS IN. Its back edge is flush to the wall
	-- and it clears the roof columns by less than a stud; both sides are now
	-- named numbers, so moving either one is a build failure rather than a
	-- thing somebody notices in Studio.
	local wallInner = halfZ - 1
	check(deckAt.Z - deckHalfZ >= -wallInner,
		("%s's back edge is at z=%.1f and the wall's inner face is at z=%.1f — the deck would grow through the wall")
			:format(where, deckAt.Z - deckHalfZ, -wallInner))
	-- RE-AUTHORED, PREMISE OVERTURNED (see HANDOFF_v6 §3 for the convention).
	--
	-- This was `deckUnderside >= L.RoofY`: "the deck must stay clear of the
	-- roof". That was the right check for the design it was written against —
	-- the roof was a separate slab at its own literal height (20) with a shrink
	-- rule to dodge the deck (20.4), two pieces of geometry each derived on its
	-- own and each having to be kept out of the other's way, and 0.4 studs was
	-- all that separated them.
	--
	-- There is one structural line now. The deck's underside IS the ground
	-- storey's ceiling: Structure.Storeys[1].clear is derived from
	-- `height - deckSize.Y`, the walls stop there, and the roof sits on that same
	-- line until the deck takes it over. So the relationship to guard is no
	-- longer clearance, it is EQUALITY — the day someone types a literal into
	-- either side of it, the ground floor gets its band of daylight back.
	local deckUnderside = floor.height - deck.Y
	local groundStorey = Config.storey("ground") or Config.Structure.Storeys[1]
	check(math.abs(deckUnderside - (groundStorey.floorY + groundStorey.clear)) < 1e-9,
		("%s's underside is at y=%.2f but the ground storey's walls top out at y=%.2f — the deck IS that ceiling now, so anything but equality is either a gap above the wall or a wall built into the floor above it")
			:format(where, deckUnderside, groundStorey.floorY + groundStorey.clear))
	-- ...and the shortened roof it used to dodge is gone with it: with the deck
	-- up the roof is a full storey higher, over the upper walls, rather than a
	-- slab stopping two studs short of the deck's front edge. The old check here
	-- (`deckAt.Z + deckHalfZ + 2 > deckAt.Z + deckHalfZ`) was one of the ones
	-- that COULD NOT FAIL — x + 2 > x for every x.
	local upperStorey = Config.storey("upper") or Config.Structure.Storeys[2]
	local DECK_HEADROOM = 8   -- a humanoid is 5 studs and the deck carries a rail
	check(Config.roofUnderside(true) >= floor.height + DECK_HEADROOM,
		("%s: with the deck up the roof's underside is at y=%.1f, only %.1f studs over a deck at y=%.1f — the roof is a whole storey above the deck now, not a slab stopping two studs short of its front edge")
			:format(where, Config.roofUnderside(true), Config.roofUnderside(true) - floor.height, floor.height))
	check(math.abs(upperStorey.floorY - floor.height) < 1e-9,
		("%s: the deck's top is y=%.1f but the upper storey stands at y=%.1f — the storey above has to stand ON the deck")
			:format(where, floor.height, upperStorey.floorY))

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
-- THE DOORWAY'S WIDTH AND THE SLAB IT LANDS ON MOVED to the building-shell
-- block below, because the hole in the wall is now a row in
-- Config.Structure.Openings and this block was re-deriving it from Y.DoorFrom —
-- two copies of one span, either of which could move without the other. The
-- SPAN-not-a-point property is kept there, read off the `yardDoor` opening; what
-- stays here is the tie between the two, which is what the re-derivation was
-- silently standing in for.
local backOpenings = Config.openingsIn("back", "ground")
check(#backOpenings == 1,
	("the back wall's ground storey has %d openings; the yard door is the only thing that may be cut into it — the rest of that wall IS the dropper row")
		:format(#backOpenings))
local yardDoorLeft = backOpenings[1] and (backOpenings[1].centre - backOpenings[1].width / 2) or -math.huge
check(math.abs(yardDoorLeft - Y.DoorFrom) < 1e-9,
	("the back wall's opening starts at x=%.1f but the yard's own DoorFrom is %.1f — the hole in the wall and the slab it opens onto have drifted apart")
		:format(yardDoorLeft, Y.DoorFrom))

-- The gateway in the front wall has to open onto the aisle the player actually
-- walks, not onto the vault.
local gateLeft, gateRight = L.GateCentre - L.GateWidth / 2, L.GateCentre + L.GateWidth / 2
check(L.GateWidth >= 12, ("the front gateway is only %d studs wide"):format(L.GateWidth))
check(gateLeft > -halfX and gateRight < halfX,
	("the gateway spans x %.0f..%.0f, off the %d-stud front wall"):format(gateLeft, gateRight, halfX * 2))
check(L.OwnerSpawnAt.X > gateLeft and L.OwnerSpawnAt.X < gateRight,
	("the owner spawns at x=%.0f but the gateway is x %.0f..%.0f — they'd land behind a wall")
		:format(L.OwnerSpawnAt.X, gateLeft, gateRight))
-- THE GATEWAY-VERSUS-BELT CHECK MOVED to the building-shell block below, and now
-- reads the `gateway` row of Config.Structure.Openings instead of
-- GateCentre/GateWidth. Same inequality, same defect — but the opening inventory
-- is what the wall is built from now, so it is the thing that has to clear the
-- belt; reading the Layout keys it happens to be derived from today is one
-- indirection away from the geometry that actually ships.

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

-- ── the building shell ──────────────────────────────────────────────────────
--
-- THE DEFECT THIS FAMILY EXISTS FOR. The walls were five boxes emitted by
-- INSTALLERS.Structure at a local literal `h = 13`, while the roof's underside
-- was Layout.RoofY = 20. Every plot in the game therefore had a SEVEN-STUD OPEN
-- BAND all the way round it, above the wall and below the roof — and not one of
-- the 2309 checks that ran before this round looked at wall height, at wall
-- thickness, or at what the openings in the ring were. The two deliberate holes
-- were checked as x-spans on the FLOOR; nothing above y = 0 was asserted at all.
--
-- So the first check below is the one that band needed — a wall must ACCOUNT FOR
-- ITS WHOLE SPAN — and the second is the same question vertically: a storey's
-- wall stops exactly at the floor above it. A wall that ends 0.8 studs INSIDE
-- the deck above it is as wrong as one that ends seven studs short of it, and
-- neither was visible from here.
--
-- Everything is scalar and component-wise, because the Vector3 in this harness
-- is a bare table with no arithmetic (see the stubs at the top of the file).

local SH = Config.Structure
local WIN = SH.Window
local ROOF = SH.Roof
local EPS = 1e-9

local function openingById(id)
	for _, opening in ipairs(SH.Openings) do
		if opening.id == id then
			return opening
		end
	end
	return nil
end

local lightReport = nil

-- ── the light in an enclosed storey ─────────────────────────────────────────
--
-- NEW. TODO.md item 1, and HANDOFF_v7 §5 listed it first: the mezzanine deck
-- spans wall face to wall face and Lighting.Ambient is black, so from the minute
-- the storey lands the ground floor has no sky and nothing but buy-button pads
-- to see by. Nothing in this file has ever looked at light, because until #58
-- there was nothing enclosed to look at.
--
-- The verifier cannot see a room. What it can see is whether the fixtures are
-- inside it, clear of what stands in it, above what walks under them, and
-- numerous enough to reach the corners — which is every way this can be wrong
-- except "does it look right", and that one is on the Studio list.
do
	local LIGHT = SH.Lights
	local halfX = Config.World.PlotSize.X / 2 - 1 - SH.WallThickness / 2
	local halfZ = Config.World.PlotSize.Z / 2 - 1 - SH.WallThickness / 2

	check(LIGHT.columns >= 1 and LIGHT.rows >= 1,
		("Structure.Lights is a %dx%d grid; a storey with no fixtures is a black box, and Ambient is (0,0,0)")
			:format(LIGHT.columns, LIGHT.rows))
	-- ROBLOX SILENTLY CLAMPS Range AT 60. A number above it reads as set in the
	-- source, is not set at runtime, and nothing anywhere reports the
	-- difference.
	check(LIGHT.range > 0 and LIGHT.range <= 60,
		("Structure.Lights.range is %.0f; Roblox clamps a light's Range at 60 and says nothing, so anything above it is a number that reads as set and is not")
			:format(LIGHT.range))
	check(LIGHT.brightness > 0,
		"Structure.Lights.brightness is 0 — the fixtures would be built, counted against the part budget, and light nothing")

	local fixtureCount = 0
	for _, storey in ipairs(SH.Storeys) do
		local spots = Config.storeyLightPositions(storey.id)
		check(#spots == LIGHT.columns * LIGHT.rows,
			("%s hangs %d fixtures for a %dx%d grid"):format(storey.id, #spots, LIGHT.columns, LIGHT.rows))

		for index, spot in ipairs(spots) do
			fixtureCount += 1
			local where = ("the %s storey's fixture %d at (%.0f, %.0f)"):format(storey.id, index, spot.X, spot.Z)

			-- INSIDE THE ROOM. A fixture in a wall is a fixture inside solid
			-- geometry, lighting the outside of the building.
			check(math.abs(spot.X) + LIGHT.batten.width / 2 <= halfX - 1,
				("%s spans x %.1f..%.1f against an inner wall face at %.1f")
					:format(where, spot.X - LIGHT.batten.width / 2, spot.X + LIGHT.batten.width / 2, halfX))
			check(math.abs(spot.Z) + LIGHT.batten.length / 2 <= halfZ - 1,
				("%s spans z %.1f..%.1f against an inner wall face at %.1f")
					:format(where, spot.Z - LIGHT.batten.length / 2, spot.Z + LIGHT.batten.length / 2, halfZ))

			-- ABOVE EVERYTHING THAT STANDS UNDER IT. The tightest pair on the
			-- plot is a cabinet's sign, which reaches 17.5 above its own floor.
			local clear = spot.Y - LIGHT.batten.thickness / 2 - storey.floorY
			check(clear > L.MachineTopY,
				("%s hangs %.1f above its own floor; a dropper's arm reaches %.1f")
					:format(where, clear, L.MachineTopY))
			check(clear > 17.5,
				("%s hangs %.1f above its own floor and a cabinet's sign reaches 17.5 — the fixture would be inside the billboard")
					:format(where, clear))

			-- ...AND CLEAR OF WHAT IT HANGS OVER, in plan. This is the check
			-- that CHOOSES `inset`: at 24 the +X column lands on the armoury.
			local batten = Vector3.new(LIGHT.batten.width, 1, LIGHT.batten.length)
			for _, track in ipairs(Config.TrackOrder) do
				local layout = L.Tracks[track]
				if layout and (layout.floor or GROUND) == (storey.id == "ground" and GROUND or layout.floor) then
					local centre, size = Config.trackCabinet(track)
					local gap = boxBoxGap(spot, batten, centre, size)
					check(gap >= 2,
						("%s is %.1f studs from the %s cabinet in plan (need 2) — the case is 13 tall and the fixture is on the ceiling above it")
							:format(where, gap, track))
				end
			end
		end
	end

	-- ENOUGH OF THEM TO REACH THE CORNERS. Sampled on a grid rather than
	-- reasoned about, because "the fixtures are inside the room" says nothing
	-- about the room being lit — drop `rows` to 2 and the back of the plot goes
	-- dark with every check above still passing.
	local worst, worstAt = 0, nil
	local ground = Config.storey("ground")
	local spots = Config.storeyLightPositions("ground")
	local x = -halfX
	while x <= halfX do
		local z = -halfZ
		while z <= halfZ do
			local nearest = math.huge
			for _, spot in ipairs(spots) do
				local dx, dz = spot.X - x, spot.Z - z
				local dy = spot.Y - ground.floorY
				local d = math.sqrt(dx * dx + dz * dz + dy * dy)
				nearest = math.min(nearest, d)
			end
			if nearest > worst then
				worst, worstAt = nearest, Vector3.new(x, 0, z)
			end
			z += 4
		end
		x += 4
	end
	check(worst <= LIGHT.range * 0.8,
		("the darkest spot on the ground storey is (%.0f, %.0f), %.1f studs from its nearest fixture, against a range of %.0f — a light's falloff is not a cliff, so 80%% of range is where a corner stops reading as lit")
			:format(worstAt and worstAt.X or 0, worstAt and worstAt.Z or 0, worst, LIGHT.range))

	lightReport = ("lighting:          %d fixtures over %d storeys, darkest floor sample %.0f studs from one (range %d)")
		:format(fixtureCount, #SH.Storeys, worst, LIGHT.range)
end

-- ── the shell is FOUR purchases, in one order ───────────────────────────────
--
-- walls, then gates, then windows, then roof. The loader derives the chain from
-- table order — which means the ordering is real but nothing states it, and
-- INVARIANTS.md's "table order IS dependency order" is marked [nothing] for
-- exactly this reason. Moving a row is the way to get it wrong and no check
-- refuses it.
--
-- SCANNED OVER Config.Buttons, NOT OVER ONE TRACK. This block read
-- Config.Tracks.factory, which was true when the shell was welded into the
-- spine and became four loud failures the moment it moved to its own track.
-- The thing it is actually about is "some button, somewhere, builds this piece
-- of the building, and it is bought after the piece it hangs on" — neither half
-- of which is a statement about which ladder they live on. Written this way it
-- survives the next move too.
--
-- The comparison key is `order`, the GLOBAL merge index, rather than
-- `trackOrder`. On one track the two agree; across tracks only `order` is
-- comparable, and using the per-track index here would have compared a step
-- number against a different track's step number and called it an ordering.
--
-- These are those checks. Each names what the parts would be standing on.
local structureOrder = {}
for _, def in ipairs(Config.Buttons) do
	if def.kind == "Structure" then
		check(structureOrder[def.structure] == nil,
			("two buttons build %q; INSTALLERS.Structure is not idempotent and the second one would build the piece again on top of the first")
				:format(tostring(def.structure)))
		structureOrder[def.structure] = def.order
	end
end
-- ROOF NEEDS WALLS, AND THAT PAIR WAS NEVER ASSERTED. buildRoofModel derives
-- its column positions from Config.wallExtent, so a roof with no wall under it
-- is four columns and a slab standing in a field. It was unfalsifiable while
-- both lived on one chain in a fixed order; on a track of its own the roof is
-- the last rung precisely so that this holds, and now something says so.
for _, needs in ipairs({ { "gates", "walls" }, { "windows", "walls" }, { "roof", "walls" } }) do
	local later, earlier = needs[1], needs[2]
	check(structureOrder[later] ~= nil,
		("no button anywhere builds %q; INSTALLERS.Structure has a case for it that can never run"):format(later))
	check(structureOrder[earlier] ~= nil,
		("no button anywhere builds %q"):format(earlier))
	if structureOrder[later] and structureOrder[earlier] then
		check(structureOrder[later] > structureOrder[earlier],
			("%q is button %d and %q is button %d — %s is hung on the wall ring, so buying it first is parts attached to a building that is not there yet")
				:format(later, structureOrder[later], earlier, structureOrder[earlier], later))
	end
end

-- ...AND EVERY LEAF IS PAID FOR. An opening declares how many leaves it has and
-- INSTALLERS.Structure hangs them from the `gates` purchase. Declare an opening
-- with leaves and no gates button and the gateway is a hole forever, with the
-- wall's own segment check still passing because the hole is exactly the shape
-- the wall says it should be.
do
	local leaves = 0
	for _, opening in ipairs(SH.Openings) do
		leaves += opening.leaves or 0
	end
	check(leaves == 0 or structureOrder.gates ~= nil,
		("Structure.Openings declares %d gate leaves and no button builds them; every opening would stay a hole and the wall spans would still tile perfectly")
			:format(leaves))
end

--- An axis-aligned box for a span of one wall, in plan: `extent.axis` is the
--- axis the wall RUNS along, so the other axis carries its thickness.
local function wallSpanBox(extent, from, to)
	if extent.axis == "X" then
		return Vector3.new((from + to) / 2, 0, extent.fixed),
			Vector3.new(to - from, 1, SH.WallThickness)
	end
	return Vector3.new(extent.fixed, 0, (from + to) / 2),
		Vector3.new(SH.WallThickness, 1, to - from)
end

-- THE RING IS FOUR WALLS, and Structure.Sides is the list every loop below runs
-- over — including the builder's. A side missing from it is a wall that is
-- simply never emitted, which on a plot that is meant to be enclosed is the
-- seven-stud band again with a different shape. Validated once here, so a side
-- naming a wall that does not exist is reported rather than crashing the four
-- loops after it.
local sides = {}
for _, side in ipairs(SH.Sides) do
	local extent = Config.wallExtent(side)
	check(extent ~= nil, ("Structure.Sides names %q but wallExtent has no such wall"):format(tostring(side)))
	if extent then
		table.insert(sides, { id = side, extent = extent })
	end
end
for _, wall in ipairs({ "back", "front", "left", "right" }) do
	local found = 0
	for _, side in ipairs(sides) do
		if side.id == wall then
			found += 1
		end
	end
	check(found == 1,
		("Structure.Sides names the %s wall %d times; the ring is four walls and a side missing from that list is a wall nothing builds")
			:format(wall, found))
end

-- 1. SPAN ACCOUNTING — THE CHECK THE SEVEN-STUD BAND NEEDED.
--
-- Config.wallSegments is what the builder emits from, so summing it here is the
-- difference between "the wall covers its own span" being an assertion and being
-- a hope. Contiguity, no gap, no overlap, and the widths summing to the extent:
-- the same three ways a hand-rolled loop of five boxes gets a wall wrong.
for _, side in ipairs(sides) do
	local extent = side.extent
	check(extent.to > extent.from,
		("the %s wall runs %.1f..%.1f, which is not an extent"):format(side.id, extent.from, extent.to))
	check(extent.outward == 1 or extent.outward == -1,
		("the %s wall's outward is %s; it must be 1 or -1 or that side of the ring faces inward")
			:format(side.id, tostring(extent.outward)))

	for _, storey in ipairs(SH.Storeys) do
		local segments = Config.wallSegments(side.id, storey.id)
		local where = ("the %s wall's %s storey"):format(side.id, storey.id)
		check(#segments > 0, ("%s has no segments at all — that wall would not be built"):format(where))

		local cursor, covered = extent.from, 0
		for index, segment in ipairs(segments) do
			check(math.abs(segment.from - cursor) < EPS,
				("%s: segment %d starts at %.2f but the span before it ended at %.2f — a wall that does not account for its whole extent is exactly the seven-stud band of daylight that shipped round every plot, and this is the check it needed")
					:format(where, index, segment.from, cursor))
			check(segment.to > segment.from,
				("%s: segment %d spans %.2f..%.2f, which is not a piece of wall"):format(where, index, segment.from, segment.to))
			covered += segment.to - segment.from
			cursor = segment.to
		end
		check(math.abs(cursor - extent.to) < EPS,
			("%s: the last segment ends at %.2f but the wall runs to %.2f — the rest of that wall is open air")
				:format(where, cursor, extent.to))
		check(math.abs(covered - (extent.to - extent.from)) < EPS,
			("%s: its segments sum to %.2f studs across a %.2f-stud extent — they either overlap or leave a gap")
				:format(where, covered, extent.to - extent.from))
	end
end

-- 2. THE WALL MEETS THE FLOOR ABOVE IT.
--
-- One structural line: a storey's ceiling is the floor above it. The ground
-- storey's `clear` is derived from the mezzanine deck's UNDERSIDE — a full deck
-- thickness below its top, not half of one — and getting that wrong by 0.8
-- studs is a wall built into the floor above it, which is the same class of
-- defect as the band and just as invisible.
check(Config.storey("ground") ~= nil and Config.storey("upper") ~= nil,
	"Config.storey cannot find `ground` and `upper` — those two ids are how every consumer of the shell asks for a storey, so a renamed one is a storey nothing can look up")
local groundStorey = Config.storey("ground") or SH.Storeys[1]
local upperStorey = Config.storey("upper") or SH.Storeys[2]
local groundClear = groundStorey.clear
local mezz = Config.Floors[1]

check(math.abs(groundClear - (mezz.height - mezz.deckSize.Y)) < EPS,
	("the ground storey's clear height is %.2f but the mezzanine deck's underside is at %.2f (top %.1f less a %.1f-stud slab) — the wall has to stop exactly there: short of it is open band, past it is a wall inside the floor above")
		:format(groundClear, mezz.height - mezz.deckSize.Y, mezz.height, mezz.deckSize.Y))

for index, storey in ipairs(SH.Storeys) do
	local above = SH.Storeys[index + 1]
	local top = storey.floorY + storey.clear
	check(storey.clear > 0, ("Storeys[%d] (%s) has no clear height"):format(index, tostring(storey.id)))
	if above then
		-- Floors[index] is the deck that IS the floor of Storeys[index + 1].
		local deck = Config.Floors[index]
		local thickness = deck and deck.deckSize.Y or 0
		check(math.abs(top - (above.floorY - thickness)) < EPS,
			("the %s storey's wall tops out at y=%.2f but the %s storey's floor starts at y=%.2f (its slab spans %.2f..%.2f) — the wall must meet the underside of the deck above it, to the stud")
				:format(storey.id, top, above.id, above.floorY - thickness, above.floorY - thickness, above.floorY))
	end
end

-- 3. AN OPENING IS A DOORWAY, NOT A HOLE IN THE SIDE OF THE BUILDING.
--
-- Eight clear studs is a humanoid plus its hitbox plus the jamb it does not want
-- to catch on; the gateway is 22 and the yard doorway 13. And an opening has to
-- be IN its wall: a hole cut past the end of an extent is a hole in nothing,
-- and wallSegments would silently emit it as the whole wall.
local MIN_OPENING = 8
for _, opening in ipairs(SH.Openings) do
	local where = ("the %s opening"):format(tostring(opening.id))
	local extent = Config.wallExtent(opening.side)
	local storey = Config.storey(opening.storey)
	check(extent ~= nil, ("%s is in wall %q, which is not one of the four"):format(where, tostring(opening.side)))
	check(storey ~= nil, ("%s is on storey %q, which does not exist"):format(where, tostring(opening.storey)))

	check(opening.width >= MIN_OPENING,
		("%s is %.1f studs of clear width; a humanoid plus its hitbox needs %d and anything less is a doorway you get stuck in")
			:format(where, opening.width, MIN_OPENING))

	if extent then
		local from, to = opening.centre - opening.width / 2, opening.centre + opening.width / 2
		check(from >= extent.from - EPS and to <= extent.to + EPS,
			("%s spans %.1f..%.1f but the %s wall runs %.1f..%.1f — an opening outside its own wall is a hole in nothing")
				:format(where, from, to, opening.side, extent.from, extent.to))
	end
	if storey then
		check(opening.height < storey.clear,
			("%s is %.1f studs tall in a storey with %.2f of clear height — an opening as tall as its storey leaves no lintel course above it")
				:format(where, opening.height, storey.clear))
	end
end

-- 4. THE GATEWAY STILL CLEARS THE BELT.
--
-- This inequality used to live in the yard block, read off GateCentre/GateWidth.
-- It reads the opening inventory now, because that is what the wall is built
-- from: the Layout keys are one indirection away from the geometry that ships.
local gateway = openingById("gateway")
check(gateway ~= nil, "Structure.Openings has no `gateway` — the front wall would be solid")
if gateway then
	local left = gateway.centre - gateway.width / 2
	check(left > L.BeltEnd.X + L.BeltWidth / 2,
		("the gateway starts at x=%.0f, over the belt/vault side of the plot (the belt's edge is x=%.0f)")
			:format(left, L.BeltEnd.X + L.BeltWidth / 2))
end

-- 5. THE YARD DOORWAY STILL LANDS OVER THE YARD SLAB — AS A SPAN, NOT A POINT.
--
-- A 28-stud corner slab can sit entirely clear of the door it is reached through
-- while its left jamb still tests fine, and you would step out of the back wall
-- onto grass. Derived from the `yardDoor` opening now rather than re-derived from
-- Yard.DoorFrom beside the slab it has to match.
local yardDoor = openingById("yardDoor")
check(yardDoor ~= nil, "Structure.Openings has no `yardDoor` — the generator yard would be unreachable")
if yardDoor then
	local from, to = yardDoor.centre - yardDoor.width / 2, yardDoor.centre + yardDoor.width / 2
	check(Y.Centre.X - yardHalfX <= from + EPS and Y.Centre.X + yardHalfX >= to - EPS,
		("the doorway spans x %.0f..%.0f but the yard slab spans %.0f..%.0f; you would step out of the back wall onto grass")
			:format(from, to, Y.Centre.X - yardHalfX, Y.Centre.X + yardHalfX))
end

-- 6. WINDOW BAYS.
--
-- A solid run is three courses: sill, bay, head. The bay course is alternating
-- piers and panes and it has to tile its run the same way the run tiles the
-- wall — the slack goes to the piers, deliberately, so a run that does not
-- divide evenly still comes out centred instead of dumping the remainder on the
-- last pier.
--
-- AND THE TRANSPARENCY IS LOAD-BEARING. Roblox's PopperCam only treats a part as
-- occluding when `Transparency < 0.25 and CanCollide`, so under that number
-- every pane becomes a thing the camera shoves itself through — on a plot that
-- is now fully enclosed, which is the whole reason glass appears in this round.
check(WIN.transparency >= 0.25,
	("Window.transparency is %.2f; PopperCam only occludes on Transparency < 0.25 and CanCollide, so anything under 0.25 turns every pane into a hole the camera pushes itself through on a plot that is now enclosed")
		:format(WIN.transparency))
check(WIN.pane > 0 and WIN.pier > 0,
	"Window.pane and Window.pier both have to be positive; a zero pier is a run of glass with nothing holding it up")

for _, courseId in ipairs({ "ground", "upper" }) do
	local course = WIN[courseId]
	local storey = Config.storey(courseId)
	check(course ~= nil and storey ~= nil, ("Window has no bay course for the %s storey"):format(courseId))
	if course and storey then
		check(course.sill > 0 and course.height > 0,
			("the %s bay course has sill %.1f and height %.1f; both have to be positive"):format(courseId, course.sill, course.height))
		check(course.sill + course.height + 2 <= storey.clear,
			("the %s storey's bay course runs y %.1f..%.1f inside %.2f studs of clear height — a head course needs at least 2 studs above the glass, or the window IS the top of the wall")
				:format(courseId, course.sill, course.sill + course.height, storey.clear))
	end
end

for _, side in ipairs(sides) do
	for _, storey in ipairs(SH.Storeys) do
		for _, segment in ipairs(Config.wallSegments(side.id, storey.id)) do
			if segment.kind == "solid" then
				local where = ("the %s wall's %s storey, run %.1f..%.1f"):format(side.id, storey.id, segment.from, segment.to)
				local bays = Config.wallBays(segment.from, segment.to)
				check(#bays > 0, ("%s has no bays; the run would be built as nothing"):format(where))

				local cursor, covered = segment.from, 0
				for index, bay in ipairs(bays) do
					check(math.abs(bay.from - cursor) < EPS,
						("%s: bay %d starts at %.2f but the bay before it ended at %.2f — the bay course has to tile its run, or the gap between two piers is a hole in the wall at eye height")
							:format(where, index, bay.from, cursor))
					if bay.kind == "pane" then
						check(bay.to - bay.from >= WIN.pane - EPS,
							("%s: a pane of %.2f studs against a %.1f-stud spec — the slack in a run goes to the PIERS, never to the glass")
								:format(where, bay.to - bay.from, WIN.pane))
					end
					covered += bay.to - bay.from
					cursor = bay.to
				end
				check(math.abs(cursor - segment.to) < EPS,
					("%s: its bays end at %.2f, short of the run"):format(where, cursor))
				check(math.abs(covered - (segment.to - segment.from)) < EPS,
					("%s: its bays sum to %.2f studs across a %.2f-stud run"):format(where, covered, segment.to - segment.from))
			end
		end
	end
end

-- 7. NO PANE WHERE SOMETHING ALREADY IS.
--
-- Glass is the first thing this game has ever put in the wall ring at machine
-- height, and the plot floor is crowded right up to the walls: the dropper row
-- stands 1.5 studs off the back wall's inner face and the armour cabinet 2 studs
-- off the right wall's. Both of those are FINE and both are within a couple of
-- studs of failing, which is the reason to assert them rather than eyeball them.
--
-- Measured with the box helpers, so overlap along the wall reduces to the
-- separation across it — which is the only number that matters for something
-- standing in front of glass.
local PANE_STANDOFF = 1    -- studs between a pane and anything standing at it
local PANE_JAMB = 2        -- solid wall between a pane and an opening's edge

-- The ground floor's machine rows, as a band per leg: from the belt centre line
-- out to the far face of the machines standing outboard of it.
local groundPath = Config.BeltPaths[1]
local machineReach = L.MachineOffset + L.MachineFootprint / 2
local obstacles = {}
for index = 1, #groundPath.points - 1 do
	local a, b = groundPath.points[index], groundPath.points[index + 1]
	local sign = groundPath.outboard[index] or 1
	local alongX = math.abs(a.Z - b.Z) < EPS
	local alongZ = math.abs(a.X - b.X) < EPS
	check(alongX or alongZ,
		("the ground belt's leg %d is diagonal; the machine row this block models assumes an axis-aligned leg and would measure the wrong band")
			:format(index))
	if alongX then
		local normalZ = ((b.X > a.X) and 1 or -1) * sign
		table.insert(obstacles, {
			label = ("the machine row outboard of belt leg %d"):format(index),
			centre = Vector3.new((a.X + b.X) / 2, 0, a.Z + normalZ * machineReach / 2),
			size = Vector3.new(math.abs(b.X - a.X), 1, machineReach),
		})
	elseif alongZ then
		local normalX = -((b.Z > a.Z) and 1 or -1) * sign
		table.insert(obstacles, {
			label = ("the machine row outboard of belt leg %d"):format(index),
			centre = Vector3.new(a.X + normalX * machineReach / 2, 0, (a.Z + b.Z) / 2),
			size = Vector3.new(machineReach, 1, math.abs(b.Z - a.Z)),
		})
	end
end
for _, track in ipairs(Config.TrackOrder) do
	if L.Tracks[track] and placedTracks[track] then
		local centre, size = Config.trackCabinet(track)
		table.insert(obstacles, { label = ("the %s cabinet"):format(track), centre = centre, size = size })
	end
end

for _, side in ipairs(sides) do
	local extent = side.extent
	local openings = Config.openingsIn(side.id, "ground")
	for _, segment in ipairs(Config.wallSegments(side.id, "ground")) do
		if segment.kind == "solid" then
			for _, bay in ipairs(Config.wallBays(segment.from, segment.to)) do
				if bay.kind == "pane" then
					local where = ("the %s wall's ground pane at %.1f..%.1f"):format(side.id, bay.from, bay.to)

					for _, opening in ipairs(openings) do
						local from, to = opening.centre - opening.width / 2, opening.centre + opening.width / 2
						local gap = math.max(from - bay.to, bay.from - to)
						check(gap >= PANE_JAMB,
							("%s is %.1f studs from the %s opening (need %d) — a gate closes against solid wall, not against the edge of a window")
								:format(where, gap, tostring(opening.id), PANE_JAMB))
					end

					local paneCentre, paneSize = wallSpanBox(extent, bay.from, bay.to)
					for _, obstacle in ipairs(obstacles) do
						local gap = boxBoxGap(paneCentre, paneSize, obstacle.centre, obstacle.size)
						check(gap >= PANE_STANDOFF,
							("%s comes within %.1f studs of %s (need %d) — that is a window with a machine growing through it")
								:format(where, gap, obstacle.label, PANE_STANDOFF))
					end
				end
			end
		end
	end
end

-- 8. GATE LEAVES FIT, AND FIT SOMEWHERE TO SLIDE.
--
-- A leaf slides along the inside face of the wall and its travel is one leaf
-- width, so the solid run beside the opening has to be at least that long — a
-- leaf that needs more run than the wall has slides out past the end of the
-- building. Two leaves means both sides; one leaf means the side it slides
-- toward, and this says which side that has to be rather than assuming it.
for _, opening in ipairs(SH.Openings) do
	local where = ("the %s opening"):format(tostring(opening.id))
	local leaves = opening.leaves
	local leafWidth = opening.width / leaves
	check(leaves >= 1 and leaves == math.floor(leaves) and math.abs(leaves * leafWidth - opening.width) < EPS,
		("%s has %s leaves of %.2f studs across a %.1f-stud opening — a leaf count has to be a whole number and the leaves have to sum to the opening, or a closed gate has a gap down the middle of it")
			:format(where, tostring(leaves), leafWidth, opening.width))

	local before, after = 0, 0
	-- guarded: an opening naming a wall that does not exist is reported by the
	-- inventory checks above, and wallSegments has nothing to return for it
	for _, segment in ipairs(Config.wallExtent(opening.side)
			and Config.wallSegments(opening.side, opening.storey) or {}) do
		if segment.kind == "solid" then
			if segment.to <= opening.centre then
				before = math.max(before, segment.to - segment.from)
			else
				after = math.max(after, segment.to - segment.from)
			end
		end
	end
	if leaves >= 2 then
		check(before >= leafWidth and after >= leafWidth,
			("%s: a %.1f-stud leaf slides each way but the solid runs beside it are %.1f and %.1f studs — a leaf whose travel is longer than the wall beside it slides out past the end of the building")
				:format(where, leafWidth, before, after))
	else
		check(math.max(before, after) >= leafWidth,
			("%s: its single %.1f-stud leaf has %.1f studs of wall on one side and %.1f on the other, and needs a run of %.1f to slide into — it must slide toward the longer one")
				:format(where, leafWidth, before, after, leafWidth))
	end

	-- WHICH FACE THE LEAVES HANG ON, AND WHY THAT IS NOT COSMETIC.
	--
	-- This assertion exists because the shipped numbers failed it. The yard door
	-- is flush to the end of the back wall, so its single leaf can only slide
	-- inward along x — and the inside of the back wall IS the dropper row. An
	-- inboard leaf swept 0.1 studs THROUGH dropper slot 1. It hangs outboard now,
	-- over the generator yard's own slab, and `opening.face` is the field that
	-- says so.
	--
	-- The band a leaf sweeps is measured off the wall's face, not its centre
	-- plane: half the wall, the stated air gap, then the leaf's own thickness.
	check(opening.face == "inboard" or opening.face == "outboard",
		("%s has face %q; a leaf hangs on one side of the wall or the other, and which one is not a default")
			:format(where, tostring(opening.face)))
	if opening.face == "inboard" then
		local extent = Config.wallExtent(opening.side)
		local near = SH.WallThickness / 2 + SH.Gate.inset
		local far = near + SH.Gate.thickness
		-- The machine row that stands along this wall, if one does: the droppers
		-- run outboard of belt leg 1 (the back edge) and the upgraders outboard
		-- of leg 2 (the left edge), MachineOffset out with a footprint either
		-- side of that.
		local ground = Config.BeltPaths[1]
		for legIndex = 1, 2 do
			local a, b = ground.points[legIndex], ground.points[legIndex + 1]
			if a and b and extent then
				local legAxis = (math.abs(a.X - b.X) > math.abs(a.Z - b.Z)) and "X" or "Z"
				-- only a leg parallel to this wall can be swept along
				if legAxis == extent.axis then
					local legCross = (extent.axis == "X") and a.Z or a.X
					-- The machine's face TOWARD the wall: MachineOffset outboard
					-- of the belt, then half a footprint further out again. Half a
					-- footprint the other way is the face toward the plot centre,
					-- which is 5 studs of slack and would have made this check
					-- pass on the very geometry it was written for.
					local machineNear = math.abs(legCross + extent.outward
						* (L.MachineOffset + L.MachineFootprint / 2) - extent.fixed)
					check(machineNear >= far,
						("%s: an inboard leaf sweeps %.2f..%.2f studs off the %s wall's centre plane, and the machine row on belt leg %d starts %.2f studs off it — the leaf would pass through a machine")
							:format(where, near, far, opening.side, legIndex, machineNear))
				end
			end
		end
	end
end

-- 9. THE PART BUDGET, WHICH HANDOFF_v5 §4 HAS LISTED AS UNTESTED FOR THREE
-- ROUNDS. The shell was about ten parts; windows, lintels and gate leaves take
-- it to over a hundred, times ten plots, and this is the first change big enough
-- that guessing is not good enough. Asserted at the FULL build — both storeys —
-- and printed in the report block at the bottom of this file, because the number
-- itself wants reading every time the window spec moves.
-- Skipped, not faked, if the ring above did not resolve to four walls:
-- shellPartCount walks Structure.Sides itself and cannot count a side that names
-- no wall. The Sides checks at the top of this block are what report that.
local ringResolved = #sides == 4 and #SH.Sides == 4
local shellParts = ringResolved and Config.shellPartCount(true) or 0
local shellPartsGround = ringResolved and Config.shellPartCount(false) or 0
if ringResolved then
	check(shellParts <= SH.PartBudget,
		("one plot's shell is %d parts against a PartBudget of %d — at %d plots that is %d parts of building before a single machine is bought")
			:format(shellParts, SH.PartBudget, Config.World.MaxPlots, shellParts * Config.World.MaxPlots))
	check(shellPartsGround < shellParts,
		("the shell costs %d parts with the mezzanine storey and %d without; the upper storey has to cost something or shellPartCount is not modelling it")
			:format(shellParts, shellPartsGround))
end

-- 10. THE ROOF, WHICH IS NOW A CONSEQUENCE RATHER THAN A NUMBER.
--
-- It sits on the top storey that exists — the ground storey's line before the
-- mezzanine is bought, the upper storey's after — so there is no half-roof state
-- and no shrink rule. The old arrangement was a literal 20 next to a deck
-- underside of 20.4, which is how the band got in.
check(math.abs(Config.roofUnderside(false) - (groundStorey.floorY + groundStorey.clear)) < EPS,
	("roofUnderside(false) is %.2f but the ground storey tops out at %.2f — with no mezzanine the roof IS that ceiling")
		:format(Config.roofUnderside(false), groundStorey.floorY + groundStorey.clear))
check(math.abs(Config.roofUnderside(true) - (upperStorey.floorY + upperStorey.clear)) < EPS,
	("roofUnderside(true) is %.2f but the upper storey tops out at %.2f — with the mezzanine up the roof sits on the upper walls")
		:format(Config.roofUnderside(true), upperStorey.floorY + upperStorey.clear))

-- THE COMPANY SIGN, above the roof's top face by Roof.signLift. The billboard is
-- 12 studs tall and centred on its anchor, so a lift under half of that puts its
-- lower half inside the slab it is standing on — and a BillboardGui that is not
-- AlwaysOnTop is occluded by exactly that. The 12 is mirrored from
-- Installers.lua's `Style.billboard{ height = 12 }`, which is the one number in
-- this family that is not in Config; see the report.
local ROOF_SIGN_HEIGHT = 12
for _, hasFloor in ipairs({ false, true }) do
	local roofTop = Config.roofUnderside(hasFloor) + ROOF.thickness
	local signY = roofTop + ROOF.signLift
	check(signY - ROOF_SIGN_HEIGHT / 2 >= roofTop,
		("the company sign hangs at y=%.1f over a roof whose top face is y=%.1f (%s the mezzanine); a %d-stud billboard centred there has its lower %.1f studs inside the slab, and a billboard that is not AlwaysOnTop is occluded by the part in front of it")
			:format(signY, roofTop, hasFloor and "with" or "without", ROOF_SIGN_HEIGHT,
				roofTop - (signY - ROOF_SIGN_HEIGHT / 2)))
end

-- THE FOUR COLUMNS. They stand `columnInset` in from the wall ring, which has to
-- put them INSIDE it — a column in the wall is a column you cannot see and a
-- wall segment you cannot build — and clear of the machine rows they stand
-- among. roofColumnX/Z are the numbers the cabinet block above models, derived
-- from Roof.columnInset in one place so the two cannot drift.
local wallInnerX = halfX - 1 - SH.WallThickness / 2
local wallInnerZ = halfZ - 1 - SH.WallThickness / 2
check(roofColumnX + ROOF.column / 2 <= wallInnerX,
	("the roof columns reach x=%.1f but the wall ring's inner face is x=%.1f — a column inside the wall is a column nobody can see, in a wall segment nobody can build")
		:format(roofColumnX + ROOF.column / 2, wallInnerX))
check(roofColumnZ + ROOF.column / 2 <= wallInnerZ,
	("the roof columns reach z=%.1f but the wall ring's inner face is z=%.1f — a column inside the wall is a column nobody can see, in a wall segment nobody can build")
		:format(roofColumnZ + ROOF.column / 2, wallInnerZ))
local COLUMN_CLEAR = 2
for _, sx in ipairs({ -1, 1 }) do
	for _, sz in ipairs({ -1, 1 }) do
		local at = Vector3.new(sx * roofColumnX, 0, sz * roofColumnZ)
		local columnSize = Vector3.new(ROOF.column, 1, ROOF.column)
		for _, obstacle in ipairs(obstacles) do
			local gap = boxBoxGap(at, columnSize, obstacle.centre, obstacle.size)
			check(gap >= COLUMN_CLEAR,
				("the roof column at (%.0f, %.0f) is %.1f studs from %s (need %d)")
					:format(at.X, at.Z, gap, obstacle.label, COLUMN_CLEAR))
		end
	end
end

-- 11. A CLOSED GATE CANNOT TRAP A RAID.
--
-- The gates are the first thing on a plot that can be shut, so the question has
-- to be asked once and then never again: is a raider ever on the wrong side of
-- one? HANDOFF_v4 §2 has the numbers — raiders live on a home ring in the arena
-- and are leashed to it, and the nearest plot's front wall (the one the gateway
-- is cut into) is further away than the leash plus a swing.
--
-- The leash block above asserts the same inequality against the plot EDGE. This
-- one reads the WALL: its outer face is `PlotSize.Z/2 - 1` plus half a wall
-- thickness, so a thicker wall or a ring moved outboard fires this and not that.
local frontWallOut = (Config.World.PlotSize.Z / 2 - 1) + SH.WallThickness / 2
local tightestRadius = tightestPlotEdge + Config.World.PlotSize.Z / 2
local toFrontWall = tightestRadius - frontWallOut
check(raiderReach < toFrontWall,
	("a leashed raider reaches %.0f studs from the arena centre and the nearest plot's FRONT WALL — the one the gateway is cut into — is %.0f studs out; any closer and a closed gate stops being decoration as far as combat is concerned and starts being the thing a raider is standing at")
		:format(raiderReach, toFrontWall))

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
-- A label you have to crane at is its own problem, and a label through the
-- ceiling is worse. RE-AUTHORED: this read a hard-coded 20, which was
-- Layout.RoofY — a key that no longer exists, and which was the WRONG number
-- even when it did, because the ground floor's ceiling was the deck's underside
-- at 20.4 and the roof was a separate slab. It reads the ground storey's clear
-- height now, so the label follows the ceiling it has to stay under.
check(BTN.lift + BTN.height / 2 <= groundClear,
	("the buy-button label's top edge is at y=%.1f, through the ground storey's ceiling at y=%.2f")
		:format(BTN.lift + BTN.height / 2, groundClear))

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

-- THE BOSS BAR IS CARVED OUT OF THE RAID SIGN, not added under it: the check
-- immediately above is what makes that the only option, because a taller
-- billboard would push the raid line into the arena title. So the bar is bounded
-- by the sign it lives in, and the line it shares that sign with still has to be
-- the bigger of the two.
check(ST.BossBarHeight > 0 and ST.BossBarHeight <= ST.RaidSignHeight / 2,
	("Style.BossBarHeight is %.1f studs inside a %.1f-stud sign; past half of it the health bar is the sign and the wave line is the footnote")
		:format(ST.BossBarHeight, ST.RaidSignHeight))
check(ST.BossBarInset >= 0 and ST.BossBarInset < 0.25,
	("Style.BossBarInset is %.2f; it is a fraction of the sign's width per side, so at 0.5 the bar has no width left")
		:format(ST.BossBarInset))

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

-- THE STATUS CARD.
--
-- One card carrying the balance, the multiplier, the terms that built it and the
-- next purchase with a progress bar under it — where there were two panels, and
-- where "how far are we from it" was text alone. Its rows are named heights in
-- Config.UI and its Ys are accumulated from them, so everything below is a
-- relationship between two numbers in this file rather than between a number
-- here and a literal in a builder. That is the whole reason the geometry lives
-- in Config: HUD.lua types none of these.
local CARD = UI.StatusCard

-- THE CARD FITS ITS OWN ROWS. Height is chosen and ContentHeight is the sum of
-- the rows, so this fires the moment a row grows or one is added — which is the
-- edit that happened last time (the friend row took the old cash panel from 96
-- to 126) and will happen again.
check(CARD.Height >= CARD.ContentHeight,
	("the status card is %d tall but its rows need %d: pad %d, balance %d, multiplier %d, terms %d, group gap %d, heading %d, name %d, bar %d, detail %d, pad %d")
		:format(CARD.Height, CARD.ContentHeight, CARD.Pad, CARD.BalanceHeight,
			CARD.MultHeight, CARD.TermsHeight, CARD.GroupGap, CARD.HeadingHeight,
			CARD.NameHeight, CARD.BarHeight, CARD.DetailHeight, CARD.Pad))

-- EVERY TEXT SIZE ON THE CARD, AGAINST THE FLOOR, IN PHYSICAL PIXELS. The card
-- carries six of them and it is the densest surface in the game; the smallest is
-- the one that decides whether the device-agnostic claim is true, and a design-px
-- number means nothing until it is multiplied by the worst scale it can be drawn
-- at.
local cardText = {
	{ "balance", CARD.BalanceTextPx },
	{ "multiplier line", CARD.MultTextPx },
	{ "terms line", CARD.TermsTextPx },
	{ "NEXT UPGRADE heading", CARD.HeadingTextPx },
	{ "purchase name", CARD.NameTextPx },
	{ "progress detail", CARD.DetailTextPx },
}
for _, row in ipairs(cardText) do
	check(row[2] >= UI.MinTextPx,
		("the status card's %s is %d design px, which is %.1f physical px at MinScale — under the %d-px floor this file declares")
			:format(row[1], row[2], row[2] * UI.MinScale, UI.MinTextPx))
end

-- THE BALANCE IS THE BIGGEST THING ON THE CARD. It is the number the whole game
-- is about and the first thing the eye is supposed to land on; a card where the
-- purchase name or the multiplier out-sizes it is a card that reads as being
-- about something else. Ordering, not a magnitude, so it survives a retype of
-- every number in the group.
for _, row in ipairs(cardText) do
	check(row[1] == "balance" or CARD.BalanceTextPx > row[2],
		("the status card's balance is %d design px and its %s is %d; the balance has to be the first thing read")
			:format(CARD.BalanceTextPx, row[1], row[2]))
end

-- THE PROGRESS BAR IS A GAUGE, NOT A CONTROL, and it is bounded from both sides
-- for two different reasons. Too thin and it is a hairline nobody can read a
-- fraction off — at MinScale a 3-px design bar is under 2 physical px. Too thick
-- and it reads as a button: everything else in this file that is MinTouchPx tall
-- answers a press, and this one never will.
check(CARD.BarHeight * UI.MinScale >= 3,
	("the progress bar is %d design px tall, which is %.1f physical px at MinScale — a gauge nobody can read the fill of is decoration")
		:format(CARD.BarHeight, CARD.BarHeight * UI.MinScale))
check(CARD.BarHeight < UI.MinTouchPx,
	("the progress bar is %d design px tall against a touch floor of %d; at that height it reads as a control, and pressing it does nothing")
		:format(CARD.BarHeight, UI.MinTouchPx))

-- THE CARD HAS NOTHING ON IT TO PRESS, AND THIS FILE CANNOT SAY SO.
--
-- Two checks stood here and both are gone with the row they described: that the
-- friend row was at least Button.pill tall (the INVITE pill had shipped at 26 —
-- 16 physical px at MinScale, on the one control whose whole job is to be
-- pressed by a child) and that the sentence beside it got more of the row than
-- the one word did. The invite is a rail item now and there is no friend row.
--
-- What replaces them is NOT another check here. The invariant worth keeping is
-- that this card carries no control at all, and Config holds numbers: it cannot
-- see a TextButton, and the obvious proxy — "no row is a touch target's height"
-- — is false on its face, because the balance row is 46 px tall to hold 38 px of
-- text and is not a control. That proxy was written, and it failed on the
-- shipped config the first time it ran, which is the only reason it is being
-- described here instead of shipped.
--
-- So the enforcement moved rather than shrank: tools/testing/specs/hud_spec.lua
-- walks the card's descendants and fails on a TextButton or an ImageButton. See
-- docs/dev/INVARIANTS.md — that entry is [spec], not [assert].

-- Printed because every number on the card is derived from the ten row heights
-- above it, and a derived layout nobody ever reads back is one nobody notices has
-- drifted. This is the line to look at when the card looks wrong in Studio.
print(("status card:       %dx%d (rows need %d), bar %dx%d at y=%d, left column ends at y=%d of %d")
	:format(CARD.Width, CARD.Height, CARD.ContentHeight, CARD.ContentWidth,
		CARD.BarHeight, CARD.BarY, UI.ColumnBottom + UI.Margin, UI.ReferenceHeight))

-- THE TOP-LEFT COLUMN AND THE UPGRADE SHOP.
--
-- This is the check that had no owner. HUD.lua stacks the status card and (via
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
local column = { UI.StatusCard, UI.SessionPanel }
for index, entry in ipairs(column) do
	check(entry.Width == UI.ColumnWidth,
		("panel %d of the left column is %d wide but the column is %d; a column of two widths is two panels")
			:format(index, entry.Width, UI.ColumnWidth))
end
-- Two heights now, not three. CompactHeight was the Prototypes.Sessions-off
-- layout; the flag graduated in #50 and nothing has been able to select that
-- height since, so it is gone rather than sitting here being ordered.
check(UI.SessionPanel.TallHeight >= UI.SessionPanel.Height,
	"the session panel's tall height is shorter than its ordinary one")
check(UI.SessionPanel.CompactHeight == nil,
	"UI.SessionPanel.CompactHeight is back — nothing can select it, so it is a layout that reads as supported and is not")

-- THE SESSION PANEL'S TALL HEIGHT IS THE PANEL WITH ITS WHOLE TAIL SHOWING.
--
-- TallHeight shipped at 258 and SessionUI.layoutTail() could build 310, because
-- 258 was the ONE-optional-row height and there are two optional rows: the Vault
-- Timer and the pending-offline row, both visible at once for any returning
-- player who has not maxed the vault. ColumnBottom was measured against the
-- number the code had already left behind, so the column fitted by luck.
--
-- OptionalRows is the input to both heights now. What this file cannot see is
-- how many rows SessionUI actually stacks — that is a list in src/client, the
-- one directory this harness is blind to — so the count is asserted to be a
-- count (a tail of zero optional rows is a TallHeight that means nothing) and
-- the list itself is held to it by a spec in tools/testing/specs/hud_spec.lua.
check(UI.SessionPanel.OptionalRows >= 1,
	("the session panel declares %d optional rows; with none of them, TallHeight is just Height under another name")
		:format(UI.SessionPanel.OptionalRows))
-- There is deliberately NO check here that TallHeight - Height equals the rows
-- OptionalRows describes. One was written and it could not fail: both heights
-- are derived from those same three numbers eight lines apart in Config, so the
-- identity holds by construction whatever anybody types. The thing that CAN be
-- wrong is OptionalRows disagreeing with the list SessionUI actually stacks, and
-- that list is in src/client, which this harness cannot see. hud_spec.lua drives
-- a SessionState with both rows up and reads the panel's height back.
-- Every row on the panel that IS a control clears the touch floor, and the one
-- gauge on it does not read as one.
check(UI.SessionPanel.ActionWidth >= UI.MinTouchPx,
	("the session panel's claim pill is %d design px wide against a touch floor of %d; height is not the only axis a thumb has")
		:format(UI.SessionPanel.ActionWidth, UI.MinTouchPx))
check(UI.SessionPanel.BarHeight < UI.MinTouchPx,
	("the playtime gauge is %d design px tall against a touch floor of %d; at that height it reads as a control and pressing it does nothing")
		:format(UI.SessionPanel.BarHeight, UI.MinTouchPx))
-- Its text, against the same floor the status card's is held to. Three of these
-- shipped at 12 — 7.4 physical px at MinScale — as literals in SessionUI.lua,
-- which is the same defect the NEXT UPGRADE heading had and for the same reason.
local panelText = {
	{ "SESSION heading", UI.SessionPanel.HeadTextPx },
	{ "row title", UI.SessionPanel.RowTitleTextPx },
	{ "row sub-line", UI.SessionPanel.RowSubTextPx },
	{ "claim pill", UI.SessionPanel.ActionTextPx },
	{ "boost button", UI.SessionPanel.BoostTextPx },
}
for _, row in ipairs(panelText) do
	check(row[2] >= UI.MinTextPx,
		("the session panel's %s is %d design px, which is %.1f physical px at MinScale — under the %d-px floor this file declares")
			:format(row[1], row[2], row[2] * UI.MinScale, UI.MinTextPx))
end

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

-- ── THE RIGHT EDGE: the rail, the toasts under it, and the action stack ─────
--
-- The right side is a column too now, and it had the defect the left one had
-- before Config could see both ends of it: the rail and the toast column were
-- both docked to the top-right corner, and the action stack was docked to a
-- corner the engine already draws in. Three surfaces, one edge, and until this
-- block nothing in the repo could read more than one of them at a time.

-- THE INVITE IS THE ONE CONTROL IN THIS GAME AIMED AT SOMEBODY WHO IS NOT
-- PLAYING IT YET, and it is pressed by children. It shipped once as a 72x26
-- literal in a builder — 16 physical px at MinScale, under half the floor this
-- file declares — which is the whole reason UI.Button exists. A rail item is not
-- on that ladder (it is a square, not a row), so it is held to the floor
-- directly and on BOTH axes: a 56-wide button 20 tall is as unhittable as a
-- 20-wide one, and only one of those two mistakes is the one already made.
check(UI.Rail.ItemWidth >= UI.MinTouchPx and UI.Rail.ItemHeight >= UI.MinTouchPx,
	("a rail item is %dx%d design px against a touch floor of %d — %.0fx%.0f physical at MinScale")
		:format(UI.Rail.ItemWidth, UI.Rail.ItemHeight, UI.MinTouchPx,
			UI.Rail.ItemWidth * UI.MinScale, UI.Rail.ItemHeight * UI.MinScale))
check(UI.Rail.ItemHeight >= UI.Rail.ContentHeight,
	("a rail item is %d tall but its glyph and caption need %d: pad %d, glyph %d, gap %d, badge %d, pad %d")
		:format(UI.Rail.ItemHeight, UI.Rail.ContentHeight, UI.Rail.Pad, UI.Rail.GlyphSize,
			UI.Rail.GlyphGap, UI.Rail.BadgeHeight, UI.Rail.Pad))
-- The caption is the price tag the old friend row carried — "+10%" is what the
-- ask is worth — so it is small print that has to be readable, not decoration.
check(UI.Rail.BadgeTextPx >= UI.MinTextPx,
	("the rail caption is %d design px, which is %.1f physical px at MinScale — under the %d-px floor this file declares")
		:format(UI.Rail.BadgeTextPx, UI.Rail.BadgeTextPx * UI.MinScale, UI.MinTextPx))
check(UI.Rail.GlyphSize <= UI.Rail.ItemWidth - UI.Rail.Pad * 2,
	("the rail glyph is %d wide inside a %d item with %d of padding a side")
		:format(UI.Rail.GlyphSize, UI.Rail.ItemWidth, UI.Rail.Pad))

-- BOTH BOTTOM CORNERS BELONG TO THE ENGINE. On a touch device Roblox draws the
-- movement thumbstick bottom-left and the jump button bottom-right, on a layer
-- above ours, and there is no API that returns either rectangle. The action
-- stack was anchored (1,1) at the margin — 200x112 in exactly the jump button's
-- corner — so for four out of five players REBIRTH and JUMP were the same
-- pixels, and it looked fine on the machine it was written on.
--
-- The reserve is a guess. The guard on a guess is that it is at least as big as
-- the biggest thing we DO have a number for: a reserve under two of our own
-- primary buttons is not clearing a thumb control, it is decorating one.
check(UI.TouchReserve.Bottom >= UI.Button.primary * 2,
	("the bottom touch reserve is %d design px and a primary button is %d; under two of those it is not clearing the engine's controls, it is decorating them")
		:format(UI.TouchReserve.Bottom, UI.Button.primary))
check(UI.Action.Top + UI.Action.Height + UI.TouchReserve.Bottom <= UI.ReferenceHeight,
	("the action stack ends at y=%d and the bottom %d px are reserved for the engine's own controls on a %d-tall screen")
		:format(UI.Action.Top + UI.Action.Height, UI.TouchReserve.Bottom, UI.ReferenceHeight))

-- THE TOAST COLUMN CLEARS THE RAIL ABOVE IT AND THE ACTION STACK BELOW IT.
-- Both are one-axis checks on one edge, and both are only assertable because
-- HUD.toast destroys cards past UI.Toast.MaxCards: a UIListLayout does not clip
-- and does not stop, so before that a burst of toasts simply drew through
-- whatever was under them and ListHeight described nothing.
check(UI.Toast.Y >= UI.Rail.Bottom + UI.Gap,
	("the toast column starts at y=%d and the rail ends at y=%d; the first toast of the session would land on the invite")
		:format(UI.Toast.Y, UI.Rail.Bottom))
check(UI.Toast.Bottom + UI.Gap <= UI.Action.Top,
	("the toast column runs to y=%d and the action stack starts at y=%d — %d cards of %d with a %d gap do not fit between the rail and REBIRTH")
		:format(UI.Toast.Bottom, UI.Action.Top, UI.Toast.MaxCards, UI.Toast.CardHeight, UI.Gap))
check(UI.Toast.MaxCards >= 2,
	("the toast column holds %d card(s); a notification that replaces the one before it is a notification nobody reads")
		:format(UI.Toast.MaxCards))
-- The card's own insides, so the accent bar and the two lines stay inside it.
check(UI.Toast.BodyY + UI.Toast.BodyHeight <= UI.Toast.CardHeight,
	("a toast card is %d tall and its body ends at %d")
		:format(UI.Toast.CardHeight, UI.Toast.BodyY + UI.Toast.BodyHeight))
check(UI.Toast.TitleTextPx >= UI.MinTextPx and UI.Toast.BodyTextPx >= UI.MinTextPx,
	("a toast prints at %d and %d design px against a %d-px floor")
		:format(UI.Toast.TitleTextPx, UI.Toast.BodyTextPx, UI.MinTextPx))

print(("right edge:        rail ends y=%d, toasts %d..%d (%d cards), actions %d..%d, reserve %d of %d")
	:format(UI.Rail.Bottom, UI.Toast.Y, UI.Toast.Bottom, UI.Toast.MaxCards,
		UI.Action.Top, UI.Action.Top + UI.Action.Height, UI.TouchReserve.Bottom, UI.ReferenceHeight))

-- MODALS FIT THE REFERENCE FRAME. They are centred and unscaled relative to the
-- design canvas, so a card wider than the canvas is a card with its buttons off
-- both sides of the screen — on every device, not just a phone.
--
-- Each card's rows are accumulated in Config's derivation block now, so the last
-- of them can be asserted against the button that has to sit under it. Nothing
-- had checked that: the offline modal's cap line is two lines of wrapped text
-- and the COLLECT button below it was at a hand-typed y.
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
		check(card.ContentHeight + UI.Gap <= card.ButtonY,
			("the %s modal's last row ends at y=%d and its button starts at y=%d")
				:format(name, card.ContentHeight, card.ButtonY))
		-- Every text size on the card, by name, against the same floor the status
		-- card's six are held to. Walked rather than listed because the two modals
		-- carry different rows — the offline one has an AmountTextPx of 46 and the
		-- rebirth one has no amount at all — and a hand-written list is a list that
		-- stops covering the row somebody adds next.
		for key, value in pairs(card) do
			if type(key) == "string" and key:sub(-6) == "TextPx" then
				check(value >= UI.MinTextPx,
					("the %s modal's %s is %d design px, which is %.1f physical px at MinScale — under the %d-px floor this file declares")
						:format(name, key, value, value * UI.MinScale, UI.MinTextPx))
			end
		end
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

-- design:D-03 — these four bands are product decisions that happen to be
-- enforceable. The reason each is the number it is lives in that issue; what
-- lives here is the check.
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

-- ...and an UNGATED track must NOT be affordable at spawn. A player who can buy
-- a bat before a dropper has spent their whole opening balance on a plot with
-- no income, and nothing in the game can dig them out of that.
--
-- SCOPED TO UNGATED TRACKS, because on a gated one this cannot fail at any
-- price — Config.TrackUnlock names a factory button and you have not bought it
-- yet, so the pad does not exist to be bought. It read `track ~= "factory"`,
-- and round 8 gating both cabinets on `dropper3` quietly turned two of its
-- three iterations into theatre; the structure track would have made it three
-- of four. `power` is the one track this is really about and the one track
-- that has never been gated.
for _, track in ipairs(Config.TrackOrder) do
	local defs = Config.Tracks[track]
	if track ~= "factory" and Config.TrackUnlock[track] == nil and #defs > 0 then
		check(defs[1].price > Config.Economy.StartingCash,
			("%s is on the ungated %s track and costs %d against StartingCash of %d — a new player could buy it instead of their first dropper and strand themselves")
				:format(defs[1].id, track, defs[1].price, Config.Economy.StartingCash))
	end
end

local cash = Config.Economy.StartingCash
local elapsed, upgradeMult = 0, 1
local curve = {}

-- The income at every step is Config.incomeRate over what the sim has bought
-- so far — the same function the two runtime readers wrap, so the sim cannot
-- drift from the game. `upgradeMult` and `power` survive as bookkeeping: the
-- report prints the stack, and the payback check below needs each power
-- purchase's before/after factor.
local ownedSoFar = {}
local function ownsSoFar(id: string): boolean
	return ownedSoFar[id] == true
end

-- THE SPINE, which is N interleaved ladders.
--
-- The factory is the thing that generates income and therefore the thing whose
-- "45 to 150 minutes" pacing is about. The generator belongs in here with it
-- rather than in the side-track model below, because that model prices a track
-- against a curve it does not change — true of a bat, false of anything that
-- multiplies production. A power rung bought at minute 12 moves every row after
-- it. The shell belongs in here for the OTHER half of that model's premise: a
-- detour is something you can decline, and Config.ButtonUnlock puts `roof`
-- between the player and the mezzanine.
--
-- READS `paced` RATHER THAN NAMING THE TRACKS. This was two hand-written
-- indices over two named tables, so adding a third spine track meant editing a
-- loop rather than adding a row to Config.TrackInfo — and TrackInfo exists
-- precisely so that a per-track fact lives in one place. The two-index form
-- also could not say what it meant: `paced` was already the field that decides
-- this, and the loop was a second opinion about it that happened to agree.
--
-- The policy is UNCHANGED: BUY WHICHEVER NEXT RUNG IS CHEAPEST. Deterministic,
-- one comparison, and it makes the price the control: put a rung between
-- dropper6 and roof and the sim buys it exactly there, visibly, in the printed
-- curve. A payback heuristic would model a player nobody is.
local power = 1
local spineLanes = {}
for _, track in ipairs(Config.TrackOrder) do
	if Config.TrackInfo[track].paced == "spine" then
		table.insert(spineLanes, { track = track, defs = Config.Tracks[track], index = 1 })
	end
end
check(#spineLanes >= 1,
	"no track is paced as the spine, so the build has no length and every pacing check below is measuring nothing")

-- A TIE WOULD MAKE THE TIE-BREAK THE CONTROL. The two-index form wrote
-- `nextPower.price <= nextFactory.price`, so power silently won a tie; there
-- has never been one, and the day there is, the printed curve stops explaining
-- itself — two rungs land in an order chosen by the iteration sequence of
-- TrackOrder rather than by a number anybody set. Refuse it instead of picking
-- a winner in a loop nobody reads.
do
	local seenPrice = {}
	for _, lane in ipairs(spineLanes) do
		for _, def in ipairs(lane.defs) do
			check(seenPrice[def.price] == nil,
				("%s and %s are both priced at %d; the spine simulation buys the cheapest next rung, so an equal price makes TrackOrder the tie-break rather than the price")
					:format(def.id, tostring(seenPrice[def.price]), def.price))
			seenPrice[def.price] = def.id
		end
	end
end

while true do
	local pick
	for _, lane in ipairs(spineLanes) do
		local candidate = lane.defs[lane.index]
		if candidate and (pick == nil or candidate.price < pick.def.price) then
			pick = { lane = lane, def = candidate }
		end
	end
	if pick == nil then break end
	local def = pick.def

	local income = Config.incomeRate(ownsSoFar)
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
	-- Income itself comes from Config.incomeRate; this dispatch is the
	-- bookkeeping the report and the payback check still need. Dispatched on
	-- KIND, not on which lane it came from — the "which lane" and "what does
	-- it do" questions are different questions, and only one of them is being
	-- asked here.
	if def.kind == "Power" then
		power = def.factor
	elseif def.kind == "Upgrader" then
		upgradeMult *= def.multiplier
	end
	ownedSoFar[def.id] = true
	pick.lane.index += 1

	-- `earned` is everything the plot has produced by this point, ignoring what
	-- was spent. It is the budget a side-track purchase competes for.
	table.insert(curve, {
		id = def.id, wait = wait, at = elapsed,
		income = Config.incomeRate(ownsSoFar),
		earned = (curve[#curve] and curve[#curve].earned or 0) + (wait ~= math.huge and wait or 0) * income,
		isPower = def.kind == "Power", price = def.price,
		previousPower = previousPower, power = power,
	})
end

local endgameIncome = Config.incomeRate(ownsSoFar)
check(elapsed / 60 >= MIN_TOTAL_MINUTES,
	("full build takes only %.0f min (want >= %d) — the game is over too fast"):format(elapsed / 60, MIN_TOTAL_MINUTES))
check(elapsed / 60 <= MAX_TOTAL_MINUTES,
	("full build takes %.0f min (want <= %d) — too grindy"):format(elapsed / 60, MAX_TOTAL_MINUTES))

-- ── how long the number is allowed to stand still ───────────────────────────
--
-- Some purchases change no number at all: the enclosure does not drop, refine
-- or multiply anything, and neither does the roof or the deck. Six of them, and
-- they are not a mistake — a tycoon whose every purchase is a bigger number is
-- a spreadsheet. But a RUN of them is different from one of them: for the whole
-- run the income readout is frozen, and the player is buying scenery while the
-- thing they are measuring themselves by has stopped moving.
--
-- WHAT THIS PROVES CHANGED WHEN THE SHELL LEFT THE SPINE, AND THE CHECK IS
-- WORTH KEEPING FOR THE NEW REASON, SO BOTH HALVES ARE WRITTEN DOWN.
--
-- It was added the round the shell was split into walls/gates/windows, all
-- three welded into the factory chain. There it proved something strong: the
-- chain is strict, so a run of three flat rungs was a FORCED MARCH — everyone
-- walked it, in that order, to reach dropper4.
--
-- The shell is a parallel track now and nothing forces it. The run still shows
-- up in the curve, byte for byte, at 4.4 minutes across walls/gates/windows —
-- but it shows up because the SIMULATION buys the cheapest available rung and
-- those three prices happen to sit between dropper3 and dropper4. It is a
-- property of the model's policy, not of the ladder, and a player following the
-- beacon need never see it. So the check proves less than it used to.
--
-- It also covers more. It reads the curve, and the curve is now every spine
-- lane rather than the factory table, so a flat rung landing anywhere in that
-- price window on any spine track joins the run. That is worth more than the
-- guarantee it lost: three cheap income-neutral purchases clustering in the
-- opening minutes is exactly as bad whichever ladder they came off, and this is
-- still the only thing in the file that looks at it.
--
-- The count "six of twenty-four factory rungs" was true and is not: it is two
-- of the twenty on the factory track (`belt1`, `floor2`) plus all four on the
-- structure track.
--
-- Belt is on the list deliberately: belt speed changes latency and density, not
-- income (INVARIANTS.md §2), so `belt1` genuinely does not move the number
-- either.
local EARNS = { Dropper = true, Upgrader = true, Power = true }
-- design:D-03
local MAX_FLAT_RUN = 3
local MAX_FLAT_MINUTES = 6

local runLength, runMinutes, runFrom = 0, 0, nil
local worstRun, worstMinutes, worstIds = 0, 0, ""
for _, entry in ipairs(curve) do
	local def = Config.ButtonById[entry.id]
	if def and not EARNS[def.kind] then
		runLength += 1
		runMinutes += entry.wait
		runFrom = runFrom or entry.id
		if runLength > worstRun then
			worstRun, worstMinutes, worstIds = runLength, runMinutes, runFrom .. " through " .. entry.id
		elseif runLength == worstRun and runMinutes > worstMinutes then
			worstMinutes, worstIds = runMinutes, runFrom .. " through " .. entry.id
		end
	else
		runLength, runMinutes, runFrom = 0, 0, nil
	end
end

check(worstRun <= MAX_FLAT_RUN,
	("%d purchases in a row (%s) leave income exactly where it was; past %d the player is buying scenery with the number they measure themselves by standing still")
		:format(worstRun, worstIds, MAX_FLAT_RUN))
check(worstMinutes / 60 <= MAX_FLAT_MINUTES,
	("%s is %.1f minutes of grind at an unchanged income (limit %d) — that is the longest stretch of this build where nothing gets better")
		:format(worstIds, worstMinutes / 60, MAX_FLAT_MINUTES))

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
-- design:D-01 — a platform fact, not a preference, which is why it is a
-- separate check from MAX_TOTAL_MINUTES rather than the same one retuned.
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
-- design:D-03 — the window the first rebirth has to land in, and the rungs that
-- have to be left over when it does.
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
-- EVERY BUTTON GATE IS REACHED IN PRICE ORDER, not merely reachable.
--
-- The closure check near the top of this file proves a gate cannot deadlock.
-- This is the pacing half of the same question: the simulation buys the
-- cheapest available rung, so a gate priced ABOVE the thing it gates turns into
-- a wall — the player arrives at floor2 with the money for it and is told to go
-- and buy a roof that costs more. Nothing about that is a deadlock and nothing
-- above would catch it.
--
-- This is also what took over from the bespoke "the deck is bought after the
-- roof" assertion that used to live in the floor loop below, and it is stated
-- generically on purpose: that one named two buttons and had to be rewritten
-- every time either of them moved.
for id, gate in pairs(Config.ButtonUnlock) do
	local gatedRow, gateRow = curveRow(id), curveRow(gate)
	if gatedRow and gateRow then
		check(gateRow.at < gatedRow.at,
			("%s waits on %s, but the spine simulation banks %s at minute %.1f and %s only at minute %.1f — the gate costs more than the thing it gates, so it is a wall rather than an order")
				:format(id, gate, id, gatedRow.at / 60, gate, gateRow.at / 60))
	end
end

local floorReport = nil
for _, floor in ipairs(Config.Floors) do
	local row = curveRow(floor.button)
	if row then
		local at = row.at / 60
		local fraction = at / buildMinutes
		-- WHERE THE FLOOR LANDS, now that it is a storey and not a gate.
		--
		-- PREMISE OVERTURNED, TWICE, AND THE SECOND TIME BY THE FIRST. The band
		-- before this one was `0.06 <= fraction <= 0.20` with a hard `at <= 10`,
		-- and every word of its argument rested on one fact: Config.TrackUnlock
		-- gated BOTH side-track cabinets on this button, so parking the floor
		-- parked the weapons and armour ladders behind it. Round 8 moved that
		-- gate to `dropper3` (TODO.md item 2, the cabinets are downstairs now).
		-- The floor gates nothing. Every reason it had to be early went with the
		-- cabinets, and TODO.md item 3 asks for it late — after the shell and
		-- after a run of conveyor upgrades.
		--
		-- `at <= 10` is DELETED rather than retuned. Its stated reason — "it
		-- gates both cabinets, so past ~10 the side tracks have no session left
		-- to be climbed in" — is now false, and a check whose argument is false
		-- is worse than no check: the next person reads the message, believes
		-- it, and reasons from it. What it was really protecting is protected
		-- below, against the thing that is actually on a deadline.
		--
		-- THE SKY-HOLE CHECK THAT STOOD HERE IS GONE, AND ITS JOB IS DONE
		-- BETTER ELSEWHERE. It asserted `row.at > curveRow("roof").at` and said
		-- that a deck bought first "leaves the upper walls open to the sky for
		-- the N minutes in between". That sentence was true while the only
		-- thing standing between the two was their order in one table.
		--
		-- It is FALSE now. Config.ButtonUnlock.floor2 = "roof" makes the
		-- purchase impossible rather than merely late, so the state the message
		-- describes cannot be reached at any pricing and the minutes it offers
		-- to count do not exist. Keeping it would leave a check that still
		-- fires for a reason that has stopped being the reason — the exact
		-- fault that got `at <= 10` deleted six paragraphs above this one, and
		-- the fault this file keeps rediscovering.
		--
		-- Two checks replace it, neither of them special-cased to the floor:
		-- the gate is asserted against the structural fact that motivates it,
		-- and every ButtonUnlock edge is asserted to be reachable in price
		-- order. Both live with the other gate checks. What is left in this
		-- loop is the pacing band, which is the only thing it was ever the
		-- right place for.
		-- THE BAND. Late, because the storey is the building growing rather than
		-- the enclosure it grew inside; not last, because it arrives BARREN
		-- (TODO.md item 4) and a room you never fill is a room you paid for.
		check(fraction >= 0.50,
			("Floors.%s opens at %.0f%% of the build (want 50-80%%) — the ground floor is not finished yet, and a second storey offered while the first one still has empty slots is a room you buy instead of the line you were building")
				:format(floor.id, fraction * 100))
		check(fraction <= 0.80,
			("Floors.%s opens at %.0f%% of the build (want 50-80%%) — the storey arrives barren and its conveyor is a further purchase, so past four fifths there is no session left to put anything in it")
				:format(floor.id, fraction * 100))

		-- ── the deck, and the line on it, are two purchases ──────────────────
		--
		-- TODO.md item 4: the storey arrives BARREN. `floor.button` buys the
		-- deck, its guards, the wall ring and the ladder; `floor.lineButton`
		-- buys the conveyor and the hopper. Neither of the next two can be got
		-- wrong by a player — the loader derives the chain from table order — but
		-- both can be got wrong by moving a row, which is the whole of
		-- INVARIANTS.md's `[nothing]` entry about table order.
		local lineDef = floor.lineButton and Config.ButtonById[floor.lineButton]
		local lineRow = floor.lineButton and curveRow(floor.lineButton)
		if floor.lineButton then
			check(lineDef ~= nil,
				("Floors.%s names %q as its lineButton and no such button exists; the storey would never get a conveyor")
					:format(floor.id, tostring(floor.lineButton)))
			check(lineRow ~= nil,
				("Floors.%s's line is built by %q, which the spine never buys")
					:format(floor.id, tostring(floor.lineButton)))
			if lineRow then
				check(lineRow.at > row.at,
					("Floors.%s's deck is bought at minute %.1f and its conveyor at %.1f — a belt is built on a storey, so buying the line first is a conveyor in mid-air")
						:format(floor.id, at, lineRow.at / 60))
			end
			-- ...AND NOTHING RIDES A BELT THAT IS NOT THERE. A machine pinned to
			-- this path used to be gated on the deck, because the deck came with
			-- the belt; it is gated on the line now, and a row moved above it
			-- would put a dropper on a slab with no conveyor under it, dropping
			-- its output through the floor.
			for _, def in ipairs(Config.Tracks.factory) do
				if def.path == floor.id then
					local machineRow = curveRow(def.id)
					check(machineRow ~= nil and lineRow ~= nil and machineRow.at > lineRow.at,
						("%s is pinned to %s's belt but is bought at minute %.1f, before the line that carries it at %.1f — its drops would fall through a deck with no conveyor on it")
							:format(def.id, floor.id,
								machineRow and machineRow.at / 60 or -1,
								lineRow and lineRow.at / 60 or -1))
				end
			end
		end

		-- HOW MUCH THE LINE IS WORTH THE MINUTE YOU BUY IT. The upstairs
		-- machines are refined by the plot's upgrade stack (see
		-- Tycoon:refineryMultiplierFor), so this share is a constant for the
		-- rest of the build rather than something that decays — which is the
		-- entire reason for that decision, and the reason to keep measuring it.
		--
		-- MEASURED AT THE LINE, NOT AT THE DECK, and that is not a refinement.
		-- It used to read `defRow.at <= row.at`, where `row` is the DECK's
		-- purchase — so it counted the upstairs dropper's output as arriving the
		-- minute you bought a storey that does not have it yet. That was
		-- harmless while the two were one purchase and is a straight lie now: a
		-- barren deck's own machines are 0% of plot income by construction, so
		-- the lower bound would fail on a correct build and the upper bound
		-- could never fail on any build at all.
		local shareAt = lineRow or row
		local floorDps, groundDps = 0, 0
		for _, def in ipairs(Config.Tracks.factory) do
			if def.kind == "Dropper" then
				local defRow = curveRow(def.id)
				if defRow and defRow.at <= shareAt.at + 1e-9 then
					if def.path == floor.id then
						floorDps += def.dropValue / def.dropRate
					else
						groundDps += def.dropValue / def.dropRate
					end
				end
			end
		end
		-- The first machine on the line is bought AFTER the line itself, so at
		-- the moment of purchase the numerator is zero by construction. What the
		-- band is about is what the line is worth once it is running, so the
		-- machines that arrive on it are counted against the ground floor as it
		-- stands when the line opens.
		for _, def in ipairs(Config.Tracks.factory) do
			if def.kind == "Dropper" and def.path == floor.id then
				local defRow = curveRow(def.id)
				if defRow and defRow.at > shareAt.at then
					floorDps += def.dropValue / def.dropRate
				end
			end
		end
		local share = floorDps / (groundDps + floorDps)
		floorReport = ("floor %s:        deck at %.0f min (%.0f%% of build), line at %.0f min, worth %.0f%% of income")
			:format(floor.id, at, fraction * 100, shareAt.at / 60, share * 100)
		-- A third is the shape being asserted: the first upstairs machine is a
		-- PEER of the ground floor's newest dropper, not a replacement for the
		-- ground floor and not a decoration on top of it. Split into two checks
		-- so each failure names the defect it is about.
		check(share >= 0.25,
			("Floors.%s's own machines are %.0f%% of plot income when its line opens (want 25-45%%) — below that the deck is a viewing platform and its dropper is a decoration")
				:format(floor.id, share * 100))
		check(share <= 0.45,
			("Floors.%s's own machines are %.0f%% of plot income when its line opens (want 25-45%%) — above that the ground slots you have not filled yet stop being what you are playing for")
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

-- design:D-03 — a detour is priced against what it does, not as a toll on the
-- factory, and a cabinet must not be scenery once it has opened.
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

-- ── the Vault Timer, priced against the factory ─────────────────────────────
--
-- The offline cap upgrade is a THING YOU BUY now — before this round
-- `offlineCapLevel` had no writer anywhere in the repo and the welcome-back
-- panel advertised a product that did not exist. A purchase has to be priced
-- like one, and "priced like one" is not a number you can pick by looking at
-- Config.Offline: it is a question about the income the player has at the moment
-- the cap is worth fixing, which means it has to be asked down here, against the
-- curve, exactly like the side tracks above.
--
-- Two things are asserted, and they are the two ways a cap upgrade fails:
--
--   TOO DEAR. Measured as DETOUR, the same metric and the same limit the bats
--   and armour are held to — how many minutes of your current income it costs.
--   Past that and buying the vault means visibly stalling the factory, which is
--   the trade nobody makes; the cap stays where it is and the upsell on the
--   welcome-back panel is just a second sentence about being clipped.
--
--   TOO LATE. The 8-hour cap first bites on the FIRST overnight, so a tier one
--   nobody can bank inside their first session is a fix that arrives a day after
--   the problem it fixes. 50 minutes is the same threshold the second floor is
--   held to, and for the same reason: Roblox credits the first 60 minutes of a
--   session and nothing after it.
local VAULT_FIRST_TIER_BY_MINUTE = 50
local vaultReport = {}
do
	local O = Config.Offline
	local previousHours = O.CapHours
	for tier, hours in ipairs(O.CapUpgradeHours) do
		local cost = O.CapUpgradeCost[tier]
		local at, income = firstAffordable(cost)
		check(at ~= math.huge,
			("Vault Timer %d costs %.3g, which the factory never banks across a whole build")
				:format(tier, cost))
		if at ~= math.huge and income > 0 then
			local detour = cost / income / 60
			table.insert(vaultReport, ("%dh at %.0f min (%.1f min of income)"):format(hours, at, detour))
			check(detour <= SIDE_MAX_DETOUR_MINUTES,
				("Vault Timer %d costs %.1f min of the income you have when you can first afford it (limit %d) — that is a wall, not a detour")
					:format(tier, detour, SIDE_MAX_DETOUR_MINUTES))
			if tier == 1 then
				check(at <= VAULT_FIRST_TIER_BY_MINUTE,
					("the first Vault Timer is unaffordable until minute %.0f (limit %d) — the %dh cap bites on the first overnight, and the fix for it has to be reachable in the first session")
						:format(at, VAULT_FIRST_TIER_BY_MINUTE, O.CapHours))
			end
		end
		previousHours = hours
	end
	-- and the top of the ladder has to be worth having: a cap you can never fill
	-- is a purchase that pays nothing for the last hours it sold you
	check(previousHours <= 24,
		("the longest Vault Timer banks %dh; past a full day nobody is away long enough to fill it")
			:format(previousHours))
end

-- ── the playtime ladder, against what the factory makes in the same minutes ──
--
-- Newly assertable, and newly worth asserting. The ladder used to reset when the
-- session did, which made it a one-off arrival bonus; its rungs are claimed once
-- per UTC DAY now, so every number in it is RECURRING INCOME that a player
-- collects for walking around, forever, for as long as they keep playing.
--
-- The rule is that the ladder supplements the factory and never replaces it. So
-- for each rung, everything the ladder has paid by that minute is compared with
-- everything the plot has produced by the same minute. Above 1.0 the optimal
-- play is to stand in a corner pressing W, which is not a tycoon.
--
-- The minutes are not quite the same minutes — the ladder counts ACTIVE seconds
-- and the curve counts grind time — but a player doing the build is active by
-- definition, so the curve is the right yardstick and the approximation runs in
-- the conservative direction.
local LADDER_MAX_SHARE = 1.0
do
	local S = Config.Sessions
	local ladderTotal = 0
	for index, minutes in ipairs(S.PlaytimeMinutes) do
		ladderTotal += math.floor(S.PlaytimeRewardBase * (S.PlaytimeRewardGrowth ^ (index - 1)))

		local produced = 0
		for _, row in ipairs(curve) do
			if row.at / 60 <= minutes then
				produced = row.earned
			end
		end
		check(produced > 0 and ladderTotal <= produced * LADDER_MAX_SHARE,
			("the playtime ladder has paid %.3g by minute %d and the factory has produced %.3g — a daily ladder that out-earns the plot it is attached to makes standing still the optimal play")
				:format(ladderTotal, minutes, produced))
	end
end

-- HOW FAST A CABINET EMPTIES ONCE IT OPENS, printed rather than asserted.
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
-- SIDE TRACKS ONLY, AND THE WORD "CABINET" IN THE MESSAGE IS WHY. Every line
-- of the argument above is about a DETOUR: a ladder of optional tiers that
-- appears all at once, priced against income it does not produce, which you
-- either empty in one pass or stare at. The structure track is gated too, so
-- keying this on `TrackUnlock` swept it in — and it fails, 3 of 4, for a reason
-- that is not a defect. The shell is deliberately three cheap rungs bought in
-- the opening minutes; "you could afford all of them" is the DESIGN, because
-- the thing being sold is one building in three instalments, not four
-- interchangeable tiers of the same slot. `paced` already draws exactly this
-- line and it is the honest key.
--
-- Raising VENDING_MACHINE_RUNGS to 3 would have made this pass. It would also
-- have stopped the check catching a real three-rung cabinet, which is the only
-- thing it is for.
-- design:D-03
local VENDING_MACHINE_RUNGS = 2
for _, track in ipairs(Config.TrackOrder) do
	local gate = Config.TrackUnlock[track]
	if gate and Config.TrackInfo[track].paced == "side" then
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
-- The shell's part cost at full scale, printed because HANDOFF_v5 §4 has listed
-- "part budget at full scale is still untested" for three rounds and the number
-- wants reading every time the window spec moves, not just when it fails.
print(("shell parts:       %d of a %d budget (%d before the mezzanine storey), %d across %d plots")
	:format(shellParts, Config.Structure.PartBudget, shellPartsGround,
		shellParts * Config.World.MaxPlots, Config.World.MaxPlots))
print(("belt:              %.0f studs, %.1fs transit, %.0f drops in flight at peak (%.0f%% full)")
	:format(beltLength, transit, inFlight, inFlight * DROP_LENGTH / beltLength * 100))
-- Printed because partitioning the furniture by floor removes comparisons by
-- construction, and a number nobody looks at is how that becomes a quiet loss of
-- coverage. It was 204 on a one-floor plot.
print(("furniture:         %d pieces on %d floors, %d plan pairs compared")
	:format(#floorSpots, 1 + #Config.Floors, furniturePairs))
if lightReport then print(lightReport) end
if floorReport then print(floorReport) end
print(("vault timers:      %dh free, then %s")
	:format(Config.Offline.CapHours, table.concat(vaultReport, ", ")))
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
