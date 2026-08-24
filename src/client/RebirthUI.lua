--[[
	RebirthUI.lua — the moment a rebirth opens (#107).

	One overlay card on RebirthReport: the rank (loud when it changed), the
	multiplier, what you keep, and one honest line about what reset — a
	rebirth must read as a promotion, and a promotion that hides the cost
	reads as a trick. Dismissible by button and by timer; never a hard modal.
	Everything on it arrived derived from Config and the profile; this file
	renders and decides nothing.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Net = Req("Net")
local UiKit = Req("UiKit")
local Config = Req("Config")
local HUD = Req("HUD")
local Style = Req("Style")

local RebirthUI = {}

local ROLE = UiKit.ROLE
local CARD = Config.UI.RebirthCard
local ONWARD_WIDTH = 140
local SHOW_SECONDS = 14

local panel
local generation = 0

local function render(payload)
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local y = 14
	UiKit.text(panel, {
		Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.TitleHeight),
		Position = UDim2.fromOffset(CARD.Pad, y),
		Font = Style.Font.title,
		Text = ("SAHUR REBIRTH #%d"):format(payload.rebirths or 0),
		TextSize = CARD.TitleTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.emphasis,
	})
	y += CARD.TitleHeight + CARD.RowGap
	if payload.rankChanged then
		UiKit.text(panel, {
			Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.TitleHeight),
			Position = UDim2.fromOffset(CARD.Pad, y),
			Font = Style.Font.title,
			Text = ("RANK UP  •  %s"):format(payload.rank or ""),
			TextSize = CARD.TitleTextPx,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.heading,
		})
		y += CARD.TitleHeight + CARD.RowGap
	end
	if payload.motto then
		UiKit.text(panel, {
			Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.LineHeight),
			Position = UDim2.fromOffset(CARD.Pad, y),
			Font = Style.Font.body,
			Text = payload.motto,
			TextSize = CARD.LineTextPx,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.onSurfaceMuted,
		})
		y += CARD.LineHeight + CARD.RowGap
	end
	UiKit.text(panel, {
		Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.LineHeight),
		Position = UDim2.fromOffset(CARD.Pad, y),
		Font = Style.Font.body,
		Text = ("Every payout is now x%.2f."):format(payload.multiplier or 1),
		TextSize = CARD.LineTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.affirm,
	})
	y += CARD.LineHeight + CARD.RowGap
	UiKit.text(panel, {
		Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.LineHeight),
		Position = UDim2.fromOffset(CARD.Pad, y),
		Font = Style.Font.body,
		Text = "YOU KEEP",
		TextSize = CARD.LineTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += CARD.LineHeight - CARD.RowGap
	for _, line in ipairs(payload.keeps or {}) do
		UiKit.text(panel, {
			Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2 - 8, CARD.LineHeight),
			Position = UDim2.fromOffset(CARD.Pad + 8, y),
			Font = Style.Font.body,
			Text = "• " .. line,
			TextSize = CARD.LineTextPx,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.emphasis,
		})
		y += CARD.LineHeight - CARD.RowGap
	end
	y += CARD.RowGap
	-- the honest line: what a promotion costs
	UiKit.text(panel, {
		Size = UDim2.fromOffset(CARD.Width - CARD.Pad * 2, CARD.LineHeight),
		Position = UDim2.fromOffset(CARD.Pad, y),
		Font = Style.Font.body,
		Text = "The factory resets. The climb back is faster than it was.",
		TextSize = CARD.LineTextPx,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += CARD.LineHeight + CARD.RowGap

	-- 96x26 was a 60x16 physical target at MinScale, on the one button that
	-- dismisses the report.
	local close = UiKit.control(panel, {
		variant = "primary", text = "ONWARD", width = ONWARD_WIDTH,
		position = UDim2.new(0.5, -math.floor(ONWARD_WIDTH / 2), 0, y),
	})
	close.Activated:Connect(function()
		panel.Visible = false
	end)
	y += Config.UI.Button.primary + 8
	panel.Size = UDim2.fromOffset(Config.UI.RebirthCard.Width, y)
end

function RebirthUI.start()
	panel = UiKit.overlayCard(HUD.overlay(),
		UDim2.fromOffset(Config.UI.RebirthCard.Width, Config.UI.RebirthCard.TitleHeight))
	panel.Name = "Rebirth"
	panel.Visible = false

	Net.event("RebirthReport").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		render(payload)
		panel.Visible = true
		-- dismissible AND self-dismissing: "not modal for long" is the spec
		generation += 1
		local mine = generation
		task.delay(SHOW_SECONDS, function()
			if generation == mine and panel.Visible then
				panel.Visible = false
			end
		end)
	end)
end

return RebirthUI
