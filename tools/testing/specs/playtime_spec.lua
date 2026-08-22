--[[
	playtime_spec.lua — the session ladder pays for PLAYING, not for being
	connected.

	The distinction is the entire feature. A playtime reward gated on the wall
	clock prices itself against nothing: the optimal play is to join, alt-tab,
	and come back an hour later for the money. That is not a session loop, it is
	a tax on the players who are actually there. So `sampleActivity` gates the
	ladder on two signals and accrues `activeSeconds` only when one of them
	fires, and the first spec below is the one that matters — an idle player with
	a fully spawned character, ten minutes of real clock, and a rung that is
	still locked.

	The two signals are tested SEPARATELY because each covers a hole in the
	other, and a regression that deletes one of them leaves the other passing:

	  * position delta misses someone holding W into a wall;
	  * MoveDirection misses someone carried by a conveyor or a knockback.

	Assert them together and either one alone is green.

	THE LAST TWO SPECS USED TO BE ONE, AND IT PINNED A FARM. `claimedPlaytime`
	lived on the per-session Live entry and was never written to the profile, so
	leaving and rejoining re-opened the whole ladder: five minutes of walking was
	worth 1200 tung as many times as you cared to press Leave. That spec asserted
	the farm as shipping behaviour and said, in as many words, that closing it
	meant changing the spec LOUDLY. This is that change.

	The claimed rungs are persisted into `profile.sessions` now and bucketed by
	UTC day — the same `floor(os.time() / 86400)` the streak uses — so the ladder
	is a DAILY loop rather than a per-session one. Which means two boundaries
	worth pinning from both sides, and they pull in opposite directions:

	  * a rejoin inside the same day must NOT re-open a claimed rung (the farm);
	  * the next day MUST re-open the whole ladder (the feature).

	Assert only the first and the fix is indistinguishable from deleting the
	ladder after one use.

	The stored form is a BITMASK, not a `{ [index] = true }` set, and the spec
	reads the raw DataStore blob to say so. A sparse numeric-keyed table goes
	through a JSON round trip as an object with STRING keys, and `claimed["2"]`
	never matches `claimed[2]` again — the ladder would silently re-open on every
	load, which is the exact bug the field exists to close.
]]

return function(T)

T.family("playtime", "the ladder accrues on activity, and resets daily rather than per session")

--- Push a claim through the real remote. The 0.5s nudge clears the 0.25s
--- per-player flood guard, which reads 0 on both sides on a brand new world.
local function claim(w, player, payload)
	local folder = w.replicatedStorage:FindFirstChild("TungNet")
	local remote = folder and folder:FindFirstChild("RequestClaim")
	assert(remote, "harness: no RequestClaim remote in TungNet")
	w.clock:advance(0.5)
	remote.OnServerEvent:Fire(player, payload)
end

local function playtimeState(w, player)
	local state = w.req("SessionService").stateFor(player)
	return state and state.playtime
end

--- A running server, one player, a profile, a live session and a spawned rig.
local function seated(w, name: string, userId: number?)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local player = w.join(name, userId)
	local profile = Data.load(player)
	-- a mid-build factory, so the storage cap (#98) clears every ladder
	-- reward — the cap binding on a bare fixture is the cap working, and
	-- these specs are about the ladder, not the cap
	profile.owned.dropper5 = true
	Session.onPlayer(player)
	w.spawnCharacter(player)
	return player, profile
end

T.spec("an idle player with a character accrues nothing and stays locked", function(t)
	-- The whole reason the ladder is gated on activity instead of on the clock.
	local w = T.retention()
	local Economy = w.req("Economy")
	w.req("SessionService").start()
	local player = seated(w, "afk")

	w.clock:advance(600)       -- ten minutes of wall clock, nobody at the keyboard

	local state = playtimeState(w, player)
	t:eq(state.activeSeconds, 0,
		"an idle player accrued playtime — the ladder is gated on the wall clock, not on activity")
	t:eq(state.rungs[1].status, "locked",
		"the five-minute rung unlocked itself for a player who never moved")

	local before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(Economy.get(player) - before, 0,
		"the server paid a playtime rung the player had not earned")
end)

T.spec("a moving player reaches rung one at 300 active seconds and is paid once", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	local Config = w.config
	w.req("SessionService").start()
	local player = seated(w, "walker")
	w.walk(player, true)

	t:eq(Config.Sessions.PlaytimeMinutes[1], 5, "the first rung is no longer five minutes")
	t:eq(math.floor(Config.Sessions.PlaytimeRewardBase
		* (Config.Sessions.PlaytimeRewardGrowth ^ 0)), 1200, "the first rung's payout has moved")

	w.clock:advance(299)
	t:eq(playtimeState(w, player).rungs[1].status, "locked",
		"the five-minute rung unlocked one second early")

	w.clock:advance(1)
	local state = playtimeState(w, player)
	t:eq(state.activeSeconds, 300, "an actively moving player is not accruing one second per second")
	t:eq(state.rungs[1].status, "ready", "300 active seconds did not unlock the five-minute rung")

	local before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(Economy.get(player) - before, 1200, "the five-minute rung paid the wrong amount")
	t:eq(playtimeState(w, player).rungs[1].status, "claimed", "a paid rung is not being marked claimed")

	before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(Economy.get(player) - before, 0, "a claimed rung paid out a second time")
end)

T.spec("a rung the player has not reached pays nothing however loudly it is asked for", function(t)
	local w = T.retention()
	local Economy = w.req("Economy")
	w.req("SessionService").start()
	local player = seated(w, "eager")
	w.walk(player, true)

	w.clock:advance(300)       -- rung 1 earned, rung 2 (10 minutes) is not
	t:eq(playtimeState(w, player).rungs[2].status, "locked", "the fixture already earned rung two")

	local before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 2 })
	t:eq(Economy.get(player) - before, 0,
		"the client asked early and the server paid — the ladder is client-authoritative")
	t:eq(playtimeState(w, player).rungs[2].status, "locked",
		"an early claim marked an unearned rung as claimed")
end)

T.spec("position delta alone counts as activity, with MoveDirection flat zero", function(t)
	-- The conveyor / knockback case: carried across the map without touching a
	-- key. Driven a step at a time rather than through the session loop so the
	-- rig can be moved BETWEEN samples.
	local w = T.retention()
	local Session = w.req("SessionService")
	local player = seated(w, "carried")

	Session.step(player, 1)
	t:eq(playtimeState(w, player).activeSeconds, 0,
		"the first sample counted as activity before there was anything to compare against")

	w.move(player, 3, 0)
	Session.step(player, 1)
	t:eq(playtimeState(w, player).activeSeconds, 1,
		"a three-stud move with no MoveDirection read as idle — a carried player is not being credited")

	w.move(player, 1, 0)
	Session.step(player, 1)
	t:eq(playtimeState(w, player).activeSeconds, 1,
		"a one-stud drift counted as activity — the two-stud gate is not being applied")
end)

T.spec("MoveDirection alone counts as activity, with the position pinned", function(t)
	-- The holding-W-into-a-wall case: every key held, nothing moves.
	local w = T.retention()
	local Session = w.req("SessionService")
	local player = seated(w, "pusher")

	Session.step(player, 1)
	Session.step(player, 1)
	t:eq(playtimeState(w, player).activeSeconds, 0, "a stationary player accrued playtime")

	w.walk(player, true)
	Session.step(player, 1)
	t:eq(playtimeState(w, player).activeSeconds, 1,
		"a player holding a direction into a wall read as idle — MoveDirection is not being sampled")
end)

T.spec("a rejoin does not re-open a claimed rung, and the claim is on the save", function(t)
	-- THE FARM, CLOSED. This spec is the rewrite of one that asserted the
	-- opposite: `claimedPlaytime` used to live on the per-session Live entry, so
	-- leave/rejoin re-opened every rung and five minutes of walking paid 1200
	-- tung as many times as you cared to reconnect. The claimed set is persisted
	-- into profile.sessions now and this is the assertion that says so.
	local w = T.retention()
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	Data.start()
	Session.start()

	local player = seated(w, "farmer")
	w.walk(player, true)
	w.clock:advance(300)

	local before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(Economy.get(player) - before, 1200, "the fixture never earned the first rung")

	local userId = player.UserId
	w.leave(player)

	local stored = w.store():raw("player_" .. userId)
	t:notNil(stored, "the leave did not save, so the rejoin below reads nothing")
	t:isNil(stored.claimedPlaytime, "the claimed set reached the TOP level of the save")
	-- A BITMASK, and a number rather than a table on purpose: `{ [1] = true }`
	-- comes back from a JSON round trip as `{ ["1"] = true }` and stops matching
	-- the numeric index, which re-opens the ladder without anything erroring.
	t:eq(stored.sessions.playtimeClaimed, 1,
		"rung one is not stored as bit 1 of sessions.playtimeClaimed")
	t:eq(stored.sessions.playtimeDay, math.floor(os.time() / 86400),
		"the claimed set was stored without the day bucket that expires it")

	local rejoined = seated(w, "farmer", userId)
	t:eq(playtimeState(w, rejoined).rungs[1].status, "claimed",
		"a rejoin re-opened a rung that was already claimed today — the farm is back")

	w.walk(rejoined, true)
	w.clock:advance(300)

	before = Economy.get(rejoined)
	claim(w, rejoined, { kind = "playtime", index = 1 })
	t:eq(Economy.get(rejoined) - before, 0,
		"the first rung paid a second time after a rejoin on the same day")
end)

T.spec("the whole ladder re-opens in the next UTC day bucket", function(t)
	-- The other side of the boundary. A ladder that is claimed once and never
	-- comes back is not a daily loop, it is a one-off bonus with a countdown on
	-- it, and closing the farm by making the claim permanent would look exactly
	-- like this spec failing.
	local w = T.retention()
	local Session = w.req("SessionService")
	local Economy = w.req("Economy")
	Session.start()

	local player, profile = seated(w, "returner")
	w.walk(player, true)
	w.clock:advance(300)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(playtimeState(w, player).rungs[1].status, "claimed", "the fixture never claimed rung one")

	local bucket = profile.sessions.playtimeDay
	t:eq(bucket, math.floor(os.time() / 86400), "the claim was not stamped into today's bucket")

	-- still the same day, twenty-three hours later
	w.clock:skip(23 * 3600)
	t:eq(math.floor(os.time() / 86400), bucket, "the fixture crossed midnight before it meant to")
	t:eq(playtimeState(w, player).rungs[1].status, "claimed",
		"the ladder re-opened inside the same UTC day")

	-- and over the boundary
	w.clock:skip(3600)
	t:eq(math.floor(os.time() / 86400), bucket + 1, "the fixture did not cross into the next bucket")
	t:eq(playtimeState(w, player).rungs[1].status, "ready",
		"the new day did not re-open the ladder — the claim is permanent, not daily")

	local before = Economy.get(player)
	claim(w, player, { kind = "playtime", index = 1 })
	t:eq(Economy.get(player) - before, 1200, "the re-opened rung paid nothing")
	t:eq(profile.sessions.playtimeDay, bucket + 1, "the rollover did not restamp the bucket")
end)

end
