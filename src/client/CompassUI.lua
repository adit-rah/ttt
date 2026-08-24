--[[
	CompassUI.lua — a thin strip that answers "which way" (#104).

	The open world's four questions — where is home, where is the tower,
	where is the middle, where is my party — all have client-readable
	answers: the plot position derives from the PlotAssigned index and
	Config.plotPlacements, the tower and the core are Config constants, and
	partymates' characters replicate. So the compass costs ZERO remotes: a
	strip at the top of the screen, markers sliding by relative bearing
	against the camera's flat look vector, clamped to the edges when behind
	you.

	Deliberately a strip and not a map: a map is the largest surface this
	game could ever put on a phone, and it waits for its own ticket. The
	buy-pad beacon stays separate — it is plot-local wayfinding and already
	answers its one question. Disclosure-gated on "world", the same row that
	names the bands.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local UiKit = Req("UiKit")
local Util = Req("Util")
local HUD = Req("HUD")
local Style = Req("Style")

local Players = game:GetService("Players")

local CompassUI = {}

local ROLE = UiKit.ROLE
local WIDTH, HEIGHT = 260, 20
local MARK_WIDTH = 26
-- The strip is exactly one small glyph tall, so a landmark fills it.
local GLYPH = Config.UI.Icon.Small
local HALF_FOV = math.rad(100)

local strip
local markers = {}
local plotIndex = nil
local partyIds = {}
-- #138: players currently carrying MY Tung, by userId. The mark outranks
-- disclosure — being robbed is itself the event, like a party invite.
local thiefIds = {}

--- One mark on the strip: a drawn glyph for a landmark, a letter for a person.
---
--- A PERSON STAYS A LETTER, and that is not an oversight. The four landmarks are
--- each one thing, so a glyph names them completely; a partymate's mark has to
--- answer WHICH partymate, and no glyph carries that. The letter is the
--- information, which is why every map ever drawn labels its pins.
local function markerFor(id: string, spec, colour: Color3)
	local mark = markers[id]
	if not mark then
		local holder = Instance.new("Frame")
		holder.Name = "Mark_" .. id
		holder.Size = UDim2.fromOffset(MARK_WIDTH, HEIGHT)
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.Parent = strip
		mark = { holder = holder }
		if spec.icon then
			mark.glyph = UiKit.icon(holder, spec.icon, GLYPH, colour, ROLE.surface)
			mark.glyph.Position = UDim2.fromOffset(math.floor((MARK_WIDTH - GLYPH) / 2), 0)
		else
			mark.label = UiKit.text(holder, {
				Size = UDim2.fromScale(1, 1),
				Font = Style.Font.title,
				Text = spec.text,
				TextSize = 12,
				TextColor3 = colour,
				TextXAlignment = Enum.TextXAlignment.Center,
			})
		end
		markers[id] = mark
	end
	if mark.label then
		mark.label.Text = spec.text
	end
	return mark
end

--- An edge-pinned mark is behind you and dims rather than vanishing. A glyph
--- and a letter recede by different properties, so the dispatch is here.
local function fadeMark(mark, alpha: number)
	if mark.label then
		Style.fade(mark.label, alpha)
	else
		UiKit.fadeIcon(mark.glyph, alpha)
	end
end

local function targets()
	local list = {
		{ id = "core", icon = "core", color = ROLE.alarm, position = Vector3.zero },
		{ id = "tower", icon = "tower", color = ROLE.emphasis,
			position = Vector3.new(0, 0, -Config.Tower.EntranceRadius) },
	}
	if plotIndex then
		local placements = Config.plotPlacements(Config.plotCountFor())
		local placement = placements[plotIndex]
		if placement then
			table.insert(list, { id = "home", icon = "home", color = ROLE.currency,
				position = Vector3.new(
					math.sin(placement.angle) * placement.radius, 0,
					math.cos(placement.angle) * placement.radius) })
		end
	end
	for userId in pairs(partyIds) do
		local mate = Players:GetPlayerByUserId(userId)
		local root = mate and mate.Character and mate.Character:FindFirstChild("HumanoidRootPart")
		if root and mate ~= Players.LocalPlayer then
			table.insert(list, { id = "mate" .. userId, text = mate.DisplayName:sub(1, 1),
				color = ROLE.affirm, position = root.Position })
		end
	end
	for userId in pairs(thiefIds) do
		local thief = Players:GetPlayerByUserId(userId)
		local root = thief and thief.Character and thief.Character:FindFirstChild("HumanoidRootPart")
		if root then
			table.insert(list, { id = "thief" .. userId, icon = "alert",
				color = ROLE.alarm, position = root.Position })
		else
			-- the thief left or died unseen; the mark dies with the body
			thiefIds[userId] = nil
		end
	end
	return list
end

local function beat()
	if not strip.Visible then
		return
	end
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not root then
		return
	end
	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.05 then
		return
	end
	flatLook = flatLook.Unit
	local heading = Util.atan2(flatLook.X, flatLook.Z)

	local live = {}
	for _, target in ipairs(targets()) do
		live[target.id] = true
		local offset = target.position - root.Position
		local bearing = Util.atan2(offset.X, offset.Z)
		local diff = Util.atan2(math.sin(bearing - heading), math.cos(bearing - heading))
		local x = math.clamp(diff / HALF_FOV, -1, 1)
		local mark = markerFor(target.id, target, target.color)
		mark.holder.Position = UDim2.new(0.5 + x * 0.48, -math.floor(MARK_WIDTH / 2), 0, 0)
		fadeMark(mark, math.abs(x) >= 0.99 and 0.55 or 0)
	end
	for id, mark in pairs(markers) do
		if not live[id] then
			mark.holder:Destroy()
			markers[id] = nil
		end
	end
end

local function refreshVisible()
	-- the thief mark outranks disclosure: if someone is carrying your Tung,
	-- the strip shows whatever else you have earned
	strip.Visible = HUD.disclosed("world") or next(thiefIds) ~= nil
end

function CompassUI.start()
	strip = UiKit.dock(HUD.root(), {
		name = "Compass", corner = "topCentre",
		width = WIDTH, height = HEIGHT, insetY = 6,
	})
	strip.BackgroundColor3 = ROLE.surface
	strip.BackgroundTransparency = 0.55
	UiKit.corner(strip, 10)
	strip.Visible = false

	Net.event("PlotAssigned").OnClientEvent:Connect(function(index)
		if type(index) == "number" then
			plotIndex = index
		end
	end)
	Net.event("Party").OnClientEvent:Connect(function(payload)
		partyIds = {}
		for _, member in ipairs((payload and payload.members) or {}) do
			partyIds[member.userId] = true
		end
	end)
	Net.event("ThiefMark").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.thiefUserId) ~= "number" then
			return
		end
		thiefIds[payload.thiefUserId] = (not payload.gone) and true or nil
		refreshVisible()
	end)
	HUD.onDisclosure(refreshVisible)
	refreshVisible()

	task.spawn(function()
		while true do
			task.wait(0.15)
			local ok, err = pcall(beat)
			if not ok then
				warn("[Tung] compass error: " .. tostring(err))
			end
		end
	end)
end

return CompassUI
