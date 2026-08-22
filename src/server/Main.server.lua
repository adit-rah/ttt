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

-- 4. raids
NPCService.start()

-- 4b. admin chat commands. Self-gating on Config.Admin and on WHO is asking, so
-- this is a no-op for an ordinary player on a live server. After NPCService,
-- because !wave and !clear drive its schedule.
AdminService.start()

-- 5. sessions and the one remaining prototype
UpgradeService.start()
SessionService.start()
-- after SessionService: it registers listeners on plots that are already built
-- and reads the projection SessionService owns
VaultService.start()
-- The gates in the shell's two openings. Anywhere after PlotService.build: it
-- walks Tycoon.all() on its own fixed beat and finds the leaves inside the walls
-- model, so the plots have to exist, but it registers no listener and reacts to
-- no purchase — a gate is a distance test, not an event.
GateService.start()
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
SocialService.start()

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
