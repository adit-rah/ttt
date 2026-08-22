--[[
	tycoon/Props.lua — the furniture around the belt: the claim rig, the
	rebirth pad, the generator yard and the generator standing on it. The
	side-track cabinets stood here until #108 moved weapons and armour into
	the shop.

	THE self.props / self.machines SPLIT IS THE POINT OF THIS FILE. The yard
	slab goes in self.props; the generator that stands on the yard is a
	machine, so a rebirth — machines:ClearAllChildren() — takes it down and
	leaves the slab standing. release() clears props as well, and that is why
	ensureYard is IDEMPOTENT and re-run from refreshButtons. It used to be
	buildYard(), called once from the constructor: the first owner to leave a
	plot took its slab and fence with them for the rest of the server's life,
	and every later owner bought generators that stood in mid-air.

	refreshGenerator is DERIVED STATE, not an install side effect. It shows the
	LAST owned power rung — the same rule Config.powerFactor uses, because the
	factor is cumulative and so is the machine that represents it — and rebuilds
	only when that rung changes, so the refresh on every purchase costs one
	attribute read. It deliberately does not write self.objects[id].machine: four
	button entries would share one model handle and release() would destroy
	through one of them and leave three dangling.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Fx = Req("Fx")
local Economy = Req("Economy")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local newPart = Parts.newPart
local COLORS = Tycoon.COLORS

local L = Config.Layout

-- ── claim pad ────────────────────────────────────────────────────────────────

function Tycoon:buildClaimPad()
	local folder = Instance.new("Folder")
	folder.Name = "Claim"
	folder.Parent = self.model
	self.claimFolder = folder

	local frontX, frontZ = L.ClaimPadAt.X, L.ClaimPadAt.Z

	-- The pad itself. Safe to centre now that the factory is hidden while
	-- unclaimed -- there is nothing standing on the frontage to hide behind.
	local pad = newPart(folder, "ClaimPad", Vector3.new(34, 1.2, 20),
		self:at(frontX, 0.6, frontZ), Color3.fromRGB(120, 230, 160), Enum.Material.Neon)
	pad.CanCollide = false
	pad:SetAttribute("PlotIndex", self.index)
	self.claimPad = pad

	-- A beacon, because a flat pad on the floor is invisible from more than a
	-- few studs away or from any angle that isn't directly above it. THIS is
	-- the thing you actually navigate by.
	local beacon = newPart(folder, "ClaimBeacon", Vector3.new(7, 80, 7),
		self:at(frontX, 40, frontZ), Color3.fromRGB(120, 255, 170), Enum.Material.Neon, false)
	beacon.Transparency = 0.55
	beacon.CanQuery = false

	local halo = newPart(folder, "ClaimHalo", Vector3.new(0.6, 44, 44),
		self:at(frontX, 0.35, frontZ) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(80, 220, 130), Enum.Material.Neon, false)
	halo.Shape = Enum.PartType.Cylinder
	halo.Transparency = 0.4
	halo.CanQuery = false

	-- Sign high up the beacon so it clears the walls of neighbouring plots and
	-- is readable from the arena.
	local signAnchor = newPart(folder, "ClaimSign", Vector3.new(1, 1, 1),
		self:at(frontX, 62, frontZ), Color3.new(1, 1, 1), nil, false)
	signAnchor.Transparency = 1
	signAnchor.CanQuery = false

	-- `world`, not `plot`: a free plot has to be findable from anywhere on the
	-- ring, and the two furthest-apart plots are a full diameter apart. This is
	-- the one label whose old 1200 was doing a real job rather than being the
	-- number somebody happened to type.
	local billboard = Style.billboard(signAnchor, {
		name = "ClaimSign", width = 34, height = 12, distance = "world",
	})
	local label = Style.text(billboard, {
		text = "PLOT " .. self.index .. "\nFREE — WALK ON IT",
		color = Color3.fromRGB(190, 255, 215),
	})
	self.claimLabel = label
end

-- ── rebirth pad ──────────────────────────────────────────────────────────────

--- invariant: the generator yard — a small slab behind the plot's back-right
--- corner, with a fence around three sides of it.
---
--- Permanent plot furniture in self.props. The GENERATOR that stands on it
--- goes into self.machines instead, so a rebirth takes it down with the
--- droppers it was speeding up and leaves the yard standing.
---
--- IDEMPOTENT AND RE-RUN FROM refreshButtons: release() does
--- props:ClearAllChildren(), so a yard built once from the constructor goes
--- with the first owner who leaves and never comes back: every subsequent
--- owner buys generators that stand in mid-air.
---
--- NO SIGN. design:D-05: the pad twelve studs away already
--- carries the track, the tier name, the effect and the price.
function Tycoon:ensureYard()
	local Y = L.Yard
	if self.props:FindFirstChild("Yard") then
		return
	end
	local model = Instance.new("Model")
	model.Name = "Yard"
	model.Parent = self.props

	newPart(model, "Slab", Y.Size,
		self:at(Y.Centre.X, Y.LocalY - Y.Size.Y / 2, Y.Centre.Z),
		Color3.fromRGB(96, 96, 104), Enum.Material.Concrete)

	-- Fence on three sides. The plot side is left open: it is where you walk in
	-- from, through the doorway the wall leaves for it.
	--
	-- Inset by half its own thickness so it stands ON the slab rather than
	-- straddling the edge. With the yard now flush against the plot's own
	-- x-extent at 60, the old straddling fence would have hung half a stud past
	-- it and made the containment assertion a lie by exactly that much.
	local halfX = Y.Size.X / 2 - Y.FenceThickness / 2
	local halfZ = Y.Size.Z / 2 - Y.FenceThickness / 2
	local sides = {
		{ Vector3.new(Y.Size.X, Y.FenceHeight, Y.FenceThickness), Vector3.new(0, 0, -halfZ) },
		{ Vector3.new(Y.FenceThickness, Y.FenceHeight, Y.Size.Z), Vector3.new(-halfX, 0, 0) },
		{ Vector3.new(Y.FenceThickness, Y.FenceHeight, Y.Size.Z), Vector3.new(halfX, 0, 0) },
	}
	for index, side in ipairs(sides) do
		newPart(model, "Fence" .. index, side[1],
			self:at(Y.Centre.X + side[2].X, Y.LocalY + Y.FenceHeight / 2, Y.Centre.Z + side[2].Z),
			COLORS.frame, Enum.Material.DiamondPlate)
	end
end

--- The one generator, showing the highest power rung this plot owns.
---
--- DERIVED STATE, not an install side effect. It used to be buildYardMachine(),
--- called from INSTALLERS.Power, which built a NEW machine per rung in a slot of
--- its own — four generators standing in a row for a track whose rungs are
--- upgrades of each other. Now each rung replaces the machine in place and the
--- visible change is the variant: golden, crimson, void, infinity.
---
--- Rebuilt only when the tier actually changes, so a refresh on every button
--- purchase costs one attribute read. Lives in self.machines, so a rebirth
--- takes it down and leaves the yard standing.
function Tycoon:refreshGenerator()
	local Y = L.Yard

	-- The LAST owned rung, the same rule Config.powerFactor uses, because
	-- `factor` is cumulative and so is the machine that represents it.
	local top = nil
	for _, def in ipairs(Config.Tracks.power) do
		if self.owned[def.id] then
			top = def
		end
	end

	local existing = self.machines:FindFirstChild("Generator")
	if existing and existing:GetAttribute("PowerId") == (top and top.id or nil) then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	if not top then
		return nil
	end

	local variant = Config.Variants[top.variant] or Config.Variants.classic
	local spot = Config.yardMachinePosition()

	local model = Instance.new("Model")
	model.Name = "Generator"
	model:SetAttribute("PowerId", top.id)
	model.Parent = self.machines

	newPart(model, "Body", Y.MachineSize,
		self:at(spot.X, spot.Y + Y.MachineSize.Y / 2, spot.Z), COLORS.metal, Enum.Material.Metal)
	local core = newPart(model, "Core",
		Vector3.new(Y.MachineSize.X - 4, Y.MachineSize.Y - 5, Y.MachineSize.Z - 4),
		self:at(spot.X, spot.Y + Y.MachineSize.Y / 2, spot.Z),
		variant.light and variant.light.color or variant.wood, Enum.Material.Neon, false)
	core.Transparency = 0.35
	Fx.applyVariant(core, variant)

	-- Deliberately NOT written to self.objects[id].machine. Four button entries
	-- would share one model handle, and release() destroys through one of them
	-- and leaves three dangling. machines:ClearAllChildren() already covers it
	-- in both release() and rebirth().
	return model
end


function Tycoon:buildRebirthPad()
	local folder = Instance.new("Folder")
	folder.Name = "Rebirth"
	folder.Parent = self.model
	self.rebirthFolder = folder
	self:registerFactoryFolder(folder)

	local spot = L.RebirthPadAt
	local pad = newPart(folder, "RebirthPad", Vector3.new(12, 1.2, 12),
		self:at(spot.X, 0.9, spot.Z), Color3.fromRGB(200, 120, 255), Enum.Material.Neon)
	pad.CanCollide = false
	self.rebirthPad = pad

	local ring = newPart(folder, "RebirthRing", Vector3.new(0.4, 16, 16),
		self:at(spot.X, 0.3, spot.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(120, 60, 200), Enum.Material.Neon, false)
	ring.Shape = Enum.PartType.Cylinder

	local billboard = Style.billboard(pad, {
		name = "Sign", width = 16, height = 6, distance = "prop", offset = 6,
	})
	self.rebirthLabel = Style.text(billboard, {
		name = "Label", text = "SAHUR REBIRTH",
		color = Color3.fromRGB(235, 200, 255),
	})

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

return Tycoon
