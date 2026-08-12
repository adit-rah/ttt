--[[
	SessionService.lua — offline earnings, the three session loops (daily
	streak, playtime ladder, boost button) and the three rebirth grants that
	Tycoon:rebirth() does not hand out.

	Three Config.Prototypes flags live here — Offline, Sessions and
	RebirthPerks — because they share one profile sub-table, one replicated
	payload and one panel. Each is checked independently, and with all three
	off every entry point returns before doing any work.

	TIME. Two rules, both of them bugs someone else already shipped:

	  * **os.time(), never tick().** tick() is the wall clock of whatever
	    machine the server happens to be running on. Storing one machine's
	    tick() and subtracting another's is how a developer accidentally
	    granted 1.6 billion from a few seconds of drift. os.time() is UTC
	    epoch seconds and is the same number everywhere.
	  * **Day buckets are math.floor(os.time() / 86400), never
	    os.date("%j").** The day-of-year restarts at 1 on January 1st, so a
	    streak keyed on it breaks for every player in the game on the same
	    night — and it breaks in the direction of resetting their streak.

	os.clock() still appears below, but only for monotonic in-session
	durations (activity sampling, rate limits) where it is the right tool and
	nothing is persisted.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local DataService = Req("DataService")
local Economy = Req("Economy")
local Analytics = Req("Analytics")

local Players = game:GetService("Players")

local SessionService = {}

local P = Config.Prototypes
local S = Config.Sessions
local O = Config.Offline
local RP = Config.RebirthPerks

local DAY = 86400
local PUSH_SECONDS = 5        -- how often state is re-replicated if nothing changed
local ACTIVITY_STUDS = 2      -- movement per sample that counts as "still playing"
local CLAIM_COOLDOWN = 0.25   -- per-player floor between remote claims

local sessionState = Net.event("SessionState")
local requestClaim = Net.event("RequestClaim")
local requestBoost = Net.event("RequestBoost")

--- Anything on at all? The whole file is inert otherwise.
local function enabled(): boolean
	return P.Offline or P.Sessions or P.RebirthPerks
end

-- ─────────────────────────────────────────────────────────────────────────────
-- per-session runtime state (never persisted)
-- ─────────────────────────────────────────────────────────────────────────────

type Live = {
	player: Player,
	activeSeconds: number,        -- session-scoped, and only counts while active
	lastPosition: Vector3?,
	lastClaim: number,
	claimedPlaytime: { [number]: boolean },
	offline: any,                 -- pending welcome-back grant, nil once claimed
	rebirths: number,             -- last seen count, to detect a rebirth landing
	dirty: boolean,
	lastPush: number,
}

local live: { [Player]: Live } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- profile shape
-- ─────────────────────────────────────────────────────────────────────────────

--- The `sessions` sub-table of a profile.
---
--- DataService.reconcile() only type-checks TOP-LEVEL keys, so a table field
--- arrives from the DataStore exactly as it was written — including from a
--- build where the shape was different. Every field is re-derived here on
--- every read, which is cheap and means no other function in this file has to
--- wonder whether a number is a number.
local function sessions(profile)
	local s = profile.sessions
	if type(s) ~= "table" then
		s = {}
		profile.sessions = s
	end
	s.dailyDay = math.floor(tonumber(s.dailyDay) or 0)
	s.streak = math.max(0, math.floor(tonumber(s.streak) or 0))
	s.boostUntil = math.floor(tonumber(s.boostUntil) or 0)
	s.boostReadyAt = math.floor(tonumber(s.boostReadyAt) or 0)
	s.offlineCapLevel = math.clamp(math.floor(tonumber(s.offlineCapLevel) or 0), 0, #O.CapUpgradeHours)
	return s
end

local function dayNumber(): number
	return math.floor(os.time() / DAY)
end

--- UTC, because a server-wide "weekend" that depends on where the machine is
--- would start at different times for different players.
local function isWeekend(): boolean
	return S.WeekendDays[os.date("!*t").wday] == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- income, derived from the SAVED plot
-- ─────────────────────────────────────────────────────────────────────────────

--- Income per second computed from persisted plot state and nothing else.
---
--- Never from a value cached at logout (a stale multiplier survives a nerf and
--- pays out forever) and never from anything the client said. An offline
--- player has no Tycoon instance to ask, which is why this mirrors
--- `Tycoon:incomePerSecond()` rather than calling it.
---
--- Deliberately EXCLUDES the session multipliers below: a 2x boost is bought
--- with presence, and banking it while logged out is the opposite of the
--- point. It includes the rebirth multiplier because that is a property of the
--- factory, not of the session.
function SessionService.incomePerSecondFor(profile): number
	if type(profile) ~= "table" then
		return 0
	end
	local upgradeMult, total = 1, 0
	for id, owned in pairs(profile.owned or {}) do
		local def = owned and Config.ButtonById[id]
		if def then
			if def.kind == "Upgrader" then
				upgradeMult *= def.multiplier
			elseif def.kind == "Dropper" then
				total += def.dropValue / def.dropRate
			end
		end
	end
	local rebirths = math.max(0, math.floor(tonumber(profile.rebirths) or 0))
	-- The generator IS included, for the same reason the rebirth multiplier is
	-- and the boost is not: it is a property of the factory, bought once and
	-- standing there whether or not anyone is logged in. Excluding it would pay
	-- an offline player as though their yard were empty.
	local power = Config.powerFactor(function(id)
		return (profile.owned or {})[id] == true
	end)
	return total * upgradeMult * power * (Config.Rebirth.MultiplierPerRebirth ^ rebirths)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- offline earnings
-- ─────────────────────────────────────────────────────────────────────────────

--- Hours of offline income this profile banks. The cap is a purchase, which is
--- what turns it from a wall you resent into a goal you aim at.
function SessionService.offlineCapHours(profile): number
	local level = sessions(profile).offlineCapLevel
	return O.CapUpgradeHours[level] or O.CapHours
end

--- The upgrade that WOULD have prevented the clip. Naming it on the panel is
--- the difference between "we took your money" and "here is what to buy".
local function nextCapUpgrade(profile)
	local level = sessions(profile).offlineCapLevel + 1
	local hours = O.CapUpgradeHours[level]
	if not hours then
		return nil
	end
	return {
		level = level,
		hours = hours,
		cost = O.CapUpgradeCost[level],
		name = ("Vault Timer %d"):format(level),
		label = ("Vault Timer %d — banks %dh offline instead of %dh"):format(
			level, hours, SessionService.offlineCapHours(profile)),
	}
end

--- What they earned while away. Returns nil when there is nothing worth
--- showing a panel for — that is a real answer, not a failure.
local function computeOffline(profile)
	if not P.Offline then
		return nil
	end
	local lastSeen = math.floor(tonumber(profile.lastSeen) or 0)
	if lastSeen <= 0 then
		return nil            -- no recorded logout: pre-prototype save, or a first session
	end

	local away = os.time() - lastSeen
	-- A clock that went backwards (host migration, NTP correction) must pay
	-- nothing rather than something huge with a sign error in it.
	if away < O.MinimumSeconds then
		return nil
	end

	local perSecond = SessionService.incomePerSecondFor(profile)
	if perSecond <= 0 then
		return nil            -- no factory yet; there is nothing to have missed
	end

	local capSeconds = SessionService.offlineCapHours(profile) * 3600
	local credited = math.min(away, capSeconds)
	local earned = math.floor(credited * perSecond * O.Rate)
	if earned <= 0 then
		return nil
	end

	return {
		seconds = away,
		creditedSeconds = credited,
		earned = earned,
		rate = O.Rate,
		perSecond = perSecond,
		capHours = capSeconds / 3600,
		clipped = away > capSeconds,
		lost = math.max(0, math.floor((away - credited) * perSecond * O.Rate)),
		upgrade = nextCapUpgrade(profile),
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- daily streak
-- ─────────────────────────────────────────────────────────────────────────────

local function dailyRewardFor(streak: number)
	-- the ladder loops, so day 8 restarts at day 1's payout and the MILESTONES
	-- carry the long tail
	local index = ((math.max(1, streak) - 1) % #S.DailyRewards) + 1
	local base = S.DailyRewards[index]
	local milestone = S.DailyMilestones[streak]
	return base + (milestone or 0), index, milestone
end

--- Streak arithmetic in whole UTC day buckets.
---
--- Grace is expressed in buckets rather than hours on purpose: buckets are
--- coarse (claim at 23:00 and again at 01:00 two buckets later is 26 real
--- hours), and every rounding error in a grace period should fall on the
--- player's side. Losing a 20-day streak to one missed evening is how you lose
--- the player, not the streak.
local function nextStreak(s): number
	local graceBuckets = 1 + math.floor(S.DailyGraceHours / 24)
	if s.dailyDay <= 0 then
		return 1
	end
	local gap = dayNumber() - s.dailyDay
	if gap <= graceBuckets then
		return s.streak + 1
	end
	return 1
end

local function dailyState(profile)
	local s = sessions(profile)
	local streak = nextStreak(s)
	local reward, index, milestone = dailyRewardFor(streak)
	return {
		available = s.dailyDay < dayNumber(),
		streak = s.streak,
		nextStreak = streak,
		dayIndex = index,
		ladder = #S.DailyRewards,
		reward = reward,
		milestone = milestone,
		graceHours = S.DailyGraceHours,
		-- seconds until the next bucket opens, for the "come back in" line
		resetIn = ((dayNumber() + 1) * DAY) - os.time(),
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- playtime ladder
-- ─────────────────────────────────────────────────────────────────────────────

local function playtimeReward(index: number): number
	return math.floor(S.PlaytimeRewardBase * (S.PlaytimeRewardGrowth ^ (index - 1)))
end

local function playtimeState(entry: Live)
	local rungs = {}
	for index, minutes in ipairs(S.PlaytimeMinutes) do
		local required = minutes * 60
		local status = "locked"
		if entry.claimedPlaytime[index] then
			status = "claimed"
		elseif entry.activeSeconds >= required then
			status = "ready"
		end
		rungs[index] = {
			index = index,
			minutes = minutes,
			reward = playtimeReward(index),
			status = status,
		}
	end
	return {
		activeSeconds = math.floor(entry.activeSeconds),
		rungs = rungs,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- boost + weekend
-- ─────────────────────────────────────────────────────────────────────────────

--- Everything the session layer multiplies income by. Registered onto Economy
--- at start(), so `Economy.multiplier()` — and therefore every payout and
--- every income/sec readout — picks it up without Economy knowing this file
--- exists.
function SessionService.incomeMultiplier(player: Player): number
	if not P.Sessions then
		return 1
	end
	local profile = DataService.get(player)
	if not profile then
		return 1
	end
	local mult = 1
	if sessions(profile).boostUntil > os.time() then
		mult *= S.BoostMultiplier
	end
	if isWeekend() then
		mult *= S.WeekendMultiplier
	end
	return mult
end

local function boostState(profile)
	local s = sessions(profile)
	local now = os.time()
	return {
		active = s.boostUntil > now,
		secondsLeft = math.max(0, s.boostUntil - now),
		cooldownLeft = math.max(0, s.boostReadyAt - now),
		multiplier = S.BoostMultiplier,
		duration = S.BoostSeconds,
		cooldown = S.BoostCooldown,
		weekend = isWeekend(),
		weekendMultiplier = S.WeekendMultiplier,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- rebirth perks
-- ─────────────────────────────────────────────────────────────────────────────

--- The four things a rebirth pays, for a given profile's CURRENT rebirth count.
---
--- Exposed rather than applied wholesale because `Tycoon:rebirth()` is owned by
--- another track and already applies two of them (it increments
--- profile.rebirths, which is the multiplier, and resets cash to
--- Config.Economy.StartingCash). This function is the single description of
--- all four; Economy.applyRebirthGrants() consumes two more, and the fourth is
--- the TODO below.
---
--- Safe to call with the flag off: you get the shipped behaviour (multiplier
--- only, default starting cash), which is what makes it usable as the one
--- source of truth for a HUD.
function SessionService.rebirthPerksFor(profile)
	local n = math.max(0, math.floor(tonumber(profile and profile.rebirths) or 0))
	local perks = {
		rebirths = n,
		multiplier = Config.Rebirth.MultiplierPerRebirth ^ n,
		startingCash = Config.Economy.StartingCash,
		capacityBonus = 0,
		milestone = nil,
		unlocks = {},
	}
	if not P.RebirthPerks or n == 0 then
		return perks
	end

	-- Geometric like the cost curve it is paid against; a flat per-rebirth
	-- grant is invisible by rebirth four.
	perks.startingCash = math.max(
		Config.Economy.StartingCash,
		math.floor(RP.StartingCashPerRebirth * (RP.StartingCashGrowth ^ (n - 1))))

	-- TODO(capacity): the third grant is a PERMANENT CAPACITY BUMP and it is
	-- the one part of this that cannot be applied from outside the tycoon.
	-- The consumer is `Tycoon:spawnDrop()`, whose guard reads
	--
	--     if self.dropCount >= Config.Economy.MaxDropsPerPlot then
	--
	-- and needs to become
	--
	--     local perks = SessionService.rebirthPerksFor(DataService.get(self.owner))
	--     if self.dropCount >= Config.Economy.MaxDropsPerPlot + perks.capacityBonus then
	--
	-- Tycoon.lua is owned by another track, so the number is computed and
	-- replicated here and is simply not read yet. Belt occupancy is verified
	-- in tools/verify_config.lua, so raising the cap needs that check re-run.
	perks.capacityBonus = math.floor(n / RP.SlotEveryRebirths)

	perks.milestone = RP.Milestones[n]
	-- every milestone at or below the current count, so a player who somehow
	-- skipped one (a rollback, an admin grant) still owns everything they passed
	for at, milestone in pairs(RP.Milestones) do
		if n >= at then
			perks.unlocks[milestone.unlock] = milestone.label
		end
	end
	return perks
end

--- Has this profile been granted a milestone unlock? The persisted form is
--- `profile.unlocks[id] = label`, written by Economy.applyRebirthGrants — this
--- is the read side, for whoever consumes "mezzanine" / "utility2" /
--- "goldplot" (FloorService and the utility slot own those, not this file).
function SessionService.hasUnlock(profile, id: string): boolean
	return type(profile) == "table" and type(profile.unlocks) == "table" and profile.unlocks[id] ~= nil
end

--- Detected rather than called: Tycoon:rebirth() is off limits, so the rebirth
--- count is polled once a second and the extra grants land right behind it.
local function onRebirthDetected(player: Player, profile, entry: Live)
	local perks = SessionService.rebirthPerksFor(profile)
	local granted = Economy.applyRebirthGrants(player, perks)

	local lines = { ("All payouts x%.2f"):format(perks.multiplier) }
	if granted > 0 then
		table.insert(lines, ("Starting cash %s"):format(Util.abbreviate(granted)))
	end
	if perks.capacityBonus > 0 then
		table.insert(lines, ("+%d permanent slot%s"):format(
			perks.capacityBonus, perks.capacityBonus == 1 and "" or "s"))
	end
	if perks.milestone then
		table.insert(lines, ("Unlocked: %s"):format(perks.milestone.label))
	end

	Economy.notify(player, {
		kind = "rebirth",
		title = ("REBIRTH %d PERKS"):format(perks.rebirths),
		body = table.concat(lines, "  •  "),
	})
	entry.dirty = true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- replication
-- ─────────────────────────────────────────────────────────────────────────────

--- The entire replicated payload for one player. Public because it is also the
--- answer to "what does the server think my session is", which is the only
--- useful thing to print when a claim button disagrees with the server.
function SessionService.stateFor(player: Player)
	local entry = live[player]
	local profile = DataService.get(player)
	if not entry or not profile then
		return nil
	end
	return {
		enabled = { offline = P.Offline, sessions = P.Sessions, rebirth = P.RebirthPerks },
		daily = P.Sessions and dailyState(profile) or nil,
		playtime = P.Sessions and playtimeState(entry) or nil,
		boost = P.Sessions and boostState(profile) or nil,
		offline = entry.offline,
		rebirth = P.RebirthPerks and SessionService.rebirthPerksFor(profile) or nil,
	}
end

local function pushState(player: Player)
	local entry = live[player]
	local payload = SessionService.stateFor(player)
	if not entry or not payload then
		return
	end
	entry.dirty = false
	entry.lastPush = os.clock()
	sessionState:FireClient(player, payload)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- claims (server-authoritative; the client sends an intent, never an amount)
-- ─────────────────────────────────────────────────────────────────────────────

local function claimOffline(player: Player, entry: Live)
	local pending = entry.offline
	if not P.Offline or not pending then
		return
	end
	-- cleared BEFORE the payout so a double-fired remote cannot pay twice
	entry.offline = nil

	Economy.add(player, pending.earned, false)   -- perSecond already carries the rebirth multiplier
	Economy.push(player)
	-- `clipped` is the only reason this event carries a facet at all: whether
	-- the 8-hour cap actually cut someone off is the question that decides
	-- whether the Vault Timer upgrades are worth anything.
	Analytics.onOfflineClaim(player, pending, Economy.get(player))
	Economy.notify(player, {
		kind = "claim",
		title = "OFFLINE TUNG COLLECTED",
		body = ("%s banked from %s away."):format(
			Util.abbreviate(pending.earned), SessionService.describeDuration(pending.seconds)),
	})
	entry.dirty = true
end

local function claimDaily(player: Player, entry: Live, profile)
	if not P.Sessions then
		return
	end
	local s = sessions(profile)
	local today = dayNumber()
	if s.dailyDay >= today then
		return                      -- already claimed in this UTC bucket
	end

	local streak = nextStreak(s)
	local reward, _index, milestone = dailyRewardFor(streak)
	s.streak = streak
	s.dailyDay = today

	-- flat, unmultiplied: a login reward that scales with a 2x boost turns the
	-- boost button into a "wait before claiming" puzzle
	Economy.add(player, reward, false)
	Economy.push(player)
	Economy.notify(player, {
		kind = "claim",
		title = ("DAY %d STREAK"):format(streak),
		body = milestone
			and ("%s — including a %s milestone bonus."):format(Util.abbreviate(reward), Util.abbreviate(milestone))
			or ("%s. Come back tomorrow for more."):format(Util.abbreviate(reward)),
	})
	entry.dirty = true
end

local function claimPlaytime(player: Player, entry: Live, index: number)
	if not P.Sessions then
		return
	end
	local minutes = S.PlaytimeMinutes[index]
	if not minutes or entry.claimedPlaytime[index] then
		return
	end
	if entry.activeSeconds < minutes * 60 then
		return                      -- the client asked early; the server decides
	end

	entry.claimedPlaytime[index] = true
	local reward = playtimeReward(index)
	Economy.add(player, reward, false)
	Economy.push(player)
	Economy.notify(player, {
		kind = "claim",
		title = ("%d MINUTES PLAYED"):format(minutes),
		body = ("%s. The ladder resets when you leave."):format(Util.abbreviate(reward)),
	})
	entry.dirty = true
end

local function claimBoost(player: Player, entry: Live, profile)
	if not P.Sessions then
		return
	end
	local s = sessions(profile)
	local now = os.time()
	if s.boostReadyAt > now then
		return
	end
	s.boostUntil = now + S.BoostSeconds
	s.boostReadyAt = now + S.BoostCooldown

	Economy.push(player)            -- the multiplier readout changes immediately
	Economy.notify(player, {
		kind = "gear",
		title = ("x%g BOOST ACTIVE"):format(S.BoostMultiplier),
		body = ("All income x%g for %d minutes."):format(S.BoostMultiplier, S.BoostSeconds // 60),
	})
	entry.dirty = true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- activity
-- ─────────────────────────────────────────────────────────────────────────────

--- The playtime ladder is gated on ACTIVITY, not wall clock. Paying for
--- alt-tabbed minutes prices the reward against nothing and rewards the one
--- behaviour a session loop exists to avoid.
---
--- Two signals, because either alone has a hole: position delta misses someone
--- holding W into a wall, and MoveDirection misses someone being carried by a
--- conveyor or a knockback. Neither misses someone actually playing.
local function sampleActivity(entry: Live, dt: number)
	local character = entry.player.Character
	if not character then
		entry.lastPosition = nil
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local active = false
	local position = (root :: BasePart).Position
	if entry.lastPosition and (position - entry.lastPosition).Magnitude >= ACTIVITY_STUDS then
		active = true
	end
	entry.lastPosition = position

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MoveDirection.Magnitude > 0.1 then
		active = true
	end

	if active then
		local before = entry.activeSeconds
		entry.activeSeconds += dt
		-- a rung becoming claimable is the moment worth replicating
		for index, minutes in ipairs(S.PlaytimeMinutes) do
			local required = minutes * 60
			if before < required and entry.activeSeconds >= required and not entry.claimedPlaytime[index] then
				entry.dirty = true
				Economy.notify(entry.player, {
					kind = "claim",
					title = ("%d MINUTE REWARD READY"):format(minutes),
					body = ("Claim %s from the session panel."):format(Util.abbreviate(playtimeReward(index))),
				})
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- public
-- ─────────────────────────────────────────────────────────────────────────────

--- "2 days, 3 hours" — the panel has to state how long they were away, and
--- "173,244 seconds" is not that.
function SessionService.describeDuration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local days = seconds // DAY
	local hours = (seconds % DAY) // 3600
	local minutes = (seconds % 3600) // 60
	if days > 0 then
		return ("%dd %dh"):format(days, hours)
	elseif hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	elseif minutes > 0 then
		return ("%dm"):format(minutes)
	end
	return ("%ds"):format(seconds)
end

--- One beat of one player's session. Pulled out of the loop below so the loop
--- reads as a loop, and so the whole of this file can be driven a step at a
--- time from outside Roblox.
function SessionService.step(player: Player, dt: number)
	local entry = live[player]
	local profile = DataService.get(player)
	if not entry or not profile then
		return
	end

	-- Keep the logout stamp fresh every beat. PlayerRemoving also writes it,
	-- but DataService connects its own PlayerRemoving save first and signal
	-- handler order is not a guarantee — this is what actually makes the
	-- offline calculation correct, and it costs a server crash at most one
	-- second of a player's banked time.
	profile.lastSeen = os.time()

	if P.Sessions then
		sampleActivity(entry, dt)
	end

	if P.RebirthPerks then
		local rebirths = math.max(0, math.floor(tonumber(profile.rebirths) or 0))
		if rebirths > entry.rebirths then
			entry.rebirths = rebirths
			onRebirthDetected(player, profile, entry)
		end
	end

	if entry.dirty or os.clock() - entry.lastPush >= PUSH_SECONDS then
		pushState(player)
	end
end

function SessionService.onPlayer(player: Player)
	if not enabled() then
		return
	end
	local profile = DataService.get(player) or DataService.load(player)
	if not profile then
		return
	end

	local entry: Live = {
		player = player,
		activeSeconds = 0,
		lastPosition = nil,
		lastClaim = 0,
		claimedPlaytime = {},
		offline = nil,
		rebirths = math.floor(tonumber(profile.rebirths) or 0),
		dirty = true,
		lastPush = 0,
	}
	live[player] = entry

	-- Read lastSeen BEFORE stamping it, then stamp it: from here on this
	-- session owns the clock.
	entry.offline = computeOffline(profile)
	profile.lastSeen = os.time()

	if P.RebirthPerks and entry.rebirths > 0 then
		-- Retroactive unlock sync for a save made before this prototype
		-- existed. startingCash is deliberately zeroed: applyRebirthGrants
		-- tops cash UP to the number it is given, and a join must never be a
		-- way to refill your wallet.
		local perks = SessionService.rebirthPerksFor(profile)
		Economy.applyRebirthGrants(player, { startingCash = 0, unlocks = perks.unlocks })
	end

	if entry.offline then
		Economy.notify(player, {
			kind = "welcome",
			title = "WELCOME BACK",
			body = ("Your factory ran for %s while you were gone."):format(
				SessionService.describeDuration(entry.offline.seconds)),
		})
	end

	-- the client's panel is built on the first push, so send one promptly
	task.delay(1, function()
		if live[player] then
			pushState(player)
		end
	end)
end

function SessionService.start()
	if not enabled() then
		return
	end

	if P.Sessions then
		Economy.setMultiplierHook("sessions", SessionService.incomeMultiplier)
	end

	requestClaim.OnServerEvent:Connect(function(player, payload)
		local entry = live[player]
		local profile = DataService.get(player)
		if not entry or not profile or type(payload) ~= "table" then
			return
		end
		-- cheap flood guard: the claims below are all idempotent, but a remote
		-- that can be spammed is a remote that will be
		if os.clock() - entry.lastClaim < CLAIM_COOLDOWN then
			return
		end
		entry.lastClaim = os.clock()

		local kind = payload.kind
		if kind == "offline" then
			claimOffline(player, entry)
		elseif kind == "daily" then
			claimDaily(player, entry, profile)
		elseif kind == "playtime" then
			local index = math.floor(tonumber(payload.index) or 0)
			claimPlaytime(player, entry, index)
		end
		pushState(player)
	end)

	requestBoost.OnServerEvent:Connect(function(player)
		local entry = live[player]
		local profile = DataService.get(player)
		if not entry or not profile then
			return
		end
		if os.clock() - entry.lastClaim < CLAIM_COOLDOWN then
			return
		end
		entry.lastClaim = os.clock()
		claimBoost(player, entry, profile)
		pushState(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local profile = DataService.get(player)
		if profile then
			-- Stamped here AND on the tick below. DataService connects its own
			-- PlayerRemoving save before this one and signal handlers are not
			-- ordered guarantees, so the tick is what actually makes this
			-- correct — this line just tightens the last few seconds.
			profile.lastSeen = os.time()
		end
		live[player] = nil
	end)

	-- One loop for everything: a 1-second beat is fine for session state and
	-- keeps the rebirth grant landing visibly right after the rebirth.
	task.spawn(function()
		while true do
			task.wait(1)
			for player in pairs(live) do
				if player.Parent then
					local ok, err = pcall(SessionService.step, player, 1)
					if not ok then
						warn("[Tung] session tick error: " .. tostring(err))
					end
				else
					live[player] = nil
				end
			end
		end
	end)
end

return SessionService
