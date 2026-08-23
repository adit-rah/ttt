--[[
	Fx.lua — every particle / light / sound effect in the game, built from code.

	No asset uploads required: all textures use Roblox's built-in default
	particle sprites (rbxasset://textures/particles/*) which ship with the
	engine and are always available, so nothing here can be moderated away.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local Style = Req("Style")
local Sound = Req("Sound")

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Fx = {}

-- Built-in engine textures. These are shipped in the Roblox client itself.
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE   = "rbxasset://textures/particles/smoke_main.dds"
local FIRE    = "rbxasset://textures/particles/fire_main.dds"

local function emitter(part: BasePart, props: { [string]: any }): ParticleEmitter
	local p = Instance.new("ParticleEmitter")
	p.Name = "TungFx"
	p.Texture = SPARKLE
	p.Lifetime = NumberRange.new(0.4, 0.9)
	p.Rate = 12
	p.Speed = NumberRange.new(1, 3)
	p.SpreadAngle = Vector2.new(180, 180)
	p.LightEmission = 0.6
	p.LockedToPart = false
	for key, value in pairs(props) do
		(p :: any)[key] = value
	end
	p.Parent = part
	return p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-variant recipes
-- ─────────────────────────────────────────────────────────────────────────────

local RECIPES: { [string]: (BasePart, any) -> () } = {}

RECIPES.none = function() end

RECIPES.sparkle = function(part, variant)
	emitter(part, {
		Color = ColorSequence.new(variant.accent, variant.wood),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 14,
		Lifetime = NumberRange.new(0.4, 0.8),
	})
end

RECIPES.dust = function(part, variant)
	emitter(part, {
		Texture = SMOKE,
		Color = ColorSequence.new(variant.wood),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new(1.2),
		Rate = 8,
		Speed = NumberRange.new(0.5, 1.5),
		LightEmission = 0,
	})
end

RECIPES.embers = function(part, variant)
	emitter(part, {
		Texture = FIRE,
		Color = ColorSequence.new(Color3.fromRGB(255, 160, 60), variant.wood),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 22,
		Speed = NumberRange.new(2, 5),
		Acceleration = Vector3.new(0, 6, 0),
		Lifetime = NumberRange.new(0.5, 1.1),
		LightEmission = 1,
	})
end

RECIPES.pulse = function(part, variant)
	emitter(part, {
		Color = ColorSequence.new(variant.wood),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.4, 1.1),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 26,
		Speed = NumberRange.new(0.5, 2),
		LightEmission = 1,
		LightInfluence = 0,
	})
end

RECIPES.void = function(part, variant)
	emitter(part, {
		Color = ColorSequence.new(Color3.fromRGB(160, 80, 255), Color3.fromRGB(30, 0, 60)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.4),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 24,
		Speed = NumberRange.new(-3, -1),  -- negative = sucked inward
		Lifetime = NumberRange.new(0.6, 1.2),
		LightEmission = 1,
		LightInfluence = 0,
	})
end

RECIPES.eclipse = function(part, variant)
	RECIPES.embers(part, variant)
	emitter(part, {
		Color = ColorSequence.new(Color3.fromRGB(255, 150, 40)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 2.4),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Rate = 6,
		Speed = NumberRange.new(0, 0.5),
		LightEmission = 1,
		LightInfluence = 0,
	})
end

RECIPES.galaxy = function(part, _variant)
	emitter(part, {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 160, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 120, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
		}),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 40,
		Speed = NumberRange.new(1, 4),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-180, 180),
		Lifetime = NumberRange.new(0.7, 1.4),
		LightEmission = 1,
		LightInfluence = 0,
	})
end

RECIPES.infinity = function(part, variant)
	RECIPES.galaxy(part, variant)
	emitter(part, {
		Texture = FIRE,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 210, 90)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.2),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Rate = 30,
		Speed = NumberRange.new(3, 8),
		SpreadAngle = Vector2.new(180, 180),
		Lifetime = NumberRange.new(0.4, 0.9),
		LightEmission = 1,
		LightInfluence = 0,
	})
end

--- Applies a variant's signature effect + light to a part.
--- `opts.light = false` skips the PointLight — important for conveyor drops,
--- since Roblox only renders a limited number of lights and hundreds of
--- glowing drops would starve the lights that actually matter.
--- `opts.rateScale` thins out the particles for the same reason.
function Fx.applyVariant(part: BasePart, variant, opts)
	opts = opts or {}
	local recipe = RECIPES[variant.fx or "none"] or RECIPES.none
	recipe(part, variant)

	if opts.rateScale then
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("ParticleEmitter") then
				child.Rate = math.max(1, child.Rate * opts.rateScale)
			end
		end
	end

	if variant.light and opts.light ~= false then
		local light = Instance.new("PointLight")
		light.Color = variant.light.color
		light.Range = variant.light.range
		light.Brightness = variant.light.brightness
		light.Shadows = false
		light.Parent = part
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- One-shot effects
-- ─────────────────────────────────────────────────────────────────────────────

--- A quick expanding ring. Used for purchases, upgrades and heavy hits.
function Fx.burst(position: Vector3, color: Color3, size: number?, parent: Instance?)
	local ring = Instance.new("Part")
	ring.Name = "TungBurst"
	ring.Shape = Enum.PartType.Ball
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.25
	ring.Size = Vector3.one * 0.5
	ring.CFrame = CFrame.new(position)
	ring.Parent = parent or workspace

	local goalSize = Vector3.one * (size or 10)
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = goalSize,
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

--- Floating "+1.2K" text.
function Fx.floatingText(position: Vector3, text: string, color: Color3, parent: Instance?)
	local anchor = Instance.new("Part")
	anchor.Name = "TungFloatText"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = parent or workspace

	-- ONE OF THE TWO THINGS IN THIS GAME THAT DRAWS THROUGH WALLS. A damage
	-- number you can't see is a hit you didn't feel land, and the thing most
	-- likely to be standing between you and it is the enemy you just hit. (The
	-- other is enemy nameplates, and those are Roblox's own — it draws them on
	-- top whatever we ask for.)
	local billboard = Style.billboard(anchor, {
		name = "FloatText", width = 6, height = 2,
		distance = "prop", alwaysOnTop = true,
	})

	local label = Style.text(billboard, { text = text, color = color })

	TweenService:Create(anchor, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(position + Vector3.new(0, 6, 0)),
	}):Play()
	TweenService:Create(label, TweenInfo.new(1.1), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1.3)
end

--- Procedural "tung" percussion. Generated from engine default sound ids that
--- ship with Studio, pitched by index so each variant sounds different.
---
--- With Config.Prototypes.Sound on, both of these hand off to Sound.lua, which
--- plays them out of a fixed pool instead of allocating one Sound per drop.
--- With it off they keep the shipped behaviour exactly, down to the volumes
--- and roll-off distances — the prototype has to be switchable, not merged.
local TUNG_SOUND = "rbxasset://sounds/electronicpingshort.wav"
local IMPACT_SOUND = "rbxasset://sounds/impact_water.mp3"

function Fx.tung(part: BasePart, pitch: number?, volume: number?)
	if Config.Prototypes.Sound then
		Sound.playAt("collect", part, { pitch = pitch, volume = volume or 0.35 })
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = TUNG_SOUND
	sound.PlaybackSpeed = pitch or 1
	sound.Volume = volume or 0.35
	sound.RollOffMaxDistance = 90
	sound.Parent = part
	sound:Play()
	Debris:AddItem(sound, 3)
end

function Fx.impact(part: BasePart, pitch: number?)
	if Config.Prototypes.Sound then
		-- combo is passed by callers that track one (bat swings); without it
		-- this is just the pitch they asked for
		Sound.playAt("impact", part, { pitch = pitch, volume = 0.6, rollOff = 120 })
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = IMPACT_SOUND
	sound.PlaybackSpeed = pitch or 1
	sound.Volume = 0.6
	sound.RollOffMaxDistance = 120
	sound.Parent = part
	sound:Play()
	Debris:AddItem(sound, 3)
end

--- Named passthroughs for the rest of the library, so callers outside Fx do
--- not have to know the asset keys. All no-ops with the flag off.
function Fx.sfx(name: string, position: Vector3?, opts)
	if not Config.Prototypes.Sound then
		return
	end
	if position then
		Sound.playAt(name, position, opts)
	else
		Sound.play(name, opts)
	end
end

--- Trail between two attachments, used on bats mid-swing.
function Fx.trail(a0: Attachment, a1: Attachment, color: Color3): Trail
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 0.22
	trail.LightEmission = 0.8
	trail.MinLength = 0.1
	trail.Enabled = false
	trail.Parent = a0.Parent
	return trail
end

return Fx
