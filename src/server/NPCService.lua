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

-- Raider swing poses, in body space: arm overhead, then swung through to just
-- past the target. See SwingAnim for why these are expressed this way.
local TOP_PITCH = 158
local CONTACT_PITCH = 22

local active: { [Model]: any } = {}
local folder: Folder

--- THE SCHEDULE.
---
--- `waveNumber` is only ever read to mint a record. Everything a wave needs to
--- know about itself lives on the record, and every raider holds a reference to
--- the one that spawned it — which is what makes `remaining` per-wave instead
--- of a global count of every living raider on the map.
---
--- phase ∈ idle | resting | warning | spawning | active | clear
---
--- `spawning` is a separate phase from `active` on purpose: it makes the clear
--- test `spawnFinished and alive <= 0`, so the moment mid-drip when the count
--- legitimately touches zero is structurally unreachable rather than guarded
--- against.
local waveNumber = 0
local phase = "idle"
local phaseUntil = 0
local liveWave: any = nil
local emptySince: number? = nil
local nextBroadcast = 0

-- raider flavour escalates with the wave number
local WAVE_VARIANTS = { "classic", "oak", "ash", "crimson", "neon", "void", "eclipse", "galaxy", "infinity" }

local function variantForWave(wave: number, boss: boolean): string
	local index = math.clamp(math.floor((wave - 1) / 2) + 1, 1, #WAVE_VARIANTS)
	if boss then
		index = math.clamp(index + 2, 1, #WAVE_VARIANTS)
	end
	return WAVE_VARIANTS[index]
end

--- The packet describing where the raid currently is. Built from the live
--- record rather than passed around, so there is one description of the truth
--- and a late joiner can be handed exactly what everyone else last saw.
local function wavePacket()
	local seconds = math.max(0, math.ceil(phaseUntil - os.clock()))
	if phase == "idle" then
		return { phase = "idle" }
	elseif phase == "resting" then
		return { phase = "resting", wave = waveNumber + 1, seconds = seconds }
	end
	local w = liveWave
	if not w then
		return { phase = "idle" }
	end
	return {
		phase = phase,
		wave = w.number,
		boss = w.boss,
		remaining = w.alive,
		total = w.expected,
		forced = w.forced,
		seconds = (phase == "warning" or phase == "clear") and seconds or nil,
	}
end

local function broadcast(payload)
	waveRemote:FireAllClients(payload or wavePacket())
end

-- ─────────────────────────────────────────────────────────────────────────────

--- ONE snapshot of every live player, rebuilt at most every SnapshotInterval
--- and read by every raider.
---
--- This used to be a scan per raider per repath, at four instance reads per
--- player: 26 raiders x 10 players x ~1.7 Hz was about 1,700 property reads a
--- second, and the tighter chase repath below would have made that worse
--- rather than better. Rebuilding once a frame-ish makes it flat at ~400
--- regardless of how many raiders are alive, and turns the per-raider work
--- into float maths over a ten-entry array.
---
--- It is also the one place that decides what counts as a target, which is
--- exactly the seam the `decoy` utility prototype needs — see the TODO in
--- UpgradeService.
local snapshot: { any } = {}
local snapshotAt = 0

local function refreshSnapshot(now: number)
	if now < snapshotAt then
		return
	end
	snapshotAt = now + WV.SnapshotInterval
	table.clear(snapshot)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			table.insert(snapshot, {
				player = player,
				character = character,
				root = root,
				position = root.Position,
			})
		end
	end
end

--- Nearest live player to `position` within `maxDistance`, from the snapshot.
--- Squared distances: nothing here needs the actual magnitude.
local function nearestPlayer(position: Vector3, maxDistance: number): (Player?, Model?, number)
	local bestPlayer, bestChar, best = nil, nil, maxDistance * maxDistance
	for _, entry in ipairs(snapshot) do
		local offset = entry.position - position
		local d2 = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
		if d2 < best then
			bestPlayer, bestChar, best = entry.player, entry.character, d2
		end
	end
	return bestPlayer, bestChar, math.sqrt(best)
end

--- Flat XZ distance. Every AI radius here is a ground distance — a raider on a
--- ramp is not further away for being higher up.
local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--- A point inside a disc of `radius` around `centre`. sqrt() on the random so
--- points spread evenly over the area instead of clustering at the middle.
local function pointInDisc(centre: Vector3, radius: number): Vector3
	local angle = math.random() * math.pi * 2
	local r = radius * math.sqrt(math.random())
	return Vector3.new(centre.X + math.sin(angle) * r, centre.Y, centre.Z + math.cos(angle) * r)
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
	-- Decrement THIS raider's own wave. A straggler from wave N therefore
	-- decrements wave N, and because that record is not the live one it emits
	-- nothing at all — which is what stops leftovers being counted against,
	-- and labelled with, the wave that came after them.
	local record = entry.waveRecord
	if record then
		record.alive = math.max(0, record.alive - 1)
	end

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

	-- No FireAllClients here. This used to send one packet per death — up to 27
	-- a wave, and a whole burst on a single frame when an AoE lands. Mark the
	-- record dirty instead and let the tick flush at most every
	-- BroadcastInterval; the driver sends phase changes immediately, so the
	-- kill that ENDS a wave is still instant.
	if record == liveWave then
		record.dirty = true
	end
end

local function spawnRaider(record, index: number, count: number, boss: boolean)
	local wave = record.number
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
	-- The VISIBLE arm, not the R6 rig's. Every rig part is Transparency = 1
	-- (the rig exists so Humanoid/MoveTo/damage work); the guy you actually see
	-- is the Visual model, and TungArm is its one articulated joint.
	local visual = npc:FindFirstChild("Visual")
	local core = visual and visual.PrimaryPart
	local arm = core and core:FindFirstChild("TungArm")
	local entry = {
		wave = wave,
		waveRecord = record,
		-- Strictly later than the wave's own deadline, so the wave-level
		-- timeout always fires first and this only ever catches a raider whose
		-- record was somehow lost. It used to be a hardcoded 420, which was
		-- longer than the whole wave interval and is why waves overlapped.
		despawnAt = os.clock() + WV.MaxWaveTime + WV.StragglerGrace,
		boss = boss,
		damage = damage,
		-- AI state. NOT `entry.phase` — that name is already the waddle's sine
		-- phase a few lines down, and reusing it would desync the walk cycle
		-- every time the raider changed its mind.
		ai = "wander",
		-- The patch this raider calls home. Scattered around the ARENA CENTRE
		-- rather than sitting at the spawn point: raiders land on the rim and
		-- then walk inward to mill about, which is what makes them read as
		-- gathering in the middle rather than as a ring closing in.
		home = pointInDisc(Vector3.zero, WV.HomeSpread),
		wanderUntil = 0,
		nextAggroCheck = 0,
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
	-- The waddle used to rewrite the sway joint's C0 from a hardcoded 0.7, but
	-- buildNPC sets it to 0.7 * scale — so a 2.1x boss dropped a stud and a half
	-- into its own legs on the first frame it moved.
	if entry.sway then
		entry.swayBase = entry.sway.C0
	end

	active[npc] = entry
	record.alive += 1
	record.spawned += 1

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
	refreshSnapshot(now)
	for npc, entry in pairs(active) do
		if not npc.Parent or entry.dead then
			continue
		end
		local humanoid, root = Util.getRig(npc)
		if not humanoid or not root or humanoid.Health <= 0 then
			continue
		end

		-- waddle
		if entry.sway and entry.swayBase then
			entry.phase += dt * (6 + humanoid.WalkSpeed * 0.25)
			local lean = math.sin(entry.phase) * 0.18
			local bob = math.abs(math.cos(entry.phase)) * 0.22
			entry.sway.C0 = entry.swayBase * CFrame.new(0, bob, 0) * CFrame.Angles(0, 0, lean)
		end

		-- Raise the bat over the wind-up, hold at the top for an instant, then
		-- chop down through the hit. The shape matters more than the numbers:
		-- what makes a raider fair is that the arm is visibly UP before the
		-- damage lands, and that they are rooted while it is.
		if entry.arm and entry.armBase then
			-- Raise, hold, chop — and the chop has to finish BEFORE the damage
			-- lands, not after it. The whole point of a telegraph is that the
			-- bat is visibly on its way down when it connects.
			local pitch = 0
			if entry.swingAt then
				local w = 1 - math.clamp((entry.swingAt - now) / entry.windUp, 0, 1)
				if w < 0.55 then
					pitch = TOP_PITCH * (w / 0.55)                 -- raise
				elseif w < 0.72 then
					pitch = TOP_PITCH                              -- hold at the top
				else
					-- chop, arriving at the contact pose exactly on the hit
					local k = (w - 0.72) / 0.28
					pitch = TOP_PITCH + (CONTACT_PITCH - TOP_PITCH) * (k ^ 0.6)
				end
			elseif now < entry.rootedUntil then
				-- follow-through settling back to rest
				pitch = CONTACT_PITCH * math.clamp((entry.rootedUntil - now) / WV.AttackRecover, 0, 1)
			end
			-- The pitch is in BODY space; conjugating by the joint's own C0
			-- rotation converts it, so this reads the same way as the player
			-- swing poses in SwingAnim and doesn't depend on how the shoulder
			-- happens to be oriented. +X pitch raises the arm forward.
			local basis = entry.armBase.Rotation
			entry.arm.C0 = entry.armBase * (basis:Inverse() * CFrame.Angles(math.rad(pitch), 0, 0) * basis)
		end

		-- ── AI: wander / chase / return ──────────────────────────────────────
		--
		-- Evaluated only when the raider is free to move. The telegraph above
		-- runs regardless of state ON PURPOSE: gating it on "chase" would
		-- freeze a raider mid-swing with its bat overhead the instant it
		-- de-aggroed.
		if now >= entry.rootedUntil and not entry.swingAt then
			local homeDistance = flatDistance(root.Position, entry.home)

			if entry.ai == "chase" then
				local target = entry.target
				local targetRootPart = target and target.Parent
					and target:FindFirstChild("HumanoidRootPart")
				local targetHumanoid = target and target.Parent
					and target:FindFirstChildOfClass("Humanoid")
				local lost = not targetRootPart
					or not targetHumanoid
					or targetHumanoid.Health <= 0
					or flatDistance(targetRootPart.Position, root.Position) > WV.DeAggroRadius
					or homeDistance > WV.LeashRadius

				if lost then
					entry.ai = "return"
					entry.target = nil
					entry.nextRepath = 0
				end
			elseif entry.ai == "return" then
				if homeDistance <= WV.HomeArrive then
					entry.ai = "wander"
					entry.wanderUntil = 0
				end
			end

			-- Only a raider that is NOT already committed goes looking, and a
			-- returning one may not bite again until it is most of the way
			-- home — otherwise a player parked on the leash line yo-yos it.
			if entry.ai ~= "chase" and now >= entry.nextAggroCheck then
				entry.nextAggroCheck = now + WV.AggroCheck
				local mayAggro = entry.ai == "wander"
					or homeDistance <= WV.LeashRadius * WV.ReAggroFrac
				if mayAggro then
					local _, found = nearestPlayer(root.Position, WV.AggroRadius)
					if found then
						entry.ai = "chase"
						entry.target = found
						entry.nextRepath = 0
					end
				end
			end

			local interval = (entry.ai == "chase" and WV.RepathChase)
				or (entry.ai == "return" and WV.RepathReturn)
				or WV.RepathWander

			if now >= entry.nextRepath then
				entry.nextRepath = now + interval

				if entry.ai == "chase" then
					local targetRootPart = entry.target and entry.target.Parent
						and entry.target:FindFirstChild("HumanoidRootPart")
					if targetRootPart then
						humanoid:MoveTo(targetRootPart.Position)
					end
				elseif entry.ai == "return" then
					humanoid:MoveTo(entry.home)
				else
					-- Drift around the home patch. The old idle target was a
					-- hardcoded +/-60 world-space box unrelated to the arena,
					-- so idling raiders wandered off it.
					if now >= entry.wanderUntil then
						entry.wanderUntil = now
							+ WV.WanderDwellMin
							+ math.random() * (WV.WanderDwellMax - WV.WanderDwellMin)
						entry.wanderTarget = pointInDisc(entry.home, WV.WanderRadius)
					end
					humanoid:MoveTo(entry.wanderTarget or entry.home)
				end

				-- unstick
				if entry.lastPosition and (root.Position - entry.lastPosition).Magnitude < 1.5 then
					humanoid.Jump = true
				end
				entry.lastPosition = root.Position
			end
		end

		-- Rooted while winding up and recovering. This is the window a player
		-- punishes: before, the raider closed and dealt damage on the same
		-- tick, so being hit was pure proximity and there was nothing to read.
		--
		-- Still written EVERY frame, and still hard-zeroed while rooted. The
		-- per-state scale MULTIPLIES the captured entry.walkSpeed rather than
		-- replacing it, so each raider keeps the jitter buildNPC gave it.
		-- (UpgradeService's freeze verb anchors the assembly specifically
		-- because this write exists every frame — see the note there.)
		local speedScale = 1
		if entry.ai == "wander" then
			speedScale = WV.WanderSpeedScale
		elseif entry.ai == "return" then
			speedScale = WV.ReturnSpeedScale
		end
		humanoid.WalkSpeed = (now < entry.rootedUntil) and 0 or (entry.walkSpeed * speedScale)

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
		if now >= entry.despawnAt then
			humanoid.Health = 0
		end
	end

	-- Flush the coalesced counter update. Two comparisons a frame, against one
	-- FireAllClients per death before.
	if liveWave and liveWave.dirty and now >= nextBroadcast then
		liveWave.dirty = false
		nextBroadcast = now + WV.BroadcastInterval
		broadcast()
	end
end

-- ─────────────────────────────────────────────────────────────────────────────

local function setPhase(newPhase: string, seconds: number?)
	phase = newPhase
	phaseUntil = os.clock() + (seconds or 0)
	-- Phase changes bypass the broadcast throttle. These are the packets that
	-- must never be late: a banner that says "1 RAIDER LEFT" for half a second
	-- after you killed the last one is worse than no banner.
	broadcast()
end

--- Mints the record for the next wave and puts the warning up.
local function beginWave()
	waveNumber += 1
	local count = math.min(WV.BaseCount + (waveNumber - 1) * WV.CountPerWave, WV.MaxCount)
	local boss = (waveNumber % WV.BossEvery == 0)

	liveWave = {
		number = waveNumber,
		boss = boss,
		count = count,
		expected = count + (boss and 1 or 0),
		spawned = 0,
		alive = 0,
		spawnFinished = false,
		cleared = false,
		forced = false,
		dirty = false,
		deadline = math.huge,
		-- Generous: the drip itself is count * SpawnGap, and this only exists
		-- so a thread that dies mid-drip cannot wedge the schedule.
		spawnDeadline = os.clock() + WV.WarningTime + count * WV.SpawnGap * 4 + 10,
	}

	setPhase("warning", WV.WarningTime)
	notifyRemote:FireAllClients({
		kind = boss and "boss" or "wave",
		title = ("SAHUR RAID %d INCOMING"):format(waveNumber),
		body = boss and "A BOSS is coming. tung tung tung."
			or ("%d raiders in %d seconds."):format(count, WV.WarningTime),
	})
end

--- Drips the wave in. Runs in its OWN thread and only sets a flag the driver
--- polls, so the driver itself never blocks — the old loop ran the warning wait
--- and the whole drip inside the pcall'd startWave, which meant an error
--- anywhere in there took the schedule down with it.
local function spawnWave(record)
	task.spawn(function()
		for i = 1, record.count do
			if record ~= liveWave then
				return
			end
			spawnRaider(record, i, record.count, false)
			task.wait(WV.SpawnGap)
		end
		if record.boss and record == liveWave then
			spawnRaider(record, 0, record.count, true)
		end
		record.spawnFinished = true
		record.deadline = os.clock() + WV.MaxWaveTime
	end)
end

--- Kills whatever is left of a wave that has run out of time.
local function forceEnd(record)
	record.forced = true
	for npc, entry in pairs(active) do
		if entry.waveRecord == record and not entry.dead then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if humanoid then
				-- Through Died, so the flop and the Debris cleanup still run.
				-- No creator tag, so no reward is paid for a wave nobody
				-- finished — which is correct, not an oversight.
				humanoid.Health = 0
			end
		end
	end
end

function NPCService.clearAll()
	for npc in pairs(active) do
		npc:Destroy()
	end
	active = {}
	liveWave = nil
end

--- One step of the schedule. Polled rather than driven by signals: at 4 Hz the
--- cost is nothing, and it keeps every transition in one readable place
--- instead of spread across a death handler and three timers.
local function step()
	local now = os.clock()
	local populated = #Players:GetPlayers() > 0

	-- An empty server runs no raid, and does not burn a wave number doing it.
	if not populated and phase ~= "idle" then
		NPCService.clearAll()
		emptySince = now
		setPhase("idle")
		return
	end

	if phase == "idle" then
		if populated then
			-- A server that sat empty long enough resets, so someone joining a
			-- stale one is not met by a wave-30 raider with 2.9k health.
			if emptySince and now - emptySince >= WV.EmptyResetAfter then
				waveNumber = 0
			end
			emptySince = nil
			setPhase("resting", WV.JoinGrace)
		end
		return
	end

	if phase == "resting" then
		if now >= phaseUntil then
			beginWave()
		end
		return
	end

	if phase == "warning" then
		if now >= phaseUntil then
			setPhase("spawning")
			spawnWave(liveWave)
		end
		return
	end

	if phase == "spawning" then
		-- The drip runs in its own thread, so an error inside it kills that
		-- thread and nothing else — `spawnFinished` would simply never arrive
		-- and the schedule would sit here forever. Time it out into `active`
		-- with whatever did spawn; if that is nothing, `active` clears it on
		-- the next step and the raid moves on.
		if liveWave.spawnFinished or now >= liveWave.spawnDeadline then
			liveWave.spawnFinished = true
			liveWave.deadline = math.min(liveWave.deadline, now + WV.MaxWaveTime)
			setPhase("active")
		end
		return
	end

	if phase == "active" then
		-- `spawnFinished` is what makes this safe. Without it the moment
		-- mid-drip when alive legitimately touches zero would read as a clear.
		if liveWave.alive <= 0 then
			setPhase("clear", WV.ClearBannerTime)
		elseif now >= liveWave.deadline then
			forceEnd(liveWave)
			setPhase("clear", WV.ClearBannerTime)
		end
		return
	end

	if phase == "clear" then
		if now >= phaseUntil then
			local rest = liveWave.boss and WV.RestTimeAfterBoss or WV.RestTime
			liveWave = nil
			setPhase("resting", rest)
		end
		return
	end
end

--- Hands a joining client the packet everyone else last saw, so a mid-wave
--- joiner does not stare at a blank banner until the next death.
function NPCService.pushTo(player: Player)
	waveRemote:FireClient(player, wavePacket())
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

	Players.PlayerAdded:Connect(function(player)
		task.defer(NPCService.pushTo, player)
	end)

	if not WV.Enabled then
		return
	end

	task.spawn(function()
		task.wait(WV.FirstWaveDelay)
		while true do
			local ok, err = pcall(step)
			if not ok then
				warn("[Tung] wave step error: " .. tostring(err))
			end
			task.wait(0.25)
		end
	end)
end

function NPCService.currentWave(): number
	return liveWave and liveWave.number or waveNumber
end

--- How many raiders of the CURRENT wave are still standing. Nil when no wave
--- is running, which is different from zero.
function NPCService.remaining(): number?
	return liveWave and liveWave.alive or nil
end

return NPCService
