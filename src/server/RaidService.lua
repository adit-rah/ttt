--[[
	RaidService.lua — what a raid takes, who carries it, and how it gets home
	(#94).

	design:D-04. Breaking in is #124's verb and the storage unit is #93's
	object; this file owns the LOOT ARITHMETIC between them. Config.Raid holds
	every number, and the shape is: a safe amount is structurally out of reach,
	a break spills a fraction of the overflow above it into the raider's HANDS,
	and the spoils only become the raider's when they stand on their own plot.
	Until then the carrier can be killed, and a kill returns the loot.

	THE SAFE AMOUNT IS UNREACHABLE BY CONSTRUCTION. overflowOf subtracts
	SafeFraction x cap before anything is computed, and every taking — spill
	and kill-steal both — is sized from that remainder. There is no code path
	that reads the victim's cash without the subtraction, which is the only
	kind of guarantee worth making about a number griefers will probe.

	AN EMPTY UNIT STILL PAYS. Raiding has to reward the raider every time or
	the verb dies; a break over no overflow MINTS EmptyBountyFraction of the
	victim's cap for the attacker and the victim loses nothing. Camping decays
	both kinds the same way: spoils halve per repeat on the same victim inside
	the window, so farming one target converges on zero.

	CLOCKS ARE PARAMETERS. Every entry point takes `now` so the specs drive
	time; the wiring in start() passes os.clock(). The one Studio-only piece is
	the banking heartbeat — standing-on-your-own-plot is CFrame arithmetic the
	mock world does not claim to have — and the handoff names it.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Economy = Req("Economy")
local HelpService = Req("HelpService")

local Players = game:GetService("Players")

local RaidService = {}

local R = Config.Raid

-- per-carrier: { total, sources = { [victimUserId] = amount } }. Sources are
-- kept apart so a death can hand each victim back exactly what was theirs.
local carried: { [Player]: { total: number, sources: { [number]: number } } } = {}

-- camping ledger, attacker -> victimUserId -> { count, expires }. Counting
-- resets when the window lapses; the factor is read BEFORE the increment, so
-- the first break always pays full.
local recent: { [Player]: { [number]: { count: number, expires: number } } } = {}

--- The character wears the number so other players can see a thief worth
--- chasing. The handoff owns making it legible; the attribute is the seam.
local function mirrorCarry(player: Player)
	local character = player.Character
	if character and character.SetAttribute then
		local carry = carried[player]
		character:SetAttribute("CarryingTung", carry and carry.total or 0)
	end
end

--- The only Tung a raid can reach: cash above the safe fraction of the cap.
function RaidService.overflowOf(victim: Player): number
	local safe = R.SafeFraction * Economy.storageCapFor(victim)
	return math.max(0, Economy.get(victim) - safe)
end

--- The camping decay: CampingHalving^breaks-inside-the-window. Read only —
--- recordBreak advances the ledger, so a refused raid costs no decay.
function RaidService.campingFactor(attacker: Player, victimUserId: number, now: number): number
	local ledger = recent[attacker]
	local entry = ledger and ledger[victimUserId]
	if not entry or now >= entry.expires then
		return 1
	end
	return R.CampingHalving ^ entry.count
end

local function recordBreak(attacker: Player, victimUserId: number, now: number)
	local ledger = recent[attacker]
	if not ledger then
		ledger = {}
		recent[attacker] = ledger
	end
	local entry = ledger[victimUserId]
	if not entry or now >= entry.expires then
		entry = { count = 0, expires = 0 }
		ledger[victimUserId] = entry
	end
	entry.count += 1
	entry.expires = now + R.CampingWindowSeconds
end

function RaidService.carriedBy(player: Player): number
	local carry = carried[player]
	return carry and carry.total or 0
end

local function addCarry(carrier: Player, victimUserId: number, amount: number)
	if amount <= 0 then
		return
	end
	local carry = carried[carrier]
	if not carry then
		carry = { total = 0, sources = {} }
		carried[carrier] = carry
	end
	carry.total += amount
	carry.sources[victimUserId] = (carry.sources[victimUserId] or 0) + amount
	mirrorCarry(carrier)
end

--- The storage unit broke with an attacker on the bat. Called through
--- Tycoon's break observer (Main.server wires it — the service requires
--- Tycoon's world, so the arrow cannot point back). Returns what the
--- attacker now carries from this break.
function RaidService.onStorageBroken(tycoon, attacker: Player, now: number): number
	local victim = tycoon.owner
	if not victim or not attacker or victim == attacker then
		return 0
	end

	local factor = RaidService.campingFactor(attacker, victim.UserId, now)
	recordBreak(attacker, victim.UserId, now)

	local overflow = RaidService.overflowOf(victim)
	local spoils
	if overflow >= 1 then
		spoils = math.floor(R.SpillFraction * overflow * factor)
		spoils = Economy.take(victim, spoils)
	else
		-- minted, so the raider is paid and the broke stay broke
		spoils = math.floor(R.EmptyBountyFraction * Economy.storageCapFor(victim) * factor)
	end
	if spoils <= 0 then
		return 0
	end

	addCarry(attacker, victim.UserId, spoils)
	Economy.notify(victim, { kind = "warn", title = "Raided!",
		body = ("%s broke your storage and grabbed %s. Kill them before they bank it!")
			:format(attacker.Name, Util.abbreviate(spoils)) })
	Economy.notify(attacker, { kind = "claim", title = "Loot",
		body = ("Carrying %s — get back to your plot."):format(Util.abbreviate(RaidService.carriedBy(attacker))) })
	return spoils
end

--- Standing on your own plot is what banks the carry. The deposit goes
--- through Economy.add, so the CAP CLAMPS IT — loot above what your unit
--- holds is lost, the same rule every other inflow obeys.
function RaidService.bankCarry(player: Player): number
	local carry = carried[player]
	if not carry then
		return 0
	end
	carried[player] = nil
	mirrorCarry(player)
	local banked = Economy.add(player, carry.total, false)
	Economy.notify(player, { kind = "claim", title = "Banked",
		body = banked < carry.total
			and ("Banked %s — your storage held no more."):format(Util.abbreviate(banked))
			or ("Banked %s of stolen Tung."):format(Util.abbreviate(banked)) })
	return banked
end

--- Any death drops the carry, and each victim gets their share straight back
--- if they are still on the server (through Economy.add: their own cap
--- clamps the return too). A killer who is a player also lifts
--- KillStealFraction of the dead player's overflow — into a CARRY of their
--- own, so the chase can chain.
function RaidService.onPlayerDied(victim: Player, killer: Player?, now: number)
	local carry = carried[victim]
	if carry then
		carried[victim] = nil
		mirrorCarry(victim)
		for userId, amount in pairs(carry.sources) do
			local source = Players:GetPlayerByUserId(userId)
			if source then
				local returned = Economy.add(source, amount, false)
				if returned > 0 then
					Economy.notify(source, { kind = "claim", title = "Recovered",
						body = ("%s went down — %s of your Tung came home.")
							:format(victim.Name, Util.abbreviate(returned)) })
				end
				-- downing a thief is a kindness to everyone they robbed;
				-- getting your OWN money back is self-interest, and credit()
				-- refuses self-help anyway
				if killer and killer ~= source then
					HelpService.credit(killer, source, "raid defence", now)
				end
			end
		end
	end

	if killer and killer ~= victim then
		local steal = math.floor(R.KillStealFraction * RaidService.overflowOf(victim) *
			RaidService.campingFactor(killer, victim.UserId, now))
		steal = Economy.take(victim, steal)
		if steal > 0 then
			recordBreak(killer, victim.UserId, now)
			addCarry(killer, victim.UserId, steal)
			Economy.notify(victim, { kind = "warn", title = "Robbed",
				body = ("%s took %s off your body."):format(killer.Name, Util.abbreviate(steal)) })
		end
	end
end

function RaidService.start()
	-- deaths: the classic creator tag CombatService already plants is the
	-- killer credit; a death with no tag (fall, reset) still drops the carry
	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character)
			mirrorCarry(player)
			local humanoid = character:WaitForChild("Humanoid", 10)
			if not humanoid then
				return
			end
			humanoid.Died:Connect(function()
				local tag = humanoid:FindFirstChild("creator")
				local credited = tag and tag.Value
				local killer = (credited and credited:IsA("Player")) and credited or nil
				RaidService.onPlayerDied(player, killer, os.clock())
			end)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		carried[player] = nil
		recent[player] = nil
		for _, ledger in pairs(recent) do
			if player.UserId then
				ledger[player.UserId] = nil
			end
		end
	end)

	-- the banking heartbeat: a carrier standing on their own plot deposits.
	-- CFrame arithmetic — Studio owns proving the rectangle feels right.
	-- PlotService is required HERE: the ledger above runs in the spec
	-- harness, whose bundle carries neither PlotService nor a workspace,
	-- and start() is the one function only Roblox calls.
	local PlotService = Req("PlotService")
	task.spawn(function()
		while true do
			task.wait(2)
			for player, carry in pairs(carried) do
				if carry.total > 0 then
					local tycoon = PlotService.plotOf(player)
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if tycoon and tycoon.cf and root then
						local rel = tycoon.cf:PointToObjectSpace(root.Position)
						local half = Config.World.PlotSize / 2
						if math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z then
							RaidService.bankCarry(player)
						end
					end
				end
			end
		end
	end)
end

return RaidService
