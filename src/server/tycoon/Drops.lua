--[[
	tycoon/Drops.lua — spawning the things the belt carries, and the budget that
	stops a finished factory spawning without limit.

	DROPS CARRY THE MONEY. design:D-02, via #180 — a tung stamps its
	dropper's value at spawn and PAYS it at the vault, through the plot
	multiplier and the live session stack. A tung that never reaches the
	collector — launched, jammed, cleared, reaped — is income that never
	arrives, which is what makes the conveyor the real indication of how the
	money is made. Config.incomeRate stays the quote, the offline mirror and
	the pacing model: it is the drops' long-run average.

	ONE CONSTRAINT AND ONE MODEL. The constraint: a LinearVelocity in Plane mode
	plus an AlignOrientation, so a drop costs no per-frame script and physically
	cannot drift sideways off the belt. The model: PivotTo overwrites the body's
	rotation outright, so the upright pose has to be baked into the target CFrame
	or every drop spawns lying on its side.

	THE ATTRIBUTES ARE THE ROUTING. PlotIndex, Leg and Path are what the corner
	sensors, the upgrader triggers and the collector all filter on, so a drop on
	the mezzanine is invisible to the ground floor's geometry and vice versa. A
	drop built without them sails off the first bend and stands wherever it
	lands until the reaper takes it.

	Config.Economy.MaxDropsPerPlot and self.dropCount are the INCOME budget
	since #180: a spawn the cap refuses is money that never arrives. Every
	path that removes a drop — collected, expired, cleared — has to decrement
	the count, or the counter drifts up to the cap and the plot silently
	stops earning.

	THE POOL RECYCLES BODIES, per variant. A finished factory retires ~10
	drops a second, and building a Model with constraints for each one is the
	server cost the pool removes. recycleDrop is the ONE way off the belt for
	an intact drop: it wipes the ride's attributes and the flash's tint,
	unparents, and shelves the body under its variant. clearDrops destroys the
	pool with the live drops — release hands the plot to a new owner whose
	factory drops different variants, and a shelved body from the last tenant
	is a leak wearing the wrong colour.
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

	local pool = self.dropPool[def.variant]
	local drop = pool and table.remove(pool) or nil
	if drop then
		-- Wipe the last ride: every upgrader's once-flag and the collector's
		-- claim, or a recycled drop arrives pre-flashed and pre-collected.
		for id, buttonDef in pairs(Config.ButtonById) do
			if buttonDef.kind == "Upgrader" then
				drop:SetAttribute("up_" .. id, nil)
			end
		end
		drop:SetAttribute("Collected", nil)
	else
		drop = TungModels.buildDrop(def.variant, 0.62)
		drop:SetAttribute("Variant", def.variant)
	end
	drop:SetAttribute("PlotIndex", self.index)
	-- The money this tung is worth at the vault, before multipliers — stamped
	-- raw so the stack is read fresh at COLLECTION and a mid-ride upgrade
	-- pays through on everything still on the belt (#180).
	drop:SetAttribute("DropValue", def.dropValue)

	-- Which belt, and how far along it: the corner sensors and the collector
	-- all filter on these, so a drop on the mezzanine is invisible to the
	-- ground floor's geometry and vice versa.
	drop:SetAttribute("Leg", legIndex)
	drop:SetAttribute("Path", pathIndex)

	local body = drop.PrimaryPart :: BasePart
	-- the upgrader flash tints the body toward its variant; a pooled body
	-- comes back at the nozzle in its natural coat
	local variant = Config.Variants[def.variant] or Config.Variants.classic
	body.Color = variant.wood
	body.Material = variant.material
	local direction = self:legDirectionWorld(legIndex, pathIndex)
	local across = self:legNormalWorld(legIndex, pathIndex)
	local jitter = (math.random() - 0.5) * (L.BeltWidth * 0.35)

	-- NOTE: the model's pivot is the body, so PivotTo overwrites the body's
	-- rotation outright. The upright orientation has to be baked into the
	-- target CFrame or every drop spawns lying on its side.
	local upright = TungModels.dropOrientation(direction)
	local spawnPosition = nozzle.Position + across * jitter - Vector3.new(0, 1.6, 0)
	drop:PivotTo(CFrame.new(spawnPosition) * upright)

	-- A pooled body keeps its rig; a fresh one gets it here. The dynamic
	-- fields — the leg's axes, the plot's speed, the upright pose — are
	-- written either way, every spawn.
	local attachment = body:FindFirstChild("BeltAttach")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "BeltAttach"
		attachment.Parent = body
	end

	-- conveyor motion, done with a constraint so there is no per-frame script
	local mover = body:FindFirstChild("BeltMover")
	if not mover then
		mover = Instance.new("LinearVelocity")
		mover.Name = "BeltMover"
		mover.Attachment0 = attachment
		mover.RelativeTo = Enum.ActuatorRelativeTo.World
		mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		mover.MaxForce = 120000
		mover.Parent = body
	end
	mover.PrimaryTangentAxis = direction
	mover.SecondaryTangentAxis = across
	mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)

	-- keep the little guy standing up and facing back down the belt, so you
	-- see a queue of angry faces instead of a pile of rolling logs
	local upkeep = body:FindFirstChild("StayUpright")
	if not upkeep then
		upkeep = Instance.new("AlignOrientation")
		upkeep.Name = "StayUpright"
		upkeep.Mode = Enum.OrientationAlignmentMode.OneAttachment
		upkeep.Attachment0 = attachment
		upkeep.RigidityEnabled = true
		upkeep.Parent = body
	end
	upkeep.CFrame = upright

	-- The ride token. A recycled body still has the LAST ride's reaper
	-- pending on it, and "is it parented" cannot tell ride 2 from ride 1 —
	-- so the reaper only takes the ride it was armed for.
	local ride = (drop:GetAttribute("Ride") or 0) + 1
	drop:SetAttribute("Ride", ride)

	drop.Parent = self.drops

	-- SERVER-OWNED, EXPLICITLY (#162 tophat). Automatic network ownership
	-- hands a drop near a player to that player's client, and every retarget
	-- the server writes — the corner snap, the plane axes, the collect — then
	-- reaches the real simulation a round trip late. At the shipped 28
	-- studs/s that latency hid inside the corner square; at power3's 74 the
	-- drop crossed the bend and landed on the floor before its pivot arrived.
	-- The belt is constraint-driven precisely so drops cost no per-frame
	-- script, so keeping them on the server is cheap and keeps every corner
	-- exact. After Parent: ownership can only be set on a part in workspace.
	-- pcall because a drop spawned into a plot being torn down has no
	-- workspace to be owned in, and that ride is already over.
	pcall(function()
		body:SetNetworkOwner(nil)
	end)

	Fx.tung(body, 1.6 + math.random() * 0.3, 0.08)

	task.delay(Config.Economy.DropLifetime, function()
		if drop.Parent and drop:GetAttribute("Ride") == ride then
			self:recycleDrop(drop)
		end
	end)
end

--- The one way off the belt for an intact drop: back to its variant's shelf.
--- Decrements the budget, unparents, and leaves the ride's attributes for the
--- next spawn to wipe — spawnDrop resets everything it reuses.
function Tycoon:recycleDrop(drop: Model)
	if not drop.Parent then
		return
	end
	self.dropCount = math.max(0, self.dropCount - 1)
	drop.Parent = nil
	local variant = drop:GetAttribute("Variant")
	local pool = self.dropPool[variant]
	if not pool then
		pool = {}
		self.dropPool[variant] = pool
	end
	table.insert(pool, drop)
end

function Tycoon:clearDrops()
	for _, drop in ipairs(self.drops:GetChildren()) do
		drop:Destroy()
	end
	-- The pool goes with the live drops: release hands the plot to an owner
	-- whose factory drops different variants, and a shelved body that
	-- survives the handover is a leak wearing the last tenant's colours.
	for _, pool in pairs(self.dropPool) do
		for _, drop in ipairs(pool) do
			drop:Destroy()
		end
	end
	self.dropPool = {}
	self.dropCount = 0
end

return Tycoon
