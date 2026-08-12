--[[
	Net.lua — lazily creates and hands out the project's RemoteEvents.

	Server calls Net.event("Name") and it is created on demand.
	Client calls Net.event("Name") and it waits for it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

local FOLDER_NAME = "TungNet"

local folder: Folder
if RunService:IsServer() then
	folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
else
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30) :: Folder
end

-- Every remote the game uses. Declared up front so the client never races.
Net.NAMES = {
	"Notify",        -- S->C  { kind, title, body, color }
	"Stats",         -- S->C  { cash, rebirths, kills, batTier, armorTier, multiplier, owned, rebirthCost }
	"PlotAssigned",  -- S->C  plotIndex
	"Purchased",     -- S->C  { id, name, price }
	"WaveState",     -- S->C  { phase, wave, remaining, seconds }
	"SwingFx",       -- S->C  { character, combo, duration } — play a swing on that rig
	"HitFeedback",   -- S->C  { damage, crit, killed, position }
	"Knockback",     -- S->C  impulse Vector3, applied by the owning client
	"RequestRebirth",-- C->S
	"RequestReset",  -- C->S  (leave plot)
	"Sfx",           -- S->C  { name, position }

	-- PROTOTYPES (see Config.Prototypes). Declared here rather than created on
	-- demand so a client that connects with a flag off still resolves them and
	-- never sits in WaitForChild for 30 seconds.
	"UpgradeState",   -- S->C  { levels = {id = level}, costs = {id = price} }
	"RequestUpgrade", -- C->S  upgrade id
	"UseUtility",     -- C->S  (fire the equipped utility)
	"SessionState",   -- S->C  { daily, playtime, boost, offline }
	"RequestClaim",   -- C->S  { kind = "daily" | "playtime" | "offline", index }
	"RequestBoost",   -- C->S
	"FloorState",     -- S->C  { unlocked = boolean }
}

if RunService:IsServer() then
	for _, name in ipairs(Net.NAMES) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
end

local cache: { [string]: RemoteEvent } = {}

function Net.event(name: string): RemoteEvent
	local hit = cache[name]
	if hit then
		return hit
	end
	local remote
	if RunService:IsServer() then
		remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	else
		remote = folder:WaitForChild(name, 30)
		if not remote then
			error(("[Tung] remote %q never replicated"):format(name))
		end
	end
	cache[name] = remote
	return remote
end

return Net
