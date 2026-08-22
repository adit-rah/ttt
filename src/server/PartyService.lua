--[[
	PartyService.lua — deliberate grouping (#102).

	design:D-04. A party is a TRUST BOUNDARY as much as a bonus: partymates
	cannot damage each other, cannot raid each other's plots, and open each
	other's gates — the door #89's owner-only gates promised invited guests.
	Those three consumers reach the one predicate, sameParty, through hooks
	wired in Main.server (CombatService's ally check, Tycoon.allyCheck) or by
	requiring this module (GateService, RaidService); nothing here requires
	any of them back.

	SESSION-SCOPED. A party lives while two or more members are on this
	server, and dissolves to nothing below that. Persistence would need a
	roster nobody present can see; the co-play signal this exists for is
	per-session anyway.

	THE SERVER DECIDES EVERYTHING. One remote both ways: the client sends
	{ action, target } and renders whatever state comes back — the
	SessionState arrangement. Invites die quietly after InviteTimeoutSeconds;
	the expiry is checked on read, so no timer thread exists to leak.

	THE BONUS COMPOSES. "party" is a named Economy multiplier hook beside
	"friends" and "help", and the verifier bounds the whole stack. Forming a
	party is also a kindness: accept credits BOTH sides through
	HelpService.credit, so a veteran partying with a new player comes out
	ahead — #123's weighting, for free.

	Clocks are parameters on the ledger functions; start()'s handlers pass
	os.clock(). The module runs headless in the spec harness.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Net = Req("Net")
local Economy = Req("Economy")
local HelpService = Req("HelpService")

local Players = game:GetService("Players")

local PartyService = {}

local P = Config.Party

-- one shared members array per party; every member maps to the SAME table,
-- which is what makes sameParty a two-read identity check
local partyOf: { [Player]: { Player } } = {}

-- invitee -> { from, expires }. One pending invite per invitee: a second
-- invite overwrites the first, which is the friendly direction — the newest
-- ask is the one on screen.
local invites: { [Player]: { from: Player, expires: number } } = {}

local remote = Net.event("Party")

local function push(player: Player)
	local members = partyOf[player]
	local names = {}
	if members then
		for _, member in ipairs(members) do
			table.insert(names, { name = member.DisplayName, userId = member.UserId })
		end
	end
	local invite = invites[player]
	remote:FireClient(player, {
		members = names,
		invite = invite and { fromName = invite.from.DisplayName, fromUserId = invite.from.UserId } or nil,
	})
end

local function pushParty(members: { Player })
	for _, member in ipairs(members) do
		push(member)
	end
end

function PartyService.partyOf(player: Player): { Player }?
	return partyOf[player]
end

--- The predicate the trust boundary hangs on: same shared table, or false.
function PartyService.sameParty(a: Player?, b: Player?): boolean
	if not a or not b or a == b then
		return false
	end
	return partyOf[a] ~= nil and partyOf[a] == partyOf[b]
end

--- Partymates present, for the income hook. Zero outside a party.
function PartyService.mates(player: Player): number
	local members = partyOf[player]
	return members and math.max(0, #members - 1) or 0
end

--- Returns (ok, reason). The reasons are player-facing.
function PartyService.invite(from: Player, to: Player, now: number): (boolean, string)
	if from == to then
		return false, "that is you"
	end
	if PartyService.sameParty(from, to) then
		return false, "already in your party"
	end
	if partyOf[to] then
		return false, ("%s is in another party"):format(to.DisplayName)
	end
	local members = partyOf[from]
	if members and #members >= P.MaxSize then
		return false, ("your party is full (%d)"):format(P.MaxSize)
	end
	invites[to] = { from = from, expires = now + P.InviteTimeoutSeconds }
	push(to)
	return true, to.DisplayName
end

function PartyService.accept(invitee: Player, now: number): (boolean, string)
	local invite = invites[invitee]
	invites[invitee] = nil
	if not invite or now >= invite.expires then
		push(invitee)
		return false, "that invite has expired"
	end
	local from = invite.from
	if not from.Parent then
		push(invitee)
		return false, "they left the server"
	end
	if partyOf[invitee] then
		return false, "you are already in a party"
	end
	local members = partyOf[from]
	if members and #members >= P.MaxSize then
		push(invitee)
		return false, "that party filled up"
	end
	if not members then
		members = { from }
		partyOf[from] = members
	end
	table.insert(members, invitee)
	partyOf[invitee] = members

	-- forming a party is a kindness both ways; #123's gap weighting rides in
	HelpService.credit(from, invitee, "partying up", now)
	HelpService.credit(invitee, from, "partying up", now)

	pushParty(members)
	return true, from.DisplayName
end

function PartyService.decline(invitee: Player)
	invites[invitee] = nil
	push(invitee)
end

function PartyService.leave(player: Player)
	local members = partyOf[player]
	if not members then
		return
	end
	partyOf[player] = nil
	for index, member in ipairs(members) do
		if member == player then
			table.remove(members, index)
			break
		end
	end
	-- a party of one is nobody's party
	if #members == 1 then
		partyOf[members[1]] = nil
	end
	push(player)
	pushParty(members)
end

function PartyService.start()
	-- the bonus: an O(1) read, per the Economy hook contract
	Economy.setMultiplierHook("party", function(player)
		return 1 + P.BonusPerMate * math.min(PartyService.mates(player), P.MaxSize - 1)
	end)

	remote.OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local now = os.clock()
		if payload.action == "invite" then
			local target = type(payload.target) == "number" and Players:GetPlayerByUserId(payload.target)
			if target then
				local ok, what = PartyService.invite(player, target, now)
				Economy.notify(player, { kind = ok and "info" or "warn", title = "Party",
					body = ok and ("Invited %s."):format(what) or what })
				if ok then
					Economy.notify(target, { kind = "info", title = "Party",
						body = ("%s invited you — check your party card."):format(player.DisplayName) })
				end
			end
		elseif payload.action == "accept" then
			local ok, what = PartyService.accept(player, now)
			Economy.notify(player, { kind = ok and "claim" or "warn", title = "Party",
				body = ok and ("You joined %s's party."):format(what) or what })
		elseif payload.action == "decline" then
			PartyService.decline(player)
		elseif payload.action == "leave" then
			PartyService.leave(player)
			Economy.notify(player, { kind = "info", title = "Party", body = "You left the party." })
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		PartyService.leave(player)
		invites[player] = nil
		-- and any invite FROM them dies with them
		for invitee, invite in pairs(invites) do
			if invite.from == player then
				invites[invitee] = nil
				push(invitee)
			end
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.defer(push, player)
	end)
end

return PartyService
