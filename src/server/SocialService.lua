--[[
	SocialService.lua — who in this server is your friend, and what that is worth.

	GROWTH-TODO item 4: "Nobody has any reason to bring a friend, and Roblox is
	counting." One of the six things the platform scores this place on is
	INTENTIONAL CO-PLAY DAYS — days a person played with a friend through a join,
	an invite or a private server rather than through matchmaking. The repo had
	no social surface whatsoever, so that number was structurally zero.

	This file is the cheap half of the fix: a friend in your server pays +10%
	income each, capped at +30%, with the number on the HUD so another person has
	a visible price tag. The invite button beside it is the other half, and it is
	client-side (SocialService:PromptGameInvite must be called on the client).

	FRIEND DETECTION IS PAIRWISE AND CACHED.

	`Player:IsFriendsWith(userId)` answers one question about one other person.
	Config.World.MaxPlots is 10 and MaxPlayers is set to match, so the whole
	server is at most 45 unordered pairs and one join costs at most 9 calls. Each
	pair is resolved once and cached for the server's lifetime.

	`Players:GetFriendsAsync(userId)` was the obvious alternative and is REJECTED
	here. It returns a paginated FriendPages of unbounded length — a player with
	400 friends is many pages of web calls and many chances to fail — to answer a
	question about at most nine specific user ids we already hold. It becomes the
	right call somewhere north of 30 concurrent players, where the pair count
	stops being small. At ten it is strictly more work and strictly more failure
	surface.

	A FAILED CALL IS NEVER CACHED AS `false`. It is retried. Writing `false` into
	the cache on a web failure would silently delete the bonus for that pair for
	the rest of the session, which is the worst outcome available here: no error,
	no warning anyone reads, and a number on screen that is simply wrong.

	KNOWN LIMITATION: a friendship formed DURING a session is not picked up. The
	cache is keyed on the pair and written once, so two people who add each other
	mid-session keep their old answer until one of them rejoins. Re-polling every
	unfriended pair on a timer would cost a web call per pair per interval to
	catch an event that happens approximately never, and the failure it prevents
	is "you got the bonus one session late".
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local Economy = Req("Economy")

local Players = game:GetService("Players")

local SocialService = {}

local S = Config.Social

local socialState = Net.event("SocialState")
local requestInvite = Net.event("RequestInvite")

-- ─────────────────────────────────────────────────────────────────────────────
-- state (per server, never persisted)
-- ─────────────────────────────────────────────────────────────────────────────

--- pair key -> true | false. `nil` means UNKNOWN, which is not the same as
--- `false` and is the single most important distinction in this file.
local friendship: { [string]: boolean } = {}

--- The hook below runs on EVERY Economy.add. This is what it reads.
local count: { [Player]: number } = {}

--- Friend display names, for the toast and the HUD. Kept beside `count` rather
--- than derived in the hook, because the hook must not iterate anything.
local names: { [Player]: { string } } = {}

local lastInvite: { [Player]: number } = {}

--- Set for the duration of PlayerRemoving. Roblox still lists a leaving player
--- in Players:GetPlayers() while that signal runs, so a recount taken from
--- inside the handler would count the person who is walking out of the door.
local leaving: { [Player]: boolean } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- the pair cache
-- ─────────────────────────────────────────────────────────────────────────────

--- Friendship is symmetric, so it is stored once. Sorting the two ids means
--- key(a, b) == key(b, a) and the cache cannot hold two disagreeing answers
--- about the same two people.
local function key(a: number, b: number): string
	if a > b then
		a, b = b, a
	end
	return a .. ":" .. b
end

--- The resolve queue. ONE call in flight at a time, ResolveGap apart, because
--- ten simultaneous joins would otherwise fire 45 web calls inside one frame
--- and meet the per-player throttle. tools/verify_config.lua asserts that the
--- fan-out for a single joiner still completes before that joiner's first raid.
local queue: { { a: Player, b: Player, key: string } } = {}
local queued: { [string]: boolean } = {}
local pumping = false
local pump

local function enqueue(a: Player, b: Player)
	local k = key(a.UserId, b.UserId)
	if friendship[k] ~= nil or queued[k] then
		return                       -- already known, or already on its way
	end
	queued[k] = true
	table.insert(queue, { a = a, b = b, key = k })
	if not pumping then
		pumping = true
		task.spawn(pump)
	end
end

function pump()
	while #queue > 0 do
		-- THE GAP COMES FIRST. Nothing goes out to the web on the same frame as
		-- the join that asked for it — ten people arriving together would
		-- otherwise fire their first nine calls into one tick — and it keeps the
		-- whole feature off the join path, where a yield is a stall.
		task.wait(S.ResolveGap)

		local job = table.remove(queue, 1)
		queued[job.key] = nil
		local a, b = job.a, job.b

		if a.Parent and b.Parent and friendship[job.key] == nil then
			local ok, result = pcall(a.IsFriendsWith, a, b.UserId)
			if ok then
				friendship[job.key] = result == true
				SocialService.recountAll()
			else
				-- NOT cached. Not as false, not as anything. Retried.
				warn(("[Tung] IsFriendsWith(%s, %s) failed: %s — retrying in %ds")
					:format(a.Name, b.Name, tostring(result), S.RetrySeconds))
				task.delay(S.RetrySeconds, function()
					if a.Parent and b.Parent then
						enqueue(a, b)
					end
				end)
			end
		end
	end
	pumping = false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- counting
-- ─────────────────────────────────────────────────────────────────────────────

local function present(player: Player): boolean
	return player.Parent ~= nil and not leaving[player]
end

local function friendsPresentFor(player: Player): { string }
	local found = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and present(other) and friendship[key(player.UserId, other.UserId)] then
			table.insert(found, other.DisplayName or other.Name)
		end
	end
	table.sort(found)
	return found
end

--- The entire replicated payload for one player. Public for the same reason
--- SessionService.stateFor is: it is the answer to "what does the server think
--- my friend count is", which is the only useful thing to print when the number
--- on the HUD is argued with.
function SocialService.stateFor(player: Player)
	return {
		friends = count[player] or 0,
		cap = S.MaxFriends,
		bonus = S.BonusPerFriend,
		multiplier = SocialService.incomeMultiplier(player),
		names = names[player] or {},
	}
end

local function pushState(player: Player)
	socialState:FireClient(player, SocialService.stateFor(player))
end

--- A friend arriving or leaving changes YOUR income at that instant, and an
--- unexplained income change reads as a bug. Both directions get a toast, and
--- both reuse the Notify remote the HUD already listens on — zero new client
--- code, landing at the exact moment the bonus becomes legible.
local function announce(player: Player, name: string, joined: boolean, total: number)
	local percent = math.floor(math.min(total, S.MaxFriends) * S.BonusPerFriend * 100)
	local body
	if total <= 0 then
		body = "No friend bonus any more. Invite someone."
	else
		body = ("+%d%% income. %d friend%s here."):format(percent, total, total == 1 and "" or "s")
	end
	Economy.notify(player, {
		kind = joined and "claim" or "warn",
		title = ("%s %s"):format(name:upper(), joined and "JOINED" or "LEFT"),
		body = body,
	})
end

--- Recount EVERYONE, not just the player who moved.
---
--- Friendship is a pair, so one join changes the count of every friend already
--- in the server as well as the count of the joiner. Recounting only the joiner
--- is the obvious bug and it fails silently: their HUD is right, everyone
--- else's is stale, and nobody can tell which one is lying.
function SocialService.recountAll()
	for _, player in ipairs(Players:GetPlayers()) do
		if present(player) then
			local before = names[player] or {}
			local after = friendsPresentFor(player)

			local was = {}
			for _, name in ipairs(before) do
				was[name] = true
			end
			local is = {}
			for _, name in ipairs(after) do
				is[name] = true
			end

			names[player] = after
			count[player] = #after

			local changed = #before ~= #after
			for _, name in ipairs(after) do
				if not was[name] then
					changed = true
					announce(player, name, true, #after)
				end
			end
			for _, name in ipairs(before) do
				if not is[name] then
					changed = true
					announce(player, name, false, #after)
				end
			end

			if changed then
				pushState(player)
				-- the multiplier readout in the cash panel moved too
				Economy.push(player)
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the multiplier
-- ─────────────────────────────────────────────────────────────────────────────

--- What the friend layer multiplies income by. Registered onto Economy under
--- its own key at start(), so it STACKS with the session hook rather than
--- overwriting it.
---
--- THIS RUNS ON EVERY Economy.add — up to ~10 times a second per plot at
--- endgame, times ten plots. It is one table read and two arithmetic ops, and
--- it must stay that way. Never a web call, never an iteration over
--- Players:GetPlayers(); that is what `count` is maintained for.
---
--- IT DOES NOT BANK WHILE LOGGED OUT, and that is a decision rather than an
--- oversight. `SessionService.incomePerSecondFor` derives offline income from
--- the persisted plot and deliberately never calls `Economy.multiplier` — which
--- is what excludes the boost and the weekend bonus too (see the comment at
--- SessionService.lua:122-125). The same reasoning applies with more force
--- here: a bonus for being in a server WITH your friends must not pay out while
--- you are in no server at all. The spec pins it.
function SocialService.incomeMultiplier(player: Player): number
	return 1 + math.min(count[player] or 0, S.MaxFriends) * S.BonusPerFriend
end

-- ─────────────────────────────────────────────────────────────────────────────
-- lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function SocialService.onPlayer(player: Player)
	count[player] = count[player] or 0
	names[player] = names[player] or {}

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and present(other) then
			enqueue(player, other)
		end
	end

	-- Push immediately with what is known so far — usually zero — rather than
	-- waiting on the web. The zero state is the one the invite button lives on,
	-- and it is the state this whole feature exists to interrupt.
	SocialService.recountAll()
	pushState(player)
end

local function onPlayerRemoving(player: Player)
	leaving[player] = true
	count[player] = nil
	names[player] = nil
	lastInvite[player] = nil
	-- The pair cache is NOT dropped. It is keyed on user ids and valid for the
	-- server's lifetime, so a player who rejoins costs no web calls at all.
	SocialService.recountAll()
	leaving[player] = nil
end

function SocialService.start()
	-- THE KILL SWITCH. There is no Config.Prototypes flag for this feature (the
	-- verifier asserts every remaining flag ships false, and the precedent is
	-- that a flag is a thing you delete); zeroing the bonus is what turns it
	-- off, and it does so by never registering the hook rather than by
	-- registering one that returns 1 ten times a second.
	if S.BonusPerFriend <= 0 then
		return
	end

	-- Keyed, so it stacks with SessionService's "sessions" hook instead of
	-- silently replacing it.
	Economy.setMultiplierHook("friends", SocialService.incomeMultiplier)

	Players.PlayerAdded:Connect(SocialService.onPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- The client owns the prompt (PromptGameInvite is a client call), so this
	-- remote carries nothing and is trusted with nothing. It exists so the
	-- server has a per-player floor on how often it can be fired — the same
	-- shape as SessionService's CLAIM_COOLDOWN guard — and somewhere to hang
	-- an invite analytics event when item 8 lands.
	requestInvite.OnServerEvent:Connect(function(player)
		local now = os.clock()
		local last = lastInvite[player]
		if last and now - last < S.InviteCooldown then
			return
		end
		lastInvite[player] = now
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		SocialService.onPlayer(player)
	end
end

return SocialService
