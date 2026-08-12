--[[
	tycoon/Parts.lua — every Part on a plot is made here, and the description a
	belt machine's masses are built from.

	newPart is the plot's one part constructor: anchored, smooth surfaces,
	collidable unless told otherwise. The aggregator re-exports it as
	`Tycoon.part` because FloorService builds its deck out of the same defaults,
	and a second near-identical local copy that drifts is what that re-export
	prevents.

	MACHINE_MASSES exists so the GHOST PREVIEW and the real machine are built
	from ONE description — buildMasses below, buildGhost in tycoon/Buttons.lua.
	A silhouette hand-copied from the installer stops matching the machine the
	first time either is touched.

	It reads a def's `kind` and nothing else about it. Which def gets built, and
	when, belongs to Buttons and Installers; the offsets and heights belong to
	Config.Layout, so a mass sized from a literal here is a mass the verifier
	cannot check against the belt it hangs over.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Tycoon = Req("Class")

local L = Config.Layout

local Parts = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- construction helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function newPart(parent, name, size, cf, color, material, collide)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = collide ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- ── machine geometry ─────────────────────────────────────────────────────────

--- The masses a belt machine is made of: { name, size, offset, y, collide }.
--- Offset is outboard of the belt, y is the centre height, both in the leg's
--- own frame (see Tycoon:segmentCF).
---
--- This exists so the GHOST PREVIEW and the real machine are built from one
--- description. A silhouette hand-copied from the installer is a silhouette
--- that stops matching the machine the first time either is touched.
local MACHINE_MASSES = {
	Dropper = function()
		-- Sized to Layout.MachineFootprint so neighbouring droppers can never
		-- overlap. The arm hangs directly over the running surface, so it is
		-- non-collidable: a tall drop has to pass under it untouched.
		local depth = L.MachineFootprint
		return {
			{ "Base", Vector3.new(depth, 3.6, depth), L.MachineOffset, 1.8, true },
			{ "Core", Vector3.new(depth - 1.4, 2.2, depth - 1.4), L.MachineOffset, 4.7, true },
			{ "Arm", Vector3.new(L.MachineOffset, 1, 1.4), L.MachineOffset / 2, L.BeltY + 5, false },
			{ "Spout", Vector3.new(2.4, 1.8, 2.4), 0, L.BeltY + 4.2, false },
			{ "Nozzle", Vector3.new(1.8, 0.5, 1.8), 0, L.BeltY + 3.2, false },
		}
	end,
	Upgrader = function()
		-- Single post on the OUTBOARD side with a cantilevered beam, rather
		-- than an arch straddling the belt: keeps the inboard walkway clear.
		local reach = L.MachineOffset + L.BeltWidth / 2
		return {
			{ "Post", Vector3.new(1.8, 6, 1.8), L.MachineOffset, 3, true },
			{ "Beam", Vector3.new(reach, 1.5, 2.2), (L.MachineOffset - L.BeltWidth / 2) / 2, L.BeltY + 4.6, false },
			-- The VISIBLE plate. One stud thick, because that is what it should
			-- look like: a scanner beam, not a wall. It no longer does the
			-- catching.
			{ "Scanner", Vector3.new(L.BeltWidth, 3.6, 1), 0, L.BeltY + 1.8, false },
			-- ...and the volume that actually catches drops, invisible and five
			-- studs deep. Same split, and for the same reason, as the
			-- mezzanine's invisible guard behind its visible railing: what a
			-- thing looks like and what it has to physically be are different
			-- questions, and a 1-stud trigger loses drops at belt speed.
			{ "ScanTrigger", Vector3.new(L.BeltWidth, 3.6, L.TriggerThickness), 0, L.BeltY + 1.8, false },
		}
	end,
}

--- Builds a machine's masses into `parent` and returns them keyed by name.
function Tycoon:buildMasses(def, parent: Instance, color: Color3, material: Enum.Material)
	local shape = MACHINE_MASSES[def.kind]
	if not shape then
		return {}
	end
	local legIndex, distance, pathIndex = self:legOf(def)
	local parts = {}
	for _, mass in ipairs(shape()) do
		local name, size, offset, y, collide = mass[1], mass[2], mass[3], mass[4], mass[5]
		parts[name] = newPart(parent, name, size,
			self:segmentCF(legIndex, distance, offset, y, pathIndex), color, material, collide)
	end
	return parts, legIndex, distance, pathIndex
end

-- Exported because the files that build parts are other files now. `newPart`
-- was a file-local when there was one file; MACHINE_MASSES is read by
-- tycoon/Buttons.lua, which draws the ghost from the same description the real
-- machine is built from.
Parts.newPart = newPart
Parts.MACHINE_MASSES = MACHINE_MASSES

return Parts
