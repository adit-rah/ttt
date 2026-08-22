--[[
	movement_spec.lua — sprint and dash, the server's half (#101).

	The impulse itself is client physics and a Studio item; what runs here is
	the ledger: the sprint toggle writing exactly two speeds, the dash
	cooldown refusing early requests, and the respawn reset. The clock is a
	parameter so the spec drives it.
]]

return function(T)

T.family("movement", "sprint is one bit, the dash cooldown is the server's")

T.spec("sprint writes exactly two speeds, and nothing the client picks", function(t)
	local w = T.world()
	local Config = w.config
	local Movement = w.req("MovementService")
	local player = w.join("runner")
	w.spawnCharacter(player)
	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")

	Movement.setSprint(player, true)
	t:eq(humanoid.WalkSpeed, Config.Movement.SprintSpeed, "sprint did not reach the humanoid")
	Movement.setSprint(player, false)
	t:eq(humanoid.WalkSpeed, Config.Combat.WalkSpeed, "releasing sprint did not restore the walk")

	-- a truthy-but-weird payload is still just a bit
	Movement.setSprint(player, "yes plus 900 speed")
	t:eq(humanoid.WalkSpeed, Config.Combat.WalkSpeed,
		"a non-boolean payload toggled sprint — the remote carries one bit and nothing else")
end)

T.spec("the dash cooldown refuses early requests and recovers exactly", function(t)
	local w = T.world()
	local Config = w.config
	local Movement = w.req("MovementService")
	local player = w.join("dodger")

	t:isTrue(Movement.tryDash(player, 100), "the first dash was refused")
	t:isFalse(Movement.tryDash(player, 100 + Config.Movement.DashCooldown - 0.01),
		"a dash inside the cooldown was approved")
	t:isTrue(Movement.tryDash(player, 100 + Config.Movement.DashCooldown),
		"a dash exactly at the cooldown was refused")
	t:isFalse(Movement.dashReady(player, 100 + Config.Movement.DashCooldown + 0.1),
		"dashReady disagrees with the stamp tryDash just wrote")
end)

end
