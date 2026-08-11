--[[
	PlotService.lua — owns the Tycoon instances and who is standing on what.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local Tycoon = Req("Tycoon")
local Economy = Req("Economy")

local Players = game:GetService("Players")

local PlotService = {}

local plots: { any } = {}
local byOwner: { [Player]: any } = {}
local reserved: { [number]: { userId: number, until_: number } } = {}

local plotAssigned = Net.event("PlotAssigned")

function PlotService.build(parent: Instance)
	local folder = parent:FindFirstChild("Plots") or parent
	for index = 1, Config.World.PlotCount do
		local tycoon = Tycoon.new(index, folder)
		plots[index] = tycoon
		PlotService.hookClaimPad(tycoon)
	end
end

function PlotService.hookClaimPad(tycoon)
	local lastTouch = 0
	local function onTouch(hit)
		-- cheapest possible early-out: an owned plot ignores touches entirely
		if tycoon.owner then
			return
		end
		if os.clock() - lastTouch < 0.5 then
			return
		end
		lastTouch = os.clock()
		local player = tycoon:playerFromHit(hit)
		if player and not byOwner[player] then
			PlotService.claim(player, tycoon.index)
		end
	end

	-- The marked pad is the affordance, but the ENTIRE plot floor claims an
	-- unclaimed plot. Hunting for a specific tile to stand on is a bad first
	-- thirty seconds, and there is no downside: the plot is free either way.
	for _, part in ipairs({ tycoon.claimPad, tycoon.padPart }) do
		if part then
			part.Touched:Connect(onTouch)
		end
	end
end

--- Puts a player on their own plot. Used on claim and on every respawn, so
--- dying never costs you a walk back across the map.
function PlotService.teleportToPlot(player: Player): boolean
	local tycoon = byOwner[player]
	local character = player.Character
	if not tycoon or not character or not character.PrimaryPart then
		return false
	end
	character:PivotTo(tycoon:ownerSpawnCFrame())
	return true
end

function PlotService.plotOf(player: Player)
	return byOwner[player]
end

local function isReservedForSomeoneElse(index: number, player: Player): boolean
	local hold = reserved[index]
	if not hold then
		return false
	end
	if os.clock() > hold.until_ then
		reserved[index] = nil
		return false
	end
	return hold.userId ~= player.UserId
end

function PlotService.claim(player: Player, index: number): boolean
	if byOwner[player] then
		return false
	end
	local tycoon = plots[index]
	if not tycoon or tycoon.owner then
		return false
	end
	if isReservedForSomeoneElse(index, player) then
		Economy.notify(player, {
			kind = "warn",
			title = "Plot reserved",
			body = "That factory is being held for a player who just disconnected.",
		})
		return false
	end

	reserved[index] = nil
	if not tycoon:assign(player) then
		return false
	end
	byOwner[player] = tycoon

	plotAssigned:FireClient(player, index)
	Economy.notify(player, {
		kind = "claim",
		title = "PLOT " .. index .. " CLAIMED",
		body = "Buy the first dropper to start the tung.",
	})
	Economy.push(player)

	PlotService.teleportToPlot(player)
	return true
end

function PlotService.release(player: Player, hold: boolean?)
	local tycoon = byOwner[player]
	if not tycoon then
		return
	end
	byOwner[player] = nil
	if hold then
		reserved[tycoon.index] = {
			userId = player.UserId,
			until_ = os.clock() + Config.Economy.OfflineGraceSeconds,
		}
	end
	tycoon:release()
end

--- Auto-place a player on the first free plot (used on join for convenience).
function PlotService.autoAssign(player: Player): boolean
	-- honour a reservation from a recent disconnect first
	for index, hold in pairs(reserved) do
		if hold.userId == player.UserId and os.clock() <= hold.until_ then
			if PlotService.claim(player, index) then
				return true
			end
		end
	end
	for index = 1, Config.World.PlotCount do
		local tycoon = plots[index]
		if tycoon and not tycoon.owner and not isReservedForSomeoneElse(index, player) then
			return PlotService.claim(player, index)
		end
	end
	Economy.notify(player, {
		kind = "warn",
		title = "All plots taken",
		body = "Hang out in the arena — a plot frees up when someone leaves.",
	})
	return false
end

function PlotService.rebirth(player: Player)
	local tycoon = byOwner[player]
	if not tycoon then
		return
	end
	tycoon:rebirth(player)
end

function PlotService.start()
	Net.event("RequestRebirth").OnServerEvent:Connect(function(player)
		PlotService.rebirth(player)
	end)

	Net.event("RequestReset").OnServerEvent:Connect(function(player)
		PlotService.release(player, false)
		Economy.notify(player, { kind = "info", title = "Plot released", body = "Your progress is saved. Claim any plot to resume." })
	end)

	Players.PlayerRemoving:Connect(function(player)
		PlotService.release(player, true)
	end)

	-- keep the signage honest
	task.spawn(function()
		while true do
			task.wait(3)
			for _, tycoon in ipairs(plots) do
				local ok, err = pcall(function()
					tycoon:updateSign()
					if tycoon.owner then
						tycoon:refreshButtons()
					end
				end)
				if not ok then
					warn("[Tung] plot refresh error: " .. tostring(err))
				end
			end
		end
	end)
end

return PlotService
