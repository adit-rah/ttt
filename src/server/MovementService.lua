--[[
	MovementService.lua — sprint and dash (#101).

	SPRINT IS SERVER-WRITTEN WalkSpeed. A client cannot replicate its own
	WalkSpeed, so the toggle comes up a remote and the server writes the
	humanoid — clamped to exactly two states, walking and Config.Movement's
	SprintSpeed, so the remote carries one bit of intent and nothing a client
	sends can pick a number.

	THE DASH IS CLIENT PHYSICS, SERVER CADENCE. The client owns its
	character's assembly, so the impulse happens there for feel; what the
	server owns is the COOLDOWN — RequestDash answers approved or not, and
	MovementService.dashReady is the ledger any combat system reads when it
	needs to trust dash cadence (#94's escape arithmetic will).

	Sprint interacts with two existing writers of player WalkSpeed:
	CombatService.onCharacter (the baseline, on spawn) and UpgradeService
	(prototype, flag off). Respawn resets to walking here too — a sprint held
	across death would leave the corpse's toggle on the fresh humanoid.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")

local Players = game:GetService("Players")

local MovementService = {}

local M = Config.Movement

-- per-player: { sprinting = boolean, lastDash = seconds }
local state: { [Player]: { sprinting: boolean, lastDash: number } } = {}

local function stateFor(player: Player)
	local s = state[player]
	if not s then
		s = { sprinting = false, lastDash = -math.huge }
		state[player] = s
	end
	return s
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

--- The one WalkSpeed decision: walking or sprinting, nothing a client picks.
function MovementService.setSprint(player: Player, sprinting: boolean)
	local s = stateFor(player)
	s.sprinting = sprinting == true
	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.WalkSpeed = s.sprinting and M.SprintSpeed or Config.Combat.WalkSpeed
	end
end

--- Whether a dash is off cooldown, and the stamp if it is taken. `now` is a
--- parameter so the spec can drive the clock; callers pass os.clock().
function MovementService.tryDash(player: Player, now: number): boolean
	local s = stateFor(player)
	if now - s.lastDash < M.DashCooldown then
		return false
	end
	s.lastDash = now
	return true
end

--- Seconds until this player may dash again — #94's escape arithmetic reads
--- cadence from here rather than trusting the client's word.
function MovementService.dashReady(player: Player, now: number): boolean
	return now - stateFor(player).lastDash >= M.DashCooldown
end

function MovementService.start()
	local setSprint = Net.event("SetSprint")
	local requestDash = Net.event("RequestDash")

	setSprint.OnServerEvent:Connect(function(player, sprinting)
		MovementService.setSprint(player, sprinting == true)
	end)

	requestDash.OnServerEvent:Connect(function(player)
		if MovementService.tryDash(player, os.clock()) then
			-- the approval is the client's cue to fire the impulse; a denied
			-- request answers nothing and the client's local cooldown bar is
			-- what tells the player why
			requestDash:FireClient(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		state[player] = nil
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- a sprint held across death must not ride onto the fresh
			-- humanoid; CombatService.onCharacter writes the walking baseline
			-- and this keeps the ledger agreeing with it
			stateFor(player).sprinting = false
		end)
	end)
end

return MovementService
