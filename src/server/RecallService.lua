--[[
	RecallService.lua — the way home (#103).

	design:D-04. The open world makes the trip home a recurring tax; recall
	pays it with six seconds standing still. The stillness is the whole
	anti-escape design: a caster is a free hit for anything already on them,
	moving or taking damage cancels the cast, and a raid carry blocks it
	outright — stolen Tung walks home (#94's chase must never end in a blink).

	THE LEDGER AND THE CAST ARE SPLIT. tryStart/complete are pure bookkeeping
	over a clock parameter — the cooldown, the carry block — and run headless
	in the spec harness. The cast watch (position drift, health drop) needs a
	character and lives in start()'s handler; the handoff owns proving it in
	Studio. Arrival is PlotService.teleportToPlot, the one placement everyone
	else already uses.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local Economy = Req("Economy")
local RaidService = Req("RaidService")

local Players = game:GetService("Players")

local RecallService = {}

local R = Config.Recall

local cooldownUntil: { [Player]: number } = {}
local casting: { [Player]: boolean } = {}

--- The bookkeeping gate. Returns (ok, reason); the reasons are player-facing.
function RecallService.tryStart(player: Player, now: number): (boolean, string)
	if casting[player] then
		return false, "already recalling"
	end
	if now < (cooldownUntil[player] or 0) then
		return false, ("recall is resting — %ds left"):format(math.ceil((cooldownUntil[player] or 0) - now))
	end
	if RaidService.carriedBy(player) > 0 then
		return false, "not with stolen Tung in your hands — carry it home"
	end
	return true, ""
end

--- Stamps the cooldown. Called on a completed cast, never on a cancelled one
--- — a cancel already cost the standing still.
function RecallService.complete(player: Player, now: number)
	casting[player] = nil
	cooldownUntil[player] = now + R.CooldownSeconds
end

function RecallService.cancel(player: Player)
	casting[player] = nil
end

function RecallService.start()
	-- required here: the spec bundle carries neither PlotService nor a
	-- workspace, and start() is the one function only Roblox calls
	local PlotService = Req("PlotService")

	Net.event("RequestRecall").OnServerEvent:Connect(function(player)
		local now = os.clock()
		local ok, reason = RecallService.tryStart(player, now)
		if not ok then
			Economy.notify(player, { kind = "warn", title = "Recall", body = reason })
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			return
		end

		casting[player] = true
		Economy.notify(player, { kind = "info", title = "Recall",
			body = ("Stand still for %d seconds."):format(R.CastSeconds) })

		local startPosition = root.Position
		local startHealth = humanoid.Health
		task.spawn(function()
			local deadline = now + R.CastSeconds
			while os.clock() < deadline do
				task.wait(0.2)
				if not casting[player] or not player.Parent then
					return
				end
				local liveRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				local liveHumanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				-- moving, dying, respawning or getting hit all cancel; the
				-- cast is a promise to stand there and take it
				if not liveRoot or not liveHumanoid
					or liveHumanoid.Health < startHealth
					or (liveRoot.Position - startPosition).Magnitude > R.CancelMoveStuds then
					RecallService.cancel(player)
					Economy.notify(player, { kind = "warn", title = "Recall",
						body = "Cancelled — you moved, or something hit you." })
					return
				end
			end
			if casting[player] and player.Parent then
				RecallService.complete(player, os.clock())
				PlotService.teleportToPlot(player)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		cooldownUntil[player] = nil
		casting[player] = nil
	end)
end

return RecallService
