--[[
	instance.lua — a minimal Instance tree and Signal.

	Enough to satisfy Net.lua (a Folder of RemoteEvents in ReplicatedStorage),
	Economy.setupLeaderstats (a Folder holding an IntValue), and the character
	rig SessionService's activity sampler reads. Deliberately NOT enough for
	BaseParts, CFrames or physics — see SERVER_MODULES in tools/test.py for why
	that line is drawn where it is.

	The RemoteEvent matters more than it looks. Because it records what was
	fired and can be fired AT, a spec can push a RequestClaim through the real
	OnServerEvent handler rather than calling the private claimDaily directly —
	so the flood guard, the payload validation and the state re-push are all
	part of what is under test, which is the whole point.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end

function Signal:Connect(fn)
	table.insert(self.handlers, fn)
	local connection = {
		Connected = true,
	}
	function connection:Disconnect()
		self.Connected = false
		for index, handler in ipairs(self.handlers or {}) do
			if handler == fn then
				table.remove(self.handlers, index)
				break
			end
		end
	end
	connection.handlers = self.handlers
	return connection
end

--- Errors raised by a connected handler. Roblox swallows these; the harness
--- collects them so a spec can assert on them rather than losing them.
Signal.errors = {}

function Signal:Fire(...)
	-- iterate a copy: a handler may disconnect during dispatch
	for _, fn in ipairs(table.clone(self.handlers)) do
		local ok, err = pcall(fn, ...)
		if not ok then
			table.insert(Signal.errors, err)
		end
	end
end

local Instance = {}

local Inst = {}
Inst.__index = Inst

function Inst:GetChildren()
	return table.clone(self._children)
end

function Inst:FindFirstChild(name: string)
	for _, child in ipairs(self._children) do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function Inst:FindFirstChildOfClass(class: string)
	for _, child in ipairs(self._children) do
		if child.ClassName == class then
			return child
		end
	end
	return nil
end

function Inst:FindFirstChildWhichIsA(class: string)
	return self:FindFirstChildOfClass(class)
end

--- Instant. The tree is built synchronously in the harness, so there is
--- nothing to wait for; returning nil after a timeout would only ever mean a
--- genuine wiring bug, which is what the spec wants to see.
function Inst:WaitForChild(name: string, _timeout: number?)
	return self:FindFirstChild(name)
end

function Inst:IsA(class: string): boolean
	return self.ClassName == class
end

function Inst:Destroy()
	self.Parent = nil
	self._children = {}
end

function Inst:ClearAllChildren()
	for _, child in ipairs(table.clone(self._children)) do
		child.Parent = nil
	end
end

function Inst:GetAttribute(name: string)
	return self._attributes[name]
end

function Inst:SetAttribute(name: string, value)
	self._attributes[name] = value
end

function Inst:GetPropertyChangedSignal(_name: string)
	return Signal.new()
end

local function detach(inst)
	local parent = rawget(inst, "_parent")
	if not parent then
		return
	end
	for index, child in ipairs(parent._children) do
		if child == inst then
			table.remove(parent._children, index)
			break
		end
	end
end

local proxy = {
	__index = function(self, key)
		if key == "Parent" then
			return rawget(self, "_parent")
		end
		local method = Inst[key]
		if method then
			return method
		end
		return rawget(self, "_props") and self._props[key] or nil
	end,
	__newindex = function(self, key, value)
		if key == "Parent" then
			detach(self)
			rawset(self, "_parent", value)
			if value then
				table.insert(value._children, self)
			end
			return
		end
		self._props[key] = value
	end,
}

function Instance.new(className: string, parent)
	local inst = setmetatable({
		_children = {},
		_parent = nil,
		_props = {},
		_attributes = {},
		ClassName = className,
		Name = className,
	}, proxy)

	if className == "RemoteEvent" then
		local fired = {}
		inst._props.__fired = fired
		inst._props.OnServerEvent = Signal.new()
		inst._props.FireClient = function(_self, player, ...)
			table.insert(fired, { player = player, args = table.pack(...) })
		end
		inst._props.FireAllClients = function(_self, ...)
			table.insert(fired, { player = "all", args = table.pack(...) })
		end
	elseif className == "IntValue" or className == "NumberValue" then
		inst._props.Value = 0
	elseif className == "StringValue" or className == "ObjectValue" then
		inst._props.Value = nil
	end

	if parent then
		inst.Parent = parent
	end
	return inst
end

Instance.Signal = Signal
return Instance
