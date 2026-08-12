--[[
	UpgradeService.lua — PROTOTYPE. Two features that share one profile field:

	  * the player upgrade shop  (Config.Prototypes.PlayerUpgrades)
	  * the utility slot         (Config.Prototypes.Utilities)

	Both are gated; with both flags off every entry point returns on its first
	line and nothing here is ever constructed.

	Server-authoritative in the usual shape: the client may only ever ask. It
	sends RequestUpgrade with an id and gets a fresh UpgradeState back — it is
	never told "yes", it is told what the state now is, so a rejected purchase
	and a lost race look identical from the client's side.

	The utility slot is a KEYBIND, not a second Tool. A Tool would be the
	obvious reading of "second slot", and Roblox's hotbar would carry it for
	free — but only one Tool can be equipped at a time, so firing the utility
	would mean putting the bat away, which is exactly the moment you need it.
	The verbs here (freeze a pack of raiders, shove them off you) are things you
	do mid-swing. So: Q on desktop, an on-screen chip on touch, both routed
	through the UseUtility remote, and the equipped utility is chosen in the
	shop panel rather than by which Tool is in your hand.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local Net = Req("Net")
local Utilities = Req("Utilities")
local DataService = Req("DataService")
local Economy = Req("Economy")
local CombatService = Req("CombatService")

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local UpgradeService = {}

local SHOP_ON = Config.Prototypes.PlayerUpgrades
local UTILITY_ON = Config.Prototypes.Utilities
local ENABLED = SHOP_ON or UTILITY_ON

-- Reach and force are per-verb and live on the Config.Utilities row, because
-- "how far does the shove reach" is a property of the shove: the moment they
-- are shared constants the next utility has to fight them.
local function reachOf(id: string, fallback: number): number
	local def = Config.Utilities and Utilities.UtilityById[id]
	return (def and def.radius) or fallback
end
local function forceOf(id: string, fallback: number): number
	local def = Config.Utilities and Utilities.UtilityById[id]
	return (def and def.force) or fallback
end

local USE_THROTTLE = 0.15       -- floor on UseUtility, independent of cooldowns
local ICE = Color3.fromRGB(150, 220, 255)

local upgradeState = Net.event("UpgradeState")
local requestUpgrade = Net.event("RequestUpgrade")
local useUtility = Net.event("UseUtility")
local knockbackRemote = Net.event("Knockback")

-- os.clock() timestamps, dropped when the player leaves.
local cooldowns: { [Player]: { [string]: number } } = {}
local lastUse: { [Player]: number } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- profile state
--
-- PERSISTENCE. DataService whitelists what it saves twice over: reconcile()
-- only copies keys that exist in defaultProfile(), and save() builds an
-- explicit payload table. A new profile field is invisible until it is added
-- to BOTH, which is why `upgrades` and `utilityEquipped` appear in each.
--
-- utilityEquipped defaults to "" rather than nil, and that matters: reconcile
-- carries a saved value across only when type(saved[k]) == type(default[k]),
-- and a nil default is not even iterated by pairs(), so a nil default would
-- silently discard the field on every load. "" reads as "nothing equipped".
-- Everything below also tolerates the fields being absent, so a profile saved
-- before this prototype existed loads either way.
-- ─────────────────────────────────────────────────────────────────────────────

--- Levels for BOTH tables live in one map. Ids can't collide (speed/magnet/
--- payout/autocollect vs freeze/shove/decoy) and it keeps the persistence ask
--- down to a single new field. A utility is level 0 or 1.
local function ensure(player: Player)
	local profile = DataService.get(player)
	if not profile then
		return nil
	end
	if type(profile.upgrades) ~= "table" then
		profile.upgrades = {}
	end
	if type(profile.utilityEquipped) ~= "string" then
		profile.utilityEquipped = ""
	end
	-- A save written before a Config edit can carry a level above the new cap,
	-- or an id that no longer exists. Sanitising on read means every consumer
	-- below can trust the number.
	for id, level in pairs(profile.upgrades) do
		local def = Utilities.UpgradeById[id]
		local utility = Utilities.UtilityById[id]
		if def then
			profile.upgrades[id] = math.clamp(math.floor(tonumber(level) or 0), 0, def.levels)
		elseif utility then
			profile.upgrades[id] = math.clamp(math.floor(tonumber(level) or 0), 0, 1)
		else
			profile.upgrades[id] = nil
		end
	end
	if profile.utilityEquipped ~= "" and (profile.upgrades[profile.utilityEquipped] or 0) < 1 then
		profile.utilityEquipped = ""
	end
	return profile
end

-- ─────────────────────────────────────────────────────────────────────────────
-- public read API — for Tycoon / Economy / anyone else
-- ─────────────────────────────────────────────────────────────────────────────

function UpgradeService.levelOf(player: Player, id: string): number
	if not ENABLED then
		return 0
	end
	local profile = DataService.get(player)
	if not profile or type(profile.upgrades) ~= "table" then
		return 0
	end
	return tonumber(profile.upgrades[id]) or 0
end

--- The value of an upgrade's stat right now (WalkSpeed in studs/sec, magnet
--- radius in studs, payout as a multiplier…). Level 0 returns the def's base,
--- so this is safe to call for a player who has bought nothing.
function UpgradeService.valueOf(player: Player, id: string): number
	local def = Utilities.UpgradeById[id]
	if not def then
		return 0
	end
	if not SHOP_ON then
		return def.base
	end
	return Utilities.valueAt(def, UpgradeService.levelOf(player, id))
end

--- Cash multiplier from the `payout` track. 1.0 when the prototype is off.
---
--- Registered with Economy.setMultiplierHook("upgrades") in start(), so this
--- folds into every payout beside the rebirth multiplier. The registry is keyed
--- so the session track's hook and this one compose rather than clobber.
function UpgradeService.multiplierFor(player: Player): number
	if not SHOP_ON then
		return 1
	end
	return UpgradeService.valueOf(player, "payout")
end

--- Pickup radius from the `magnet` track, in studs.
---
--- TODO(consumer): Tycoon.lua's collector should sweep drops within this
--- radius of the owner instead of requiring a touch, or the drop's own
--- proximity check should widen by it. Tycoon.lua belongs to another track.
function UpgradeService.magnetRadius(player: Player): number
	if not SHOP_ON then
		return 0
	end
	return UpgradeService.valueOf(player, "magnet")
end

--- Whether the vault empties itself.
---
--- TODO(consumer): Tycoon.lua's vault loop should, when this is true, pay the
--- owner out on a timer rather than waiting for them to walk into the
--- collector. Tycoon.lua belongs to another track.
function UpgradeService.autoCollects(player: Player): boolean
	if not SHOP_ON then
		return false
	end
	return UpgradeService.levelOf(player, "autocollect") >= 1
end

function UpgradeService.equippedUtility(player: Player): string?
	if not UTILITY_ON then
		return nil
	end
	local profile = DataService.get(player)
	local id = profile and profile.utilityEquipped
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- replication
-- ─────────────────────────────────────────────────────────────────────────────

local function cooldownRemaining(player: Player, id: string): number
	local byId = cooldowns[player]
	local readyAt = byId and byId[id]
	if not readyAt then
		return 0
	end
	return math.max(0, readyAt - os.clock())
end

function UpgradeService.push(player: Player)
	if not ENABLED or not player.Parent then
		return
	end
	local profile = ensure(player)
	if not profile then
		return
	end

	local levels: { [string]: number } = {}
	local costs: { [string]: number } = {}
	-- utilities gated behind a tycoon button they haven't bought yet, mapped to
	-- the name of the thing that unlocks them so the row can say why it's dead
	local locked: { [string]: string } = {}

	if SHOP_ON then
		for _, def in ipairs(Config.PlayerUpgrades) do
			local level = tonumber(profile.upgrades[def.id]) or 0
			levels[def.id] = level
			-- nil cost means maxed out; the client draws that as "MAX"
			costs[def.id] = Utilities.costAt(def, level)
		end
	end

	local equipped = ""
	if UTILITY_ON then
		for _, def in ipairs(Config.Utilities) do
			local level = tonumber(profile.upgrades[def.id]) or 0
			levels[def.id] = level
			costs[def.id] = Utilities.utilityCostAt(def, level)
			if level < 1 and def.requires and not (profile.owned and profile.owned[def.requires]) then
				local button = Config.ButtonById[def.requires]
				locked[def.id] = button and button.name or def.requires
			end
		end
		equipped = profile.utilityEquipped or ""
	end

	local cooldown, cooldownTotal = 0, 0
	if equipped ~= "" then
		local def = Utilities.UtilityById[equipped]
		cooldown = cooldownRemaining(player, equipped)
		cooldownTotal = def and def.cooldown or 0
	end

	-- The declared payload is { levels, costs }; the rest is additive and a
	-- client that ignores it still draws a correct shop.
	upgradeState:FireClient(player, {
		levels = levels,
		costs = costs,
		locked = locked,
		equipped = equipped,
		-- seconds remaining at the moment this was sent. The client counts it
		-- down locally rather than trusting os.clock() to mean the same thing
		-- on both machines — it doesn't.
		cooldown = cooldown,
		cooldownTotal = cooldownTotal,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- applying the stat upgrades
-- ─────────────────────────────────────────────────────────────────────────────

--- WalkSpeed is the only upgrade with a live effect on the character; the rest
--- are read by other services through the API above.
local function applySpeed(player: Player, character: Model?)
	if not SHOP_ON then
		return
	end
	character = character or player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = UpgradeService.valueOf(player, "speed")

	-- Mirrored onto the player so anything that wants the stat — the client,
	-- a future Tycoon collector sweep — can read it without a round trip. The
	-- server is still the only writer.
	player:SetAttribute("TungMagnetRadius", UpgradeService.magnetRadius(player))
	player:SetAttribute("TungCashMultiplier", UpgradeService.multiplierFor(player))
	player:SetAttribute("TungAutoCollect", UpgradeService.autoCollects(player))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the utility verbs
-- ─────────────────────────────────────────────────────────────────────────────

--- NPCService parents every raider to workspace.SahurRaiders and exposes no
--- accessor for the live set, so we read the folder. TODO(NPCService): a
--- `NPCService.raidersNear(position, radius)` would let this stop reaching
--- into the workspace by name. The IsSahurNPC attribute check is the same one
--- CombatService.canDamage uses, so a stray Model in the folder can't be
--- frozen by accident.
local function raidersNear(position: Vector3, radius: number): { Model }
	local folder = workspace:FindFirstChild("SahurRaiders")
	local found: { Model } = {}
	if not folder then
		return found
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("IsSahurNPC") then
			local humanoid, root = Util.getRig(child)
			if humanoid and root and humanoid.Health > 0
				and (root.Position - position).Magnitude <= radius
			then
				table.insert(found, child)
			end
		end
	end
	return found
end

type FrozenEntry = { root: BasePart, wasAnchored: boolean, thawAt: number, highlight: Highlight? }
local frozen: { [Model]: FrozenEntry } = {}

local function thaw(npc: Model)
	local entry = frozen[npc]
	if not entry then
		return
	end
	-- a second freeze landed while this one was pending; let the later one own
	-- the thaw so overlapping casts extend rather than cut each other short
	local remaining = entry.thawAt - os.clock()
	if remaining > 0.05 then
		task.delay(remaining, thaw, npc)
		return
	end
	frozen[npc] = nil
	if entry.highlight then
		entry.highlight:Destroy()
	end
	if entry.root.Parent then
		entry.root.Anchored = entry.wasAnchored
	end
end

--- Roots a raider by ANCHORING it, not by zeroing WalkSpeed.
---
--- NPCService's tick writes `humanoid.WalkSpeed` on every Heartbeat, so a
--- WalkSpeed of 0 set from out here survives for less than a frame. Anchoring
--- the root part anchors the whole welded assembly and no amount of MoveTo
--- moves it, which is the only way to root a raider without editing
--- NPCService. Side effect worth knowing: a raider frozen mid-air hangs there
--- and drops when it thaws, and a frozen raider still swings if you stand in
--- its reach — freeze buys you movement, not safety.
local function freezeRaider(npc: Model, seconds: number)
	local humanoid, root = Util.getRig(npc)
	if not humanoid or not root then
		return
	end

	local entry = frozen[npc]
	if entry then
		entry.thawAt = math.max(entry.thawAt, os.clock() + seconds)
		return
	end

	-- Highlights are capped at 255 per client and disabled ones still hold a
	-- slot, so these are created per freeze and destroyed on thaw rather than
	-- living on every raider. A wave is capped well under the limit.
	local highlight = Instance.new("Highlight")
	highlight.FillColor = ICE
	highlight.FillTransparency = 0.55
	highlight.OutlineColor = Color3.fromRGB(235, 250, 255)
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = npc
	highlight.Parent = npc

	frozen[npc] = {
		root = root,
		wasAnchored = root.Anchored,
		thawAt = os.clock() + seconds,
		highlight = highlight,
	}
	root.Anchored = true
	Fx.burst(root.Position, ICE, 6, workspace)

	task.delay(seconds, thaw, npc)
end

local VERBS: { [string]: (Player, Model, BasePart, any) -> boolean } = {}

VERBS.freeze = function(player: Player, character: Model, root: BasePart, def): boolean
	local targets = raidersNear(root.Position, reachOf("freeze", 34))
	for _, npc in ipairs(targets) do
		freezeRaider(npc, def.duration)
	end
	Fx.burst(root.Position, ICE, reachOf("freeze", 34) * 0.9, workspace)
	Fx.impact(root, 1.9)
	Economy.notify(player, {
		kind = "info",
		title = "SAHUR FREEZE",
		body = #targets == 0
			and "Nothing in range."
			or ("%d raider%s frozen for %ds."):format(#targets, #targets == 1 and "" or "s", def.duration),
	})
	return true
end

VERBS.shove = function(player: Player, character: Model, root: BasePart, def): boolean
	local origin = root.Position
	local pushed = 0

	local function impulseFor(victimRoot: BasePart): Vector3
		local direction = victimRoot.Position - origin
		direction = Vector3.new(direction.X, 0, direction.Z)
		if direction.Magnitude < 0.1 then
			direction = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		end
		direction = direction.Unit
		-- same shape as CombatService.damage's knockback so a shove reads as a
		-- very heavy bat hit rather than as a different physics system
		return (direction * forceOf("shove", 130) + Vector3.new(0, forceOf("shove", 130) * 0.45, 0))
			* victimRoot.AssemblyMass * 0.6
	end

	for _, npc in ipairs(raidersNear(origin, reachOf("shove", 26))) do
		local _, npcRoot = Util.getRig(npc)
		-- A frozen raider is anchored, so an impulse does nothing to it. That
		-- interaction is deliberate: freeze pins them, shove scatters them, and
		-- you have to pick.
		if npcRoot and not npcRoot.Anchored then
			npcRoot:ApplyImpulse(impulseFor(npcRoot))
			pushed += 1
		end
	end

	for _, other in ipairs(Players:GetPlayers()) do
		local otherChar = other.Character
		local victimHumanoid, victimRoot = Util.getRig(otherChar)
		if other ~= player and otherChar and victimHumanoid and victimRoot and victimHumanoid.Health > 0
			and (victimRoot.Position - origin).Magnitude <= reachOf("shove", 26)
			-- Shove deals no damage, but it still displaces someone, so it obeys
			-- the same geography rule as the bat: only inside the arena, never
			-- onto someone standing on their own plot.
			and CombatService.canDamage(player, otherChar)
		then
			-- The victim's client owns their character's physics; a server
			-- ApplyImpulse here is discarded on the next replication tick, so
			-- the impulse is computed on the server and applied by them.
			knockbackRemote:FireClient(other, impulseFor(victimRoot))
			pushed += 1
		end
	end

	Fx.burst(origin, Color3.fromRGB(255, 190, 120), reachOf("shove", 26) * 0.9, workspace)
	Fx.impact(root, 0.7)
	Economy.notify(player, {
		kind = "info",
		title = "TUNG SHOVE",
		body = pushed == 0 and "Nothing in range." or ("Shoved %d."):format(pushed),
	})
	return true
end

--- STUB. It builds and shows the decoy, and raiders completely ignore it.
---
--- Making it real is a change in NPCService, not here, and that change now has
--- exactly one site: `refreshSnapshot()` builds the single list of everything
--- raiders consider a target, and `nearestSnapshotEntry()` reads it. Adding
--- models tagged IsSahurDecoy to that list — plus a Humanoid on the decoy so
--- raider swings have something to connect with — is the whole hook.
---
--- Left as a stub on purpose: faking it here (e.g. teleporting raiders at the
--- decoy) would look right for one wave and fight the AI forever after.
VERBS.decoy = function(player: Player, character: Model, root: BasePart, def): boolean
	local dummy = Instance.new("Part")
	dummy.Name = "TungDecoy"
	dummy.Anchored = true
	dummy.CanCollide = false
	dummy.Material = Enum.Material.Neon
	dummy.Color = Color3.fromRGB(255, 150, 60)
	dummy.Size = Vector3.new(2.4, 5.6, 2.4)
	dummy.CFrame = root.CFrame * CFrame.new(0, 0, -reachOf("decoy", 6))
	dummy:SetAttribute("IsSahurDecoy", true)
	dummy:SetAttribute("Owner", player.UserId)
	dummy.Parent = workspace
	Debris:AddItem(dummy, def.duration)

	Economy.notify(player, {
		kind = "warn",
		title = "DECOY (PROTOTYPE)",
		body = "The decoy spawns, but raiders don't target it yet.",
	})
	return true
end

--- Runs the equipped verb if it is off cooldown. Returns whether it fired, so
--- a refusal never starts a cooldown.
function UpgradeService.useUtility(player: Player): boolean
	if not UTILITY_ON then
		return false
	end
	local now = os.clock()
	if now - (lastUse[player] or 0) < USE_THROTTLE then
		return false
	end
	lastUse[player] = now

	local id = UpgradeService.equippedUtility(player)
	if not id then
		return false
	end
	local def = Utilities.UtilityById[id]
	if not def or UpgradeService.levelOf(player, id) < 1 then
		return false
	end
	if cooldownRemaining(player, id) > 0 then
		-- the client hides this case already; a stale or hostile one gets a
		-- state push back so its readout resyncs instead of silence
		UpgradeService.push(player)
		return false
	end

	local character = player.Character
	local humanoid, root = Util.getRig(character)
	if not character or not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	local verb = VERBS[def.verb]
	if not verb then
		warn(("[Tung] utility %q has no verb implementation"):format(def.verb))
		return false
	end

	local ok, err = pcall(verb, player, character, root, def)
	if not ok then
		warn(("[Tung] utility %s failed: %s"):format(id, tostring(err)))
		return false
	end

	local byId = cooldowns[player]
	if not byId then
		byId = {}
		cooldowns[player] = byId
	end
	byId[id] = os.clock() + def.cooldown
	UpgradeService.push(player)
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- purchases
-- ─────────────────────────────────────────────────────────────────────────────

local function buyUpgrade(player: Player, profile, def): boolean
	local level = tonumber(profile.upgrades[def.id]) or 0
	local cost = Utilities.costAt(def, level)
	if not cost then
		return false
	end
	if not Economy.spend(player, cost) then
		Economy.notify(player, {
			kind = "warn",
			title = "NOT ENOUGH TUNG",
			body = ("%s costs %s."):format(def.name, Util.abbreviate(cost)),
		})
		return false
	end

	profile.upgrades[def.id] = level + 1
	applySpeed(player)

	Economy.notify(player, {
		kind = "buy",
		title = ("%s  Lv %d"):format(def.name, level + 1),
		body = Utilities.describe(def, level + 1),
	})
	local _, root = Util.getRig(player.Character)
	if root then
		Fx.burst(root.Position, Color3.fromRGB(190, 130, 255), 8, workspace)
	end
	return true
end

--- One remote does buy AND equip: clicking a utility you don't own buys it,
--- clicking one you do own equips it. The alternative is a second C->S remote
--- for equipping, and "the row you tap is the utility you get" is a simpler
--- contract than two verbs on one row.
local function buyOrEquipUtility(player: Player, profile, def): boolean
	local level = tonumber(profile.upgrades[def.id]) or 0
	if level >= 1 then
		if profile.utilityEquipped == def.id then
			return false
		end
		profile.utilityEquipped = def.id
		Economy.notify(player, {
			kind = "gear",
			title = "EQUIPPED: " .. def.name,
			body = ("Press Q  •  %ds cooldown"):format(def.cooldown),
		})
		return true
	end

	if def.requires and not (profile.owned and profile.owned[def.requires]) then
		local button = Config.ButtonById[def.requires]
		Economy.notify(player, {
			kind = "warn",
			title = "LOCKED",
			body = ("%s needs %s first."):format(def.name, button and button.name or def.requires),
		})
		return false
	end

	if not Economy.spend(player, def.price) then
		Economy.notify(player, {
			kind = "warn",
			title = "NOT ENOUGH TUNG",
			body = ("%s costs %s."):format(def.name, Util.abbreviate(def.price)),
		})
		return false
	end

	profile.upgrades[def.id] = 1
	-- equip it immediately: buying a verb and then having to select it is a
	-- second step nobody expects
	profile.utilityEquipped = def.id
	Economy.notify(player, {
		kind = "gear",
		title = "UTILITY: " .. def.name,
		body = ("Press Q  •  %ds cooldown"):format(def.cooldown),
	})
	return true
end

function UpgradeService.request(player: Player, id: string)
	if not ENABLED or type(id) ~= "string" then
		return
	end
	local profile = ensure(player)
	if not profile then
		return
	end

	local upgrade = SHOP_ON and Utilities.UpgradeById[id]
	local utility = UTILITY_ON and Utilities.UtilityById[id]
	if upgrade then
		buyUpgrade(player, profile, upgrade)
	elseif utility then
		buyOrEquipUtility(player, profile, utility)
	end

	-- Push regardless of the outcome. The client's own copy of the state is
	-- only ever a redraw of ours, so a rejected click resyncs it rather than
	-- leaving it showing a price it can't pay.
	UpgradeService.push(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function UpgradeService.onPlayer(player: Player)
	if not ENABLED then
		return
	end
	task.spawn(function()
		-- the profile can still be loading on first join; the shop is not worth
		-- blocking the boot for, so wait for it out of band
		local deadline = os.clock() + 12
		while not DataService.get(player) and player.Parent and os.clock() < deadline do
			task.wait(0.25)
		end
		if not player.Parent then
			return
		end
		ensure(player)
		applySpeed(player)
		UpgradeService.push(player)
	end)
end

function UpgradeService.onCharacter(player: Player, character: Model)
	if not ENABLED then
		return
	end
	if not character:FindFirstChildOfClass("Humanoid") then
		character:WaitForChild("Humanoid", 10)
	end
	applySpeed(player, character)
	-- CombatService.onCharacter also writes WalkSpeed, and on respawn the order
	-- of the two is not guaranteed by anything stronger than Main's call order.
	-- Re-applying once a beat later is a cheap way to always win that race.
	task.delay(0.75, function()
		if player.Character == character then
			applySpeed(player, character)
		end
	end)
	UpgradeService.push(player)
end

function UpgradeService.start()
	if not ENABLED then
		return
	end

	-- Fold the `payout` track into every payout. The registry is keyed so the
	-- session track's own hook and this one compose instead of clobbering each
	-- other, and registering here rather than in Economy keeps Economy from
	-- having to know a prototype exists.
	if SHOP_ON then
		Economy.setMultiplierHook("upgrades", UpgradeService.multiplierFor)
	end

	requestUpgrade.OnServerEvent:Connect(function(player, id)
		UpgradeService.request(player, id)
	end)

	useUtility.OnServerEvent:Connect(function(player)
		UpgradeService.useUtility(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		cooldowns[player] = nil
		lastUse[player] = nil
	end)

	print(("[Tung] UpgradeService: %d upgrades, %d utilities%s")
		:format(SHOP_ON and #Config.PlayerUpgrades or 0,
			UTILITY_ON and #Config.Utilities or 0,
			UTILITY_ON and "" or " (utility slot off)"))
end

return UpgradeService
