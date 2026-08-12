--[[
	players.lua — the Players service and a Player good enough to be tested.

	MaxPlayers is not decoration. Config.lua:1409 runs

		Config.World.PlotCount = Config.plotCountFor()

	AT MODULE LOAD, and that reaches for game:GetService("Players").MaxPlayers
	inside a pcall. verify_config.lua gets the fallback because it has no
	`game` at all; the harness HAS one, so if MaxPlayers is not a number here
	the specs would silently run against different plot geometry than the
	verifier does. Same Config, two answers, no error.
]]

local Instance = nil   -- injected by world.lua to avoid a require cycle

local Players = {}
Players.__index = Players

local nextUserId = 100

function Players.new(instanceMock)
	Instance = instanceMock
	local self = setmetatable({
		-- Players is a service rather than an Instance here, but a Player's
		-- Parent is set to it, and the Instance mock maintains a child list on
		-- whatever it is parented to. Give it one.
		_children = {},
		_players = {},
		MaxPlayers = 10,          -- matches Config.World.MaxPlots
		CharacterAutoLoads = true,
		PlayerAdded = Instance.Signal.new(),
		PlayerRemoving = Instance.Signal.new(),
	}, Players)
	return self
end

function Players:GetPlayers()
	return table.clone(self._players)
end

function Players:GetPlayerByUserId(userId: number)
	for _, player in ipairs(self._players) do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

function Players:GetPlayerFromCharacter(character)
	for _, player in ipairs(self._players) do
		if player.Character == character then
			return player
		end
	end
	return nil
end

--- Build a Player and announce it, the way a real join does.
function Players:join(name: string, userId: number?)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name
	player.UserId = userId or nextUserId
	player.DisplayName = name
	player.Parent = self
	player.kicked = nil
	player.Kick = function(_self, reason: string?)
		_self.kicked = reason or ""
	end
	-- IsFriendsWith is stubbed here so the social specs can drive it without a
	-- second mock; world.lua sets `friendsWith` per spec.
	player.IsFriendsWith = function(_self, otherId: number)
		local set = _self.friendsWith or {}
		return set[otherId] == true
	end
	table.insert(self._players, player)
	self.PlayerAdded:Fire(player)
	return player
end

function Players:leave(player)
	for index, existing in ipairs(self._players) do
		if existing == player then
			table.remove(self._players, index)
			break
		end
	end
	-- SessionService's tick reaps entries by reading player.Parent, so this
	-- must actually go nil or dead sessions accumulate and the spec lies.
	player.Parent = nil
	self.PlayerRemoving:Fire(player)
end

--- The rig the playtime ladder's activity gate reads: a HumanoidRootPart with
--- a real Vector3 Position, and a Humanoid with a MoveDirection.
function Players:spawnCharacter(player, Vector3Mock)
	local character = Instance.new("Model")
	character.Name = player.Name

	local root = Instance.new("Part", character)
	root.Name = "HumanoidRootPart"
	root.Position = Vector3Mock.new(0, 5, 0)

	local humanoid = Instance.new("Humanoid", character)
	humanoid.Name = "Humanoid"
	humanoid.Health = 100
	humanoid.MaxHealth = 100
	humanoid.MoveDirection = Vector3Mock.new(0, 0, 0)
	humanoid.WalkSpeed = 22

	player.Character = character
	return character
end

return Players
