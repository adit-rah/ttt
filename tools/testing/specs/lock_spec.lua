--[[
	lock_spec.lua — two servers must never both write one player's save.

	This is the defect named in all five handoffs and in GROWTH-TODO item 11.
	`DataService.save` used UpdateAsync with a transform that ignored its
	argument (`function() return payload end`) — a SetAsync with retries, and
	last-write-wins by construction. Two servers holding the same userId, which
	is what an ordinary soft shutdown, a teleport or a rejoin during a Roblox
	migration produces, clobbered each other silently and forever.

	The lock lives INSIDE the profile record, as `stored.__lock`. Roblox has no
	cross-key transaction, so a lock in its own key could only ever be checked
	SEPARATELY from the write it guards — a smaller race, not a fix. In the
	record, "only the lock holder may write" is one UpdateAsync.

	Two specs here are worth more than the rest of the family put together, and
	both reach something no Config assertion could ever have reached:

	  * "two realms cannot both hold one key" — two independent loads of the
	    module tree over one mock DataStore is a genuine two-server race, run
	    deterministically.
	  * "the loser of a steal never writes" — the stolen server's autosave has
	    to abandon its payload rather than merge it. That write IS the data loss.
]]

return function(T)

T.family("lock", "one server at a time may write a profile, and it must know when it stops being that server")

--- Config.Persistence, typed loosely on purpose. Reading `w.config.Persistence.X`
--- inline exhausts luau-analyze's inference budget against a 1,600-line Config
--- and reports it as a whole-file finding, which verify.py treats as a failure.
local function P(w): any
	return w.config.Persistence
end

local function keyOf(player): string
	return "player_" .. player.UserId
end

--- Deep value equality, so "the record did not change" is one assertion rather
--- than a field-by-field list that quietly stops covering new fields.
local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--- A stored record shaped the way a real one is, plus whatever lock the spec
--- wants sitting on it.
local function record(cash: number, lock)
	return {
		cash = cash,
		owned = {},
		rebirths = 0,
		batTier = 1,
		armorTier = 1,
		kills = 0,
		playtime = 0,
		lastSeen = 0,
		sessions = {},
		unlocks = {},
		upgrades = {},
		utilityEquipped = "",
		version = 2,
		__lock = lock,
	}
end

--- A load that must complete WITHOUT waiting.
---
--- On its own thread deliberately. A load that unexpectedly blocks would yield
--- the spec body itself, and a yield from the main thread is "thread yielded
--- unexpectedly" — an error no xpcall can catch, which kills the whole report
--- instead of failing one assertion. Every regression in this family that turns
--- an instant acquire into a waiting one lands here as a readable failure.
local function loadNow(t, Data, player, message: string)
	local done, result = false, nil
	task.spawn(function()
		result = Data.load(player)
		done = true
	end)
	t:isTrue(done, message)
	return result
end

--- A load that is expected to BLOCK on a held lock. Lets the retry window
--- elapse and reports whether it ever finished.
local function loadAcross(w, Data, player, seconds: number)
	local done, result = false, nil
	task.spawn(function()
		result = Data.load(player)
		done = true
	end)
	w.clock:advance(seconds)
	return done, result
end

-- ── taking the lock ─────────────────────────────────────────────────────────

T.spec("a free key is taken, and the acquire IS the read", function(t)
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")

	local player = w.join("first", 1001)
	local profile = loadNow(t, Data, player, "taking a lock nobody holds must not wait for anything")

	t:notNil(profile, "a key nobody holds must load")
	local stored = w.store():raw(keyOf(player))
	t:eq(stored.__lock.jobId, "job-A",
		"the stored record carries no lock, so nothing stops a second server writing over this player")
	t:eq(stored.__lock.heartbeat, os.time(), "the heartbeat is not the time the lock was taken")
	t:eq(stored.__lock.placeId, 1234567, "the lock does not say which place holds it")
	t:calls(w.store(), "UpdateAsync", 1,
		"taking a free lock cost more than one round trip — the acquire is supposed to be the read")
	t:calls(w.store(), "GetAsync", 0,
		"a separate GetAsync doubles the request cost of every join and re-reads a record the acquire already returned")
end)

T.spec("a fresh foreign lock is refused, and the record is left untouched", function(t)
	local w = T.world()
	w.jobId = "job-B"
	local Data = w.req("DataService")

	local player = w.join("locked-out", 1002)
	local seed = record(777, { jobId = "job-A", heartbeat = os.time(), placeId = 1234567 })
	w.store():seed(keyOf(player), seed)

	local done, profile = loadAcross(w, Data, player, 300)

	t:isTrue(done, "the acquire loop never gave up — a player would sit on the loading screen forever")
	t:isNil(profile, "a live foreign lock was honoured in name only; the second server got a profile anyway")
	t:notNil(player.kicked, "the player was left in the game with no profile, which every consumer reads as nil")
	t:calls(w.store(), "UpdateAsync", P(w).AcquireAttempts,
		"the acquire loop did not run its full budget of attempts")

	local calls = w.store().calls
	local window = calls[#calls].atMono - calls[1].atMono
	t:gte(window, 28,
		"the retry window is shorter than a soft shutdown's drain, so an ordinary shutdown becomes a kick storm")
	t:gt(window, P(w).AcquireAttempts * P(w).AcquireRetrySeconds - P(w).AcquireRetrySeconds,
		"the retries are unjittered — a mass teleport lands a dozen players at once and their retries arrive as one burst against a single key")

	t:isTrue(same(w.store():raw(keyOf(player)), seed),
		"a refused acquire wrote to the record anyway — the transform must abort, not write a no-op")
end)

T.spec("a stale foreign lock is stolen on the first attempt, loudly", function(t)
	local w = T.world()
	w.jobId = "job-B"
	local Data = w.req("DataService")

	local player = w.join("abandoned", 1003)
	local stale = P(w).LockStaleSeconds
	w.store():seed(keyOf(player), record(777, {
		jobId = "job-A", heartbeat = os.time() - stale - 100, placeId = 1234567,
	}))

	local profile = loadNow(t, Data, player,
		"a five-minute-dead lock was waited on instead of taken; that is 30s of loading screen for nothing")

	t:notNil(profile, "a lock left behind by a dead server locks its owner out of their save permanently")
	t:eq(profile.cash, 777, "the steal threw away the data it was standing on")
	t:calls(w.store(), "UpdateAsync", 1, "stealing a dead lock should be one round trip")
	t:eq(w.store():raw(keyOf(player)).__lock.jobId, "job-B", "the steal did not put our own jobId on the record")
	t:warned("job%-A", "a silent steal leaves no trace of which server was overridden")
	t:warned("job%-B", "the warning does not name the server that did the stealing")
	t:warned("400s", "the warning does not say how stale the lock was, which is the number that says whether it was safe")
end)

T.spec("the stale boundary holds from both sides", function(t)
	-- The one number that decides between "recover a crashed server's player"
	-- and "steal a live server's player". Pinned from both directions, because
	-- an off-by-one either way is a different disaster.
	local stale = P(T.world()).LockStaleSeconds

	local dead = T.world()
	dead.jobId = "job-B"
	local DeadData = dead.req("DataService")
	local pDead = dead.join("just-dead", 1004)
	dead.store():seed(keyOf(pDead), record(1, {
		jobId = "job-A", heartbeat = os.time() - stale, placeId = 1234567,
	}))
	local recovered = loadNow(t, DeadData, pDead,
		("a lock exactly %ds old was waited on rather than taken; the boundary is off by one and a crashed server holds its player out that much longer")
			:format(stale))
	t:notNil(recovered, "the exactly-stale lock was never taken at all")

	-- The other side is asserted on the FIRST attempt and no further, because
	-- the clock keeps running: a lock one second short of stale is legitimately
	-- stealable one second later, and letting the retry window elapse would be
	-- measuring the boundary against a time that has moved past it.
	local alive = T.world()
	alive.jobId = "job-B"
	local AliveData = alive.req("DataService")
	local pAlive = alive.join("just-alive", 1005)
	local seed = record(1, { jobId = "job-A", heartbeat = os.time() - (stale - 1), placeId = 1234567 })
	alive.store():seed(keyOf(pAlive), seed)

	local done = false
	task.spawn(function()
		AliveData.load(pAlive)
		done = true
	end)

	t:isFalse(done,
		("a lock %ds old was taken on the spot; the boundary is off by one and a LIVE server's player gets stolen")
			:format(stale - 1))
	t:calls(alive.store(), "UpdateAsync", 1, "the first attempt should be one round trip")
	t:isTrue(same(alive.store():raw(keyOf(pAlive)), seed),
		("a lock %ds old was overwritten rather than waited on"):format(stale - 1))
end)

T.spec("a server walks back into its own lock, however old", function(t)
	-- Studio never releases: BindToClose early-returns there. SERVER_ID falls
	-- back to the stable string "studio" precisely so the next run recognises
	-- the leftovers as its own instead of sitting out LockStaleSeconds.
	local w = T.world()
	w.isStudio = true
	w.jobId = ""
	local Data = w.req("DataService")

	local player = w.join("restarted", 1006)
	w.store():seed(keyOf(player), record(4242, {
		jobId = "studio", heartbeat = os.time() - 5, placeId = 1234567,
	}))

	local profile = loadNow(t, Data, player,
		"a same-server rejoin waited on a lock it already owns; in Studio that is a 30s pause on every single run")

	t:notNil(profile, "a Studio restart cannot get back into the save it left locked")
	t:eq(profile.cash, 4242, "walking back into our own lock threw the record away")
	t:calls(w.store(), "UpdateAsync", 1, "re-taking our own lock should be one round trip")
	t:isNil(w.warnings[1], "re-taking our own lock is not a steal and must not be reported as one")
end)

T.spec("a second load waits for the first instead of starting its own acquire", function(t)
	-- `loading` was written and never read. That cost nothing while a load was
	-- one GetAsync; SessionService.onPlayer runs
	-- `DataService.get(player) or DataService.load(player)`, so with an acquire
	-- loop in front of it the second caller queues a second acquire against a
	-- key this server is already waiting on — and ends up holding a DIFFERENT
	-- profile table from the rest of the game.
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")
	w.store():latency(5)

	local player = w.join("double-loaded", 1007)
	local first, second
	task.spawn(function() first = Data.load(player) end)
	task.spawn(function() second = Data.load(player) end)
	w.clock:advance(60)

	t:notNil(first, "the first load never completed")
	t:eq(second, first,
		"a concurrent load handed back a second profile table for one player, so half the session's progress lands on a profile nothing else can see")
	t:calls(w.store(), "UpdateAsync", 1,
		"a concurrent load doubled the acquires against one key; on a busy join that is a request budget spent on nothing")
end)

-- ── holding it ──────────────────────────────────────────────────────────────

T.spec("the autosave refreshes the heartbeat and costs no extra write", function(t)
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")
	Data.start()

	local player = w.join("holder", 1008)
	loadNow(t, Data, player, "the holder could not take a free lock")
	local first = w.store():raw(keyOf(player)).__lock.heartbeat

	w.clock:advance(P(w).AutosaveSeconds + 1)

	local lock = w.store():raw(keyOf(player)).__lock
	t:gte(lock.heartbeat - first, P(w).AutosaveSeconds,
		"the heartbeat did not move with the autosave, so a live server's lock goes stale and its player gets stolen")
	t:eq(lock.jobId, "job-A", "the autosave rewrote the lock's owner")
	t:calls(w.store(), "UpdateAsync", 2,
		"the heartbeat is costing a request of its own; it must ride the autosave transform, which is already an UpdateAsync")
end)

T.spec("the heartbeat is stamped inside the transform, not before the call", function(t)
	-- A DataStore round trip is not free, and a heartbeat sampled before it is
	-- born stale by however long the call took — worst exactly when the service
	-- is slow, which is when a lock going stale matters most. It is also what
	-- UpdateAsync's conflict re-run needs: the second run must write the second
	-- run's clock.
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")
	w.store():latency(10)

	local start = os.time()
	local player = w.join("slow-store", 1009)
	local done, profile = loadAcross(w, Data, player, 60)

	t:isTrue(done, "the load never returned")
	t:notNil(profile, "a slow store must still hand back a profile")
	t:eq(w.store():raw(keyOf(player)).__lock.heartbeat, start + 10,
		"the heartbeat was sampled before the round trip, so a slow store writes locks that are already ageing")
end)

T.spec("leaving releases the lock and banks the final cash", function(t)
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")
	Data.start()

	local player = w.join("leaver", 1010)
	local profile = loadNow(t, Data, player, "the leaver could not take a free lock")
	profile.cash = 5150

	w.leave(player)

	local stored = w.store():raw(keyOf(player))
	t:isNil(stored.__lock,
		"a clean logout left the lock behind, so the player has to wait out LockStaleSeconds to rejoin anywhere")
	t:eq(stored.cash, 5150, "the release dropped the lock but not the session's progress")
end)

T.spec("BindToClose drains and releases on a server, and writes nothing in Studio", function(t)
	local live = T.world()
	live.isStudio = false
	live.jobId = "job-A"
	local LiveData = live.req("DataService")
	LiveData.start()
	local pLive = live.join("shutting-down", 1011)
	loadNow(t, LiveData, pLive, "the shutting-down server could not take a free lock").cash = 999

	live.shutdown()

	local stored = live.store():raw(keyOf(pLive))
	t:eq(stored.cash, 999, "a soft shutdown lost the session it had 25 seconds to drain")
	t:isNil(stored.__lock,
		"a soft shutdown left its locks behind, so every player it teleports away waits out the whole acquire window on arrival")

	local studio = T.world()
	studio.isStudio = true
	studio.jobId = ""
	local StudioData = studio.req("DataService")
	StudioData.start()
	local pStudio = studio.join("stopped", 1012)
	loadNow(t, StudioData, pStudio, "the Studio session could not take a free lock")
	local before = studio.store():countCalls("UpdateAsync")

	studio.shutdown()

	t:calls(studio.store(), "UpdateAsync", before,
		"Studio wrote on shutdown; it is not a real session and must never touch live data")
	t:notNil(studio.store():raw(keyOf(pStudio)).__lock,
		"Studio released its lock, which contradicts the stable 'studio' server id that exists to walk back into it")
end)

-- ── two servers ─────────────────────────────────────────────────────────────

T.spec("two realms cannot both hold one key", function(t)
	-- The production failure nobody has ever been able to reproduce: two
	-- independent loads of the module tree, each with its own DataService
	-- upvalues, racing over one DataStore.
	local w = T.world()
	w.jobId = "job-A"
	local A = w.req("DataService")
	w.jobId = "job-B"
	local B = w.realm().req("DataService")

	local player = w.join("contested", 1013)

	local a = loadNow(t, A, player, "the first server could not take a free key")
	t:notNil(a, "the first server got no profile")
	a.cash = 31337

	local done, b = loadAcross(w, B, player, 300)
	t:isTrue(done, "the second server never gave up")
	t:isNil(b, "both servers hold the same save and the later one to write wins — this IS the defect")
	t:notNil(player.kicked, "the second server let the player in with no profile")
	t:eq(w.store():raw(keyOf(player)).__lock.jobId, "job-A", "the refused server took the lock anyway")

	t:isTrue(A.save(player, true), "the holder could not write its own save")
	t:isNil(w.store():raw(keyOf(player)).__lock, "releasing did not clear the lock")

	player.kicked = nil
	local b2 = loadNow(t, B, player, "a released lock is still not takeable, so the handover never completes")
	t:notNil(b2, "the second server got no profile after a clean release")
	t:eq(b2.cash, 31337, "the second server picked up a stale record rather than what the first one banked")
	t:eq(w.store():raw(keyOf(player)).__lock.jobId, "job-B", "the second server holds the profile but not the lock")
end)

T.spec("the loser of a steal never writes", function(t)
	-- THE HEADLINE. A server frozen past LockStaleSeconds has its lock taken
	-- while it still believes it holds it. Everything in its memory is now older
	-- than what the new owner has been saving, so its next autosave is not a
	-- save — it is the rollback.
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")
	Data.start()

	local player = w.join("frozen", 1014)
	local profile = loadNow(t, Data, player, "the frozen server could not take a free lock")
	profile.cash = 12345
	Data.save(player, false)

	-- Out of band, the way the other server would have done it: our lock is
	-- gone, someone else's is on the record, and they have been playing.
	local taken = w.store():raw(keyOf(player))
	taken.cash = 60000
	taken.__lock = { jobId = "job-B", heartbeat = os.time(), placeId = 1234567 }
	w.store():seed(keyOf(player), taken)

	profile.cash = 999999
	w.clock:advance(P(w).AutosaveSeconds + 1)

	local after = w.store():raw(keyOf(player))
	t:isTrue(same(after, taken),
		"a server that lost its lock wrote anyway and rolled the new owner's session back — this is the data loss the whole change exists to stop")
	t:eq(after.cash, 60000, "the stale payload landed on top of the live one")
	t:isTrue(profile.__loadFailed,
		"the losing session was left saveable, so every later autosave takes another run at clobbering the record")
	t:notNil(player.kicked,
		"the player is still playing a session that can never be saved again")
end)

-- ── the paths that must not have changed ────────────────────────────────────

T.spec("a failed read still never writes", function(t)
	-- README: "DataService refuses to save a profile whose load failed. Better
	-- to lose a session than to overwrite a real save with a default one." The
	-- lock must not have quietly given that up.
	local w = T.world()
	local Data = w.req("DataService")
	local store = w.store()
	store:fail("UpdateAsync")

	local player = w.join("unreadable", 1015)
	local done, profile = loadAcross(w, Data, player, 300)

	t:isTrue(done, "a DataStore outage hung the load instead of failing it")
	t:notNil(profile, "a DataStore outage must still yield a playable memory-only session")
	t:isTrue(profile.__loadFailed, "a failed acquire produced a profile the game will happily save over a real one")

	store:clearFaults()
	Data.start()
	local before = store:countCalls("UpdateAsync")
	w.clock:advance(3 * P(w).AutosaveSeconds + 3)

	t:calls(store, "UpdateAsync", before,
		"a profile whose load failed wrote to the store; a default profile has just replaced a real save")
end)

T.spec("memory-only mode never touches a DataStore at all", function(t)
	local w = T.world()
	w.dataStoreService.fail = true       -- Studio with API access off
	local Data = w.req("DataService")
	Data.start()

	local player = w.join("apiless", 1016)
	local profile = loadNow(t, Data, player, "memory-only mode reached lock code and waited on something")

	t:notNil(profile, "the game must still run with DataStores unavailable")
	t:isTrue(profile.__loadFailed, "memory-only mode must refuse to save, not save into the void")
	profile.cash = 4242
	t:isFalse(Data.save(player, false), "memory-only mode reported a save that cannot have happened")

	w.clock:advance(3 * P(w).AutosaveSeconds + 3)
	t:isNil(w.dataStoreService.stores.TungTungTycoon_v1,
		"lock code reached the DataStore in memory-only mode, where the store handle does not exist")
end)

T.spec("the lock never reaches the profile, and dead keys never accumulate", function(t)
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")

	local player = w.join("clean", 1017)
	local seeded = record(500, { jobId = "job-A", heartbeat = os.time(), placeId = 1234567 })
	seeded.ghost = 7                       -- a key no schema has mentioned in a year
	w.store():seed(keyOf(player), seeded)

	local profile = loadNow(t, Data, player, "walking back into our own lock waited on it")
	t:isNil(profile.__lock,
		"the lock reached the in-memory profile, where any consumer can read it and SessionService can hand it back into a save")
	t:isNil(profile.ghost, "reconcile merged a key the default does not have")

	profile.cash = 6000
	Data.save(player, false)
	t:isNil(profile.__lock, "a save hung the lock on the profile it was saving")

	local stored = w.store():raw(keyOf(player))
	t:isNil(stored.ghost,
		"a key from a retired schema survived a full load and save, so the record grows forever and nothing can ever prune it")
	t:eq(stored.cash, 6000, "the save did not land")
	t:notNil(stored.__lock, "the save dropped the lock without being asked to release it")

	-- THE TRANSFORM IS THE ONLY THING THAT MAY WRITE A LOCK. Hang one on the
	-- profile by hand and the release must still clear the record: if the
	-- payload could carry a lock, anything that touches a profile could forge
	-- one.
	profile.__lock = { jobId = "job-IMPOSTOR", heartbeat = 0, placeId = 1 }
	Data.save(player, true)
	t:isNil(w.store():raw(keyOf(player)).__lock,
		"a lock hung on the profile survived into the record, so the save payload can forge a lock the transform never wrote")
end)

T.spec("the v1 batTier remap still fires through the locking load path", function(t)
	-- profile.batTier is an INDEX. A v1 save reading 3 meant void and now means
	-- ash — an in-range value that quietly means something weaker, which no
	-- clamp can catch. The new load path must still run the migration.
	local w = T.world()
	w.jobId = "job-A"
	local Data = w.req("DataService")

	local player = w.join("legacy", 1018)
	local old = record(500, nil)
	old.version = 1
	old.batTier = 3
	w.store():seed(keyOf(player), old)

	local profile = loadNow(t, Data, player, "a lockless legacy record was treated as held")
	t:eq(profile.version, 2, "PROFILE_VERSION moved; every save written before it is now on an unmigrated path")
	t:eq(profile.batTier, 5,
		"a v1 save's void bat came back as ash — a silent downgrade of a purchase, and nothing else in the game could detect it")

	local stored = w.store():raw(keyOf(player))
	t:eq(stored.version, 2, "the acquire wrote the record back without migrating it")
	t:eq(stored.batTier, 5, "the migrated tier did not survive the acquire's write-back")
end)

T.spec("a re-run transform produces exactly what a single run does", function(t)
	-- Real UpdateAsync re-runs its transform when it loses an internal conflict.
	-- A transform that accumulates instead of assigning — a `+=` onto a captured
	-- table, an outcome field left over from the previous run — diverges only
	-- there, and only in production.
	local function scenario(reentrant: boolean)
		local w = T.world()
		w.jobId = "job-A"
		local Data = w.req("DataService")
		w.store().reentrant = reentrant

		local player = w.join("conflicted", 1019)
		local profile
		task.spawn(function()
			profile = Data.load(player)
			profile.cash = 4242
			profile.playtime = 30
			Data.save(player, false)
		end)
		w.clock:advance(1)

		return w.store():raw(keyOf(player)), profile
	end

	local once, onceProfile = scenario(false)
	local twice, twiceProfile = scenario(true)

	t:isTrue(same(once, twice),
		"running the transform twice for one call produced a different record; a real conflict retry would corrupt the save")
	t:eq(twice.__lock.jobId, "job-A", "the re-run wrote a different owner")
	t:eq(twice.playtime, 30, "playtime accumulated across the re-run instead of being assigned")
	t:eq(onceProfile.cash, twiceProfile.cash, "the profile handed back to the game differs between the two runs")
end)

end
