--[[
	control_spec.lua — a control is a variant and a state, and a state sets all
	of it.

	WHY THIS FAMILY EXISTS. "Disabled" was written inline at four call sites and
	every one of them forgot the same three properties. ShopUI is the clearest:
	it set BackgroundColor3 and Active = false, and left AutoButtonColor on, so a
	dead button still flashed under a thumb; left TextColor3 at the live
	variant's ink, so OWNED printed dark-on-dark; and left Selectable on, so a
	gamepad still landed there. Three of those four are invisible to a person
	looking at a screenshot, which is why they survived.

	WHAT THIS CAN SEE. The mock stores a UDim2 and never resolves it, so nothing
	here knows where a control LANDS or how big it looks — that is
	verify_config.lua's job and every height and text size in the variant table
	is held there. What a spec can read is the property bag, and the four
	forgotten properties are all in it.

	EVERY SPEC HERE HAS BEEN MADE TO FAIL, each under one mutation applied and
	reverted in the working tree:

	  variant attribute   the SetAttribute call deleted
	  all six             each of the four properties dropped from the setter
	  the ink follows     the TextColor3 line dropped from the setter
	  idle restores       the variant lookup replaced with BTN.Disabled
	  unknown variant     the error() replaced with a fallback row
	  unknown state       the CONTROL_STATES guard deleted
	  on is not disabled  the On row pointed at the Disabled roles
]]

return function(T)

T.family("control", "a control is a variant and a state, and a state sets all of it")

local function clientWorld()
	local world = T.world()
	world.client()
	return world
end

local function surface(world)
	local frame = Instance.new("Frame")
	frame.Parent = world.playerGui()
	return frame
end

T.spec("every variant builds, and remembers which variant it is", function(t)
	local world = clientWorld()
	local UiKit, Config = world.req("UiKit"), world.req("Config")
	local seen = 0
	for name, variant in pairs(Config.UI.Button.Variant) do
		seen += 1
		local b = UiKit.control(surface(world), { variant = name, text = "TEST", width = 120 })
		t:eq(b.ClassName, "TextButton", ("the %q variant built a %s"):format(name, b.ClassName))
		t:eq(b:GetAttribute("Variant"), name,
			("a %q control does not carry its own variant; setControlState reads that attribute rather than a closure")
				:format(name))
		t:eq(b.TextSize, variant.textPx, ("the %q variant printed at the wrong size"):format(name))
		t:isFalse(b.TextScaled,
			("the %q variant came out TextScaled, so its label size is derived from its box and is not the number Config declares")
				:format(name))
	end
	t:gt(seen, 0, "Config.UI.Button.Variant is empty — the table parsed as nothing")
end)

T.spec("disabled sets all four properties the inline version forgot", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local b = UiKit.control(surface(world), { variant = "pill", text = "BUY", width = 120 })

	t:isTrue(b.AutoButtonColor, "a fresh control should flash under a thumb")
	t:isTrue(b.Active, "a fresh control should be pressable")

	UiKit.setControlState(b, "disabled")
	t:isFalse(b.AutoButtonColor,
		"a disabled control still flashes under a thumb — this is the property ShopUI forgot four times")
	t:isFalse(b.Active, "a disabled control is still pressable")
	t:isFalse(b.Selectable, "a disabled control still takes gamepad focus")
	t:ne(b.BackgroundColor3, UiKit.ROLE.affirm, "a disabled control kept its live fill")
end)

T.spec("the ink follows the fill, so a disabled label stays readable", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local b = UiKit.control(surface(world), { variant = "pill", text = "BUY", width = 120 })
	local live = b.TextColor3

	UiKit.setControlState(b, "disabled")
	t:ne(b.TextColor3, live,
		"a disabled control kept the live variant's ink — the fill went dark and the label went with it, which is how OWNED printed unreadably")
	t:eq(b.TextColor3, UiKit.ROLE.onDisabled, "a disabled control's ink is not the disabled ink")
end)

T.spec("idle restores exactly what the variant declared", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	for name in pairs(world.req("Config").UI.Button.Variant) do
		local b = UiKit.control(surface(world), { variant = name, text = "TEST", width = 120 })
		local fill, ink = b.BackgroundColor3, b.TextColor3
		UiKit.setControlState(b, "disabled")
		UiKit.setControlState(b, "idle")
		t:eq(b.BackgroundColor3, fill, ("a %q control came back from disabled with a different fill"):format(name))
		t:eq(b.TextColor3, ink, ("a %q control came back from disabled with different ink"):format(name))
		t:isTrue(b.AutoButtonColor, ("a %q control came back from disabled still not flashing"):format(name))
		t:isTrue(b.Active, ("a %q control came back from disabled still unpressable"):format(name))
	end
end)

T.spec("on is unpressable and does not look disabled", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local b = UiKit.control(surface(world), { variant = "primary", text = "BOOST", width = 120 })

	UiKit.setControlState(b, "on")
	t:isFalse(b.Active, "a running effect should not be pressable again")
	t:ne(b.BackgroundColor3, UiKit.ROLE.disabled,
		"a running boost rendered as disabled, which reads to a player as the boost having stopped")
	t:eq(b.BackgroundColor3, UiKit.ROLE.affirm, "the on state is not the affirm fill")
end)

T.spec("an unknown variant and an unknown state are both errors", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")
	local into = surface(world)

	t:raises(function()
		UiKit.control(into, { variant = "shiny", text = "NO" })
	end, "unknown control variant")

	local b = UiKit.control(into, { variant = "pill", text = "YES", width = 120 })
	t:raises(function()
		UiKit.setControlState(b, "sparkling")
	end, "unknown control state")

	-- A control built by hand carries no variant, and the setter says so rather
	-- than silently doing nothing to it.
	local raw = Instance.new("TextButton")
	raw.Parent = into
	t:raises(function()
		UiKit.setControlState(raw, "disabled")
	end, "carries no Variant")
end)

T.spec("a glyph control carries its label beside the drawing, not under it", function(t)
	local world = clientWorld()
	local UiKit = world.req("UiKit")

	-- A TextButton with Text set runs it UNDER a child glyph, so a labelled icon
	-- control has to hand its text to a sibling of the drawing.
	local b = UiKit.control(surface(world), { variant = "pill", text = "SHOP", icon = "coin", width = 160 })
	t:eq(b.Text, "", "a glyph control kept its own Text, which draws underneath the drawing")
	local label = b:FindFirstChild("Label")
	t:notNil(label, "a glyph control built no label, so its text went nowhere")
	if label then
		t:eq(label.Text, "SHOP", "the label beside the glyph says the wrong thing")
	end
	t:notNil(b:FindFirstChild("Glyph"), "a glyph control drew no glyph")
end)

T.spec("an icon-only control is square, at the touch floor, and has no label", function(t)
	local world = clientWorld()
	local UiKit, Config = world.req("UiKit"), world.req("Config")
	local b = UiKit.control(surface(world), { variant = "ghost", icon = "close", iconOnly = true })

	t:eq(b.Size.X.Offset, Config.UI.Button.IconOnly, "an icon-only control is not the declared square")
	t:eq(b.Size.Y.Offset, Config.UI.Button.IconOnly, "an icon-only control is not square")
	t:eq(b.Text, "", "an icon-only control has text in it")
	t:isNil(b:FindFirstChild("Label"), "an icon-only control built a label it has no room for")
end)

end
