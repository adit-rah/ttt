--[[
	MovementClient.lua — sprint and dash, from the player's side (#101).

	KEYBOARD: hold LeftShift to sprint, Q to dash. TOUCH: two buttons docked
	above the LEFT thumb reserve — movement lives on the movement thumb, and
	the bottom-right stack already belongs to the action buttons. 80% of
	sessions are a phone; the buttons exist for them and never draw on a
	machine without touch.

	THE SPLIT WITH THE SERVER: sprint is one bit of intent up SetSprint (the
	server writes WalkSpeed, because a client's own write does not replicate);
	the dash impulse is applied HERE, on RequestDash's approval echo — the
	client owns its character's assembly, so the burst has to happen on this
	side to feel like one, and the server's echo is the cooldown ledger
	agreeing.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local UiKit = Req("UiKit")
local HUD = Req("HUD")

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local MovementClient = {}

local M = Config.Movement

local function dashImpulse()
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	-- Dash where you are heading, or where you face when standing still — a
	-- dodge you can aim by moving is the combat half of the feature.
	local direction = humanoid.MoveDirection
	if direction.Magnitude < 0.1 then
		direction = root.CFrame.LookVector
	end
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.1 then
		return
	end
	root.AssemblyLinearVelocity = direction.Unit * M.DashSpeed
		+ Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
end

function MovementClient.start()
	local setSprint = Net.event("SetSprint")
	local requestDash = Net.event("RequestDash")

	-- the server's approval echo is what actually moves us
	requestDash.OnClientEvent:Connect(dashImpulse)

	local sprinting = false
	local function sprint(on: boolean)
		if sprinting == on then
			return
		end
		sprinting = on
		setSprint:FireServer(on)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftShift then
			sprint(true)
		elseif input.KeyCode == Enum.KeyCode.Q then
			requestDash:FireServer()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.LeftShift then
			sprint(false)
		end
	end)

	-- TOUCH: above the LEFT reserve, on the movement thumb. Never built on a
	-- machine without touch — an empty frame is still a frame somebody has to
	-- rule out when a layout breaks.
	if not UserInputService.TouchEnabled then
		return
	end

	local stack = UiKit.dock(HUD.root(), {
		name = "Movement", corner = "bottomLeft",
		width = 64, height = 136,
		insetY = Config.UI.TouchReserve.Bottom,
		direction = "Vertical",
	})

	local function touchButton(name, text, order)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.fromOffset(64, 64)
		button.BackgroundColor3 = Color3.fromRGB(30, 26, 44)
		button.BackgroundTransparency = 0.35
		button.Text = text
		button.TextColor3 = Color3.fromRGB(235, 225, 250)
		button.TextSize = 20
		button.BorderSizePixel = 0
		button.LayoutOrder = order
		button.AutoButtonColor = true
		button.Parent = stack
		return button
	end

	local sprintButton = touchButton("Sprint", "RUN", 2)
	local dashButton = touchButton("Dash", "DASH", 1)

	-- hold-to-sprint on touch: down is on, up is off, and the button's colour
	-- carries the state
	sprintButton.MouseButton1Down:Connect(function()
		sprint(true)
		sprintButton.BackgroundColor3 = Color3.fromRGB(90, 70, 150)
	end)
	sprintButton.MouseButton1Up:Connect(function()
		sprint(false)
		sprintButton.BackgroundColor3 = Color3.fromRGB(30, 26, 44)
	end)
	dashButton.MouseButton1Click:Connect(function()
		requestDash:FireServer()
	end)
end

return MovementClient
