--[[
	PartyUI.lua — the party card (#102).

	One panel in HUD.column(): out of a party it lists who else is on the
	server with an INVITE button each; in one it lists your partymates with a
	live distance, and LEAVE. A pending invite renders as an ACCEPT / DECLINE
	row at the top. Everything is presentation — the server sends the whole
	state on the Party remote and decides every action; this file's only
	outbound messages are button presses.

	The distance line re-renders on a one-second beat, client-side only:
	other characters' positions replicate anyway, so "where is my party" costs
	no remote. That is the whole map surface for now; #104 owns wayfinding.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local UiKit = Req("UiKit")
local HUD = Req("HUD")
local Style = Req("Style")

local Players = game:GetService("Players")

local PartyUI = {}

local ROLE = UiKit.ROLE
local P = Config.UI.PartyPanel
local UI = Config.UI
-- The COLUMN's width, not the session panel's. Both this card and the
-- objectives card read SessionPanel.Width, so two of the column's four panels
-- took their width from a third — and verify_config's column loop iterated
-- the two that declared one.
local WIDTH = Config.UI.ColumnWidth

local panel
local state = { members = {}, invite = nil }

local function remote()
	return Net.event("Party")
end

local function send(action, target)
	remote():FireServer({ action = action, target = target })
end

local function distanceTo(userId: number): string
	local me = Players.LocalPlayer.Character
	local myRoot = me and me:FindFirstChild("HumanoidRootPart")
	local mate = Players:GetPlayerByUserId(userId)
	local root = mate and mate.Character and mate.Character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not root then
		return ""
	end
	return ("%d studs"):format((root.Position - myRoot.Position).Magnitude)
end

local function row(order: number): Frame
	local r = Instance.new("Frame")
	r.Size = UDim2.new(1, 0, 0, P.RowHeight)
	r.BackgroundTransparency = 1
	r.LayoutOrder = order
	r.Parent = panel
	return r
end

local function rowText(parent: Frame, textValue: string, color: Color3)
	return UiKit.text(parent, {
		Size = UDim2.fromOffset(P.TextWidth, P.RowHeight),
		Position = UDim2.fromOffset(P.Pad, 0),
		Font = Style.Font.body,
		Text = textValue,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color,
	})
end

--- A row's control, right-aligned. Every one is a full touch target now: the
--- height comes off the ladder through P.RowHeight rather than from the row.
local function rowButton(parent: Frame, label: string, variant: string, x: number)
	return UiKit.control(parent, {
		variant = variant, text = label, width = P.ActionWidth,
		position = UDim2.new(1, -x, 0, math.round((P.RowHeight - UI.Button.pill) / 2)),
	})
end

--- The decline. A glyph rather than an "X" typed into a 26-px box, which is how
--- it came to be the smallest control in the game.
local function rowClose(parent: Frame, x: number)
	return UiKit.control(parent, {
		variant = "danger", name = "Decline", icon = "close", iconOnly = true,
		position = UDim2.new(1, -x, 0, math.round((P.RowHeight - UI.Button.IconOnly) / 2)),
	})
end

--- The whole card, rebuilt from state. Cheap: at most MaxSize + a header of
--- rows, and it runs on a state push or the distance beat.
local function render()
	if not panel then
		return
	end
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local rows = 0
	local inParty = #state.members > 1

	local header = UiKit.text(panel, {
		Size = UDim2.new(1, -16, 0, P.HeaderHeight),
		Position = UDim2.fromOffset(8, 2),
		Font = Style.Font.body,
		Text = inParty and ("PARTY  %d/%d"):format(#state.members, Config.Party.MaxSize) or "PARTY",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	header.LayoutOrder = 0

	if state.invite then
		local r = row(1)
		rows += 1
		rowText(r, ("%s invited you"):format(state.invite.fromName), ROLE.heading)
		rowButton(r, "JOIN", "pill", P.PairX).Activated:Connect(function()
			send("accept")
		end)
		rowClose(r, P.CloseX).Activated:Connect(function()
			send("decline")
		end)
	end

	if inParty then
		for i, member in ipairs(state.members) do
			if member.userId ~= Players.LocalPlayer.UserId then
				local r = row(1 + i)
				rows += 1
				rowText(r, ("%s   %s"):format(member.name, distanceTo(member.userId)), ROLE.emphasis)
			end
		end
		local r = row(99)
		rows += 1
		rowButton(r, "LEAVE", "danger", P.ActionX).Activated:Connect(function()
			send("leave")
		end)
	else
		-- everyone else on the server, invitable. The server re-checks every
		-- rule; these buttons are only the ask.
		local shown = 0
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= Players.LocalPlayer and shown < Config.Party.MaxSize then
				shown += 1
				local r = row(1 + shown)
				rows += 1
				rowText(r, other.DisplayName, ROLE.emphasis)
				rowButton(r, "INVITE", "pill", P.ActionX).Activated:Connect(function()
					send("invite", other.UserId)
				end)
			end
		end
	end

	panel.Size = UDim2.fromOffset(WIDTH, P.HeaderHeight + P.HeadGap + rows * P.RowHeight)
	-- #96: the card waits for its row — except an incoming invite, which is
	-- itself the disclosure (someone chose you; hiding that is worse)
	panel.Visible = (rows > 0 or state.invite ~= nil)
		and (HUD.disclosed("party") or state.invite ~= nil or #state.members > 1)
end

function PartyUI.start()
	panel = UiKit.panel(HUD.column(),
		UDim2.fromOffset(Config.UI.ColumnWidth, P.HeaderHeight), UDim2.fromOffset(0, 0))
	panel.Name = "Party"
	panel.LayoutOrder = P.LayoutOrder

	HUD.onDisclosure(render)
	remote().OnClientEvent:Connect(function(payload)
		state.members = payload.members or {}
		state.invite = payload.invite
		render()
	end)
	Players.PlayerAdded:Connect(render)
	Players.PlayerRemoving:Connect(function()
		task.defer(render)
	end)

	-- the distance beat; a second is plenty for "roughly where"
	task.spawn(function()
		while true do
			task.wait(1)
			if #state.members > 1 then
				render()
			end
		end
	end)

	render()
end

return PartyUI
