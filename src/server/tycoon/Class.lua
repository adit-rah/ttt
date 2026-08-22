--[[
	tycoon/Class.lua — the Tycoon table itself, and the constructor that builds
	one plot out of it.

	THE ONE TABLE EVERY OTHER FILE IN THIS FOLDER HANGS ITS METHODS ON. This
	file requires no sibling, which is what keeps the folder acyclic: Req raises
	"circular dependency" at RUNTIME (Req.lua:70-73), so a mixin that required
	the aggregator back would fail the boot rather than the build.

	It owns the state a plot is made of — `paths`, `owned`, `objects`,
	`factoryFolders`, the two belt-speed inputs — and the values the mixins
	share. COLORS, MISC_SPOTS and MIN_PART hang off the class table rather than
	being file-locals because a file-local cannot be read from the file next
	door. They are read there, never written.

	Tycoon.new CALLS METHODS THIS FILE DOES NOT DEFINE (buildBelt,
	buildCollector, ensureCabinets, updateSign, ...). That is safe because
	nothing reaches Tycoon.new without going through Req("Tycoon"), the
	aggregator, which requires every mixin first. Req("Class") on its own would
	hand you a class that builds a pad and nothing on it.
]]

local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
local Config = Req("Config")
local MapBuilder = Req("MapBuilder")

local L = Config.Layout

local Tycoon = {}
Tycoon.__index = Tycoon

--- Roblox refuses a part thinner than this on any axis, and silently keeps the
--- old size rather than erroring — so an empty gauge would keep whatever height
--- it last had. The floor is here rather than in Config because it is a
--- property of the engine, not a tuning knob.
Tycoon.MIN_PART = 0.05

--- Every plot built this session, in plot order. PlotService owns the plots and
--- hands them out by player; a service that has to walk ALL of them (like
--- FloorService) has nowhere else to get the list.
local INSTANCES: { any } = {}

function Tycoon.all(): { any }
	return INSTANCES
end

-- Buttons that aren't attached to a belt machine sit in a row on the open
-- floor, spaced further apart than a button is wide. Positions live in Config
-- so they scale with the plot instead of drifting into the wall when it grows.
Tycoon.MISC_SPOTS = L.MiscButtons

Tycoon.COLORS = {
	frame     = Color3.fromRGB(118, 122, 130),
	metal     = Color3.fromRGB(160, 164, 172),
	belt      = Color3.fromRGB(62, 62, 68),
	beltLine  = Color3.fromRGB(255, 176, 60),
	buttonOn  = Color3.fromRGB(110, 235, 150),
	buttonOff = Color3.fromRGB(230, 90, 90),
	preview   = Color3.fromRGB(126, 122, 146),
	vault     = Color3.fromRGB(146, 110, 72),
	gold      = Color3.fromRGB(255, 205, 90),
	-- The gauge in its two voices, on the same two-voice principle as
	-- Style.Button/ButtonLocked: bright gold is tung you can COLLECT, the
	-- duller amber is tung you would bank by leaving. Colour is not carrying
	-- the difference on its own — the empty column is also a sliver rather
	-- than a full pane, and the prompt is off.
	vaultPromise = Color3.fromRGB(196, 150, 70),
}

function Tycoon.new(index: number, parent: Instance)
	local self = setmetatable({}, Tycoon)

	self.index = index
	self.owner = nil :: Player?
	self.owned = {}
	self.objects = {}
	self.generation = 0
	-- BELT SPEED IS DERIVED, NOT ACCUMULATED. It has two inputs now — the
	-- additive Belt bonus and the multiplicative generator factor — and `+=` on
	-- the product is only safe while install() guards on `owned`. It does, but
	-- assign() replays a save by installing every owned button in `order`
	-- sequence, so a multiplicative installer written the same way as the Belt
	-- one would land on 1.19 x 1.42 x 1.68 x 2.00 rather than on 2.00. Keep the
	-- two inputs and recompute; the hot path still reads the cached product.
	self.beltBonus = 0
	self.powerFactor = 1
	self.beltSpeed = L.BeltSpeed
	self.dropCount = 0
	self.dropPool = {}   -- retired drop bodies, shelved per variant (Drops.lua)
	-- The storage unit's state (Storage.lua). A plain table here rather than
	-- resetStorage(), because Class must not call methods the mixins attach.
	self.storage = { health = Config.Storage.MaxHealth, broken = false }
	-- The walls' and gates' state (Siege.lua). Empty means nothing tracked
	-- yet; assign() fills it via resetSiege, then overwrites from the save.
	self.structureHealth = {}

	-- Folders that come and go with the factory. Registered as they are built
	-- rather than listed in setFactoryVisible; see registerFactoryFolder.
	self.factoryFolders = {}
	self.factoryShown = true
	self.ownedChangedListeners = {}

	-- BELT PATHS ARE REGISTERED UP FRONT, all of them, including floors nobody
	-- has bought yet. A path is pure maths — legs, directions, normals — and
	-- registering it builds nothing. It has to happen here because buy buttons
	-- are built once, on first claim, and a button standing on the mezzanine
	-- needs that path to exist to know its own height. The floor's PARTS still
	-- wait for the purchase.
	self.paths = {}
	for _, path in ipairs(Config.BeltPaths) do
		self:addBeltPath(path)
	end

	local model, cf = MapBuilder.buildPlotPad(parent, index)
	self.model = model
	self.cf = cf
	self.padPart = model:FindFirstChild("Pad")

	self.machines = Instance.new("Folder")
	self.machines.Name = "Machines"
	self.machines.Parent = model
	self:registerFactoryFolder(self.machines)

	-- Side-track props: the cabinets and whatever stands on their shelves.
	-- A SEPARATE folder from self.machines specifically because rebirth does
	-- machines:ClearAllChildren() — putting a bat display in there would wipe
	-- the cabinet every prestige while its purchase survived in the profile.
	-- release() still clears this one: new owner, different tiers.
	self.props = Instance.new("Folder")
	self.props.Name = "Props"
	self.props.Parent = model
	self:registerFactoryFolder(self.props)

	self.buttonsFolder = Instance.new("Folder")
	self.buttonsFolder.Name = "Buttons"
	self.buttonsFolder.Parent = model

	self.drops = Instance.new("Folder")
	self.drops.Name = "Drops"
	self.drops.Parent = model

	self:buildBelt(1)
	self:buildCollector(1, nil, true)
	self:buildRebirthPad()
	self:buildClaimPad()
	self:ensureCabinets()
	-- Kept like a cabinet body. The generator standing on it is a machine and
	-- comes and goes with a rebirth; the slab does not. Idempotent, and also
	-- re-run from refreshButtons, because release() clears self.props.
	self:ensureYard()

	-- An unclaimed plot shows a bare pad and a claim marker, nothing else.
	-- Leaving the vault and belt standing on an empty plot is what makes it
	-- look like there's a big block parked in front of the thing you're
	-- meant to walk onto.
	self:setFactoryVisible(false)
	self:updateSign()

	table.insert(INSTANCES, self)
	return self
end

--- Listener for "what this plot owns has changed" — a purchase, a claim, a
--- release, a rebirth. FloorService hangs the mezzanine off this rather than
--- polling every plot on a timer. One listener, because there is exactly one
--- consumer; make it a list the day there are two.
--- A LIST, as the comment here has been asking for. It was one slot with
--- "make it a list the day there are two" written over it, and FloorService
--- held it. There are two now.
function Tycoon:onOwnedChanged(fn: ((any) -> ())?)
	if fn then
		table.insert(self.ownedChangedListeners, fn)
	end
end

function Tycoon:fireOwnedChanged()
	for _, fn in ipairs(self.ownedChangedListeners) do
		-- pcall'd per listener: one that throws must take neither the purchase
		-- nor the listeners after it down with it
		local ok, err = pcall(fn, self)
		if not ok then
			warn("[Tung] owned-changed listener error on plot " .. self.index .. ": " .. tostring(err))
		end
	end
end

--- Buy buttons are built on first claim, not at server start: every plot x 21
--- buttons is a lot of instances to create just to immediately hide them.
function Tycoon:ensureButtons()
	if self.buttonsBuilt then
		return
	end
	self.buttonsBuilt = true
	self:buildButtons()
end

--- Adds a folder to the set that appears and disappears with the factory.
---
--- Registration rather than a literal list, because setFactoryVisible used to
--- walk `for i = 1, 4` over one: the fifth folder anyone added was silently
--- left standing on an unclaimed plot, which is the exact bug the hidden
--- factory exists to prevent. A folder registered while the factory is hidden
--- is hidden immediately, so late arrivals (an upper floor) can't leak either.
function Tycoon:registerFactoryFolder(folder: Instance)
	table.insert(self.factoryFolders, folder)
	if not self.factoryShown then
		folder.Parent = nil
	end
end

--- Shows/hides the whole factory. Machinery lives in folders so this is a
--- reparent rather than a rebuild.
function Tycoon:setFactoryVisible(visible: boolean)
	self.factoryShown = visible
	local target = visible and self.model or nil
	for _, folder in ipairs(self.factoryFolders) do
		folder.Parent = target
	end
end

function Tycoon:at(x: number, y: number, z: number): CFrame
	return self.cf * CFrame.new(x, y, z)
end

--- Where the owner is placed on claim and on every respawn: just inside the
--- gateway, on the open aisle, looking down plot-local -Z. A CFrame looks
--- along its own -Z by default, so with no rotation you land facing the length
--- of the factory with the belt on your left and the buy buttons ahead of you.
function Tycoon:ownerSpawnCFrame(): CFrame
	local spot = L.OwnerSpawnAt
	return self:at(spot.X, spot.Y, spot.Z)
end

return Tycoon
