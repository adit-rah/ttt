--[[
	DisclosureService.lua — the game reveals itself as you can take it (#96).

	design:D-05. One beat computes, per player, which Config.Disclosure rows
	their ownership has earned; a newly earned row is written into
	profile.disclosed (the persisted HIGH-WATER — nothing ever disappears once
	shown, and a returning player is never re-onboarded), announced with one
	toast, and the whole set is pushed down the Disclosure remote for the
	client to render. The client never decides anything.

	GAMEPLAY GATES READ THE SAME TABLE. A row with `gate = true` holds a
	SYSTEM back, not just its pixels: NPCService asks unlocked() before it
	sieges a plot, because a raid siren in the first minute is the overload
	this file exists to prevent. unlocked() answers from the profile, so the
	gate and the interface can never disagree.

	The beat is a 3-second poll over present players — the refreshButtons
	cadence, and the same argument: ownership changes arrive from several
	writers (purchase, admin grant, rebirth wipe) and one reconciler beat is
	simpler than chasing them all. A rebirth wipes `owned` and NOT
	`disclosed`; the high-water is the point.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local Economy = Req("Economy")
local DataService = Req("DataService")

local Players = game:GetService("Players")

local DisclosureService = {}

local remote = Net.event("Disclosure")

--- The one question: has this player ever earned this surface?
function DisclosureService.unlocked(player: Player, id: string): boolean
	local profile = DataService.get(player)
	return profile ~= nil and profile.disclosed ~= nil and profile.disclosed[id] == true
end

local function push(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	local ids = {}
	for id in pairs(profile.disclosed or {}) do
		table.insert(ids, id)
	end
	remote:FireClient(player, { ids = ids })
end

--- One pass for one player: write every newly earned row into the high-water.
--- Returns how many arrived, so the beat knows whether to push.
function DisclosureService.reconcile(player: Player): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	profile.disclosed = profile.disclosed or {}
	local has = function(id)
		return profile.owned[id] == true
	end
	local arrived = 0
	for _, row in ipairs(Config.Disclosure) do
		if not profile.disclosed[row.id] and Config.disclosureEarned(row, has) then
			profile.disclosed[row.id] = true
			arrived += 1
			if row.after then
				-- the always-on rows announce nothing; an arrival is earned
				Economy.notify(player, { kind = "claim", title = "NEW: " .. row.name, body = row.help })
			end
		end
	end
	return arrived
end

function DisclosureService.start()
	Players.PlayerAdded:Connect(function(player)
		task.defer(push, player)
	end)
	task.spawn(function()
		while true do
			task.wait(3)
			for _, player in ipairs(Players:GetPlayers()) do
				local ok, arrived = pcall(DisclosureService.reconcile, player)
				if ok and arrived > 0 then
					push(player)
				elseif not ok then
					warn("[Tung] disclosure error: " .. tostring(arrived))
				end
			end
		end
	end)
end

return DisclosureService
