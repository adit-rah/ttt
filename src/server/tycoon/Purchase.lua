--[[
	tycoon/Purchase.lua — the two ways a button becomes owned, and the difference
	between them.

	tryPurchase IS THE ONLY PLACE A BUTTON IS EVER BOUGHT WITH MONEY. It checks
	the owner, the requirements and the wallet, writes profile.owned, and emits
	the economy event. install() applies a purchase and is ALSO replayed for
	every owned button at assign(), which is exactly why the Analytics call sits
	in tryPurchase: logging it in install() would report a returning player's
	whole factory as bought again this second.

	requirementsMet is re-checked here as well as in refreshButtons, so a stale
	Touched on a pad that is about to be hidden cannot buy through a closed gate.

	install() dispatches through Tycoon.INSTALLERS on `kind` and warns rather
	than throwing when there is no case for it, so an unknown kind costs one
	button instead of the plot's construction. KNOWN_KINDS in
	tools/verify_config.lua is what stops one reaching production.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local Economy = Req("Economy")
local DataService = Req("DataService")
local Analytics = Req("Analytics")
local Tycoon = Req("Class")

-- ── purchasing ───────────────────────────────────────────────────────────────

function Tycoon:playerFromHit(hit: BasePart): Player?
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return game:GetService("Players"):GetPlayerFromCharacter(character)
end

function Tycoon:tryPurchase(player: Player, id: string)
	if player ~= self.owner then
		return
	end
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	if not self:requirementsMet(id) then
		return
	end
	if not Economy.spend(player, def.price) then
		local short = def.price - Economy.get(player)
		Economy.notify(player, {
			kind = "warn",
			title = "Not enough Tung",
			body = ("You need %s more for %s."):format(Util.abbreviate(short), def.name),
		})
		return
	end

	local profile = DataService.get(player)
	if profile then
		profile.owned[id] = true
	end

	self:install(id, false)

	-- THE ONLY PLACE A BUTTON IS EVER BOUGHT WITH MONEY, which is why the
	-- economy event goes here and not in install() — install() also runs for
	-- every button of a save being replayed at assign(), and logging those would
	-- report a returning player's whole factory as bought again this second.
	Analytics.onPurchase(player, def, Economy.get(player))

	Economy.notify(player, {
		kind = "buy",
		title = def.name,
		body = def.blurb or "",
		price = def.price,
	})
	Economy.push(player)
end

--- Applies a purchase. `silent` skips effects (used when loading a save).
function Tycoon:install(id: string, silent: boolean?)
	local def = Config.ButtonById[id]
	if not def or self.owned[id] then
		return
	end
	self.owned[id] = true

	local entry = self.objects[id]
	if entry then
		entry.holder.Parent = nil
	end

	local installer = Tycoon.INSTALLERS[def.kind]
	if installer then
		installer(self, def, silent)
	else
		warn("[Tung] no installer for kind " .. tostring(def.kind))
	end

	if not silent then
		-- The twin of the bug buttonBaseCF fixes: the purchase confetti used a
		-- literal world 5 rather than five studs above the button, so a
		-- mezzanine purchase would have burst on the ground floor underneath it.
		local variant = Config.Variants[def.variant or "classic"]
		Fx.burst((self:buttonBaseCF(def) * CFrame.new(0, 5, 0)).Position, variant.wood, 18, self.model)
	end

	self:refreshButtons()
	self:fireOwnedChanged()
end

return Tycoon
