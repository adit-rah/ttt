--[[
	HelpService.lua — kindness earns reputation and a short income boost (#123).

	design:D-04. The counterweight to #94: a server where everyone is prey
	loses its new players, so helping has to pay, and pay MORE for helping
	someone earlier in the game than you. credit() is the one door every
	qualifying act comes through — raid defence today (RaidService), visitor
	repair today (Tycoon's repair observer, wired in Main.server), parties and
	co-combat when #102 and the wave pot arrive.

	THE REWARD IS DELIBERATELY SMALL. A persistent reputation number, and
	BoostMinutes of a BoostMultiplier on income for both sides. At this scale
	two accounts farming each other is acceptable — friends helping friends is
	the behaviour being bought — which is what removes the need for an abuse
	system. The one guard is the per-pair cooldown, and it exists so a tame
	pair cannot hold a boost forever.

	THE WEIGHT IS THE POINT. Each rebirth the helper has over the helped adds
	GapWeightPerRebirth, capped at MaxWeight; the weight scales the reputation
	earned and the helper's boost minutes. A veteran pulling a new player up
	comes out ahead of two peers pairing, which is the issue's whole ask.

	The boost is a named Economy multiplier hook ("help"), the SessionService
	shape: an O(1) expiry read, registered at boot so the require arrow keeps
	pointing at Economy. Clocks are parameters everywhere except the hook,
	which reads os.clock() — the spec harness patches it.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Economy = Req("Economy")
local DataService = Req("DataService")

local Players = game:GetService("Players")

local HelpService = {}

local H = Config.Help

-- boost expiry per player, monotonic seconds. The multiplier hook reads it.
local boostUntil: { [Player]: number } = {}

-- per helper: { [helpedUserId] = cooldown-end }. One pair, one credit per
-- window.
local lastCredit: { [Player]: { [number]: number } } = {}

--- The gap weighting: 1 plus GapWeightPerRebirth per rebirth the helper has
--- over the helped, capped. Helping DOWN the ladder is what pays extra;
--- helping up or across pays the base.
function HelpService.weightFor(helper: Player, helped: Player): number
	local hp = DataService.get(helper)
	local ep = DataService.get(helped)
	if not hp or not ep then
		return 1
	end
	local gap = math.max(0, hp.rebirths - ep.rebirths)
	return math.min(H.MaxWeight, 1 + H.GapWeightPerRebirth * gap)
end

--- Seconds of boost left, for the HUD and the specs.
function HelpService.boostRemaining(player: Player, now: number): number
	return math.max(0, (boostUntil[player] or 0) - now)
end

local function extendBoost(player: Player, minutes: number, now: number)
	local from = math.max(boostUntil[player] or 0, now)
	boostUntil[player] = math.min(from + minutes * 60, now + H.MaxBoostMinutes * 60)
end

--- The one door. Every qualifying kindness lands here; `kind` names the act
--- for the notification. Returns the reputation earned — 0 when refused
--- (self-help, a missing profile, or the pair inside its cooldown).
function HelpService.credit(helper: Player, helped: Player, kind: string, now: number): number
	if helper == helped then
		return 0
	end
	local profile = DataService.get(helper)
	if not profile or not DataService.get(helped) then
		return 0
	end

	local pairs_ = lastCredit[helper]
	if pairs_ and (pairs_[helped.UserId] or 0) > now then
		return 0
	end
	if not pairs_ then
		pairs_ = {}
		lastCredit[helper] = pairs_
	end
	pairs_[helped.UserId] = now + H.PairCooldownSeconds

	local weight = HelpService.weightFor(helper, helped)
	profile.reputation = (profile.reputation or 0) + weight
	Economy.markDirty(helper)

	extendBoost(helper, H.BoostMinutes * weight, now)
	extendBoost(helped, H.BoostMinutes, now)

	Economy.notify(helper, { kind = "claim", title = "Good deed",
		body = ("+%s Rep for %s — income boosted %d min."):format(
			Util.abbreviate(weight), kind, math.floor(HelpService.boostRemaining(helper, now) / 60)) })
	Economy.notify(helped, { kind = "info", title = "Helped",
		body = ("%s had your back (%s) — income boosted %d min."):format(
			helper.Name, kind, math.floor(HelpService.boostRemaining(helped, now) / 60)) })
	return weight
end

function HelpService.start()
	-- the boost, as a named multiplier: an O(1) table read, per the Economy
	-- hook contract
	Economy.setMultiplierHook("help", function(player)
		if (boostUntil[player] or 0) > os.clock() then
			return H.BoostMultiplier
		end
		return 1
	end)
	Players.PlayerRemoving:Connect(function(player)
		boostUntil[player] = nil
		lastCredit[player] = nil
	end)
end

return HelpService
