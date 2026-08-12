--[[
	world.lua — T.world(), the per-spec sandbox.

	Each spec gets a fresh clock, a fresh DataStore, a fresh player list and a
	fresh REALM — its own load of the module tree, with its own Config table
	and its own DataService upvalues. The mocks underneath are per-world but the
	globals are installed once, delegating through Mock.current, which world()
	swaps.

	Two realms over ONE world is what makes the session-locking specs possible:
	two independent DataService instances racing a single DataStore key, which
	is exactly the production failure nobody has ever been able to reproduce.

	FLAGS. Config.Prototypes ships all-false and tools/verify_config.lua
	asserts it, so the harness flips them at runtime instead. That works
	because SessionService captures `local P = Config.Prototypes` — a
	REFERENCE — and reads P.Offline at call time, so flipping after load is
	enough, as long as it happens before start().
]]

local World = {}

function World.install(T, req)
	local Clock = req("clock")
	local Vector3Mock = req("vector3")
	local Instance = req("instance")
	local DataStoreService = req("datastore")
	local PlayersMock = req("players")
	local Mock = req("roblox")

	Mock.install({ Instance = Instance, Vector3 = Vector3Mock })

	T.worlds = {}
	T.executed = {}

	local function record(name: string)
		for _, existing in ipairs(T.executed) do
			if existing == name then
				return
			end
		end
		table.insert(T.executed, name)
	end

	--- A fresh world plus a fresh realm.
	function T.world(opts)
		opts = opts or {}
		local world = Mock.build({
			Clock = Clock,
			Instance = Instance,
			DataStoreService = DataStoreService,
			Players = PlayersMock,
			epoch = opts.epoch,
		})
		world.task = world.clock:taskLibrary()
		Mock.current = world
		T.worldRef = world
		table.insert(T.worlds, world)

		local realmReq = T.newRealm()

		--- Load a game module inside this realm. Recorded, so the report can
		--- print WHICH modules actually executed — the line that answers five
		--- handoffs' worth of "nothing has run in Roblox".
		function world.req(name: string)
			record(name)
			return realmReq(name)
		end

		world.config = world.req("Config")

		-- convenience passthroughs, so specs read as prose
		function world.join(name: string, userId: number?)
			return world.players:join(name, userId)
		end
		function world.leave(player)
			return world.players:leave(player)
		end
		function world.spawnCharacter(player)
			return world.players:spawnCharacter(player, Vector3Mock)
		end
		function world.move(player, dx: number, dz: number)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root then
				root.Position = root.Position + Vector3Mock.new(dx, 0, dz)
			end
		end
		function world.walk(player, on: boolean)
			local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
			if humanoid then
				humanoid.MoveDirection = Vector3Mock.new(on and 1 or 0, 0, 0)
			end
		end
		function world.store()
			return world.dataStoreService:GetDataStore("TungTungTycoon_v1")
		end
		function world.shutdown()
			for _, fn in ipairs(world.bindToClose) do
				world.task.spawn(fn)
			end
			world.clock:advance(26)
		end
		--- A SECOND realm over the same world: a second "server".
		--- Set world.jobId before calling, so the two disagree about identity.
		function world.realm()
			local otherReq = T.newRealm()
			return { req = otherReq, config = otherReq("Config") }
		end

		return world
	end

	--- Shorthand: a world with the two retention prototypes graduated.
	function T.retention(opts)
		opts = opts or {}
		local world = T.world(opts)
		if opts.offline ~= false then
			world.config.Prototypes.Offline = true
		end
		if opts.sessions ~= false then
			world.config.Prototypes.Sessions = true
		end
		return world
	end
end

return World
