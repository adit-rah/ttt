--[[
	clock.lua — a controllable clock and a cooperative scheduler.

	This is the core of the harness. Every retention feature in this game is
	time-based: an 8-hour offline accrual, a 48-hour streak grace, a 2400s boost
	cooldown, a 90s autosave, a 300s lock staleness. None of them are testable
	against a real clock, and all of them are trivially testable against this
	one.

	TWO TIME BASES, because src/ deliberately uses two.
	SessionService.lua's header commits to os.time() for anything PERSISTED
	(UTC epoch seconds, the same number on every machine) and os.clock() only
	for in-session monotonic durations. The clock honours that split, which is
	what makes `set()` below meaningful.
]]

local Clock = {}
Clock.__index = Clock

-- 2026-01-01T00:00:00Z. A Thursday, chosen deliberately: Config.Sessions
-- .WeekendDays is { [1] = Sun, [7] = Sat }, so the default seed must NOT be a
-- weekend or every income assertion in every spec silently doubles.
Clock.DEFAULT_EPOCH = 1767225600

-- A spec that spins forever should fail with a message, not hang a CI job.
local RESUME_BUDGET = 200000

function Clock.new(epoch: number?)
	return setmetatable({
		epoch = epoch or Clock.DEFAULT_EPOCH,
		mono = 0,
		timers = {},        -- { at = mono, thread | fn, repeats }
		resumes = 0,
		advanced = 0,
	}, Clock)
end

-- ── the time the code under test reads ──────────────────────────────────────

function Clock:time(): number
	return math.floor(self.epoch)
end

function Clock:clockTime(): number
	return self.mono
end

-- ── scheduling ──────────────────────────────────────────────────────────────

function Clock:_schedule(at: number, thread, fn)
	local timer = { at = at, thread = thread, fn = fn }
	table.insert(self.timers, timer)
	return timer
end

function Clock:_due(limit: number)
	--- The earliest pending timer at or before `limit`, or nil.
	local best, bestIndex = nil, nil
	for index, timer in ipairs(self.timers) do
		if not timer.cancelled and timer.at <= limit then
			if best == nil or timer.at < best.at then
				best, bestIndex = timer, index
			end
		end
	end
	return best, bestIndex
end

function Clock:_fire(timer, index: number)
	table.remove(self.timers, index)
	if timer.cancelled then
		return
	end
	self.resumes += 1
	if self.resumes > RESUME_BUDGET then
		error(("runaway loop: %d scheduler resumes in one spec — something is " ..
			"waiting 0 seconds in a while-true"):format(self.resumes), 0)
	end
	if timer.fn then
		local ok, err = pcall(timer.fn)
		if not ok then
			self.lastError = err
		end
	elseif timer.thread and coroutine.status(timer.thread) == "suspended" then
		local ok, err = coroutine.resume(timer.thread)
		if not ok then
			self.lastError = err
		end
	end
end

--- Run time forward, firing every timer in wake order.
---
--- Use this when the thing under test is SUPPOSED to be running — an autosave
--- beat, a session tick, a boost expiring while the player is online.
function Clock:advance(dt: number)
	local target = self.mono + dt
	self.advanced += dt
	while true do
		local timer, index = self:_due(target)
		if not timer then
			break
		end
		local step = timer.at - self.mono
		self.mono = timer.at
		self.epoch += step
		self:_fire(timer, index)
	end
	local remainder = target - self.mono
	self.mono = target
	self.epoch += remainder
end

--- Jump forward, COLLAPSING everything that would have fired into one firing
--- each.
---
--- This is the honest model for "the player was logged out for eight hours".
--- Nothing was running. Simulating 320 autosave ticks against an empty server
--- proves nothing and costs a third of a second, and it is why an 8h accrual
--- spec runs in microseconds.
function Clock:skip(dt: number)
	local target = self.mono + dt
	self.mono = target
	self.epoch += dt
	self.advanced += dt
	local fired = {}
	for index = #self.timers, 1, -1 do
		local timer = self.timers[index]
		if not timer.cancelled and timer.at <= target then
			table.insert(fired, { timer = timer, index = index })
		end
	end
	table.sort(fired, function(a, b)
		return a.timer.at < b.timer.at
	end)
	for _, entry in ipairs(fired) do
		for index, timer in ipairs(self.timers) do
			if timer == entry.timer then
				timer.at = self.mono
				self:_fire(timer, index)
				break
			end
		end
	end
end

--- Move the WALL CLOCK only, leaving the monotonic clock and every pending
--- timer where they are.
---
--- Two real uses, and they are the reason the two bases are separate:
---   * seeding a weekend or a New Year's Eve boundary;
---   * reproducing a clock that went BACKWARDS (host migration, an NTP
---     correction), which computeOffline explicitly defends against and which
---     no other tool in this repo can reach.
--- An NTP correction moves os.time() and not os.clock(), so this mirrors
--- reality rather than being a convenience.
function Clock:set(epoch: number)
	self.epoch = epoch
end

-- ── the `task` library, which the standalone luau CLI does not have ─────────

function Clock:taskLibrary()
	local clock = self

	local task = {}

	function task.spawn(fn, ...)
		-- Roblox resumes IMMEDIATELY, up to the first yield. DataService.start's
		-- `task.spawn(DataService.save, player, false)` depends on this.
		local thread = if type(fn) == "thread" then fn else coroutine.create(fn)
		clock.resumes += 1
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			clock.lastError = err
		end
		return thread
	end

	function task.wait(seconds: number?)
		local thread = coroutine.running()
		clock:_schedule(clock.mono + math.max(seconds or 0, 0), thread, nil)
		coroutine.yield()
		return seconds or 0
	end

	function task.delay(seconds: number?, fn, ...)
		local args = table.pack(...)
		local timer = clock:_schedule(clock.mono + math.max(seconds or 0, 0), nil, function()
			fn(table.unpack(args, 1, args.n))
		end)
		return timer
	end

	function task.defer(fn, ...)
		local args = table.pack(...)
		return clock:_schedule(clock.mono, nil, function()
			fn(table.unpack(args, 1, args.n))
		end)
	end

	function task.cancel(handle)
		if type(handle) == "table" then
			handle.cancelled = true
		else
			for _, timer in ipairs(clock.timers) do
				if timer.thread == handle then
					timer.cancelled = true
				end
			end
		end
	end

	return task
end

return Clock
