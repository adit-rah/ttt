--[[
	NPCService.lua — the Sahur Raid.

	Every few minutes a wave of Tung Tung Tung Sahur raiders spawns at the
	arena rim and goes looking for players. They hit hard, they nibble your
	bank, and they pay out well when you knock them down.

	All NPCs are ticked from one loop rather than a thread each.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local Net = Req("Net")
local TungModels = Req("TungModels")
local Economy = Req("Economy")
local DataService = Req("DataService")
local CombatService = Req("CombatService")

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local NPCService = {}

local waveRemote = Net.event("WaveState")
local notifyRemote = Net.event("Notify")

local WV = Config.Waves

local active: { [Model]: any } = {}
local folder: Folder
local waveNumber = 0
local aliveCount = 0

-- raider flavour escalates with the wave number
local WAVE_VARIANTS = { "classic", "oak", "ash", "crimson", "neon", "void", "eclipse", "galaxy", "infinity" }

local function variantForWave(wave: number, boss: boolean): string
	local index = math.clamp(math.floor((wave - 1) / 2) + 1, 1, #WAVE_VARIANTS)
	if boss then
		index = math.clamp(index + 2, 1, #WAVE_VARIANTS)
	end
	return WAVE_VARIANTS[index]
end

local function broadcast(payload)
	waveRemote:FireAllClients(payload)
end

-- ─────────────────────────────────────────────────────────────────────────────

local function nearestPlayer(position: Vector3, maxDistance: number): (Player?, Model?, number)
	local bestPlayer, bestChar, bestDistance = nil, nil, maxDistance
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and humanoid and humanoid.Health > 0 then
			local distance = (character:GetPivot().Position - position).Magnitude
			if distance < bestDistance then
				bestPlayer, bestChar, bestDistance = player, character, distance
			end
		end
	end
	return bestPlayer, bestChar, bestDistance
end

local function killReward(wave: number, boss: boolean): number
	local reward = WV.RewardBase * (WV.RewardGrowth ^ (wave - 1))
	if boss then
		reward *= WV.BossHealthMultiplier
	end
	return math.floor(reward)
end

local function onRaiderDied(npc: Model, entry)
	if entry.dead then
		return
	end
	entry.dead = true
	aliveCount = math.max(0, aliveCount - 1)

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local tag = humanoid and humanoid:FindFirstChild("creator") :: ObjectValue?
	local killer = tag and tag.Value

	local pivot = npc:GetPivot().Position
	local variant = Config.Variants[npc:GetAttribute("Variant") or "classic"] or Config.Variants.classic
	Fx.burst(pivot, variant.wood, entry.boss and 40 or 18, workspace)

	if killer and killer:IsA("Player") and killer.Parent then
		local reward = killReward(entry.wave, entry.boss)
		local gained = Economy.add(killer, reward, true)
		local profile = DataService.get(killer)
		if profile then
			profile.kills += 1
		end
		Economy.push(killer)
		Fx.floatingText(pivot + Vector3.new(0, 6, 0), "+" .. Util.abbreviate(gained), Color3.fromRGB(255, 205, 90), workspace)
		if entry.boss then
			notifyRemote:FireAllClients({
				kind = "boss",
				title = "BOSS DOWN",
				body = ("%s finished the wave %d boss."):format(killer.DisplayName, entry.wave),
			})
		end
	end

	-- flop over, then clean up
	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("Motor6D") then
			part.Enabled = false
		end
	end
	Debris:AddItem(npc, 4)
	active[npc] = nil

	if aliveCount <= 0 then
		broadcast({ phase = "clear", wave = waveNumber, remaining = 0 })
	else
		broadcast({ phase = "active", wave = waveNumber, remaining = aliveCount })
	end
end

local function spawnRaider(wave: number, index: number, count: number, boss: boolean)
	local variantName = variantForWave(wave, boss)
	local health = WV.BaseHealth * (WV.HealthGrowth ^ (wave - 1)) * (boss and WV.BossHealthMultiplier or 1)
	-- The cap is absolute. It used to be scaled by the boss multiplier along
	-- with the damage, which meant the ceiling written to stop a raider two-
	-- shotting a 100 HP player let a late boss hit for 61.
	local damage = math.min(
		WV.BaseDamage * (WV.DamageGrowth ^ (wave - 1)) * (boss and WV.BossDamageMultiplier or 1),
		boss and WV.MaxBossDamage or WV.MaxDamage)

	local npc = TungModels.buildNPC(variantName, {
		scale = boss and 2.1 or (0.9 + math.random() * 0.35),
		health = health,
		walkSpeed = WV.WalkSpeed + (boss and -2 or math.random() * 4),
		displayName = boss and ("SAHUR BOSS  •  wave " .. wave) or "Tung Tung Tung Sahur",
		boss = boss,
	})

	local angle = (index / math.max(count, 1)) * math.pi * 2 + math.random() * 0.4
	local radius = Config.World.ArenaRadius - 18
	local position = Vector3.new(math.sin(angle) * radius, 8, math.cos(angle) * radius)
	npc:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	npc.Parent = folder

	local humanoid = npc:FindFirstChildOfClass("Humanoid") :: Humanoid
	local torso = npc:FindFirstChild("Torso")
	local arm = torso and torso:FindFirstChild("Right Shoulder")
	local entry = {
		wave = wave,
		boss = boss,
		damage = damage,
		nextAttack = 0,
		nextRepath = 0,
		sway = torso and torso:FindFirstChild("TungSway"),
		phase = math.random() * math.pi * 2,
		spawnedAt = os.clock(),
		dead = false,
		-- attack telegraph. Raiders are server-owned, so unlike player swings
		-- these Motor6D writes replicate on their own and no remote is needed.
		arm = arm,
		armBase = arm and arm.C0,
		walkSpeed = humanoid.WalkSpeed,
		windUp = WV.AttackWindUp * (boss and WV.BossWindUpScale or 1),
		swingAt = nil,
		rootedUntil = 0,
	}
	active[npc] = entry
	aliveCount += 1

	humanoid.Died:Connect(function()
		onRaiderDied(npc, entry)
	end)

	-- boss aura
	if boss then
		local _, root = Util.getRig(npc)
		if root then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 90, 60)
			light.Range = 40
			light.Brightness = 3
			light.Parent = root
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────

local function tick(dt: number)
	local now = os.clock()
	for npc, entry in pairs(active) do
		if not npc.Parent or entry.dead then
			continue
		end
		local humanoid, root = Util.getRig(npc)
		if not humanoid or not root or humanoid.Health <= 0 then
			continue
		end

		-- waddle
		if entry.sway and entry.sway:IsA("Motor6D") then
			entry.phase += dt * (6 + humanoid.WalkSpeed * 0.25)
			local lean = math.sin(entry.phase) * 0.18
			local bob = math.abs(math.cos(entry.phase)) * 0.22
			entry.sway.C0 = CFrame.new(0, 0.7 + bob, 0) * CFrame.Angles(0, 0, lean)
		end

		-- Raise the bat over the wind-up, hold at the top for an instant, then
		-- chop down through the hit. The shape matters more than the numbers:
		-- what makes a raider fair is that the arm is visibly UP before the
		-- damage lands, and that they are rooted while it is.
		if entry.arm and entry.armBase then
			local pitch = 0
			if entry.swingAt then
				pitch = 155 * (1 - math.clamp((entry.swingAt - now) / entry.windUp, 0, 1))
			elseif now < entry.rootedUntil then
				-- the chop itself: cubic, so it falls fast off the top and
				-- settles rather than sliding back at a constant rate
				local k = 1 - math.clamp((entry.rootedUntil - now) / WV.AttackRecover, 0, 1)
				pitch = 155 * (1 - k) ^ 3
			end
			-- The pitch is in TORSO space; conjugating by the joint's own C0
			-- rotation converts it, so this reads the same way as the player
			-- swing poses in SwingAnim and doesn't depend on how the raider rig
			-- happens to orient its shoulder. +X pitch raises the arm forward.
			local basis = entry.armBase.Rotation
			entry.arm.C0 = entry.armBase * (basis:Inverse() * CFrame.Angles(math.rad(pitch), 0, 0) * basis)
		end

		if now >= entry.nextRepath and now >= entry.rootedUntil then
			entry.nextRepath = now + 0.6
			local _, targetChar = nearestPlayer(root.Position, 500)
			if targetChar then
				entry.target = targetChar
				humanoid:MoveTo(targetChar:GetPivot().Position)
			else
				entry.target = nil
				humanoid:MoveTo(Vector3.new(math.random(-60, 60), 0, math.random(-60, 60)))
			end
			-- unstick
			if entry.lastPosition and (root.Position - entry.lastPosition).Magnitude < 1.5 then
				humanoid.Jump = true
			end
			entry.lastPosition = root.Position
		end

		-- Rooted while winding up and recovering. This is the window a player
		-- punishes: before, the raider closed and dealt damage on the same
		-- tick, so being hit was pure proximity and there was nothing to read.
		humanoid.WalkSpeed = (now < entry.rootedUntil) and 0 or entry.walkSpeed

		local target = entry.target
		local targetRoot = target and target.Parent and target:FindFirstChild("HumanoidRootPart")
		local inRange = targetRoot
			and (targetRoot.Position - root.Position).Magnitude <= WV.AttackRange

		if entry.swingAt and now >= entry.swingAt then
			entry.swingAt = nil
			-- The hit only lands if the target is STILL in range: walking out of
			-- a telegraphed swing has to actually work or the telegraph is a lie.
			if inRange then
				CombatService.npcAttack(npc, target, entry.damage)
				Fx.impact(root, 0.85)

				local victim = Players:GetPlayerFromCharacter(target)
				if victim then
					local stolen = Economy.steal(victim, WV.StealPerHit)
					if stolen > 0 then
						Fx.floatingText(targetRoot.Position + Vector3.new(0, 4, 0),
							"-" .. Util.abbreviate(stolen), Color3.fromRGB(255, 110, 110), workspace)
					end
				end
			end
		elseif not entry.swingAt and inRange and now >= entry.nextAttack then
			entry.swingAt = now + entry.windUp
			entry.rootedUntil = entry.swingAt + WV.AttackRecover
			entry.nextAttack = entry.rootedUntil + WV.AttackCooldown
			if targetRoot then
				-- face the target so the wind-up reads as aimed at you
				root.CFrame = CFrame.lookAt(root.Position,
					Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z))
			end
			Fx.impact(root, 1.5)
		end

		-- despawn stragglers so a wave can't hang forever
		if now - entry.spawnedAt > 420 then
			humanoid.Health = 0
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────

function NPCService.startWave()
	if #Players:GetPlayers() == 0 then
		return
	end
	waveNumber += 1
	local count = math.min(WV.BaseCount + (waveNumber - 1) * WV.CountPerWave, WV.MaxCount)
	local boss = (waveNumber % WV.BossEvery == 0)

	broadcast({ phase = "warning", wave = waveNumber, seconds = WV.WarningTime, boss = boss })
	notifyRemote:FireAllClients({
		kind = "wave",
		title = ("SAHUR RAID %d INCOMING"):format(waveNumber),
		body = boss and "A BOSS is coming. tung tung tung." or ("%d raiders in %d seconds."):format(count, WV.WarningTime),
	})

	task.wait(WV.WarningTime)

	for i = 1, count do
		spawnRaider(waveNumber, i, count, false)
		task.wait(0.12)
	end
	if boss then
		spawnRaider(waveNumber, 0, count, true)
	end

	broadcast({ phase = "active", wave = waveNumber, remaining = aliveCount })
end

function NPCService.clearAll()
	for npc in pairs(active) do
		npc:Destroy()
	end
	active = {}
	aliveCount = 0
end

function NPCService.start()
	folder = Instance.new("Folder")
	folder.Name = "SahurRaiders"
	folder.Parent = workspace

	game:GetService("RunService").Heartbeat:Connect(function(dt)
		local ok, err = pcall(tick, dt)
		if not ok then
			warn("[Tung] NPC tick error: " .. tostring(err))
		end
	end)

	if not WV.Enabled then
		return
	end

	task.spawn(function()
		task.wait(WV.FirstWaveDelay)
		while true do
			local ok, err = pcall(NPCService.startWave)
			if not ok then
				warn("[Tung] wave error: " .. tostring(err))
			end
			task.wait(WV.Interval)
		end
	end)
end

function NPCService.currentWave(): number
	return waveNumber
end

return NPCService
