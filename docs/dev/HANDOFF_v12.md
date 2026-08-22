# HANDOFF v12 — income comes off the belt

design:D-02, via #93. Income is a rate computed from what the plot owns, paid
on a one-second tick. No part carries value. Drops are cosmetic, pooled and
recycled under `MaxDropsPerPlot` as a visual budget. The vault body is the
storage unit: health, a broken state, an owner-only repair prompt, and the
seams #94, #98 and #124 will call into.

The curve did not move: the progression simulation prints the same report to
the byte — 53-minute build, first rebirth at minute 42 with six rungs
unbought, the mezzanine at 67%. That was the acceptance test for the whole
round, and the mechanism is that the simulation now calls `Config.incomeRate`,
the same function the game pays with.

## 1. What moved where

| was | is |
| --- | --- |
| three hand-maintained income copies | `Config.incomeRate`, two one-line wrappers, and a sim that calls it raw |
| `Value` attribute on every drop, multiplied in flight, cashed at the vault | `Tycoon:startIncomeLoop` paying `rate × IncomeTickSeconds` through `Economy.add` |
| `refineryMultiplierFor` forcing reality to match the model | deleted — the model multiplies every floor by the whole stack, and reality is the model |
| a fresh Model with two constraints per drop, ~10/sec late game | per-variant pool; `recycleDrop` returns the slot, `spawnDrop` resets the ride |
| the generator-cancellation assertion family | deleted; occupancy and budget checks restated with the cosmetic cost they now protect |
| the vault as a pure collector | the storage unit: `tycoon/Storage.lua`, health/broken/repair, attributes as a replication mirror |

## 2. What only Studio can tell you

The mock world has no physics, no constraints, no CFrame arithmetic and no
replication, so every line below is unverified until someone stands in Studio
and looks. This list is meant to be answered, and belt speed took three rounds
to get answered last time.

1. **A recycled drop actually moves.** `spawnDrop` reuses the pooled body's
   `BeltMover`/`StayUpright` and rewrites their axes, velocity and CFrame. A
   constraint that does not resettle on reparent would leave recycled drops
   standing at the nozzle. Watch a plot for one full `DropLifetime` cycle.
2. **The ride-token reaper.** Let a drop expire (block the collector), watch
   it recycle once, and confirm the next ride is not reaped early by the old
   timer.
3. **The upgrader flash reads at belt speed** now that it changes no number —
   tint, burst and tung with no Value write behind them.
4. **The repair prompt.** Break the unit (call `Tycoon:damageStorage` from the
   command bar — nothing in the live game damages it yet), confirm the prompt
   appears only then, holds for `RepairHoldSeconds`, refuses a visitor, and
   the body recolours both ways.
5. **The income tick against the HUD lerp.** One payment per second through
   the 0.1s coalescer should read as a smooth counter; if it stutters,
   `IncomeTickSeconds` is the lever and its verifier bounds say how far.
6. **FX throughput at the budget**: 70 drops, ten plots, the 0.3s payout
   throttle and the per-pass flash all firing with nobody watching.

## 3. Mock claims this round leans on

- `task.wait`/`task.delay` under the mock clock schedule exactly like the
  engine's — the income tick and the reaper are specced against it.
- Attributes on mock Instances behave like the engine's (set, read, nil-out).
- What the harness cannot claim: `LinearVelocity`, `AlignOrientation`,
  `PhysicalProperties`, CFrame multiplication. `spawnDrop` is therefore
  outside the spec suite entirely; `drops_spec` covers the bookkeeping around
  it and §2 items 1–2 cover the rest.

## 4. Seams left deliberately open

- `Tycoon:storedOverflowFraction()` returns 0. #98 fills it in; damage
  scaling and (later) raid loot both read it, so the arithmetic lands in one
  place.
- `Tycoon:damageStorage(amount, attacker)` has no live caller. #94 and #124
  are the callers; the `attacker` parameter is already in the signature so
  neither has to change the seam.
- `Tycoon:storageIntact()` is the predicate #98's overflow banking consults.
- Storage state is tenancy-scoped. Persisting damage across sessions is a
  #124 decision (walls persist there; the unit may follow).
