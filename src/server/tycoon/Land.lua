--[[
	tycoon/Land.lua — the ground a plot grows into, reconciled from `owned`.

	design:D-02, via #88. Land is bought outward from the centre and the centre
	pad is the permanent anchor. ensureLand runs on the refreshButtons beat and
	makes the world match `owned`: slabs and their edge strips per expansion,
	and the wall ring re-emitted around whatever ground is standing. Purchase,
	release, rebirth and re-claim all reach
	refreshButtons, which is why there is no service and no listener — the
	FloorService this replaces existed to catch those four events, and a
	derived reconciler catches them by construction.

	THE RING RE-EMITS COURSES AND NEVER TOUCHES A LEAF. Rebuilding wall boxes
	is safe — nothing tweens them; rebuilding a gate leaf mid-tween is the
	defect GateService's Parent check exists for. So rebuildWallRing destroys
	everything in the ring EXCEPT Gate_* parts, re-emits the courses from
	Config.wallSegments at the current land state, and leaves the leaves
	alone. The openings never move — they live on the centre span — so a
	surviving leaf is exactly where its spec still says it belongs.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local newPart = Parts.newPart
local W = Config.World

local SLAB_COLOR = Color3.fromRGB(112, 105, 98)
local EDGE_COLOR = Color3.fromRGB(255, 196, 84)

--- How many expansions each side owns. Derived from `owned` on every call,
--- never cached — a cached count is a second copy of the save (#35).
function Tycoon:landState()
	return Config.landCounts(self.owned)
end

--- One expansion's ground: the slab, neon strips along its front, back and
--- (for the outermost owned strip) outer edge — and the sub-belt it arrives
--- with (#109): the strip's own path gets its surfaces, corner sensors and a
--- plain collector, all parented into this model so tearing the strip down
--- takes its conveyor with it.
local function buildSlab(self, folder, def, outermost)
	local rect = Config.landRect(def.id)
	local model = Instance.new("Model")
	model.Name = "Land_" .. def.id
	model.Parent = folder

	local width = rect.toX - rect.fromX
	local centreX = (rect.fromX + rect.toX) / 2
	newPart(model, "Slab", Vector3.new(width, W.PlotSize.Y, W.PlotSize.Z),
		self:at(centreX, -W.PlotSize.Y / 2, 0), SLAB_COLOR, Enum.Material.Concrete)

	local pathIndex = self:pathIndexOf({ id = def.id, path = def.id })
	if pathIndex and self.paths[pathIndex] then
		self:buildBelt(pathIndex, model)
		self:buildCollector(pathIndex, model, false)
	end

	local halfZ = W.PlotSize.Z / 2
	local edges = {
		{ Vector3.new(width, 1, 2), self:at(centreX, 0.2, halfZ) },
		{ Vector3.new(width, 1, 2), self:at(centreX, 0.2, -halfZ) },
	}
	if outermost then
		local outerX = (rect.side == "left") and rect.fromX or rect.toX
		table.insert(edges, { Vector3.new(2, 1, W.PlotSize.Z), self:at(outerX, 0.2, 0) })
	end
	for index, edge in ipairs(edges) do
		local strip = newPart(model, "Edge" .. index, edge[1], edge[2], EDGE_COLOR, Enum.Material.Neon)
		strip.CanCollide = false
	end
	return model
end

--- Re-emit the ring's courses at the current land state, leaves excepted.
function Tycoon:rebuildWallRing()
	self:withWallRing(function(ring)
		for _, part in ipairs(ring:GetChildren()) do
			if part.Name:sub(1, 5) ~= "Gate_" then
				part:Destroy()
			end
		end
		self:buildWallRing(ring)
	end)
end

--- Make the ground and the ring match `owned`. Idempotent: called on every
--- refreshButtons beat, it builds what is missing, destroys what is no longer
--- owned, and touches nothing that already agrees.
function Tycoon:ensureLand()
	-- A stub plot (the spec harness's fakes) has no model and no plot CFrame;
	-- there is no world for the ground to exist in, so there is nothing to
	-- reconcile.
	if not (self.model and self.cf) then
		return
	end
	local counts = self:landState()

	local folder = self.landFolder
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "Land"
		folder.Parent = self.model
		self.landFolder = folder
	end

	local changed = false
	for _, side in ipairs({ "left", "right" }) do
		local rows = Config.landRows(side)
		for index, def in ipairs(rows) do
			local wanted = index <= counts[side]
			local existing = folder:FindFirstChild("Land_" .. def.id)
			if wanted and not existing then
				buildSlab(self, folder, def, index == counts[side])
				changed = true
			elseif not wanted and existing then
				existing:Destroy()
				changed = true
			elseif wanted and existing then
				-- the outer edge strip belongs to the outermost strip only;
				-- an expansion that stopped being outermost sheds it
				local outer = existing:FindFirstChild("Edge3")
				if outer and index ~= counts[side] then
					outer:Destroy()
				end
			end
		end
	end

	if changed then
		self:rebuildWallRing()
	end
end

return Tycoon
