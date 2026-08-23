--[[
	tycoon/Income.lua — what a plot is worth per second, and the signs that quote
	it.

	THE MODEL LIVES IN Config.incomeRate, and this file is one of its three
	readers. incomePerSecond wraps it with the live multiplier stack;
	SessionService.incomePerSecondFor wraps it with the rebirth term from a
	SAVED profile, because an offline player has no plot to ask; the verifier's
	progression simulation reads it raw. Change the shape in Config and the
	wrappers stay one line each.

	THE PAYER LIVES IN Vault.lua NOW (design:D-02, via #180): a collected
	tung pays its dropper's value through Config.dropPayout and the live
	multiplier stack, and a tung that never reaches the vault pays nothing.
	incomeRate stays the quote and the mirror — the drops' long-run average.

	updateSign has a ONE-WRITER RULE. PlotService repaints every sign on a
	3-second beat and VaultService recomputes the gauge on its own schedule, so
	when the gauge has a headline it owns the board and the income readout is the
	fallback. Two writers make the label flicker between two different sentences
	a few times a minute.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Economy = Req("Economy")
local DataService = Req("DataService")
local Tycoon = Req("Class")

-- ── income readout ───────────────────────────────────────────────────────────

--- Estimated Tung/second with everything currently installed.
---
--- `extraId` pretends one more button is owned, which is how a buy button can
--- advertise "+$28/sec" instead of only a price. A price alone is a cost with
--- no stated benefit, and for an Upgrader the benefit is not even guessable —
--- x1.85 of an unknown number is not information.
function Tycoon:incomePerSecond(extraId: string?): number
	local function has(id: string): boolean
		return self.owned[id] == true or id == extraId
	end

	-- Economy.multiplier carries rebirth and every session hook; the factory
	-- itself is Config.incomeRate, the one copy of the arithmetic.
	local rebirthMult = self.owner and Economy.multiplier(self.owner) or 1
	return Config.incomeRate(has) * rebirthMult
end

-- design:D-02, via #180 — startIncomeLoop IS GONE. The live plot's payer is
-- Tycoon:onCollect: a tung that enters the vault pays its dropper's value
-- through Config.dropPayout and the live multiplier stack, and a tung that
-- never arrives pays nothing. incomeRate stays the quote, the mirror and
-- the simulation — the drops' long-run average — which is why this file
-- keeps incomePerSecond and lost the loop.

--- One line of plain English for what a button actually does for you. Income
--- kinds get the measured delta; the rest get their blurb, because "walls" has
--- no income to quote.
function Tycoon:effectLine(def): string
	if def.kind == "Dropper" or def.kind == "Upgrader" then
		local delta = self:incomePerSecond(def.id) - self:incomePerSecond()
		if delta > 0 then
			return ("+%s/sec"):format(Util.abbreviate(delta))
		end
	elseif def.kind == "Belt" then
		return ("belt +%d studs/sec"):format(def.speedBonus)
	elseif def.kind == "Gear" then
		-- Same rule as the income kinds: quote the measured effect, not the
		-- flavour text. A bat's whole value is its numbers.
		local bat = Config.BatById[def.grants]
		if bat then
			return ("%d dmg  •  %.0f%% crit"):format(bat.damage, bat.crit * 100)
		end
	elseif def.kind == "Armor" then
		local tier = Config.ArmorById[def.grants]
		if tier then
			local previous = Config.Armor.Tiers[tier.tier - 1]
			return ("%d max health  (+%d)"):format(tier.health, tier.health - (previous and previous.health or 0))
		end
	end
	return def.blurb or ""
end

function Tycoon:updateSign()
	local ownerName = self.owner and self.owner.DisplayName or nil
	local sign = self.model:FindFirstChild("Totem")
	local billboard = sign and sign:FindFirstChild("Sign")
	-- the label lives inside a Frame inside the BillboardGui, so this lookup
	-- has to be recursive or it silently returns nil forever
	local label = billboard and billboard:FindFirstChild("Owner", true)
	if label then
		if ownerName then
			-- design:D-03, via #106 — the tier is public: the tag names the
			-- owner's rank beside their name, at the sign's existing close
			-- draw distance. The profile can lag a beat behind a rebirth; the
			-- 3-second repaint catches it up.
			local profile = DataService.get(self.owner)
			local rank = Config.tierName(profile and profile.rebirths or 0)
			label.Text = ("%s's TUNG FACTORY  •  %s\n%s Tung/sec")
				:format(ownerName, rank, Util.abbreviate(self:incomePerSecond()))
		else
			label.Text = ("UNCLAIMED PLOT %d\nstep on the pad to claim"):format(self.index)
		end
	end
	-- ONE writer at a time. PlotService repaints every sign on a 3-second beat
	-- and VaultService recomputes the gauge on its own schedule, so if both
	-- wrote this label it would flicker between two different sentences a few
	-- times a minute. When the gauge has a headline it owns the board; when it
	-- does not — an unclaimed plot, or a build with Prototypes.Offline off —
	-- the income readout this sign has always carried is the fallback.
	if self.vaultLabel then
		if not ownerName then
			self.vaultLabel.Text = "SAHUR VAULT"
		elseif self.vaultHeadline then
			self.vaultLabel.Text = self.vaultHeadline
		else
			self.vaultLabel.Text = ("SAHUR VAULT  •  %s/sec"):format(Util.abbreviate(self:incomePerSecond()))
		end
	end
	-- the whole claim rig (pad, beacon, halo, sign) appears and disappears
	-- together, so an owned plot never shows a stray "free" marker
	if self.claimFolder then
		self.claimFolder.Parent = (ownerName == nil) and self.model or nil
	end
	if self.rebirthLabel and self.owner then
		self.rebirthLabel.Text = ("SAHUR REBIRTH\n%s"):format(Util.abbreviate(Economy.rebirthCost(self.owner)))
	end
end

return Tycoon
