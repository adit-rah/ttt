--[[
	tycoon/Buttons.lua — the buy buttons: where each one stands, what it says,
	which of its three states it is in, and the ghost of the machine it will
	build.

	THREE STATES, because both obvious designs fail: every button at once gives
	the plot no focal point, and only the next one hides the shape of the build
	from you. available / preview / hidden, with the label's two voices (BTN vs
	BTN_LOCKED) moving five properties together — colour alone is the first
	signal lost to a bright sky or a neon variant standing behind the label.

	refreshButtons IS THE BEAT. It runs on install, assign, release and rebirth,
	plus PlotService's 3-second loop, and it is where ensureCabinets,
	updateCabinetSigns, ensureYard and refreshGenerator hang. Anything that has
	to survive all four of those events, and is idempotent, belongs on this beat
	rather than on a listener of its own; anything expensive does not belong here
	at all.

	buttonBaseCF KEEPS THE HEIGHT. The conversion from a button position to a
	CFrame was written twice and both copies threw the Y away, which put
	everything an upper floor priced on the ground floor underneath its deck. The
	Studio-only assertion in buildButtons is the half of that no config check can
	reach: whether the pad that got built is where buttonPosition said.

	A gated track is HIDDEN, not previewed, and takes no ghost — nine dimmed pads
	with ghost bats on them is the same wall of labels with the brightness turned
	down, and the point of gating the cabinets is that half the plot is bare
	ground until it is earned.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Util = Req("Util")
local Economy = Req("Economy")
local Tycoon = Req("Class")
local Parts = Req("Parts")

local RunService = game:GetService("RunService")

local newPart = Parts.newPart
local MACHINE_MASSES = Parts.MACHINE_MASSES
local COLORS = Tycoon.COLORS
local MISC_SPOTS = Tycoon.MISC_SPOTS

local L = Config.Layout
local BTN = Config.Style.Button
local BTN_LOCKED = Config.Style.ButtonLocked

-- ── buttons ──────────────────────────────────────────────────────────────────

--- Buy buttons line the INBOARD side of the belt, next to the machine they
--- build, so the row you walk along is the row you buy from.
function Tycoon:buttonPosition(def): Vector3
	if def.kind == "Dropper" or def.kind == "Upgrader" then
		local legIndex, distance, pathIndex = self:legOf(def)
		return self:pointOnLeg(legIndex, distance, -L.ButtonOffset, pathIndex)
	end
	-- Dispatched on what KIND of furniture the track has, not on "is it the
	-- factory". The old test sent everything non-factory to a cabinet column,
	-- which is the right answer for a display case standing on the plot floor
	-- and the wrong one for a row of generators on a slab behind it — and
	-- Layout.Tracks has no `power` entry, so it would have indexed nil and
	-- taken the whole plot's construction down with it.
	-- A Line button stands on the deck whose conveyor it buys, so its position
	-- comes from the floor rather than from Layout.MiscButtons — which asserts
	-- y = 0 and would put this pedestal on the ground floor under its own deck.
	if def.kind == "Line" then
		local floor = Config.floorForLineButton(def.id)
		if floor then
			return Config.floorLineButtonPosition(floor)
		end
	end
	local furniture = def.track and Config.TrackInfo[def.track].furniture
	if furniture == "cabinet" then
		return Config.trackButtonPosition(def.track, def.trackOrder)
	elseif furniture == "yard" then
		return Config.yardButtonPosition()
	end
	return MISC_SPOTS[def.id] or Vector3.new(0, 0, 0)
end

--- Where a buy button's pedestal actually stands, height included.
---
--- This exists because the conversion from "button position" to "CFrame" was
--- written twice, and both copies threw the Y away — `self:at(pos.X, 0, pos.Z)`.
--- `buttonPosition` has always returned the right height for a machine on any
--- belt path (pointOnLeg bakes in `path.y`), so the floors prototype could
--- never have a purchasable thing standing on it: everything it priced would
--- have been built on the ground floor underneath the deck. One line, and it
--- was the single blocker for a real second storey.
---
--- IT STOPPED BEING A NO-OP. This used to read "no-op today: every source of a
--- button position returns Y = 0 while there is one ground-level path". Two of the
--- three sources answer with a height now — Config.trackButtonPosition takes its Y
--- from Config.floorTopY, and both side tracks name floor = "mezzanine", so the
--- weapons and armour columns (nine pads, five and four) are built on the deck at
--- y = 22 by this line and nothing else. Layout.MiscButtons is still all on the
--- floor, and the mezzanine's own belt buttons come through pointOnLeg, which bakes
--- in path.y.
---
--- The Studio-only half is the assertion in buildButtons below: whether the pad
--- that got built is where buttonPosition said. No config check can reach it.
function Tycoon:buttonBaseCF(def): CFrame
	local pos = self:buttonPosition(def)
	return self:at(pos.X, pos.Y, pos.Z)
end

function Tycoon:buildButtons()
	for _, def in ipairs(Config.Buttons) do
		local base = self:buttonBaseCF(def)

		local holder = Instance.new("Model")
		holder.Name = "Btn_" .. def.id
		holder.Parent = self.buttonsFolder

		-- Total height is Layout.ButtonHeight (1.4 studs). A Roblox humanoid
		-- steps over ~2 studs without jumping, so you can run straight across
		-- these instead of having to hop onto each one.
		local plinth = L.ButtonHeight * 0.55
		newPart(holder, "Pedestal", Vector3.new(5, plinth, 5), base * CFrame.new(0, plinth / 2, 0),
			COLORS.frame, Enum.Material.DiamondPlate)

		local pad = newPart(holder, "Pad", Vector3.new(4.6, L.ButtonHeight - plinth, 4.6),
			base * CFrame.new(0, (L.ButtonHeight + plinth) / 2, 0), COLORS.buttonOn, Enum.Material.Neon)
		pad.CanCollide = false
		pad:SetAttribute("ButtonId", def.id)

		local light = Instance.new("PointLight")
		light.Color = COLORS.buttonOn
		light.Range = 11
		light.Brightness = 1.4
		light.Shadows = false
		light.Parent = pad

		-- NOT AlwaysOnTop. Hiding behind a wall you are on the wrong side of is
		-- correct; hiding behind a machine two feet away is not, and the x-ray
		-- was covering the second case at the cost of the first — every locked
		-- pad on the plot showed through everything, which is most of why the
		-- plot read as a wall of labels. The label clears the machinery on its
		-- own now, by standing above it (Style.Button.lift, asserted against
		-- Layout.MachineTopY).
		local billboard = Style.billboard(pad, {
			name = "Info", width = BTN.width, height = BTN.height,
			distance = BTN.distance, offset = BTN.lift,
		})

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromRGB(20, 16, 30)
		frame.BackgroundTransparency = BTN.panelAlpha
		frame.BorderSizePixel = 0
		frame.Parent = billboard
		Util.roundedFrame(frame, 10)

		local stroke = Instance.new("UIStroke")
		stroke.Color = COLORS.buttonOn
		stroke.Thickness = BTN.strokeThickness
		stroke.Parent = frame

		-- Four lines, in the order you ask the questions: where am I in the
		-- build, what is this, what does it do for me, what does it cost.
		--
		-- The track name, not a global ordinal. "STEP 21 OF 30" on a pedestal
		-- in front of a weapons cabinet tells you nothing; "WEAPONS 2/5" is
		-- the whole feature explained in three words.
		local step = Style.text(frame, {
			name = "Step", weight = "body",
			size = UDim2.fromScale(0.94, 0.18), position = UDim2.fromScale(0.03, 0.02),
			text = ("%s %d/%d"):format(
				Config.TrackLabel[def.track] or "STEP", def.trackOrder, #Config.Tracks[def.track]),
			color = Color3.fromRGB(150, 142, 172),
		})

		local title = Style.text(frame, {
			name = "Title",
			size = UDim2.fromScale(0.94, 0.32), position = UDim2.fromScale(0.03, 0.2),
			text = def.name, color = Color3.fromRGB(255, 240, 210),
		})

		local effect = Style.text(frame, {
			name = "Effect", weight = "body",
			size = UDim2.fromScale(0.94, 0.22), position = UDim2.fromScale(0.03, 0.52),
			text = def.blurb or "", color = Color3.fromRGB(150, 235, 190),
		})

		local price = Style.text(frame, {
			name = "Price", weight = "body",
			size = UDim2.fromScale(0.94, 0.24), position = UDim2.fromScale(0.03, 0.74),
			color = COLORS.buttonOn,
		})
		price.Text = "$" .. Util.abbreviate(def.price)

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

		-- The half of "buttons honour their height" that no config check can
		-- reach: whether the part that got built is actually where
		-- buttonPosition said. Free in production, and it fails loudly the day
		-- somebody reintroduces the flattening on a floor that has content.
		if RunService:IsStudio() then
			local want = (self:buttonBaseCF(def)).Position.Y
			assert(math.abs(pad.Position.Y - want) < L.ButtonHeight + 0.01,
				("[Tung] button %s built at y=%.2f but buttonPosition says y=%.2f")
					:format(def.id, pad.Position.Y, want))
		end

		self.objects[def.id] = {
			def = def,
			holder = holder,
			pad = pad,
			pedestal = holder:FindFirstChild("Pedestal"),
			billboard = billboard,
			frame = frame,
			stroke = stroke,
			priceLabel = price,
			effectLabel = effect,
			stepLabel = step,
			titleLabel = title,
			-- every label the two voices have to fade together
			labels = { step, title, effect, price },
			light = light,
			machine = nil,
			ghost = nil,
		}
	end
end

--- Whether the floor a button stands on has actually been built.
---
--- A previewed button is a dimmed pad with a ghost of its machine standing
--- where it will go, which is the right answer on the ground floor and a
--- terrible one twenty-two studs up in open air: before the deck exists there
--- is nothing under it, so it reads as a bug rather than as a plan. Buttons on
--- an unbuilt floor are HIDDEN, and appear with the deck.
---
--- TWO WAYS A BUTTON NAMES ITS FLOOR, and this used to read only the first. A belt
--- machine names it by `path`; a side-track button names it on its track's
--- Layout.Tracks entry, which is how the weapons and armour columns came to stand
--- on the mezzanine. Nine pads at y = 22 are covered today only by a COINCIDENCE —
--- Config.TrackUnlock gates both cabinets on `floor2`, the same button that builds
--- the deck, so `trackUnlocked` happens to answer the same question. A cabinet
--- track gated on anything else, or a floor that stopped being what unlocked it,
--- would hang nine pads in open air and this function would have said yes.
function Tycoon:floorBuiltFor(def): boolean
	-- A LINE BUTTON WAITS ON THE DECK IT STANDS ON. Its pedestal is at y = 22,
	-- so before the storey lands it would hang in open air over the aisle.
	if def.kind == "Line" then
		local floor = Config.floorForLineButton(def.id)
		return floor == nil or self.owned[floor.button] == true
	end

	local track = def.track and Config.Layout.Tracks[def.track]
	local floorId = def.path or (track and track.floor)
	if not floorId then
		return true
	end
	for _, floor in ipairs(Config.Floors) do
		if floor.id == floorId then
			-- A MACHINE ON A BELT WAITS ON THE BELT, NOT ON THE STOREY. These
			-- used to be the same question — buying the floor built the deck and
			-- the conveyor together — and this function's own comment above
			-- flagged that as a coincidence it was banking on. TODO.md item 4
			-- split them, so a plot can own a barren deck for the rest of the
			-- build; `mezz_dropper1` revealed there would be a pad standing over
			-- a slab with no conveyor under it, dropping its output through the
			-- floor.
			if def.path == floor.id then
				return self.owned[floor.button] == true
					and Config.floorLineBuilt(floor, self.owned)
			end
			return self.owned[floor.button] == true
		end
	end
	return true
end

function Tycoon:requirementsMet(id: string): boolean
	local def = Config.ButtonById[id]
	if not def then
		return false
	end
	-- ANDed in here rather than only in refreshButtons, so a stale Touched on a
	-- pad that is about to be hidden cannot buy through the gate.
	if not Config.trackUnlocked(def.track, self.owned) then
		return false
	end
	for _, req in ipairs(Config.requirementsOf(def)) do
		if not self.owned[req] then
			return false
		end
	end
	return true
end

--- A translucent stand-in for a machine you haven't bought yet, built from the
--- same MACHINE_MASSES description as the real thing.
---
--- Showing the next few purchases as ghosts turns the plot into a plan you are
--- filling in, rather than a row of anonymous pads with prices on them. It also
--- answers the standing complaint about tycoon infrastructure — "why am I
--- buying walls before I can buy upgraders" stops being a fair question once
--- you can see the upgraders standing there waiting.
function Tycoon:buildGhost(def)
	if not MACHINE_MASSES[def.kind] then
		return nil
	end
	local variant = Config.Variants[def.variant] or Config.Variants.classic

	local model = Instance.new("Model")
	model.Name = "Ghost_" .. def.id

	local parts = self:buildMasses(def, model, variant.wood, Enum.Material.ForceField)
	for name, part in pairs(parts) do
		-- A mass whose whole job is to be an invisible trigger has no business
		-- in a silhouette: drawn as a ghost, the upgrader's 5-stud ScanTrigger
		-- is a translucent slab across the belt where the real machine shows a
		-- 1-stud beam. The ghost is built from the same description as the real
		-- machine ON PURPOSE, so this is the one exception and it is named.
		if name:match("Trigger$") then
			part:Destroy()
			continue
		end
		part.Transparency = 0.72
		-- A ghost must never be walked into, stood on, or hit by a drop: it is
		-- a drawing, and the belt has to run through where it will stand.
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
	end
	return model
end

--- Buy buttons have three states, because the two obvious designs both fail:
--- showing every button at once gives the plot no focal point, and showing
--- only the next one hides the shape of the build from you.
---
---   available   full colour, lit, touchable, and the cheapest one wears a
---               Highlight and a beacon so it is findable from anywhere
---   preview     the next few steps: dimmed, inert, with a ghost of the
---               machine standing where it will go
---   hidden      everything further out, and everything already owned
-- Preview depth and beacon rank both used to be tables here. They are
-- Config.TrackInfo[track].preview and Config.TrackRank[track] now — the second
-- of those existed TWICE, once here and once in the HUD, with a comment on the
-- HUD copy warning that they had to stay identical. Rank is just the TrackOrder
-- index, so deriving it deletes both copies rather than adding a third.

--- Switches a buy button's label between its two voices.
---
--- `locked` is a Config.Style.ButtonLocked table, or nil for the full-volume
--- one. Five properties move together because any one of them alone is a nudge
--- and the point is a difference you cannot miss: the label shrinks, its panel
--- fades, its outline thins, its text fades (outline along with it, or a dimmed
--- label keeps a hard edge and reads as MORE contrasty than the bright one),
--- and it stops drawing at a shorter range so a plot full of locked pads
--- clears out as you walk away from it.
function Tycoon:setButtonVoice(entry, locked)
	local scale = locked and locked.scale or 1
	entry.billboard.Size = UDim2.fromScale(BTN.width * scale, BTN.height * scale)
	Style.setDistance(entry.billboard, locked and locked.distance or BTN.distance)
	entry.frame.BackgroundTransparency = locked and locked.panelAlpha or BTN.panelAlpha
	entry.stroke.Thickness = locked and locked.strokeThickness or BTN.strokeThickness
	local alpha = locked and locked.textAlpha or 0
	for _, label in ipairs(entry.labels) do
		Style.fade(label, alpha)
	end
end

function Tycoon:refreshButtons()
	if not self.owner then
		for _, entry in pairs(self.objects) do
			entry.holder.Parent = nil
			if entry.ghost then
				entry.ghost:Destroy()
				entry.ghost = nil
			end
		end
		if self.marker then
			self:pointAt(nil)
		end
		return
	end

	local cash = Economy.get(self.owner)

	-- How far along EACH track the player has got. One frontier per track is a
	-- strict generalisation of the old single scan: with one track it produces
	-- exactly the numbers that loop produced.
	local frontier = {}
	for track, defs in pairs(Config.Tracks) do
		frontier[track] = #defs + 1
		for _, def in ipairs(defs) do
			if not self.owned[def.id] then
				frontier[track] = def.trackOrder
				break
			end
		end
	end

	local target, targetRank, targetPrice = nil, math.huge, math.huge

	for id, entry in pairs(self.objects) do
		local def = entry.def
		local owned = self.owned[id] == true
		-- A gated track is HIDDEN, not previewed, and it takes no ghost: the
		-- point of gating the cabinets is that the right half of the plot is
		-- empty ground until you have earned it, and nine dimmed pads with
		-- ghost bats standing on them is the same wall of labels with the
		-- brightness turned down.
		local standing = self:floorBuiltFor(def) and Config.trackUnlocked(def.track, self.owned)
		local available = (not owned) and standing and self:requirementsMet(id)
		local preview = (not owned) and (not available) and standing
			and (def.trackOrder <= frontier[def.track] + Config.TrackInfo[def.track].preview)

		entry.holder.Parent = (available or preview) and self.buttonsFolder or nil

		if preview then
			-- inert: a preview pad you can buy from would just spam "you can't
			-- afford that yet" every time you crossed it
			entry.pad.CanTouch = false
			entry.pad.Color = COLORS.preview
			entry.pad.Transparency = 0.45
			if entry.pedestal then
				entry.pedestal.Transparency = 0.55
				entry.pedestal.CanCollide = false
			end
			entry.light.Enabled = false
			-- SMALLER, FAINTER, THINNER, AND IT GIVES UP SOONER. Colour on its
			-- own was never going to carry this: it is the first signal lost to
			-- a bright sky or a neon variant standing behind the label, and it
			-- was the ONLY thing separating a locked pad from the one you can
			-- press.
			self:setButtonVoice(entry, BTN_LOCKED)
			entry.stroke.Color = COLORS.preview
			entry.stepLabel.TextColor3 = COLORS.preview
			entry.titleLabel.TextColor3 = COLORS.preview
			-- Name the thing you have to buy, not an ordinal. "step N" meant
			-- one thing when there was one chain; with three tracks the global
			-- order is meaningless on a pedestal and the per-track one is
			-- ambiguous across cabinets. The requirement is right here, so say
			-- it: "locked — buy Oak Sahur Bat first".
			local blocker
			for _, req in ipairs(Config.requirementsOf(def)) do
				if not self.owned[req] then
					blocker = Config.ButtonById[req]
					break
				end
			end
			entry.effectLabel.Text = blocker
				and ("locked — buy %s first"):format(blocker.name)
				or "locked"
			entry.effectLabel.TextColor3 = COLORS.preview
			entry.priceLabel.Text = "$" .. Util.abbreviate(def.price)
			entry.priceLabel.TextColor3 = COLORS.preview
		elseif available then
			local affordable = cash >= def.price
			local color = affordable and COLORS.buttonOn or COLORS.buttonOff
			entry.pad.CanTouch = true
			entry.pad.Transparency = 0
			entry.pad.Color = color
			if entry.pedestal then
				entry.pedestal.Transparency = 0
				entry.pedestal.CanCollide = true
			end
			entry.light.Enabled = true
			entry.light.Color = color
			self:setButtonVoice(entry, nil)
			entry.stroke.Color = color
			entry.stepLabel.TextColor3 = Color3.fromRGB(150, 142, 172)
			entry.titleLabel.TextColor3 = Color3.fromRGB(255, 240, 210)
			entry.effectLabel.Text = self:effectLine(def)
			entry.effectLabel.TextColor3 = Color3.fromRGB(150, 235, 190)
			entry.priceLabel.TextColor3 = color
			entry.priceLabel.Text = affordable
				and ("$" .. Util.abbreviate(def.price))
				or ("NEED " .. Util.abbreviate(def.price - cash) .. " MORE")

			-- (track, price) lexicographically. Cheapest-overall would park the
			-- beacon on the first cabinet rung for the whole early game, since
			-- a bat costs less than the next dropper for most of it.
			local rank = Config.TrackRank[def.track] or 99
			if rank < targetRank or (rank == targetRank and def.price < targetPrice) then
				target, targetRank, targetPrice = entry, rank, def.price
			end
		end

		-- ghosts stand for anything not yet built, available or previewed
		local wantsGhost = (available or preview) and MACHINE_MASSES[def.kind] ~= nil
		if wantsGhost and not entry.ghost then
			entry.ghost = self:buildGhost(def)
			if entry.ghost then
				entry.ghost.Parent = self.machines
			end
		elseif not wantsGhost and entry.ghost then
			entry.ghost:Destroy()
			entry.ghost = nil
		end
	end

	self:pointAt(target)
	-- Here rather than as a second ownedChanged listener: refreshButtons
	-- already runs on install, assign, release and rebirth — every event that
	-- can open or close a track — and updateCabinetSigns has always lived on
	-- the end of it. ensureCabinets is idempotent, so the periodic refresh
	-- costs a FindFirstChild per track.
	self:ensureCabinets()
	self:updateCabinetSigns()
	-- The yard and its generator are refreshed on the same beat and for the
	-- same reason: this is the one place that runs on install, assign, release
	-- and rebirth, and both of them have to survive all four.
	self:ensureYard()
	self:refreshGenerator()
end

--- Moves the "buy this next" marker onto `entry`. One Highlight and one light
--- column per plot, reparented, rather than one of each per button: Highlight
--- is capped at 255 per client and disabled ones still occupy a slot.
function Tycoon:pointAt(entry)
	if not self.marker then
		local marker = Instance.new("Model")
		marker.Name = "NextMarker"

		local beam = newPart(marker, "Beam", Vector3.new(4, 26, 4), CFrame.new(),
			COLORS.gold, Enum.Material.Neon, false)
		beam.Transparency = 0.75
		beam.CanQuery = false

		local highlight = Instance.new("Highlight")
		highlight.FillColor = COLORS.gold
		highlight.FillTransparency = 0.65
		highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
		-- through your own machinery: the point of the marker is that you can
		-- find it from the far end of a plot you have already half filled
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = marker

		self.marker = marker
		self.markerBeam = beam
		self.markerHighlight = highlight
	end

	if not entry then
		self.marker.Parent = nil
		self.markerHighlight.Adornee = nil
		return
	end

	self.markerHighlight.Adornee = entry.holder
	self.markerBeam.CFrame = entry.pad.CFrame * CFrame.new(0, 13, 0)
	self.marker.Parent = self.buttonsFolder
end

return Tycoon
