--[[
	DataService.lua — DataStore persistence with retries, autosave and a
	safe shutdown flush. Falls back to in-memory only if DataStores are
	unavailable (Studio without API access), so the game still runs.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataService = {}

local STORE_NAME = "TungTungTycoon_v1"
local AUTOSAVE_SECONDS = 90

--- Bumped whenever a saved value's MEANING changes rather than its shape.
--- reconcile() runs the migrations between the saved version and this one.
---
--- 1 -> 2: Config.Bats grew from three tiers to six, with ash and crimson
---         inserted between oak and void. profile.batTier stores an INDEX, so
---         a v1 save reading "3" meant void and now means ash — a silent
---         downgrade of a purchase, and one nothing else in the game could
---         detect.
local PROFILE_VERSION = 2

--- v1 bat tier -> v2 bat tier. { starter, oak, void } -> their new indices.
local LEGACY_BAT_TIERS = { 1, 2, 5 }

local store: DataStore? = nil
local dataStoresUsable = true

do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		dataStoresUsable = false
		warn("[Tung] DataStores unavailable, running in memory-only mode: " .. tostring(result))
	end
end

local function defaultProfile()
	return {
		cash = Config.Economy.StartingCash,
		owned = {},        -- { [buttonId] = true }
		rebirths = 0,
		batTier = 1,
		armorTier = 1,
		kills = 0,
		playtime = 0,
		-- PROTOTYPE fields (Offline / Sessions / RebirthPerks). reconcile()
		-- merges a saved value onto this default only when the TYPES match, so
		-- adding a field here is what makes every existing save keep loading:
		-- an old profile simply arrives with the default.
		--
		-- lastSeen is 0 rather than os.time() deliberately. A profile that has
		-- never stored one has no knowable logout time, and seeding it with
		-- "now" would look like a zero-second session; seeding it with 0 means
		-- SessionService skips the offline payout for that first session and
		-- starts counting from the logout after it.
		lastSeen = 0,
		sessions = {},     -- streak / boost / cap state, shaped by SessionService
		unlocks = {},      -- { [unlockId] = label } granted by rebirth milestones
		upgrades = {},     -- { [upgradeId] = level }, shaped by UpgradeService
		utilityEquipped = "",  -- a Config.Utilities id; "" rather than nil so the
		                       -- type-matched reconcile can merge a saved value
		version = PROFILE_VERSION,
	}
end

local profiles: { [number]: any } = {}
local loading: { [number]: boolean } = {}

local function key(userId: number): string
	return "player_" .. userId
end

local function retry(fn, attempts: number)
	local lastErr
	for i = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(0.6 * i)
	end
	return false, lastErr
end

--- Merges saved fields onto a fresh default so schema additions are safe.
local function reconcile(saved)
	local profile = defaultProfile()
	if type(saved) ~= "table" then
		return profile
	end
	for k, v in pairs(profile) do
		if saved[k] ~= nil and type(saved[k]) == type(v) then
			profile[k] = saved[k]
		end
	end
	-- prune ids that no longer exist in Config
	local cleanOwned = {}
	if type(profile.owned) == "table" then
		for id, value in pairs(profile.owned) do
			if value and Config.ButtonById[id] then
				cleanOwned[id] = true
			end
		end
	end
	profile.owned = cleanOwned
	profile.cash = math.max(0, tonumber(profile.cash) or 0)
	profile.rebirths = math.clamp(math.floor(tonumber(profile.rebirths) or 0), 0, Config.Rebirth.MaxRebirths)
	profile.batTier = math.floor(tonumber(profile.batTier) or 1)

	-- MIGRATIONS. Run before the clamps, because a stale index is not out of
	-- range — it is in range and means the wrong thing, which is worse.
	local version = math.floor(tonumber(profile.version) or 1)
	if version < 2 then
		profile.batTier = LEGACY_BAT_TIERS[profile.batTier] or profile.batTier
	end
	profile.version = PROFILE_VERSION

	profile.batTier = math.clamp(profile.batTier, 1, #Config.Bats)
	profile.armorTier = math.clamp(math.floor(tonumber(profile.armorTier) or 1), 1, #Config.Armor.Tiers)

	-- A weapon or armour button is the RECORD of a granted tier, so it must
	-- never disagree with the tier itself. A save from before the weapons
	-- track existed owns batforge and batforge2 but none of the rungs now
	-- sitting between them — and because grantBat is monotonic, those rungs
	-- would light up as available and then take the player's money and do
	-- nothing. Backfill anything the tier already covers.
	--
	-- Idempotent, and it fixes the CLASS: the same divergence would reappear
	-- from any future reordering of Config.Bats.
	for _, def in ipairs(Config.Buttons) do
		if def.kind == "Gear" then
			local bat = Config.BatById[def.grants]
			if bat and bat.tier <= profile.batTier then
				profile.owned[def.id] = true
			end
		elseif def.kind == "Armor" then
			local tier = Config.ArmorById[def.grants]
			if tier and tier.tier <= profile.armorTier then
				profile.owned[def.id] = true
			end
		end
	end

	return profile
end

function DataService.load(player: Player)
	local userId = player.UserId
	if profiles[userId] then
		return profiles[userId]
	end
	loading[userId] = true

	local profile
	if store and dataStoresUsable then
		local ok, saved = retry(function()
			return (store :: DataStore):GetAsync(key(userId))
		end, 4)
		if ok then
			profile = reconcile(saved)
		else
			warn(("[Tung] load failed for %s: %s"):format(player.Name, tostring(saved)))
			profile = reconcile(nil)
			profile.__loadFailed = true   -- never overwrite good data with a failed read
		end
	else
		profile = reconcile(nil)
		profile.__loadFailed = not dataStoresUsable
	end

	profiles[userId] = profile
	loading[userId] = nil
	return profile
end

function DataService.get(player: Player)
	return profiles[player.UserId]
end

function DataService.save(player: Player, release: boolean?)
	local userId = player.UserId
	local profile = profiles[userId]
	if not profile then
		return false
	end
	if profile.__loadFailed then
		-- data never loaded cleanly; refuse to clobber the real save
		if release then
			profiles[userId] = nil
		end
		return false
	end

	local payload = {
		cash = profile.cash,
		owned = profile.owned,
		rebirths = profile.rebirths,
		batTier = profile.batTier,
		armorTier = profile.armorTier,
		kills = profile.kills,
		playtime = profile.playtime,
		lastSeen = profile.lastSeen,
		sessions = profile.sessions,
		unlocks = profile.unlocks,
		upgrades = profile.upgrades,
		utilityEquipped = profile.utilityEquipped,
		version = profile.version,
	}

	local saved = false
	if store and dataStoresUsable then
		local ok, err = retry(function()
			return (store :: DataStore):UpdateAsync(key(userId), function()
				return payload
			end)
		end, 4)
		saved = ok
		if not ok then
			warn(("[Tung] save failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end

	if release then
		profiles[userId] = nil
	end
	return saved
end

function DataService.start()
	Players.PlayerRemoving:Connect(function(player)
		DataService.save(player, true)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = profiles[player.UserId]
				if profile then
					profile.playtime += AUTOSAVE_SECONDS
					task.spawn(DataService.save, player, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		local remaining = 0
		for _, player in ipairs(Players:GetPlayers()) do
			remaining += 1
			task.spawn(function()
				DataService.save(player, true)
				remaining -= 1
			end)
		end
		local deadline = os.clock() + 25
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
