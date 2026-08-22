--[[ Main.client.lua — client entry point. ]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))

local Net = Req("Net")
local Util = Req("Util")

local HUD = Req("HUD")
local CombatClient = Req("CombatClient")
local MovementClient = Req("MovementClient")
local UpgradeUI = Req("UpgradeUI")
local SessionUI = Req("SessionUI")

-- The default Backpack CoreGui stays ON: the bat is an ordinary Tool, so
-- Roblox's own hotbar and inventory handle equipping it.
HUD.start()
CombatClient.start()
MovementClient.start()

-- Prototype panels. Both return immediately unless their Config.Prototypes
-- flag is on.
UpgradeUI.start()
SessionUI.start()

-- THE ONE THING THE SERVER CANNOT WORK OUT FOR ITSELF.
--
-- Roblox has no server-side device API, so the analytics layer's platform label
-- has to come from here. Fired ONCE, immediately: the server holds the session's
-- three join events open waiting for it and gives up after ten seconds, because
-- a logged event cannot be edited afterwards.
--
-- The ladder is Util.platformFrom and the ORDER inside it is the whole point —
-- a VR headset and a console can both report TouchEnabled, so asking touch first
-- files every headset in the game under "mobile" and the chart looks fine. The
-- server re-validates whatever this sends against the declared set, because a
-- client can say anything; nothing in the game is gated on the answer.
task.spawn(function()
	local UIS = game:GetService("UserInputService")
	local GuiService = game:GetService("GuiService")

	local tenFoot = false
	pcall(function()
		tenFoot = GuiService:IsTenFootInterface()
	end)

	local viewportX = 0
	local camera = workspace.CurrentCamera
	if camera then
		viewportX = camera.ViewportSize.X
	end

	Net.event("ClientHello"):FireServer({
		platform = Util.platformFrom({
			vr = UIS.VREnabled,
			tenFoot = tenFoot,
			touch = UIS.TouchEnabled,
			keyboard = UIS.KeyboardEnabled,
			mouse = UIS.MouseEnabled,
			viewportX = viewportX,
		}),
	})
end)

print("[Tung] client ready")
