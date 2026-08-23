--[[
	tycoon/Ownership.lua — claim, leave, prestige: the three transitions a plot
	makes, and what each of them has to put back.

	assign REPLAYS THE SAVE by installing every owned button in `order`,
	cheapest-first so requirements resolve as they are reached. That replay is
	why every installer has to be idempotent and why nothing derived from `owned`
	may be accumulated.

	release AND rebirth DIFFER IN ONE THING, and it is not how much they wipe.
	release is a new owner: machines and props both go, cabinet signs with them,
	the gauge is cleared BEFORE updateSign runs so the last owner's "leaving now
	banks 2.4M" never sits on a free plot's sign. rebirth is a factory reset for
	the same player: machines go, props stay, and the tracks marked
	keepOnRebirth survive in both profile.owned and self.owned. That rule is one
	table read twice — Config.TrackInfo[track].keepOnRebirth — because two name
	tests with opposite polarity fail OPEN, and the fourth track missing from one
	of them means the generator survives the reset it is part of.

	All three end with refreshButtons() then fireOwnedChanged(), in that order:
	buttons first, listeners second.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local Economy = Req("Economy")
local Net = Req("Net")
local DataService = Req("DataService")
local Analytics = Req("Analytics")
local Tycoon = Req("Class")

local COLORS = Tycoon.COLORS

-- ── ownership ────────────────────────────────────────────────────────────────

function Tycoon:assign(player: Player)
	if self.owner then
		return false
	end
	self.owner = player
	self.generation += 1
	self:ensureButtons()
	self:setFactoryVisible(true)
	-- Before the install replay: the replay builds walls, and applySiegeState
	-- reads this table to know what may stand.
	self:resetSiege()

	local profile = DataService.get(player)
	if profile then
		-- rebuild everything they had, cheapest-first so requirements resolve
		local ids = {}
		for id, owned in pairs(profile.owned) do
			if owned and Config.ButtonById[id] then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return Config.ButtonById[a].order < Config.ButtonById[b].order
		end)
		for _, id in ipairs(ids) do
			self:install(id, true)
		end
		-- After the replay stood the walls up: the saved dents scale onto the
		-- current maxes and the ring is made to agree (#124).
		self:restoreSiege(profile)
	end

	self:refreshButtons()
	self:updateSign()
	self:fireOwnedChanged()
	self:startIncomeLoop(player)
	self:resetStorage()
	return true
end

function Tycoon:release()
	self.owner = nil
	self.generation += 1
	self.owned = {}
	self.beltBonus, self.powerFactor = 0, 1
	self:refreshBeltSpeed()

	for _, entry in pairs(self.objects) do
		if entry.machine then
			entry.machine:Destroy()
			entry.machine = nil
		end
	end
	self.machines:ClearAllChildren()
	self.props:ClearAllChildren()
	self:clearDrops()
	self:setFactoryVisible(false)

	self:eachBeltSurface(function(surface)
		surface.Color = COLORS.belt
	end)
	-- Dropped BEFORE updateSign runs below, not left for VaultService to clear
	-- on the owned-changed that follows: for those few lines the plot has no
	-- owner, and the last owner's "leaving now banks 2.4M" would be sitting on
	-- a free plot's sign while the claim beacon lit up next to it.
	self:setVaultGauge(0, nil, nil, false)
	-- Storage and siege state are tenancy-scoped: the next claimant starts
	-- with an intact plot, whatever the last one let happen to it.
	self:resetStorage()
	self:resetSiege()

	self:refreshButtons()
	self:updateSign()
	self:fireOwnedChanged()
end

--- Wipes the factory but keeps the player, and hands out a rebirth.
function Tycoon:rebirth(player: Player): boolean
	if player ~= self.owner then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	local cost = Economy.rebirthCost(player)
	if profile.rebirths >= Config.Rebirth.MaxRebirths then
		Economy.notify(player, { kind = "warn", title = "Max rebirths", body = "You have ascended as far as sahur allows." })
		return false
	end
	if profile.cash < cost then
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("Rebirth costs %s."):format(Util.abbreviate(cost)),
		})
		return false
	end

	profile.rebirths += 1
	profile.cash = Config.Economy.StartingCash

	-- A rebirth is a FACTORY reset, not an account reset. The cabinets are
	-- bought with the same wallet but they are not part of the thing being
	-- rebuilt, and re-earning your bat every prestige is exactly the coupling
	-- this split exists to remove.
	--
	-- This also closes a live bug. Rebirth used to wipe `owned` wholesale
	-- while leaving profile.batTier alone, and CombatService.grantBat is
	-- monotonic — so re-buying batforge afterwards took your money and did
	-- nothing at all.
	local kept = {}
	for id in pairs(profile.owned) do
		local def = Config.ButtonById[id]
		-- One derivation, not two name tests with opposite polarity — a track
		-- missing from one of them fails OPEN and the generator survives the
		-- reset it is part of. keptOnRebirth also carries #109's carve-out:
		-- land ground survives, the machines on it reset.
		if def and Config.keptOnRebirth(def) then
			kept[id] = true
		end
	end
	profile.owned = kept

	self.generation += 1
	self.owned = Util.shallowCopy(kept)
	self.beltBonus, self.powerFactor = 0, 1
	self:refreshBeltSpeed()
	for _, entry in pairs(self.objects) do
		-- Side-track props live in self.props and are not cleared below, so
		-- their entries must keep their handle or the model outlives its
		-- reference and can never be cleaned up.
		if not Config.keptOnRebirth(entry.def) then
			entry.machine = nil
		end
	end
	self.machines:ClearAllChildren()
	self:clearDrops()

	self:refreshButtons()
	self:updateSign()
	self:fireOwnedChanged()
	Economy.push(player)

	-- After profile.owned has been wiped, so the milestone Analytics carries
	-- forward is the one this player now stands on rather than the one the
	-- rebirth just took away.
	Analytics.onRebirth(player, profile.rebirths, cost, profile.cash)

	Economy.notify(player, {
		kind = "rebirth",
		title = "SAHUR REBIRTH #" .. profile.rebirths,
		body = ("All payouts are now x%.2f."):format(Economy.multiplier(player)),
	})

	-- #107: the moment's report, DERIVED — every line reads Config or the
	-- profile, so a new tier row cannot ship with a stale list. The client
	-- only renders it.
	do
		local landCount = 0
		for id in pairs(kept) do
			local def = Config.ButtonById[id]
			if def and (def.track == "landL" or def.track == "landR") then
				landCount += 1
			end
		end
		local bat = Config.Bats[math.clamp(profile.batTier or 1, 1, #Config.Bats)]
		local armor = Config.Armor.Tiers[math.clamp(profile.armorTier or 1, 1, #Config.Armor.Tiers)]
		local row = Config.tierRow(profile.rebirths)
		Net.event("RebirthReport"):FireClient(player, {
			rebirths = profile.rebirths,
			multiplier = Economy.multiplier(player),
			rank = row.name,
			motto = row.motto,
			rankChanged = Config.tierName(profile.rebirths) ~= Config.tierName(profile.rebirths - 1),
			keeps = {
				("%s, in your hand"):format(bat and bat.name or "your bat"),
				("%s, on your back"):format(armor and armor.name or "your armour"),
				landCount > 0 and ("%d pieces of ground"):format(landCount) or nil,
				(profile.reputation or 0) >= 1 and ("%d Rep"):format(math.floor(profile.reputation)) or nil,
			},
		})
	end

	local character = player.Character
	if character and character.PrimaryPart then
		Fx.burst(character:GetPivot().Position, Color3.fromRGB(200, 120, 255), 60, workspace)
	end
	return true
end

return Tycoon
