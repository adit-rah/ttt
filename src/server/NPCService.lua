--[[
	NPCService.lua — every Sahur in the world.

	design:D-04, via #89. Three populations share one AI, one tick loop and
	one stat curve, differing only in where they live and what minted them:

	  * BAND ROAMERS — the open world's standing danger. Three annuli between
	    the plot belt and the centre, strongest in the middle, each kept at
	    its population by a slow census. Kill one, it pays its level.
	  * THE CENTRAL WAVE — the one shared event: the old wave machine, at the
	    dais, boss and pot included. Its number may climb with the server's
	    lifetime because nobody stands in the core by accident.
	  * PLOT SIEGES — each plot's own small raid, at the plot's OWN level,
	    spawned at its gate. They press the structures (#124's mobs, finally
	    arrived) and stream in when the gate breaks.

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
-- The GateService arrangement: walk Tycoon.all() on a beat. Tycoon does not
-- require NPCService, so the arrow is one-way.
local Tycoon = Req("Tycoon")

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local NPCService = {}

local waveRemote = Net.event("WaveState")
local notifyRemote = Net.event("Notify")

local WV = Config.Waves
local MB = Config.Mobs
local PW = Config.PlotWave
local SH = Config.Structure.Health

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
	-- THE SHARED HEALTH BAR RIDES THIS PACKET. No new remote: the boss's health
	-- is part of where the raid currently is, so it belongs in the one
	-- description of that, and it reaches late joiners through pushTo for free.
	--
	-- Read off the record rather than by scanning `active`, and nil'd when the
	-- boss dies — otherwise the packet would report a bar sitting at 0% for the
	-- rest of the wave.
	local bossEntry = w.bossEntry
	local bossHumanoid = bossEntry and bossEntry.humanoid
	return {
		phase = phase,
		wave = w.number,
		boss = w.boss,
		remaining = w.alive,
		total = w.expected,
		forced = w.forced,
		seconds = (phase == "warning" or phase == "clear") and seconds or nil,
		bossHp = bossHumanoid and math.max(0, bossHumanoid.Health) or nil,
		bossMaxHp = bossEntry and bossEntry.maxHealth or nil,
		-- How many players the fight was scaled for, so the sign can say so.
		-- Sampled once at beginWave; see the note there.
		bossScale = bossEntry and w.players or nil,
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
				-- Recounted from scratch each rebuild by the tick below, so a
				-- raider that died or de-aggroed frees its slot without anyone
				-- having to remember to decrement anything.
				chasers = 0,
			})
		end
	end
end

--- The snapshot row for a character, or nil. Used to find the chaser slot a
--- committed raider belongs to.
local function snapshotFor(character: Model?)
	if not character then
		return nil
	end
	for _, entry in ipairs(snapshot) do
		if entry.character == character then
			return entry
		end
	end
	return nil
end

--- Counts, per player, how many raiders are currently chasing them. Rebuilt
--- rather than maintained incrementally: a decrement that has to happen in
--- four different places is a decrement that eventually does not.
local function countChasers()
	for _, slot in ipairs(snapshot) do
		slot.chasers = 0
	end
	for _, entry in pairs(active) do
		if entry.ai == "chase" and not entry.dead then
			local slot = snapshotFor(entry.target)
			if slot then
				slot.chasers += 1
			end
		end
	end
end

--- Nearest live player to `position` within `maxDistance`, from the snapshot.
--- Squared distances: nothing here needs the actual magnitude.
--- The nearest live player's snapshot row within `maxDistance`, or nil. The row
--- rather than the character, because the caller needs its chaser count too.
--- Squared distances: nothing here needs the actual magnitude.
local function nearestSnapshotEntry(position: Vector3, maxDistance: number)
	local best, bestD2 = nil, maxDistance * maxDistance
	for _, entry in ipairs(snapshot) do
		local offset = entry.position - position
		local d2 = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
		if d2 < bestD2 then
			best, bestD2 = entry, d2
		end
	end
	return best
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

--- THE DAMAGE LEDGER. Registered on CombatService at boot, which is the only
--- TakeDamage call in the repo, so this sees every hit any player lands on
--- anything — and cares about exactly one of them.
---
--- `applied` is the health that actually came off, not the damage that was
--- asked for. See the note at the call site.
local function onDamageDealt(victim: Model, attacker: Player, applied: number)
	if applied <= 0 then
		return
	end
	local entry = active[victim]
	-- Ordinary raiders keep their creator tag and nothing else; only a boss
	-- carries a ledger.
	if not entry or entry.dead or not entry.contrib then
		return
	end
	entry.contrib[attacker] = (entry.contrib[attacker] or 0) + applied
	entry.contribTotal += applied
	-- The health bar rides the existing 2 Hz coalescer rather than a remote per
	-- swing. Twelve people hitting a boss is a lot of swings.
	local record = entry.waveRecord
	if record == liveWave then
		record.dirty = true
	end
end

--- SPLITS THE BOSS POT, and is the whole reason any of this exists.
---
--- `fraction` is how much of the pot the fight earned: 1 on a kill, and
--- contribTotal/maxHealth when the wave timed out with the boss still standing.
--- Idempotent through `entry.paid`, because the timeout path deliberately kills
--- its own survivors and would otherwise pay twice.
---
--- profile.kills goes to the TOP CONTRIBUTOR ONLY. Crediting everyone would
--- inflate the KO leaderboard by twelve for one boss.
local function payBoss(entry, fraction: number, pivot: Vector3?, escaped: boolean?)
	if entry.paid then
		return
	end
	entry.paid = true

	local record = entry.waveRecord
	local pot = killReward(entry.wave, true)
		* (record and record.rewardFactor or 1)
		* math.clamp(fraction, 0, 1)
	if pot <= 0 then
		return
	end

	-- WHO GETS PAID. A damage floor, so a player who landed one hit on their way
	-- past does not dilute the even split twelve ways; and still present, because
	-- Economy.add on a departed player writes to a profile nobody will save.
	local minDamage = WV.BossMinDamageFrac * entry.maxHealth
	local eligible, eligibleTotal = {}, 0
	local top, topDamage = nil, 0
	for player, damage in pairs(entry.contrib) do
		if damage >= minDamage and player.Parent then
			table.insert(eligible, { player = player, damage = damage })
			eligibleTotal += damage
			if damage > topDamage then
				top, topDamage = player, damage
			end
		end
	end
	if #eligible == 0 then
		return
	end

	for _, who in ipairs(eligible) do
		local share = Config.bossShare(who.damage, eligibleTotal, #eligible, pot)
		local gained = Economy.add(who.player, share, true)
		if who.player == top then
			local profile = DataService.get(who.player)
			if profile then
				profile.kills += 1
			end
		end
		Economy.push(who.player)
		-- The personal number is better as a payout than as a HUD element: it
		-- arrives once, in the place every other reward arrives.
		Economy.notify(who.player, {
			kind = "boss",
			title = "YOUR CUT",
			body = ("%s  •  %d%% of the boss"):format(
				Util.abbreviate(gained),
				math.floor((who.damage / entry.maxHealth) * 100 + 0.5)),
		})
	end

	if pivot then
		Fx.floatingText(pivot + Vector3.new(0, 8, 0), "+" .. Util.abbreviate(pot),
			Color3.fromRGB(255, 205, 90), workspace)
	end

	notifyRemote:FireAllClients({
		kind = "boss",
		title = escaped and "BOSS ESCAPED" or "BOSS DOWN",
		body = ("Wave %d. %s led with %d%%. %d player%s paid out."):format(
			entry.wave,
			top and top.DisplayName or "nobody",
			math.floor((topDamage / entry.maxHealth) * 100 + 0.5),
			#eligible, #eligible == 1 and "" or "s"),
	})
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

	if entry.contrib then
		-- A BOSS IS NOT PAID TO WHOEVER SWUNG LAST. It is the one fight in this
		-- game that takes more than one person, so the pot is split across
		-- everyone who did real damage to it — see payBoss.
		payBoss(entry, 1, pivot, false)
		if record then
			record.bossEntry = nil
		end
	elseif killer and killer:IsA("Player") and killer.Parent then
		local reward = killReward(entry.wave, entry.boss)
		local gained = Economy.add(killer, reward, true)
		local profile = DataService.get(killer)
		if profile then
			profile.kills += 1
		end
		Economy.push(killer)
		Fx.floatingText(pivot + Vector3.new(0, 6, 0), "+" .. Util.abbreviate(gained), Color3.fromRGB(255, 205, 90), workspace)
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

--- Everything below the stat arithmetic, shared by all three populations.
--- `opts`:
---   level      — feeds the growth curves; the central wave passes its number
---   boss       — central wave only
---   position   — where the body lands
---   home       — the patch it returns to; the leash measures from here
---   leash      — chase tether
---   record     — the schedule record whose alive/spawned it moves (optional;
---                roamers have none, and onRaiderDied already guards for it)
---   siege      — { tycoon = ... } for a plot raider; its objective is
---                re-derived live as things break
---   band       — band index, for the roamer census
---   despawnAt  — absolute; roamers pass math.huge
---   index/count — approach-ring slot spread (defaults spread randomly)
local function mintNPC(opts)
	local level = opts.level
	local boss = opts.boss == true
	local variantName = variantForWave(level, boss)
	local health = WV.BaseHealth * (WV.HealthGrowth ^ (level - 1)) * (boss and WV.BossHealthMultiplier or 1)
	if boss then
		-- Scaled to the headcount the wave was MINTED with, never to the live
		-- one. See beginWave: re-reading it here would move a bar twelve
		-- people are watching every time somebody logged off.
		health *= (opts.record and opts.record.healthFactor or 1)
	end
	-- The cap is absolute. It used to be scaled by the boss multiplier along
	-- with the damage, which meant the ceiling written to stop a raider two-
	-- shotting a 100 HP player let a late boss hit for 61.
	local damage = math.min(
		WV.BaseDamage * (WV.DamageGrowth ^ (level - 1)) * (boss and WV.BossDamageMultiplier or 1),
		boss and WV.MaxBossDamage or WV.MaxDamage)

	local npc = TungModels.buildNPC(variantName, {
		scale = boss and WV.BossBodyScale or (0.9 + math.random() * 0.35),
		health = health,
		walkSpeed = WV.WalkSpeed + (boss and -2 or math.random() * 4),
		displayName = boss and ("SAHUR BOSS  •  wave " .. level) or "Tung Tung Tung Sahur",
		boss = boss,
	})
	npc:PivotTo(CFrame.new(opts.position) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	npc.Parent = folder

	local humanoid = npc:FindFirstChildOfClass("Humanoid") :: Humanoid
	local torso = npc:FindFirstChild("Torso")
	-- The VISIBLE arm, not the R6 rig's. Every rig part is Transparency = 1
	-- (the rig exists so Humanoid/MoveTo/damage work); the guy you actually see
	-- is the Visual model, and TungArm is its one articulated joint.
	local visual = npc:FindFirstChild("Visual")
	local core = visual and visual.PrimaryPart
	local arm = core and core:FindFirstChild("TungArm")
	local record = opts.record
	local count = opts.count or 8
	local entry = {
		wave = level,
		waveRecord = record,
		despawnAt = opts.despawnAt,
		boss = boss,
		damage = damage,
		siege = opts.siege,
		band = opts.band,
		-- AI state. NOT `entry.phase` — that name is already the waddle's sine
		-- phase a few lines down, and reusing it would desync the walk cycle
		-- every time the raider changed its mind.
		ai = "wander",
		home = opts.home,
		leash = opts.leash,
		wanderUntil = 0,
		nextAggroCheck = 0,
		-- Where on the approach ring this raider stands. Fixed per raider so a
		-- pack spreads deterministically instead of jostling for the same spot.
		slotAngle = ((opts.index or math.random(count)) / math.max(count, 1)) * math.pi * 2 + math.random() * 0.5,
		-- How long it must hold you inside AggroRadius before committing.
		-- Random per raider, so a pack that all crosses the threshold on one
		-- tick still commits raggedly over ~2 seconds.
		aggroDelay = math.random() * WV.AggroStagger,
		aggroSince = nil,
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
	if record then
		record.alive += 1
		record.spawned += 1
	end

	humanoid.Died:Connect(function()
		onRaiderDied(npc, entry)
	end)

	if boss then
		-- THE LEDGER, and the record's handle on it. `contrib` being non-nil is
		-- what marks an entry as carrying one at all, so nothing else in the
		-- tick has to ask whether a raider is a boss.
		--
		-- `maxHealth` is captured rather than read back off the humanoid because
		-- both the eligibility floor and the escaped-boss pro-rata are fractions
		-- of it, and a dead humanoid reports a MaxHealth nobody promised.
		entry.contrib = {}
		entry.contribTotal = 0
		entry.maxHealth = health
		entry.paid = false
		entry.humanoid = humanoid
		if record then
			record.bossEntry = entry
		end

		local _, root = Util.getRig(npc)
		if root then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 90, 60)
			light.Range = 40
			light.Brightness = 3
			light.Parent = root
		end
	end
	return entry
end

--- One central-wave raider. Land in CLUSTERS, not on one evenly-divided ring:
--- a ring of 26 arrives as a wall closing from every direction at once; six
--- clusters of four arrive as a raid. `groupAngle` is chosen per group by the
--- caller and jittered per member here.
---
--- THE BOSS DOES NOT GET A BEARING AT ALL. It lands on a fixed spot just off
--- the dais, every time. A shared objective that appears somewhere different
--- every wave is one twelve people spend the first thirty seconds looking
--- for. BossSpawnRadius clears the 26-diameter dais and the statue standing
--- on it, which the verifier asserts.
local function spawnRaider(record, index: number, count: number, boss: boolean, groupAngle: number?)
	local position
	if boss then
		position = Vector3.new(0, 12, WV.BossSpawnRadius)
	else
		local angle = (groupAngle or 0) + (math.random() - 0.5) * 2 * WV.GroupArc
		local radius = Config.World.ArenaRadius - 18
		position = Vector3.new(math.sin(angle) * radius, 8, math.cos(angle) * radius)
	end
	mintNPC({
		level = record.number,
		boss = boss,
		position = position,
		-- The patch this raider calls home. Scattered around the CENTRE rather
		-- than sitting at the spawn point: raiders land on the rim and then
		-- walk inward to mill about, which is what makes them read as
		-- gathering in the middle rather than as a ring closing in. The boss
		-- keeps to the dais it lands on, and is leashed tighter than a raider
		-- (BossLeashRadius), so the fight everyone is walking towards stays
		-- where they last saw it.
		home = pointInDisc(Vector3.zero, boss and WV.BossSpawnRadius or WV.HomeSpread),
		leash = boss and WV.BossLeashRadius or WV.LeashRadius,
		record = record,
		index = index,
		count = count,
		-- Strictly later than the wave's own deadline, so the wave-level
		-- timeout always fires first and this only ever catches a raider whose
		-- record was somehow lost.
		despawnAt = os.clock() + WV.MaxWaveTime + WV.StragglerGrace,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- band roamers (#89): the world's standing danger, kept at population by a
-- slow census. No records, no schedule — a roamer lives until killed and its
-- band refills one body at a time.
-- ─────────────────────────────────────────────────────────────────────────────

local nextRoamerSpawn: { [number]: number } = {}

--- An area-uniform point in the band's annulus, clear of the edges by
--- HomeMargin so a roamer's wander never straddles a boundary. The spawn
--- pad needs no rejection sampling: it sits OUTSIDE every band, and the
--- verifier holds the clearance.
local function bandHome(band): Vector3
	local angle = math.random() * math.pi * 2
	local inner = band.inner + MB.HomeMargin
	local outer = math.max(band.outer - MB.HomeMargin, inner + 1)
	local r = math.sqrt(inner * inner + math.random() * (outer * outer - inner * inner))
	return Vector3.new(math.sin(angle) * r, 0, math.cos(angle) * r)
end

local function maintainRoamers(now: number)
	if not MB.Enabled or #Players:GetPlayers() == 0 then
		return
	end
	local alive = {}
	for _, entry in pairs(active) do
		if entry.band and not entry.dead then
			alive[entry.band] = (alive[entry.band] or 0) + 1
		end
	end
	for index, band in ipairs(MB.Bands) do
		if (alive[index] or 0) < band.count and now >= (nextRoamerSpawn[index] or 0) then
			nextRoamerSpawn[index] = now + MB.RespawnSeconds
			local home = bandHome(band)
			mintNPC({
				level = band.level,
				position = home + Vector3.new(0, 8, 0),
				home = home,
				leash = WV.LeashRadius,
				band = index,
				despawnAt = math.huge,
			})
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- plot sieges (#89): each plot's own raid, at the plot's own level. The
-- schedule is per-plot state on this table; the raiders are ordinary entries
-- with `siege = { tycoon }`, and the tick presses whatever objective
-- siegeObjective currently answers with.
-- ─────────────────────────────────────────────────────────────────────────────

local plotSieges: { [any]: any } = {}

--- What a plot raider is here to break, right now: the gate while one is
--- owned and standing, the storage unit after (or instead, on a plot that
--- never bought gates), nil when everything is down — then they just mill
--- and menace. Position second, so a caller can ask "anything left?" cheaply.
local function siegeObjective(tycoon): (string?, Vector3?)
	if tycoon.owned and tycoon.owned.gates and not tycoon:structureBroken("gate_gateway") then
		return "gate", tycoon.cf:PointToWorldSpace(
			Vector3.new(Config.Layout.GateCentre, 0, Config.World.PlotSize.Z / 2))
	end
	local base = tycoon.storageBase
	if base and base.Parent and tycoon:storageIntact() then
		return "storage", base.Position
	end
	return nil, nil
end

local function endSiege(tycoon, state)
	for npc, entry in pairs(active) do
		if entry.siege and entry.siege.tycoon == tycoon and not entry.dead then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end
	end
	state.record = nil
end

local function stepPlotSieges(now: number)
	if not PW.Enabled then
		return
	end
	local concurrent = 0
	for _, state in pairs(plotSieges) do
		if state.phase == "warning" or state.phase == "active" then
			concurrent += 1
		end
	end
	-- drop state for plots whose tenancy ended, and kill their raiders with it
	for tycoon, state in pairs(plotSieges) do
		if not tycoon.owner then
			endSiege(tycoon, state)
			plotSieges[tycoon] = nil
		end
	end
	for _, tycoon in ipairs(Tycoon.all()) do
		local owner = tycoon.owner
		if owner then
			local state = plotSieges[tycoon]
			if not state then
				-- a fresh tenancy gets half a rest before its first raid, so
				-- claiming a plot is never answered with an instant siege
				state = { phase = "resting",
					phaseUntil = now + PW.RestSeconds / 2 + math.random() * PW.RestJitter }
				plotSieges[tycoon] = state
			end

			if state.phase == "resting" then
				-- #96: the siege is a GATED disclosure — a raid siren in the
				-- first minute is the overload the system exists to prevent.
				-- The high-water lives on the profile, so the gate and the
				-- interface cannot disagree.
				local profile = DataService.get(owner)
				local disclosed = profile and profile.disclosed and profile.disclosed.siege == true
				if disclosed and now >= state.phaseUntil and concurrent < PW.MaxConcurrent then
					concurrent += 1
					local counts = tycoon:landState()
					state.level = Config.plotWaveLevel(counts.left + counts.right,
						profile and profile.rebirths or 0)
					state.count = math.min(PW.BaseCount + math.floor(state.level / 3), PW.MaxCount)
					state.phase = "warning"
					state.phaseUntil = now + WV.WarningTime
					-- The siren. WarningTime plus the gate's asserted breach
					-- floor is the run-home promise — see the verifier.
					Economy.notify(owner, { kind = "wave", title = "RAID ON YOUR PLOT",
						body = ("%d Sahur at your gate in %d seconds."):format(state.count, WV.WarningTime) })
				end
			elseif state.phase == "warning" then
				if now >= state.phaseUntil then
					state.phase = "active"
					state.phaseUntil = now + PW.MaxSiegeSeconds
					state.record = { number = state.level, alive = 0, spawned = 0 }
					local halfZ = Config.World.PlotSize.Z / 2
					for i = 1, state.count do
						local outside = tycoon.cf:PointToWorldSpace(Vector3.new(
							Config.Layout.GateCentre + (math.random() - 0.5) * 24, 0, halfZ + 24 + math.random() * 10))
						mintNPC({
							level = state.level,
							position = outside + Vector3.new(0, 6, 0),
							home = outside,
							-- generous: the objective walks inward as things
							-- break, and the leash must not strand them at
							-- the gate they broke
							leash = Config.World.PlotSize.Z + 60,
							record = state.record,
							siege = { tycoon = tycoon },
							index = i,
							count = state.count,
							despawnAt = now + PW.MaxSiegeSeconds + WV.StragglerGrace,
						})
					end
				end
			elseif state.phase == "active" then
				-- GateSlots raiders press the structure; the rest mill and
				-- menace. Reassigned every step so a dead slot frees itself.
				local slots = 0
				for _, entry in pairs(active) do
					if entry.siege and entry.siege.tycoon == tycoon and not entry.dead then
						slots += 1
						entry.siegeSlot = slots <= PW.GateSlots
					end
				end
				if not state.record or state.record.alive <= 0 then
					state.phase = "resting"
					state.phaseUntil = now + PW.RestSeconds + math.random() * PW.RestJitter
					Economy.notify(owner, { kind = "wave", title = "RAID CLEARED",
						body = "Your plot held. tung tung." })
				elseif now >= state.phaseUntil then
					endSiege(tycoon, state)
					state.phase = "resting"
					state.phaseUntil = now + PW.RestSeconds + math.random() * PW.RestJitter
				end
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────

local function tick(dt: number)
	local now = os.clock()
	refreshSnapshot(now)
	countChasers()
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
			-- a plot raider's home rides its objective: the gate until it
			-- breaks, the storage after it, the plot's heart when everything
			-- is down — which is what makes a broken gate an OPEN gate
			if entry.siege then
				local _, objectivePosition = siegeObjective(entry.siege.tycoon)
				entry.home = objectivePosition
					or entry.siege.tycoon.cf:PointToWorldSpace(Vector3.zero)
			end
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
					or homeDistance > entry.leash

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
					or homeDistance <= entry.leash * WV.ReAggroFrac
				local slot = mayAggro and nearestSnapshotEntry(root.Position, WV.AggroRadius) or nil
				-- Cap how many may engage one player. The overflow keeps
				-- milling and steps in as slots free, which reads as
				-- reinforcements rather than as a queue.
				if slot and slot.chasers >= WV.MaxChasers then
					slot = nil
				end
				if slot then
					-- ...and even then, hold the player for this raider's own
					-- delay first. A pack that all crosses the threshold on one
					-- tick still commits raggedly.
					entry.aggroSince = entry.aggroSince or now
					if now - entry.aggroSince >= entry.aggroDelay then
						entry.ai = "chase"
						entry.target = slot.character
						entry.nextRepath = 0
						slot.chasers += 1
					end
				else
					entry.aggroSince = nil
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
						-- A point on a ring AROUND the target, not the target
						-- itself. Twenty-six raiders all pathing to one stud
						-- is what made a wave read as a single blob standing
						-- inside itself.
						--
						-- ApproachStandoff is UNDER AttackRange, so a raider
						-- parked on its slot is already in swing range: the
						-- ring costs no damage output. The orbit term is
						-- folded into the repath rather than animated per
						-- frame, which at 0.35s is smooth enough and costs two
						-- trig calls per chasing raider per repath.
						local slotAngle = entry.slotAngle + now * WV.OrbitSpeed
						humanoid:MoveTo(targetRootPart.Position + Vector3.new(
							math.sin(slotAngle) * WV.ApproachStandoff,
							0,
							math.cos(slotAngle) * WV.ApproachStandoff))
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

		-- A SLOTTED plot raider with no player in reach presses the structure
		-- instead (#89/#124). Players always outrank masonry: a defender who
		-- steps into range pulls the next swing onto themselves.
		local objectivePosition
		if entry.siege and entry.siegeSlot and not inRange then
			local _, position = siegeObjective(entry.siege.tycoon)
			if position and flatDistance(position, root.Position) <= WV.AttackRange + 6 then
				objectivePosition = position
			end
		end

		if entry.swingAt and now >= entry.swingAt then
			entry.swingAt = nil
			if entry.swingStructure then
				entry.swingStructure = nil
				-- resolved FRESH: the gate this swing wound up on may have
				-- broken under a packmate's bat mid-telegraph, and the hit
				-- has to land on whatever actually still stands
				local kind, position = siegeObjective(entry.siege.tycoon)
				if position and flatDistance(position, root.Position) <= WV.AttackRange + 6 then
					local tycoon = entry.siege.tycoon
					if kind == "gate" then
						tycoon:damageStructure("gate_gateway", entry.damage * SH.MobDamageScale)
					else
						tycoon:damageStorage(entry.damage * SH.MobDamageScale, nil)
					end
					Fx.impact(root, 0.85)
				end
			elseif inRange then
				-- The hit only lands if the target is STILL in range: walking
				-- out of a telegraphed swing has to actually work or the
				-- telegraph is a lie.
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
		elseif not entry.swingAt and now >= entry.nextAttack and (inRange or objectivePosition) then
			entry.swingAt = now + entry.windUp
			entry.rootedUntil = entry.swingAt + WV.AttackRecover
			entry.nextAttack = entry.rootedUntil + WV.AttackCooldown
			entry.swingStructure = (not inRange) and objectivePosition ~= nil
			local face = (targetRoot and targetRoot.Position) or objectivePosition
			if face then
				-- face the target so the wind-up reads as aimed at it
				root.CFrame = CFrame.lookAt(root.Position,
					Vector3.new(face.X, root.Position.Y, face.Z))
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

	-- HOW BIG THE SERVER IS, SAMPLED ONCE AND NEVER AGAIN.
	--
	-- Both factors are minted here, into the record, and every later reader
	-- takes them from it. If the boss's health tracked the live player count,
	-- one person logging off mid-fight would move a bar that a dozen people are
	-- watching, and the pot would change under the ledger that is already
	-- half-written. Somebody who joins mid-fight therefore gets a free ride,
	-- which is the friendly direction to be wrong in.
	local players = #Players:GetPlayers()

	liveWave = {
		number = waveNumber,
		boss = boss,
		players = players,
		healthFactor = Config.bossHealthFactor(players),
		rewardFactor = Config.bossRewardFactor(players),
		bossEntry = nil,
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
		local groups = math.max(1, math.ceil(record.count / WV.SpawnGroupSize))
		local index = 0
		for group = 1, groups do
			-- A bearing per cluster, spread around the rim and jittered, so
			-- successive waves do not land in the same six places.
			local groupAngle = ((group - 1) / groups) * math.pi * 2 + math.random() * 0.6
			for _ = 1, WV.SpawnGroupSize do
				index += 1
				if index > record.count then
					break
				end
				if record ~= liveWave then
					return
				end
				spawnRaider(record, index, record.count, false, groupAngle)
				task.wait(WV.SpawnGap)
			end
			if group < groups then
				task.wait(WV.SpawnGroupGap)
			end
		end
		if record.boss and record == liveWave then
			-- No bearing: the boss lands on the dais, at the same spot every
			-- time, so a server-wide objective is somewhere everyone can name.
			spawnRaider(record, 0, record.count, true, nil)
		end
		record.spawnFinished = true
		record.deadline = os.clock() + WV.MaxWaveTime
	end)
end

--- Kills whatever is left of a wave that has run out of time.
local function forceEnd(record)
	record.forced = true

	-- PAY THE BOSS LEDGER FIRST, PRO-RATA.
	--
	-- The loop below zeroes every survivor with no creator tag, and the comment
	-- on it says no reward is paid for a wave nobody finished, "which is
	-- correct, not an oversight". That reasoning is right for ordinary raiders
	-- and WRONG for a shared boss: twelve people fighting for five straight
	-- minutes and running into MaxWaveTime would get nothing at all, which is
	-- the most player-visible bug this could ship. They are paid for the share
	-- of it they actually took down, and `paid` stops onRaiderDied — which is
	-- about to fire for this very boss — paying a second time.
	local boss = record.bossEntry
	if boss and not boss.paid then
		local humanoid = boss.humanoid
		local pivot = humanoid and humanoid.Parent and (humanoid.Parent :: Model):GetPivot().Position
		payBoss(boss, boss.contribTotal / math.max(boss.maxHealth, 1), pivot, true)
	end

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

--- The tower's door into the one minting site (#95): a public wrapper so
--- TowerService never grows its own AI. opts is mintNPC's contract.
function NPCService.spawn(opts)
	return mintNPC(opts)
end

--- Read-only walk of every live entry — TowerService sweeps its own floor's
--- bodies on a run ending. Nothing outside this file may write through it.
function NPCService.activeEntries()
	return active
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

	-- One hook, registered once. CombatService does not know what a raid is and
	-- must not learn; this is the same arrangement Economy has with its
	-- multiplier hooks, and for the same reason.
	CombatService.setDamageObserver(onDamageDealt)

	game:GetService("RunService").Heartbeat:Connect(function(dt)
		local ok, err = pcall(tick, dt)
		if not ok then
			warn("[Tung] NPC tick error: " .. tostring(err))
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.defer(NPCService.pushTo, player)
	end)

	-- The world loop: the roamer census and the plot-siege schedules. Gated
	-- on its own flags rather than on WV.Enabled — turning the central wave
	-- off must not empty the bands.
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				local now = os.clock()
				maintainRoamers(now)
				stepPlotSieges(now)
			end)
			if not ok then
				warn("[Tung] world step error: " .. tostring(err))
			end
			task.wait(MB.MaintainInterval)
		end
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

--- ADMIN HOOKS, for AdminService's !wave and !clear.
---
--- Public functions rather than AdminService reaching in, because the whole
--- reason the schedule is one readable `step` is that nothing else writes
--- `phase` and `phaseUntil`. These two go through the state machine rather than
--- around it: !wave collapses the rest timer so the next step begins a wave the
--- ordinary way, and !clear ends the live one through forceEnd so the flop, the
--- Debris cleanup and the clear banner all still run.
---
--- Neither is reachable without Config.Admin authorisation — see AdminService.

--- Skip the wait before the next raid. False if one is already in flight.
function NPCService.forceWave(): boolean
	if not WV.Enabled then
		return false
	end
	if phase == "idle" then
		setPhase("resting", 0)
		return true
	end
	if phase ~= "resting" then
		return false
	end
	phaseUntil = 0
	return true
end

--- Collapse this plot's rest timer so its next step begins the siege the
--- ordinary way — the forceWave arrangement, one plot down. False while one
--- is already warning or active, or before the plot has a schedule.
function NPCService.forcePlotWave(tycoon): boolean
	if not PW.Enabled or not tycoon then
		return false
	end
	local state = plotSieges[tycoon]
	if not state or state.phase ~= "resting" then
		return false
	end
	state.phaseUntil = 0
	return true
end

--- Kill whatever is standing. False if nothing is.
function NPCService.forceClear(): boolean
	if not liveWave or (phase ~= "active" and phase ~= "spawning") then
		return false
	end
	-- Without this the clear would be read as the mid-drip moment when `alive`
	-- legitimately touches zero, which is the case `spawnFinished` exists for.
	liveWave.spawnFinished = true
	forceEnd(liveWave)
	setPhase("clear", WV.ClearBannerTime)
	return true
end

return NPCService
