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
	local pad = tycoon.claimPad
	if not pad then
		return
	end
	local lastTouch = 0
	pad.Touched:Connect(function(hit)
		if os.clock() - lastTouch < 0.5 then
			return
		end
		lastTouch = os.clock()
		local player = tycoon:playerFromHit(hit)
		if player then
			PlotService.claim(player, tycoon.index)
		end
	end)
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

	-- Put them in the walking aisle beside the belt, facing the machinery.
	-- x=17 is the clear lane between the dropper bodies (|x| <= 14.5) and the
	-- buy-button pedestals (|x| >= 20.5); the plot frontage is occupied by
	-- the vault, so spawning "at the entrance" would be inside a solid part.
	local character = player.Character
	if character and character.PrimaryPart then
		character:PivotTo(tycoon:at(17, 6, 10) * CFrame.Angles(0, math.rad(90), 0))
	end
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
