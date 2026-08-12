--[[
	Util.lua — the leaf. Thirteen small helpers, required by fifteen files
	across both sides of the game.

	IT REQUIRES NOTHING, and that is a contract rather than an accident. There is
	no `Req` line and no service lookup anywhere below, so any module can require
	Util without thinking about the require graph, and the spec harness can load it
	with no mock standing behind it. Adding `Req("Config")` here would hand all
	fifteen of those files a new edge, and Req refuses a circular require at
	RUNTIME — a cycle introduced here does not fail the build, it fails the boot.

	IT IS COMPILED INTO BOTH PASTE BUILDS. tools/pack.py builds the server script
	from [src/shared, src/server] and the client one from [src/shared, src/client],
	so everything in src/shared ships to both. Nothing that only one side is
	allowed to do belongs here — src/client/UiKit.lua lives on the client for
	precisely this reason, and its header explains the failure.

	WHAT IS LOAD-BEARING, out of the thirteen:

	  abbreviate    the game's money formatter — fifty-odd call sites, and
	                Economy.format is an alias for it. Its trailing-zero trim is
	                gated on the text containing a decimal point: an
	                unconditional trim turned "320" into "32", so 320K rendered
	                as 32K. That guard is the whole function's history.
	  platformFrom  every string it can return must also appear in
	                Config.Analytics.Fields.platform.values. It cannot read
	                Config to check (see above), so analytics_spec.lua checks it
	                instead, through the Analytics.platformFrom re-export — which
	                is why that alias exists and must not be deleted as
	                redundant. The ORDER of the tests inside it is the function.
	  getRig        the sanctioned way to read a character's Humanoid and root.
	                Twelve call sites, every one of which relies on the nil, nil
	                return rather than on a pcall.

	shallowCopy IS SHALLOW, and its one caller makes that matter: Tycoon:rebirth
	copies the kept-buttons set with it. A Config.ButtonById def is one table
	shared by every plot on the server, so copying a def rather than a set of ids
	would hand you nested tables that are still shared with every other plot.

	comma, count, hash, newPart, setCollision and weldModel have no caller in src/
	today. They are available; they are not proven.
]]

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

--- Device class from a bag of input flags. One of Config.Analytics.Fields
--- .platform.values, always.
---
--- HERE RATHER THAN IN Analytics.lua, and that is the one thing about this
--- function worth arguing over. Roblox has no server-side device API at all, so
--- the ladder has to RUN on the client — but Analytics.lua is deliberately
--- server-only (an analytics call from a client silently does nothing forever,
--- so the module must not be reachable from one). Written twice it would drift,
--- and the drift would be invisible: two ladders, both plausible, disagreeing
--- about tablets. So the pure part lives in the shared module that already
--- exists for exactly this, takes no Roblox types, and Analytics re-exports it
--- as `Analytics.platformFrom` so the specs pin the server's contract.
---
--- ORDER IS THE WHOLE FUNCTION. A VR headset and a console both report
--- TouchEnabled in some configurations, so a `TouchEnabled` test placed first
--- files every headset in the game under "mobile" — and the resulting chart
--- looks completely normal. VR and console are therefore asked first, and the
--- touch test additionally requires that there is no keyboard.
---
--- The tablet split is a viewport width because Roblox does not expose a device
--- class: 900px is where a phone in landscape stops and a tablet starts. It is a
--- judgement call and it is the only line here that is.
function Util.platformFrom(flags): string
	flags = flags or {}
	if flags.vr then
		return "vr"
	elseif flags.tenFoot then
		return "console"
	elseif flags.touch and not flags.keyboard then
		return (tonumber(flags.viewportX) or 0) >= 900 and "tablet" or "mobile"
	elseif flags.keyboard and flags.mouse then
		return "desktop"
	end
	return "unknown"
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
