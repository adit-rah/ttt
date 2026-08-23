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
local HUD = Req("HUD")
local Style = Req("Style")

local Players = game:GetService("Players")

local CompassUI = {}

local PALETTE = UiKit.PALETTE
local WIDTH, HEIGHT = 260, 20
local HALF_FOV = math.rad(100)

-- Two-argument arctangent, by hand: the toolchain's math.atan definition is
-- single-argument and the analysis pass is allowed to fail the build.
local function atan2(y: number, x: number): number
	if x > 0 then
		return math.atan(y / x)
	elseif x < 0 then
		return math.atan(y / x) + (y >= 0 and math.pi or -math.pi)
	end
	return y >= 0 and math.pi / 2 or -math.pi / 2
end

local strip
local markers = {}
local plotIndex = nil
local partyIds = {}
-- #138: players currently carrying MY Tung, by userId. The mark outranks
-- disclosure — being robbed is itself the event, like a party invite.
local thiefIds = {}

local function markerFor(id: string, text: string, color: Color3)
	local label = markers[id]
	if not label then
		label = UiKit.text(strip, {
			Size = UDim2.fromOffset(26, HEIGHT),
			Position = UDim2.fromOffset(0, 0),
			Font = Style.Font.body,
			Text = text,
			TextSize = 12,
			TextColor3 = color,
		})
		label.Name = "Mark_" .. id
		markers[id] = label
	end
	label.Text = text
	return label
end

local function targets()
	local list = {
		{ id = "core", text = "◆", color = Color3.fromRGB(255, 110, 90), position = Vector3.zero },
		{ id = "tower", text = "▲", color = Color3.fromRGB(200, 120, 255),
			position = Vector3.new(0, 0, -Config.Tower.EntranceRadius) },
	}
	if plotIndex then
		local placements = Config.plotPlacements(Config.plotCountFor())
		local placement = placements[plotIndex]
		if placement then
			table.insert(list, { id = "home", text = "⌂", color = PALETTE.gold,
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
				color = PALETTE.good, position = root.Position })
		end
	end
	for userId in pairs(thiefIds) do
		local thief = Players:GetPlayerByUserId(userId)
		local root = thief and thief.Character and thief.Character:FindFirstChild("HumanoidRootPart")
		if root then
			table.insert(list, { id = "thief" .. userId, text = "!",
				color = Color3.fromRGB(255, 90, 70), position = root.Position })
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
	local heading = atan2(flatLook.X, flatLook.Z)

	local live = {}
	for _, target in ipairs(targets()) do
		live[target.id] = true
		local offset = target.position - root.Position
		local bearing = atan2(offset.X, offset.Z)
		local diff = atan2(math.sin(bearing - heading), math.cos(bearing - heading))
		local x = math.clamp(diff / HALF_FOV, -1, 1)
		local label = markerFor(target.id, target.text, target.color)
		label.Position = UDim2.new(0.5 + x * 0.48, -13, 0, 0)
		-- an edge-pinned marker is behind you; it dims rather than vanishing
		Style.fade(label, math.abs(x) >= 0.99 and 0.55 or 0)
	end
	for id, label in pairs(markers) do
		if not live[id] then
			label:Destroy()
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
		name = "Compass", corner = "topLeft",
		width = WIDTH, height = HEIGHT,
	})
	-- centred: the dock gave it a corner anchor; the strip re-anchors to the
	-- top middle, which no other surface claims
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.Position = UDim2.new(0.5, 0, 0, 6)
	strip.BackgroundColor3 = Color3.fromRGB(10, 8, 16)
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
