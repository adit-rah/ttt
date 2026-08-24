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
local HUD = Req("HUD")
local Style = Req("Style")

local RebirthUI = {}

local ROLE = UiKit.ROLE
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
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.title,
		Text = ("SAHUR REBIRTH #%d"):format(payload.rebirths or 0),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.emphasis,
	})
	y += 28
	if payload.rankChanged then
		UiKit.text(panel, {
			Size = UDim2.new(1, -24, 0, 24),
			Position = UDim2.fromOffset(12, y),
			Font = Style.Font.title,
			Text = ("RANK UP  •  %s"):format(payload.rank or ""),
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.heading,
		})
		y += 26
	end
	if payload.motto then
		UiKit.text(panel, {
			Size = UDim2.new(1, -24, 0, 16),
			Position = UDim2.fromOffset(12, y),
			Font = Style.Font.body,
			Text = payload.motto,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.onSurfaceMuted,
		})
		y += 22
	end
	UiKit.text(panel, {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.body,
		Text = ("Every payout is now x%.2f."):format(payload.multiplier or 1),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.affirm,
	})
	y += 24
	UiKit.text(panel, {
		Size = UDim2.new(1, -24, 0, 14),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.body,
		Text = "YOU KEEP",
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += 16
	for _, line in ipairs(payload.keeps or {}) do
		UiKit.text(panel, {
			Size = UDim2.new(1, -32, 0, 15),
			Position = UDim2.fromOffset(20, y),
			Font = Style.Font.body,
			Text = "• " .. line,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = ROLE.emphasis,
		})
		y += 16
	end
	y += 6
	-- the honest line: what a promotion costs
	UiKit.text(panel, {
		Size = UDim2.new(1, -24, 0, 15),
		Position = UDim2.fromOffset(12, y),
		Font = Style.Font.body,
		Text = "The factory resets. The climb back is faster than it was.",
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = ROLE.onSurfaceMuted,
	})
	y += 22

	local close = UiKit.button(panel, "ONWARD", ROLE.action, {
		Size = UDim2.fromOffset(96, 26),
		Position = UDim2.new(0.5, -48, 0, y),
	})
	close.Activated:Connect(function()
		panel.Visible = false
	end)
	y += 34
	panel.Size = UDim2.fromOffset(320, y)
end

function RebirthUI.start()
	panel = UiKit.panel(HUD.overlay(), UDim2.fromOffset(320, 100), UDim2.fromScale(0.5, 0.42), Vector2.new(0.5, 0.5))
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
