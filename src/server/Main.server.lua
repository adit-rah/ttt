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
local Economy = Req("Economy")
local CombatService = Req("CombatService")
local PlotService = Req("PlotService")
local NPCService = Req("NPCService")

local Players = game:GetService("Players")

local START = os.clock()

Players.CharacterAutoLoads = true

-- 1. world
local world = MapBuilder.build()

-- 2. services
DataService.start()
Economy.start()
CombatService.start()

-- 3. plots
PlotService.build(world)
PlotService.start()

-- 4. raids
NPCService.start()

-- 5. players
local function onCharacterAdded(player: Player, character: Model)
	-- keep players from clipping into the belt machinery on spawn
	character:WaitForChild("HumanoidRootPart", 10)
	CombatService.onCharacter(player, character)
	Economy.push(player)
end

local function onPlayerAdded(player: Player)
	DataService.load(player)
	Economy.setupLeaderstats(player)
	Economy.push(player)

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
