--[[
	tycoon/Storage.lua — the storage unit's health, and the repair that needs
	the owner standing at it.

	design:D-02, via #93 — the vault body is the storage unit: it has health, a
	raider hits it with a bat, and while it is broken the plot cannot bank
	overflow. Where it stands and what it looks like are #88 and #126; what a
	raid takes from it is #94; the cap it holds is #98. This file is the state
	machine those tickets call into.

	AUTHORITY IS THE TABLE, THE ATTRIBUTES ARE A MIRROR. self.storage holds
	health and brokenness; StorageHealth/StorageMaxHealth/StorageBroken on the
	vault base replicate so a client bar can draw with no remote, and nothing
	server-side may read them back.

	damageStorage IS THE SEAM. Raids (#94), mobs and bosses (#124) all land
	here, and damage already scales by storedOverflowFraction — which returns 0
	until #98 gives the unit a cap, so the raid arithmetic arrives in one place
	later with no caller changing.

	NO REMOTE, same argument as CollectOffline: the repair intent has no
	payload, so there is no number for a client to send and none for the server
	to disbelieve. The ProximityPrompt is only enabled while broken, and the
	handler re-checks the owner anyway.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Economy = Req("Economy")
local Tycoon = Req("Class")

local COLORS = Tycoon.COLORS
local S = Config.Storage

-- The charred coat a broken unit wears. A constant here rather than a lerp of
-- the live colour, so repair can restore COLORS.vault exactly.
local BROKEN_COLOR = Color3.fromRGB(38, 30, 34)

--- Fresh tenancy, full unit. assign() and release() both call this; a rebirth
--- keeps the owner and deliberately keeps the unit's dents with them.
function Tycoon:resetStorage()
	self.storage = { health = S.MaxHealth, broken = false }
	local base = self.storageBase
	if base and base.Parent then
		base.Color = COLORS.vault
	end
	self:mirrorStorage()
end

--- Writes the replication mirror. One writer: every state change ends here.
function Tycoon:mirrorStorage()
	local base = self.storageBase
	if base and base.Parent then
		base:SetAttribute("StorageHealth", self.storage.health)
		base:SetAttribute("StorageMaxHealth", S.MaxHealth)
		base:SetAttribute("StorageBroken", self.storage.broken)
		base:SetAttribute("StorageFill", self:storedOverflowFraction())
	end
	if self.storagePrompt and self.storagePrompt.Parent then
		self.storagePrompt.Enabled = self.storage.broken
	end
end

--- Hangs the repair prompt on the vault base. Called by buildCollector on the
--- headline vault only — the plot has one storage unit, whatever it grows.
function Tycoon:buildStorageUnit(base: BasePart)
	self.storageBase = base

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RepairStorage"
	prompt.ActionText = "Repair"
	prompt.ObjectText = "Storage Unit"
	prompt.HoldDuration = S.RepairHoldSeconds
	prompt.MaxActivationDistance = Config.Offline.Vault.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false          -- nothing to repair until something breaks
	prompt.Parent = base
	prompt.Triggered:Connect(function(player)
		self:repairStorage(player)
	end)
	self.storagePrompt = prompt

	self:mirrorStorage()
end

--- How full the unit is: the owner's banked Tung against the cap (#98).
--- The damage scaling below and #94's loot arithmetic read the same number,
--- which is the whole reason it is one function.
function Tycoon:storedOverflowFraction(): number
	local owner = self.owner
	if not owner then
		return 0
	end
	local cap = Economy.storageCapFor(owner)
	if cap <= 0 then
		return 0
	end
	return math.clamp(Economy.get(owner) / cap, 0, 1)
end

--- The predicate #98's overflow banking consults: a broken unit banks nothing.
function Tycoon:storageIntact(): boolean
	return self.storage.broken ~= true
end

-- The break observer: fires once per break, on the transition only, with the
-- attacker who landed it. Main.server points this at RaidService (#94) —
-- the service requires this world, so the arrow cannot point back.
Tycoon.storageBreakObserver = nil :: ((any, Player) -> ())?

--- One hit on the unit. Returns the damage actually dealt — a broken unit
--- absorbs nothing more, so hitting it again is wasted swings, and the return
--- value is how #94 will know the difference.
function Tycoon:damageStorage(amount: number, attacker: Player?): number
	if amount <= 0 or self.storage.broken then
		return 0
	end
	local scaled = amount * (1 + S.DamagePerOverflowFraction * self:storedOverflowFraction())
	self.storage.health = math.max(0, self.storage.health - scaled)
	if self.storage.health <= 0 then
		self.storage.broken = true
		local base = self.storageBase
		if base and base.Parent then
			base.Color = BROKEN_COLOR
		end
		if attacker and Tycoon.storageBreakObserver then
			Tycoon.storageBreakObserver(self, attacker)
		end
	end
	self:mirrorStorage()
	return scaled
end

--- The owner, present, pressing the thing: the whole repair. Anyone else, or
--- an intact unit, is refused.
function Tycoon:repairStorage(player: Player): boolean
	if player ~= self.owner or not self.storage.broken then
		return false
	end
	self.storage.health = S.MaxHealth
	self.storage.broken = false
	local base = self.storageBase
	if base and base.Parent then
		base.Color = COLORS.vault
	end
	self:mirrorStorage()
	return true
end

return Tycoon
