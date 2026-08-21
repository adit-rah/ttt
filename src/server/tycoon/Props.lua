--[[
	tycoon/Props.lua — the furniture around the belt: the claim rig, the rebirth
	pad, the side-track cabinets and their signs, the generator yard and the
	generator standing on it.

	THE self.props / self.machines SPLIT IS THE POINT OF THIS FILE. Cabinet
	bodies and the yard slab go in self.props; the generator that stands on the
	yard is a machine, so a rebirth — machines:ClearAllChildren() — takes it down
	and leaves the slab standing. release() clears props as well, because the
	next owner has different tiers, and that is why ensureCabinets and ensureYard
	are IDEMPOTENT and re-run from refreshButtons. ensureYard used to be
	buildYard(), called once from the constructor: the first owner to leave a plot
	took its slab and fence with them for the rest of the server's life, and
	every later owner bought generators that stood in mid-air.

	refreshGenerator is DERIVED STATE, not an install side effect. It shows the
	LAST owned power rung — the same rule Config.powerFactor uses, because the
	factor is cumulative and so is the machine that represents it — and rebuilds
	only when that rung changes, so the refresh on every purchase costs one
	attribute read. It deliberately does not write self.objects[id].machine: four
	button entries would share one model handle and release() would destroy
	through one of them and leave three dangling.

	NO SIGN ON THE YARD, and if one is ever wanted it must not go in
	self.cabinetSigns — updateCabinetSigns rewrites everything in that map with
	the cabinet format string, which is how a "POWER YARD" board came to read
	"POWER CABINET - 0/4".
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

--- mechanism: the side-track cabinets — a display case standing behind each
--- track's column of buy buttons.
---
--- These carry the wayfinding that the side tracks would otherwise have to
--- take from `pointAt`. There is exactly ONE Highlight per plot and it belongs
--- to the factory (Highlight is capped at 255 per client and disabled ones
--- still occupy a slot), so a cabinet announces itself with a sign instead —
--- which is better anyway, because a sign can say what it is and a glow
--- cannot.
--- Builds the cabinets a plot has earned, and takes down the ones it has not.
---
--- Called from the constructor and again on every ownership change, because a
--- cabinet is no longer permanent plot furniture: it arrives with the second
--- floor, it goes when the plot is released, and it survives a rebirth on the
--- strength of the tiers you keep. Idempotent, so calling it on every purchase
--- costs a table walk and nothing else.
function Tycoon:ensureCabinets()
	self.cabinetSigns = self.cabinetSigns or {}

	for _, track in ipairs(Config.TrackOrder) do
		if track ~= "factory" and Config.Layout.Tracks[track] then
			local existing = self.props:FindFirstChild("Cabinet_" .. track)
			local wanted = Config.trackUnlocked(track, self.owned)

			if not wanted then
				if existing then
					existing:Destroy()
					self.cabinetSigns[track] = nil
				end
				continue
			end
			if existing then
				continue
			end

			local centre, size = Config.trackCabinet(track)
			local model = Instance.new("Model")
			model.Name = "Cabinet_" .. track
			model.Parent = self.props

			-- centre.Y, NOT ZERO. Both side tracks stand on the mezzanine now
			-- (Layout.Tracks names floor = "mezzanine" and Config.trackCabinet takes
			-- its Y from Config.floorTopY), and this line is the twin of the bug
			-- Tycoon:buttonBaseCF was written to fix: the height was thrown away in
			-- every conversion from a stated position to a CFrame, so anything an
			-- upper floor unlocked was built on the ground floor underneath the deck.
			-- Config.TrackUnlock has gated both cabinets on floor2 for two rounds —
			-- the mezzanine was already what opened them, and they were downstairs.
			local baseCF = self:at(centre.X, centre.Y, centre.Z)
			newPart(model, "Back", size, baseCF * CFrame.new(0, size.Y / 2, 0),
				COLORS.metal, Enum.Material.Metal, true)
			newPart(model, "Trim", Vector3.new(size.X + 1.2, 0.8, size.Z + 1.2),
				baseCF * CFrame.new(0, size.Y + 0.4, 0), COLORS.gold, Enum.Material.Metal, false)

			local anchor = newPart(model, "SignAnchor", Vector3.new(1, 1, 1),
				baseCF * CFrame.new(0, size.Y + 2.5, 0), COLORS.metal, Enum.Material.Metal, false)
			anchor.Transparency = 1

			local billboard = Style.billboard(anchor, {
				name = "Sign", width = 18, height = 4, distance = "prop",
			})
			local label = Style.text(billboard, {
				name = "Label", color = COLORS.gold,
				text = (Config.TrackLabel[track] or track:upper()) .. " CABINET",
			})

			self.cabinetSigns[track] = label
		end
	end
end

--- invariant: the generator yard — a small slab behind the plot's back-right
--- corner, with a fence around three sides of it.
---
--- Permanent plot furniture in self.props, exactly like a cabinet body. The
--- GENERATOR that stands on it goes into self.machines instead, so a rebirth
--- takes it down with the droppers it was speeding up and leaves the yard
--- standing — the same split the cabinets and their shelf displays already use.
---
--- IDEMPOTENT AND RE-RUN FROM refreshButtons, for the same reason
--- ensureCabinets is. release() does props:ClearAllChildren(), so a yard built
--- once from the constructor goes with the first owner who leaves and never
--- comes back: every subsequent owner buys generators that stand in mid-air.
---
--- NO SIGN, and if one is ever wanted it must NOT go in self.cabinetSigns —
--- updateCabinetSigns rewrites everything in there with the cabinet format
--- string, which is how a "POWER YARD" billboard came to read
--- "POWER CABINET - 0/4". design:D-09: the pad twelve studs away already
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

--- Keeps each cabinet sign honest about how far up its track you are.
function Tycoon:updateCabinetSigns()
	if not self.cabinetSigns then
		return
	end
	for track, label in pairs(self.cabinetSigns) do
		-- a cabinet that has been taken down leaves its sign behind in this map
		if not label.Parent then
			self.cabinetSigns[track] = nil
			continue
		end
		local defs = Config.Tracks[track]
		local owned = 0
		for _, def in ipairs(defs) do
			if self.owned[def.id] then
				owned += 1
			end
		end
		label.Text = ("%s CABINET  •  %d/%d"):format(
			Config.TrackLabel[track] or track:upper(), owned, #defs)
	end
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
