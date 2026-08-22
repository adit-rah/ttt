--[[
	DataService.lua — DataStore persistence with SESSION LOCKING, retries,
	autosave and a safe shutdown flush. Falls back to in-memory only if
	DataStores are unavailable (Studio without API access), so the game still
	runs.

	THE LOCK LIVES INSIDE THE PROFILE RECORD, as `stored.__lock`, rather than
	under a key of its own. Roblox has no cross-key transaction, so a lock in a
	second key could only ever be CHECKED separately from the write it is meant
	to guard — and a check that is not the write is a race with a smaller
	window, not a fix. Keeping it in the record makes "only the lock holder may
	write" one UpdateAsync: the transform sees the lock and the data together
	and either writes both or writes neither. It also halves the request cost
	and lets a server that has lost its lock discover that on its next write for
	free, instead of by polling.

	NO PROFILE_VERSION BUMP AND NO MIGRATION IS NEEDED for it, which is worth
	knowing before someone adds one. reconcile() iterates the keys of a fresh
	DEFAULT (`for k, v in pairs(profile)`), so a key the default does not have
	is structurally invisible to it and `__lock` can never reach the in-memory
	profile; and save() builds an explicit payload table rather than cloning the
	profile, so it can never leak back out either. The `__` prefix matches the
	existing `__loadFailed` convention: fields the save format does not own.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataService = {}

local STORE_NAME = "TungTungTycoon_v1"

--- Every timing this file runs on. They are in Config because they are numbers
--- in relationships with each other and tools/verify_config.lua can see Config;
--- see the PERSISTENCE banner there for what each relationship protects.
local P = Config.Persistence

--- WHO THIS SERVER IS, computed once. `game.JobId` is empty in Studio, and the
--- fallback is the stable string "studio" rather than a fresh random id ON
--- PURPOSE: BindToClose early-returns in Studio, so a Studio session never
--- releases its lock, and a stable identity means the next Studio run walks
--- straight back into its own lock instead of waiting out LockStaleSeconds.
local SERVER_ID = (game.JobId ~= "" and game.JobId) or "studio"

--- Bumped whenever a saved value's MEANING changes rather than its shape.
--- reconcile() runs the migrations between the saved version and this one.
---
--- 1 -> 2: Config.Bats grew from three tiers to six, with ash and crimson
---         inserted between oak and void. profile.batTier stores an INDEX, so
---         a v1 save reading "3" meant void and now means ash — a silent
---         downgrade of a purchase, and one nothing else in the game could
---         detect.
local PROFILE_VERSION = 2

--- v1 bat tier -> v2 bat tier. { starter, oak, void } -> their new indices.
local LEGACY_BAT_TIERS = { 1, 2, 5 }

local store: DataStore? = nil
local dataStoresUsable = true

do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		dataStoresUsable = false
		warn("[Tung] DataStores unavailable, running in memory-only mode: " .. tostring(result))
	end
end

local function defaultProfile()
	return {
		cash = Config.Economy.StartingCash,
		owned = {},        -- { [buttonId] = true }
		rebirths = 0,
		batTier = 1,
		armorTier = 1,
		kills = 0,
		playtime = 0,
		-- invariant: SESSION fields. reconcile() merges a saved value onto this
		-- default only when the TYPES match, so adding a field here is what makes every
		-- existing save keep loading: an old profile simply arrives with the
		-- default. Every one of these must ALSO appear in the hand-listed
		-- payload in save() below, or it is dropped on the way out.
		--
		-- lastSeen is 0 rather than os.time() deliberately. A profile that has
		-- never stored one has no knowable logout time, and seeding it with
		-- "now" would look like a zero-second session; seeding it with 0 means
		-- SessionService skips the offline payout for that first session and
		-- starts counting from the logout after it.
		--
		-- `unlocks` used to live here, holding the rebirth milestones a player
		-- had passed. It was a saved copy of something SessionService derives
		-- from profile.rebirths on every read, so it could only ever go stale;
		-- it is gone, and a save that still carries one is simply ignored.
		lastSeen = 0,
		-- #95: the tower — the UTC day last climbed and the best floor
		-- reached that day. Compared against today's day number on read, so
		-- yesterday's best resets by arithmetic instead of by a job.
		tower = { day = 0, best = 0 },
		-- #123: the reputation stat — a weighted count of acts of help. A
		-- number rather than an int: gap weighting accrues halves.
		reputation = 0,
		-- #124: damaged defences, as { [siegeKey] = fraction of full health },
		-- only keys below full. Fractions rather than hit points, so the same
		-- dent survives the max moving when the plot buys land.
		structure = {},
		sessions = {},     -- streak / boost / cap / playtime state, shaped by SessionService
		upgrades = {},     -- { [upgradeId] = level }, shaped by UpgradeService (PROTOTYPE)
		utilityEquipped = "",  -- a Config.Utilities id; "" rather than nil so the
		                       -- type-matched reconcile can merge a saved value

		-- ANALYTICS. Three counters, and all three are ACCOUNT-scoped rather
		-- than session-scoped, which is the only reason they need persisting at
		-- all.
		--
		-- firstBuySeconds is the one worth explaining: 0 means "has never bought
		-- a button", so `first_button_purchased` fires once per ACCOUNT. A
		-- returning player's first purchase of the evening is not onboarding,
		-- and a session-scoped version of this number would say it was, every
		-- evening, forever — which is the shape of a metric that looks healthy
		-- while onboarding is broken.
		--
		-- No PROFILE_VERSION bump and no migration: reconcile() merges a saved
		-- value onto the default only when the types match, so every existing
		-- save simply arrives with 0. That is the correct answer for all three.
		firstJoin = 0,         -- os.time() of the account's first ever session
		totalSessions = 0,     -- incremented by Analytics.onPlayer
		firstBuySeconds = 0,   -- seconds from join to the first button ever bought
		version = PROFILE_VERSION,
	}
end

local profiles: { [number]: any } = {}
local loading: { [number]: boolean } = {}

local function key(userId: number): string
	return "player_" .. userId
end

local function retry(fn, attempts: number)
	local lastErr
	for i = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(0.6 * i)
	end
	return false, lastErr
end

--- Merges saved fields onto a fresh default so schema additions are safe.
local function reconcile(saved)
	local profile = defaultProfile()
	if type(saved) ~= "table" then
		return profile
	end
	for k, v in pairs(profile) do
		if saved[k] ~= nil and type(saved[k]) == type(v) then
			profile[k] = saved[k]
		end
	end
	-- prune ids that no longer exist in Config
	local cleanOwned = {}
	if type(profile.owned) == "table" then
		for id, value in pairs(profile.owned) do
			if value and Config.ButtonById[id] then
				cleanOwned[id] = true
			end
		end
	end
	profile.owned = cleanOwned
	profile.cash = math.max(0, tonumber(profile.cash) or 0)
	profile.rebirths = math.clamp(math.floor(tonumber(profile.rebirths) or 0), 0, Config.Rebirth.MaxRebirths)
	profile.batTier = math.floor(tonumber(profile.batTier) or 1)

	-- MIGRATIONS. Run before the clamps, because a stale index is not out of
	-- range — it is in range and means the wrong thing, which is worse.
	local version = math.floor(tonumber(profile.version) or 1)
	if version < 2 then
		profile.batTier = LEGACY_BAT_TIERS[profile.batTier] or profile.batTier
	end
	profile.version = PROFILE_VERSION

	profile.batTier = math.clamp(profile.batTier, 1, #Config.Bats)
	profile.armorTier = math.clamp(math.floor(tonumber(profile.armorTier) or 1), 1, #Config.Armor.Tiers)

	-- A weapon or armour button is the RECORD of a granted tier, so it must
	-- never disagree with the tier itself. A save from before the weapons
	-- track existed owns batforge and batforge2 but none of the rungs now
	-- sitting between them — and because grantBat is monotonic, those rungs
	-- would light up as available and then take the player's money and do
	-- nothing. Backfill anything the tier already covers.
	--
	-- Idempotent, and it fixes the CLASS: the same divergence would reappear
	-- from any future reordering of Config.Bats.
	for _, def in ipairs(Config.Buttons) do
		if def.kind == "Gear" then
			local bat = Config.BatById[def.grants]
			if bat and bat.tier <= profile.batTier then
				profile.owned[def.id] = true
			end
		elseif def.kind == "Armor" then
			local tier = Config.ArmorById[def.grants]
			if tier and tier.tier <= profile.armorTier then
				profile.owned[def.id] = true
			end
		end
	end

	return profile
end

--- The saved shape of a profile, listed key by key.
---
--- EXPLICIT ON PURPOSE, and a new persisted field needs BOTH this and the key
--- in defaultProfile() — with only the default it works all session and is gone
--- at next login. It is also what keeps `__lock` and `__loadFailed` out of the
--- save: a clone of the profile would carry whatever anyone hung off it.
local function payloadOf(profile)
	return {
		cash = profile.cash,
		owned = profile.owned,
		rebirths = profile.rebirths,
		batTier = profile.batTier,
		armorTier = profile.armorTier,
		kills = profile.kills,
		playtime = profile.playtime,
		lastSeen = profile.lastSeen,
		tower = profile.tower,
		reputation = profile.reputation,
		structure = profile.structure,
		sessions = profile.sessions,
		upgrades = profile.upgrades,
		utilityEquipped = profile.utilityEquipped,
		-- A FIELD ADDED TO defaultProfile() AND NOT TO THIS TABLE IS NEVER
		-- PERSISTED. It defaults correctly, works for the whole session, and is
		-- gone at logout with nothing anywhere saying so. HANDOFF_v4 §2 names
		-- this landmine by name; armorTier nearly repeated it.
		firstJoin = profile.firstJoin,
		totalSessions = profile.totalSessions,
		firstBuySeconds = profile.firstBuySeconds,
		version = profile.version,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SESSION LOCKING
-- ─────────────────────────────────────────────────────────────────────────────

--- What a stored lock means to US, right now. Pure; `now` is passed in rather
--- than read, because every caller is inside an UpdateAsync transform that may
--- run more than once and must sample the clock itself.
---
--- A MISSING OR MALFORMED LOCK COUNTS AS FREE. The store is full of records
--- written before this feature existed, and refusing to touch them would lock
--- every existing player out of their own save.
local function lockState(lock, now: number): string
	if type(lock) ~= "table" or type(lock.jobId) ~= "string" then
		return "free"
	end
	if lock.jobId == SERVER_ID then
		return "own"
	end
	if now - (tonumber(lock.heartbeat) or 0) >= P.LockStaleSeconds then
		return "stale"
	end
	return "held"
end

--- The one write primitive. Everything this file stores goes through it.
---
--- THE TRANSFORM CAN RUN MORE THAN ONCE. UpdateAsync re-runs it when it loses
--- an internal conflict, so a mutator must be pure with respect to anything it
--- captured: it ASSIGNS its result onto `outcome` and never accumulates onto
--- it, and it builds the value it returns from scratch rather than editing
--- something a previous run touched.
local function transact(userId: number, mutate)
	local outcome = {}
	local ok, err = retry(function()
		return (store :: DataStore):UpdateAsync(key(userId), function(stored)
			-- os.time() SAMPLED HERE, inside the transform. A timestamp taken
			-- outside would be stale by exactly however long the conflict that
			-- caused the re-run cost us, which is the one case where a
			-- heartbeat being late matters.
			return mutate(stored, os.time(), outcome)
		end)
	end, 4)
	return ok, err, outcome
end

--- Take the lock, and read the profile in the same round trip.
---
--- Branches in priority order. Our own lock is taken unconditionally however
--- old it is — that is a rejoin to the same server, and the only server that
--- could be racing us is us. A stale foreign lock is stolen on the FIRST
--- attempt, because waiting out a server that has been silent for five minutes
--- helps nobody. A live foreign lock aborts the write by returning nil, which
--- leaves the record untouched down to the byte.
local function acquire(stored, now: number, outcome)
	outcome.stolen = nil
	local state = lockState(stored and stored.__lock, now)

	if state == "held" then
		outcome.status = "held"
		outcome.profile = nil
		return nil
	end
	if state == "stale" then
		local lock = stored.__lock
		outcome.stolen = {
			jobId = tostring(lock.jobId),
			age = now - (tonumber(lock.heartbeat) or 0),
		}
	end

	-- THE ACQUIRE IS THE READ: one round trip, no separate GetAsync. The record
	-- written back is built from a freshly reconciled profile rather than from
	-- `stored`, so a key no schema has mentioned in a year is dropped here
	-- instead of riding along forever.
	local profile = reconcile(stored)
	outcome.status = "acquired"
	outcome.profile = profile

	local out = payloadOf(profile)
	out.__lock = { jobId = SERVER_ID, heartbeat = now, placeId = game.PlaceId }
	return out
end

--- Write `payload`, refreshing the heartbeat — or, on release, dropping the
--- lock entirely.
---
--- A FOREIGN LOCK MEANS WE LOST OURS, and the write is abandoned. It is the
--- serious case: nothing else can put another jobId there while we still hold
--- it, so reaching this branch means this server was frozen or throttled for
--- longer than LockStaleSeconds and someone else has been the owner since.
local function writer(payload, release: boolean)
	return function(stored, now: number, outcome)
		local state = lockState(stored and stored.__lock, now)
		if state == "held" or state == "stale" then
			outcome.status = "lost"
			return nil
		end

		outcome.status = if release then "released" else "written"
		local out = table.clone(payload)
		if not release then
			out.__lock = { jobId = SERVER_ID, heartbeat = now, placeId = game.PlaceId }
		end
		return out
	end
end

function DataService.load(player: Player)
	local userId = player.UserId

	-- WAIT FOR A LOAD ALREADY IN FLIGHT. `loading` was written and never read.
	-- That cost nothing while a load was a single GetAsync; it costs a second
	-- acquire against a key this server is already queueing for now that a load
	-- can take half a minute, because SessionService.onPlayer runs
	-- `DataService.get(player) or DataService.load(player)`.
	while loading[userId] do
		task.wait(0.2)
	end
	if profiles[userId] then
		return profiles[userId]
	end
	loading[userId] = true

	local profile
	if store and dataStoresUsable then
		for _ = 1, P.AcquireAttempts do
			local ok, err, outcome = transact(userId, acquire)
			if not ok then
				warn(("[Tung] load failed for %s: %s"):format(player.Name, tostring(err)))
				profile = reconcile(nil)
				profile.__loadFailed = true   -- never overwrite good data with a failed read
				break
			end
			if outcome.status == "acquired" then
				if outcome.stolen then
					warn(("[Tung] job %s took the session lock on %s from job %s, whose heartbeat is %ds old")
						:format(SERVER_ID, player.Name, outcome.stolen.jobId, outcome.stolen.age))
				end
				profile = outcome.profile
				break
			end
			-- Held by a live server. JITTER MATTERS: a mass teleport lands a
			-- dozen players at once, and unjittered retries arrive as a burst
			-- against one key's request budget.
			task.wait(P.AcquireRetrySeconds + math.random() * 2)
		end

		if not profile then
			warn(("[Tung] job %s could not take the session lock on %s after %d attempts; another server still holds it")
				:format(SERVER_ID, player.Name, P.AcquireAttempts))
			loading[userId] = nil
			player:Kick("Your save is still in use on another server. Please rejoin in a moment.")
			return nil
		end
	else
		profile = reconcile(nil)
		profile.__loadFailed = not dataStoresUsable
	end

	profiles[userId] = profile
	loading[userId] = nil
	return profile
end

function DataService.get(player: Player)
	return profiles[player.UserId]
end

function DataService.save(player: Player, release: boolean?)
	local userId = player.UserId
	local profile = profiles[userId]
	if not profile then
		return false
	end
	if profile.__loadFailed then
		-- data never loaded cleanly; refuse to clobber the real save
		if release then
			profiles[userId] = nil
		end
		return false
	end

	local payload = payloadOf(profile)

	local saved = false
	if store and dataStoresUsable then
		local ok, err, outcome = transact(userId, writer(payload, release == true))
		if not ok then
			warn(("[Tung] save failed for %s: %s"):format(player.Name, tostring(err)))
		elseif outcome.status == "lost" then
			-- WE ARE NOT THE OWNER ANY MORE. Do not write: whoever holds the
			-- lock has been loading, playing and saving this profile while we
			-- were frozen, and our payload is older than theirs by however long
			-- that was. From this instant the session is unsaveable, so it also
			-- ends — playing on is playing for nothing.
			profile.__loadFailed = true
			warn(("[Tung] job %s lost the session lock on %s and will not write; the session was frozen for over %ds")
				:format(SERVER_ID, player.Name, P.LockStaleSeconds))
			player:Kick("Your save was taken over by another server. Please rejoin.")
		else
			saved = true
		end
	end

	if release then
		profiles[userId] = nil
	end
	return saved
end

function DataService.start()
	Players.PlayerRemoving:Connect(function(player)
		DataService.save(player, true)
	end)

	-- THE HEARTBEAT RIDES THIS LOOP. There is deliberately no second timer for
	-- it: every autosave is already an UpdateAsync, and the transform refreshing
	-- `__lock.heartbeat` on its way past costs nothing. A separate heartbeat
	-- loop would double this game's write rate to buy nothing.
	task.spawn(function()
		while true do
			task.wait(P.AutosaveSeconds)
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = profiles[player.UserId]
				if profile then
					profile.playtime += P.AutosaveSeconds
					task.spawn(DataService.save, player, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		-- STUDIO WRITES NOTHING ON SHUTDOWN, which is also why SERVER_ID falls
		-- back to a stable "studio": the lock this session took is still there
		-- at the next run, and the next run recognises it as its own.
		if RunService:IsStudio() then
			return
		end
		local remaining = 0
		for _, player in ipairs(Players:GetPlayers()) do
			remaining += 1
			task.spawn(function()
				DataService.save(player, true)
				remaining -= 1
			end)
		end
		local deadline = os.clock() + P.ShutdownDrainSeconds
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
