--[[
	GateService.lua — the doors in the shell, and the one loop that opens them.

	The shell has two deliberate openings: the front gateway you walk in through
	and the cut in the back wall onto the generator yard. Until this round they
	were holes. They have leaves now — one for the yard door, a pair for the
	gateway — and they slide out of the way when somebody walks up to them.

	Three decisions that look arbitrary and are not:

	  A DISTANCE TEST, NOT Touched/TouchEnded. This is the same trap the teleport
	  pads were deleted for. A character standing on a trigger bounces off its own
	  physics jitter, firing Touched and TouchEnded over and over, and the pads
	  needed a cooldown, an arrival lock and a TouchEnded sweep to paper over it —
	  about a hundred lines to notice somebody was standing there.
	  Config.Floors[1].ladder's comment is the long version. A gate asked "is
	  anybody within triggerRadius" on a fixed beat cannot bounce, because there
	  is no event to bounce.

	  ONE LOOP FOR THE WHOLE SERVER, not one per plot. Ten plots x
	  1 / Gate.tickRate is fifty coroutine wakeups a second to move at most three
	  parts. This walks Tycoon.all() from a single loop and skips a plot that has
	  no owner or has not bought the walls yet, so an empty server does nothing at
	  all.

	  IT HOLDS NO REFERENCE IT TRUSTS. Gate leaves are built into the walls model
	  in self.machines, and release() and rebirth() both do
	  machines:ClearAllChildren() — so a leaf can vanish under this service
	  between two ticks. Every tick checks Parent and re-resolves, exactly as
	  Tycoon:updateCabinetSigns drops a sign whose cabinet has been taken down.

	WHERE THE GEOMETRY LIVES: not here. Tycoon:gateLeafSpecs (tycoon/Installers.lua)
	answers what a leaf is called, where it hangs closed and where it slides to,
	and the walls branch builds from the same list. Two copies of "one leaf width
	along the wall, away from the opening centre" is two answers the day either
	wall moves.

	THE GATE ANSWERS TO ITS OWNER, nobody else. Since #89 hostile things do
	reach gates — a plot wave stands at yours, and PvP raiders walk up to
	anyone's — so a door that opened for any nearby humanoid would hand both
	of them a free entrance and gut #124's break-in verb. Opening on the
	owner's own proximity keeps the plot usable and makes letting a fight in
	through your own door a choice. NPCs never open anything: the position
	sweep below reads Players, and mobs get in by breaking things.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Tycoon = Req("Tycoon")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local GateService = {}

local GATE = Config.Structure.Gate

-- Eased out rather than linear: a door that decelerates into its stop reads as a
-- door, and a linear slide reads as a part being moved by a script.
local TRAVEL = TweenInfo.new(GATE.travelTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--- The button that builds the walls, found by WHAT IT BUILDS rather than by id.
--- The leaves are part of the walls model, so before that purchase there is
--- nothing on the plot to look for and no reason to look every fifth of a second
--- for the whole session.
local WALLS_BUTTON = (function(): string?
	for _, def in ipairs(Config.Buttons) do
		if def.kind == "Structure" and def.structure == "walls" then
			return def.id
		end
	end
	return nil
end)()

-- one entry per plot: { openings = { { centre, leaves = { { spec, part, open, tween } } } } }
local state: { [any]: any } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- what a plot's gates are
-- ─────────────────────────────────────────────────────────────────────────────

--- Grouped BY OPENING, because the distance test is per opening and the tween is
--- per leaf: the gateway's two leaves answer one question between them.
---
--- Cached per plot for the life of the server. The specs are pure arithmetic over
--- Config and the plot's own CFrame, neither of which changes — what changes is
--- whether the parts they name are standing, and that is resolved every tick.
local function stateFor(tycoon)
	local entry = state[tycoon]
	if entry then
		return entry
	end

	local openings, byId = {}, {}
	for _, spec in ipairs(tycoon:gateLeafSpecs()) do
		local opening = byId[spec.opening]
		if not opening then
			opening = { centre = spec.centre, leaves = {} }
			byId[spec.opening] = opening
			table.insert(openings, opening)
		end
		table.insert(opening.leaves, { spec = spec, part = nil, open = false, tween = nil })
	end

	entry = { openings = openings }
	state[tycoon] = entry
	return entry
end

--- The leaf part, if it is still standing.
---
--- A leaf that has gone (release, rebirth) drops its cached state with it: the
--- replacement is a NEW part built closed, so remembering that the old one was
--- open would leave a gate that never opens again and never says why.
local function resolve(tycoon, leaf)
	local part = leaf.part
	if part and part.Parent then
		return part
	end
	leaf.part = tycoon.machines:FindFirstChild(leaf.spec.name, true)
	leaf.open = false
	leaf.tween = nil
	return leaf.part
end

--- Slides one leaf, and only if it is not already going there. Re-tweening a leaf
--- every tick while somebody stands in the doorway restarts the animation five
--- times a second, which looks like a stuck door.
local function setLeaf(leaf, part: BasePart, open: boolean)
	if leaf.open == open then
		return
	end
	leaf.open = open
	-- Cancel rather than overlap. TweenService does not replace a running tween on
	-- the same property; both keep writing CFrame and whichever ran last that
	-- frame wins, so a leaf reversed mid-travel would stutter between the two
	-- targets instead of turning round.
	if leaf.tween then
		leaf.tween:Cancel()
	end
	leaf.tween = TweenService:Create(part, TRAVEL, {
		CFrame = open and leaf.spec.open or leaf.spec.closed,
	})
	leaf.tween:Play()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the loop
-- ─────────────────────────────────────────────────────────────────────────────

--- Every player's root position, WITH its player, collected once per tick.
---
--- Once, because the alternative is a Character/HumanoidRootPart lookup per
--- opening per plot: ten players against twenty openings is the same two hundred
--- distance tests either way round, but ten instance walks instead of two
--- hundred. Players rather than every Humanoid in the workspace on purpose:
--- an NPC must never open a gate — mobs get in by breaking things.
local function rootPositions(): { { player: Player, position: Vector3 } }
	local roots = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(roots, { player = player, position = root.Position })
		end
	end
	return roots
end

local function ownerNear(roots, owner: Player, centre: Vector3): boolean
	for _, entry in ipairs(roots) do
		if entry.player == owner and (entry.position - centre).Magnitude <= GATE.triggerRadius then
			return true
		end
	end
	return false
end

--- Opens or closes one plot's gates to match where its OWNER is standing.
function GateService.sync(tycoon, roots)
	for _, opening in ipairs(stateFor(tycoon).openings) do
		local wanted = ownerNear(roots, tycoon.owner, opening.centre)
		for _, leaf in ipairs(opening.leaves) do
			local part = resolve(tycoon, leaf)
			if part then
				setLeaf(leaf, part, wanted)
			end
		end
	end
end

--- One beat for every gate in the game.
function GateService.tick()
	local roots = rootPositions()
	for _, tycoon in ipairs(Tycoon.all()) do
		-- An unclaimed plot has no walls standing and nobody to open them for;
		-- a claimed plot that has not bought the walls has no leaves to find.
		if tycoon.owner ~= nil and (WALLS_BUTTON == nil or tycoon.owned[WALLS_BUTTON] == true) then
			GateService.sync(tycoon, roots)
		end
	end
end

function GateService.start()
	if #Config.Structure.Openings == 0 then
		return
	end
	task.spawn(function()
		while true do
			task.wait(GATE.tickRate)
			-- pcall'd so one plot's bad state cannot end the loop for the other
			-- nine and leave every gate in the game frozen where it was
			local ok, err = pcall(GateService.tick)
			if not ok then
				warn("[Tung] gate tick error: " .. tostring(err))
			end
		end
	end)
end

return GateService
