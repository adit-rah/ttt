--[[
	hud_spec.lua — the client boots, and the card names the purchase the plot's
	beacon points at.

	WHY THIS FAMILY EXISTS. Until this round no client module had ever executed
	outside Roblox: SERVER_MODULES listed eight server modules and all of
	src/shared, and src/client was simply absent. That is half of why the headline
	defect of the round shipped — SessionUI.lua read `Config.UI` at module scope
	with its `local Config = Req("Config")` deleted, Req re-raises a failed
	require, and Main.client.lua requires SessionUI BEFORE it calls HUD.start(),
	so the entire HUD was dead at boot for two rounds with a green CI. The
	analysis pass now names the Roblox globals instead of waving through the
	"Unknown global" class, which closes that one. A LINT CATCHES AN UNDECLARED
	IDENTIFIER; IT DOES NOT CATCH A MODULE THAT RAISES FOR ANY OTHER REASON. The
	first spec below is that half, and it is deliberately the dullest thing in
	this file.

	MAIN.CLIENT.LUA ITSELF IS NOT IN THE BUNDLE. It is an entry script rather than
	a module (see CLIENT_MODULES in tools/test.py), so the boot ORDER it owns is
	imitated here rather than executed: the fourth spec drives HUD.start,
	CombatClient.start, UpgradeUI.start and SessionUI.start in exactly the order
	that file does, because three of the four read HUD.root() and give up if it is
	nil. If someone reorders that file, this spec does not notice — that gap is
	real and it belongs to review.

	WHAT IS ASSERTED IS BEHAVIOUR, NOT LAYOUT. Every size and position in the HUD
	comes from Config.UI and is asserted against its neighbours by
	tools/verify_config.lua, which can see the whole column at once; this file
	cannot see a rectangle at all (the mock stores a UDim2 and never resolves it —
	see tools/testing/mock/gui.lua, claim 1). So nothing here names a panel's
	size, a Y or a colour. The balance is found by the NUMBER it prints and then
	tracked through a second packet; the next purchase is found by the NAME it
	prints. Both survive the card being redrawn, which is what happened to both of
	those panels in this very round.

	THE LAST TWO SPECS ARE THE POINT OF THE FILE. HUD.lua says of its
	cheapestAvailable that keeping two hand-maintained copies of Tycoon:pointAt's
	ranking identical "is not a plan, it is a hope", and nothing has ever checked
	that they agree. Tycoon is already in the harness, so both are reachable in one
	realm: the first walks the whole build, buying whatever the card names and
	asserting at every one of the 34 steps that refreshButtons hands pointAt the
	same button; the second puts the two branches that walk cannot reach — the
	track gate and the price tie-break — somewhere they decide the answer. See the
	note above that spec for why neither is reachable from any state the shipped
	Config can produce, which is itself the most interesting thing this family
	found.

	WHAT THIS FAMILY DOES NOT COVER, because the mock deliberately stops short:
	no tween advances, so HUD.toast, the rebirth modal and the welcome-back modal
	are unreached; the viewport never changes after boot, so rotation and resize
	are unreached; ChildAdded never fires, so CombatClient's bat watching is
	unreached. All of it is named, with what it costs, in mock/gui.lua's header.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL — two specs in this project were once
	found that could not, and a green spec is read as evidence. Each was watched
	failing under one mutation of the file it guards, applied and reverted in the
	working tree:

	  smoke        `local Config` deleted from UiKit.lua (the shipped defect's
	               shape, on a different file); UiKit returning nil
	  the layers   Overlay assigned the Root frame; the UIScale never parented;
	               the UIPadding never parented
	  the viewport the layers sized fromScale(1, 1) instead of 1/scale
	  the arena    the missing-RaidAnchor warn deleted
	  boot order   HUD.root() returning nil, which is what the three panels
	               guard against and the shape of the defect that shipped
	  the balance  applyStats not reading payload.cash; the label printed once
	               from a constant (which passes the first assertion and fails the
	               second); the counter moved off RenderStepped
	  the ranking  the plot ranking by price alone (fails at step 8); the HUD's
	               tie-break flipped to `>`; the HUD's trackUnlocked gate deleted;
	               the plot's gate deleted from BOTH refreshButtons and
	               requirementsMet — either one alone changes no answer, because
	               the plot applies that gate twice on purpose, and the spec is
	               right not to fail for it.
]]

return function(T)

T.family("hud", "the client boots headless, and the card names what the beacon points at")

-- ── reading the screen ──────────────────────────────────────────────────────

local function descend(instance, out)
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(out, child)
		descend(child, out)
	end
	return out
end

--- Every ScreenGui under the LocalPlayer's PlayerGui.
---
--- The one-ScreenGui rule is linted statically (tools/verify.py pass 8) by
--- looking for `Instance.new("ScreenGui")` outside HUD.lua. This is the runtime
--- half: a count of what actually got built and parented, which also covers a
--- second one made through a helper the lint cannot see.
local function screenGuis(world): number
	local n = 0
	for _, instance in ipairs(descend(world.playerGui(), {})) do
		if instance.ClassName == "ScreenGui" then
			n += 1
		end
	end
	return n
end

--- The one TextLabel printing `text`, or nil with the count in the message.
---
--- TextLabels only: the rebirth button prints an abbreviated number too, and a
--- balance found on a TextButton would be the wrong widget passing this spec.
local function labelSaying(root, text: string)
	local found = {}
	for _, instance in ipairs(descend(root, {})) do
		if instance.ClassName == "TextLabel" and instance.Text == text then
			table.insert(found, instance)
		end
	end
	if #found == 1 then
		return found[1]
	end
	return nil, #found
end

--- Which button def the card is naming, read out of whatever label holds it.
---
--- cheapestAvailable is a local in HUD.lua and there is deliberately no accessor
--- for it, so the readout IS the observable — which means this also proves the
--- card is wired to the ranking rather than to something else.
---
--- LONGEST MATCH WINS, and that is not a nicety: "Tung Dropper" is a substring of
--- "Tung Tung Dropper", so a plain search finds two candidates for one label and
--- the shorter one is always the wrong answer. The true name always matches, and
--- anything else that matches is a substring of it, hence shorter.
local function cardNames(root, Config)
	local texts = {}
	for _, instance in ipairs(descend(root, {})) do
		if instance.ClassName == "TextLabel" and type(instance.Text) == "string" then
			table.insert(texts, instance.Text)
		end
	end
	local best
	for _, def in ipairs(Config.Buttons) do
		for _, text in ipairs(texts) do
			if string.find(text, def.name, 1, true) then
				if not best or #def.name > #best.name then
					best = def
				end
				break
			end
		end
	end
	return best
end

-- ── driving the wire ────────────────────────────────────────────────────────

local function remoteNamed(world, name: string)
	local folder = world.replicatedStorage:FindFirstChild("TungNet")
	return folder and folder:FindFirstChild(name)
end

--- Push a payload down a remote the way the server would.
---
--- Through OnClientEvent rather than by calling HUD.applyStats directly, for the
--- same reason the server specs fire OnServerEvent: the connection itself is part
--- of what is under test, and a handler that was never connected is exactly the
--- failure this family exists for.
local function toClient(world, name: string, payload)
	remoteNamed(world, name).OnClientEvent:Fire(payload)
end

--- Fails with the error text rather than with a count.
---
--- Roblox swallows an error raised inside a connected handler, and so does the
--- Signal mock. Without this, a Stats handler that raised would read as a label
--- that simply did not change.
local function quiet(t, world, what: string)
	local errors = world.handlerErrors()
	t:eq(#errors, 0, errors[1] and ("%s: %s"):format(what, tostring(errors[1])) or what)
end

--- A world with a LocalPlayer, which has to exist BEFORE the first client module
--- loads: HUD and CombatClient both read Players.LocalPlayer at module scope.
local function clientWorld(opts)
	local world = T.world(opts)
	world.client()
	return world
end

-- ── boot ────────────────────────────────────────────────────────────────────

T.spec("every module in src/client loads", function(t)
	local world = clientWorld()
	local seen = 0
	for _, name in ipairs(T.clients.modules) do
		seen += 1
		local module = world.req(name)
		t:eq(type(module), "table",
			("Req(%q) returned no module table — it raised, or it returns nothing"):format(name))
	end
	-- The list is generated from CLIENT_MODULES by tools/test.py, so an empty or
	-- truncated one would make every assertion above vacuous.
	t:gte(seen, 5, "the generated client module list is empty or truncated")
end)

-- ── the two layers ──────────────────────────────────────────────────────────

T.spec("HUD.start builds ONE ScreenGui, with a Root and an Overlay that both scale", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	local gui = HUD.start()

	t:eq(gui.ClassName, "ScreenGui", "HUD.start did not return the ScreenGui")
	t:eq(screenGuis(world), 1, "HUD.start built more than one ScreenGui")
	t:eq(HUD.root(), gui:FindFirstChild("Root"), "root() is not the Root layer of that gui")
	t:eq(HUD.overlay(), gui:FindFirstChild("Overlay"), "overlay() is not the Overlay layer of that gui")
	t:ne(HUD.root(), HUD.overlay(), "root() and overlay() are the same frame")

	-- A layer with no UIScale is a layer outside mobile scaling, which is the
	-- entire reason there is only one ScreenGui to begin with.
	t:notNil(HUD.root():FindFirstChildOfClass("UIScale"), "the Root layer carries no UIScale")
	t:notNil(HUD.overlay():FindFirstChildOfClass("UIScale"), "the Overlay layer carries no UIScale")
	-- Padded clear of the notch, and the shade layer deliberately is not.
	t:notNil(HUD.root():FindFirstChildOfClass("UIPadding"), "the Root layer carries no safe-area padding")
end)

T.spec("on a landscape phone both layers take the same scale, and 1/scale for their size", function(t)
	local world = clientWorld()
	-- Set before start(): the harness cannot fire a ViewportSize change (mock/
	-- gui.lua, claim 3), so this is the one applyViewport() call boot makes.
	world.camera.ViewportSize = Vector2.new(896, 414)

	local UiKit = world.req("UiKit")
	local HUD = world.req("HUD")
	HUD.start()

	local scale = UiKit.scaleFor(world.camera.ViewportSize)
	t:gt(scale, 0, "scaleFor returned no scale for a phone viewport")
	t:lte(scale, 1, "a phone was scaled UP")

	for _, layer in ipairs({ HUD.root(), HUD.overlay() }) do
		local uiScale = layer:FindFirstChildOfClass("UIScale")
		t:near(uiScale.Scale, scale, 1e-9, "a layer's UIScale is not the viewport's scale")
		-- 1/scale is what cancels the UIScale for scale-based children, so a
		-- fromScale(1, 1) shade still covers the whole screen.
		t:near(layer.Size.X.Scale, 1 / scale, 1e-9, "a layer is not 1/scale wide")
		t:near(layer.Size.Y.Scale, 1 / scale, 1e-9, "a layer is not 1/scale tall")
	end
end)

T.spec("the topbar's own buttons are not a full-height left gutter", function(t)
	--- Root's safe-area padding, in design px, for a given TopbarInset.
	local function paddingUnder(bar)
		local world = clientWorld()
		-- Set before start(): boot makes the one applyViewport() call this
		-- harness can produce (mock/gui.lua, claim 3).
		world.services.GuiService.TopbarInset = bar
		local HUD = world.req("HUD")
		HUD.start()
		local padding = HUD.root():FindFirstChildOfClass("UIPadding")
		t:notNil(padding, "the root layer lost its safe-area padding")
		return padding
	end

	-- A DESKTOP TOPBAR, WHICH IS NOT A NOTCH. GuiService.TopbarInset is the strip
	-- left over for CUSTOM topbar buttons, so its left edge sits past Roblox's own
	-- menu and chat buttons — 165 px in, on the machine this was found on. It was
	-- read as "the only reading of the side safe area available to a LocalScript"
	-- and applied as a full-height gutter, which pushed the entire left column 191
	-- px inside the screen on every device, to clear an obstruction that lives in a
	-- strip IgnoreGuiInset = false has already put the whole layer below. About a
	-- sixth of the screen's width, and it looked deliberate.
	local wide = paddingUnder(Rect.new(165, 0, 1280, 36))
	-- ...and the same client with nothing reserved at either end of the topbar.
	local flush = paddingUnder(Rect.new(0, 0, 1280, 36))

	t:eq(wide.PaddingLeft.Offset, flush.PaddingLeft.Offset,
		("165 px of Roblox's own topbar buttons moved the HUD's left edge: %d px against %d")
			:format(wide.PaddingLeft.Offset, flush.PaddingLeft.Offset))
	t:eq(wide.PaddingRight.Offset, flush.PaddingRight.Offset,
		"the topbar's far edge moved the HUD's right edge")

	-- ...and what is left is the declared gutter and nothing else, because this
	-- mock's GetGuiInset reports no side cutout (claim 4). On a notched phone
	-- topLeft.X is the cutout and this number grows; on a desktop it is exactly
	-- SafeAreaPad, and a desktop is where the defect was visible.
	local Config = clientWorld().req("Config")
	t:eq(flush.PaddingLeft.Offset, Config.UI.SafeAreaPad,
		"an unnotched client's left gutter is not just SafeAreaPad")
end)

T.spec("with no arena in the workspace the raid sign is skipped, not fatal", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	HUD.start()
	t:warned("RaidAnchor", "the raid sign was built with nothing to hang it on, or failed silently")
	-- Every read of the banner is nil-guarded, so a wave packet arriving without
	-- one is a no-op rather than an error a player would see.
	HUD.applyWave({ phase = "warning", wave = 3, seconds = 5, boss = false })
	HUD.renderWave()
	quiet(t, world, "a wave packet with no banner raised")
end)

-- ── the panels that build into those layers ─────────────────────────────────

T.spec("CombatClient, UpgradeUI and SessionUI all start after HUD, in boot order", function(t)
	local world = clientWorld()
	-- The prototype flags ship false, and UpgradeUI.start() returns immediately
	-- with them off — so with the shipped values this spec would prove only that
	-- an early return does not raise. world.lua's FLAGS note is why flipping them
	-- here works: the module reads them at load, so they go on first.
	world.config.Prototypes.PlayerUpgrades = true
	world.config.Prototypes.Utilities = true

	local HUD = world.req("HUD")
	local CombatClient = world.req("CombatClient")
	local UpgradeUI = world.req("UpgradeUI")
	local SessionUI = world.req("SessionUI")

	-- Main.client.lua's order, which is the contract these three depend on: each
	-- of them reads HUD.root() and gives up if it is nil.
	HUD.start()
	CombatClient.start()
	UpgradeUI.start()
	SessionUI.start()

	local root = HUD.root()
	t:notNil(root:FindFirstChild("Hitmarker"), "CombatClient built no hitmarker into the HUD's root layer")
	t:notNil(root:FindFirstChild("UpgradeShop"), "UpgradeUI built no shop into the HUD's root layer")
	t:notNil(world.renderBindings["TungCameraShake"], "CombatClient bound no camera shake")

	-- THE SESSION PANEL IS A GRANDCHILD NOW, not a child. It builds into
	-- HUD.column() — the top-left UIListLayout — rather than positioning itself
	-- on the root layer from Config.UI.SessionPanel.Y, so a non-recursive find
	-- would report it missing. Asserted through the column rather than with a
	-- recursive search, because WHERE it landed is the point: a panel that ended
	-- up anywhere else in the tree is a panel that is not in the column.
	local column = HUD.column()
	t:notNil(column, "HUD built no left column")
	t:notNil(column:FindFirstChild("Status"), "the status card is not in the left column")
	t:notNil(column:FindFirstChild("Session"), "SessionUI built no session panel into the HUD's column")

	-- The whole reason the three of them are here rather than in ScreenGuis of
	-- their own.
	t:eq(screenGuis(world), 1, "a panel built its own ScreenGui")
	quiet(t, world, "a panel raised while starting")
end)

-- ── the invite, and the card it came off ────────────────────────────────────

--- The rail's invite item, wherever it ended up.
local function inviteItem(HUD)
	local rail = HUD.root():FindFirstChild("Rail")
	return rail and rail:FindFirstChild("Invite"), rail
end

T.spec("the invite is a rail item, and account policy decides whether it exists at all", function(t)
	-- POLICY SAYS NO. CanSendGameInviteAsync can return false as well as throw,
	-- and both answers hide the button: the audience here is largely children and
	-- the failure they must never see is an error where a button used to be.
	-- HANDOFF_v6 lists this path as one nobody has ever seen; it is seen here.
	local refused = clientWorld()
	refused.socialService.canInvite = false
	local HUD = refused.req("HUD")
	HUD.start()

	local invite, rail = inviteItem(HUD)
	t:notNil(rail, "HUD built no top-right rail")
	t:notNil(invite, "the invite is not on the rail")
	t:eq(invite.Visible, false, "a policy-refused account was still shown an invite button")
	quiet(t, refused, "building the rail raised")

	-- POLICY SAYS YES, which is the other half of a branch that had neither.
	local allowed = clientWorld()
	allowed.socialService.canInvite = true
	local HUD2 = allowed.req("HUD")
	HUD2.start()
	local invite2 = inviteItem(HUD2)
	t:eq(invite2.Visible, true, "an account that may invite was shown nothing")

	-- THE CAPTION IS THE PRICE TAG. The friend row this replaced argued that the
	-- ZERO state is the one that matters — the moment the number is legible is
	-- the moment the ask has a price tag on it — and with nobody here the caption
	-- reads what ONE friend would be worth, not the nothing you currently have.
	local Config = allowed.req("Config")
	local caption = invite2:FindFirstChild("Caption")
	t:notNil(caption, "the rail item has no caption")
	t:eq(caption.Text, ("+%d%%"):format(math.floor(Config.Social.BonusPerFriend * 100)),
		"with no friends here the invite does not say what one would be worth")
	quiet(t, allowed, "building the rail raised")
end)

T.spec("the status card has nothing on it to press", function(t)
	local world = clientWorld()
	local HUD = world.req("HUD")
	HUD.start()

	-- THE REGRESSION GUARD FOR THE PILL COMING BACK. The card carries the
	-- balance, what multiplies it and the next purchase; it is read at a glance
	-- and there is nothing on it to press. verify_config asserts that no ROW on
	-- the card is a touch target's height, which is as close as Config can get to
	-- saying this. This is the other half, and it is the half that sees a widget.
	local card = HUD.column():FindFirstChild("Status")
	t:notNil(card, "no status card")
	local pressable = {}
	for _, instance in ipairs(descend(card, {})) do
		if instance.ClassName == "TextButton" or instance.ClassName == "ImageButton" then
			table.insert(pressable, instance.Name)
		end
	end
	t:eq(#pressable, 0, ("there is a button on the status card again: %s")
		:format(table.concat(pressable, ", ")))
end)

-- ── the session panel's tail ────────────────────────────────────────────────

--- A SessionState the panel can render, with or without its optional tail.
---
--- The fixed rows need every field their formatters read — a nil graceHours is a
--- format error inside a signal handler, which the Signal mock swallows and which
--- would read as a panel that simply did not resize.
local function withTail(tail: boolean)
	local payload = {
		enabled = { rebirth = false },
		daily = {
			available = false, streak = 3, nextStreak = 4, dayIndex = 4, ladder = 7,
			reward = 500, milestone = nil, graceHours = 6, resetIn = 3600,
		},
		playtime = { activeSeconds = 120, resetIn = 3600, rungs = {} },
		boost = {
			multiplier = 2, duration = 600, secondsLeft = 0, cooldownLeft = 0,
			weekend = false, weekendMultiplier = 2,
		},
	}
	if tail then
		-- The two optional rows, both up at once: a returning player who has not
		-- maxed the vault. capUpgrade nil is the top of the ladder, which is what
		-- makes the Vault Timer row disappear.
		-- Every field the welcome-back modal formats, because pushing an offline
		-- grant is what auto-opens it. A missing one raises inside the signal
		-- handler and the panel behind it never gets resized.
		payload.offline = {
			earned = 1000, seconds = 3600, creditedSeconds = 3600,
			rate = 0.5, perSecond = 10, clipped = false, capHours = 4,
		}
		payload.capUpgrade = { name = "Vault Timer II", hours = 8, cost = 5000 }
		payload.capHours = 4
	end
	return payload
end

T.spec("the session panel never outgrows the height the column is budgeted for", function(t)
	local world = clientWorld()
	local Config = world.req("Config")
	local HUD = world.req("HUD")
	local SessionUI = world.req("SessionUI")
	HUD.start()
	SessionUI.start()

	local panel = HUD.column():FindFirstChild("Session")
	t:notNil(panel, "no session panel")

	-- BOTH OPTIONAL ROWS AT ONCE, which is the state the shipped numbers had
	-- already been left behind by: TallHeight was 258, the one-row height, and
	-- layoutTail built 310 with the Vault Timer and a pending offline grant both
	-- up. That is every returning player who has not maxed the vault. It fitted
	-- the screen by luck, and Config.UI.ColumnBottom was measured against the
	-- smaller number, so nothing would have said anything until it did not fit.
	-- PUSHED TWICE, AND THE SECOND ONE IS THE ONE THIS SPEC READS. The first
	-- sight of a pending grant also opens the welcome-back modal, which tweens —
	-- and mock/gui.lua claim 7 deliberately implements no TweenInfo, so that path
	-- raises. It raises AFTER render() has sized the panel, so the first push is
	-- still what puts both rows up; the second one finds `hadOffline` already set
	-- and leaves the modal alone, which is what lets quiet() below mean something.
	toClient(world, "SessionState", withTail(true))
	world.handlerErrors()
	toClient(world, "SessionState", withTail(true))

	t:eq(panel.Visible, true, "the session panel stayed hidden after a SessionState")
	local grown = panel.Size.Y.Offset
	t:eq(grown, Config.UI.SessionPanel.TallHeight,
		("both optional rows showing built a %d-px panel; TallHeight says %d")
			:format(grown, Config.UI.SessionPanel.TallHeight))
	-- ...and the budget the verifier holds the whole column to is the budget the
	-- runtime can actually reach.
	t:eq(Config.UI.Margin + Config.UI.StatusCard.Height + Config.UI.Gap + grown,
		Config.UI.ColumnBottom,
		"the column's tallest real layout is not the one Config.UI.ColumnBottom describes")

	-- ...and with no tail at all it is back to the ordinary height, so the two
	-- are two reachable states rather than one number and one guess.
	toClient(world, "SessionState", withTail(false))
	t:eq(panel.Size.Y.Offset, Config.UI.SessionPanel.Height,
		"with no optional rows the panel is not at its ordinary height")

	quiet(t, world, "a SessionState payload raised")
end)

-- ── the balance ─────────────────────────────────────────────────────────────

T.spec("an injected Stats payload reaches the balance, and the balance follows it", function(t)
	local world = clientWorld()
	local Util = world.req("Util")
	local HUD = world.req("HUD")
	HUD.start()

	local function stats(cash: number)
		toClient(world, "Stats", {
			cash = cash, rebirths = 0, kills = 0, multiplier = 1,
			owned = {}, rebirthCost = 5000,
		})
		quiet(t, world, "the Stats handler raised")
		-- One long frame: the counter lerps by min(dt * 9, 1), so a whole second
		-- lands it exactly on the packet rather than 90% of the way there.
		world.render(1)
	end

	stats(12345)
	local shown, count = labelSaying(HUD.root(), Util.abbreviate(12345))
	t:notNil(shown, ("no single label prints the balance the packet carried (%d matched)"):format(count or 0))

	-- FOLLOWS, not just prints once: the same label object, a second packet. A
	-- balance written from state.cash instead of the lerped value passes the first
	-- assertion and fails this one.
	stats(720)
	t:eq(shown and shown.Text, Util.abbreviate(720), "the balance label did not follow payload.cash")
end)

-- ── the ranking, against the plot's own ──────────────────────────────────────

--- A plot with the state refreshButtons touches and nothing else.
---
--- Everything that would need a BasePart, a Highlight or a CFrame is stubbed on
--- the INSTANCE, which shadows the class method without changing it — the same
--- shape generator_spec.lua uses, and for the same reason. `pointAt` is the one
--- stub that records rather than doing nothing: it is where the ranking LANDS, so
--- the entry it is handed is the plot's answer.
---
--- THE STUB LIST IS A DEPENDENCY. If refreshButtons grows a call to something
--- else that touches a part, this spec fails with `attempt to index nil` and the
--- fix is a line here, not in the game.
local function fakePlot(world)
	local Tycoon = world.req("Tycoon")
	local Config = world.config
	local plot = setmetatable({}, { __index = Tycoon })
	local pointed = {}

	plot.owner = world.join("Ranker")     -- no profile, so Economy.get is 0; cash is not part of the ranking
	plot.owned = {}
	plot.objects = {}
	plot.buttonsFolder = { Name = "Buttons" }
	for _, def in ipairs(Config.Buttons) do
		plot.objects[def.id] = {
			def = def, holder = {}, pad = {}, light = {}, stroke = {},
			stepLabel = {}, titleLabel = {}, effectLabel = {}, priceLabel = {},
		}
	end

	plot.setButtonVoice = function() end
	plot.buildGhost = function() return nil end
	plot.effectLine = function() return "" end
	plot.ensureCabinets = function() end
	plot.updateCabinetSigns = function() end
	plot.ensureYard = function() end
	plot.refreshGenerator = function() end
	plot.pointAt = function(_self, entry)
		pointed.entry = entry
	end

	return plot, pointed
end

--- Both answers for one `owned` set: what the card names, and what refreshButtons
--- hands pointAt. Cash is deliberately enormous — affordability moves the card's
--- COLOURS and never its ranking, and the plot's ranking never reads it at all.
local function picks(t, world, root, plot, pointed, owned)
	toClient(world, "Stats", {
		cash = 1e12, rebirths = 0, kills = 0, multiplier = 1,
		owned = owned, rebirthCost = 5000,
	})
	quiet(t, world, "the Stats handler raised")
	local card = cardNames(root, world.config)

	plot.owned = owned
	pointed.entry = nil
	plot:refreshButtons()
	return card, pointed.entry and pointed.entry.def or nil
end

T.spec("the card names the button the plot's beacon points at, at every step of the build", function(t)
	local world = clientWorld()
	local Config = world.config
	local HUD = world.req("HUD")
	HUD.start()
	local root = HUD.root()
	local plot, pointed = fakePlot(world)

	-- The precondition of reading the card by name: two defs sharing a name would
	-- make the readout ambiguous and this whole spec meaningless.
	local names = {}
	for _, def in ipairs(Config.Buttons) do
		t:isNil(names[def.name], ("two buttons are both called %q"):format(def.name))
		names[def.name] = def.id
	end

	local owned = {}
	local steps = 0
	while steps <= #Config.Buttons do
		local card, beacon = picks(t, world, root, plot, pointed, owned)
		if card == nil and beacon == nil then
			break      -- everything built, and both agree there is nothing left
		end
		t:eq(card and card.id, beacon and beacon.id,
			("at step %d the card and the beacon name different buttons"):format(steps + 1))
		if card == nil or beacon == nil then
			break      -- they already disagree; walking further only repeats it
		end
		owned[card.id] = true
		steps += 1
	end

	-- A loop that asserts inside itself passes for free when it never runs. This
	-- is what it actually visited, and it has to be the whole build.
	t:eq(steps, #Config.Buttons, "the walk did not buy every button in Config.Buttons")
end)

--- THE WALK ABOVE CANNOT REACH EITHER OF THE OTHER TWO BRANCHES, and that was
--- worth finding out. With today's Config:
---
---   * THE TRACK GATE never decides anything. It only hides the two cabinets, and
---     it only hides them while `mezzanine` is unowned — but mezzanine is a
---     FACTORY rung, and the factory is rank 1, so while it is unowned the factory
---     always has an available rung that outranks everything the gate could have
---     hidden. Deleting the gate from either copy leaves both answers unchanged at
---     all 34 steps.
---   * THE PRICE TIE-BREAK never fires. Two buttons only tie on rank if they are
---     in the SAME track, a track is a chain, so exactly one of its rungs is ever
---     available at once. Flipping `<` to `>` in either copy changes nothing.
---
--- Two hand-maintained copies of a branch that cannot change the answer is worse
--- than one, not better: it can drift for as long as it likes and the game looks
--- fine. So this spec puts each branch somewhere it DOES decide, by mutating this
--- realm's own Config — legal for the reason structure_spec.lua gives when it does
--- the same to Config.Structure: a fresh realm's Config belongs to one spec, and
--- the degenerate case the shipped numbers happen not to contain is exactly where
--- this kind of arithmetic breaks.
T.spec("the gate and the price tie-break agree too, where the shipped build cannot reach them", function(t)
	local world = clientWorld()
	local Config = world.config
	local HUD = world.req("HUD")
	HUD.start()
	local root = HUD.root()
	local plot, pointed = fakePlot(world)

	local everything = {}
	for _, def in ipairs(Config.Buttons) do
		everything[def.id] = true
	end

	-- THE GATE. Gate the POWER track, which today is gated on nothing and ranks
	-- last: with everything else built, a gate on it is the only thing left that
	-- can decide the answer. Both copies must offer nothing at all.
	Config.TrackUnlock.power = "no_such_button"
	local owned = table.clone(everything)
	for _, def in ipairs(Config.Tracks.power) do
		owned[def.id] = nil
	end
	local card, beacon = picks(t, world, root, plot, pointed, owned)
	t:isNil(card, "the card named a rung of a gated track")
	t:isNil(beacon, "the beacon pointed at a rung of a gated track")

	-- THE TIE-BREAK. Tie the two cabinets on rank and leave the top rung of each
	-- unbought: the ranks are now equal, so price is all that is left, and both
	-- copies have their own copy of "cheapest wins".
	Config.TrackUnlock.power = nil
	Config.TrackRank.armor = Config.TrackRank.weapons
	local weapon = Config.Tracks.weapons[#Config.Tracks.weapons]
	local armor = Config.Tracks.armor[#Config.Tracks.armor]
	t:ne(weapon.price, armor.price, "the two top rungs cost the same, so the tie-break is unobservable")
	local cheaper = weapon.price < armor.price and weapon or armor

	owned = table.clone(everything)
	owned[weapon.id] = nil
	owned[armor.id] = nil
	card, beacon = picks(t, world, root, plot, pointed, owned)
	t:eq(card and card.id, cheaper.id, "the card did not take the cheaper of two tracks tied on rank")
	t:eq(beacon and beacon.id, cheaper.id, "the beacon did not take the cheaper of two tracks tied on rank")
end)

--- THE THIRD BRANCH, AND UNLIKE THE OTHER TWO THE SHIPPED BUILD DOES REACH IT.
---
--- Config.ButtonUnlock.floor2 = "roof" is the only cross-ladder precondition in
--- the game, and it is the one place where the thing blocking your next purchase
--- is on a track you were not looking at. Both copies of the ranking have to
--- know about it or they disagree in the most expensive way available: the card
--- names the mezzanine and starts filling a progress bar towards 9.3 million,
--- while the beacon out on the plot glows on a roof costing a fifteenth of that.
---
--- The walk above does exercise this — it would stall or mismatch at floor2 if
--- either copy were missing the gate — but it exercises it in passing, mixed in
--- with thirty-six other steps. This puts the gate on its own, and then TAKES IT
--- AWAY and shows the answer changes, which is the part that proves the branch
--- is deciding something rather than agreeing by luck.
T.spec("the card and the beacon both wait for the roof before naming the mezzanine", function(t)
	local world = clientWorld()
	local Config = world.config
	local HUD = world.req("HUD")
	HUD.start()
	local root = HUD.root()
	local plot, pointed = fakePlot(world)

	local floorButton = Config.Floors[1].button
	local gate = Config.ButtonUnlock[floorButton]
	t:eq(gate, "roof", "this spec is about the roof gating the storey")

	-- Everything on the factory chain up to the mezzanine, and everything on the
	-- shell except the roof. So the factory's frontier IS the mezzanine and the
	-- shell's frontier IS the roof, and exactly one of those two is buyable.
	local owned = {}
	for _, def in ipairs(Config.Tracks.factory) do
		if def.id == floorButton then break end
		owned[def.id] = true
	end
	for _, def in ipairs(Config.Tracks.structure) do
		if def.id == gate then break end
		owned[def.id] = true
	end

	local card, beacon = picks(t, world, root, plot, pointed, owned)
	t:eq(card and card.id, gate,
		"the card named the mezzanine while the storey below it has no roof")
	t:eq(beacon and beacon.id, gate,
		"the beacon pointed at the mezzanine while the storey below it has no roof")

	-- FACTORY OUTRANKS STRUCTURE, so this is not the ranking picking the roof by
	-- accident: with the gate gone, rank 1 wins and both answers move to the
	-- mezzanine. If deleting the gate changes nothing, the gate was never being
	-- read and the two assertions above were passing for the wrong reason.
	t:lte(Config.TrackRank.factory, Config.TrackRank.structure)
	Config.ButtonUnlock[floorButton] = nil
	card, beacon = picks(t, world, root, plot, pointed, owned)
	t:eq(card and card.id, floorButton,
		"removing the gate did not change the card, so the card was not reading it")
	t:eq(beacon and beacon.id, floorButton,
		"removing the gate did not change the beacon, so the beacon was not reading it")
end)

end
