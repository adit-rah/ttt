--[[
	tycoon/Installers.lua — one case per `kind`, and the machines those cases
	build.

	ADDING CONTENT IS A Config.Buttons ROW, NEVER A CASE HERE. A new case means a
	new KIND of buyable, and it has to land in three places at once: this table,
	KNOWN_KINDS in tools/verify_config.lua, and the contract in the header of
	tycoon/Tycoon.lua.

	Every installer takes (self, def, silent) and runs AFTER install() has set
	self.owned[def.id], so a rung may count itself. They must be IDEMPOTENT UNDER
	REPLAY, because assign() reinstalls every owned button in `order`: Power
	assigns Config.powerFactor(owned) rather than multiplying into the factor,
	which is what makes it correct under a replay, under a double install, and
	under a save holding power3 without power2. Floor is a documented no-op for a
	related reason — the deck outlives the purchase, so FloorService builds it
	off onOwnedChanged.

	buildDropperMachine and buildShelfDisplay sit outside the installers on
	purpose: FloorService stands a dropper on each upper floor, and a floor's
	dropper is not a button, so it cannot go through INSTALLERS.

	buildRoofModel is extracted for the same class of reason and is the one piece
	of structure that gets REBUILT: the mezzanine deck is the roof of the back
	half of the plot, so a plot that buys the floor fifteen minutes after the roof
	needs the roof reshaped rather than two slabs a third of a stud apart.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local CombatService = Req("CombatService")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local newPart = Parts.newPart
local COLORS = Tycoon.COLORS

local L = Config.Layout
local W = Config.World

-- ── installers ───────────────────────────────────────────────────────────────

Tycoon.INSTALLERS = {}

--- The dropper machine itself: masses, dressing, nameplate. Shared by the buy
--- button installer and by FloorService, which stands one on each upper floor —
--- a floor's dropper is not a button, so it cannot go through INSTALLERS.
--- Returns the model, its nozzle, and the leg and path it feeds.
function Tycoon:buildDropperMachine(def, parent: Instance)
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Dropper_" .. def.id
	model.Parent = parent

	local parts, legIndex, _, pathIndex = self:buildMasses(def, model, COLORS.frame, Enum.Material.DiamondPlate)

	local core = parts.Core
	core.Color = variant.wood
	core.Material = variant.material
	Fx.applyVariant(core, variant)

	parts.Arm.Color = COLORS.metal
	parts.Arm.Material = Enum.Material.Metal
	parts.Spout.Color = COLORS.metal
	parts.Spout.Material = Enum.Material.Metal

	local nozzle = parts.Nozzle
	nozzle.Color = variant.light and variant.light.color or variant.wood
	nozzle.Material = Enum.Material.Neon

	local billboard = Style.billboard(core, {
		name = "Plate", width = 9, height = 2.6, distance = "machine", offset = 3.4,
	})
	Style.text(billboard, {
		weight = "body", color = Color3.fromRGB(255, 250, 235),
		text = def.name .. "  •  $" .. Util.abbreviate(def.dropValue),
	})

	return model, nozzle, legIndex, pathIndex
end

--- Starts a dropper's drop loop. `alive` is polled each cycle so the caller
--- decides what ends it: a bought dropper dies when its button is wiped by a
--- rebirth, a floor's dropper dies when the floor is torn down (its model is
--- destroyed, which the model.Parent check catches on its own).
function Tycoon:startDropLoop(def, model: Model, nozzle: BasePart, legIndex: number, pathIndex: number?, alive: (() -> boolean)?)
	local generation = self.generation
	task.spawn(function()
		-- stagger so ten droppers don't fire on the same frame
		task.wait(math.random() * self:dropInterval(def))
		while self.generation == generation and model.Parent and (alive == nil or alive()) do
			self:spawnDrop(def, nozzle, legIndex, pathIndex)
			task.wait(self:dropInterval(def))
		end
	end)
end

Tycoon.INSTALLERS.Dropper = function(self, def, silent)
	local model, nozzle, legIndex, pathIndex = self:buildDropperMachine(def, self.machines)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end

	self:startDropLoop(def, model, nozzle, legIndex, pathIndex, function()
		return self.owned[def.id] == true
	end)
end

Tycoon.INSTALLERS.Upgrader = function(self, def, silent)
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Upgrader_" .. def.id
	model.Parent = self.machines

	local parts = self:buildMasses(def, model, COLORS.metal, Enum.Material.Metal)

	local beam = parts.Beam
	beam.Color = variant.wood
	beam.Material = variant.material
	Fx.applyVariant(beam, variant)

	-- The plate you see, which catches nothing...
	local scanner = parts.Scanner
	scanner.Color = variant.light and variant.light.color or variant.wood
	scanner.Material = Enum.Material.Neon
	scanner.Transparency = 0.55
	scanner.CanTouch = false

	-- ...and the volume that does, which you don't. Five studs deep so a drop
	-- cannot cross it between two physics steps on a plot nobody is standing on.
	local trigger = parts.ScanTrigger
	trigger.Transparency = 1
	trigger.CanTouch = true
	trigger.CanQuery = false
	trigger.CastShadow = false

	local billboard = Style.billboard(beam, {
		name = "Plate", width = 11, height = 3, distance = "machine", offset = 3,
	})
	Style.text(billboard, {
		text = ("%s  x%.2g"):format(def.name, def.multiplier),
		color = Color3.fromRGB(255, 240, 210),
	})

	local flagName = "up_" .. def.id
	trigger.Touched:Connect(function(hit)
		local drop = hit.Parent
		if not drop or not drop:IsA("Model") then
			return
		end
		if drop:GetAttribute("PlotIndex") ~= self.index then
			return
		end
		local value = drop:GetAttribute("Value")
		if not value or drop:GetAttribute(flagName) then
			return
		end
		drop:SetAttribute(flagName, true)
		drop:SetAttribute("Value", value * def.multiplier)

		local body = drop.PrimaryPart or drop:FindFirstChild("Body")
		if body and body:IsA("BasePart") then
			body.Color = Util.lerpColor(body.Color, variant.wood, 0.55)
			body.Material = variant.material
			Fx.burst(body.Position, variant.wood, 4, self.model)
			Fx.tung(body, 1.15 + math.random() * 0.2, 0.12)
		end
	end)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Belt = function(self, def, silent)
	self.beltBonus += def.speedBonus
	self:refreshBeltSpeed()
	-- one speed for the whole plot, every floor included
	self:eachBeltSurface(function(surface)
		surface.Color = Color3.fromRGB(92, 70, 40)
	end)
end

Tycoon.INSTALLERS.Power = function(self, def, silent)
	-- THE FACTOR HAS TO BE ASSIGNED, and it never was.
	--
	-- self.powerFactor was initialised to 1 and reset to 1 by release() and
	-- rebirth(), and those were the only three writes in the file. This
	-- installer called refreshBeltSpeed() without setting it, so the two things
	-- that read the field — refreshBeltSpeed's (BeltSpeed + beltBonus) * factor
	-- and dropInterval's dropRate / factor — both multiplied by one. The belt
	-- and every dropper have been running at stock speed since the generator
	-- shipped in #32.
	--
	-- incomePerSecond reads Config.powerFactor(has) directly instead, so it was
	-- correct the whole time. That asymmetry is why nothing looked wrong: the
	-- plot quoted the full multiplier on the HUD, on the buy button and through
	-- SessionService's offline mirror while producing none of it, and the only
	-- thing 300M Tung actually bought was a bigger number in the corner.
	--
	-- DERIVED, NEVER ACCUMULATED. assign() replays a save by installing every
	-- owned button in `order`, so a *= here would land on
	-- 1.19 x 1.42 x 1.68 x 2.00 = 5.67 rather than on 2.00. Config.powerFactor
	-- takes the last owned rung because `factor` is cumulative, which makes
	-- this idempotent under replay, under a double install, and under a save
	-- that somehow holds power3 without power2. install() has already set
	-- self.owned[def.id] before dispatching here, so the rung being bought
	-- counts itself.
	self.powerFactor = Config.powerFactor(function(id: string): boolean
		return self.owned[id] == true
	end)
	self:refreshBeltSpeed()
	-- The machine is derived from `owned` by refreshGenerator, which install()
	-- reaches through refreshButtons on the next line of its own body. It lives
	-- in self.machines rather than self.props, which is what makes a rebirth
	-- take it down along with the droppers it was speeding up while the yard
	-- around it stays.
	self:refreshGenerator()
end

--- A bought tier's display, standing on its own shelf of the track's cabinet.
---
--- Parented into self.props, NOT self.machines: rebirth clears machines, and a
--- weapon you keep across a rebirth must not lose its shelf.
function Tycoon:buildShelfDisplay(def, variant: string, label: string)
	local model = Instance.new("Model")
	model.Name = "Shelf_" .. def.id
	model.Parent = self.props

	local spot = Config.trackShelfPosition(def.track, def.trackOrder)
	local shelfCF = self:at(spot.X, spot.Y, spot.Z)
	newPart(model, "Shelf", Vector3.new(5, 0.6, 8), shelfCF, COLORS.metal, Enum.Material.Metal)

	-- 0.85 rather than the 1.1 the old free-standing anvil used: the display
	-- now stands INSIDE a 13-stud case, and the tallest variants scale up by a
	-- further 1.5 on top of whatever is asked for here.
	local display = TungModels.buildStatue(variant, 0.85)
	display:PivotTo(shelfCF * CFrame.new(0, 3.2, 0))
	display.Parent = model

	local plate = newPart(model, "Plate", Vector3.new(0.4, 1.6, 7),
		shelfCF * CFrame.new(-2.2, 1, 0), COLORS.metal, Enum.Material.Metal, false)
	local billboard = Style.billboard(plate, {
		name = "Plate", width = 7, height = 1.4, distance = "machine", offset = 1.6,
	})
	Style.text(billboard, { weight = "body", text = label, color = COLORS.gold })

	return model
end

Tycoon.INSTALLERS.Gear = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantBat(owner, def.grants)
	end

	local batDef = Config.BatById[def.grants]
	local model = self:buildShelfDisplay(def, batDef and batDef.variant or "classic",
		batDef and batDef.name or def.name)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Armor = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantArmor(owner, def.grants)
	end

	local tierDef = Config.ArmorById[def.grants]
	local model = self:buildShelfDisplay(def, tierDef and tierDef.variant or "classic",
		tierDef and tierDef.name or def.name)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

--- A DOCUMENTED NO-OP. The deck is built by FloorService off the
--- ownedChanged signal, not from here, because the deck outlives this
--- purchase: release, rebirth and re-claim all have to rebuild or drop it and
--- none of them go through install(). This exists so install() does not
--- warn("no installer for kind Floor") on a button that worked perfectly.
Tycoon.INSTALLERS.Floor = function(self, def, silent)
end

Tycoon.INSTALLERS.Structure = function(self, def, silent)
	local model = Instance.new("Model")
	model.Name = "Structure_" .. def.id
	model.Parent = self.machines

	local halfX = W.PlotSize.X / 2 - 1
	local halfZ = W.PlotSize.Z / 2 - 1

	if def.structure == "walls" then
		local h = 13
		-- The gateway sits over the open floor on the right, NOT at x = 0:
		-- the belt and vault occupy the left half, so a centred gate would
		-- open onto machinery. Config owns the numbers so they scale with
		-- the plot and can be checked against the aisle by the verifier.
		local gateCentre, gateWidth = L.GateCentre, L.GateWidth
		local gateLeft = gateCentre - gateWidth / 2
		local gateRight = gateCentre + gateWidth / 2
		local leftSpan = gateLeft + halfX
		local rightSpan = halfX - gateRight
		-- The BACK wall is one piece short of the full width, leaving a doorway
		-- in the back-right corner onto the generator yard. Cut here rather
		-- than when the generator is bought, because walls land around minute
		-- five and the first rung later — a solid back wall would seal the yard
		-- off permanently for anyone who bought walls first, which is everyone.
		--
		-- The corner is not a preference. The back edge of the plot IS the
		-- dropper row (slots 1..10 run x = -42.5 to 43.5) and the left side is
		-- the upgrader alley, so it is the only span with nothing behind it.
		local door = L.Yard.DoorFrom
		local backSpan = door + halfX
		local specs = {
			{ Vector3.new(backSpan, h, 2), CFrame.new((door - halfX) / 2, h / 2, -halfZ) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(halfX, h / 2, 0) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(-halfX, h / 2, 0) },
			-- front wall in two pieces, leaving the gateway over the aisle
			{ Vector3.new(leftSpan, h, 2), CFrame.new(gateLeft - leftSpan / 2, h / 2, halfZ) },
			{ Vector3.new(rightSpan, h, 2), CFrame.new(gateRight + rightSpan / 2, h / 2, halfZ) },
		}
		for i, spec in ipairs(specs) do
			newPart(model, "Wall" .. i, spec[1], self.cf * spec[2], Color3.fromRGB(150, 111, 74), Enum.Material.WoodPlanks)
			newPart(model, "Trim" .. i, spec[1] + Vector3.new(0.4, -h + 1, 0.4),
				self.cf * spec[2] * CFrame.new(0, h / 2, 0), COLORS.beltLine, Enum.Material.Neon, false)
		end
	elseif def.structure == "roof" then
		self:buildRoofModel(model, halfX, halfZ)
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

--- The roof slab, its columns and the company sign.
---
--- Extracted from the installer because the roof's SHAPE depends on something
--- bought later. The mezzanine deck is the roof of the back half of the plot,
--- so with the floor up the roof stops short of it with a couple of studs of
--- daylight; roofing it twice interpenetrates two slabs a third of a stud apart
--- and hides a floor under a roof nobody can see.
---
--- That used to key off the prototype flag, which was the same answer for
--- everybody forever. Now that the floor is a purchase in the middle of the
--- build, the roof at minute 28 and the floor at minute 40 are fifteen minutes
--- apart — so the roof has to be REBUILT when the floor lands, or every player
--- gets a half-roof over an empty back half for the gap between them.
function Tycoon:buildRoofModel(model: Instance, halfX: number, halfZ: number)
	model:ClearAllChildren()

	local front = W.PlotSize.Z / 2
	local back = -W.PlotSize.Z / 2
	local floorDef = Config.Floors[1]
	if floorDef and self.owned[floorDef.button] then
		back = floorDef.deckAt.Z + floorDef.deckSize.Z / 2 + 2
	end

	do
		-- Heights come from Layout now rather than being literals here, because
		-- the mezzanine deck sits at 22 and these columns are 20 tall — a
		-- relationship nothing was checking, on two pieces of geometry that
		-- already reach into each other.
		local roof = newPart(model, "Roof", Vector3.new(W.PlotSize.X, L.RoofThickness, front - back),
			self:at(0, L.RoofY, (front + back) / 2), Color3.fromRGB(138, 88, 58), Enum.Material.WoodPlanks)
		roof.CanCollide = true
		for _, sign in ipairs({ -1, 1 }) do
			for _, signZ in ipairs({ -1, 1 }) do
				newPart(model, "Column", Vector3.new(L.RoofColumn, L.RoofY, L.RoofColumn),
					self:at(sign * (halfX - L.RoofColumnInset), L.RoofY / 2, signZ * (halfZ - L.RoofColumnInset)),
					Color3.fromRGB(150, 111, 74), Enum.Material.Wood)
			end
		end

		local signAnchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1), self:at(0, 27, 0), COLORS.frame, nil, false)
		signAnchor.Transparency = 1
		local billboard = Style.billboard(signAnchor, {
			name = "Sign", width = 46, height = 12, distance = "plot",
		})
		self.roofSign = Style.text(billboard, {
			text = "TUNG TUNG TUNG SAHUR CO.", color = COLORS.gold,
		})
		self:updateSign()
	end
end

--- Reshapes an already-built roof. Called when the floor lands under it.
function Tycoon:refreshRoof()
	local entry = self.objects.roof
	local model = entry and entry.machine
	if model and model.Parent then
		self:buildRoofModel(model, W.PlotSize.X / 2 - 1, W.PlotSize.Z / 2 - 1)
	end
end

return Tycoon
