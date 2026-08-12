--[[
	Analytics.lua — the seven events the game sends, and the one choke point
	they all go through.

	WHY THIS FILE IS IN src/server AND NOT src/shared. The Roblox AnalyticsService
	API is server-only and published-place-only. It does not error on the client;
	it does nothing. A module in TungShared is reachable from a LocalScript, and
	the first person to call it from one gets a function that returns
	successfully and sends nothing, forever, with no symptom but a chart that is
	quietly low. Putting it here makes that call a require failure instead.

	EVERYTHING ABOUT THIS API FAILS SILENTLY. Not one of the limits below raises,
	warns or logs:

	  * three custom fields per event, keyed ONLY by
	    Enum.AnalyticsCustomFieldKeys.CustomField01/02/03 (`.Name` is the
	    dictionary key). A fourth entry, or a key of any other name, is dropped.
	  * field values must be STRINGS. A number is dropped.
	  * 8,000 unique combinations of field values across the whole EXPERIENCE.
	  * 100 custom event names across the whole experience.

	That is the entire reason the schema lives in Config.Analytics and is
	verifier-checked rather than being written inline at each call site. A call
	site can be wrong; a call site that is wrong here produces no error and no
	missing data, just data that is subtly not what it says it is.

	ONE CHOKE POINT. Every event goes through Analytics.emit, which resolves the
	three field keys from the schema, tostring()s every value, snaps anything
	outside a declared value set back into it, appends to the tail, spends a
	rate-limit token and only then calls the sink. There is deliberately no
	second path.

	NEVER LOG AN ECONOMY EVENT PER COLLECTED DROP. Late game the vault eats
	roughly ten drops a second — Tycoon.lua says so in as many words next to the
	confetti throttle — which is 600 service calls a minute from ONE player on a
	ten-player server. Economy events fire on button purchases, on rebirth and on
	claims. Nothing that happens on a Touched handler is ever an economy event.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local DataService = Req("DataService")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Analytics = {}

local A = Config.Analytics

--- The three keys Roblox will read, resolved once. `.Name` is the string the
--- dictionary is keyed by; passing the EnumItem itself is one of the ways to
--- get an event accepted with no fields on it.
local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- pure helpers — no Roblox types, so the harness can drive them directly
-- ─────────────────────────────────────────────────────────────────────────────

--- Which bucket `value` falls in, as one of the field's declared strings.
---
--- `bounds` is inclusive-upper and ascending: the first bound the number does
--- not exceed wins, and anything past the last bound gets the final label. A
--- non-number lands in the first bucket rather than erroring, because an event
--- that throws at a call site is a gameplay bug caused by telemetry, which is
--- the one thing telemetry is never allowed to be.
function Analytics.bucket(value: number?, field): string
	if type(field) ~= "table" or type(field.values) ~= "table" then
		return "unknown"
	end
	local n = tonumber(value) or 0
	for index, bound in ipairs(field.bounds or {}) do
		if n <= bound then
			return field.values[index]
		end
	end
	return field.values[#field.values]
end

--- Device class from the client's input flags. Re-exported from Util because
--- the ladder has to run on the client (Roblox has no server-side device API)
--- and this module must not be reachable from one — see Util.platformFrom for
--- the argument and for why VR and console are asked before touch.
Analytics.platformFrom = Util.platformFrom

--- How the player got here. Entirely server-side and therefore trustworthy,
--- which is what makes it worth more than the platform label: no remote, nothing
--- the client can assert about itself.
---
--- Order matters. A followed join into a private server is a FOLLOW — the friend
--- is why they came, the server is only where the friend was — and the follow is
--- the co-play signal Roblox actually scores.
function Analytics.entryPointFrom(followUserId: number?, joinData, privateServerId: string?): string
	if (tonumber(followUserId) or 0) ~= 0 then
		return "follow_friend"
	end
	if type(joinData) == "table" then
		if (tonumber(joinData.ReferredByPlayerId) or 0) ~= 0 then
			return "referral"
		end
		if (tonumber(joinData.SourcePlaceId) or 0) ~= 0 then
			return "teleport"
		end
	end
	if type(privateServerId) == "string" and privateServerId ~= "" then
		return "private_server"
	end
	return "direct"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- schema, resolved once at require time
-- ─────────────────────────────────────────────────────────────────────────────

local EVENTS: { [string]: any } = {}
for _, event in ipairs(A.Events) do
	EVENTS[event.name] = event
end

--- Membership sets for every field, plus the value an undeclared string is
--- snapped to. Snapping rather than passing it through is the point: an
--- undeclared value does not fail, it quietly spends one of the experience's
--- 8,000 combinations and keeps spending more of them every time it appears.
local MEMBERS: { [string]: any } = {}
for name, field in pairs(A.Fields) do
	local index = {}
	for _, value in ipairs(field.values) do
		index[value] = true
	end
	MEMBERS[name] = {
		index = index,
		fallback = index["unknown"] and "unknown" or field.values[1],
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the sink and the rate limit
-- ─────────────────────────────────────────────────────────────────────────────

--- ON in a published server, OFF anywhere the API would no-op. Read at emit
--- time, and note what it does NOT gate: emit still resolves the schema, builds
--- the field table and fills the tail when this is false. Field construction is
--- where every bug in this file will live, so the harness has to be able to
--- exercise it, and only the terminal service call is skipped.
Analytics.enabled = A.Enabled and RunService:IsServer() and not RunService:IsStudio()

--- The last TailSize events, oldest first. The only way to answer "what did the
--- server actually send" without waiting a day for a dashboard.
Analytics.tail = {}

--- Events dropped by the rate limit, since boot. Counted rather than assumed
--- away, because the limit this is designed against is unverified — see
--- Config.Analytics.RateBurst.
Analytics.dropped = 0

--- Values that were not in their declared set and got snapped. Non-zero means
--- the schema and a call site disagree.
Analytics.coerced = 0

local analyticsService = nil
do
	-- GetService itself can fail on a place where the service is unavailable.
	-- An analytics module that stops the server booting is worse than no
	-- analytics.
	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	analyticsService = ok and service or nil
end

local function defaultSink(record)
	if not analyticsService then
		return
	end
	if record.kind == "economy" then
		analyticsService:LogEconomyEvent(
			record.player, record.flow, record.currency, record.amount,
			record.balance, record.transaction, record.sku, record.fields)
	else
		analyticsService:LogCustomEvent(record.player, record.name, record.value, record.fields)
	end
end

local sink = defaultSink

--- Swap the terminal call. The harness captures events with this; nothing in
--- src/ calls it.
function Analytics.setSink(fn)
	sink = fn or defaultSink
end

-- TOKEN BUCKET. The rate limit it is sized against is NOT in the reference
-- documentation — a staff forum post gives roughly 120 + 20 x CCU service calls
-- per minute, and that figure is unverified. It is modelled here anyway, because
-- the failure mode of exceeding an unknown limit is silent loss, and a bucket
-- that is too generous costs nothing while a bucket that is too tight only
-- delays a chart.
--
-- Capacity scales with the player count for the same reason the quoted figure
-- does: a fuller server legitimately produces more events.
local tokens = A.RateBurst
local lastRefill = os.clock()

local function capacity(): number
	return A.RateBurst + A.RatePerPlayerPerMinute * #Players:GetPlayers()
end

local function spendToken(): boolean
	local now = os.clock()
	local size = capacity()
	tokens = math.min(size, tokens + (now - lastRefill) * (size / 60))
	lastRefill = now
	if tokens < 1 then
		return false
	end
	tokens -= 1
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- emit
-- ─────────────────────────────────────────────────────────────────────────────

local function remember(record)
	table.insert(Analytics.tail, record)
	while #Analytics.tail > A.TailSize do
		table.remove(Analytics.tail, 1)
	end
end

local function coerce(fieldName: string, raw): string
	local members = MEMBERS[fieldName]
	if not members then
		return tostring(raw)
	end
	local text = tostring(raw)
	if members.index[text] then
		return text
	end
	Analytics.coerced += 1
	warn(("[Tung] analytics field %s got %q, which is not in its declared set — snapped to %q so it cannot spend a new combination")
		:format(fieldName, text, tostring(members.fallback)))
	return members.fallback
end

--- Send one custom event. `fields` is keyed by the SCHEMA's field names, not by
--- CustomField01: the mapping to the three keys is this function's job and
--- exists in one place.
---
--- Returns the record it built, whether or not it was sent, so a caller (and the
--- harness) can see what the field resolution produced.
function Analytics.emit(name: string, player: Player?, value: number?, fields)
	local event = EVENTS[name]
	if not event then
		warn(("[Tung] analytics event %q is not in Config.Analytics.Events — it would log under a name nothing reads"):format(tostring(name)))
		return nil
	end

	local packed = {}
	for index, fieldName in ipairs(event.fields) do
		packed[FIELD_KEYS[index]] = coerce(fieldName, (fields or {})[fieldName])
	end

	local record = {
		kind = "custom",
		name = name,
		player = player,
		-- Roblox takes `value` as a number and aggregates it. Everything
		-- continuous lives here precisely because it costs no combinations.
		value = tonumber(value) or 0,
		fields = packed,
	}
	remember(record)

	if not Analytics.enabled then
		return record
	end
	if not spendToken() then
		Analytics.dropped += 1
		return record
	end
	-- pcall, always: a throttled or unavailable service must not take a
	-- purchase, a rebirth or a logout down with it.
	local ok, err = pcall(sink, record)
	if not ok then
		warn("[Tung] analytics sink failed: " .. tostring(err))
	end
	return record
end

--- Send one economy event. SEPARATE from emit because it is a different API
--- with different limits (5 currency types, 20 transaction types, 100 SKUs per
--- experience) and because its amounts are real numbers rather than strings.
---
--- `sku` is a button id, so the SKU budget is #Config.Buttons plus the handful
--- of non-button skus below — which the verifier prices, because a fifth track
--- is what actually reaches 100.
function Analytics.economy(player: Player?, flow: string, amount: number, balance: number,
		transaction: string, sku: string)
	local record = {
		kind = "economy",
		player = player,
		flow = flow,
		currency = A.Currency,
		amount = math.floor(tonumber(amount) or 0),
		balance = math.floor(tonumber(balance) or 0),
		transaction = transaction,
		sku = sku,
	}
	remember(record)

	if not Analytics.enabled then
		return record
	end
	if not spendToken() then
		Analytics.dropped += 1
		return record
	end
	local ok, err = pcall(sink, record)
	if not ok then
		warn("[Tung] analytics economy sink failed: " .. tostring(err))
	end
	return record
end

-- ─────────────────────────────────────────────────────────────────────────────
-- per-session state
--
-- ITS OWN TABLE, READ FROM NOTHING ELSE AT REMOVAL. DataService.start connects
-- PlayerRemoving -> save(player, true) -> profiles[userId] = nil, and Roblox
-- does not order signal handlers. By the time this file's PlayerRemoving runs
-- the profile may already be gone, so `session_end` reads only from here. Same
-- shape as SessionService's `live`, for the same reason.
-- ─────────────────────────────────────────────────────────────────────────────

type Live = {
	player: Player,
	joinAt: number,          -- os.time(), for wall-clock session length
	platform: string,
	entry: string,
	helloSeen: boolean,
	started: boolean,
	lastSeen: number,        -- captured BEFORE anything re-stamps it
	sessionIndex: number,
	lastMilestone: string,
	rebirths: number,
}

local live: { [Player]: Live } = {}

--- The furthest button this profile owns, by install order. "none" is a real
--- answer and the most important one on this event.
local function milestoneOf(profile): string
	local best, bestOrder = "none", -1
	for id, owned in pairs((profile and profile.owned) or {}) do
		local def = owned and Config.ButtonById[id]
		if def and def.order > bestOrder then
			best, bestOrder = id, def.order
		end
	end
	return best
end

local function friendsInServer(player: Player): number
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWith(other.UserId)
			end)
			if ok and isFriend then
				count += 1
			end
		end
	end
	return count
end

--- The three join events, fired together once the platform is known.
---
--- TOGETHER IS THE POINT. There is no edit path on a logged event: firing
--- session_start early with platform "unknown" and correcting it later is not
--- something this API can express, so the join waits instead.
local function fireSessionStart(player: Player, entry: Live)
	if entry.started then
		return
	end
	entry.started = true
	local F = A.Fields

	Analytics.emit("session_start", player, entry.sessionIndex, {
		platform = entry.platform,
		entry = entry.entry,
		sessionIndex = Analytics.bucket(entry.sessionIndex, F.sessionIndex),
	})

	-- RETURNED, and this is the event the whole ordering dance exists for. A
	-- lastSeen of 0 is a profile that has never logged out — a first session, or
	-- a save from before the field existed — and "came back after 1970" is worse
	-- than no row at all.
	if entry.lastSeen > 0 then
		local away = math.max(0, entry.joinAt - entry.lastSeen)
		Analytics.emit("returned", player, away / 3600, {
			platform = entry.platform,
			awayBucket = Analytics.bucket(away, F.awayBucket),
			sessionIndex = Analytics.bucket(entry.sessionIndex, F.sessionIndex),
		})
	end

	-- Only when there IS a friend here. friendCount has no "0" value, and adding
	-- one would buy a fifth facet for a number session_start already implies:
	-- friends_in_server over session_start IS the co-play rate.
	local friends = friendsInServer(player)
	if friends > 0 then
		local privateId = tostring(game.PrivateServerId or "")
		Analytics.emit("friends_in_server", player, friends, {
			platform = entry.platform,
			friendCount = Analytics.bucket(friends, F.friendCount),
			serverKind = privateId ~= "" and "private" or "public",
		})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- public entry points
-- ─────────────────────────────────────────────────────────────────────────────

--- MUST RUN BETWEEN DataService.load AND SessionService.onPlayer.
---
--- SessionService.onPlayer stamps `profile.lastSeen = os.time()` as its second
--- act, and SessionService.step re-stamps it every second after that. Whatever
--- the previous logout wrote is gone the moment either of those runs, and the
--- whole value of `returned` — the only measurement of whether anybody comes
--- back — is that one number. So it is captured here, into this file's own
--- table, before anything else can touch it. Main.server.lua's ordering is
--- load-bearing and says so.
function Analytics.onPlayer(player: Player)
	local profile = DataService.get(player)
	local now = os.time()

	-- Read FIRST, before the counters below touch the profile at all.
	local lastSeen = math.max(0, math.floor(tonumber(profile and profile.lastSeen) or 0))

	local sessionIndex = 1
	if profile then
		if (tonumber(profile.firstJoin) or 0) <= 0 then
			profile.firstJoin = now
		end
		profile.totalSessions = math.max(0, math.floor(tonumber(profile.totalSessions) or 0)) + 1
		sessionIndex = profile.totalSessions
	end

	local joinData
	do
		local ok, data = pcall(function()
			return player:GetJoinData()
		end)
		joinData = ok and data or nil
	end

	local entry: Live = {
		player = player,
		joinAt = now,
		platform = "unknown",
		entry = Analytics.entryPointFrom(player.FollowUserId, joinData, tostring(game.PrivateServerId or "")),
		helloSeen = false,
		started = false,
		lastSeen = lastSeen,
		sessionIndex = sessionIndex,
		lastMilestone = milestoneOf(profile),
		rebirths = math.max(0, math.floor(tonumber(profile and profile.rebirths) or 0)),
	}
	live[player] = entry

	-- The platform arrives from the client, some time after the join. Wait for
	-- it, then fire the three join events; give up at HelloTimeoutSeconds and
	-- log "unknown", which is an honest answer and a countable one.
	task.spawn(function()
		local deadline = os.clock() + A.HelloTimeoutSeconds
		while not entry.helloSeen and os.clock() < deadline do
			task.wait(0.25)
		end
		if live[player] then
			fireSessionStart(player, entry)
		end
	end)
end

--- A purchase landed. Called from Tycoon:tryPurchase, which is the only place a
--- button is ever bought with money.
function Analytics.onPurchase(player: Player, def, balance: number)
	local entry = live[player]
	if entry then
		-- Furthest by install order, not most recent: the four tracks are bought
		-- interleaved, so "the last thing they clicked" is not "how far they got".
		local standing = Config.ButtonById[entry.lastMilestone]
		if def.order > (standing and standing.order or -1) then
			entry.lastMilestone = def.id
		end
	end

	Analytics.economy(player, "Sink", def.price, balance, "Shop", def.id)

	-- FIRST BUTTON, ONCE PER ACCOUNT, NOT ONCE PER SESSION. The number is
	-- persisted, so a returning player's first purchase of the evening is not
	-- onboarding and does not pretend to be. 0 means never.
	local profile = DataService.get(player)
	if not profile or (tonumber(profile.firstBuySeconds) or 0) > 0 then
		return
	end
	local seconds = entry and math.max(1, os.time() - entry.joinAt) or 1
	profile.firstBuySeconds = seconds

	-- Only factory buttons are in the buttonId set; the side tracks are gated
	-- forty minutes in and cannot be a first purchase. coerce() would snap one
	-- into the set rather than widen it, and warn — which is the right failure,
	-- but it should never happen.
	Analytics.emit("first_button_purchased", player, seconds, {
		platform = entry and entry.platform or "unknown",
		buttonId = def.id,
		secondsBucket = Analytics.bucket(seconds, A.Fields.secondsBucket),
	})
end

--- A rebirth landed. Called from Tycoon:rebirth, after the profile is updated.
function Analytics.onRebirth(player: Player, rebirths: number, cost: number, balance: number)
	local entry = live[player]
	local minutes = entry and (os.time() - entry.joinAt) / 60 or 0
	if entry then
		entry.rebirths = rebirths
		-- A rebirth wipes the factory, so the milestone it was standing on is
		-- gone with it. Anything else would report the logout of a rebirthed
		-- player at a rung they no longer own.
		entry.lastMilestone = milestoneOf(DataService.get(player))
	end

	Analytics.emit("rebirth", player, rebirths, {
		platform = entry and entry.platform or "unknown",
		minutesBucket = Analytics.bucket(minutes, A.Fields.minutesBucket),
		rebirthBand = Analytics.bucket(rebirths, A.Fields.rebirthBand),
	})
	Analytics.economy(player, "Sink", cost, balance, "Gameplay", "rebirth")
end

--- An offline payout was claimed. Called from SessionService.claimOffline with
--- the pending grant it just paid.
function Analytics.onOfflineClaim(player: Player, pending, balance: number)
	local entry = live[player]
	Analytics.emit("offline_claim", player, pending.earned, {
		platform = entry and entry.platform or "unknown",
		clipped = pending.clipped and "clipped" or "within_cap",
		awayBucket = Analytics.bucket(pending.seconds, A.Fields.awayBucket),
	})
	Analytics.economy(player, "Source", pending.earned, balance, "TimedReward", "offline_claim")
end

--- The logout event. Reads `live` and nothing else — see the block comment above
--- `live` for why touching DataService here would work in testing and fail in
--- production about half the time.
function Analytics.onRemoving(player: Player)
	local entry = live[player]
	live[player] = nil
	if not entry then
		return
	end

	-- A SESSION SHORTER THAN THE HELLO TIMEOUT STILL STARTED. Without this,
	-- anyone who leaves inside ten seconds produces a session_end and no
	-- session_start — and session_start is the DENOMINATOR that `returned` and
	-- `friends_in_server` are read against, so the shortest sessions in the game
	-- would quietly drop out of every rate we compute. They are also the exact
	-- sessions worth looking at.
	if not entry.started then
		fireSessionStart(player, entry)
	end

	-- The logout itself still has a length and still stopped somewhere, which
	-- are the two things this event is for. It fires with platform "unknown"
	-- rather than not firing.
	Analytics.emit("session_end", player, math.max(0, os.time() - entry.joinAt), {
		platform = entry.platform,
		milestone = entry.lastMilestone,
		rebirthBand = Analytics.bucket(entry.rebirths, A.Fields.rebirthBand),
	})
end

--- What this session looks like to the analytics layer. Exposed because "the
--- chart disagrees with the game" is otherwise unanswerable from a live server.
function Analytics.stateFor(player: Player)
	return live[player]
end

function Analytics.start()
	local clientHello = Net.event("ClientHello")

	clientHello.OnServerEvent:Connect(function(player, payload)
		local entry = live[player]
		if not entry or entry.helloSeen then
			return              -- once per player per session; a remote that can be spammed will be
		end
		entry.helloSeen = true

		-- A CLIENT CAN LIE, so this is validated against the declared set and
		-- otherwise thrown away. It must also never gate anything: `platform` is
		-- a label on a chart and touches no gameplay path anywhere in src/.
		local claimed = type(payload) == "table" and payload.platform or nil
		entry.platform = (type(claimed) == "string" and MEMBERS.platform.index[claimed]) and claimed or "unknown"
	end)

	Players.PlayerRemoving:Connect(Analytics.onRemoving)
end

return Analytics
