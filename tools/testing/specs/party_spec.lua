--[[
	party_spec.lua — the party as a trust boundary (#102).

	Pinned: the lifecycle (invite, accept, leave, dissolve-at-one), the size
	cap, invite expiry, sameParty as the one predicate, the composing income
	bonus, the kindness credit on formation, and the raid loop refusing to
	operate inside a party. The combat and gate consumers take the predicate
	through hooks; the wiring is Main.server's and the Studio list's.
]]

return function(T)

T.family("party", "invite, accept, leave; the boundary the raid and the bonus both read")

local function join(w, name, rebirths)
	local Data = w.req("DataService")
	local player = w.join(name)
	local profile = Data.load(player)
	profile.rebirths = rebirths or 0
	return player, profile
end

T.spec("invite and accept form the party, and the cap holds", function(t)
	local w = T.world()
	local Party = w.req("PartyService")
	local P = w.config.Party

	local host = join(w, "host")
	local guests = {}
	for i = 1, P.MaxSize do
		guests[i] = join(w, "guest" .. i)
	end

	t:isTrue(Party.invite(host, guests[1], 0), "a plain invite was refused")
	t:isTrue(Party.accept(guests[1], 1), "a live invite would not accept")
	t:isTrue(Party.sameParty(host, guests[1]), "accepting did not join the party")
	t:eq(Party.mates(host), 1, "the host's mate count is wrong")

	for i = 2, P.MaxSize - 1 do
		Party.invite(host, guests[i], 0)
		t:isTrue(Party.accept(guests[i], 1), ("guest %d could not join"):format(i))
	end
	local okInvite = Party.invite(host, guests[P.MaxSize], 0)
	t:isFalse(okInvite, "a full party still sent invites")
	t:isFalse(Party.sameParty(host, guests[P.MaxSize]), "the cap did not hold")
end)

T.spec("an invite expires, self-invites and poaching are refused", function(t)
	local w = T.world()
	local Party = w.req("PartyService")
	local P = w.config.Party

	local host = join(w, "host")
	local guest = join(w, "guest")
	local other = join(w, "other")

	t:isFalse(Party.invite(host, host, 0), "you can party with yourself")

	Party.invite(host, guest, 0)
	t:isFalse(Party.accept(guest, P.InviteTimeoutSeconds + 1),
		"an expired invite still joined the party")

	Party.invite(host, guest, 100)
	Party.accept(guest, 101)
	t:isFalse(Party.invite(other, guest, 102),
		"a player already in a party accepted a second membership")
end)

T.spec("leaving dissolves a party of one, and the predicate follows", function(t)
	local w = T.world()
	local Party = w.req("PartyService")

	local host = join(w, "host")
	local guest = join(w, "guest")
	Party.invite(host, guest, 0)
	Party.accept(guest, 1)

	Party.leave(guest)
	t:isFalse(Party.sameParty(host, guest), "the leaver is still bound")
	t:eq(Party.mates(host), 0,
		"a party of one survived — its bonus and its trust boundary would both linger")
	t:isNil(Party.partyOf(host), "the empty party table leaked")
end)

T.spec("forming a party is a kindness both ways, and the bonus reaches income", function(t)
	local w = T.world()
	local Party = w.req("PartyService")
	local Economy = w.req("Economy")
	local P = w.config.Party

	local veteran, vp = join(w, "veteran", 2)
	local newbie, np = join(w, "newbie", 0)
	Party.start()

	local base = Economy.multiplier(veteran)
	Party.invite(veteran, newbie, 0)
	Party.accept(newbie, 1)

	t:eq(vp.reputation, 2, "the veteran's formation credit must carry the gap weight")
	t:eq(np.reputation, 1, "the newbie's side of the formation earned nothing")
	t:near(Economy.multiplier(veteran) / base, 1 + P.BonusPerMate, 1e-6,
		"one partymate must be worth exactly BonusPerMate, composed onto the stack")
end)

T.spec("the raid loop refuses to operate inside a party", function(t)
	local w = T.world()
	local Party = w.req("PartyService")
	local Raid = w.req("RaidService")
	local Data = w.req("DataService")

	local a, ap = join(w, "alice")
	local b = join(w, "bob")
	ap.cash = 1000
	Party.invite(a, b, 0)
	Party.accept(b, 1)

	t:eq(Raid.onStorageBroken({ owner = a }, b, 5), 0,
		"a partymate raided the plot the party exists to defend")

	-- a partymate's kill returns the carry and lifts nothing
	local thief = join(w, "thief")
	local tp = Data.load(thief)
	tp.cash = 1000
	Raid.onStorageBroken({ owner = a }, thief, 10)
	local aliceAfter = ap.cash
	local spoils = Raid.carriedBy(thief)
	Raid.onPlayerDied(thief, nil, 15)
	t:eq(ap.cash, aliceAfter + spoils, "the carry did not come home")

	Party.invite(a, thief, 20)
	Party.accept(thief, 21)
	tp.cash = 1000
	Raid.onPlayerDied(thief, a, 25)
	t:eq(Raid.carriedBy(a), 0,
		"killing your own partymate lifted their overflow — the boundary leaks through death")
end)

end
