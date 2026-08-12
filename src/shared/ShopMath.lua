--[[
	ShopMath.lua — shared maths and lookups for the two player-progression
	prototypes: the upgrade shop (Config.PlayerUpgrades) and the utility slot
	(Config.Utilities).

	IT WAS CALLED Utilities.lua, next to Util.lua, and the two are unrelated:
	Util is number formatting and welding, this is price curves. Two modules a
	letter apart, neither named after what it does, is a wrong guess every time
	somebody new opens the tree — and this one is reached from exactly two files
	while Util is reached from fifteen. Renamed for the reader, not for tidiness.

	Why one module for both: the server prices a purchase and the client draws
	the price, and if those two ever disagree the shop shows a number you can't
	actually buy at. Every formula the UI needs lives here so there is exactly
	one copy of it, and the server treats its own result as the authority.

	Pure data + maths only — no Instances, no remotes, so it is safe on both
	sides of the wire.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local ShopMath = {}

export type UpgradeDef = {
	id: string, name: string, stat: string, levels: number,
	base: number, perLevel: number, cost: number, costGrowth: number,
	blurb: string,
}

export type UtilityDef = {
	id: string, name: string, verb: string,
	duration: number, cooldown: number, price: number, requires: string,
}

-- Config ships the two tables as arrays; index them once here rather than
-- looping over four entries on every remote call.
ShopMath.UpgradeById = {} :: { [string]: UpgradeDef }
for _, def in ipairs(Config.PlayerUpgrades) do
	ShopMath.UpgradeById[def.id] = def
end

ShopMath.UtilityById = {} :: { [string]: UtilityDef }
for _, def in ipairs(Config.Utilities) do
	ShopMath.UtilityById[def.id] = def
end

--- The value of an upgrade's stat at `level` (level 0 = unpurchased).
function ShopMath.valueAt(def, level: number): number
	return def.base + def.perLevel * math.clamp(level, 0, def.levels)
end

--- What the NEXT level costs, or nil at max. Geometric, per IDEAS.md §7:
--- x4–6 per tier for a ~7-level premium stat.
function ShopMath.costAt(def, level: number): number?
	if level >= def.levels then
		return nil
	end
	return math.floor(def.cost * (def.costGrowth ^ level))
end

--- Trims trailing zeros so "23.10 studs/sec" reads as "23.1 studs/sec" without
--- turning the payout multiplier into a bare "x1".
function ShopMath.formatValue(value: number): string
	if value == math.floor(value) then
		return tostring(math.floor(value))
	end
	local s = ("%.2f"):format(value)
	s = s:gsub("0$", "")
	return s
end

--- The blurb with the current stat value substituted in. Some blurbs (the
--- autocollect toggle) have no placeholder, hence the find().
function ShopMath.describe(def, level: number): string
	if not def.blurb:find("%%s") then
		return def.blurb
	end
	return def.blurb:format(ShopMath.formatValue(ShopMath.valueAt(def, level)))
end

--- What each verb actually does, for the shop row. Config.Utilities carries a
--- verb and a duration but no player-facing description, and the wording has
--- to match what UpgradeService's implementation really does — so it lives
--- next to the maths rather than in the UI, where it would be one more thing
--- that can quietly stop being true.
local VERB_BLURB = {
	freeze = "Roots nearby raiders for %ds. They can still swing.",
	shove = "Heavy knockback on everything nearby. No damage.",
	decoy = "Drops a decoy for %ds. PROTOTYPE: raiders ignore it.",
}

function ShopMath.verbBlurb(def): string
	local blurb = VERB_BLURB[def.verb] or ("%s nearby."):format(def.verb)
	if blurb:find("%%d") then
		return blurb:format(def.duration)
	end
	return blurb
end

--- Utilities are one-shot purchases, so their "level" is 0 or 1 and their cost
--- is flat. Expressed through the same two functions as the upgrades so the
--- shop UI can draw both kinds of row with one code path.
function ShopMath.utilityCostAt(def, level: number): number?
	if level >= 1 then
		return nil
	end
	return def.price
end

return ShopMath
