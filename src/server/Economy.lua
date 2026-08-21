--[[
	Economy.lua — the single place cash is created, spent and replicated.

	IT OWNS profile.cash, the leaderstats folder, and the Stats payload the HUD
	draws itself from. Everything else asks: add, spend, steal, get.

	THERE IS EXACTLY ONE OTHER WRITER, and it is deliberate rather than a leak.
	Tycoon:rebirth resets profile.cash to Config.Economy.StartingCash as part of
	wiping the factory, because the reset and the wipe have to be one act;
	applyRebirthGrants below then tops that up to the rebirth's starting-cash
	grant. Any THIRD writer is a bug — the point of the rule is that "where did
	this money come from" has one answer per source.

	push AND markDirty ARE NOT INTERCHANGEABLE. add() and steal() only mark the
	player dirty and replicate on the 0.1s beat in start(), because droppers pay
	out several times a second and a remote per drop is a remote per drop. spend()
	and applyRebirthGrants() push synchronously, because a purchase that takes a
	tenth of a second to show up reads as a purchase that did not happen. A
	one-off grant therefore has to push for itself; AdminService does, and says
	why.

	THE MULTIPLIER HOOKS MULTIPLY, THEY DO NOT REPLACE. Three names are live:
	"friends" (SocialService), "sessions" (SessionService — the boost and the
	weekend bonus), and "upgrades" (UpgradeService, prototype). The registry is
	keyed so they compose instead of clobbering each other, and
	tools/testing/specs/weekend_spec.lua pins that: a boost on a Saturday must
	come out as x4, because a 3 means someone added them and a 2 means one is
	being silently dropped. Registration is inverted on purpose — the hooks
	register themselves at boot and Economy stays ignorant of what they are —
	because they all depend on Economy and Req refuses a circular require.

	SO A HOOK MUST BE AN O(1) TABLE READ. multiplier() runs on every add(), up to
	~10 times a second per plot at endgame, and every one of those calls walks the
	whole registry. Never a web call, never a DataStore read; SocialService
	resolves friendship on its own timer and the hook reads the result.

	DO NOT PASS applyMultiplier = true FOR A NUMBER THAT ALREADY CARRIES IT.
	SessionService's offline grant is computed from a per-second rate that already
	includes the rebirth multiplier, and AdminService's `$1000` is meant to be
	1000; both pass false, and both would be silently wrong the other way.

	setupLeaderstats SILENTLY DOES NOTHING WITHOUT A LOADED PROFILE — it returns
	on a nil profile rather than yielding — which is the whole reason
	Main.server.lua boots DataService before Economy and calls DataService.load
	before setupLeaderstats. Reordering those lines produces a server with no
	leaderstats and no error.

	BEFORE YOU CHANGE THE CURVE: MultiplierPerRebirth is compounded, not added
	(see multiplier below). tools/verify_config.lua asserts that
	Config.Economy.StartingCash covers the cheapest requirement-free button — a
	fresh player with no dropper has no income and deadlocks — that no other
	track's first rung is affordable from it, and that CostGrowth over
	MultiplierPerRebirth keeps the prestige ladder solvable. Run the verifier
	before you playtest a number in Config.Rebirth or Config.Economy; the curve
	checks are the slowest thing to rediscover by hand.

	This module also runs headless — it is in tools/test.py's SERVER_MODULES, and
	boost_spec, weekend_spec and playtime_spec all observe the game through
	Economy.multiplier and Economy.get. Keep it free of Touched handlers and of
	anything that needs a physics step, or those specs stop being runnable.
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
		armorTier = profile.armorTier,
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

--- mechanism: PROTOTYPE (Config.Prototypes.RebirthPerks). A rebirth pays four
--- things, not one number. `Tycoon:rebirth()` owns two of them — it bumps profile.rebirths
--- (the multiplier) and resets cash to Config.Economy.StartingCash — and it is
--- owned by another track, so the starting-cash grant is applied here, from the
--- one module allowed to create cash.
---
--- `perks` comes from SessionService.rebirthPerksFor(profile). Passing it in
--- rather than computing it keeps the dependency arrow pointing one way.
---
--- Milestone unlocks are DERIVED ON READ and there is nothing here to write.
--- A saved copy of a pure function of profile.rebirths can only go stale, and
--- the one this used to keep had.
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
