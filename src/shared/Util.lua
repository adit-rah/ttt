--[[ Util.lua — small helpers shared by client and server. ]]

local Util = {}

local SUFFIXES = {
	"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No",
	"Dc", "UDc", "DDc", "TDc", "QaDc", "QiDc", "SxDc", "SpDc", "OcDc", "NoDc", "Vg",
}

--- 1234567 -> "1.23M"
function Util.abbreviate(n: number): string
	if n ~= n then return "0" end            -- NaN guard
	local sign = n < 0 and "-" or ""
	n = math.abs(n)
	if n < 1000 then
		return sign .. tostring(math.floor(n + 0.5))
	end
	local index = math.floor(math.log(n, 1000))
	index = math.clamp(index, 1, #SUFFIXES - 1)
	local scaled = n / (1000 ^ index)
	local text
	if scaled >= 100 then
		text = string.format("%.0f", scaled)
	elseif scaled >= 10 then
		text = string.format("%.1f", scaled)
	else
		text = string.format("%.2f", scaled)
	end
	-- Trim trailing zeros, but ONLY past a decimal point. Trimming
	-- unconditionally turns "320" into "32", i.e. 320K displays as 32K.
	if text:find("%.") then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end
	return sign .. text .. SUFFIXES[index + 1]
end

--- 1234567 -> "1,234,567"
function Util.comma(n: number): string
	local whole = string.format("%.0f", math.abs(n))
	local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return (n < 0 and "-" or "") .. out
end

function Util.weld(a: BasePart, b: BasePart, name: string?): WeldConstraint
	local weld = Instance.new("WeldConstraint")
	weld.Name = name or "TungWeld"
	weld.Part0 = a
	weld.Part1 = b
	weld.Parent = a
	return weld
end

--- Welds every descendant BasePart of `model` to `root` and anchors nothing.
function Util.weldModel(model: Model, root: BasePart)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= root then
			part.Anchored = false
			Util.weld(root, part)
		end
	end
end

function Util.setCollision(model: Instance, group: string)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = group
		end
	end
	if model:IsA("BasePart") then
		model.CollisionGroup = group
	end
end

function Util.newPart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(part :: any)[key] = value
		end
	end
	if props.Parent then
		part.Parent = props.Parent
	end
	return part
end

function Util.roundedFrame(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

function Util.shallowCopy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

function Util.count(t): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

--- Deterministic-ish pseudo random from a string seed (used for plot flavour).
function Util.hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 2147483647
	end
	return h
end

function Util.lerpColor(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

--- Safely reads a character's humanoid + root, or nil.
function Util.getRig(model: Instance?): (Humanoid?, BasePart?)
	if not model or not model:IsA("Model") then
		return nil, nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

return Util
