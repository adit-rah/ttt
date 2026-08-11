--[[
	CombatClient.lua — local feel for combat: hitmarkers, camera shake and
	knockback. Damage itself is entirely server-side, and equipping is handled
	by Roblox's built-in Backpack.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Net = Req("Net")
local HUD = Req("HUD")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local CombatClient = {}

local shake = 0

local function buildHitmarker(gui: ScreenGui)
	local marker = Instance.new("Frame")
	marker.Name = "Hitmarker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.fromScale(0.5, 0.5)
	marker.Size = UDim2.fromOffset(44, 44)
	marker.BackgroundTransparency = 1
	marker.Visible = false
	marker.Parent = gui

	for i, rot in ipairs({ 45, -45 }) do
		for j, offset in ipairs({ -1, 1 }) do
			local tick = Instance.new("Frame")
			tick.Name = ("Tick%d_%d"):format(i, j)
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Size = UDim2.fromOffset(16, 4)
			tick.Position = UDim2.fromScale(0.5, 0.5)
			tick.BackgroundColor3 = Color3.fromRGB(255, 245, 200)
			tick.BorderSizePixel = 0
			tick.Rotation = rot
			tick.Parent = marker
			local dx = math.cos(math.rad(rot)) * 16 * offset
			local dy = math.sin(math.rad(rot)) * 16 * offset
			tick.Position = UDim2.new(0.5, dx, 0.5, dy)
		end
	end

	return marker
end

function CombatClient.start()
	local gui = HUD.screenGui()
	if not gui then
		return
	end

	local marker = buildHitmarker(gui)
	local hideAt = 0

	Net.event("HitFeedback").OnClientEvent:Connect(function(payload)
		marker.Visible = true
		hideAt = os.clock() + 0.16
		for _, tick in ipairs(marker:GetChildren()) do
			if tick:IsA("Frame") then
				tick.BackgroundColor3 = payload.killed and Color3.fromRGB(255, 120, 90) or Color3.fromRGB(255, 245, 200)
			end
		end
		shake = math.min(shake + (payload.killed and 1.1 or 0.55), 2)
	end)

	-- knockback is applied here, not on the server: this client owns its own
	-- character's physics, so a server-side impulse would just be overwritten
	Net.event("Knockback").OnClientEvent:Connect(function(impulse)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and typeof(impulse) == "Vector3" then
			root:ApplyImpulse(impulse)
		end
	end)

	RunService.RenderStepped:Connect(function()
		if marker.Visible and os.clock() > hideAt then
			marker.Visible = false
		end
	end)

	-- The default camera module writes Camera.CFrame from a bound render step
	-- at Enum.RenderPriority.Camera. Shaking on RenderStepped runs BEFORE that
	-- and gets thrown away, so bind after the camera instead.
	RunService:BindToRenderStep("TungCameraShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if shake <= 0.001 then
			return
		end
		shake = math.max(0, shake - dt * 5)
		local magnitude = shake * 0.6
		local activeCamera = workspace.CurrentCamera
		if activeCamera then
			activeCamera.CFrame = activeCamera.CFrame * CFrame.Angles(
				math.rad((math.random() - 0.5) * magnitude),
				math.rad((math.random() - 0.5) * magnitude),
				math.rad((math.random() - 0.5) * magnitude)
			)
		end
	end)

	-- No custom swing button and no auto-equip: the bat is a plain Tool, so
	-- Roblox's built-in hotbar equips it and its built-in activation (click,
	-- tap, or the mobile fire button) triggers Tool.Activated for us.
end

return CombatClient
