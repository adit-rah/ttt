--[[
	Sound.lua — the whole audio layer, built on sounds that ship INSIDE the
	Roblox client (`rbxasset://sounds/*`). No upload, no moderation queue, and
	nothing here can 404 or be taken down, which is the same contract every
	other asset in this project honours.

	Three rules drive the shape of this file, and all three are failure modes
	rather than preferences:

	  * **Never `Instance.new` a Sound per event.** Around 400 live Sound
	    instances is where audio/video desync starts, and ten plots dropping a
	    Tung every 0.4s reach that inside a minute. Every sound name owns a
	    fixed pool of `Config.Sound.PoolSize` instances handed out round-robin;
	    the 9th overlapping play steals the oldest slot instead of allocating.
	  * **Server-side sound spam can take a 20-player server down.** Anything
	    the client can play for itself, it plays for itself — the server never
	    broadcasts audio it does not have to.
	  * **Everything goes through one SoundGroup.** "There is no way to turn
	    the sound off" is a recurring playtest complaint, and with a group the
	    fix is one property write.

	Gated on `Config.Prototypes.Sound`: with the flag off every entry point
	returns nil before touching a single instance, so a shipping build is
	byte-for-byte the audio it has today.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Sound = {}

local CFG = Config.Sound
local GROUP_NAME = "TungSfx"
local ANCHOR_FOLDER = "TungSfxAnchors"

local IS_SERVER = RunService:IsServer()

export type PlayOptions = {
	pitch: number?,       -- multiplies the resolved playback speed
	volume: number?,
	combo: number?,       -- pitch-stacks: 1 + combo * PitchPerCombo, clamped
	rollOff: number?,     -- override RollOffMaxDistance for one play
	looped: boolean?,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- lazily-built plumbing
-- ─────────────────────────────────────────────────────────────────────────────

local group: SoundGroup? = nil
local groupVolume = 1

--- One group for every sound in the game. Found-or-created rather than always
--- created: the server's group replicates, so a client that arrives late must
--- adopt the existing one instead of stacking a second.
local function soundGroup(): SoundGroup
	if group and group.Parent then
		return group :: SoundGroup
	end
	local existing = SoundService:FindFirstChild(GROUP_NAME)
	if existing and existing:IsA("SoundGroup") then
		group = existing :: SoundGroup
	else
		local made = Instance.new("SoundGroup")
		made.Name = GROUP_NAME
		made.Volume = groupVolume
		made.Parent = SoundService
		group = made
	end
	return group :: SoundGroup
end

local anchorFolder: Folder? = nil

local function anchors(): Folder
	if anchorFolder and anchorFolder.Parent then
		return anchorFolder :: Folder
	end
	local existing = workspace:FindFirstChild(ANCHOR_FOLDER)
	if existing then
		anchorFolder = existing :: Folder
	else
		local made = Instance.new("Folder")
		made.Name = ANCHOR_FOLDER
		made.Parent = workspace
		anchorFolder = made
	end
	return anchorFolder :: Folder
end

--- A pooled positional sound needs somewhere permanent to live. Parenting it
--- to the thing that made the noise looks obvious and is wrong: a drop being
--- collected destroys its children, so the pool would quietly decay back into
--- allocate-per-drop. Each slot owns a 0.2-stud invisible anchor we teleport
--- to the emitter instead.
local function newAnchor(): BasePart
	local part = Instance.new("Part")
	part.Name = "SfxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.Parent = anchors()
	return part
end

type Slot = { sound: Sound, anchor: BasePart? }
type Pool = { slots: { Slot }, cursor: number, lastPlay: number }

local pools: { [string]: Pool } = {}
local warned: { [string]: boolean } = {}

local function buildPool(name: string, assetId: string, positional: boolean): Pool
	local pool: Pool = { slots = {}, cursor = 0, lastPlay = -math.huge }
	for i = 1, math.max(1, CFG.PoolSize) do
		local sound = Instance.new("Sound")
		sound.Name = ("%s_%d"):format(name, i)
		sound.SoundId = assetId
		sound.SoundGroup = soundGroup()
		sound.Volume = 0.5
		if positional then
			local anchor = newAnchor()
			-- RollOffMaxDistance is the whole reason a neighbour's factory
			-- does not blare across the ring: a plot is ~120 studs wide and
			-- the gap between plots is 44, so 60 studs dies out at the fence.
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMinDistance = 8
			sound.RollOffMaxDistance = CFG.RollOffMaxDistance
			sound.Parent = anchor
			table.insert(pool.slots, { sound = sound, anchor = anchor })
		else
			-- parented to a non-BasePart, a Sound is 2D and plays at full
			-- volume wherever the listener is — which is what UI wants
			sound.Parent = SoundService
			table.insert(pool.slots, { sound = sound })
		end
	end
	return pool
end

--- Round-robin, with the repeat-rate guard applied per sound NAME. Two drops
--- landing in the same frame is one audible "tung", not two stacked into a
--- clipped mush — and the guard is what stops a ten-plot server machine-gunning
--- the same 40ms sample.
---
--- os.clock() here, not os.time(): this is a sub-second monotonic timer, and
--- os.time() has 1-second resolution which would silence everything.
local function acquire(name: string, positional: boolean): Slot?
	local assetId = CFG.Library[name]
	if not assetId then
		if not warned[name] then
			warned[name] = true
			warn(("[Tung] no sound named %q in Config.Sound.Library"):format(name))
		end
		return nil
	end

	local key = name .. (positional and "@3d" or "@2d")
	local pool = pools[key]
	if not pool then
		pool = buildPool(name, assetId, positional)
		pools[key] = pool
	end

	local now = os.clock()
	if now - pool.lastPlay < CFG.MinRepeatSeconds then
		return nil
	end
	pool.lastPlay = now

	pool.cursor = (pool.cursor % #pool.slots) + 1
	return pool.slots[pool.cursor]
end

--- `PlaybackSpeed = min(1 + combo * PitchPerCombo, MaxPitch)` — the combo
--- pitch-stack. Rising pitch on a repeated hit is the single cheapest way to
--- make one stock sample read as a streak instead of a stutter.
function Sound.comboPitch(combo: number?): number
	return math.min(1 + (combo or 0) * CFG.PitchPerCombo, CFG.MaxPitch)
end

local function resolvePitch(opts: PlayOptions?): number
	local speed = (opts and opts.pitch) or 1
	if opts and opts.combo then
		speed *= Sound.comboPitch(opts.combo)
	end
	return math.clamp(speed, 0.2, CFG.MaxPitch)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- public
-- ─────────────────────────────────────────────────────────────────────────────

--- 2D one-shot: UI clicks, stings, anything that is not happening at a place.
--- On the client this goes through `PlayLocalSound`, which never replicates and
--- never asks the server for anything.
function Sound.play(name: string, opts: PlayOptions?): Sound?
	if not Config.Prototypes.Sound then
		return nil
	end
	local slot = acquire(name, false)
	if not slot then
		return nil
	end

	local sound = slot.sound
	sound.PlaybackSpeed = resolvePitch(opts)
	sound.Volume = (opts and opts.volume) or 0.5
	sound.Looped = (opts and opts.looped) or false

	if IS_SERVER then
		sound:Play()
	else
		SoundService:PlayLocalSound(sound)
	end
	return sound
end

--- Positional one-shot at a part or a raw position.
---
--- Called from the server this replicates a *bounded* number of instances
--- (PoolSize per name for the whole server), which is the point: the shipped
--- code allocates one Sound per drop and lets Debris clean up after it.
function Sound.playAt(name: string, where: any, opts: PlayOptions?): Sound?
	if not Config.Prototypes.Sound then
		return nil
	end

	local position: Vector3?
	if typeof(where) == "Vector3" then
		position = where
	elseif typeof(where) == "Instance" and where:IsA("BasePart") then
		position = where.Position
	elseif typeof(where) == "CFrame" then
		position = where.Position
	end
	if not position then
		return nil
	end

	local slot = acquire(name, true)
	if not slot or not slot.anchor then
		return nil
	end

	local anchor = slot.anchor :: BasePart
	anchor.CFrame = CFrame.new(position)

	local sound = slot.sound
	sound.PlaybackSpeed = resolvePitch(opts)
	sound.Volume = (opts and opts.volume) or 0.5
	sound.Looped = (opts and opts.looped) or false
	sound.RollOffMaxDistance = (opts and opts.rollOff) or CFG.RollOffMaxDistance
	sound:Play()
	return sound
end

--- The mute toggle a HUD checkbox would drive. Volume rather than
--- SoundGroup.Parent = nil so a muted group still tracks playback position.
function Sound.setVolume(volume: number)
	groupVolume = math.clamp(volume, 0, 1)
	if Config.Prototypes.Sound then
		soundGroup().Volume = groupVolume
	end
end

function Sound.setMuted(muted: boolean)
	Sound.setVolume(muted and 0 or 1)
end

function Sound.group(): SoundGroup?
	if not Config.Prototypes.Sound then
		return nil
	end
	return soundGroup()
end

--- Warms every pool up front so the first drop of the session is not the one
--- that pays for eight instantiations. Safe to call more than once.
function Sound.preload(positional: boolean?)
	if not Config.Prototypes.Sound then
		return
	end
	for name, assetId in pairs(CFG.Library) do
		local wants3d = positional ~= false
		local key = name .. (wants3d and "@3d" or "@2d")
		if not pools[key] then
			pools[key] = buildPool(name, assetId, wants3d)
		end
	end
end

return Sound
