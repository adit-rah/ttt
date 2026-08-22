# HANDOFF v17 — movement, the raid loot loop, and helping

The round shipped #101 (sprint and dash), the core of #94 (raiding), and #123
(helping pays). Wave 3 of the build order, complete.

## 1. What moved

- `Config.Movement` and `Config.Raid` are new blocks; every number in both is
  asserted by its own verifier family and each check has been falsified.
- `MovementService` / `MovementClient`: sprint is one bit up `SetSprint` and
  the server writes `WalkSpeed`; the dash impulse fires client-side on the
  `RequestDash` approval echo, and the server's cooldown ledger
  (`tryDash`/`dashReady`) is what #94-adjacent systems must read for cadence.
- `RaidService`: `overflowOf` (cash above `SafeFraction x cap`) is the only
  door to a victim's money; a storage break spills a fraction of it into the
  attacker's CARRY; `bankCarry` deposits through `Economy.add` (cap-clamped)
  when the carrier stands on their own plot; any death drops the carry back to
  its sources and a player kill lifts `KillStealFraction` of the dead player's
  overflow; repeat raids on one victim decay by `CampingHalving` per break
  inside `CampingWindowSeconds`.
- `Economy.take(player, amount)`: the absolute outflow the ledger uses. The
  caller sizes the amount from overflow; `take` clamps only at an empty bank.
- The storage unit is now a swing target: `VaultBase` resolves to the reserved
  key `"storage"` inside `Tycoon.siegeStrike` and routes to `damageStorage`,
  with the same per-swing dedup and owner refusal as a wall. The break
  transition calls `Tycoon.storageBreakObserver` (wired to
  `RaidService.onStorageBroken` in `Main.server`).
- Kill credit rides the `creator` tag CombatService already plants; a death
  with no tag (fall, reset) still drops the carry.
- `HelpService` (#123): `credit(helper, helped, kind, now)` is the one door
  kindness comes through — raid defence and visitor repair land there today.
  Reputation persists (`profile.reputation`, `Rep` leaderstat), both sides get
  minutes of the `"help"` income multiplier, the helper's scaled by the
  rebirth-gap weight. Repair opened past the owner; the breaker is the one
  exclusion (`lastBreaker`/`storageBreaker`), so break-and-repair cannot farm.

## 2. Decisions the round recorded

- Sprint and dash are baseline capabilities. Mounts and waypoints wait for #89
  — there is no world to cross yet.
- The siren guarantee keeps its walking form; sprint only strengthens the run
  home.
- The safe amount is a fraction of the CAP, so what a raid can reach grows
  with the same curve as what the victim can hold, at every rebirth count.
- An empty unit pays a minted bounty: raiding must reward the raider every
  time, and the broke must lose nothing.
- Carried loot is the anti-grief spine: the thief is killable until they get
  home, the kill returns each share to its source, and both returns are
  cap-clamped like every other inflow.

## 3. What only Studio can tell you

1. **Dash feel.** `DashSpeed = 70` for `0.25s` is arithmetic; whether the
   burst reads as a dodge is not. Aim it with `MoveDirection` held and
   standing still (LookVector fallback).
2. **Approval-echo latency.** The dash impulse waits on a server round trip.
   On a 150 ms connection, does Q-press-to-burst feel acceptable?
3. **Touch buttons vs the thumbstick.** RUN/DASH dock above the LEFT reserve.
   On a real phone, does the stack collide with the engine thumbstick at any
   scale?
4. **The banking rectangle.** The heartbeat banks a carrier standing inside
   `PlotSize` of their own plot's centre — the CENTRE pad, so a carrier on
   their own bought land beyond it does not bank. Stand on landL5 and check
   whether that reads as a bug or as "get to the heart of your base".
5. **The chase.** Break a storage unit with a second account, run, and get
   killed: does the `creator` tag survive long enough (8 s Debris) for the
   defender's kill to register the return?
6. **`CarryingTung` legibility.** The attribute is set on the carrier's
   character; nothing draws it yet. A raider carrying loot should be visibly
   marked — filed as a sub-issue of #94.
7. Sprint across the grown ring (~750 radius): at 32 studs/s the walk between
   plots is still long. #89 owns the real answer.
8. **The repair prompt in a stranger's hands.** Prompts now trigger for
   anyone; on a live server, does a passer-by understand that holding a
   stranger's stump is a good deed that pays? The notification says so after
   the fact; nothing invites it before.
9. **The boost's legibility.** `Rep` is a leaderstat and the boost arrives as
   a notification plus a bigger multiplier in the Stats payload; whether the
   HUD needs a visible boost timer is a Studio read.
