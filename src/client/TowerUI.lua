--[[
	TowerUI.lua — the climb's banner (#145).

	A strip under the compass, alive only mid-run: floor and total, the
	archetype's instruction, the day's modifier, a countdown for clocked
	floors, and your best today. The server pushes whole state on TowerState
	(secondsLeft, never a deadline — the clocks differ); this file renders,
	counts the seconds down locally between pushes, and sends nothing.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Net = Req("Net")
local UiKit = Req("UiKit")
local HUD = Req("HUD")
local Style = Req("Style")

local TowerUI = {}

local ROLE = UiKit.ROLE

local WIDTH, HEIGHT = 300, 22

local strip, label
local state = nil          -- the last packet, or nil when no run
local countdownAt = 0      -- os.clock() when the packet landed

local WORDS = {
	wave = "clear the pack",
	boss = "the boss",
	timed = "beat the clock",
	survival = "stay alive",
}

local function render()
	if not state or state.over then
		strip.Visible = false
		return
	end
	local parts = {
		("FLOOR %d/%d"):format(state.floor or 0, state.total or 0),
		WORDS[state.archetype] or state.archetype or "",
	}
	if state.secondsLeft then
		local left = math.max(0, state.secondsLeft - math.floor(os.clock() - countdownAt))
		table.insert(parts, ("%ds"):format(left))
	end
	if state.modifier and state.modifier ~= "STEADY" then
		table.insert(parts, state.modifier)
	end
	if (state.best or 0) > 0 then
		table.insert(parts, ("best %d"):format(state.best))
	end
	label.Text = table.concat(parts, "  •  ")
	strip.Visible = true
end

function TowerUI.start()
	strip = UiKit.dock(HUD.root(), {
		name = "TowerBanner", corner = "topLeft",
		width = WIDTH, height = HEIGHT,
	})
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.Position = UDim2.new(0.5, 0, 0, 30)
	strip.BackgroundColor3 = ROLE.surface
	strip.BackgroundTransparency = 0.35
	UiKit.corner(strip, 10)
	strip.Visible = false
	label = UiKit.text(strip, {
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.fromOffset(6, 0),
		Font = Style.Font.body,
		Text = "",
		TextSize = 13,
		TextColor3 = ROLE.onSurface,
	})

	Net.event("TowerState").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		state = payload
		countdownAt = os.clock()
		render()
	end)

	-- the local countdown between pushes; cheap, and only while visible
	task.spawn(function()
		while true do
			task.wait(0.5)
			if state and state.secondsLeft and not state.over then
				render()
			end
		end
	end)
end

return TowerUI
