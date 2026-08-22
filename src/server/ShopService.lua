--[[
	ShopService.lua — the storefront for gear (#108).

	design:D-03. The cabinets are gone; weapons and armour sell HERE, and the
	mechanics deliberately did not move an inch: the catalog is the same
	Config.Buttons rows (same ids, same prices, same chains — the tuned week
	walk still spends through them unchanged), a purchase still writes
	profile.owned and still lands as CombatService.grantBat/grantArmor, and
	both grants stay monotonic. What changed is the DOOR: a remote instead of
	a pedestal, so character progression travels with the character.

	TWO DOORS, ONE SHOP. The rail button (client-side, disclosure-gated) and
	the merchant by the spawn — a prompt whose whole job is FireClient
	{ open = true }. The server validates everything on buy: the row must be a
	shop-track row, its chain predecessor owned, its track open
	(Config.trackUnlocked — the dropper3 plot milestone), the shop disclosed,
	and the price paid through Economy.spend.

	The tycoon's `owned` mirror is kept in step when the buyer has a plot, so
	the frontier arithmetic and the replay path agree with the profile — the
	AdminService.give arrangement.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Net = Req("Net")
local Economy = Req("Economy")
local DataService = Req("DataService")
local CombatService = Req("CombatService")
local DisclosureService = Req("DisclosureService")

local ShopService = {}

local remote = Net.event("Shop")

local SHOP_TRACKS = { weapons = true, armor = true }

--- Returns (ok, reason); reasons are player-facing. Clock-free and pure over
--- the profile, so the whole gate runs headless.
function ShopService.tryBuy(player, id: string): (boolean, string)
	local def = Config.ButtonById[id]
	if not def or not SHOP_TRACKS[def.track] then
		return false, "the shop does not sell that"
	end
	local profile = DataService.get(player)
	if not profile then
		return false, "your save is still loading"
	end
	if profile.owned[id] then
		return false, "you already own that"
	end
	if not DisclosureService.unlocked(player, "shop") then
		return false, "keep building — the shop opens soon"
	end
	if not Config.trackUnlocked(def.track, profile.owned) then
		return false, "keep building — this counter opens soon"
	end
	for _, req in ipairs(Config.requirementsOf(def)) do
		if not profile.owned[req] then
			local blocker = Config.ButtonById[req]
			return false, ("buy %s first"):format(blocker and blocker.name or req)
		end
	end
	if not Economy.spend(player, def.price) then
		return false, ("you need %s more"):format(Util.abbreviate(def.price - Economy.get(player)))
	end

	profile.owned[id] = true
	if def.track == "weapons" then
		CombatService.grantBat(player, def.grants)
	else
		CombatService.grantArmor(player, def.grants)
	end
	Economy.push(player)
	return true, def.name
end

function ShopService.start()
	local PlotService = Req("PlotService")

	remote.OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" or payload.action ~= "buy" or type(payload.id) ~= "string" then
			return
		end
		local ok, what = ShopService.tryBuy(player, payload.id)
		Economy.notify(player, { kind = ok and "buy" or "warn", title = "Shop",
			body = ok and ("%s is yours."):format(what) or what })
		if ok then
			-- keep the plot's mirror in step, so the frontier arithmetic and
			-- the rejoin replay agree with the profile
			local tycoon = PlotService.plotOf(player)
			if tycoon then
				tycoon.owned[payload.id] = true
			end
		end
	end)

	-- the merchant: a Tung by the spawn pad whose prompt opens the shop
	local TungModels = Req("TungModels")
	local bearing = math.pi / math.max(Config.plotCountFor(), 1)
	local base = Vector3.new(
		math.sin(bearing) * (Config.World.SpawnRadius - 20),
		Config.World.GroundTopY,
		math.cos(bearing) * (Config.World.SpawnRadius - 20))
	local merchant = TungModels.buildStatue("golden", 1.4)
	merchant.Name = "Merchant"
	merchant:PivotTo(CFrame.new(base + Vector3.new(0, 4, 0)))
	merchant.Parent = workspace

	local anchor = merchant.PrimaryPart or merchant:FindFirstChildWhichIsA("BasePart")
	if anchor then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "OpenShop"
		prompt.ActionText = "Browse"
		prompt.ObjectText = "The Shop"
		prompt.HoldDuration = 0.5
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = anchor
		prompt.Triggered:Connect(function(player)
			remote:FireClient(player, { open = true })
		end)
	end
end

return ShopService
