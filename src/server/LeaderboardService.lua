--[[
	LeaderboardService.lua — the board by the spawn, and the frontier (#105).

	design:D-01. The leaderboard is a WORLD OBJECT — screen space is reserved
	for what is true wherever the player stands, and a board people gather at
	is a social surface a panel is not. Server-level, ranked on Tung, top
	five, repainted on a slow beat.

	THE FRONTIER IS TOLD THE TRUTH. A player who owns every button at the
	rebirth cap has finished what exists; hiding that abandons them, so the
	moment is detected, told to them plainly with their rank, announced to
	the server once, and STAMPED into profile.frontier — the stamp is the
	telemetry, because the players who run out of game are the ones worth
	talking to. Rank only: no currency, no sink, no boost, per the issue.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Style = Req("Style")
local Economy = Req("Economy")
local DataService = Req("DataService")

local Players = game:GetService("Players")

local LeaderboardService = {}

local boardLabel

--- Present players, richest first.
function LeaderboardService.standings()
	local rows = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(rows, { player = player, cash = Economy.get(player) })
	end
	table.sort(rows, function(a, b)
		return a.cash > b.cash
	end)
	return rows
end

--- This player's 1-based rank on the server.
function LeaderboardService.rankOf(player): number
	for rank, row in ipairs(LeaderboardService.standings()) do
		if row.player == player then
			return rank
		end
	end
	return #Players:GetPlayers()
end

--- Out of game: every button owned, at the rebirth cap.
function LeaderboardService.isFrontier(profile): boolean
	if (profile.rebirths or 0) < Config.Rebirth.MaxRebirths then
		return false
	end
	for _, def in ipairs(Config.Buttons) do
		if not profile.owned[def.id] then
			return false
		end
	end
	return true
end

--- Stamps and announces the frontier, exactly once per account.
function LeaderboardService.checkFrontier(player, now: number): boolean
	local profile = DataService.get(player)
	if not profile or (profile.frontier or 0) ~= 0 or not LeaderboardService.isFrontier(profile) then
		return false
	end
	profile.frontier = now
	Economy.notify(player, { kind = "boss", title = "THE FRONTIER",
		body = ("You have bought everything that exists. Rank #%d on this server. More game is coming; you finished this one.")
			:format(LeaderboardService.rankOf(player)) })
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			Economy.notify(other, { kind = "boss", title = "THE FRONTIER",
				body = ("%s has reached the edge of what exists."):format(player.DisplayName) })
		end
	end
	print(("[Tung] FRONTIER: %s (%d) at %d"):format(player.Name, player.UserId, now))
	return true
end

local function paintBoard()
	if not boardLabel then
		return
	end
	local lines = { "TOP TUNG" }
	for rank, row in ipairs(LeaderboardService.standings()) do
		if rank > 5 then
			break
		end
		local profile = DataService.get(row.player)
		local star = (profile and (profile.frontier or 0) ~= 0) and "  ★" or ""
		table.insert(lines, ("%d. %s  •  %s%s"):format(
			rank, row.player.DisplayName, Util.abbreviate(row.cash), star))
	end
	boardLabel.Text = table.concat(lines, "\n")
end

local function buildBoard()
	local bearing = math.pi / math.max(Config.plotCountFor(), 1)
	local base = Vector3.new(
		math.sin(bearing) * (Config.World.SpawnRadius + 24),
		Config.World.GroundTopY,
		math.cos(bearing) * (Config.World.SpawnRadius + 24))

	local model = Instance.new("Model")
	model.Name = "Leaderboard"
	local post = Instance.new("Part")
	post.Name = "Post"
	post.Size = Vector3.new(1.5, 10, 1.5)
	post.CFrame = CFrame.new(base + Vector3.new(0, 5, 0))
	post.Anchored = true
	post.Color = Color3.fromRGB(70, 52, 40)
	post.Material = Enum.Material.Wood
	post.Parent = model
	local board = Instance.new("Part")
	board.Name = "Board"
	board.Size = Vector3.new(12, 7, 0.8)
	board.CFrame = CFrame.new(base + Vector3.new(0, 11, 0))
		* CFrame.Angles(0, bearing + math.pi, 0)
	board.Anchored = true
	board.Color = Color3.fromRGB(24, 18, 34)
	board.Material = Enum.Material.SmoothPlastic
	board.Parent = model
	model.Parent = workspace

	local billboard = Style.billboard(board, {
		name = "Standings", width = 22, height = 12, distance = "prop", offset = 1,
	})
	boardLabel = Style.text(billboard, {
		name = "Rows", text = "TOP TUNG",
		color = Color3.fromRGB(255, 236, 180),
	})
end

function LeaderboardService.start()
	buildBoard()
	task.spawn(function()
		while true do
			task.wait(10)
			local ok, err = pcall(function()
				paintBoard()
				for _, player in ipairs(Players:GetPlayers()) do
					LeaderboardService.checkFrontier(player, os.time())
				end
			end)
			if not ok then
				warn("[Tung] leaderboard error: " .. tostring(err))
			end
		end
	end)
end

return LeaderboardService
