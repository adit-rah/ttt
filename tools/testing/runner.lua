--[[
	runner.lua — spec registry, assertions and the report.

	Modelled on tools/verify_config.lua deliberately: accumulate rather than
	abort, count the checks, print families, list every failure at the end. A
	suite that stops at the first failure tells you one thing per run; this
	repo's verifier tells you all of them, and the specs should not be a
	different experience.
]]

local T = {}

T.families = {}
T.current = nil
T.checks = 0
T.failures = {}
T.pendingFailures = {}
T.specCount = 0
T.plain = false

local function colour(code: string, text: string): string
	if T.plain then
		return text
	end
	return ("\27[%sm%s\27[0m"):format(code, text)
end

-- ── registry ────────────────────────────────────────────────────────────────

function T.family(name: string, blurb: string?)
	T.current = { name = name, blurb = blurb, specs = {} }
	table.insert(T.families, T.current)
end

--- Declare the current family as a KNOWN failure with a stated reason.
---
--- Its failures are reported in full and loudly, but they do not fail the
--- build. This exists for exactly one situation: a spec that documents a bug
--- whose fix is owned by someone else, landing before the fix does. The
--- alternative is to not write the spec until the fix is ready, which is how a
--- defect ends up with no test at all.
---
--- A pending family is a debt, not a decision. `reason` must name who closes it
--- and the report keeps shouting until they do.
function T.pending(reason: string)
	assert(T.current, "T.pending called before T.family")
	T.current.pending = reason
end

function T.spec(name: string, fn)
	assert(T.current, "T.spec called before T.family")
	table.insert(T.current.specs, { name = name, fn = fn })
end

--- Load a spec module, handing it the harness. Specs are modules in the
--- bundle, so they receive `T` by calling the factory the runner passes.
function T.load(name: string, req)
	local module = req(name)
	if type(module) == "function" then
		module(T)
	end
end

-- ── assertions ──────────────────────────────────────────────────────────────

local Case = {}
Case.__index = Case

local function fail(case, message: string, detail: string?)
	local record = {
		family = case.family,
		spec = case.spec,
		message = message,
		detail = detail,
		pending = case.pending,
	}
	table.insert(case.pending and T.pendingFailures or T.failures, record)
	case.failed += 1
end

local function describe(value): string
	if type(value) == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then
			return ("%d"):format(value)
		end
		return ("%.6g"):format(value)
	elseif type(value) == "string" then
		return ("%q"):format(value)
	elseif type(value) == "table" then
		return "<table>"
	end
	return tostring(value)
end

function Case:count()
	T.checks += 1
	self.checks += 1
end

function Case:eq(actual, expected, message: string?)
	self:count()
	if actual ~= expected then
		fail(self, message or "values differ",
			("got %s, want %s"):format(describe(actual), describe(expected)))
	end
end

function Case:ne(actual, unexpected, message: string?)
	self:count()
	if actual == unexpected then
		fail(self, message or "value should have changed",
			("both are %s"):format(describe(actual)))
	end
end

function Case:near(actual, expected, epsilon: number?, message: string?)
	self:count()
	epsilon = epsilon or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > epsilon then
		fail(self, message or "values differ beyond tolerance",
			("got %s, want %s +/- %s"):format(describe(actual), describe(expected), describe(epsilon)))
	end
end

function Case:isTrue(value, message: string?)
	self:count()
	if value ~= true then
		fail(self, message or "expected true", ("got %s"):format(describe(value)))
	end
end

function Case:isFalse(value, message: string?)
	self:count()
	if value ~= false then
		fail(self, message or "expected false", ("got %s"):format(describe(value)))
	end
end

function Case:isNil(value, message: string?)
	self:count()
	if value ~= nil then
		fail(self, message or "expected nil", ("got %s"):format(describe(value)))
	end
end

function Case:notNil(value, message: string?)
	self:count()
	if value == nil then
		fail(self, message or "expected a value, got nil")
	end
end

function Case:gt(actual, bound, message: string?)
	self:count()
	if not (type(actual) == "number" and actual > bound) then
		fail(self, message or "expected greater",
			("got %s, want > %s"):format(describe(actual), describe(bound)))
	end
end

function Case:gte(actual, bound, message: string?)
	self:count()
	if not (type(actual) == "number" and actual >= bound) then
		fail(self, message or "expected at least",
			("got %s, want >= %s"):format(describe(actual), describe(bound)))
	end
end

function Case:lt(actual, bound, message: string?)
	self:count()
	if not (type(actual) == "number" and actual < bound) then
		fail(self, message or "expected less",
			("got %s, want < %s"):format(describe(actual), describe(bound)))
	end
end

function Case:contains(container, key, message: string?)
	self:count()
	if type(container) ~= "table" or container[key] == nil then
		fail(self, message or ("expected key %s"):format(describe(key)))
	end
end

function Case:calls(store, method: string, expected: number, message: string?)
	self:count()
	local actual = store:countCalls(method)
	if actual ~= expected then
		fail(self, message or ("expected %d %s call(s)"):format(expected, method),
			("got %d"):format(actual))
	end
end

--- The world these two read. Found independently by the session-locking and
--- the social work within an hour of each other, which is the cheapest way
--- dead-on-arrival API ever gets found.
---
--- `self.world` is honoured if a spec set one — a
--- spec that builds several worlds has to say which — and otherwise it is the
--- most recently built one, which is the world every single-world spec means.
--- Without the fallback both assertions indexed nil and the first spec to use
--- either of them failed as a harness error rather than as a game failure.
local function worldOf(case): any
	return case.world or T.worldRef
end

function Case:warned(pattern: string, message: string?)
	self:count()
	local world = worldOf(self)
	for _, line in ipairs(world.warnings) do
		if string.find(line, pattern) then
			return
		end
	end
	fail(self, message or ("expected a warning matching %q"):format(pattern),
		("%d warning(s) seen"):format(#world.warnings))
end

function Case:fired(remoteName: string, expected: number?, message: string?)
	self:count()
	local folder = worldOf(self).replicatedStorage:FindFirstChild("TungNet")
	local remote = folder and folder:FindFirstChild(remoteName)
	if not remote then
		fail(self, message or ("no remote named %s"):format(remoteName))
		return
	end
	local n = #remote.__fired
	if expected and n ~= expected then
		fail(self, message or ("expected %d fire(s) of %s"):format(expected, remoteName),
			("got %d"):format(n))
	elseif not expected and n == 0 then
		fail(self, message or ("expected %s to fire"):format(remoteName))
	end
end

function Case:raises(fn, pattern: string?, message: string?)
	self:count()
	local ok, err = pcall(fn)
	if ok then
		fail(self, message or "expected an error, none raised")
	elseif pattern and not string.find(tostring(err), pattern) then
		fail(self, message or ("error did not match %q"):format(pattern),
			tostring(err))
	end
end

-- ── running ─────────────────────────────────────────────────────────────────

function T.run()
	for _, family in ipairs(T.families) do
		for _, spec in ipairs(family.specs) do
			T.specCount += 1
			local case = setmetatable({
				family = family.name,
				spec = spec.name,
				checks = 0,
				failed = 0,
			}, Case)
			spec.case = case

			case.pending = family.pending

			local ok, err = xpcall(function()
				spec.fn(case)
			end, function(err)
				return tostring(err) .. "\n" .. debug.traceback("", 2)
			end)

			if not ok then
				fail(case, "spec raised", tostring(err))
			end

			-- A thread that died inside the scheduler is not visible to the
			-- spec body — task.spawn swallows it the way Roblox does. Surface
			-- it, or a broken autosave loop reads as a passing spec.
			local world = T.worldRef
			if world and world.clock and world.clock.lastError then
				fail(case, "a scheduled thread errored", tostring(world.clock.lastError))
				world.clock.lastError = nil
			end
		end
	end
end

function T.report()
	T.run()

	local totalAdvanced, totalResumes = 0, 0
	for _, world in ipairs(T.worlds or {}) do
		totalAdvanced += world.clock.advanced
		totalResumes += world.clock.resumes
	end

	for _, family in ipairs(T.families) do
		print(("\n%s specs: %s%s"):format(
			colour("2", "──"), family.name,
			family.blurb and colour("2", "  — " .. family.blurb) or ""))
		if family.pending then
			print(("  %s %s"):format(colour("33", "PENDING"), family.pending))
		end
		for _, spec in ipairs(family.specs) do
			local case = spec.case
			local checks = case and case.checks or 0
			if case and case.failed > 0 then
				print(("  %s  %-58s %d of %d"):format(
					colour(family.pending and "33" or "31", family.pending and "todo" or "FAIL"),
					spec.name, checks - case.failed, checks))
			else
				print(("  %s    %-58s %d checks"):format(
					colour("32", "ok"), spec.name, checks))
			end
		end
	end

	print("")
	print(("specs run:         %d  in %d families"):format(T.specCount, #T.families))
	print(("checks run:        %d"):format(T.checks))
	print(("fake time:         %.1fh advanced, %d scheduler resumes"):format(
		totalAdvanced / 3600, totalResumes))
	if T.executed then
		print(("modules executed:  %s"):format(table.concat(T.executed, " ")))
	end

	local function dump(list, heading: string, code: string)
		print("\n" .. colour(code, heading))
		for _, failure in ipairs(list) do
			print(("  ! %s / %s"):format(failure.family, failure.spec))
			print(("      %s"):format(failure.message))
			if failure.detail then
				for line in tostring(failure.detail):gmatch("[^\n]+") do
					print(("      %s"):format(line))
				end
			end
		end
	end

	-- A pending family is reported in full and loudly, and does NOT fail the
	-- build. It is a debt with a named owner, not a decision.
	if #T.pendingFailures > 0 then
		dump(T.pendingFailures, "KNOWN FAILURES (pending, not blocking):", "33")
	end

	if #T.failures > 0 then
		dump(T.failures, "FAILURES:", "31")
		error(("%d spec check(s) failed"):format(#T.failures), 0)
	end
end

return T
