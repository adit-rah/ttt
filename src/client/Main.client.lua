--[[ Main.client.lua — client entry point. ]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))

local HUD = Req("HUD")
local CombatClient = Req("CombatClient")

-- The default Backpack CoreGui stays ON: the bat is an ordinary Tool, so
-- Roblox's own hotbar and inventory handle equipping it.
HUD.start()
CombatClient.start()

print("[Tung] client ready")
