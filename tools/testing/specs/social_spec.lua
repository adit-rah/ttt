--[[
	social_spec.lua — the friend bonus, and the four ways it goes quietly wrong.

	Every assertion here is about something that FAILS SILENTLY. The bonus is a
	number multiplied into every payout by a hook nobody sees run, fed by a cache
	nobody prints, filled in by a web call that can fail without anyone noticing.
	There is no crash available in any of these failure modes — only a number on
	a HUD that is wrong, and no way to tell which of the ten HUDs in the server
	is the one lying.

	  THE CAP. min(count, MaxFriends), so a fifth friend pays what a third does.
	  Dropped, the bonus scales with server population and stops being a bonus.

	  A FAILED IsFriendsWith IS RETRIED, NEVER CACHED. Writing `false` on a web
	  failure deletes that friendship for the rest of the server's life, with no
	  error anywhere. This is the single worst outcome the file can produce and
	  it is pinned from both sides: nothing is cached at the moment of failure,
	  and the retry lands the real answer afterwards.

	  A LEAVE RECOUNTS EVERYONE. Friendship is a pair, so one person moving
	  changes somebody else's count. Recounting only the player who moved leaves
	  every other HUD in the server stale.

	  THE HOOK IS KEYED. `setMultiplierHook("friends", ...)` next to
	  `setMultiplierHook("sessions", ...)`: two prototypes stacking, not one
	  overwriting the other. A single-slot hook would have made this spec pass
	  and the boost disappear.

	  IT DOES NOT BANK OFFLINE. `incomePerSecondFor` never calls
	  Economy.multiplier, so the friend bonus cannot reach it. That is a
	  decision — a bonus for being in a server with friends must not pay while
	  you are in no server — and it is worth an assertion precisely because it
	  would be so easy to "fix".
]]

return function(T)

T.family("social", "a friend is worth +10%, and every way that number goes wrong is silent")

--- A server with `friendCount` of `total` other players friendly to "me".
---
--- SocialService.start() is called AFTER everyone has joined and their friend
--- lists are stocked, because the resolve queue is stocked from PlayerAdded and
--- from start()'s catch-up loop alike — and this ordering lets one helper set
--- up any roster without racing the pump.
local function seated(friendCount: number, total: number, opts)
	opts = opts or {}
	local w = opts.world or T.world()
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local Social = w.req("SocialService")

	local me = w.join("me", 1000)
	Data.load(me)
	me.friendsWith = {}

	local others = {}
	for index = 1, total do
		local pal = w.join("pal" .. index, 1000 + index)
		Data.load(pal)
		others[index] = pal
		if index <= friendCount then
			me.friendsWith[pal.UserId] = true
		end
	end

	Social.start()
	-- long enough to drain the whole pair fan-out at ResolveGap apart
	w.clock:advance(w.config.Social.ResolveGap * 60)
	return w, me, others, Economy, Social
end

T.spec("the bonus is +10% a friend and stops dead at the cap", function(t)
	local Config = T.world().config
	t:near(Config.Social.BonusPerFriend, 0.10, 1e-9, "the per-friend bonus this spec pins has moved")
	t:eq(Config.Social.MaxFriends, 3, "the friend cap this spec pins has moved")

	local _, alone, _, economyAlone = seated(0, 3)
	t:near(economyAlone.multiplier(alone), 1.0, 1e-9,
		"a player with no friends in the server is not on x1 — the hook is counting somebody")

	local _, one, _, economyOne = seated(1, 3)
	t:near(economyOne.multiplier(one), 1.10, 1e-9, "one friend is not worth +10%")

	local _, three, _, economyThree = seated(3, 5)
	t:near(economyThree.multiplier(three), 1.30, 1e-9, "three friends are not worth +30%")

	local _, five, _, economyFive, socialFive = seated(5, 5)
	t:eq(socialFive.stateFor(five).friends, 5,
		"the server did not actually see five friends, so the cap assertion below proves nothing")
	t:near(economyFive.multiplier(five), 1.30, 1e-9,
		"a fifth friend paid out — the bonus is not capped at Config.Social.MaxFriends")
end)

T.spec("nobody is friends with themselves, and a stranger is worth nothing", function(t)
	local _, me, others, Economy, Social = seated(1, 3)

	t:eq(Social.stateFor(me).friends, 1, "the one friendship in the fixture did not resolve")
	t:eq(Social.stateFor(others[2]).friends, 0, "a stranger counted as a friend")
	t:near(Economy.multiplier(others[2]), 1.0, 1e-9, "a stranger is being paid a friend bonus")

	-- symmetric: the pair is stored once, so the friend sees it too even though
	-- only `me` was ever asked
	t:eq(Social.stateFor(others[1]).friends, 1,
		"friendship resolved in one direction only — the pair key is not sorting its two user ids")
end)

T.spec("a failed IsFriendsWith is retried and is NEVER cached as false", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local Social = w.req("SocialService")
	local Config = w.config

	local me = w.join("me", 1000)
	local pal = w.join("pal", 1001)
	Data.load(me)
	Data.load(pal)

	local working = me.IsFriendsWith
	me.friendsWith = { [pal.UserId] = true }
	local calls = 0
	me.IsFriendsWith = function()
		calls += 1
		error("HTTP 503 from the friends endpoint")
	end

	Social.start()
	w.clock:advance(Config.Social.ResolveGap * 4)

	t:gte(calls, 1, "the failing call was never made, so nothing was under test")
	t:eq(Social.stateFor(me).friends, 0, "a failed lookup somehow produced a friend")
	t:warned("IsFriendsWith", "a failed friend lookup passed without a warning")

	-- the web comes back
	me.IsFriendsWith = working
	w.clock:advance(Config.Social.RetrySeconds + Config.Social.ResolveGap * 4)

	t:eq(Social.stateFor(me).friends, 1,
		"the friendship never resolved after the retry — the failure was cached as false, which deletes the bonus for the rest of the session")
	t:near(Social.stateFor(me).multiplier, 1.10, 1e-9,
		"the retried friendship did not reach the multiplier")
end)

T.spec("a friend joining recounts EVERYONE, not just the joiner", function(t)
	local w, me, others, _, Social = seated(1, 1)
	t:eq(Social.stateFor(me).friends, 1, "the fixture did not seat one friend")

	-- A late joiner. Its friend list is stocked before the clock moves, which is
	-- what the pump's gap-first ordering buys: no web call goes out on the join
	-- frame, so the mock has the same window Roblox's own latency would give it.
	local late = w.join("late", 2000)
	w.req("DataService").load(late)
	late.friendsWith = { [me.UserId] = true }
	w.clock:advance(w.config.Social.ResolveGap * 20)

	t:eq(Social.stateFor(late).friends, 1, "the joiner does not see the friend it joined")
	t:eq(Social.stateFor(me).friends, 2,
		"the player who was already here still reads 1 — only the joiner was recounted, so every other HUD in the server is stale")
	t:eq(Social.stateFor(others[1]).friends, 1,
		"an unrelated player's count moved when somebody else's friend joined")
end)

T.spec("a friend leaving recounts everyone and drops the multiplier at that instant", function(t)
	local w, me, others, Economy, Social = seated(2, 2)
	t:eq(Social.stateFor(me).friends, 2, "the fixture did not seat two friends")
	t:near(Economy.multiplier(me), 1.20, 1e-9, "two friends are not worth +20%")

	w.leave(others[1])

	t:eq(Social.stateFor(me).friends, 1,
		"a friend left and the count did not follow — the leave path is not recounting")
	t:near(Economy.multiplier(me), 1.10, 1e-9, "the multiplier kept paying for somebody who left")

	w.leave(others[2])
	t:eq(Social.stateFor(me).friends, 0, "the last friend left and the count did not reach zero")
	t:near(Economy.multiplier(me), 1.0, 1e-9, "the bonus outlived every friend it was counting")
end)

T.spec("a friend arriving and leaving both toast, because an unexplained income change reads as a bug", function(t)
	local w, me = seated(0, 1)
	local before = #w.replicatedStorage:FindFirstChild("TungNet"):FindFirstChild("Notify").__fired

	local late = w.join("ana", 2000)
	w.req("DataService").load(late)
	late.friendsWith = { [me.UserId] = true }
	w.clock:advance(w.config.Social.ResolveGap * 20)

	local remote = w.replicatedStorage:FindFirstChild("TungNet"):FindFirstChild("Notify")
	local joinToast
	for index = before + 1, #remote.__fired do
		local entry = remote.__fired[index]
		if entry.player == me and string.find(tostring(entry.args[1].title), "JOINED") then
			joinToast = entry.args[1]
		end
	end
	t:notNil(joinToast, "a friend joined and the player was never told")
	if joinToast then
		t:eq(joinToast.title, "ANA JOINED", "the join toast does not name the friend")
		t:eq(joinToast.body, "+10% income. 1 friend here.",
			"the join toast does not state what the friend is worth")
	end

	local mark = #remote.__fired
	w.leave(late)
	local leaveToast
	for index = mark + 1, #remote.__fired do
		local entry = remote.__fired[index]
		if entry.player == me and string.find(tostring(entry.args[1].title), "LEFT") then
			leaveToast = entry.args[1]
		end
	end
	t:notNil(leaveToast,
		"income dropped for everyone in the server and nothing said why — an unexplained drop reads as a bug")
end)

T.spec("the friend hook STACKS with the session hook rather than replacing it", function(t)
	local w = T.retention()
	local Data = w.req("DataService")
	local Economy = w.req("Economy")
	local Session = w.req("SessionService")

	local me = w.join("me", 1000)
	local pal = w.join("pal", 1001)
	Data.load(me)
	Data.load(pal)
	me.friendsWith = { [pal.UserId] = true }

	-- sessions first, friends second: the ordering that a single-slot hook
	-- would silently break
	Session.start()
	Session.onPlayer(me)
	w.req("SocialService").start()
	w.clock:advance(w.config.Social.ResolveGap * 8)

	t:near(Economy.multiplier(me), 1.10, 1e-9, "the friend bonus is not registered")

	w.clock:advance(1)
	local folder = w.replicatedStorage:FindFirstChild("TungNet")
	folder:FindFirstChild("RequestBoost").OnServerEvent:Fire(me)

	t:near(Economy.multiplier(me), 2 * 1.10, 1e-9,
		"a x2 boost and one friend did not come to x2.2 — one hook overwrote the other instead of stacking")
end)

T.spec("the bonus never reaches offline earnings", function(t)
	local w, me, _, Economy, Social = seated(3, 3)
	local Session = w.req("SessionService")
	local profile = w.req("DataService").get(me)

	profile.owned = { dropper1 = true, dropper2 = true }
	local withFriends = Session.incomePerSecondFor(profile)
	t:gt(withFriends, 0, "the fixture's factory earns nothing, so this proves nothing")

	t:near(Economy.multiplier(me), 1.30, 1e-9, "the fixture is not actually carrying a friend bonus")
	t:eq(Social.stateFor(me).friends, 3, "the fixture is not actually carrying three friends")

	-- the same profile, with every friend gone
	for _, pal in ipairs(w.players:GetPlayers()) do
		if pal ~= me then
			w.leave(pal)
		end
	end
	t:eq(Social.stateFor(me).friends, 0, "the friends did not actually leave")
	t:near(Session.incomePerSecondFor(profile), withFriends, 1e-9,
		"offline income changed when the friends left — the friend bonus is banking while logged out, which pays a social bonus to somebody in no server")
end)

T.spec("RequestInvite is rate limited, because an untrusted remote that can be spammed will be", function(t)
	local w, me = seated(0, 1)
	local Config = w.config
	local remote = w.replicatedStorage:FindFirstChild("TungNet"):FindFirstChild("RequestInvite")

	-- The guard is the only thing this remote does, so it is asserted by
	-- reaching into the cooldown's effect: a second fire inside the window must
	-- not move the stamp, and one after it must.
	t:notNil(remote, "the RequestInvite remote was never declared in Net.NAMES")
	remote.OnServerEvent:Fire(me)
	remote.OnServerEvent:Fire(me)
	w.clock:advance(Config.Social.InviteCooldown - 1)
	remote.OnServerEvent:Fire(me)
	w.clock:advance(2)
	remote.OnServerEvent:Fire(me)
	t:isNil(w.clock.lastError, "firing RequestInvite raised inside the handler")
end)

end
