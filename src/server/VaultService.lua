--[[
	VaultService.lua — the number on the side of the vault.

	GROWTH-TODO item 3 is "there is no reason to come back tomorrow", and the
	part of it offline earnings does NOT cover is that the payout is invisible
	until after it has already happened. A player who has never been away has no
	evidence that being away pays anything, and a popup at logout is read by
	nobody — it arrives at the exact moment attention has already left. So the
	promise moves onto the plot, all session, as a column you watch and a
	headline you read on your way out: leaving now banks 2.4M over 8h, and that
	number goes up every time you buy a dropper.

	BE HONEST ABOUT WHAT THIS IS. Nothing on a plot literally fills while you
	are away. Config.Economy.OfflineGraceSeconds holds your plot for three
	minutes and then releases it; you usually come back to a DIFFERENT plot and
	Tycoon:assign replays your installs onto it. There is no object accruing in
	your absence, and pretending otherwise would mean lying with an animation.
	What there is, is one formula:

	    capacity = offline income/sec x Offline.Rate x your cap hours x 3600
	    banked   = the pending welcome-back grant, or 0
	    fraction = clamp(banked / capacity, FillMin, 1)

	Online, banked is 0: the column reads empty and the sign reads the promise.
	Returning, banked is the grant SessionService already computed at join: the
	column is full, the sign says what is waiting, and the prompt on the vault
	pays it out while the column drains.

	WHY A THIRD MODULE. SessionService must not require Tycoon or PlotService —
	its whole reason for existing is that it derives income from a SAVED profile
	so an absent player can be paid without a plot to ask — and Tycoon must not
	require SessionService, because Tycoon is required BY it in the other
	direction of the same argument. A leaf that requires all three keeps both

	AND WHY onOwnedChanged RATHER THAN CLAIM TIME. On return you land on a plot
	that is not the one you left, and assign() replays your purchases onto it as
	a sequence. Computing the projection once when the plot is claimed reads a
	factory that is still half-built. The owned-changed seam fires on every one
	of those installs — which is also exactly when the promise changes — so the
	gauge is driven off it, with a slow beat behind it to pick up the things
	that move without a purchase (a rebirth, a Vault Timer, a grant arriving).

	NET MESSAGES: ZERO. Parts and BillboardGuis replicate on their own, the same
	way the buy-button labels and the arena title already do, and the claim goes
	through a ProximityPrompt — a server-side signal with no payload, which
	satisfies "the client sends an intent, never an amount" more strictly than a
	remote can, because there is nothing to validate.

	WHAT IT OWNS: the text and the fill on every plot's vault. It is the only
	caller of Tycoon:setVaultGauge outside Tycoon:release, and it owns `wired` (one
	connection per Tycoon for the life of the server, not one per claim) and
	`draining` (the guard that stops a 5s beat snapping the column back to full
	underneath the payout animation).

	WHAT IT MUST NOT DO: hold or recompute the offline number. SessionService owns
	pendingOffline, vaultProjectionFor and claimOfflineFor, including the
	double-fire guard that clears entry.offline BEFORE paying — this file reads a
	projection and animates it, and the moment it starts keeping its own copy the
	sign and the wallet can disagree. It also must not create a remote; see above.

	READ THE PROTOTYPE-FLAG LINT IN tools/verify.py BEFORE ANYTHING ELSE. It exists
	because of this file: offline earnings graduated, graduating deletes the flag,
	and the three `not P.Offline` guards left behind read as `not nil` and returned
	out of start() forever. The gauge was dead on main with a green build — no
	check, no spec, no warning. The comment on `local O = Config.Offline` below is
	the full story.

	AND KNOW WHAT IS NOT VERIFIED. VaultService is not in tools/test.py's
	SERVER_MODULES: vault_spec.lua covers the projection (SessionService) and the
	gauge geometry (Tycoon), not the wiring in this file. Two things about it have
	only ever been reasoned about, per HANDOFF_v6 §G5 — which lateral face of the
	vault the gauge landed on, since that is derived from the belt's exitDir and a
	gauge facing a wall makes the whole feature invisible; and whether the column
	reads as a vault filling rather than as a bar stuck on a crate. Check the face
	first: it is cheap and it is total. Note also that the gauge is built inside
	Tycoon:buildCollector, which carries a runtime assert that the collector shell
	stays downstream of the belt run-off, so anything that moves the vault body has
	to clear it.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Util = Req("Util")
local Tycoon = Req("Tycoon")
local DataService = Req("DataService")
local SessionService = Req("SessionService")

local VaultService = {}

-- `local P = Config.Prototypes` used to live here, and three guards below read
-- P.Offline. Offline earnings SHIPPED in the round this file was written, and
-- graduating a feature DELETES its flag -- so P.Offline became nil, `not
-- P.Offline` became true, and VaultService.start() returned before wiring
-- anything. The vault gauge was dead on main and nothing said so: no check, no
-- spec, no warning, and a green build.
--
-- The two branches never conflicted, because they touched different files. See
-- the prototype-flag lint in tools/verify.py, which exists because of this.
local O = Config.Offline
local V = O.Vault

-- Slow on purpose. Everything that changes the promise fires onOwnedChanged;
-- this beat exists only for what does not — a rebirth landing, a Vault Timer
-- bought off the panel, and the welcome-back grant appearing a moment after the
-- plot was claimed.
local BEAT = 5

-- Plots whose prompt has been wired. A Tycoon is built once and reused by every
-- owner it ever has, so the connection must happen once and not once per claim.
local wired: { [any]: boolean } = {}

-- Plots currently playing the post-claim drain, so a beat landing mid-animation
-- does not snap the column back to full underneath it.
local draining: { [any]: boolean } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- the two sentences
-- ─────────────────────────────────────────────────────────────────────────────

--- The exit hook. Deliberately in the second person and deliberately about the
--- FUTURE: the sign is being read by someone who is about to log off.
local function promise(projection): (string, string)
	return
		("LEAVING NOW BANKS %s OVER %dh"):format(
			Util.abbreviate(math.floor(projection.capacity)), projection.capHours),
		("%dh  •  %d%%  •  %s/sec"):format(
			projection.capHours, projection.rate * 100, Util.abbreviate(projection.perSecond))
end

--- The entry hook, read by someone who has just walked back in.
local function waiting(projection, pending): (string, string)
	return
		("%s WAITING"):format(Util.abbreviate(projection.banked)),
		("hold E at the vault  •  %s away  •  %s/sec"):format(
			SessionService.describeDuration(pending.seconds), Util.abbreviate(projection.perSecond))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- the gauge
-- ─────────────────────────────────────────────────────────────────────────────

--- Recompute one plot's gauge from its owner's saved profile. Cheap enough to
--- call on every purchase: it is two table walks and no instances.
function VaultService.refresh(tycoon)
	if draining[tycoon] then
		return
	end
	local player = tycoon.owner
	if not player then
		-- Hands the sign back to Tycoon:updateSign, which paints the free-plot
		-- text on the next pass.
		tycoon:setVaultGauge(0, nil, nil, false)
		return
	end
	local profile = DataService.get(player)
	if not profile then
		return                      -- joined, plot claimed, profile still loading
	end

	local pending = SessionService.pendingOffline(player)
	local projection = SessionService.vaultProjectionFor(profile, pending and pending.earned or 0)

	local headline, detail
	if pending then
		headline, detail = waiting(projection, pending)
	elseif projection.capacity > 0 then
		headline, detail = promise(projection)
	end
	-- capacity 0 leaves headline nil, which hands the board back to
	-- Tycoon:updateSign and its income readout. A plot with no droppers on it
	-- has nothing to promise, and "LEAVING NOW BANKS 0 OVER 8h" is a worse
	-- first thing to read than the sign that was already there.
	tycoon:setVaultGauge(projection.fraction, headline, detail, pending ~= nil)
end

--- Pays the grant out and then EMPTIES THE COLUMN IN FRONT OF THE PLAYER.
---
--- The drain is the point of the whole feature and not decoration. A popup that
--- says "you earned 2.4M" is a thing you dismiss; a column of gold visibly
--- draining into a wallet counting up is the same information delivered as
--- something you watched happen, and it is what teaches the promise on the sign
--- is real — which is what makes it worth reading on the way out tomorrow.
local function collect(tycoon, player: Player)
	if player ~= tycoon.owner or draining[tycoon] then
		return
	end
	local profile = DataService.get(player)
	local pending = SessionService.pendingOffline(player)
	if not profile or not pending then
		return
	end
	-- The double-fire guard lives inside SessionService (entry.offline is
	-- cleared BEFORE the payout), so this can be a straight call — but it
	-- reports whether it actually paid, and animating a drain for a claim that
	-- did not happen would be a lie the player has no way to see through.
	if not SessionService.claimOfflineFor(player) then
		return
	end

	local projection = SessionService.vaultProjectionFor(profile, pending.earned)
	local _, detail = promise(SessionService.vaultProjectionFor(profile, 0))

	draining[tycoon] = true
	task.spawn(function()
		local start = os.clock()
		while true do
			local alpha = math.min((os.clock() - start) / V.PulseSeconds, 1)
			if not tycoon.owner then
				break                 -- left mid-drain; the release already cleared it
			end
			tycoon:setVaultGauge(projection.fraction * (1 - alpha),
				("+%s COLLECTED"):format(Util.abbreviate(pending.earned)), detail, false)
			if alpha >= 1 then
				break
			end
			task.wait(0.05)
		end
		draining[tycoon] = nil
		VaultService.refresh(tycoon)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- wiring
-- ─────────────────────────────────────────────────────────────────────────────

function VaultService.start()
	for _, tycoon in ipairs(Tycoon.all()) do
		if not wired[tycoon] then
			wired[tycoon] = true
			tycoon:onOwnedChanged(VaultService.refresh)
			if tycoon.vaultPrompt then
				tycoon.vaultPrompt.Triggered:Connect(function(player)
					collect(tycoon, player)
				end)
			end
		end
		VaultService.refresh(tycoon)
	end

	task.spawn(function()
		while true do
			task.wait(BEAT)
			for _, tycoon in ipairs(Tycoon.all()) do
				local ok, err = pcall(VaultService.refresh, tycoon)
				if not ok then
					warn("[Tung] vault gauge error on plot " .. tostring(tycoon.index) .. ": " .. tostring(err))
				end
			end
		end
	end)
end

return VaultService
