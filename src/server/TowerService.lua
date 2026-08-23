--[[
	TowerService.lua — the daily tower (#95).

	design:D-04. Combat with a shape: Config.towerFloors deals the day's
	composition from the UTC day number, a party (#102) or a lone player
	climbs it, each floor pays every member minutes of their OWN income on
	the spot, and a wipe keeps what it cleared. The top floor is always the
	boss.

	THE LEDGER AND THE RUN ARE SPLIT, the RecallService arrangement. today(),
	bestFloor and recordClear are arithmetic over clocks and profiles and run
	headless; the run driver — the platform in the sky, the spawns through
	NPCService.spawn, the timers, the wipe detection — needs characters and a
	workspace and lives below start(). The handoff owns proving it in Studio.

	FLOORS FIGHT ON A PLATFORM AT PlatformY, one platform per concurrent run,
	spaced along X. Enemies are ordinary Sahur through the one minting site,
	leashed to the platform; falling off the edge is the survival floor's
	failure mode and the platform is sized so that is a choice.

	ENTRY IS A PROMPT ON THE SPIRE at the core's edge. The prompt brings the
	presser's whole party; solo is a party of one. No remote: the intent has
	no payload, the CollectOffline argument.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local Economy = Req("Economy")
local DataService = Req("DataService")
local SessionService = Req("SessionService")
local PartyService = Req("PartyService")

-- Resolved in start(): the run driver's dependency, and the spec bundle
-- carries neither NPCService nor the workspace the driver needs.
local NPCService = nil

local TowerService = {}

local T = Config.Tower

--- The UTC day number — the weekend bonus's clock, so the tower and the
--- weekend agree on when a day turns.
function TowerService.today(now: number): number
	return math.floor(now / 86400)
end

--- The best floor this player has reached TODAY; yesterday's number reads as
--- zero by arithmetic.
function TowerService.bestFloor(player: Player, now: number): number
	local profile = DataService.get(player)
	if not profile or not profile.tower then
		return 0
	end
	return profile.tower.day == TowerService.today(now) and profile.tower.best or 0
end

--- One member's pay for one cleared floor: minutes of their OWN income rate,
--- through the capped door like every other inflow. Progress persists as
--- today's best.
function TowerService.recordClear(player: Player, floor: number, now: number, bonusMinutes: number?): number
	local profile = DataService.get(player)
	if not profile then
		return 0
	end
	local reward = math.floor((T.FloorRewardMinutes + (bonusMinutes or 0)) * 60
		* SessionService.incomePerSecondFor(profile))
	local gained = Economy.add(player, reward, false)
	profile.tower = {
		day = TowerService.today(now),
		best = math.max(TowerService.bestFloor(player, now), floor),
	}
	Economy.push(player)
	return gained
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the run driver: everything below needs a workspace
-- ─────────────────────────────────────────────────────────────────────────────

local runs: { any } = {}   -- slot index -> run or nil
local deckLabel = nil      -- the spire sign's rows; painted per day

local function platformOrigin(slot: number): Vector3
	return Vector3.new((slot - 1) * T.PlatformSize * 3, T.PlatformY, 0)
end

local function membersOf(player: Player): { Player }
	local party = PartyService.partyOf(player)
	if party then
		return table.clone(party)
	end
	return { player }
end

--- The banner's packet (#145): pushed to every member on floor events.
--- secondsLeft rather than a deadline, because the client's clock is not
--- this server's.
local function pushRun(run, over: boolean?)
	local now = os.clock()
	local secondsLeft = nil
	if run.surviveUntil then
		secondsLeft = math.max(0, math.ceil(run.surviveUntil - now))
	elseif run.floorDeadline and run.floorDeadline ~= math.huge then
		secondsLeft = math.max(0, math.ceil(run.floorDeadline - now))
	end
	for _, member in ipairs(run.members) do
		if member.Parent then
			Net.event("TowerState"):FireClient(member, {
				floor = run.floor,
				total = T.Floors,
				archetype = run.deck[run.floor],
				modifier = run.modifier and run.modifier.name or nil,
				secondsLeft = secondsLeft,
				best = TowerService.bestFloor(member, os.time()),
				over = over or nil,
			})
		end
	end
end

local function notifyRun(run, payload)
	for _, member in ipairs(run.members) do
		if member.Parent then
			Economy.notify(member, payload)
		end
	end
end

--- A member is still climbing while alive and on the platform's level.
local function livingMembers(run): number
	local count = 0
	for _, member in ipairs(run.members) do
		local character = member.Parent and member.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0
				and math.abs(root.Position.Y - T.PlatformY) < 80 then
			count += 1
		end
	end
	return count
end

local function teleportRun(run)
	for index, member in ipairs(run.members) do
		local character = member.Parent and member.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			root.CFrame = CFrame.new(run.origin + Vector3.new(index * 4 - 8, 4, T.PlatformSize / 3))
		end
	end
end

local function endRun(run, cleared: boolean)
	runs[run.slot] = nil
	pushRun(run, true)
	for npc, entry in pairs(NPCService.activeEntries()) do
		if entry.tower == run then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end
	end
	if run.platform then
		run.platform:Destroy()
	end
	notifyRun(run, { kind = cleared and "boss" or "wave",
		title = cleared and "TOWER CLEARED" or "THE TOWER HOLDS",
		body = cleared and "Every floor, down. Come back tomorrow."
			or ("You fell on floor %d. Cleared floors stay paid."):format(run.floor) })
	-- home, the placement everything uses
	local PlotService = Req("PlotService")
	for _, member in ipairs(run.members) do
		if member.Parent then
			PlotService.teleportToPlot(member)
		end
	end
end

local function spawnFloor(run)
	local archetype = run.deck[run.floor]
	local level = Config.towerLevel(run.floor)
	local record = { number = level, alive = 0, spawned = 0 }
	run.record = record
	run.floorDeadline = archetype == "timed" and (os.clock() + T.TimedSeconds) or math.huge
	run.surviveUntil = archetype == "survival" and (os.clock() + T.SurvivalSeconds) or nil

	local count = archetype == "boss" and 1 or (T.WaveCount + #run.members - 1)
	if archetype == "survival" then
		count = math.max(2, math.floor(count / 2))
	end
	local modifier = run.modifier or {}
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local radius = T.PlatformSize / 2 - 8
		local position = run.origin + Vector3.new(math.sin(angle) * radius, 6, math.cos(angle) * radius)
		local entry = NPCService.spawn({
			level = level,
			boss = archetype == "boss",
			position = position,
			home = run.origin + Vector3.new(0, 2, 0),
			leash = T.PlatformSize,
			record = record,
			index = i,
			count = count,
			despawnAt = os.clock() + 600,
			healthScale = modifier.healthScale,
			walkScale = modifier.walkScale,
		})
		entry.tower = run
	end

	local what = ({
		wave = ("floor %d — clear the pack"):format(run.floor),
		boss = ("floor %d — the boss"):format(run.floor),
		timed = ("floor %d — %d kills in %ds"):format(run.floor, count, T.TimedSeconds),
		survival = ("floor %d — survive %ds"):format(run.floor, T.SurvivalSeconds),
	})[archetype]
	notifyRun(run, { kind = "wave", title = "THE TOWER", body = what })
	pushRun(run)
end

local function stepRun(run)
	local now = os.clock()
	if livingMembers(run) == 0 then
		endRun(run, false)
		return
	end
	-- the banner's countdown rides the step beat; only clocked floors repush
	if run.surviveUntil or (run.floorDeadline and run.floorDeadline ~= math.huge) then
		pushRun(run)
	end
	local archetype = run.deck[run.floor]
	local clearedFloor = false
	if archetype == "survival" then
		clearedFloor = now >= run.surviveUntil
	else
		clearedFloor = run.record.alive <= 0
		if archetype == "timed" and now >= run.floorDeadline and not clearedFloor then
			endRun(run, false)
			return
		end
	end
	if clearedFloor then
		-- a survival floor is cleared by the CLOCK, so its pack can outlive
		-- it; the leftovers die before the next floor deals its own
		for npc, entry in pairs(NPCService.activeEntries()) do
			if entry.waveRecord == run.record and not entry.dead then
				local humanoid = npc:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Health = 0
				end
			end
		end
		local bonus = (run.modifier and run.modifier.bonusMinutes) or 0
		for _, member in ipairs(run.members) do
			if member.Parent then
				local gained = TowerService.recordClear(member, run.floor, os.time(), bonus)
				Economy.notify(member, { kind = "claim", title = "Floor cleared",
					body = ("+%s — your %d minutes of income."):format(Util.abbreviate(gained), T.FloorRewardMinutes + bonus) })
			end
		end
		if run.floor >= T.Floors then
			endRun(run, true)
			return
		end
		run.floor += 1
		spawnFloor(run)
	end
end

local function buildPlatform(origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "TowerFloor"
	local floor = Instance.new("Part")
	floor.Name = "Deck"
	floor.Size = Vector3.new(T.PlatformSize, 2, T.PlatformSize)
	floor.CFrame = CFrame.new(origin)
	floor.Anchored = true
	floor.Color = Color3.fromRGB(58, 52, 74)
	floor.Material = Enum.Material.Slate
	floor.Parent = model
	model.Parent = workspace
	return model
end

local function beginRun(presser: Player)
	local slot
	for index = 1, T.MaxConcurrentRuns do
		if not runs[index] then
			slot = index
			break
		end
	end
	if not slot then
		Economy.notify(presser, { kind = "warn", title = "THE TOWER",
			body = "Every climb is taken — try again in a minute." })
		return
	end
	local members = membersOf(presser)
	for _, member in ipairs(members) do
		for _, run in pairs(runs) do
			for _, climber in ipairs(run.members) do
				if climber == member then
					Economy.notify(presser, { kind = "warn", title = "THE TOWER",
						body = "Someone in your party is already climbing." })
					return
				end
			end
		end
	end

	local day = TowerService.today(os.time())
	local run = {
		slot = slot,
		members = members,
		deck = Config.towerFloors(day),
		modifier = Config.towerModifier(day),
		floor = 1,
		origin = platformOrigin(slot),
	}
	runs[slot] = run
	run.platform = buildPlatform(run.origin)
	teleportRun(run)
	spawnFloor(run)
end

--- The spire at the core's edge, and the prompt that starts a climb.
local function buildEntrance()
	local model = Instance.new("Model")
	model.Name = "Tower"
	local bearing = math.pi   -- opposite the spawn pad
	local base = Vector3.new(math.sin(bearing) * T.EntranceRadius, 0, math.cos(bearing) * T.EntranceRadius)
	for storey = 1, 6 do
		local part = Instance.new("Part")
		part.Name = "Spire" .. storey
		local width = 26 - storey * 3
		part.Size = Vector3.new(width, 14, width)
		part.CFrame = CFrame.new(base + Vector3.new(0, storey * 14 - 7, 0))
			* CFrame.Angles(0, storey * 0.2, 0)
		part.Anchored = true
		part.Color = Color3.fromRGB(44, 38, 58)
		part.Material = Enum.Material.Slate
		part.Parent = model
	end
	local door = Instance.new("Part")
	door.Name = "Door"
	door.Size = Vector3.new(8, 10, 2)
	door.CFrame = CFrame.new(base + Vector3.new(0, 5, 14))
	door.Anchored = true
	door.Color = Color3.fromRGB(255, 205, 90)
	door.Material = Enum.Material.Neon
	door.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterTower"
	prompt.ActionText = "Climb"
	prompt.ObjectText = "The Tower"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = door
	prompt.Triggered:Connect(beginRun)

	-- #145: today's deck, previewed at the door — a party can talk about the
	-- climb before taking it. Repainted when the day turns.
	local Style = Req("Style")
	local billboard = Style.billboard(door, {
		name = "Deck", width = 24, height = 8, distance = "prop", offset = 8,
	})
	deckLabel = Style.text(billboard, {
		name = "Rows", text = "",
		color = Color3.fromRGB(235, 200, 255),
	})

	model.Parent = workspace
end

--- The sign's copy for one day: the deck in climb order, and the twist.
local function paintDeck()
	if not deckLabel then
		return
	end
	local day = TowerService.today(os.time())
	local deck = Config.towerFloors(day)
	local names = {}
	for _, archetype in ipairs(deck) do
		table.insert(names, archetype:upper():sub(1, 4))
	end
	local modifier = Config.towerModifier(day)
	deckLabel.Text = ("THE TOWER  •  today: %s\n%s — %s\na new tower every day")
		:format(table.concat(names, " "), modifier.name, modifier.blurb)
end

function TowerService.start()
	NPCService = Req("NPCService")
	buildEntrance()
	paintDeck()
	local paintedDay = TowerService.today(os.time())
	task.spawn(function()
		while true do
			task.wait(1)
			for _, run in pairs(runs) do
				local ok, err = pcall(stepRun, run)
				if not ok then
					warn("[Tung] tower step error: " .. tostring(err))
				end
			end
			local day = TowerService.today(os.time())
			if day ~= paintedDay then
				paintedDay = day
				pcall(paintDeck)
			end
		end
	end)
end

return TowerService
