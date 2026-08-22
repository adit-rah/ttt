--[[
	tycoon/Siege.lua — the walls and the gate can be broken, and the owner
	repairs them.

	design:D-02, via #124. The wall is the boundary the open world will press
	against: mobs will wear it down when #89 lets them reach it, a raiding
	player breaks the GATE to get in (#94), and both scale with the land —
	level is expansions owned + 1, so toughness arrives with the ground and
	there is no separate wall ladder.

	AUTHORITY IS THE TABLE, THE PARTS ARE A PICTURE. self.structureHealth maps
	a siege key — "wall_front", "wall_left", "gate_gateway", one per side and
	one per opening — to hit points, assigned from Config.wallMaxHealth /
	gateMaxHealth and never accumulated. A broken wall has no parts to carry
	an attribute, which is why the table is the authority; applySiegeState
	makes the ring agree with it after every rebuild, so the refreshButtons
	beat cannot resurrect a wall the raiders earned.

	KEYS ARE STABLE ACROSS LAND STATES. A side is one damage unit whatever its
	span count — course names shift as land splits the runs, sides do not —
	and an opening's id never changes. That is what lets damage persist (#124
	ships it as fractions in the profile) without a rename ever forgiving it.

	DAMAGE COMES THROUGH ONE DOOR. Tycoon.siegeStrike receives the parts a
	swing boxed (Main.server wires it into CombatService's structure observer,
	keeping the require arrows one-way), resolves them to plot + key, refuses
	the plot's own owner, and applies one hit per key per swing. Mobs get the
	same door when #89 wires them.

	NO REMOTE, the CollectOffline argument: a repair intent has no payload, so
	the ProximityPrompt on the stump is the whole interface and the handler
	re-checks the owner.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Fx = Req("Fx")
local DataService = Req("DataService")
local Tycoon = Req("Class")

local S = Config.Structure
local H = S.Health

local STUMP_COLOR = Color3.fromRGB(64, 48, 38)
local WALL_COLOR = Color3.fromRGB(150, 111, 74)

-- Course prefixes that belong to a wall side. `Sill` is deliberately absent:
-- the sill course survives a break as the stump the repair prompt stands on.
local BREAKABLE_PREFIXES = { Pier = true, Pane = true, Head = true, Lintel = true }

--- The siege level: expansions owned + 1. Derived, never stored.
function Tycoon:siegeLevel(): number
	local counts = self:landState()
	return counts.left + counts.right + 1
end

--- Full health for one siege key at the current level.
function Tycoon:siegeMaxHealth(key: string): number
	if key:sub(1, 5) == "gate_" then
		return Config.gateMaxHealth(self:siegeLevel())
	end
	return Config.wallMaxHealth(self:siegeLevel())
end

--- Every siege key this plot has: one per side, one per opening.
function Tycoon:siegeKeys(): { string }
	local keys = {}
	for _, side in ipairs(S.Sides) do
		table.insert(keys, "wall_" .. side)
	end
	for _, opening in ipairs(S.Openings) do
		table.insert(keys, "gate_" .. opening.id)
	end
	return keys
end

--- Fresh tenancy or repair: every key at full. assign() overwrites this from
--- the saved fractions right after.
function Tycoon:resetSiege()
	self.structureHealth = {}
	for _, key in ipairs(self:siegeKeys()) do
		self.structureHealth[key] = self:siegeMaxHealth(key)
	end
end

--- Mirror the dents into the profile, as fractions of full health — only
--- keys below full, so a healthy plot saves an empty table and a dent
--- survives the max moving when the plot buys land. Called on every damage,
--- repair and reset; a plot with no owner has no profile to write.
function Tycoon:syncSiege()
	local owner = self.owner
	local profile = owner and DataService.get(owner)
	if not profile then
		return
	end
	local out = {}
	for _, key in ipairs(self:siegeKeys()) do
		local hp = self.structureHealth[key]
		local max = self:siegeMaxHealth(key)
		if hp and hp < max then
			out[key] = hp / max
		end
	end
	profile.structure = out
end

--- The other half of the round trip, run by assign() after the install
--- replay has stood the walls up: saved fractions scale onto the CURRENT
--- maxes, and the ring is made to agree.
function Tycoon:restoreSiege(profile)
	for key, fraction in pairs(profile.structure or {}) do
		if type(fraction) == "number" and self.structureHealth[key] ~= nil then
			self.structureHealth[key] = self:siegeMaxHealth(key) * math.clamp(fraction, 0, 1)
		end
	end
	self:withWallRing(function(ring)
		self:applySiegeState(ring)
	end)
end

function Tycoon:structureBroken(key: string): boolean
	local hp = self.structureHealth and self.structureHealth[key]
	return hp ~= nil and hp <= 0
end

--- The side a wall-course part belongs to, or the opening a leaf hangs in,
--- as a siege key — nil for anything that is not siege-able.
function Tycoon.siegeKeyForPart(part: BasePart): string?
	local prefix, rest = part.Name:match("^(%a+)_(.+)$")
	if not prefix then
		return nil
	end
	if prefix == "Gate" then
		local opening = rest:match("^([%w]+)_%d+$")
		return opening and ("gate_" .. opening) or nil
	end
	if BREAKABLE_PREFIXES[prefix] or prefix == "Sill" then
		local side = rest:match("^(%a+)")
		if side == "back" or side == "front" or side == "left" or side == "right" then
			return "wall_" .. side
		end
	end
	return nil
end

--- Make the standing ring agree with the health table: a broken side keeps
--- its sill course as a charred stump and loses everything above it; a broken
--- gate loses its leaves. Idempotent, and called at the end of buildWallRing,
--- so the refreshButtons beat re-applies breakage instead of healing it.
function Tycoon:applySiegeState(ring: Instance)
	for _, part in ipairs(ring:GetChildren()) do
		if part:IsA("BasePart") then
			local key = Tycoon.siegeKeyForPart(part)
			if key and self:structureBroken(key) then
				local prefix = part.Name:match("^(%a+)_")
				if prefix == "Sill" then
					part.Color = STUMP_COLOR
				elseif prefix == "Gate" or BREAKABLE_PREFIXES[prefix] then
					part:Destroy()
				end
			elseif key then
				local prefix = part.Name:match("^(%a+)_")
				if prefix == "Sill" and part.Color == STUMP_COLOR then
					part.Color = WALL_COLOR
				end
			end
		end
	end
	self:refreshSiegePrompts(ring)
end

--- One repair prompt per broken key, standing on the stump (walls) or on an
--- invisible anchor at the opening (gates). Enabled only while broken.
function Tycoon:refreshSiegePrompts(ring: Instance)
	for _, key in ipairs(self:siegeKeys()) do
		local anchorName = "SiegeAnchor_" .. key
		local anchor = ring:FindFirstChild(anchorName, true)
		local broken = self:structureBroken(key)
		if broken and not anchor then
			-- The host outlives the break by construction: a wall's sill
			-- course is the stump a break leaves, and a gate break destroys
			-- only its leaves, so the lintel over the opening still stands.
			local hostPrefix, hostKey = "Sill_", key
			if key:sub(1, 5) == "gate_" then
				hostPrefix = "Lintel_"
				for _, opening in ipairs(S.Openings) do
					if "gate_" .. opening.id == key then
						hostKey = "wall_" .. opening.side
					end
				end
			end
			local host
			for _, part in ipairs(ring:GetChildren()) do
				if part:IsA("BasePart") and part.Name:sub(1, #hostPrefix) == hostPrefix
						and Tycoon.siegeKeyForPart(part) == hostKey then
					host = part
					break
				end
			end
			if host then
				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = anchorName
				prompt.ActionText = "Repair"
				prompt.ObjectText = key:sub(1, 5) == "gate_" and "Gate" or "Wall"
				prompt.HoldDuration = H.RepairSeconds
				prompt.MaxActivationDistance = 16
				prompt.RequiresLineOfSight = false
				prompt.Parent = host
				prompt.Triggered:Connect(function(player)
					self:repairStructure(key, player)
				end)
			end
		elseif not broken and anchor then
			anchor:Destroy()
		end
	end
end

--- One hit on one key. Returns the damage dealt — 0 for a key already down,
--- which is how a caller counts wasted swings.
function Tycoon:damageStructure(key: string, amount: number, _attacker: Player?): number
	if not self.structureHealth or self.structureHealth[key] == nil then
		return 0
	end
	if amount <= 0 or self:structureBroken(key) then
		return 0
	end
	self.structureHealth[key] = math.max(0, self.structureHealth[key] - amount)
	if self.structureHealth[key] <= 0 then
		self:withWallRing(function(ring)
			self:applySiegeState(ring)
		end)
	end
	self:syncSiege()
	return amount
end

--- The owner, present, holding the prompt: the whole repair. The rebuild path
--- is the ring's own idempotent builders — rebuildWallRing re-emits the
--- courses and hangGateLeaves the leaves, and applySiegeState (now healthy)
--- leaves them standing.
function Tycoon:repairStructure(key: string, player: Player): boolean
	if player ~= self.owner or not self:structureBroken(key) then
		return false
	end
	self.structureHealth[key] = self:siegeMaxHealth(key)
	self:syncSiege()
	self:rebuildWallRing()
	local character = player.Character
	if character and character.PrimaryPart then
		Fx.burst(character:GetPivot().Position, Color3.fromRGB(180, 220, 140), 10, workspace)
	end
	return true
end

--- Ancestry by walking `.Parent`, which the spec harness's Instances carry;
--- `IsDescendantOf` they do not, and this is the one place it would be asked.
local function isUnder(part: Instance, root: Instance): boolean
	local node = part
	while node do
		if node == root then
			return true
		end
		node = node.Parent
	end
	return false
end

--- The one door swing damage comes through. `parts` is everything one swing
--- boxed; each siege key it touched takes ONE hit — `struck` is the dedup
--- and the CALLER owns it, because a swing strikes twice (CombatService
--- samples the arc a frame apart) and the second sample must not land a
--- second hit. The plot's own owner is refused — no accidental
--- self-demolition — and the arena's PvP rule is deliberately not consulted:
--- a raider breaks a gate wherever the gate is.
function Tycoon.siegeStrike(parts: { BasePart }, attacker: Player, damage: number, struck: { [any]: any }?)
	struck = struck or {}
	for _, part in ipairs(parts) do
		local key = Tycoon.siegeKeyForPart(part)
		if key then
			for _, tycoon in ipairs(Tycoon.all()) do
				if tycoon.model and isUnder(part, tycoon.model) then
					if tycoon.owner ~= attacker and not struck[tycoon] then
						struck[tycoon] = {}
					end
					if struck[tycoon] and not struck[tycoon][key] then
						struck[tycoon][key] = true
						tycoon:damageStructure(key, damage * H.PlayerDamageScale, attacker)
					end
					break
				end
			end
		end
	end
end

return Tycoon
