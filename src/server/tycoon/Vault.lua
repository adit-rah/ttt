--[[
	tycoon/Vault.lua — the collector at the end of a belt, the gauge on its side,
	and where a drop's ride ends.

	onCollect RETIRES A DROP. design:D-02 — income is Config.incomeRate on a
	timer (tycoon/Income.lua:startIncomeLoop) and no part carries value, so the
	collector's job is to take a finished drop off the belt, return its slot to
	the visual budget, and play the payout dressing. It claims the drop with a
	Collected flag because Touched fires twice. A drop the sensor does not see
	stands at the run-off until the reaper takes it, holding a budget slot the
	whole time — which is why buildCollector ASSERTS that the vault shell stays
	downstream of the run-off and why the trigger is Layout.TriggerThickness
	deep rather than one stud.

	setVaultGauge DECIDES NOTHING. All four of its values are worked out by
	VaultService, which is the module allowed to know what offline earnings are.
	Nothing in this folder may require SessionService: it derives income from a
	SAVED profile precisely so an absent player can be paid with no plot to ask,
	and it is required BY the service that draws this gauge.

	The gauge is bottom-anchored and floored at MIN_PART. Roblox silently keeps
	the old size rather than erroring on a part thinner than 0.05 on any axis, so
	an empty gauge that failed to resize would read as whatever it last held.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Fx = Req("Fx")
local TungModels = Req("TungModels")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local newPart = Parts.newPart
local COLORS = Tycoon.COLORS
local MIN_PART = Tycoon.MIN_PART

local L = Config.Layout
local OV = Config.Offline.Vault

-- ── collector ────────────────────────────────────────────────────────────────

--- One path's way INTO a collector: the run-off ramp, the collect sensor and
--- the funnel mouth at the end of its last leg. Its own method (#162) because
--- the ground floor is two mirrored paths feeding one vault — the shell is
--- built once by buildCollector and each path brings its own intake.
function Tycoon:buildCollectorIntake(pathIndex: number, folder: Instance,
	bodyDepth: number, bodyWidth: number)
	local path = self:beltPath(pathIndex)
	local _, beltEnd, exitDir = self:leg(self:legCount(pathIndex), pathIndex)
	local runOff = (path.collectorAt - beltEnd).Magnitude

	local function alongExit(distance, y, lateral)
		local point = beltEnd + exitDir * distance + Vector3.new(0, y + path.y, 0)
			+ Vector3.new(-exitDir.Z, 0, exitDir.X) * (lateral or 0)
		return self.cf * CFrame.lookAt(point, point + exitDir)
	end

	-- funnel mouth facing back down the belt
	local mouth = newPart(folder, "Mouth", Vector3.new(bodyWidth - 6, 6, 1.5),
		alongExit(runOff - bodyDepth / 2 - 0.5, L.BeltY + 3, 0),
		Color3.fromRGB(30, 24, 40), Enum.Material.Neon, false)
	mouth.Transparency = 0.5

	-- run-off ramp carrying drops off the end of the belt into the sensor
	local ramp = newPart(folder, "Ramp", Vector3.new(L.BeltWidth, 0.6, 5), alongExit(2.4, L.BeltY - 0.2, 0),
		COLORS.belt, Enum.Material.SmoothPlastic)
	ramp.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)

	-- The most expensive one to miss: a drop the collector does not see is 100%
	-- of its value, not a fraction of it. It sits at alongExit(2), so at 5
	-- thick it spans -0.5..4.5 against a vault mouth well downstream — no
	-- overlap.
	local sensor = newPart(folder, "Sensor", Vector3.new(L.BeltWidth + 3, 7, L.TriggerThickness),
		alongExit(2, L.BeltY + 3, 0),
		Color3.fromRGB(255, 255, 255), Enum.Material.Neon, false)
	sensor.Transparency = 1
	sensor.CanTouch = true

	sensor.Touched:Connect(function(hit)
		self:onCollect(hit)
	end)
end

--- Run-off ramp, collect sensor and the body that catches the drops, at the end
--- of a path's last leg.
---
--- `headline` adds the vault dressing — gold trim, statue, income sign. Only
--- the ground floor gets it: a second statue on every upper floor is noise, and
--- the income readout on it would be wrong anyway (it reports the whole plot).
function Tycoon:buildCollector(pathIndex: number?, parent: Instance?, headline: boolean?)
	pathIndex = pathIndex or 1
	local path = self:beltPath(pathIndex)

	local folder = parent
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Collector"
		folder.Parent = self.model
		self.collectorFolder = folder
		self:registerFactoryFolder(folder)
	end

	-- The catcher sits past the end of the last leg. Its shell must stay
	-- entirely DOWNSTREAM of the sensor: a solid body overlapping the run-off
	-- walls the belt off and nothing can ever be collected.
	local _, beltEnd, exitDir = self:leg(self:legCount(pathIndex), pathIndex)
	local V = L.Vault
	local bodyDepth = headline and V.bodyDepth or V.plainDepth
	local bodyWidth = headline and V.bodyWidth or V.plainWidth
	local bodyHeight = headline and V.bodyHeight or V.plainHeight
	local centre = path.collectorAt
	local runOff = (centre - beltEnd).Magnitude
	assert(runOff > bodyDepth / 2 + 3,
		("Collector body overlaps the belt run-off on path %q; move its collectorAt further out"):format(tostring(path.id)))

	-- Path-local: `y` is measured from the floor this belt runs on, exactly as
	-- it is everywhere else on the path.
	local function alongExit(distance, y, lateral)
		local point = beltEnd + exitDir * distance + Vector3.new(0, y + path.y, 0)
			+ Vector3.new(-exitDir.Z, 0, exitDir.X) * (lateral or 0)
		return self.cf * CFrame.lookAt(point, point + exitDir)
	end

	local base = newPart(folder, "VaultBase", Vector3.new(bodyWidth, bodyHeight, bodyDepth),
		alongExit(runOff, bodyHeight / 2, 0), COLORS.vault, Enum.Material.WoodPlanks)
	newPart(folder, "VaultTrim", Vector3.new(bodyWidth + 1, 1.2, bodyDepth + 1),
		alongExit(runOff, bodyHeight + 0.4, 0), COLORS.gold, Enum.Material.Metal)

	self:buildCollectorIntake(pathIndex, folder, bodyDepth, bodyWidth)

	if not headline then
		return
	end

	-- sign
	local signAnchor = newPart(folder, "SignAnchor", Vector3.new(1, 1, 1), alongExit(runOff, V.signY, 0), COLORS.vault, nil, false)
	signAnchor.Transparency = 1

	local billboard = Style.billboard(signAnchor, {
		name = "Sign", width = V.signWidth, height = V.signHeight, distance = OV.Distance,
	})
	local label = Style.text(billboard, {
		name = "Rate", text = "SAHUR VAULT", color = COLORS.gold,
	})
	self.vaultLabel = label

	-- THE GAUGE, and it goes on a SIDE of the vault rather than on top of it.
	--
	-- The lid is spoken for three times over — trim at bodyHeight + 0.4, the
	-- 20x6 board spanning y 9..15, the statue above that — so a column on the
	-- roof would grow straight through two of them. The lateral faces are the
	-- only clear ones, and of the two only one faces the open floor: with the
	-- vault at back-centre (#162), that is the FRONT face, looking straight
	-- down the aisle at the gate.
	--
	-- WHICH SIGN THAT IS depends on the last leg's exit direction. alongExit
	-- puts lateral on (-exitDir.Z, 0, exitDir.X); this is built off the WEST
	-- path, which exits along +X, making that perpendicular +Z — so a
	-- POSITIVE lateral lands on the front face and a negative one in the gap
	-- behind the vault. Derived, not measured: UNVERIFIED IN STUDIO.
	local w = V.window
	local windowCF = alongExit(runOff, w.y, w.lateral)
	local window = newPart(folder, "FillWindow", Vector3.new(w.thickness, w.height, w.width),
		windowCF, COLORS.gold, Enum.Material.Glass, false)
	window.Transparency = 0.55
	-- CanQuery off as well as CanCollide: a pane in front of the vault body is
	-- exactly the sort of thing a raycast-driven prompt or a camera collision
	-- would otherwise catch on.
	window.CanQuery = false
	self.vaultWindow = window

	-- The gold inside the pane. Built at FULL height and centred, which is the
	-- pose setVaultGauge measures its offsets against — see vaultFillBase.
	local fill = newPart(folder, "FillBody",
		Vector3.new(w.thickness * 0.55, w.height, w.width - 0.8),
		windowCF, COLORS.gold, Enum.Material.Neon, false)
	fill.CanQuery = false
	self.vaultFill = fill
	self.vaultFillBase = windowCF

	-- The small print, bolted UNDER the pane on the same face. Its own tier:
	-- the headline is the plot's number and carries to the arena, the
	-- arithmetic behind it only has to resolve once you are standing here.
	local detailAnchor = newPart(folder, "DetailAnchor", Vector3.new(1, 1, 1),
		alongExit(runOff, V.detailSignY, V.detailLateral), COLORS.vault, nil, false)
	detailAnchor.Transparency = 1
	local detailBoard = Style.billboard(detailAnchor, {
		name = "Detail", width = V.detailWidth, height = V.detailHeight, distance = OV.NearDistance,
	})
	self.vaultDetailLabel = Style.text(detailBoard, {
		name = "Detail", text = "", color = COLORS.gold, weight = "body",
	})

	-- The claim. A ProximityPrompt rather than a remote, because the intent
	-- here has no payload at all: there is no amount for a client to send and
	-- therefore none for the server to have to disbelieve. VaultService hangs
	-- the handler on it — Tycoon does not know what offline earnings are.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CollectOffline"
	prompt.ActionText = "Collect"
	prompt.ObjectText = "Sahur Vault"
	prompt.HoldDuration = OV.PromptHoldSeconds
	prompt.MaxActivationDistance = OV.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false          -- nothing banked until something is
	prompt.Parent = base
	self.vaultPrompt = prompt

	-- The body doubles as the storage unit (#93): health, brokenness and the
	-- repair prompt all hang on this same base. Storage.lua owns that state.
	self:buildStorageUnit(base)

	-- Facing the gate: the frame looks along the west path's +X exit, so a
	-- quarter turn the other way points the statue down the aisle at the
	-- gateway. UNVERIFIED IN STUDIO, same as the gauge face.
	local statue = TungModels.buildStatue("classic", V.statueScale)
	statue:PivotTo(alongExit(runOff, V.statueY, 0) * CFrame.Angles(0, -math.pi / 2, 0))
	statue.Parent = folder
	self.vaultStatue = statue
end

--- Writes the vault gauge. THE ONLY THING IN THIS FILE THAT DRAWS IT, and it
--- decides nothing: every one of these four values is worked out by
--- VaultService, which is the module allowed to know what offline earnings are.
--- Tycoon must not require SessionService — SessionService derives income from
--- a SAVED profile precisely so it never has to reach for a live plot — so the
--- arrow points one way and this is the far end of it.
---
---   fraction  0..1 of the window, bottom-anchored
---   headline  the 20x6 board, or nil to hand it back to updateSign
---   detail    the small print under the pane
---   waiting   true when there is a real grant to collect, which is also the
---             only state the prompt is live in
function Tycoon:setVaultGauge(fraction: number, headline: string?, detail: string?, waiting: boolean?)
	self.vaultHeadline = headline
	if self.vaultLabel and self.vaultLabel.Parent and headline then
		self.vaultLabel.Text = headline
	end
	if self.vaultDetailLabel and self.vaultDetailLabel.Parent then
		self.vaultDetailLabel.Text = detail or ""
	end

	local fill = self.vaultFill
	if fill and fill.Parent then
		local full = L.Vault.window.height
		-- MIN_PART, not zero: Roblox rejects a part thinner than 0.05 on any
		-- axis, and an empty gauge that failed to resize would keep whatever
		-- height it last had — an empty vault reading as a full one.
		local height = math.max(full * math.clamp(fraction, 0, 1), MIN_PART)
		fill.Size = Vector3.new(fill.Size.X, height, fill.Size.Z)
		-- Bottom-anchored. Resizing a part in Roblox grows it about its centre,
		-- so a gauge left at the window's centre would creep DOWN through the
		-- vault floor as it filled instead of rising up the pane.
		fill.CFrame = self.vaultFillBase * CFrame.new(0, (height - full) / 2, 0)
		fill.Color = waiting and COLORS.gold or COLORS.vaultPromise
		fill.Transparency = waiting and 0 or 0.4
	end

	if self.vaultPrompt and self.vaultPrompt.Parent then
		self.vaultPrompt.Enabled = waiting == true
	end
end

function Tycoon:onCollect(hit: BasePart)
	local model = hit.Parent
	if not model or not model:IsA("Model") then
		return
	end
	if model:GetAttribute("PlotIndex") ~= self.index then
		return
	end
	if model:GetAttribute("Collected") then
		return  -- touch fires twice; the first one claimed it
	end
	model:SetAttribute("Collected", true)

	-- recycleDrop below returns the budget slot; decrementing here as well
	-- would count one drop out twice and starve the spawners.
	local owner = self.owner
	if owner and owner.Parent then
		-- late game the vault eats ~10 drops/sec; throttle the confetti so a
		-- finished factory doesn't spam hundreds of billboards per minute. The
		-- figure quoted is the plot's rate — the drop itself is worth nothing.
		local now = os.clock()
		if now - (self.lastPayoutFx or 0) > 0.3 then
			self.lastPayoutFx = now
			Fx.floatingText(hit.Position + Vector3.new(0, 3, 0),
				"+" .. Util.abbreviate(self:incomePerSecond()) .. "/sec", COLORS.gold, self.model)
			Fx.tung(hit, 0.9 + math.random() * 0.35, 0.18)
		end
	end
	self:recycleDrop(model)
end

return Tycoon
