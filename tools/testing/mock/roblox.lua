--!nolint
--[[
	roblox.lua — the `game` facade and the services hung off it.

	--!nolint because installing globals IS this file's job, and luau-analyze
	is right to complain about it everywhere else. Same reason
	tools/verify_config.lua carries the same line.

	Everything here is a global the standalone luau CLI does not define, with
	one exception: `os`, which exists and is SHADOWED so the clock can drive
	os.time / os.clock / os.date. That shadow is confirmed to work under the
	CLI; os.date delegates to the real implementation with an explicit
	timestamp rather than reimplementing the civil calendar, which is what
	keeps `wday` correct for the weekend multiplier.
]]

local Mock = {}

-- Gui arrives through `deps`, like Instance and Clock, and NOT through Req.
-- A mock that requires a sibling by name reads as a module; every other mock
-- here is handed what it needs by world.lua, and pass 2 of the verifier fails
-- the build on the free `Req` a require would leave in this file.
local Gui

--- The live world. world.lua swaps this pointer per spec, which is what lets
--- one Lua state host a fresh clock, store and player list for every spec
--- without reloading the bundle.
Mock.current = nil
Mock.errors = {}

function Mock.build(deps)
	Gui = Gui or deps.Gui
	local Clock = deps.Clock
	local Instance = deps.Instance
	local DataStoreService = deps.DataStoreService
	local PlayersMock = deps.Players

	local world = {}
	world.clock = Clock.new(deps.epoch)
	world.warnings = {}
	world.errors = {}

	world.dataStoreService = DataStoreService.new(function()
		return world.clock
	end)
	world.players = PlayersMock.new(Instance)

	world.replicatedStorage = Instance.new("Folder")
	world.replicatedStorage.Name = "ReplicatedStorage"
	world.serverScriptService = Instance.new("Folder")
	world.serverScriptService.Name = "ServerScriptService"
	world.serverStorage = Instance.new("Folder")
	world.serverStorage.Name = "ServerStorage"
	world.workspace = Instance.new("Folder")
	world.workspace.Name = "Workspace"
	world.lighting = Instance.new("Folder")
	world.lighting.Name = "Lighting"

	world.isStudio = false
	world.jobId = ""
	world.bindToClose = {}

	world.runService = {
		IsServer = function() return true end,
		IsClient = function() return false end,
		IsStudio = function() return world.isStudio end,
		IsRunning = function() return true end,
		Heartbeat = Instance.Signal.new(),
		Stepped = Instance.Signal.new(),
		PostSimulation = Instance.Signal.new(),
		PreSimulation = Instance.Signal.new(),
	}

	world.analytics = {
		events = {},
		LogCustomEvent = function(_self, player, name, value, fields)
			table.insert(world.analytics.events, {
				player = player, name = name, value = value, fields = fields,
			})
		end,
		LogEconomyEvent = function(_self, ...)
			table.insert(world.analytics.events, { economy = table.pack(...) })
		end,
	}

	world.soundService = Instance.new("Folder")
	world.soundService.Name = "SoundService"
	world.soundService.RespectFilteringEnabled = true

	world.socialService = {
		invites = {},
		canInvite = true,
		CanSendGameInviteAsync = function(_self, _player)
			return world.socialService.canInvite
		end,
		PromptGameInvite = function(_self, player)
			table.insert(world.socialService.invites, player)
		end,
	}

	local services = {
		DataStoreService = world.dataStoreService,
		Players = world.players,
		RunService = world.runService,
		ReplicatedStorage = world.replicatedStorage,
		ServerScriptService = world.serverScriptService,
		ServerStorage = world.serverStorage,
		Workspace = world.workspace,
		Lighting = world.lighting,
		AnalyticsService = world.analytics,
		SocialService = world.socialService,
		TeleportService = { TeleportAsync = function() end },
		Debris = { AddItem = function() end },
		HttpService = {
			JSONEncode = function(_self, v) return tostring(v) end,
			GenerateGUID = function() return "mock-guid" end,
		},
		TweenService = { Create = function() return { Play = function() end } end },
		CollectionService = {
			AddTag = function() end,
			GetTagged = function() return {} end,
		},
		SoundService = world.soundService,
		PhysicsService = {
			RegisterCollisionGroup = function() end,
			CollisionGroupSetCollidable = function() end,
		},
		ContextActionService = { BindAction = function() end, UnbindAction = function() end },
		UserInputService = {
			TouchEnabled = false,
			KeyboardEnabled = true,
			GamepadEnabled = false,
			InputBegan = Instance.Signal.new(),
		},
		GuiService = {
			GetGuiInset = function()
				return Vector2.new(0, 36), Vector2.new(0, 0)
			end,
		},
		MarketplaceService = {},
		BadgeService = {},
		Chat = {},
		TextService = {},
		StarterGui = { SetCore = function() end },
	}

	world.game = {
		PlaceId = 1234567,
		CreatorId = 1,
		GetService = function(_self, name: string)
			local service = services[name]
			if not service then
				error("mock: no such service " .. tostring(name), 2)
			end
			return service
		end,
		BindToClose = function(_self, fn)
			table.insert(world.bindToClose, fn)
		end,
	}
	setmetatable(world.game, {
		__index = function(_self, key)
			if key == "JobId" then
				return world.jobId
			end
			return nil
		end,
	})

	-- The screen, on top of the world: a Camera, the client-only halves of
	-- RunService, GuiService and UserInputService, and the LocalPlayer helper.
	-- Every world gets them, because a world that only sometimes has a viewport
	-- is a world every spec has to ask about.
	Gui.build(world, services, deps)

	world.services = services
	return world
end

--- Install the globals once, delegating through Mock.current so a later
--- world swap is picked up by already-loaded modules.
function Mock.install(deps)
	Gui = Gui or deps.Gui
	local realDate = os.date
	local realTime = os.time

	-- NOTE: _G is READONLY under the standalone luau CLI. Globals are assigned
	-- directly (which works, and is what verify_config.lua already relies on
	-- for Color3/Vector3/Enum); anything that needs to reach the live world
	-- goes through Mock.current instead of through _G.

	game = setmetatable({}, {
		__index = function(_self, key)
			local w = Mock.current
			if not w then
				error("mock: no world installed — call T.world() first", 2)
			end
			local value = w.game[key]
			if type(value) == "function" then
				return function(_, ...)
					return value(w.game, ...)
				end
			end
			return value
		end,
	})

	workspace = setmetatable({}, {
		__index = function(_self, key)
			return Mock.current and Mock.current.workspace[key] or nil
		end,
	})

	os = {
		time = function(t)
			if t then
				return realTime(t)
			end
			return Mock.current and Mock.current.clock:time() or realTime()
		end,
		clock = function()
			return Mock.current and Mock.current.clock:clockTime() or 0
		end,
		date = function(format, t)
			local epoch = t or (Mock.current and Mock.current.clock:time()) or realTime()
			return realDate(format, epoch)
		end,
		difftime = function(a, b) return a - b end,
	}

	-- `task` has to be re-pointed at the live world's clock on every swap, so
	-- it is a thin forwarder rather than a captured table.
	task = setmetatable({}, {
		__index = function(_self, key)
			local w = Mock.current
			if not w then
				error("mock: no world installed — call T.world() first", 2)
			end
			return w.task[key]
		end,
	})

	wait = function(n) return task.wait(n) end
	spawn = function(fn, ...) return task.spawn(fn, ...) end
	delay = function(n, fn) return task.delay(n, fn) end

	warn = function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		local line = table.concat(parts, " ")
		if Mock.current then
			table.insert(Mock.current.warnings, line)
		end
	end

	Instance = deps.Instance
	Vector3 = deps.Vector3

	Color3 = {
		fromRGB = function(r, g, b) return { r = r, g = g, b = b } end,
		new = function(r, g, b) return { r = r, g = g, b = b } end,
	}
	-- Vector2, Rect, ColorSequence and typeof: see tools/testing/mock/gui.lua.
	-- Vector2 used to be three lines here; it moved because the client needs it
	-- to answer `typeof(x) == "Vector2"`, and that needs a metatable this file
	-- has no other use for.
	Gui.globals(deps)

	UDim = { new = function(s, o) return { Scale = s or 0, Offset = o or 0 } end }
	UDim2 = {
		new = function(sx, ox, sy, oy)
			return { X = UDim.new(sx, ox), Y = UDim.new(sy, oy) }
		end,
		fromOffset = function(x, y) return UDim2.new(0, x, 0, y) end,
		fromScale = function(x, y) return UDim2.new(x, 0, y, 0) end,
	}
	CFrame = setmetatable({
		new = function(x, y, z) return { X = x or 0, Y = y or 0, Z = z or 0 } end,
		Angles = function() return {} end,
		lookAt = function() return {} end,
	}, {})
	-- ENUM ITEMS ARE OBJECTS, NOT STRINGS, AND THAT MATTERS IN ONE PLACE.
	--
	-- Analytics.lua keys its custom fields by
	-- `Enum.AnalyticsCustomFieldKeys.CustomField01.Name`, because that string is
	-- the only key Roblox reads — a field under any other key is discarded with
	-- no error anywhere. A stub returning a plain string has no `.Name`, which
	-- makes the one line that gets this right impossible to test.
	--
	-- Both levels are MEMOIZED so identity is stable: `Enum.A.B == Enum.A.B` has
	-- to stay true, and a fresh table per access would quietly make every enum
	-- comparison in the tree false.
	local enumGroups = {}
	Enum = setmetatable({}, {
		__index = function(_self, group)
			local existing = enumGroups[group]
			if existing then
				return existing
			end
			local items = {}
			local proxy = setmetatable({}, {
				__index = function(_g, name)
					local item = items[name]
					if not item then
						-- `Value` is 0 for EVERY item, and that is a claim rather
						-- than a value: this file does not know the engine's
						-- numbering. It exists because CombatClient does
						-- arithmetic on one — `Enum.RenderPriority.Camera.Value
						-- + 1` — and nil + 1 raises before the camera shake is
						-- ever bound. Nothing may ORDER by it; a spec that
						-- compares two Values is comparing 0 to 0.
						item = setmetatable({ Name = name, EnumType = group, Value = 0 }, {
							__tostring = function() return group .. "." .. name end,
						})
						items[name] = item
					end
					return item
				end,
			})
			enumGroups[group] = proxy
			return proxy
		end,
	})
end

return Mock
