--!strict
--[[
	Req.lua — tiny module locator.

	Every module in this project imports its siblings through this, e.g.

		local Config = Req("Config")

	Why not plain `require(script.Parent.Config)`? Because it makes the source
	tree position-independent, which lets `tools/pack.py` flatten the whole
	project into a single paste-in Script for people who don't use Rojo.

	Search order: TungShared -> TungServer (server only) -> TungClient (client only)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local roots: { Instance } = {}
local cache: { [string]: any } = {}
local resolving: { [string]: boolean } = {}

local shared = ReplicatedStorage:WaitForChild("TungShared", 30)
if shared then
	table.insert(roots, shared)
end

if RunService:IsServer() then
	local ServerScriptService = game:GetService("ServerScriptService")
	local serverRoot = ServerScriptService:FindFirstChild("TungServer")
	if serverRoot then
		table.insert(roots, serverRoot)
	end
else
	local Players = game:GetService("Players")
	local lp = Players.LocalPlayer
	if lp then
		local scripts = lp:FindFirstChild("PlayerScripts")
		if scripts then
			local clientRoot = scripts:FindFirstChild("TungClient")
			if clientRoot then
				table.insert(roots, clientRoot)
			end
		end
	end
end

local function find(name: string): ModuleScript?
	for _, root in ipairs(roots) do
		local direct = root:FindFirstChild(name)
		if direct and direct:IsA("ModuleScript") then
			return direct
		end
		-- allow one level of nesting so folders can be used for organisation
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("Folder") then
				local nested = child:FindFirstChild(name)
				if nested and nested:IsA("ModuleScript") then
					return nested
				end
			end
		end
	end
	return nil
end

local function Req(name: string): any
	local hit = cache[name]
	if hit ~= nil then
		return hit
	end
	if resolving[name] then
		error(("[Tung] circular dependency while loading %q"):format(name), 2)
	end

	local moduleScript = find(name)
	if not moduleScript then
		error(("[Tung] module %q not found. Is the Rojo tree synced?"):format(name), 2)
	end

	resolving[name] = true
	local ok, result = pcall(require, moduleScript)
	resolving[name] = nil

	if not ok then
		error(("[Tung] module %q failed to load: %s"):format(name, tostring(result)), 2)
	end

	cache[name] = result
	return result
end

return Req
