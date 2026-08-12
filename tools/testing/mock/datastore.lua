--[[
	datastore.lua — DataStoreService with fault injection and honest semantics.

	Two behaviours here are non-negotiable, and both exist because getting them
	wrong makes every persistence spec a tautology that passes forever:

	1. DEEP COPY ON EVERY READ AND EVERY WRITE. Real DataStores serialize. If
	   the mock stored `profile.owned` by reference, a spec that saved, mutated
	   cash and reloaded would find its mutation already "saved" — and the
	   save/load round-trip spec would prove nothing at all.

	2. A SERIALIZER THAT REJECTS WHAT ROBLOX REJECTS. Functions, threads,
	   cycles, mixed array/dictionary tables, NaN and infinity. This is free to
	   implement and it covers a real hole: profile.sessions is a free-form
	   sub-table that reconcile() type-checks only at the top level.
]]

local DataStoreService = {}

local function isArray(t): boolean
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n == #t
end

--- Deep copy, and validate as we go. Returns the copy, or errors the way the
--- real service does.
local function serialize(value, seen, path: string)
	seen = seen or {}
	path = path or "root"
	local kind = type(value)

	if kind == "number" then
		if value ~= value then
			error(("cannot store NaN at %s"):format(path), 0)
		end
		if value == math.huge or value == -math.huge then
			error(("cannot store infinity at %s"):format(path), 0)
		end
		return value
	elseif kind == "string" or kind == "boolean" or kind == "nil" then
		return value
	elseif kind ~= "table" then
		error(("cannot store a %s at %s"):format(kind, path), 0)
	end

	if seen[value] then
		error(("cyclic table at %s"):format(path), 0)
	end
	seen[value] = true

	local out = {}
	local array = isArray(value)
	for k, v in pairs(value) do
		local keyKind = type(k)
		if array then
			if keyKind ~= "number" then
				error(("mixed array and dictionary keys at %s"):format(path), 0)
			end
		else
			if keyKind ~= "string" then
				error(("non-string dictionary key (%s) at %s"):format(keyKind, path), 0)
			end
			if #k > 50 then
				error(("key longer than 50 characters at %s"):format(path), 0)
			end
		end
		out[k] = serialize(v, seen, path .. "." .. tostring(k))
	end
	seen[value] = nil
	return out
end

local Store = {}
Store.__index = Store

function Store.new(name: string, clockRef)
	return setmetatable({
		name = name,
		data = {},
		calls = {},       -- ordered { method, key, atEpoch, ok }
		faults = {},      -- method -> { times, error }
		latencySeconds = 0,
		clockRef = clockRef,
		--- Set by a spec to make UpdateAsync run its transform TWICE for one
		--- call. Real UpdateAsync re-runs the transform when it loses an
		--- internal conflict, and a transform that accumulates instead of
		--- assigning is a bug that only shows up under exactly that.
		reentrant = false,
	}, Store)
end

function Store:_clock()
	return self.clockRef and self.clockRef() or nil
end

function Store:_wait()
	local clock = self:_clock()
	if self.latencySeconds > 0 and clock then
		-- consumed through the clock, so retry()'s 0.6*i backoff is measurable
		task.wait(self.latencySeconds)
	end
end

function Store:_log(method: string, key: string, ok: boolean)
	local clock = self:_clock()
	table.insert(self.calls, {
		method = method,
		key = key,
		atEpoch = clock and clock:time() or 0,
		atMono = clock and clock:clockTime() or 0,
		ok = ok,
	})
end

function Store:_fault(method: string)
	local fault = self.faults[method]
	if not fault then
		return nil
	end
	if fault.times and fault.times <= 0 then
		return nil
	end
	if fault.times then
		fault.times -= 1
	end
	return fault.error or ("502: API Services rejected request for %s"):format(method)
end

-- ── the API under test ──────────────────────────────────────────────────────

function Store:GetAsync(key: string)
	self:_wait()
	local fault = self:_fault("GetAsync")
	if fault then
		self:_log("GetAsync", key, false)
		error(fault, 0)
	end
	self:_log("GetAsync", key, true)
	local stored = self.data[key]
	return stored ~= nil and serialize(stored) or nil
end

function Store:SetAsync(key: string, value)
	self:_wait()
	local fault = self:_fault("SetAsync")
	if fault then
		self:_log("SetAsync", key, false)
		error(fault, 0)
	end
	self.data[key] = serialize(value)
	self:_log("SetAsync", key, true)
	return value
end

function Store:UpdateAsync(key: string, transform)
	self:_wait()
	local fault = self:_fault("UpdateAsync")
	if fault then
		self:_log("UpdateAsync", key, false)
		error(fault, 0)
	end

	local stored = self.data[key]
	local result = transform(stored ~= nil and serialize(stored) or nil)
	if self.reentrant then
		-- second run, from the ORIGINAL stored value: this is what a real
		-- conflict retry looks like, and a transform that mutates captured
		-- state instead of assigning will diverge here.
		result = transform(stored ~= nil and serialize(stored) or nil)
	end

	-- nil aborts the write. Session locking depends on this.
	if result == nil then
		self:_log("UpdateAsync", key, true)
		return nil
	end

	self.data[key] = serialize(result)
	self:_log("UpdateAsync", key, true)
	return result
end

function Store:RemoveAsync(key: string)
	self:_wait()
	local old = self.data[key]
	self.data[key] = nil
	self:_log("RemoveAsync", key, true)
	return old
end

-- ── spec-facing controls ────────────────────────────────────────────────────

function Store:seed(key: string, value)
	self.data[key] = serialize(value)
end

--- Read the blob WITHOUT going through the API — the only way to assert on a
--- lock field the game code deliberately never surfaces.
function Store:raw(key: string)
	local stored = self.data[key]
	return stored ~= nil and serialize(stored) or nil
end

function Store:fail(method: string, opts)
	opts = opts or {}
	self.faults[method] = { times = opts.times, error = opts.error }
end

function Store:failNext(method: string)
	self:fail(method, { times = 1 })
end

function Store:clearFaults()
	self.faults = {}
end

function Store:latency(seconds: number)
	self.latencySeconds = seconds
end

function Store:countCalls(method: string, key: string?): number
	local n = 0
	for _, call in ipairs(self.calls) do
		if call.method == method and (key == nil or call.key == key) then
			n += 1
		end
	end
	return n
end

-- ── the service ─────────────────────────────────────────────────────────────

function DataStoreService.new(clockRef)
	local service = {
		stores = {},
		fail = false,   -- set true to model Studio with API access off
		clockRef = clockRef,
	}

	function service:GetDataStore(name: string)
		if self.fail then
			error("DataStoreService: API access is not enabled", 0)
		end
		local existing = self.stores[name]
		if existing then
			return existing
		end
		local store = Store.new(name, self.clockRef)
		self.stores[name] = store
		return store
	end

	return service
end

return DataStoreService
