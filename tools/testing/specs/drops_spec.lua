--[[
	drops_spec.lua — the drop pool's bookkeeping.

	spawnDrop itself needs constraints, CFrame arithmetic and
	PhysicalProperties, none of which the mock world claims to have — the
	pooled body's rig retarget and the ride-token reaper are Studio items,
	named in the handoff. What runs here is the bookkeeping around it: the
	budget slot coming back exactly once, the shelf keyed by variant, and the
	pool dying with the tenancy.
]]

return function(T)

T.family("drops", "a retired drop returns its slot once and its body to the right shelf")

local function fakePlot(w, dropCount)
	local Tycoon = w.req("Tycoon")
	local plot = setmetatable({}, { __index = Tycoon })
	plot.dropPool = {}
	plot.dropCount = dropCount or 0
	plot.drops = Instance.new("Folder")
	return plot
end

local function fakeDrop(w, variant)
	local drop = Instance.new("Model")
	drop.Name = "Drop"
	drop:SetAttribute("Variant", variant)
	return drop
end

T.spec("recycling shelves the body under its variant and frees one slot", function(t)
	local w = T.world()
	local plot = fakePlot(w, 3)
	local drop = fakeDrop(w, "classic")
	drop.Parent = plot.drops

	plot:recycleDrop(drop)

	t:eq(plot.dropCount, 2, "the budget slot did not come back")
	t:eq(drop.Parent, nil, "a recycled drop is still on the belt")
	t:eq(#plot.dropPool.classic, 1, "the body is not on its variant's shelf")
end)

T.spec("a drop can only be recycled once", function(t)
	-- The collector claims and recycles; the reaper may still hold the same
	-- body. The Parent check is what stops the second caller freeing a slot
	-- the first already freed and shelving the body twice.
	local w = T.world()
	local plot = fakePlot(w, 3)
	local drop = fakeDrop(w, "golden")
	drop.Parent = plot.drops

	plot:recycleDrop(drop)
	plot:recycleDrop(drop)

	t:eq(plot.dropCount, 2, "the second recycle freed a slot the first already freed")
	t:eq(#plot.dropPool.golden, 1, "the same body is shelved twice")
end)

T.spec("clearDrops takes the pool down with the live drops", function(t)
	-- release() hands the plot to an owner whose factory drops different
	-- variants; a shelved body surviving the handover is a leak wearing the
	-- last tenant's colours.
	local w = T.world()
	local plot = fakePlot(w, 2)
	local live = fakeDrop(w, "classic")
	live.Parent = plot.drops
	local shelved = fakeDrop(w, "void")
	shelved.Parent = plot.drops
	plot:recycleDrop(shelved)
	t:eq(#plot.dropPool.void, 1, "the fixture never shelved anything")

	plot:clearDrops()

	t:eq(plot.dropCount, 0, "the budget did not reset")
	t:eq(next(plot.dropPool), nil, "the pool survived the tenancy it belonged to")
end)

end
