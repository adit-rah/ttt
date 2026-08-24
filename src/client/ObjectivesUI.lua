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
local O = Config.UI.Objectives
local GLYPH = Config.UI.Icon.Small
local WIDTH = Config.UI.ColumnWidth

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

	local y = O.Pad
	UiKit.text(panel, {
		Size = UDim2.fromOffset(O.TextWidth + O.TextX - O.Gutter, O.HeaderHeight),
		Position = UDim2.fromOffset(O.Gutter, y),
		Font = Style.Font.title,
		Text = "TODAY",
		TextSize = O.HeaderTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += O.HeaderHeight

	-- A marker column, then the name. The state used to be the first character
	-- of the same string — a drawn tick when done and "2/5" when not — which
	-- gave a done row and an in-progress row two different left edges.
	for _, row in ipairs(state.rows) do
		local colour = row.done and ROLE.affirm or ROLE.emphasis
		if row.done then
			local tick = UiKit.icon(panel, "tick", GLYPH, colour, ROLE.surface)
			tick.Position = UDim2.fromOffset(O.Gutter, y)
		else
			UiKit.text(panel, {
				Size = UDim2.fromOffset(GLYPH, O.RowHeight),
				Position = UDim2.fromOffset(O.Gutter, y),
				Font = Style.Font.body,
				Text = ("%d/%d"):format(row.progress, row.count),
				TextSize = O.CountTextPx,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = colour,
			})
		end
		UiKit.text(panel, {
			Size = UDim2.fromOffset(O.TextWidth, O.RowHeight),
			Position = UDim2.fromOffset(O.TextX, y),
			Font = Style.Font.body,
			Text = row.name,
			TextSize = O.RowTextPx,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = colour,
		})
		y += O.RowHeight + O.RowGap
	end

	if state.hint then
		local hint = UiKit.text(panel, {
			Size = UDim2.fromOffset(O.TextWidth + O.TextX - O.Gutter, O.HintHeight),
			Position = UDim2.fromOffset(O.Gutter, y),
			Font = Style.Font.body,
			Text = state.hint,
			TextSize = O.HintTextPx,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.onSurfaceMuted,
		})
		hint.TextWrapped = true
		y += O.HintHeight
	end

	panel.Size = UDim2.fromOffset(WIDTH, y + O.Pad)
	panel.Visible = #state.rows > 0 or state.hint ~= nil
end

function ObjectivesUI.start()
	panel = UiKit.panel(HUD.column(),
		UDim2.fromOffset(Config.UI.ColumnWidth, Config.UI.Objectives.HeaderHeight),
		UDim2.fromOffset(0, 0))
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
