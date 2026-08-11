--[[ Main.client.lua — client entry point. ]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))

local HUD = Req("HUD")
local CombatClient = Req("CombatClient")

local StarterGui = game:GetService("StarterGui")

-- the default backpack UI fights with the auto-equip, and we never need it
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

HUD.start()
CombatClient.start()

print("[Tung] client ready")
