--[[
	ObjectiveService.lua — three things to do today (#97).

	design:D-01. The day deals three objectives from the pool (the tower's
	seeded draw, identical on every server), each pays minutes of the
	player's OWN income on completion (the tower's denomination), and the
	verifier bounds what a whole day may pay — the streak and the offline
	grant are why players log in; this is a nudge.

	PROGRESS IS A BASELINE, NOT A COUNTER. The day's first beat snapshots the
	live profile stats (kills, owned count, reputation); progress is the live
	stat minus the snapshot, so nothing has to observe kills or purchases —
	the stats already persist, and the reset is the tower's day arithmetic.
	Completion is written into profile.objectives.done and paid once.

	The hint line rides the same push: the first Config.Hints row whose stat
	the player has not reached. The guide NPC (#100) reads hintFor too.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local Economy = Req("Economy")
local DataService = Req("DataService")
local SessionService = Req("SessionService")

local Players = game:GetService("Players")

local ObjectiveService = {}

local remote = Net.event("Objectives")

local function ownedCount(profile): number
	local count = 0
	for _ in pairs(profile.owned or {}) do
		count += 1
	end
	return count
end

--- The live reading for one stat name.
local function statOf(profile, stat: string, now: number): number
	if stat == "kills" then
		return profile.kills or 0
	elseif stat == "buys" then
		return ownedCount(profile)
	elseif stat == "reputation" then
		return math.floor(profile.reputation or 0)
	elseif stat == "towerBest" then
		local tower = profile.tower
		return (tower and tower.day == math.floor(now / 86400)) and tower.best or 0
	end
	return 0
end

--- The first hint the player has not earned past, or nil when they are past
--- all of them. #100's guide speaks this line too.
function ObjectiveService.hintFor(profile): string?
	for _, hint in ipairs(Config.Hints) do
		if (profile[hint.stat] or 0) < hint.atLeast then
			return hint.text
		end
	end
	return nil
end

--- One player's pass: roll the day, snapshot baselines, measure progress,
--- pay crossings. Returns the renderable rows. `now` is UTC seconds.
function ObjectiveService.reconcile(player, now: number)
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	local day = math.floor(now / 86400)
	local state = profile.objectives
	if not state or state.day ~= day then
		state = { day = day, baseline = {}, done = {} }
		profile.objectives = state
	end

	local rows = {}
	for _, def in ipairs(Config.objectivesFor(day)) do
		-- the baseline is the day's FIRST sight of the stat; towerBest is
		-- already day-scoped so its baseline is zero by construction
		local baseline = state.baseline[def.stat]
		if baseline == nil then
			baseline = def.stat == "towerBest" and 0 or statOf(profile, def.stat, now)
			state.baseline[def.stat] = baseline
		end
		local progress = math.max(0, statOf(profile, def.stat, now) - baseline)

		if progress >= def.count and not state.done[def.id] then
			state.done[def.id] = true
			local reward = math.floor(def.rewardMinutes * 60 * SessionService.incomePerSecondFor(profile))
			local gained = Economy.add(player, reward, false)
			Economy.push(player)
			Economy.notify(player, { kind = "claim", title = "Objective done",
				body = ("%s  •  +%s"):format(def.name, Util.abbreviate(gained)) })
		end

		table.insert(rows, {
			id = def.id,
			name = def.name,
			progress = math.min(progress, def.count),
			count = def.count,
			done = state.done[def.id] == true,
		})
	end
	return rows
end

function ObjectiveService.start()
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in ipairs(Players:GetPlayers()) do
				local ok, rows = pcall(ObjectiveService.reconcile, player, os.time())
				if ok and rows then
					local profile = DataService.get(player)
					remote:FireClient(player, {
						rows = rows,
						hint = profile and ObjectiveService.hintFor(profile) or nil,
					})
				elseif not ok then
					warn("[Tung] objective error: " .. tostring(rows))
				end
			end
		end
	end)
end

return ObjectiveService
