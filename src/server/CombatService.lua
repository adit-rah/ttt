--[[
	CombatService.lua — bats, swinging, damage, knockback and PvP rules.

	Design notes
	  * The server is authoritative. Tool.Activated replicates, so the client
	    never gets to say "I hit them"; it only asks for a swing.
	  * PvP is opt-in by geography: you can only hurt another player while
	    BOTH of you are inside the arena ring. Your plot is a safe zone.
	  * Sahur raiders can be hit anywhere.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Fx = Req("Fx")
local Net = Req("Net")
local TungModels = Req("TungModels")
local DataService = Req("DataService")
local Economy = Req("Economy")

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local CombatService = {}

local hitFeedback = Net.event("HitFeedback")
local knockbackRemote = Net.event("Knockback")
local swingFx = Net.event("SwingFx")

local state: { [Player]: { lastSwing: number, combo: number, comboAt: number } } = {}

local function stateFor(player: Player)
	local s = state[player]
	if not s then
		s = { lastSwing = 0, combo = 0, comboAt = 0 }
		state[player] = s
	end
	return s
end

-- ─────────────────────────────────────────────────────────────────────────────
-- zones
-- ─────────────────────────────────────────────────────────────────────────────

function CombatService.inArena(position: Vector3): boolean
	local flat = Vector3.new(position.X, 0, position.Z)
	return flat.Magnitude <= Config.World.ArenaRadius
end

--- Can `attacker` (a Player) hurt `victimModel`?
function CombatService.canDamage(attacker: Player, victimModel: Model): boolean
	if victimModel:GetAttribute("IsSahurNPC") then
		return true
	end
	local victimPlayer = Players:GetPlayerFromCharacter(victimModel)
	if not victimPlayer then
		return false
	end
	if victimPlayer == attacker then
		return false
	end
	if not Config.Combat.ArenaPvP then
		return true
	end
	local attackerChar = attacker.Character
	if not attackerChar then
		return false
	end
	return CombatService.inArena(attackerChar:GetPivot().Position)
		and CombatService.inArena(victimModel:GetPivot().Position)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- bats
-- ─────────────────────────────────────────────────────────────────────────────

local function removeBats(container: Instance?)
	if not container then
		return
	end
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("BatId") then
			child:Destroy()
		end
	end
end

--- Blocks until the player's profile has loaded, or gives up. A character can
--- spawn before the DataStore read finishes on first join, and everything that
--- dresses that character needs the profile.
local function waitForProfile(player: Player)
	local profile = DataService.get(player)
	local deadline = os.clock() + 12
	while not profile and player.Parent and os.clock() < deadline do
		task.wait(0.25)
		profile = DataService.get(player)
	end
	return player.Parent and profile or nil
end

function CombatService.equipCurrentBat(player: Player)
	local profile = waitForProfile(player)
	if not profile then
		return
	end
	local tier = math.clamp(profile.batTier or 1, 1, #Config.Bats)
	local def = Config.Bats[tier]

	removeBats(player:FindFirstChildOfClass("Backpack"))
	removeBats(player.Character)

	local tool = TungModels.buildBatTool(def)
	-- straight into the Backpack: Roblox's own inventory + hotbar handles
	-- equipping, dropping and slot assignment, so we don't reimplement any of it
	tool.Parent = player:FindFirstChildOfClass("Backpack")

	CombatService.bind(player, tool)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- armour
--
-- Lives here rather than in a service of its own because CombatService already
-- owns the two places armour has to touch: onCharacter, which is the only
-- writer of a player's humanoid stats, and CombatService.damage, which is the
-- only TakeDamage call in the repo. A separate service would have to race the
-- first and reach across the second.
-- ─────────────────────────────────────────────────────────────────────────────

function CombatService.armorTierOf(player: Player)
	local profile = DataService.get(player)
	local tier = math.clamp(profile and profile.armorTier or 1, 1, #Config.Armor.Tiers)
	return Config.Armor.Tiers[tier]
end

function CombatService.applyArmor(player: Player, character: Model?)
	character = character or player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local health = CombatService.armorTierOf(player).health
	local delta = health - humanoid.MaxHealth
	humanoid.MaxHealth = health
	-- Setting MaxHealth alone leaves Health where it was, so a fully-armoured
	-- player spawns showing 100/320 and looking like they are bleeding out. The
	-- bar IS the reward for this track, so it has to read right.
	--
	-- Raised by the DELTA rather than to full, so buying armour in the middle
	-- of a raid is not also a free heal.
	humanoid.Health = math.clamp(humanoid.Health + math.max(0, delta), 1, health)
end

function CombatService.grantArmor(player: Player, armorId: string)
	local def = Config.ArmorById[armorId]
	local profile = DataService.get(player)
	if not def or not profile then
		return
	end
	-- monotonic, like grantBat: re-installing a tier you already have on a
	-- claim or a replay must not be a downgrade
	if def.tier <= (profile.armorTier or 1) then
		return
	end
	profile.armorTier = def.tier
	CombatService.applyArmor(player)
	Economy.push(player)
	Economy.notify(player, {
		kind = "gear",
		title = "NEW ARMOR: " .. def.name,
		body = ("%d max health"):format(def.health),
	})
end

function CombatService.grantBat(player: Player, batId: string)
	local def = Config.BatById[batId]
	local profile = DataService.get(player)
	if not def or not profile then
		return
	end
	if def.tier <= (profile.batTier or 1) then
		return
	end
	profile.batTier = def.tier
	CombatService.equipCurrentBat(player)
	Economy.push(player)
	Economy.notify(player, {
		kind = "gear",
		title = "NEW BAT: " .. def.name,
		body = ("%d damage  •  %.0f%% crit"):format(def.damage, def.crit * 100),
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- swinging
-- ─────────────────────────────────────────────────────────────────────────────

--- Tells every client to play swing `comboIndex` on this character.
---
--- The animation itself is client-side (see SwingAnim): Motor6D.Transform does
--- not replicate, so the server can only broadcast the fact of the swing and
--- let each client draw it. The attacker's own client has already started the
--- same swing from Tool.Activated — waiting for this round trip to begin the
--- wind-up is exactly what makes networked melee feel like mud.
local function broadcastSwing(character: Model, comboIndex: number, duration: number)
	swingFx:FireAllClients({
		character = character,
		combo = comboIndex,
		duration = duration,
	})
end

--- Applies damage to any humanoid, from a player or from an NPC.
function CombatService.damage(victimModel: Model, amount: number, sourcePosition: Vector3?, knockback: number?, attacker: Player?, crit: boolean?)
	local humanoid, root = Util.getRig(victimModel)
	if not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	-- classic "creator" tag so whoever landed the last hit gets the credit
	if attacker then
		local old = humanoid:FindFirstChild("creator")
		if old then
			old:Destroy()
		end
		local tag = Instance.new("ObjectValue")
		tag.Name = "creator"
		tag.Value = attacker
		tag.Parent = humanoid
		Debris:AddItem(tag, 8)
	end

	humanoid:TakeDamage(amount)

	if knockback and knockback > 0 and sourcePosition then
		local direction = (root.Position - sourcePosition)
		direction = Vector3.new(direction.X, 0, direction.Z)
		if direction.Magnitude < 0.1 then
			direction = Vector3.new(0, 0, 1)
		end
		direction = direction.Unit
		local impulse = (direction * knockback + Vector3.new(0, knockback * 0.45, 0)) * root.AssemblyMass * 0.6

		local victimPlayer = Players:GetPlayerFromCharacter(victimModel)
		if victimPlayer then
			-- The victim's own client owns their character's physics, so a
			-- server-side ApplyImpulse is overwritten on the next replication
			-- tick. Ask the owning client to apply it instead.
			knockbackRemote:FireClient(victimPlayer, impulse)
		else
			root:ApplyImpulse(impulse)
		end
	end

	if attacker then
		hitFeedback:FireClient(attacker, {
			damage = amount,
			position = root.Position,
			killed = humanoid.Health <= 0,
			crit = crit == true,
		})
	end
	return true
end

local function hitscan(character: Model, reach: number, width: number): { Model }
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not root then
		return {}
	end
	local size = Config.Combat.HitboxSize
	local box = root.CFrame * CFrame.new(0, 0, -(reach / 2))
	local boxSize = Vector3.new(size.X * width, size.Y, reach)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.MaxParts = 60

	local parts = workspace:GetPartBoundsInBox(box, boxSize, params)

	local seen = {}
	local victims = {}
	for _, part in ipairs(parts) do
		-- Walk UP until we find the model that owns a Humanoid, rather than
		-- stopping at the first Model ancestor. A raider's visible body is a
		-- sub-model of the rig, and the arm is a sub-model of that, so the first
		-- Model above a hit part is often not the character at all.
		local model = part:FindFirstAncestorOfClass("Model")
		while model and not model:FindFirstChildOfClass("Humanoid") do
			model = model:FindFirstAncestorOfClass("Model")
		end
		if model and not seen[model] then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				seen[model] = true
				table.insert(victims, model)
			end
		end
	end
	return victims
end

--- Resolves one strike: box the area in front of the swinger and damage
--- whatever is in it that we're allowed to hurt.
local function resolveStrike(player: Player, character: Model, hit: { [Model]: boolean },
	reach: number, width: number, damage: number, knockback: number, crit: boolean)

	local origin = character:GetPivot().Position

	for _, victim in ipairs(hitscan(character, reach, width)) do
		-- one swing damages a given victim once, however many samples see them
		if not hit[victim] and CombatService.canDamage(player, victim) then
			hit[victim] = true
			CombatService.damage(victim, damage, origin, knockback, player, crit)
			local _, victimRoot = Util.getRig(victim)
			if victimRoot then
				Fx.burst(victimRoot.Position, crit and Color3.fromRGB(255, 120, 80) or Color3.fromRGB(255, 230, 160),
					crit and 12 or 7, workspace)
				Fx.floatingText(victimRoot.Position + Vector3.new(0, 3, 0),
					(crit and "CRIT " or "") .. tostring(math.floor(damage)),
					crit and Color3.fromRGB(255, 140, 90) or Color3.fromRGB(255, 250, 220), workspace)
				Fx.impact(victimRoot, crit and 0.75 or 1)
			end
		end
	end
end

function CombatService.swing(player: Player, tool: Tool)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local s = stateFor(player)
	local now = os.clock()
	local cooldown = tool:GetAttribute("Cooldown") or 0.55
	if now - s.lastSwing < cooldown then
		return
	end
	s.lastSwing = now

	-- combo. Stack 0 is the first swing of a chain, so the animation index is
	-- one higher; the last step of the chain is the overhead finisher.
	if now - s.comboAt <= Config.Combat.ComboWindow then
		s.combo = (s.combo + 1) % (Config.Combat.ComboMaxStacks + 1)
	else
		s.combo = 0
	end
	s.comboAt = now

	local comboIndex = s.combo + 1
	local finisher = comboIndex == Config.Combat.SwingSteps

	broadcastSwing(character, comboIndex, cooldown)

	local handle = tool:FindFirstChild("Handle") :: BasePart
	local trail = handle and handle:FindFirstChild("SwingTrail") :: Trail
	if trail then
		-- the trail belongs to the strike, not to the wind-up: leaving it on
		-- for the whole swing draws a streak of the bat sitting still
		task.delay(cooldown * Config.Combat.SwingWindUp, function()
			if trail.Parent then
				trail.Enabled = true
			end
		end)
		task.delay(cooldown * (Config.Combat.SwingStrikeAt + 0.18), function()
			if trail.Parent then
				trail.Enabled = false
			end
		end)
	end
	if handle then
		Fx.impact(handle, 1.4 + math.random() * 0.2)
	end

	local reach = (tool:GetAttribute("Reach") or 9) * (finisher and Config.Combat.FinisherReach or 1)
	local baseDamage = tool:GetAttribute("Damage") or 18
	local knockback = (tool:GetAttribute("Knockback") or 55) * (finisher and Config.Combat.FinisherKnockback or 1)
	local critChance = tool:GetAttribute("Crit") or 0.08

	local comboMult = 1 + s.combo * Config.Combat.ComboDamagePerStack
	local crit = math.random() < critChance
	local damage = baseDamage * comboMult
		* (crit and Config.Combat.CritMultiplier or 1)
		* (finisher and Config.Combat.FinisherDamage or 1)
	if crit then
		knockback *= Config.Combat.CritKnockback
	end
	-- the slam lands flat in front of you rather than in a narrow line
	local width = finisher and 1.3 or 1

	-- The swing is resolved on its STRIKE FRAME, not on the frame the player
	-- clicked. That is the whole point of the rewrite: damage used to land a
	-- full animation before the bat visibly reached anything, which is why
	-- combat read as clicking rather than as hitting. The cost is that a target
	-- can now step out of a telegraphed swing, which is the point.
	local generation = s.lastSwing
	local hit: { [Model]: boolean } = {}

	local function strike()
		-- A second swing, a death, a respawn or a disconnect since we were
		-- scheduled all cancel this one. The player check matters: canDamage
		-- lets anyone hit an NPC without looking at the attacker, so without it
		-- a departing player's last swing still lands, tags a raider with a
		-- creator who is gone, and fires hit feedback at nobody.
		if s.lastSwing ~= generation
			or player.Parent == nil
			or player.Character ~= character
			or humanoid.Health <= 0
			or character.Parent == nil
		then
			return
		end
		resolveStrike(player, character, hit, reach, width, damage, knockback, crit)
	end

	task.delay(cooldown * Config.Combat.SwingStrikeAt, function()
		strike()
		-- The arc is still moving, so one instantaneous box misses anyone a few
		-- frames early or late. Sample again just after.
		task.delay(Config.Combat.SwingSampleGap, strike)
	end)
end

function CombatService.bind(player: Player, tool: Tool)
	tool.Activated:Connect(function()
		CombatService.swing(player, tool)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function CombatService.onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = Config.Combat.WalkSpeed
	humanoid.JumpPower = Config.Combat.JumpPower
	humanoid.UseJumpPower = true

	task.wait(0.35)
	if not waitForProfile(player) then
		return
	end
	CombatService.applyArmor(player, character)
	CombatService.equipCurrentBat(player)

	-- Re-apply once a beat later. Roblox's own Health script and the respawn
	-- pipeline both write Humanoid.Health after CharacterAdded returns, and
	-- nothing orders those against this write. Guarded on the character still
	-- being current so a fast death-respawn cannot apply to the wrong body.
	task.delay(0.75, function()
		if player.Character == character and humanoid.Health > 0 then
			CombatService.applyArmor(player, character)
		end
	end)

	humanoid.Died:Connect(function()
		local killerTag = humanoid:FindFirstChild("creator") :: ObjectValue?
		if killerTag and killerTag.Value and killerTag.Value:IsA("Player") then
			CombatService.creditKill(killerTag.Value, player.Name)
		end
	end)
end

function CombatService.creditKill(player: Player, victimName: string)
	local profile = DataService.get(player)
	if not profile then
		return
	end
	profile.kills += 1
	Economy.push(player)
	Economy.notify(player, { kind = "ko", title = "KO!", body = victimName })
end

--- Used by NPCService so raider damage flows through the same path.
function CombatService.npcAttack(npc: Model, victimModel: Model, damage: number)
	local _, npcRoot = Util.getRig(npc)
	if not npcRoot then
		return
	end
	CombatService.damage(victimModel, damage, npcRoot.Position, Config.Waves.AttackKnockback, nil)
end

function CombatService.start()
	Players.PlayerRemoving:Connect(function(player)
		state[player] = nil
	end)
end

return CombatService
