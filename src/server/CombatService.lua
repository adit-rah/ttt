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
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local CombatService = {}

local hitFeedback = Net.event("HitFeedback")
local knockbackRemote = Net.event("Knockback")

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

function CombatService.equipCurrentBat(player: Player)
	-- a character can spawn before the DataStore read finishes on first join
	local profile = DataService.get(player)
	local deadline = os.clock() + 12
	while not profile and player.Parent and os.clock() < deadline do
		task.wait(0.25)
		profile = DataService.get(player)
	end
	if not profile or not player.Parent then
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

--- Swings the BAT and nothing else.
---
--- Tool.Grip is the offset of the built-in RightGrip weld between the hand and
--- the Handle, so tweening it moves the bat within the hand. The character's
--- arm keeps whatever pose Roblox's own Animate script gives it — we never
--- touch the rig, play an animation, or override a limb.
local function animateSwing(tool: Tool, duration: number)
	local base = tool:GetAttribute("BaseGrip")
	if typeof(base) ~= "CFrame" then
		base = tool.Grip
		tool:SetAttribute("BaseGrip", base)
	end

	local windUp = TweenService:Create(tool, TweenInfo.new(duration * 0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Grip = base * CFrame.Angles(math.rad(-55), 0, 0),
	})
	local strike = TweenService:Create(tool, TweenInfo.new(duration * 0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Grip = base * CFrame.Angles(math.rad(95), 0, math.rad(20)),
	})
	local reset = TweenService:Create(tool, TweenInfo.new(duration * 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Grip = base,
	})

	windUp:Play()
	windUp.Completed:Once(function()
		strike:Play()
		strike.Completed:Once(function()
			reset:Play()
		end)
	end)
end

--- Applies damage to any humanoid, from a player or from an NPC.
function CombatService.damage(victimModel: Model, amount: number, sourcePosition: Vector3?, knockback: number?, attacker: Player?)
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
		})
	end
	return true
end

local function hitscan(character: Model, reach: number): { Model }
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	if not root then
		return {}
	end
	local size = Config.Combat.HitboxSize
	local box = root.CFrame * CFrame.new(0, 0, -(reach / 2))
	local boxSize = Vector3.new(size.X, size.Y, reach)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.MaxParts = 60

	local parts = workspace:GetPartBoundsInBox(box, boxSize, params)

	local seen = {}
	local victims = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
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

	-- combo
	if now - s.comboAt <= Config.Combat.ComboWindow then
		s.combo = math.min(s.combo + 1, Config.Combat.ComboMaxStacks)
	else
		s.combo = 0
	end
	s.comboAt = now

	animateSwing(tool, cooldown)

	local handle = tool:FindFirstChild("Handle") :: BasePart
	local trail = handle and handle:FindFirstChild("SwingTrail") :: Trail
	if trail then
		trail.Enabled = true
		task.delay(cooldown * 0.55, function()
			if trail.Parent then
				trail.Enabled = false
			end
		end)
	end
	if handle then
		Fx.impact(handle, 1.4 + math.random() * 0.2)
	end

	local reach = tool:GetAttribute("Reach") or 9
	local baseDamage = tool:GetAttribute("Damage") or 18
	local knockback = tool:GetAttribute("Knockback") or 55
	local critChance = tool:GetAttribute("Crit") or 0.08

	local comboMult = 1 + s.combo * Config.Combat.ComboDamagePerStack
	local crit = math.random() < critChance
	local damage = baseDamage * comboMult * (crit and 2 or 1)

	local origin = character:GetPivot().Position

	for _, victim in ipairs(hitscan(character, reach)) do
		if CombatService.canDamage(player, victim) then
			CombatService.damage(victim, damage, origin, knockback * (crit and 1.6 or 1), player)
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
	humanoid.WalkSpeed = 19
	humanoid.JumpPower = 52
	humanoid.UseJumpPower = true

	task.wait(0.35)
	CombatService.equipCurrentBat(player)

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
	CombatService.damage(victimModel, damage, npcRoot.Position, 28, nil)
end

function CombatService.start()
	Players.PlayerRemoving:Connect(function(player)
		state[player] = nil
	end)
end

return CombatService
