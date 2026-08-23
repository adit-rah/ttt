--[[
	Main.server.lua — Tung Tung Tycoon boot sequence.

	Order matters: data before economy (leaderstats read profiles), world
	before plots, plots before players are let in.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))

local Config = Req("Config")
Req("Net")  -- creates the RemoteEvent folder before any client asks for it
local MapBuilder = Req("MapBuilder")
local DataService = Req("DataService")
local Analytics = Req("Analytics")
local Economy = Req("Economy")
local CombatService = Req("CombatService")
local MovementService = Req("MovementService")
local RaidService = Req("RaidService")
local HelpService = Req("HelpService")
local PartyService = Req("PartyService")
local RecallService = Req("RecallService")
local TowerService = Req("TowerService")
local DisclosureService = Req("DisclosureService")
local ShopService = Req("ShopService")
local ObjectiveService = Req("ObjectiveService")
local LeaderboardService = Req("LeaderboardService")
local PlotService = Req("PlotService")
local NPCService = Req("NPCService")
local AdminService = Req("AdminService")

-- SessionService (offline earnings, the session loops) and GateService (the
-- doors in the shell) have graduated and always run.
-- UpgradeService is still a prototype and is a no-op unless
-- Config.Prototypes.PlayerUpgrades is on, so it costs nothing in a shipping build.
local Tycoon = Req("Tycoon")
local UpgradeService = Req("UpgradeService")
local SessionService = Req("SessionService")
local VaultService = Req("VaultService")
local GateService = Req("GateService")

-- Shipped, and flagless: the friend bonus turns off by setting
-- Config.Social.BonusPerFriend to 0, on which start() declines to register its
-- multiplier hook. It connects its own PlayerAdded/PlayerRemoving.
local SocialService = Req("SocialService")

local Players = game:GetService("Players")

local START = os.clock()

Players.CharacterAutoLoads = true

-- 1. world
local world = MapBuilder.build()

-- 2. services
DataService.start()
Analytics.start()
Economy.start()
CombatService.start()
MovementService.start()

-- 3. plots
PlotService.build(world)
PlotService.start()

-- One optional service must not take claiming and the player wiring down
-- with it: everything below this line is gameplay on TOP of the plot loop,
-- so a throw is contained and shouted rather than fatal. The method-resolution
-- lint is the real fix for the class of bug that motivated this; the blast
-- door is for whatever a lint cannot see. Everything ABOVE (world, data,
-- economy, plots) stays unwrapped — if those fail the server is correctly dead.
local function boot(name: string, fn)
	local ok, err = pcall(fn)
	if not ok then
		warn(("[Tung] %s failed to start: %s"):format(name, tostring(err)))
	end
end

-- 4. raids
boot("NPCService", NPCService.start)

-- 4b. admin chat commands. Self-gating on Config.Admin and on WHO is asking, so
-- this is a no-op for an ordinary player on a live server. After NPCService,
-- because !wave and !clear drive its schedule.
boot("AdminService", AdminService.start)

-- 5. sessions and the one remaining prototype
boot("UpgradeService", UpgradeService.start)
boot("SessionService", SessionService.start)
-- after SessionService: it registers listeners on plots that are already built
-- and reads the projection SessionService owns
boot("VaultService", VaultService.start)
-- The gates in the shell's two openings. Anywhere after PlotService.build: it
-- walks Tycoon.all() on its own fixed beat and finds the leaves inside the walls
-- model, so the plots have to exist, but it registers no listener and reacts to
-- no purchase — a gate is a distance test, not an event.
boot("GateService", GateService.start)
-- The siege hook (#124): a swing that boxed wall or gate parts lands here.
-- Wired from this file rather than inside CombatService, because Tycoon
-- requires CombatService and the observer shape exists to keep that arrow
-- one-way.
CombatService.setStructureObserver(Tycoon.siegeStrike)
-- The storage cap's broken-state reader (#98): a smashed unit collapses the
-- cap to its floor, and Economy cannot require Tycoon to ask.
Economy.setStorageIntactHook(function(player)
	local tycoon = PlotService.plotOf(player)
	return tycoon == nil or tycoon:storageIntact()
end)
-- The raid loot loop (#94): a break with an attacker spills into their hands,
-- and RaidService.start hangs the death-drops and banking loops. Same
-- one-way-arrow argument as the two hooks above.
Tycoon.storageBreakObserver = function(tycoon, attacker)
	RaidService.onStorageBroken(tycoon, attacker, os.clock())
end
boot("RaidService", RaidService.start)
-- Helping pays (#123): the boost hook registers, and repairing someone
-- else's plot lands as a kindness credit.
Tycoon.repairObserver = function(tycoon, player)
	HelpService.credit(player, tycoon.owner, "repairs", os.clock())
end
boot("HelpService", HelpService.start)
-- The party (#102): the trust boundary reaches combat and the plot through
-- the same observer shape as everything above.
CombatService.setAllyCheck(PartyService.sameParty)
Tycoon.allyCheck = PartyService.sameParty
boot("PartyService", PartyService.start)
-- Recall (#103): after PlotService, whose teleportToPlot is the arrival.
boot("RecallService", RecallService.start)
-- The tower (#95): after NPCService (it spawns through the minting site) and
-- PartyService (a climb brings the presser's whole party).
boot("TowerService", TowerService.start)
-- Disclosure (#96): the beat that grows each player's interface, and the
-- gate NPCService reads before a plot's first siege.
boot("DisclosureService", DisclosureService.start)
-- The shop (#108): after PlotService, whose plotOf keeps the owned mirrors
-- in step.
boot("ShopService", ShopService.start)
-- Objectives (#97): reads persisted stats on a beat; no ordering needs.
boot("ObjectiveService", ObjectiveService.start)
-- The board and the frontier (#105): a world object on its own beat.
boot("LeaderboardService", LeaderboardService.start)
-- The guide (#100): its mouth is the hint machinery, one arrow, one line.
-- It answers ANY player who talks to it — a visitor gets the owner's guide's
-- flavour, which is a kindness surface, not a leak.
Tycoon.guideSpeaker = function(tycoon, player)
	local profile = DataService.get(player)
	local hint = profile and ObjectiveService.hintFor(profile)
	Economy.notify(player, { kind = "info", title = "Your Tung says",
		body = hint or "Tung tung. The middle pays best. Come back when something new unlocks." })
end
boot("SocialService", SocialService.start)

-- 6. players
local function onCharacterAdded(player: Player, character: Model)
	-- keep players from clipping into the belt machinery on spawn
	character:WaitForChild("HumanoidRootPart", 10)

	-- Respawn on your own plot rather than the arena. Roblox picks the spawn
	-- before we get here, so this is a reposition, not a SpawnLocation: a
	-- per-plot SpawnLocation would land in the random-spawn pool and start
	-- sending other players to your factory.
	task.defer(PlotService.teleportToPlot, player)

	CombatService.onCharacter(player, character)
	UpgradeService.onCharacter(player, character)
	Economy.push(player)
end

local function onPlayerAdded(player: Player)
	DataService.load(player)
	-- BETWEEN load AND SessionService.onPlayer, AND THAT IS NOT A PREFERENCE.
	-- SessionService.onPlayer overwrites profile.lastSeen with os.time() as its
	-- second act, and its per-second tick re-stamps it after that. The previous
	-- logout time is readable exactly once, here, and it is the only input the
	-- `returned` event has. Moving this line below SessionService.onPlayer does
	-- not break anything visibly — it makes every "how long before they came
	-- back" number zero.
	Analytics.onPlayer(player)
	Economy.setupLeaderstats(player)
	Economy.push(player)
	UpgradeService.onPlayer(player)
	SessionService.onPlayer(player)

	player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacterAdded, player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	-- give them a factory right away if one is free
	task.delay(1.5, function()
		if player.Parent and not PlotService.plotOf(player) then
			PlotService.autoAssign(player)
		end
	end)

	Economy.notify(player, {
		kind = "welcome",
		title = "TUNG TUNG TYCOON",
		body = "Buy droppers. Upgrade the tung. Defend the Sahur raid.",
	})
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

print(("[Tung] Tung Tung Tycoon booted in %.2fs — %d plots, %d buttons, %d bats.")
	:format(os.clock() - START, Config.World.PlotCount, #Config.Buttons, #Config.Bats))
