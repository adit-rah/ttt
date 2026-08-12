--[[
	vector3.lua — a Vector3 with actual arithmetic.

	tools/verify_config.lua gets away with `{ X = x, Y = y, Z = z }` because
	Config only ever reads the fields. The harness cannot: SessionService's
	sampleActivity computes

		(position - entry.lastPosition).Magnitude

	which is the whole activity gate the playtime ladder stands on. So this one
	needs __sub, __add, __mul and .Magnitude, and Config's 32 Vector3.new calls
	are covered by the same implementation for free.
]]

local Vector3 = {}
Vector3.__index = function(self, k)
	if k == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif k == "Unit" then
		local m = self.Magnitude
		if m == 0 then
			return Vector3.new(0, 0, 0)
		end
		return Vector3.new(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3, k)
end

Vector3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__mul = function(a, b)
	if type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(v)
	return ("%g, %g, %g"):format(v.X, v.Y, v.Z)
end

function Vector3.new(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)

return Vector3
