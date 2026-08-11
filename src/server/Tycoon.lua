--[[
	Tycoon.lua — the standardized tycoon.

	One instance per plot. Everything it builds comes from Config.Buttons, so
	adding content is a data edit, never a code edit. The contract for a new
	entry is just:

		kind = "Dropper"   -> needs slot, variant, dropValue, dropRate
		kind = "Upgrader"  -> needs slot, variant, multiplier
		kind = "Belt"      -> needs speedBonus
		kind = "Structure" -> needs structure ("walls" | "roof")
		kind = "Gear"      -> needs grants (a Config.Bats id)

	Add a case to INSTALLERS below to invent a new kind.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local Economy = Req("Economy")
local DataService = Req("DataService")
local CombatService = Req("CombatService")
local MapBuilder = Req("MapBuilder")

local L = Config.Layout
local W = Config.World

local Tycoon = {}
Tycoon.__index = Tycoon

local MISC_SPOTS = {
	walls     = Vector3.new(-40, 0, 34),
	batforge  = Vector3.new(-40, 0, 22),
	batforge2 = Vector3.new(-40, 0, 10),
	belt1     = Vector3.new(40, 0, 34),
	roof      = Vector3.new(40, 0, 22),
}

local COLORS = {
	frame     = Color3.fromRGB(118, 122, 130),
	metal     = Color3.fromRGB(160, 164, 172),
	belt      = Color3.fromRGB(62, 62, 68),
	beltLine  = Color3.fromRGB(255, 176, 60),
	buttonOn  = Color3.fromRGB(110, 235, 150),
	buttonOff = Color3.fromRGB(230, 90, 90),
	vault     = Color3.fromRGB(146, 110, 72),
	gold      = Color3.fromRGB(255, 205, 90),
}

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

-- ─────────────────────────────────────────────────────────────────────────────

function Tycoon.new(index: number, parent: Instance)
	local self = setmetatable({}, Tycoon)

	self.index = index
	self.owner = nil :: Player?
	self.owned = {}
	self.objects = {}
	self.generation = 0
	self.beltSpeed = L.BeltSpeed
	self.dropCount = 0

	local model, cf = MapBuilder.buildPlotPad(parent, index)
	self.model = model
	self.cf = cf

	self.machines = Instance.new("Folder")
	self.machines.Name = "Machines"
	self.machines.Parent = model

	self.buttonsFolder = Instance.new("Folder")
	self.buttonsFolder.Name = "Buttons"
	self.buttonsFolder.Parent = model

	self.drops = Instance.new("Folder")
	self.drops.Name = "Drops"
	self.drops.Parent = model

	self:buildBelt()
	self:buildCollector()
	self:buildRebirthPad()
	self:buildClaimPad()
	self:buildButtons()
	self:refreshButtons()

	return self
end

function Tycoon:at(x: number, y: number, z: number): CFrame
	return self.cf * CFrame.new(x, y, z)
end

-- ── belt ─────────────────────────────────────────────────────────────────────

function Tycoon:buildBelt()
	local folder = Instance.new("Folder")
	folder.Name = "Belt"
	folder.Parent = self.model
	self.beltFolder = folder

	local length = L.BeltEndZ - L.BeltStartZ
	local midZ = (L.BeltStartZ + L.BeltEndZ) / 2

	-- support frame
	newPart(folder, "BeltBase", Vector3.new(L.BeltWidth + 2.4, L.BeltY, length + 2),
		self:at(0, L.BeltY / 2, midZ), COLORS.frame, Enum.Material.DiamondPlate)

	-- running surface, low friction so the LinearVelocity constraint rules
	local surface = newPart(folder, "BeltSurface", Vector3.new(L.BeltWidth, 0.4, length),
		self:at(0, L.BeltY + 0.2, midZ), COLORS.belt, Enum.Material.SmoothPlastic)
	surface.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)
	self.beltSurface = surface

	-- animated chevrons
	local texture = Instance.new("Texture")
	texture.Face = Enum.NormalId.Top
	texture.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	texture.Transparency = 0.75
	texture.StudsPerTileU = 6
	texture.StudsPerTileV = 6
	texture.Color3 = COLORS.beltLine
	texture.Parent = surface

	-- rails
	for _, sign in ipairs({ -1, 1 }) do
		local rail = newPart(folder, "Rail", Vector3.new(0.8, 2.4, length),
			self:at(sign * (L.BeltWidth / 2 + 0.4), L.BeltY + 1.4, midZ), COLORS.metal, Enum.Material.Metal)
		rail.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)
	end

	-- back wall so nothing escapes upstream
	newPart(folder, "BeltStop", Vector3.new(L.BeltWidth + 2, 3, 0.8),
		self:at(0, L.BeltY + 1.6, L.BeltStartZ - 0.5), COLORS.metal, Enum.Material.Metal)

	-- under-glow
	local glow = newPart(folder, "BeltGlow", Vector3.new(L.BeltWidth - 1, 0.3, length),
		self:at(0, 0.4, midZ), COLORS.beltLine, Enum.Material.Neon, false)
	glow.Transparency = 0.3
end

--- The belt direction in world space (plot-local +Z).
function Tycoon:beltDirection(): Vector3
	return (self.cf.ZVector).Unit
end

function Tycoon:beltRight(): Vector3
	return (self.cf.XVector).Unit
end

-- ── collector ────────────────────────────────────────────────────────────────

function Tycoon:buildCollector()
	local folder = Instance.new("Folder")
	folder.Name = "Collector"
	folder.Parent = self.model

	local z = L.CollectorZ

	-- IMPORTANT: the vault shell must sit entirely DOWNSTREAM of the sensor.
	-- If the solid body overlaps the sensor or the run-off ramp it walls the
	-- belt off and drops can never be collected.
	local vaultDepth = 12
	assert(z - vaultDepth / 2 > L.BeltEndZ + 4,
		"Collector vault overlaps the belt run-off; raise Layout.CollectorZ")

	newPart(folder, "VaultBase", Vector3.new(20, 10, vaultDepth), self:at(0, 5, z), COLORS.vault, Enum.Material.WoodPlanks)
	newPart(folder, "VaultTrim", Vector3.new(21, 1.2, vaultDepth + 1), self:at(0, 10.4, z), COLORS.gold, Enum.Material.Metal)

	-- funnel mouth facing the belt
	local mouth = newPart(folder, "Mouth", Vector3.new(14, 8, 2), self:at(0, L.BeltY + 4, z - vaultDepth / 2 - 0.5),
		Color3.fromRGB(20, 16, 28), Enum.Material.Neon, false)
	mouth.Transparency = 0.55

	-- run-off ramp carrying drops off the end of the belt into the sensor
	local ramp = newPart(folder, "Ramp", Vector3.new(L.BeltWidth, 0.6, 6),
		self:at(0, L.BeltY + 0.1, L.BeltEndZ + 3), COLORS.belt, Enum.Material.SmoothPlastic)
	ramp.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)

	local sensor = newPart(folder, "Sensor", Vector3.new(L.BeltWidth + 4, 10, 3),
		self:at(0, L.BeltY + 4, L.BeltEndZ + 2), Color3.fromRGB(255, 255, 255), Enum.Material.Neon, false)
	sensor.Transparency = 1
	sensor.CanTouch = true

	-- sign
	local signAnchor = newPart(folder, "SignAnchor", Vector3.new(1, 1, 1), self:at(0, 13, z), COLORS.vault, nil, false)
	signAnchor.Transparency = 1

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(20, 6)
	billboard.MaxDistance = 260
	billboard.Parent = signAnchor

	local label = Instance.new("TextLabel")
	label.Name = "Rate"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "SAHUR VAULT"
	label.TextColor3 = COLORS.gold
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard
	self.vaultLabel = label

	local statue = TungModels.buildStatue("classic", 1.6)
	statue:PivotTo(self:at(0, 15.5, z) * CFrame.Angles(0, math.pi, 0))
	statue.Parent = folder
	self.vaultStatue = statue

	sensor.Touched:Connect(function(hit)
		self:onCollect(hit)
	end)
end

function Tycoon:onCollect(hit: BasePart)
	local model = hit.Parent
	if not model or not model:IsA("Model") then
		return
	end
	local value = model:GetAttribute("Value")
	if not value then
		return
	end
	if model:GetAttribute("PlotIndex") ~= self.index then
		return
	end
	model:SetAttribute("Value", nil)  -- claim it immediately, touch fires twice

	local owner = self.owner
	self.dropCount = math.max(0, self.dropCount - 1)

	if owner and owner.Parent then
		local gained = Economy.add(owner, value, true)
		-- late game the vault eats ~10 drops/sec; throttle the confetti so a
		-- finished factory doesn't spam hundreds of billboards per minute
		local now = os.clock()
		if now - (self.lastPayoutFx or 0) > 0.3 then
			self.lastPayoutFx = now
			Fx.floatingText(hit.Position + Vector3.new(0, 3, 0), "+" .. Util.abbreviate(gained), COLORS.gold, self.model)
			Fx.tung(hit, 0.9 + math.random() * 0.35, 0.18)
		end
	end
	model:Destroy()
end

-- ── claim pad ────────────────────────────────────────────────────────────────

function Tycoon:buildClaimPad()
	-- offset to the right of the totem: the vault occupies the centre of the
	-- plot frontage, so a centred pad would sit inside it
	local pad = newPart(self.model, "ClaimPad", Vector3.new(16, 1.4, 10),
		self:at(22, 0.7, W.PlotSize.Z / 2 - 7), Color3.fromRGB(120, 230, 160), Enum.Material.Neon)
	pad.CanCollide = false
	pad:SetAttribute("PlotIndex", self.index)
	self.claimPad = pad

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(16, 5)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.MaxDistance = 180
	billboard.Parent = pad

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "CLAIM PLOT"
	label.TextColor3 = Color3.fromRGB(190, 255, 210)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard
	self.claimLabel = label
end

-- ── rebirth pad ──────────────────────────────────────────────────────────────

function Tycoon:buildRebirthPad()
	local pad = newPart(self.model, "RebirthPad", Vector3.new(12, 1.2, 12),
		self:at(-26, 0.6, 48), Color3.fromRGB(200, 120, 255), Enum.Material.Neon)
	pad.CanCollide = false
	self.rebirthPad = pad

	local ring = newPart(self.model, "RebirthRing", Vector3.new(16, 0.4, 16),
		self:at(-26, 0.25, 48), Color3.fromRGB(120, 60, 200), Enum.Material.Neon, false)
	ring.Shape = Enum.PartType.Cylinder
	ring.CFrame = self:at(-26, 0.25, 48) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Size = Vector3.new(0.4, 16, 16)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(16, 6)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	billboard.MaxDistance = 200
	billboard.Parent = pad

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "SAHUR REBIRTH"
	label.TextColor3 = Color3.fromRGB(235, 200, 255)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard
	self.rebirthLabel = label

	-- keyed by UserId, not by Player, so leaving players aren't kept alive
	local debounce: { [number]: number } = {}
	pad.Touched:Connect(function(hit)
		local player = self:playerFromHit(hit)
		if not player or player ~= self.owner then
			return
		end
		local last = debounce[player.UserId]
		if last and os.clock() - last < 3 then
			return
		end
		debounce[player.UserId] = os.clock()
		Economy.notify(player, {
			kind = "rebirthPrompt",
			title = "SAHUR REBIRTH",
			body = ("Wipe your factory for a permanent x%.2f payout boost?"):format(Config.Rebirth.MultiplierPerRebirth),
			cost = Economy.rebirthCost(player),
		})
	end)
end

-- ── buttons ──────────────────────────────────────────────────────────────────

function Tycoon:buttonPosition(def): Vector3
	if def.kind == "Dropper" then
		local sign = (def.slot % 2 == 1) and -1 or 1
		return Vector3.new(sign * L.ButtonSideX, 0, L.DropperZ[def.slot])
	elseif def.kind == "Upgrader" then
		local sign = (def.slot % 2 == 1) and 1 or -1
		return Vector3.new(sign * L.ButtonSideX, 0, L.UpgraderZ[def.slot])
	end
	return MISC_SPOTS[def.id] or Vector3.new(0, 0, 0)
end

function Tycoon:buildButtons()
	for _, def in ipairs(Config.Buttons) do
		local pos = self:buttonPosition(def)
		local base = self:at(pos.X, 0, pos.Z)

		local holder = Instance.new("Model")
		holder.Name = "Btn_" .. def.id
		holder.Parent = self.buttonsFolder

		newPart(holder, "Pedestal", Vector3.new(7, 3, 7), base * CFrame.new(0, 1.5, 0), COLORS.frame, Enum.Material.DiamondPlate)

		local pad = newPart(holder, "Pad", Vector3.new(6, 1, 6), base * CFrame.new(0, 3.4, 0),
			COLORS.buttonOn, Enum.Material.Neon)
		pad.CanCollide = false
		pad:SetAttribute("ButtonId", def.id)

		local light = Instance.new("PointLight")
		light.Color = COLORS.buttonOn
		light.Range = 14
		light.Brightness = 1.6
		light.Shadows = false
		light.Parent = pad

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Info"
		billboard.Size = UDim2.fromScale(15, 7)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 6.5, 0)
		billboard.MaxDistance = 190
		billboard.Parent = pad

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromRGB(20, 16, 30)
		frame.BackgroundTransparency = 0.2
		frame.BorderSizePixel = 0
		frame.Parent = billboard
		Util.roundedFrame(frame, 10)

		local stroke = Instance.new("UIStroke")
		stroke.Color = COLORS.buttonOn
		stroke.Thickness = 2.5
		stroke.Parent = frame

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(0.94, 0.4)
		title.Position = UDim2.fromScale(0.03, 0.05)
		title.Font = Enum.Font.FredokaOne
		title.Text = def.name
		title.TextColor3 = Color3.fromRGB(255, 240, 210)
		title.TextScaled = true
		title.Parent = frame

		local price = Instance.new("TextLabel")
		price.Name = "Price"
		price.BackgroundTransparency = 1
		price.Size = UDim2.fromScale(0.94, 0.3)
		price.Position = UDim2.fromScale(0.03, 0.44)
		price.Font = Enum.Font.GothamBold
		price.Text = "$" .. Util.abbreviate(def.price)
		price.TextColor3 = COLORS.buttonOn
		price.TextScaled = true
		price.Parent = frame

		local blurb = Instance.new("TextLabel")
		blurb.Name = "Blurb"
		blurb.BackgroundTransparency = 1
		blurb.Size = UDim2.fromScale(0.94, 0.22)
		blurb.Position = UDim2.fromScale(0.03, 0.74)
		blurb.Font = Enum.Font.Gotham
		blurb.Text = def.blurb or ""
		blurb.TextColor3 = Color3.fromRGB(180, 168, 200)
		blurb.TextScaled = true
		blurb.Parent = frame

		local lastTouch = 0
		pad.Touched:Connect(function(hit)
			if os.clock() - lastTouch < 0.35 then
				return
			end
			lastTouch = os.clock()
			local player = self:playerFromHit(hit)
			if player then
				self:tryPurchase(player, def.id)
			end
		end)

		self.objects[def.id] = {
			def = def,
			holder = holder,
			pad = pad,
			stroke = stroke,
			priceLabel = price,
			light = light,
			machine = nil,
		}
	end
end

function Tycoon:requirementsMet(id: string): boolean
	local def = Config.ButtonById[id]
	if not def then
		return false
	end
	for _, req in ipairs(Config.requirementsOf(def)) do
		if not self.owned[req] then
			return false
		end
	end
	return true
end

function Tycoon:refreshButtons()
	for id, entry in pairs(self.objects) do
		local visible = (self.owner ~= nil) and (not self.owned[id]) and self:requirementsMet(id)
		entry.holder.Parent = visible and self.buttonsFolder or nil
		if visible then
			local affordable = self.owner and Economy.get(self.owner) >= entry.def.price
			local color = affordable and COLORS.buttonOn or COLORS.buttonOff
			entry.pad.Color = color
			entry.light.Color = color
			entry.stroke.Color = color
			entry.priceLabel.TextColor3 = color
		end
	end
end

-- ── purchasing ───────────────────────────────────────────────────────────────

function Tycoon:playerFromHit(hit: BasePart): Player?
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return game:GetService("Players"):GetPlayerFromCharacter(character)
end

function Tycoon:tryPurchase(player: Player, id: string)
	if player ~= self.owner then
		return
	end
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	if not self:requirementsMet(id) then
		return
	end
	if not Economy.spend(player, def.price) then
		local short = def.price - Economy.get(player)
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("You need %s more for %s."):format(Util.abbreviate(short), def.name),
		})
		return
	end

	local profile = DataService.get(player)
	if profile then
		profile.owned[id] = true
	end

	self:install(id, false)

	Economy.notify(player, {
		kind = "buy",
		title = def.name,
		body = def.blurb or "",
		price = def.price,
	})
	Economy.push(player)
end

--- Applies a purchase. `silent` skips effects (used when loading a save).
function Tycoon:install(id: string, silent: boolean?)
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	self.owned[id] = true

	local entry = self.objects[id]
	if entry then
		entry.holder.Parent = nil
	end

	local installer = Tycoon.INSTALLERS[def.kind]
	if installer then
		installer(self, def, silent)
	else
		warn("[Tung] no installer for kind " .. tostring(def.kind))
	end

	if not silent then
		local pos = self:buttonPosition(def)
		local variant = Config.Variants[def.variant or "classic"]
		Fx.burst((self:at(pos.X, 5, pos.Z)).Position, variant.wood, 18, self.model)
	end

	self:refreshButtons()
end

-- ── installers ───────────────────────────────────────────────────────────────

Tycoon.INSTALLERS = {}

Tycoon.INSTALLERS.Dropper = function(self, def, silent)
	local sign = (def.slot % 2 == 1) and -1 or 1
	local z = L.DropperZ[def.slot]
	local x = sign * L.DropperSideX
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Dropper_" .. def.id
	model.Parent = self.machines

	-- machine body
	newPart(model, "Base", Vector3.new(7, 7, 7), self:at(x, 3.5, z), COLORS.frame, Enum.Material.DiamondPlate)
	local core = newPart(model, "Core", Vector3.new(5, 3.4, 5), self:at(x, 8.4, z), variant.wood, variant.material)
	Fx.applyVariant(core, variant)

	-- arm reaching over the belt
	local armLength = math.abs(x) + 1
	newPart(model, "Arm", Vector3.new(armLength, 1.2, 1.6), self:at(x - sign * armLength / 2, L.BeltY + 9.4, z),
		COLORS.metal, Enum.Material.Metal)

	local spout = newPart(model, "Spout", Vector3.new(3, 2.4, 3), self:at(0, L.BeltY + 8, z), COLORS.metal, Enum.Material.Metal)
	spout.CanCollide = false

	local nozzle = newPart(model, "Nozzle", Vector3.new(2.2, 0.6, 2.2), self:at(0, L.BeltY + 6.6, z),
		variant.light and variant.light.color or variant.wood, Enum.Material.Neon)
	nozzle.CanCollide = false

	-- label
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(10, 3)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.MaxDistance = 150
	billboard.Parent = core

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = def.name .. "  •  $" .. Util.abbreviate(def.dropValue)
	label.TextColor3 = Color3.fromRGB(235, 225, 255)
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Parent = billboard

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end

	-- drop loop
	local generation = self.generation
	task.spawn(function()
		-- stagger so ten droppers don't fire on the same frame
		task.wait(math.random() * def.dropRate)
		while self.generation == generation and self.owned[def.id] and model.Parent do
			self:spawnDrop(def, nozzle)
			task.wait(def.dropRate)
		end
	end)
end

Tycoon.INSTALLERS.Upgrader = function(self, def, silent)
	local z = L.UpgraderZ[def.slot]
	local variant = Config.Variants[def.variant] or Config.Variants.classic
	local halfW = L.BeltWidth / 2 + 1.2

	local model = Instance.new("Model")
	model.Name = "Upgrader_" .. def.id
	model.Parent = self.machines

	for _, sign in ipairs({ -1, 1 }) do
		newPart(model, "Pillar", Vector3.new(2, 11, 3), self:at(sign * halfW, L.BeltY + 5.5, z),
			COLORS.metal, Enum.Material.Metal)
	end
	local beam = newPart(model, "Beam", Vector3.new(halfW * 2 + 2, 2.4, 3.4), self:at(0, L.BeltY + 12, z),
		variant.wood, variant.material)
	Fx.applyVariant(beam, variant)

	local scanner = newPart(model, "Scanner", Vector3.new(L.BeltWidth, 8, 1.2), self:at(0, L.BeltY + 4.4, z),
		variant.light and variant.light.color or variant.wood, Enum.Material.Neon, false)
	scanner.Transparency = 0.55
	scanner.CanTouch = true

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(12, 3.4)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.MaxDistance = 160
	billboard.Parent = beam

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = ("%s  x%.2g"):format(def.name, def.multiplier)
	label.TextColor3 = Color3.fromRGB(255, 240, 210)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Parent = billboard

	local flagName = "up_" .. def.id
	scanner.Touched:Connect(function(hit)
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
			Fx.burst(body.Position, variant.wood, 5, self.model)
			Fx.tung(body, 1.15 + math.random() * 0.2, 0.12)
		end
	end)

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Belt = function(self, def, silent)
	self.beltSpeed += def.speedBonus
	if self.beltSurface then
		self.beltSurface.Color = Color3.fromRGB(92, 70, 40)
	end
	-- retro-apply to drops already rolling
	for _, drop in ipairs(self.drops:GetChildren()) do
		local mover = drop:FindFirstChildWhichIsA("LinearVelocity", true)
		if mover then
			mover.PlaneVelocity = Vector2.new(self.beltSpeed, 0)
		end
	end
end

Tycoon.INSTALLERS.Gear = function(self, def, silent)
	local owner = self.owner
	if owner then
		CombatService.grantBat(owner, def.grants)
	end

	local model = Instance.new("Model")
	model.Name = "Gear_" .. def.id
	model.Parent = self.machines

	local spot = MISC_SPOTS[def.id] or Vector3.new(0, 0, 0)
	local anvilCF = self:at(spot.X + (spot.X < 0 and 10 or -10), 0, spot.Z)
	newPart(model, "Anvil", Vector3.new(8, 4, 6), anvilCF * CFrame.new(0, 2, 0), COLORS.metal, Enum.Material.Metal)

	local batDef = Config.BatById[def.grants]
	if batDef then
		local display = TungModels.buildStatue(batDef.variant, 1.1)
		display:PivotTo(anvilCF * CFrame.new(0, 8, 0))
		display.Parent = model
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

Tycoon.INSTALLERS.Structure = function(self, def, silent)
	local model = Instance.new("Model")
	model.Name = "Structure_" .. def.id
	model.Parent = self.machines

	local halfX = W.PlotSize.X / 2 - 1
	local halfZ = W.PlotSize.Z / 2 - 1

	if def.structure == "walls" then
		local h = 16
		local specs = {
			{ Vector3.new(W.PlotSize.X, h, 2), CFrame.new(0, h / 2, -halfZ) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(halfX, h / 2, 0) },
			{ Vector3.new(2, h, W.PlotSize.Z), CFrame.new(-halfX, h / 2, 0) },
			-- front wall in two pieces, leaving a gateway
			{ Vector3.new(W.PlotSize.X / 2 - 8, h, 2), CFrame.new(-(W.PlotSize.X / 4 + 4), h / 2, halfZ) },
			{ Vector3.new(W.PlotSize.X / 2 - 8, h, 2), CFrame.new(W.PlotSize.X / 4 + 4, h / 2, halfZ) },
		}
		for i, spec in ipairs(specs) do
			newPart(model, "Wall" .. i, spec[1], self.cf * spec[2], Color3.fromRGB(150, 111, 74), Enum.Material.WoodPlanks)
			newPart(model, "Trim" .. i, spec[1] + Vector3.new(0.4, -h + 1, 0.4),
				self.cf * spec[2] * CFrame.new(0, h / 2, 0), COLORS.beltLine, Enum.Material.Neon, false)
		end
	elseif def.structure == "roof" then
		local roof = newPart(model, "Roof", Vector3.new(W.PlotSize.X, 1.6, W.PlotSize.Z),
			self:at(0, 26, 0), Color3.fromRGB(138, 88, 58), Enum.Material.WoodPlanks)
		roof.CanCollide = true
		for _, sign in ipairs({ -1, 1 }) do
			for _, signZ in ipairs({ -1, 1 }) do
				newPart(model, "Column", Vector3.new(3, 26, 3),
					self:at(sign * (halfX - 4), 13, signZ * (halfZ - 4)), Color3.fromRGB(150, 111, 74), Enum.Material.Wood)
			end
		end

		local signAnchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1), self:at(0, 33, 0), COLORS.frame, nil, false)
		signAnchor.Transparency = 1
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromScale(46, 12)
		billboard.MaxDistance = 700
		billboard.Parent = signAnchor
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = "TUNG TUNG TUNG SAHUR CO."
		label.TextColor3 = COLORS.gold
		label.TextStrokeTransparency = 0.15
		label.TextScaled = true
		label.Parent = billboard
		self.roofSign = label
		self:updateSign()
	end

	local entry = self.objects[def.id]
	if entry then
		entry.machine = model
	end
end

-- ── drops ────────────────────────────────────────────────────────────────────

function Tycoon:spawnDrop(def, nozzle: BasePart)
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

	local body = drop.PrimaryPart :: BasePart
	local jitter = (math.random() - 0.5) * (L.BeltWidth * 0.4)

	-- NOTE: the model's pivot is the body, so PivotTo overwrites the body's
	-- rotation outright. The upright orientation has to be baked into the
	-- target CFrame or every drop spawns lying on its side.
	local upright = TungModels.dropOrientation(self:beltDirection())
	local spawnPosition = nozzle.Position + self:beltRight() * jitter - Vector3.new(0, 1.5, 0)
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
	mover.PrimaryTangentAxis = self:beltDirection()
	mover.SecondaryTangentAxis = self:beltRight()
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

-- ── income readout ───────────────────────────────────────────────────────────

--- Estimated Tung/second with everything currently installed.
function Tycoon:incomePerSecond(): number
	local upgradeMult = 1
	for id, owned in pairs(self.owned) do
		local def = Config.ButtonById[id]
		if owned and def and def.kind == "Upgrader" then
			upgradeMult *= def.multiplier
		end
	end
	local total = 0
	for id, owned in pairs(self.owned) do
		local def = Config.ButtonById[id]
		if owned and def and def.kind == "Dropper" then
			total += (def.dropValue / def.dropRate)
		end
	end
	local rebirthMult = self.owner and Economy.multiplier(self.owner) or 1
	return total * upgradeMult * rebirthMult
end

function Tycoon:updateSign()
	local ownerName = self.owner and self.owner.DisplayName or nil
	local sign = self.model:FindFirstChild("Totem")
	local billboard = sign and sign:FindFirstChild("Sign")
	-- the label lives inside a Frame inside the BillboardGui, so this lookup
	-- has to be recursive or it silently returns nil forever
	local label = billboard and billboard:FindFirstChild("Owner", true)
	if label then
		if ownerName then
			label.Text = ("%s's TUNG FACTORY\n%s Tung/sec"):format(ownerName, Util.abbreviate(self:incomePerSecond()))
		else
			label.Text = ("UNCLAIMED PLOT %d\nstep on the pad to claim"):format(self.index)
		end
	end
	if self.vaultLabel then
		self.vaultLabel.Text = ownerName
			and ("SAHUR VAULT  •  %s/sec"):format(Util.abbreviate(self:incomePerSecond()))
			or "SAHUR VAULT"
	end
	if self.claimPad then
		self.claimPad.Transparency = ownerName and 1 or 0
		self.claimPad.CanTouch = ownerName == nil
	end
	if self.claimLabel then
		self.claimLabel.Parent.Enabled = ownerName == nil
	end
	if self.rebirthLabel and self.owner then
		self.rebirthLabel.Text = ("SAHUR REBIRTH\n%s"):format(Util.abbreviate(Economy.rebirthCost(self.owner)))
	end
end

-- ── ownership ────────────────────────────────────────────────────────────────

function Tycoon:assign(player: Player)
	if self.owner then
		return false
	end
	self.owner = player
	self.generation += 1

	local profile = DataService.get(player)
	if profile then
		-- rebuild everything they had, cheapest-first so requirements resolve
		local ids = {}
		for id, owned in pairs(profile.owned) do
			if owned and Config.ButtonById[id] then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return Config.ButtonById[a].order < Config.ButtonById[b].order
		end)
		for _, id in ipairs(ids) do
			self:install(id, true)
		end
	end

	self:refreshButtons()
	self:updateSign()
	return true
end

function Tycoon:release()
	self.owner = nil
	self.generation += 1
	self.owned = {}
	self.beltSpeed = L.BeltSpeed

	for _, entry in pairs(self.objects) do
		if entry.machine then
			entry.machine:Destroy()
			entry.machine = nil
		end
	end
	self.machines:ClearAllChildren()
	self:clearDrops()

	if self.beltSurface then
		self.beltSurface.Color = COLORS.belt
	end
	self.roofSign = nil

	self:refreshButtons()
	self:updateSign()
end

--- Wipes the factory but keeps the player, and hands out a rebirth.
function Tycoon:rebirth(player: Player): boolean
	if player ~= self.owner then
		return false
	end
	local profile = DataService.get(player)
	if not profile then
		return false
	end
	local cost = Economy.rebirthCost(player)
	if profile.rebirths >= Config.Rebirth.MaxRebirths then
		Economy.notify(player, { kind = "warn", title = "Max rebirths", body = "You have ascended as far as sahur allows." })
		return false
	end
	if profile.cash < cost then
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("Rebirth costs %s."):format(Util.abbreviate(cost)),
		})
		return false
	end

	profile.rebirths += 1
	profile.cash = Config.Economy.StartingCash
	profile.owned = {}

	self.generation += 1
	self.owned = {}
	self.beltSpeed = L.BeltSpeed
	for _, entry in pairs(self.objects) do
		entry.machine = nil
	end
	self.machines:ClearAllChildren()
	self:clearDrops()

	self:refreshButtons()
	self:updateSign()
	Economy.push(player)

	Economy.notify(player, {
		kind = "rebirth",
		title = "SAHUR REBIRTH #" .. profile.rebirths,
		body = ("All payouts are now x%.2f."):format(Economy.multiplier(player)),
	})

	local character = player.Character
	if character and character.PrimaryPart then
		Fx.burst(character:GetPivot().Position, Color3.fromRGB(200, 120, 255), 60, workspace)
	end
	return true
end

return Tycoon
