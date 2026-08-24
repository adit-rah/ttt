--[[
	MovementClient.lua — sprint and dash, from the player's side (#101).

	KEYBOARD: hold LeftShift to sprint, Q to dash, H to recall (#103). TOUCH:
	buttons docked
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

local PAD = Config.UI.TouchPad

local M = Config.Movement

local function requestRecall()
	-- the intent has no payload; the server owns the cast, the cancel rules
	-- and the cooldown, and it answers through the notify stream
	Net.event("RequestRecall"):FireServer()
end

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
		elseif input.KeyCode == Enum.KeyCode.H then
			requestRecall()
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
		name = "TouchPad", corner = "bottomLeft",
		width = PAD.Width, height = PAD.Height,
		insetY = Config.UI.TouchReserve.Bottom,
		direction = "Vertical",
	})

	-- These were three 64x64 TextButtons built by hand: their own colours off
	-- the palette, no UICorner — the only square buttons in the game — and NO
	-- FONT SET AT ALL, so the three most-pressed controls a phone player has
	-- rendered in the engine's default face while everything else was
	-- FredokaOne. The style lint could not see it, because it greps for
	-- Enum.Font and a missing assignment is not one.
	local function touchTile(name: string, icon: string, caption: string, order: number)
		local tile = UiKit.tile(stack, {
			name = name, variant = "ghost", icon = icon, caption = caption,
		})
		tile.LayoutOrder = order
		return tile
	end

	local homeButton = touchTile("Recall", "home", "HOME", 1)
	local dashButton = touchTile("Dash", "dash", "DASH", 2)
	local sprintButton = touchTile("Sprint", "run", "RUN", 3)
	-- Activated rather than MouseButton1Click, like every other control in the
	-- game: it is the one that also fires for a gamepad, and these three were
	-- the only buttons connecting anything else.
	homeButton.Activated:Connect(requestRecall)

	dashButton.Activated:Connect(function()
		requestDash:FireServer()
	end)

	-- Hold to sprint. `on` rather than a hand-picked highlight colour: it is the
	-- state a control takes while its effect is RUNNING, and it is the same look
	-- the boost button uses for the same reason.
	sprintButton.MouseButton1Down:Connect(function()
		sprint(true)
		UiKit.setControlState(sprintButton, "on")
	end)
	sprintButton.MouseButton1Up:Connect(function()
		sprint(false)
		UiKit.setControlState(sprintButton, "idle")
	end)
end

return MovementClient
