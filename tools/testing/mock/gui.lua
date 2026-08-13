--!nolint
--[[
	gui.lua — the screen. The datatypes a GUI is built out of, the services a
	LocalScript reaches for, a Camera with a ViewportSize, and the LocalPlayer
	the whole client hangs off.

	WHY A SECOND FILE AND NOT MORE OF instance.lua. That file is a tree, a Signal
	and attributes, and its header commits to being no more than that. The client
	needs a different set entirely — Vector2, Rect, ColorSequence, a viewport, a
	player with a PlayerGui — and none of it is what a server spec means when it
	asks for an Instance. Kept apart, the server suite's mock stays as small as
	its header says it is.

	--!nolint because installing globals IS this file's job, for the reason
	roblox.lua gives, and because one of them (`typeof`) is a built-in this
	deliberately overwrites.

	A MOCK IS A CLAIM ABOUT ROBLOX THAT ONLY ROBLOX CAN SETTLE. Every line below
	asserts something about an engine this harness cannot run, so the claims are
	named here rather than left implied by whichever spec happens to depend on
	them:

	  1. A GUI INSTANCE IS A PROPERTY BAG. instance.lua accepts any class name and
	     any property, so a TextLabel that ignores TextTruncate and a Frame that
	     ignores AnchorPoint both "work". Nothing here can catch a property that
	     does not exist, a property of the wrong type, or a layout that overlaps —
	     UDim2 is stored, never resolved against a parent. Geometry is
	     tools/verify_config.lua's job and stays there.
	  2. typeof ANSWERS FOR THESE TABLES. Roblox datatypes are userdata; ours are
	     tables, so `typeof(x) == "Vector2"` would be false everywhere and
	     UiKit.safeInsets would silently take its "this client is too old" fallback
	     on every run. typeof is therefore overwritten and answers Vector2, Rect
	     and Vector3 by metatable, delegating for everything else. The claim is
	     that a table tagged this way is indistinguishable from the real datatype
	     to the code under test — true for field reads, false for arithmetic that
	     Vector2 here does not implement.
	  3. THE VIEWPORT IS FIXED. There is one Camera, it is never replaced, and its
	     ViewportSize never changes after HUD.start(). So the
	     GetPropertyChangedSignal("ViewportSize") and ("CurrentCamera")
	     connections are made and never fired: rotation, window resize and Studio's
	     device emulator are all UNCOVERED. A spec sets the size it wants before
	     start() and gets the one applyViewport() call that boot makes.
	  4. THE INSETS ARE PLAUSIBLE, NOT MEASURED. GetGuiInset returns (0,36) and
	     (0,0) — a topbar and no side cutout, which is a desktop. Both are guesses
	     about a device nobody here owns, and topLeft.X is the one that decides
	     the HUD's left gutter, so a spec that wants a notched phone overwrites
	     GetGuiInset itself. TopbarInset is still installed and is read by
	     NOTHING in src/ — it is there for the spec that asserts it stays that
	     way, after its Min.X spent a round being applied as a full-height left
	     gutter and pushing the whole HUD a sixth of the screen inward.
	  5. RunService STILL SAYS IsServer(). The client specs share the server's
	     world, so Net.lua takes its server branch and CREATES the remote folder
	     rather than waiting for it to replicate. That is what lets a spec push a
	     payload down OnClientEvent — and it means the client's own
	     `WaitForChild(name, 30)` branch, and its `remote never replicated` error,
	     are uncovered.
	  6. FRAMES ARE HAND-CRANKED. RenderStepped and Heartbeat only fire when a
	     spec says so (world.render), and BindToRenderStep bindings are recorded
	     and never called. Nothing here proves the engine would call them, or in
	     what order — CombatClient's whole reason for binding after the camera is
	     invisible to this harness.
	  7. NO TWEEN EVER ADVANCES. roblox.lua's TweenService:Create returns
	     something with a Play() that does nothing, and TweenInfo does not exist at
	     all. Every path that tweens is therefore out of reach: HUD.toast, the
	     rebirth modal and the welcome-back modal. Left deliberately absent rather
	     than faked, because a tween mock that jumps to the goal state would make
	     those paths look tested while proving the opposite of what they promise.
	  8. ChildAdded AND CharacterAdded ARE INERT. The LocalPlayer carries both so
	     CombatClient can connect to them, and neither ever fires. Bats arriving in
	     the Backpack, and a respawn mid-swing, are uncovered.
]]

local Gui = {}

-- ── datatypes ───────────────────────────────────────────────────────────────
--
-- UDim, UDim2 and Color3 are NOT here: roblox.lua already installs all three
-- and the client is happy with them. Vector2 moved out of that file into this
-- one so it can carry the metatable claim 2 needs, and it is the only global
-- this file takes over rather than adds.

-- Named V2 / RectType rather than Vector2 / Rect so the assignments in
-- Gui.globals below are unambiguously to the GLOBAL. `Vector2 = Vector2` inside
-- a file with a local of that name assigns the local to itself and installs
-- nothing, silently.
local V2 = {}
V2.__index = V2

function V2.new(x: number?, y: number?)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end

V2.zero = V2.new(0, 0)
V2.one = V2.new(1, 1)

--- The shape GuiService.TopbarInset comes back as: two corners, plus the width
--- and height derived from them. Nothing in src/ reads it any more; hud_spec
--- does, to assert that it does not move the HUD's left edge.
local RectType = {}
RectType.__index = function(self, key)
	if key == "Width" then
		return self.Max.X - self.Min.X
	elseif key == "Height" then
		return self.Max.Y - self.Min.Y
	end
	return rawget(RectType, key)
end

function RectType.new(minX: number, minY: number, maxX: number, maxY: number)
	return setmetatable({ Min = V2.new(minX, minY), Max = V2.new(maxX, maxY) }, RectType)
end

local Sequence = {
	new = function(from, to)
		return { keypoints = { from, to or from } }
	end,
}

Gui.Vector2 = V2
Gui.Rect = RectType

--- Assign the globals the client needs that roblox.lua does not install.
---
--- `deps` is the same table Mock.install receives, so Vector3's metatable is
--- reachable and typeof can answer for it too — which is what CombatClient's
--- knockback guard and Sound.playAt read.
function Gui.globals(deps)
	local tags = {
		[V2] = "Vector2",
		[RectType] = "Rect",
		[deps.Vector3] = "Vector3",
	}
	local realTypeof = typeof

	Vector2 = V2
	Rect = RectType
	ColorSequence = Sequence

	typeof = function(value)
		if type(value) == "table" then
			local tag = tags[getmetatable(value)]
			if tag then
				return tag
			end
		end
		return realTypeof(value)
	end
end

-- ── the client half of a world ──────────────────────────────────────────────

--- Extend a world Mock.build has just finished with everything a LocalScript
--- expects to find, and hang the client-side conveniences off it.
---
--- The conveniences live here rather than in world.lua's join/move/walk block
--- because each one is a fake this file owns: `client()` is the PlayerGui and
--- the Backpack, `render()` is claim 6, `handlerErrors()` is the Signal mock's
--- swallowed errors. Splitting them from the fakes they build would leave two
--- files to read before a client spec makes sense.
function Gui.build(world, services, deps)
	local Instance = deps.Instance

	-- ONE camera, and it is not parented into workspace: world.workspace is a
	-- Folder whose child list several server specs walk, and a Camera in it
	-- would be a mock that changed an unrelated suite's answers. CurrentCamera
	-- is a property, and a property is all the client reads.
	world.camera = Instance.new("Camera")
	world.camera.ViewportSize = V2.new(1280, 720)
	world.workspace.CurrentCamera = world.camera

	-- RenderStepped is the client's heartbeat: the cash counter, the raid
	-- countdown and the hitmarker's expiry all ride it.
	world.runService.RenderStepped = Instance.Signal.new()
	world.renderBindings = {}
	world.runService.BindToRenderStep = function(_self, name: string, priority: number, fn)
		world.renderBindings[name] = { priority = priority, fn = fn }
	end
	world.runService.UnbindFromRenderStep = function(_self, name: string)
		world.renderBindings[name] = nil
	end

	-- Landscape, full width, 36 tall. NOT what a real client returns: on a desktop
	-- Min.X sits past Roblox's own menu and chat buttons, ~165 px in. Left at 0
	-- here so the default world is the simple case, and set to the realistic
	-- shape by the one spec that cares.
	services.GuiService.TopbarInset = RectType.new(0, 0, 1280, 36)
	services.GuiService.IsTenFootInterface = function() return false end

	services.UserInputService.VREnabled = false
	services.UserInputService.MouseEnabled = true

	--- The LocalPlayer, with the two children the client goes looking for.
	---
	--- Players.LocalPlayer is read at MODULE SCOPE by HUD and CombatClient, so
	--- this has to be called BEFORE the first world.req() of a client module —
	--- otherwise `player` is nil in both and every WaitForChild on it fails a
	--- long way from the cause.
	function world.client(name: string?)
		local player = world.players:join(name or "Local")
		world.players.LocalPlayer = player
		Instance.new("PlayerGui", player)
		local backpack = Instance.new("Backpack", player)
		-- claim 8: connected to, never fired
		backpack.ChildAdded = Instance.Signal.new()
		player.ChildAdded = Instance.Signal.new()
		player.CharacterAdded = Instance.Signal.new()
		return player
	end

	function world.playerGui()
		local player = world.players.LocalPlayer
		return player and player:FindFirstChild("PlayerGui")
	end

	--- One frame: `dt` of time passes, then RenderStepped fires with it.
	---
	--- Time first, because that is the order the engine does it in and because
	--- every countdown on that connection reads os.clock() rather than dt.
	function world.render(dt: number?)
		dt = dt or 1 / 60
		world.clock:advance(dt)
		world.runService.RenderStepped:Fire(dt)
	end

	--- Errors raised inside signal handlers since the last call, and cleared.
	---
	--- Roblox swallows an error thrown by a connected handler and so does the
	--- Signal mock. A client spec pushes its payloads through OnClientEvent, so
	--- without this a handler that raises reads as a label that simply did not
	--- change — which is the failure mode this whole family exists to end.
	function world.handlerErrors()
		local errors = Instance.Signal.errors
		local taken = table.clone(errors)
		table.clear(errors)
		return taken
	end
end

return Gui
