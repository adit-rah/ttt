--[[
	CombatClient.lua — local feel for combat: hitmarkers, camera shake and
	knockback. Damage itself is entirely server-side, and equipping is handled
	by Roblox's built-in Backpack.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local HUD = Req("HUD")
local SwingAnim = Req("SwingAnim")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local CombatClient = {}

local shake = 0

--- The crosshair flash on a landed hit.
---
--- It goes in HUD.root(), not in the ScreenGui itself. Parenting straight to the
--- ScreenGui puts it outside the UIScale AND outside the safe-area padding — the
--- exact failure the one-ScreenGui lint exists to prevent, reached through a
--- different door, because nothing had to make a second ScreenGui to get there.
--- A 44x44 marker at MinScale would have drawn 44 physical pixels on a phone
--- while every other 44 in the game drew 27.
local function buildHitmarker(root: Instance)
	local marker = Instance.new("Frame")
	marker.Name = "Hitmarker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.fromScale(0.5, 0.5)
	marker.Size = UDim2.fromOffset(44, 44)
	marker.BackgroundTransparency = 1
	marker.Visible = false
	marker.Parent = root

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

-- ─────────────────────────────────────────────────────────────────────────────
-- swings
--
-- The server is still the only thing that decides whether a swing HIT. All we
-- do here is draw it, and draw our own immediately instead of waiting for the
-- round trip — a wind-up that starts 100ms after the click feels broken even
-- though the damage timing is identical.
-- ─────────────────────────────────────────────────────────────────────────────

local localSwing = { at = 0, combo = 0 }

--- Mirrors the server's combo bookkeeping in CombatService.swing. A drifted
--- prediction only ever picks the wrong swing ANIMATION, never the wrong
--- damage, so it is allowed to be approximate.
local function predictSwing(tool: Tool)
	local now = os.clock()
	local cooldown = tool:GetAttribute("Cooldown") or 0.55
	if now - localSwing.at < cooldown then
		return
	end
	if now - localSwing.at <= Config.Combat.ComboWindow then
		localSwing.combo = (localSwing.combo + 1) % (Config.Combat.ComboMaxStacks + 1)
	else
		localSwing.combo = 0
	end
	localSwing.at = now
	SwingAnim.play(player.Character, localSwing.combo + 1, cooldown)
end

local watched: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function watchTool(tool: Instance)
	-- A tool moves Backpack -> Character on equip and back on unequip, so it
	-- turns up in ChildAdded on both containers. Connect once.
	if watched[tool] or not tool:IsA("Tool") or not tool:GetAttribute("BatId") then
		return
	end
	watched[tool] = true
	tool.Activated:Connect(function()
		predictSwing(tool)
	end)
end

--- Bats are handed out by the server into the Backpack, and moved into the
--- character on equip, so watch both containers and everything already in them.
local function watchBats()
	local function attach(container: Instance?)
		if not container then
			return
		end
		container.ChildAdded:Connect(watchTool)
		for _, child in ipairs(container:GetChildren()) do
			watchTool(child)
		end
	end

	attach(player:FindFirstChildOfClass("Backpack"))
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			attach(child)
		end
	end)

	local function onCharacter(character: Model)
		SwingAnim.stop(character)
		localSwing.combo = 0
		attach(character)
	end
	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
end

function CombatClient.start()
	local root = HUD.root()
	if not root then
		return
	end

	local marker = buildHitmarker(root)
	local hideAt = 0

	Net.event("HitFeedback").OnClientEvent:Connect(function(payload)
		marker.Visible = true
		hideAt = os.clock() + 0.16
		for _, tick in ipairs(marker:GetChildren()) do
			if tick:IsA("Frame") then
				tick.BackgroundColor3 = payload.killed and Color3.fromRGB(255, 120, 90)
					or payload.crit and Color3.fromRGB(255, 190, 90)
					or Color3.fromRGB(255, 245, 200)
			end
		end
		shake = math.min(shake + (payload.killed and 1.1 or payload.crit and 0.85 or 0.55), 2)
		-- Stopping the arc dead for two or three frames is most of what makes a
		-- hit feel like it connected with something solid.
		SwingAnim.hitStop(player.Character, Config.Combat.HitStop)
	end)

	-- Everyone else's swings. Motor6D.Transform is a local visual, so each
	-- client draws every character's swing itself; skip our own, which we
	-- already predicted on Tool.Activated.
	Net.event("SwingFx").OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or not payload.character then
			return
		end
		-- Skip our own swing only if we really did predict it. The two cooldown
		-- gates run on different clocks, so a pair of clicks near the boundary
		-- can be refused locally and accepted by the server — and an
		-- unconditional skip would leave the attacker dealing damage with no
		-- swing drawn at all.
		if payload.character == player.Character and (os.clock() - localSwing.at) < 0.3 then
			return
		end
		SwingAnim.play(payload.character, payload.combo or 1, payload.duration or 0.5)
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
	-- tap, or the mobile fire button) triggers Tool.Activated for us — on the
	-- client as well as on the server, which is what makes local prediction
	-- free rather than something we'd have to send a remote for.
	SwingAnim.start()
	watchBats()
end

return CombatClient
