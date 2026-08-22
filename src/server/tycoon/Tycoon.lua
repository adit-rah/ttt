--[[
	Tycoon.lua — the standardized tycoon.

	One instance per plot. Everything it builds comes from Config.Buttons, so
	adding content is a data edit, never a code edit. The contract for a new
	entry is just:

		kind = "Dropper"   -> needs slot, variant, dropValue, dropRate
		kind = "Upgrader"  -> needs slot, variant, multiplier
		kind = "Belt"      -> needs speedBonus
		kind = "Power"     -> needs factor (cumulative), variant, and NO slot
		kind = "Structure" -> needs structure ("walls" | "gates" | "windows" | "roof")
		kind = "Gear"      -> needs grants (a Config.Bats id)
		kind = "Armor"     -> needs grants (a Config.Armor id)
		kind = "Land"      -> needs side ("left" | "right") and width. One
		                      expansion strip of ground, outward from the centre.

	EIGHT KINDS, IN THREE PLACES. Add a case to tycoon/Installers.lua to invent
	one, add it to KNOWN_KINDS in tools/verify_config.lua, and add it to the list
	above. This list is the copy that fell behind: it said five while INSTALLERS
	and KNOWN_KINDS carried Power, Armor and Floor as well. Nothing checks it,
	which is why it is named here and in CLAUDE.md as the one to do by hand.

	THIS FILE IS THE AGGREGATOR AND NOTHING ELSE. Req searches one level of
	folder nesting (Req.lua:54-62), so Req("Tycoon") resolves here and this is
	the whole public surface: Class builds the bare table, each mixin below
	attaches its methods to that same table through Tycoon.__index, and
	`Tycoon.part` is re-exported for FloorService.

	THE REQUIRES BELOW ARE LOAD-BEARING, NOT DECORATION. Deleting one silently
	removes a dozen methods from the class, and the first symptom is a nil call
	inside Tycoon.new — pass 2 of the verifier cannot see it, because the name
	that went missing is a method on a table, not a local. The mixins require
	Class (and Parts), never each other and never this file: Req raises
	"circular dependency" at RUNTIME, so a cycle here fails the boot rather than
	the build.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Tycoon = Req("Class")
local Parts = Req("Parts")

-- Required for their side effect: each one attaches its methods to the class
-- table Class built. Alphabetical, because there is no load order to express —
-- a mixin defines functions and runs no code at load.
Req("Belt")
Req("Buttons")
Req("Drops")
Req("Income")
Req("Installers")
Req("Land")
Req("Ownership")
Req("Props")
Req("Purchase")
Req("Siege")
Req("Storage")
Req("Vault")

--- The plot's own part constructor, exposed so FloorService builds its deck out
--- of the same defaults (anchored, smooth surfaces, collidable unless told
--- otherwise) instead of a second near-identical local copy that drifts.
Tycoon.part = Parts.newPart

return Tycoon
