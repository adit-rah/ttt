--[[
	Economy.lua — the single place cash is created, spent and replicated.
	Everything else asks this module; nothing else touches profile.cash.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")

local Players = game:GetService("Players")

local DataService = Req("DataService")

local Economy = {}

local statsRemote = Net.event("Stats")
local notifyRemote = Net.event("Notify")

local dirty: { [Player]: boolean } = {}

--- PROTOTYPE HOOKS. Timed boosts, the weekend bonus and (eventually) the
--- player-upgrade cash multiplier all stack on top of rebirth, but Economy
--- must not depend on any of them — they depend on Economy, and Req refuses a
--- circular require. Each registers a named function here at boot and Economy
--- stays ignorant of what they do.
---
--- Keyed rather than a single slot so two prototypes can both stack without
--- silently overwriting each other.
local multiplierHooks: { [string]: (Player) -> number } = {}

function Economy.setMultiplierHook(name: string, fn: ((Player) -> number)?)
	multiplierHooks[name] = fn
end

function Economy.multiplier(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 1
	end
	-- compounding, not linear: rebirth cost grows geometrically (CostGrowth^n)
	-- so a linear payout bonus would make each rebirth strictly worse than the
	-- last and the prestige loop would dead-end after two or three.
	local base = Config.Rebirth.MultiplierPerRebirth ^ profile.rebirths
	for _, hook in pairs(multiplierHooks) do
		base *= hook(player)
	end
	return base
end

function Economy.get(player: Player): number
	local profile = DataService.get(player)
	return profile and profile.cash or 0
end

function Economy.setupLeaderstats(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end

	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player

	local cash = Instance.new("NumberValue")
	cash.Name = Config.Economy.CurrencyName
	cash.Value = profile.cash
	cash.Parent = folder

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = profile.rebirths
	rebirths.Parent = folder

	local kos = Instance.new("IntValue")
	kos.Name = "KOs"
	kos.Value = profile.kills
	kos.Parent = folder
end

local function syncLeaderstats(player: Player)
	local profile = DataService.get(player)
	local folder = player:FindFirstChild("leaderstats")
	if not profile or not folder then
		return
	end
	local cash = folder:FindFirstChild(Config.Economy.CurrencyName)
	if cash then
		(cash :: NumberValue).Value = profile.cash
	end
	local rebirths = folder:FindFirstChild("Rebirths")
	if rebirths then
		(rebirths :: IntValue).Value = profile.rebirths
	end
	local kos = folder:FindFirstChild("KOs")
	if kos then
		(kos :: IntValue).Value = profile.kills
	end
end

function Economy.push(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	syncLeaderstats(player)
	statsRemote:FireClient(player, {
		cash = profile.cash,
		rebirths = profile.rebirths,
		kills = profile.kills,
		batTier = profile.batTier,
		multiplier = Economy.multiplier(player),
		owned = profile.owned,
		rebirthCost = Economy.rebirthCost(player),
	})
end

--- Coalesces rapid-fire updates (droppers) into ~10 replications/sec.
function Economy.markDirty(player: Player)
	dirty[player] = true
end

function Economy.add(player: Player, amount: number, applyMultiplier: boolean?)
	local profile = DataService.get(player)
	if not profile or amount <= 0 then
		return 0
	end
	local final = amount
	if applyMultiplier then
		final = amount * Economy.multiplier(player)
	end
	profile.cash += final
	Economy.markDirty(player)
	return final
end

function Economy.spend(player: Player, amount: number): boolean
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	if profile.cash < amount then
		return false
	end
	profile.cash -= amount
	Economy.push(player)
	return true
end

--- Raiders nibble a slice of your bank when they land a hit.
function Economy.steal(player: Player, fraction: number): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local taken = math.floor(profile.cash * fraction)
	if taken <= 0 then
		return 0
	end
	profile.cash -= taken
	Economy.markDirty(player)
	return taken
end

function Economy.rebirthCost(player: Player): number
	local profile = DataService.get(player)
	local n = profile and profile.rebirths or 0
	return math.floor(Config.Rebirth.BaseCost * (Config.Rebirth.CostGrowth ^ n))
end

--- PROTOTYPE (Config.Prototypes.RebirthPerks). A rebirth pays four things, not
--- one number. `Tycoon:rebirth()` owns two of them — it bumps profile.rebirths
--- (the multiplier) and resets cash to Config.Economy.StartingCash — and it is
--- owned by another track, so the other two are applied here, from the one
--- module allowed to create cash.
---
--- `perks` comes from SessionService.rebirthPerksFor(profile). Passing it in
--- rather than computing it keeps the dependency arrow pointing one way.
---
--- Idempotent on purpose: it tops cash UP to the grant instead of adding to
--- it, so a double call (a retry, a re-detect) cannot be farmed.
function Economy.applyRebirthGrants(player: Player, perks): number
	local profile = DataService.get(player)
	if not profile or not perks then
		return 0
	end

	local granted = 0
	local target = math.floor(tonumber(perks.startingCash) or 0)
	if target > profile.cash then
		granted = target - profile.cash
		profile.cash = target
	end

	if type(perks.unlocks) == "table" then
		if type(profile.unlocks) ~= "table" then
			profile.unlocks = {}
		end
		for id, label in pairs(perks.unlocks) do
			profile.unlocks[id] = label
		end
	end

	Economy.push(player)
	return granted
end

function Economy.notify(player: Player, payload)
	notifyRemote:FireClient(player, payload)
end

function Economy.start()
	task.spawn(function()
		while true do
			task.wait(0.1)
			for player in pairs(dirty) do
				dirty[player] = nil
				if player.Parent then
					Economy.push(player)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
	end)
end

Economy.format = Util.abbreviate

return Economy
