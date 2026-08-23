--[[
	analytics_spec.lua — the funnel, and the four ways it fails without saying so.

	Every limit the Roblox analytics API has fails SILENTLY. A fourth custom
	field is discarded. A numeric field value is discarded. The 8,000
	combinations of field values an EXPERIENCE gets are simply not counted past
	the limit. None of it errors, warns, or shows up in the output window. The
	only symptom is a chart, weeks later, that is wrong in a way that looks
	exactly like data — which is the worst failure mode a measurement can have,
	because it is indistinguishable from a measurement.

	So the interesting assertions here are not "does it send". They are:

	  * field construction, which is where the bugs live and which runs whether
	    or not analytics is enabled, precisely so it can be driven from here;
	  * the ORDERING contract in Main.server.lua, because `returned` reads a
	    number that SessionService overwrites one line later;
	  * the SURVIVAL contract at logout, because DataService releases the profile
	    from its own PlayerRemoving handler and signal handler order is not a
	    guarantee;
	  * `first_button_purchased` firing once per ACCOUNT, which is one persisted
	    field and therefore one line in DataService.save's payload away from
	    being wrong every session forever.
]]

return function(T)

T.family("analytics", "seven events, three fields each, and every limit fails silently")

local KEYS = { "CustomField01", "CustomField02", "CustomField03" }

--- The module with its terminal call captured. `Analytics.setSink` exists for
--- exactly this; the default sink is exercised on its own, below, so that
--- swapping it here does not hide the one path that reaches the service.
local function analytics(w)
	local A = w.req("Analytics")
	local seen = {}
	A.setSink(function(record)
		table.insert(seen, record)
	end)
	return A, seen
end

local function find(seen, name: string)
	for _, record in ipairs(seen) do
		if record.name == name then
			return record
		end
	end
	return nil
end

local function countOf(seen, name: string): number
	local n = 0
	for _, record in ipairs(seen) do
		if record.name == name then
			n += 1
		end
	end
	return n
end

-- ── the pure helpers ────────────────────────────────────────────────────────

T.spec("bucket() is inclusive-upper, ascending, and its top band is open", function(t)
	local w = T.world()
	local A = w.req("Analytics")
	local away = w.config.Analytics.Fields.awayBucket

	t:eq(A.bucket(0, away), "<10m")
	t:eq(A.bucket(600, away), "<10m", "a bound is the TOP of its own band, not the bottom of the next one")
	t:eq(A.bucket(601, away), "10m-1h")
	t:eq(A.bucket(7200, away), "1-6h")
	t:eq(A.bucket(604800, away), "1-7d")
	t:eq(A.bucket(60480000, away), "7d+", "the last label has to absorb everything above the last bound")

	-- A field with no ladder at all still has to answer with one of its own
	-- values, because emit() will send whatever comes back.
	t:eq(A.bucket(nil, away), "<10m", "a nil must not reach the service as nil")
end)

T.spec("VR and console are classified BEFORE touch", function(t)
	local w = T.world()
	local A = w.req("Analytics")

	-- The whole reason the ladder is written in this order. A headset and a
	-- console can both report TouchEnabled, so a touch test placed first files
	-- every one of them under "mobile" — and the resulting chart looks entirely
	-- normal.
	t:eq(A.platformFrom({ vr = true, touch = true }), "vr")
	t:eq(A.platformFrom({ tenFoot = true, touch = true }), "console")

	t:eq(A.platformFrom({ touch = true, viewportX = 400 }), "mobile")
	t:eq(A.platformFrom({ touch = true, viewportX = 1024 }), "tablet")
	t:eq(A.platformFrom({ touch = true, keyboard = true, mouse = true }), "desktop",
		"a touchscreen laptop is a desktop; the touch test requires that there is no keyboard")
	t:eq(A.platformFrom({ keyboard = true, mouse = true }), "desktop")
	t:eq(A.platformFrom({}), "unknown")

	-- Every answer must be in the declared set, or the server's own label would
	-- be snapped to "unknown" by its own coercion.
	local declared = {}
	for _, value in ipairs(w.config.Analytics.Fields.platform.values) do
		declared[value] = true
	end
	for _, flags in ipairs({
		{ vr = true }, { tenFoot = true }, { touch = true },
		{ touch = true, viewportX = 1400 }, { keyboard = true, mouse = true }, {},
	}) do
		t:isTrue(declared[A.platformFrom(flags)] == true,
			"the ladder can return a platform the schema does not declare")
	end
end)

T.spec("a followed join is a follow even when it lands in a private server", function(t)
	local w = T.world()
	local A = w.req("Analytics")

	-- The friend is why they came; the private server is only where the friend
	-- was. follow_friend is the co-play signal Roblox actually scores, so it
	-- must win.
	t:eq(A.entryPointFrom(4242, nil, "abc-private"), "follow_friend")
	t:eq(A.entryPointFrom(0, { ReferredByPlayerId = 99 }, ""), "referral")
	t:eq(A.entryPointFrom(0, { ReferredByPlayerId = 0, SourcePlaceId = 77 }, ""), "teleport")
	t:eq(A.entryPointFrom(0, nil, "abc-private"), "private_server")
	t:eq(A.entryPointFrom(0, nil, ""), "direct")
	-- GetJoinData is a network call in a pcall. A failed read is not a direct
	-- join, but it is also not knowable — nil must not be treated as a referral.
	t:eq(A.entryPointFrom(nil, nil, nil), "direct")
end)

-- ── field construction ──────────────────────────────────────────────────────

T.spec("an event reaches AnalyticsService with three STRING fields under the three keys it reads", function(t)
	local w = T.world()
	-- deliberately NOT setSink: this is the one spec that drives the real
	-- terminal call, so the default sink cannot rot unnoticed.
	local A = w.req("Analytics")
	local player = w.join("fielded")

	t:isTrue(A.enabled,
		"the mock world is a published server as far as RunService is concerned; if this is false every send below is skipped and the spec proves nothing")

	A.emit("session_start", player, 3, { platform = "mobile", entry = "direct", sessionIndex = "3-5" })

	t:eq(#w.analytics.events, 1)
	local logged = w.analytics.events[1]
	t:eq(logged.name, "session_start")
	t:eq(logged.player, player)
	t:eq(logged.value, 3, "the continuous number belongs in `value`, where it costs no combinations")

	local count = 0
	for key, value in pairs(logged.fields) do
		count += 1
		t:eq(type(value), "string", "Roblox drops a custom field value that is not a string, and logs the event anyway")
		t:isTrue(key == KEYS[1] or key == KEYS[2] or key == KEYS[3],
			("field key %q is not one of the three Roblox reads, so it is discarded in silence"):format(tostring(key)))
	end
	t:eq(count, 3, "exactly three fields; a fourth is dropped without a word")

	-- and the schema's field ORDER is what decides which key each one lands under
	t:eq(logged.fields.CustomField01, "mobile")
	t:eq(logged.fields.CustomField02, "direct")
	t:eq(logged.fields.CustomField03, "3-5")

	-- A NUMBER MUST NOT ARRIVE AS A NUMBER. Roblox discards a numeric field
	-- value and logs the event without it, so the tostring() at the choke point
	-- is what makes every call site safe rather than every call site careful.
	-- sessionIndex is the field that can tell the difference: "2" is in its set,
	-- so a stringified 2 survives and an unstringified one is snapped to "1".
	A.emit("session_start", player, 1, { platform = "desktop", entry = "direct", sessionIndex = 2 })
	local numeric = w.analytics.events[2]
	t:eq(numeric.fields.CustomField03, "2",
		"a numeric field value was not stringified at the choke point, and Roblox would have dropped it")
	t:eq(A.coerced, 0, "a value that is legal once stringified must not be counted as a schema violation")
end)

T.spec("with analytics off, emit still builds its fields and still fills the tail", function(t)
	local w = T.world()
	local A = w.req("Analytics")
	local player = w.join("dark")

	-- Field construction is where every bug in this file will live, and a
	-- shipping build has `enabled` false in Studio and on the client. Only the
	-- terminal call is allowed to be what a disabled build skips.
	A.enabled = false
	local record = A.emit("session_end", player, 120,
		{ platform = "desktop", milestone = "dropper3", rebirthBand = "0" })

	t:eq(#w.analytics.events, 0, "a disabled build must not reach the service")
	t:notNil(record, "a disabled build must still return the record it would have sent")
	t:eq(record.fields.CustomField02, "dropper3")
	t:eq(#A.tail, 1, "the tail is the only way to see what a disabled build would have sent")
end)

T.spec("a value outside its declared set is snapped back into it, not passed through", function(t)
	local w = T.world()
	t.world = w
	local A = w.req("Analytics")
	A.enabled = false

	-- An undeclared value does not fail. It quietly spends one of the
	-- experience's 8,000 combinations, and spends another every time a new one
	-- appears, until the budget is gone and every chart flattens out.
	local record = A.emit("session_start", w.join("liar"), 1,
		{ platform = "nintendo", entry = "direct", sessionIndex = "1" })

	t:eq(record.fields.CustomField01, "unknown",
		"an undeclared value reached the service and bought a combination nobody budgeted for")
	t:eq(A.coerced, 1)
	t:warned("not in its declared set")
end)

T.spec("an unknown event name is refused rather than logged under a name nothing reads", function(t)
	local w = T.world()
	local A = w.req("Analytics")
	t:isNil(A.emit("session_startt", w.join("typo"), 1, {}),
		"a typo'd event name would create a second chart, sitting next to the real one, permanently")
	t:eq(#w.analytics.events, 0)
end)

-- ── the shared budget ───────────────────────────────────────────────────────

T.spec("the schema spends 3,060 of the experience's 8,000 combinations", function(t)
	local w = T.world()
	local AN = w.config.Analytics

	-- Recomputed here rather than calling Config.analyticsCombinations, so that
	-- this is a second opinion about the arithmetic and not a restatement of it.
	-- SUMMED across events, not maxed: the 8,000 is one pool for the whole
	-- experience, and two events with entirely different facets each spend their
	-- own product out of it.
	local total = 0
	for _, event in ipairs(AN.Events) do
		t:isTrue(#event.fields <= AN.MaxFields,
			("%s carries more than the three fields Roblox reads"):format(event.name))
		local product = 1
		for _, field in ipairs(event.fields) do
			product *= #AN.Fields[field].values
		end
		total += product
	end

	t:eq(total, w.config.analyticsCombinations(),
		"the verifier and the schema disagree about what this costs, so one of them is checking the wrong number")
	-- 2,340 before round 8, 2,520, 2,400 when the shell left the spine, and
	-- 2,520 again when land arrived (#88). `buttonId` and `milestone` are
	-- DERIVED from the ladder, so a reshaped ladder moves this number without
	-- anyone editing Analytics.Fields — the derivation working, and exactly
	-- why it is pinned here.
	--
	-- 3,120 with #109's strips, and 3,060 NOW (#162): the shell's `windows`
	-- and `roof` rows left the game, so `milestone` — every button on every
	-- track, plus "none" — went from 65 to 63.
	t:eq(total, 3060,
		"the combination cost moved; it is a shared experience-wide budget, so this is a decision and not an implementation detail")

	-- THE LIMIT THAT WILL BITE FIRST, and it is not the 8,000. `milestone` is
	-- every button plus "none", so it grows by one for every button anyone adds
	-- of any kind, and it is the closest set to MaxFieldValues. When it lands
	-- there the build fails with a message about facets rather than about the
	-- button that caused it.
	t:lte(#AN.Fields.milestone.values, AN.MaxFieldValues,
		"milestone is every button plus `none`; past MaxFieldValues a session that stopped at a missing rung is filed at the wrong one")
	t:gte(AN.MaxCombinations, total)
	t:gte(AN.MaxEventNames, #AN.Events)
	t:gte(AN.MaxEconomySkus, #w.config.Buttons,
		"every button is a SKU, and SKUs past the limit are dropped from every economy event silently")
end)

-- ── the join, and the number SessionService is about to overwrite ───────────

--- Main.server.lua's player sequence, in order, with the profile pre-seeded as
--- though it had logged out `awaySeconds` ago.
local function joinReturningPlayer(w, name: string, awaySeconds: number, sessionFirst: boolean?)
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local A, seen = analytics(w)

	local player = w.join(name)
	local first = Data.load(player)
	first.lastSeen = os.time() - awaySeconds
	Data.save(player, true)

	Data.load(player)
	if sessionFirst then
		Session.onPlayer(player)
		A.onPlayer(player)
	else
		A.onPlayer(player)
		Session.onPlayer(player)
	end
	-- past the client-hello timeout, so the join events resolve
	w.clock:advance(w.config.Analytics.HelloTimeoutSeconds + 1)
	return A, seen, player, Data
end

T.spec("`returned` reads lastSeen BEFORE SessionService stamps over it", function(t)
	local w = T.retention()
	local _A, seen, player, Data = joinReturningPlayer(w, "returner", 7200)

	-- The trap is real, and this is the line that proves it: by now the profile
	-- says the player was last seen moments ago, not two hours ago. Everything
	-- below reads a number that no longer exists anywhere except in Analytics'
	-- own table.
	t:gt(Data.get(player).lastSeen, os.time() - 7200,
		"SessionService no longer stamps lastSeen, so this spec is guarding nothing")

	local record = find(seen, "returned")
	t:notNil(record, "no `returned` event — the one measurement of whether anybody comes back")
	t:near(record.value, 2, 1e-6, "the value is hours away, and it came from the overwritten stamp")
	t:eq(record.fields.CustomField02, "1-6h")
end)

T.spec("running Analytics.onPlayer AFTER SessionService destroys the whole `returned` signal", function(t)
	-- The falsification of the spec above, kept as a spec rather than as a
	-- comment: swap two lines in Main.server.lua and nothing breaks, nothing
	-- warns, and every "how long before they came back" number becomes zero.
	local w = T.retention()
	local _A, seen = joinReturningPlayer(w, "reversed", 7200, true)

	local record = find(seen, "returned")
	t:notNil(record)
	t:near(record.value, 0, 1e-6,
		"two hours away read as zero, because SessionService.onPlayer stamped lastSeen first")
	t:eq(record.fields.CustomField02, "<10m")
end)

T.spec("a profile that has never logged out sends no `returned` at all", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	local player = w.join("fresh")
	Data.load(player)
	A.onPlayer(player)
	w.clock:advance(w.config.Analytics.HelloTimeoutSeconds + 1)

	t:eq(countOf(seen, "session_start"), 1)
	t:eq(countOf(seen, "returned"), 0,
		"lastSeen 0 is a first session, and 'came back after 56 years' is worse than no row at all")
end)

T.spec("the client's platform is accepted once, validated, and does not wait out the timeout", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local Net = w.req("Net")
	local A, seen = analytics(w)
	A.start()

	local player = w.join("phone")
	Data.load(player)
	A.onPlayer(player)

	local hello = Net.event("ClientHello")
	hello.OnServerEvent:Fire(player, { platform = "mobile" })
	t:eq(A.stateFor(player).platform, "mobile")

	-- A second hello must not be able to relabel a session that is already
	-- logged, and a remote that can be spammed will be.
	hello.OnServerEvent:Fire(player, { platform = "vr" })
	t:eq(A.stateFor(player).platform, "mobile")

	-- and the join must fire on the hello rather than sitting out the full
	-- ten-second timeout
	w.clock:advance(0.5)
	local record = find(seen, "session_start")
	t:notNil(record, "session_start waited for the timeout even though the client had already answered")
	t:eq(record.fields.CustomField01, "mobile")
end)

T.spec("a client that claims an undeclared platform is filed as unknown", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local Net = w.req("Net")
	local A = w.req("Analytics")
	A.start()

	local player = w.join("cheat")
	Data.load(player)
	A.onPlayer(player)

	Net.event("ClientHello").OnServerEvent:Fire(player, { platform = "gamecube" })
	t:eq(A.stateFor(player).platform, "unknown",
		"a client can say anything, and an unvalidated label spends combinations for as long as somebody keeps sending new ones")
end)

-- ── onboarding, which is an ACCOUNT-scoped question ─────────────────────────

T.spec("first_button_purchased fires once per ACCOUNT, not once per session", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)
	local Config = w.config

	local player = w.join("onboarder")
	Data.load(player)
	A.onPlayer(player)
	w.clock:advance(20)

	A.onPurchase(player, Config.ButtonById.dropper1, 50)
	t:eq(countOf(seen, "first_button_purchased"), 1)
	local record = find(seen, "first_button_purchased")
	t:eq(record.value, 20, "the value is seconds from join to first purchase")
	t:eq(record.fields.CustomField02, "dropper1")
	t:eq(record.fields.CustomField03, "0-30s")

	-- LOG OUT AND COME BACK. This is the landmine: firstBuySeconds is in
	-- defaultProfile(), and a field that is not ALSO in DataService.save's
	-- hand-listed payload works perfectly all session and is gone at logout.
	A.onRemoving(player)
	t:isTrue(Data.save(player, true))

	local again = Data.load(player)
	t:gt(again.firstBuySeconds, 0,
		"firstBuySeconds did not survive the save — it is missing from DataService.save's payload, so this event would fire fresh for the same account every session forever")
	t:eq(again.totalSessions, 1)

	A.onPlayer(player)
	w.clock:advance(w.config.Analytics.HelloTimeoutSeconds + 1)
	t:eq(Data.get(player).totalSessions, 2)

	A.onPurchase(player, Config.ButtonById.dropper2, 100)
	t:eq(countOf(seen, "first_button_purchased"), 1,
		"a returning player's first purchase of the evening is not onboarding, and counting it as onboarding makes a broken funnel look healthy")
end)

T.spec("a purchase logs exactly one economy event, with the button as its SKU", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	local player = w.join("buyer")
	Data.load(player)
	A.onPlayer(player)
	A.onPurchase(player, w.config.ButtonById.dropper1, 50)

	local economy = {}
	for _, record in ipairs(seen) do
		if record.kind == "economy" then
			table.insert(economy, record)
		end
	end
	t:eq(#economy, 1)
	t:eq(economy[1].sku, "dropper1")
	t:eq(economy[1].transaction, "Shop")
	t:eq(economy[1].currency, w.config.Analytics.Currency)
	t:eq(economy[1].amount, w.config.ButtonById.dropper1.price)
end)

-- ── the two call sites inside Tycoon ────────────────────────────────────────

--- Enough of a plot for the two money paths, and nothing more. Everything that
--- would need a BasePart is stubbed ON THE INSTANCE, which shadows the class
--- method without changing it — the same trick generator_spec uses, and the
--- reason Tycoon can be driven at all without a physics step.
local function fakePlot(w, player)
	local Tycoon = w.req("Tycoon")
	local plot = setmetatable({}, { __index = Tycoon })
	plot.owner = player
	plot.owned = {}
	plot.objects = {}
	plot.generation = 0
	plot.beltBonus, plot.powerFactor = 0, 1
	plot.machines = { ClearAllChildren = function() end }
	plot.install = function(self, id)
		self.owned[id] = true              -- the real one needs a belt to install onto
	end
	plot.refreshBeltSpeed = function() end
	plot.refreshButtons = function() end
	plot.updateSign = function() end
	plot.fireOwnedChanged = function() end
	plot.clearDrops = function() end
	return plot, Tycoon
end

T.spec("Tycoon:tryPurchase is wired to the funnel — the only path where a button costs money", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	local player = w.join("shopper")
	Data.load(player)
	A.onPlayer(player)
	w.clock:advance(12)

	local plot = fakePlot(w, player)
	plot:tryPurchase(player, "dropper1")

	t:isTrue(plot.owned.dropper1, "the purchase itself did not go through, so this proves nothing about analytics")
	t:eq(countOf(seen, "first_button_purchased"), 1,
		"a button was bought and the funnel never heard about it; tryPurchase is the ONE place this can be observed")
	t:eq(find(seen, "first_button_purchased").fields.CustomField02, "dropper1")

	-- and a refused purchase must not log one
	plot:tryPurchase(player, "dropper10")
	t:eq(countOf(seen, "first_button_purchased"), 1,
		"an unaffordable button was counted as a purchase")
end)

T.spec("Tycoon:rebirth is wired to the funnel, and reports the rebirth it just granted", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	local player = w.join("prestige")
	local profile = Data.load(player)
	profile.owned.dropper1 = true
	profile.cash = 60e9                    -- comfortably over Rebirth.BaseCost
	A.onPlayer(player)
	w.clock:advance(12)

	local plot = fakePlot(w, player)
	plot.owned.dropper1 = true

	t:isTrue(plot:rebirth(player), "the rebirth was refused, so this proves nothing about analytics")

	local record = find(seen, "rebirth")
	t:notNil(record, "a rebirth happened and the funnel never heard about it")
	t:eq(record.value, 1)
	t:eq(record.fields.CustomField03, "1")
end)

-- ── the logout, after DataService has already thrown the profile away ───────

T.spec("session_end still has its data after DataService has released the profile", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	-- The REAL removal race, not a simulation of it: DataService.start connects
	-- PlayerRemoving -> save(player, true) -> profiles[userId] = nil, and it
	-- connects FIRST. Roblox does not order signal handlers, so this is one of
	-- the two orders production will actually run.
	Data.start()
	A.start()

	local player = w.join("leaver")
	Data.load(player)
	A.onPlayer(player)
	A.onPurchase(player, w.config.ButtonById.dropper1, 50)
	w.clock:advance(w.config.Analytics.HelloTimeoutSeconds + 1)

	w.leave(player)

	t:isNil(Data.get(player),
		"DataService did not release the profile first, so this spec is not testing the race it claims to")

	local record = find(seen, "session_end")
	t:notNil(record, "no session_end — the length of a session and where it stopped are the two things it exists for")
	t:gte(record.value, 11, "the value is session seconds")
	t:eq(record.fields.CustomField02, "dropper1",
		"the milestone came back empty, which is what reading DataService at removal looks like")
	t:eq(record.fields.CustomField03, "0")
end)

T.spec("a session that ends before the client answers still logs its start", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)
	Data.start()
	A.start()

	local player = w.join("bouncer")
	Data.load(player)
	A.onPlayer(player)
	w.clock:advance(4)                     -- well inside the ten-second hello wait
	w.leave(player)

	-- session_start is the DENOMINATOR every join rate is read against. Losing
	-- it for the shortest sessions in the game loses exactly the sessions worth
	-- looking at, and every rate computed from it reads better than it is.
	t:eq(countOf(seen, "session_start"), 1,
		"a sub-ten-second session logged an end with no start, so it is invisible to every rate computed from starts")
	t:eq(countOf(seen, "session_end"), 1)
	t:eq(find(seen, "session_start").fields.CustomField01, "unknown",
		"the platform is honestly unknown here, and an honest unknown is countable")
end)

T.spec("a session that bought nothing reports `none`, which is the answer that matters", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)
	Data.start()
	A.start()

	local player = w.join("bouncer")
	Data.load(player)
	A.onPlayer(player)
	w.clock:advance(30)
	w.leave(player)

	local record = find(seen, "session_end")
	t:notNil(record)
	t:eq(record.fields.CustomField02, "none",
		"a session that got nowhere is the single most important row on this event")
end)

-- ── the two events that hang off other prototypes ───────────────────────────

T.spec("claiming offline earnings reports whether the cap clipped it", function(t)
	-- Driven through the real RequestClaim remote, so the wiring inside
	-- SessionService.claimOffline is part of what is under test. A call to
	-- Analytics.onOfflineClaim from a spec would prove only that the function
	-- exists.
	local w = T.retention()
	local Data = w.req("DataService")
	local Session = w.req("SessionService")
	local Net = w.req("Net")
	local A, seen = analytics(w)
	Session.start()

	local player = w.join("banker")
	local profile = Data.load(player)
	profile.owned.dropper1 = true
	profile.lastSeen = os.time() - 3 * 3600     -- three hours, inside the 8h cap
	Data.save(player, true)

	Data.load(player)
	A.onPlayer(player)
	Session.onPlayer(player)
	w.clock:advance(w.config.Analytics.HelloTimeoutSeconds + 1)

	Net.event("RequestClaim").OnServerEvent:Fire(player, { kind = "offline" })

	local record = find(seen, "offline_claim")
	t:notNil(record, "no offline_claim — whether the vault cap is worth anything is unanswerable without it")
	t:gt(record.value, 0, "the value is the Tung actually paid out")
	t:eq(record.fields.CustomField02, "within_cap")
	t:eq(record.fields.CustomField03, "1-6h")
end)

T.spec("a rebirth reports which one it was and how far into the session it landed", function(t)
	local w = T.world()
	local Data = w.req("DataService")
	local A, seen = analytics(w)

	local player = w.join("ascender")
	local profile = Data.load(player)
	profile.owned.dropper1 = true
	A.onPlayer(player)
	w.clock:advance(45 * 60)                    -- three quarters of an hour in

	-- Tycoon:rebirth wipes profile.owned and then calls this, which is the order
	-- that makes the carried-forward milestone the one they now stand on.
	profile.owned = {}
	A.onRebirth(player, 1, 50e9, 100)

	local record = find(seen, "rebirth")
	t:notNil(record)
	t:eq(record.value, 1)
	t:eq(record.fields.CustomField02, "30-60m")
	t:eq(record.fields.CustomField03, "1")
	t:eq(A.stateFor(player).lastMilestone, "none",
		"a rebirthed session must not log out at a rung the rebirth already took away")
end)

end
