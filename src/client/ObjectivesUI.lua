--[[
	ObjectivesUI.lua — today's three, and the hint line (#97).

	One card in the left column: the hint (small, ignorable, never modal — it
	is one line of muted text) and up to three objective rows with "2/5"
	progress. The server pushes the whole state on the Objectives remote;
	this file renders it and sends nothing. Disclosure-gated like every
	earned surface.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local UiKit = Req("UiKit")
local HUD = Req("HUD")
local Style = Req("Style")

local ObjectivesUI = {}

local ROLE = UiKit.ROLE
local WIDTH = Config.UI.SessionPanel.Width

local panel
local state = { rows = {}, hint = nil }

local function render()
	if not panel then
		return
	end
	if not HUD.disclosed("objectives") then
		panel.Visible = false
		return
	end
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local y = 4
	UiKit.text(panel, {
		Size = UDim2.new(1, -16, 0, 16),
		Position = UDim2.fromOffset(8, y),
		Font = Style.Font.body,
		Text = "TODAY",
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += 18

	for _, row in ipairs(state.rows) do
		UiKit.text(panel, {
			Size = UDim2.new(1, -16, 0, 16),
			Position = UDim2.fromOffset(8, y),
			Font = Style.Font.body,
			Text = ("%s  %s"):format(row.done and "✓" or ("%d/%d"):format(row.progress, row.count), row.name),
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = row.done and ROLE.affirm or ROLE.emphasis,
		})
		y += 17
	end

	if state.hint then
		local hint = UiKit.text(panel, {
			Size = UDim2.new(1, -16, 0, 26),
			Position = UDim2.fromOffset(8, y + 2),
			Font = Style.Font.body,
			Text = state.hint,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.onSurfaceMuted,
		})
		hint.TextWrapped = true
		y += 30
	end

	panel.Size = UDim2.fromOffset(WIDTH, y + 6)
	panel.Visible = #state.rows > 0 or state.hint ~= nil
end

function ObjectivesUI.start()
	panel = UiKit.panel(HUD.column(), UDim2.fromOffset(WIDTH, 20), UDim2.fromOffset(0, 0))
	panel.Name = "Objectives"
	panel.LayoutOrder = 4
	panel.Visible = false

	Net.event("Objectives").OnClientEvent:Connect(function(payload)
		state.rows = payload.rows or {}
		state.hint = payload.hint
		render()
	end)
	HUD.onDisclosure(render)
end

return ObjectivesUI
