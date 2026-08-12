--[[
	AdminService.lua — chat commands, for testing what the verifier cannot see.

	Every handoff since v3 has ended with a list of things only Studio can
	answer, and every one of those lists has gone unanswered. HANDOFF_v5 §5 item
	8 asked someone to own `power3` and `belt1` and read the belt speed; it went
	two rounds, and when a spec finally asked the question the answer was a
	number neither round had guessed. The reason nobody checked is that reaching
	that save meant a thirty-two minute grind, and there was no other way in.

	`!give power3` and `!give belt1` is that save, in two lines. That is what
	these commands are for. The cash grants are a convenience; `!give` is the
	one that pays for itself.

	AUTHORISATION IS PER-PLAYER, NOT PER-BUILD. See Config.Admin: Studio, the
	place owner, or an explicit allowlist. It is safe to ship — a random player
	on a live server qualifies under none of the three — but the point of it
	being shippable is that you can test on a real populated server, which is
	where most of the untested things in this repo actually live.

	COMMANDS GO THROUGH THE NORMAL PATHS. `!give` calls Tycoon:install, `!wave`
	drives the wave state machine, cash goes through Economy. A command that
	takes a shortcut tests the shortcut.

	IT OWNS NO STATE AND NO CONFIG. Everything it can do, some other service can
	already do; this file is a parser, an authorisation check, and a list of verbs.
	It writes profile.owned in exactly one place (`give`, mirroring tryPurchase)
	and otherwise only calls Economy, PlotService, Tycoon and NPCService.

	Config.Admin IS NOT A Config.Prototypes FLAG AND MUST NOT BECOME ONE.
	tools/verify_config.lua asserts every prototype flag ships false, so a
	prototype flag is one you cannot turn on — the opposite of what this needs.
	This feature is finished, is meant to be on, and is gated on WHO is asking.

	IT STARTS AFTER NPCService, in Main.server.lua, because `!wave` and `!clear`
	drive that service's schedule and forceWave/forceClear are meaningless before
	it has one. `hook` also runs over Players:GetPlayers() as well as PlayerAdded,
	because in Studio the one player who matters is always already there.

	WHAT TO READ FIRST. The load-window guard in AdminService.handle is the
	non-obvious part of this file and it explains itself at length: every command
	ends in a write that needs a loaded profile, DataService.get returns nil rather
	than yielding, and Economy.add fails silently on a nil profile — so without
	the guard a grant reported success and did nothing. That window is now up to
	~32 seconds wide on a contended session lock. Nothing here is covered by
	tools/test.py; the commands are the testing instrument, not the thing tested.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Economy = Req("Economy")
local DataService = Req("DataService")
local PlotService = Req("PlotService")
local NPCService = Req("NPCService")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AdminService = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- who is allowed
-- ─────────────────────────────────────────────────────────────────────────────

--- Studio, the place owner, or the allowlist.
---
--- CreatorType is checked before CreatorId is trusted: for a group-owned place
--- `game.CreatorId` is the GROUP's id, and comparing a UserId against it would
--- be comparing two numbers from different namespaces. They can collide, and
--- the failure mode is handing a stranger the money command.
local function isAdmin(player: Player): boolean
	if not Config.Admin.Enabled then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	for _, id in ipairs(Config.Admin.UserIds) do
		if player.UserId == id then
			return true
		end
	end
	return false
end

local function say(player: Player, title: string, body: string, kind: string?)
	Economy.notify(player, { kind = kind or "info", title = title, body = body })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the commands
-- ─────────────────────────────────────────────────────────────────────────────

--- Grant cash.
---
--- applyMultiplier is FALSE. Economy.add would otherwise scale the grant by the
--- rebirth multiplier, so `$1000` after two rebirths would silently be $5062 —
--- and the whole value of a debug grant is that you get the number you asked
--- for. Economy.push follows because add only marks dirty for the batched 10 Hz
--- replication, and a debug command that takes a tenth of a second to show up
--- reads as a command that did not work.
local function grant(player: Player, amount: number)
	Economy.add(player, amount, false)
	Economy.push(player)
	say(player, "Admin", ("+%s Tung."):format(Util.abbreviate(amount)), "claim")
end

--- Everything on the plot, at once.
---
--- Summed from Config rather than from a literal, so it keeps up with the
--- ladder. The side tracks are included: floor2 gates both cabinets and this is
--- meant to leave you able to buy the whole game, not the factory only.
local function grantEverything(player: Player)
	local total = 0
	for _, def in ipairs(Config.Buttons) do
		total += def.price
	end
	total += Config.Rebirth.BaseCost
	grant(player, total)
end

--- Install a button without paying for it.
---
--- Writes profile.owned AND calls install, in that order, exactly as
--- tryPurchase does — the profile write is what makes it survive a rejoin, and
--- install is what actually builds the machine. Doing only the second gives you
--- a machine that vanishes at next login, which is a confusing thing to hand
--- someone who is mid-debug.
---
--- requirementsMet is deliberately NOT checked. `!give power3` has to work
--- without power1 and power2, because "a save that somehow holds power3 without
--- power2" is exactly the shape of state these commands exist to produce.
local function give(player: Player, id: string): (boolean, string)
	local def = Config.ButtonById[id]
	if not def then
		return false, ("no button called %q"):format(id)
	end
	local tycoon = PlotService.plotOf(player)
	if not tycoon then
		return false, "you do not have a plot"
	end
	if tycoon.owned[id] then
		return false, ("you already own %s"):format(def.name)
	end

	local profile = DataService.get(player)
	if profile then
		profile.owned[id] = true
	end
	tycoon:install(id, false)
	Economy.push(player)
	return true, def.name
end

--- Put the player on the mezzanine.
---
--- Reads the deck's height out of Config rather than raycasting, and lands them
--- a stud above it. If the floor is not built this refuses rather than dropping
--- them through the sky, because "teleport me to a thing that does not exist"
--- has no sensible answer.
local function toMezzanine(player: Player): (boolean, string)
	local tycoon = PlotService.plotOf(player)
	if not tycoon then
		return false, "you do not have a plot"
	end
	local floor = Config.Floors[1]
	if not tycoon.owned[floor.button] then
		return false, ("buy %s first"):format(Config.ButtonById[floor.button].name)
	end
	local character = player.Character
	if not character or not character.PrimaryPart then
		return false, "no character"
	end
	local at = floor.deckAt
	character:PivotTo(tycoon:at(at.X, floor.height + 4, at.Z))
	return true, "mezzanine"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- parsing
-- ─────────────────────────────────────────────────────────────────────────────

--- Returns true if the message was a command, whether or not it succeeded.
---
--- Silent on anything that is not one: this runs on every line of chat from an
--- admin, and a handler that answers back about messages it did not understand
--- makes the chat unusable for the person who has the commands.
function AdminService.handle(player: Player, message: string): boolean
	local text = message:match("^%s*(.-)%s*$")

	-- NOTHING RUNS WITHOUT A LOADED PROFILE, and this guard is the whole
	-- reason: every command here ends in a write that DataService.get has to
	-- resolve, and `get` returns nil until the load finishes rather than
	-- yielding until it does.
	--
	-- Economy.add's first line is `if not profile or amount <= 0 then return 0`
	-- — it fails SILENTLY — so without this, `$1000` typed during the load
	-- window granted nothing and then reported "+1.0M Tung." A debug command
	-- that lies about having worked is worse than one that refuses, because the
	-- next thing you do is trust the number it printed.
	--
	-- The window used to be milliseconds and is about to be much wider: the
	-- parallel round's DataStore session locking makes a contended load take up
	-- to ~32 seconds, which is long enough to walk in and start typing.
	-- Gated on the message LOOKING like a command first. Guarding before that
	-- test would answer back on every ordinary line an admin types during the
	-- load window, which is the behaviour the "silent on anything that is not a
	-- command" rule above exists to prevent.
	if (text:sub(1, 1) == "$" or text:sub(1, 1) == "!") and not DataService.get(player) then
		say(player, "Admin", "Your save is still loading — try again in a moment.", "warn")
		return true
	end

	-- $$  — everything
	if text == "$$" then
		grantEverything(player)
		say(player, "Admin", "Granted enough for the whole plot.", "claim")
		return true
	end

	-- $ / $<amount>  — cash. The amount accepts 1e6 and 2.5e9 as well as plain
	-- digits, because the late ladder is priced in billions and typing those
	-- out is how you end up off by a zero.
	local money = text:match("^%$(.*)$")
	if money then
		if money == "" then
			grant(player, Config.Admin.DefaultGrant)
		else
			local amount = tonumber(money)
			if not amount or amount <= 0 then
				say(player, "Admin", ("%q is not an amount"):format(money), "warn")
			else
				grant(player, amount)
			end
		end
		return true
	end

	local verb, rest = text:match("^!(%a+)%s*(.*)$")
	if not verb then
		return false
	end
	verb = verb:lower()

	if verb == "give" then
		if rest == "" then
			say(player, "Admin", "!give <buttonId>", "warn")
			return true
		end
		local ok, what = give(player, rest)
		say(player, "Admin", ok and ("Installed %s."):format(what) or what, ok and "buy" or "warn")
		return true
	end

	if verb == "wave" then
		local ok = NPCService.forceWave()
		say(player, "Admin", ok and "Raid incoming." or "A raid is already running.",
			ok and "wave" or "warn")
		return true
	end

	if verb == "clear" then
		local ok = NPCService.forceClear()
		say(player, "Admin", ok and "Wave cleared." or "No raid to clear.",
			ok and "wave" or "warn")
		return true
	end

	if verb == "tp" then
		if rest:lower() ~= "mezz" and rest:lower() ~= "mezzanine" then
			say(player, "Admin", "!tp mezz", "warn")
			return true
		end
		local ok, what = toMezzanine(player)
		say(player, "Admin", ok and "Up you go." or what, ok and "info" or "warn")
		return true
	end

	return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- wiring
-- ─────────────────────────────────────────────────────────────────────────────

local function hook(player: Player)
	player.Chatted:Connect(function(message)
		-- Authorisation is checked per MESSAGE, not at connect time. The
		-- allowlist is Config and Config is reloadable in Studio, and a check
		-- baked in at join would mean rejoining to pick up a change.
		if not isAdmin(player) then
			return
		end
		local ok, err = pcall(AdminService.handle, player, message)
		if not ok then
			warn("[Tung] admin command error: " .. tostring(err))
		end
	end)
end

function AdminService.start()
	Players.PlayerAdded:Connect(hook)
	-- ...and everyone already here. PlayerAdded alone misses every player
	-- present when the server script starts, which in Studio is always you.
	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
end

return AdminService
