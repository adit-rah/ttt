--[[
	tycoon/Drops.lua — spawning the things the belt carries, and the budget that
	stops a finished factory spawning without limit.

	ONE CONSTRAINT AND ONE MODEL. The constraint: a LinearVelocity in Plane mode
	plus an AlignOrientation, so a drop costs no per-frame script and physically
	cannot drift sideways off the belt. The model: PivotTo overwrites the body's
	rotation outright, so the upright pose has to be baked into the target CFrame
	or every drop spawns lying on its side.

	THE ATTRIBUTES ARE THE ROUTING. Value, PlotIndex, Leg and Path are what the
	corner sensors, the upgrader triggers and the collector all filter on, so a
	drop on the mezzanine is invisible to the ground floor's geometry and vice
	versa. A drop built without them is a drop nothing will ever collect.

	Config.Economy.MaxDropsPerPlot and self.dropCount are the budget. Every path
	that removes a drop — collected, expired, cleared — has to decrement the
	count, or the counter drifts up to the cap and the plot silently stops
	dropping.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local Tycoon = Req("Class")

local L = Config.Layout

-- ── drops ────────────────────────────────────────────────────────────────────

function Tycoon:spawnDrop(def, nozzle: BasePart, legIndex: number, pathIndex: number?)
	pathIndex = pathIndex or 1
	if not self.owner then
		return
	end
	if self.dropCount >= Config.Economy.MaxDropsPerPlot then
		return
	end
	self.dropCount += 1

	local drop = TungModels.buildDrop(def.variant, 0.62)
	drop:SetAttribute("Value", def.dropValue)
	drop:SetAttribute("PlotIndex", self.index)
	drop:SetAttribute("Variant", def.variant)

	-- Which belt, and how far along it: the corner sensors and the collector
	-- all filter on these, so a drop on the mezzanine is invisible to the
	-- ground floor's geometry and vice versa.
	drop:SetAttribute("Leg", legIndex)
	drop:SetAttribute("Path", pathIndex)

	local body = drop.PrimaryPart :: BasePart
	local direction = self:legDirectionWorld(legIndex, pathIndex)
	local across = self:legNormalWorld(legIndex, pathIndex)
	local jitter = (math.random() - 0.5) * (L.BeltWidth * 0.35)

	-- NOTE: the model's pivot is the body, so PivotTo overwrites the body's
	-- rotation outright. The upright orientation has to be baked into the
	-- target CFrame or every drop spawns lying on its side.
	local upright = TungModels.dropOrientation(direction)
	local spawnPosition = nozzle.Position + across * jitter - Vector3.new(0, 1.6, 0)
	drop:PivotTo(CFrame.new(spawnPosition) * upright)

	local attachment = Instance.new("Attachment")
	attachment.Name = "BeltAttach"
	attachment.Parent = body

	-- conveyor motion, done with a constraint so there is no per-frame script
	local mover = Instance.new("LinearVelocity")
	mover.Name = "BeltMover"
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	mover.PrimaryTangentAxis = direction
	mover.SecondaryTangentAxis = across
	mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
	mover.MaxForce = 120000
	mover.Parent = body

	-- keep the little guy standing up and facing back down the belt, so you
	-- see a queue of angry faces instead of a pile of rolling logs
	local upkeep = Instance.new("AlignOrientation")
	upkeep.Name = "StayUpright"
	upkeep.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upkeep.Attachment0 = attachment
	upkeep.RigidityEnabled = true
	upkeep.CFrame = upright
	upkeep.Parent = body

	drop.Parent = self.drops

	Fx.tung(body, 1.6 + math.random() * 0.3, 0.08)

	task.delay(Config.Economy.DropLifetime, function()
		if drop.Parent then
			self.dropCount = math.max(0, self.dropCount - 1)
			drop:Destroy()
		end
	end)
end

function Tycoon:clearDrops()
	for _, drop in ipairs(self.drops:GetChildren()) do
		drop:Destroy()
	end
	self.dropCount = 0
end

return Tycoon
