# HANDOFF v19 — the game reveals itself, the shop, and today's three

Wave 5: #96 (progressive disclosure), #108 (the shop replacing the cabinets)
#97 (daily objectives + the hint line), #100 (the guide), #106 (the public
tier tag) and #107 (the rebirth moment). This handoff grows with the wave's
remaining rounds.

## 1. What moved

- `Config.Disclosure` is the one table: eleven surfaces, each with an earn
  trigger (`after` = a button id), a name and a help line. The always-on set
  — `hud` and `movement` — IS the sixty-second screen, printed by the
  verifier on every run and capped at three rows.
- `DisclosureService`: a 3s beat writes earned rows into `profile.disclosed`
  (persisted high-water, both homes; a rebirth wipes `owned` and forgives
  nothing), toasts each arrival with its help line, and pushes the whole set.
- Client gates: the terms line, the invite rail item, the session panel and
  the party card all ask `HUD.disclosed(id)` at render. An incoming party
  invite shows regardless — someone chose you, and hiding that is worse.
- **The plot siege is a gated disclosure**: NPCService starts a plot's raid
  cycle only once `profile.disclosed.siege` is true (earned by walls). A
  siren in the first minute is the overload the system exists to prevent.
- The help card: a "?" on the rail opens an overlay listing ONLY unlocked
  surfaces, so it structurally cannot become a manual.

- **The shop (#108)**: the cabinets, their signs, their shelves, their
  pedestal columns and their entire verifier geometry family are GONE; the
  right-hand plot floor is bare ground again. The catalog is the same
  Config.Buttons rows (the tuned week walk spends through them unchanged);
  ShopService validates disclosure → milestone → chain → price and lands the
  same monotonic grants; ShopUI is an overlay card with the pads' measured
  effect lines, opened from the SHOP rail item or the golden merchant by the
  spawn. The NEXT UPGRADE card says "in the SHOP" for shop rows.

- **Objectives (#97)**: three a day from a seeded pool, progress measured
  against a day-baseline of persisted stats (no observers anywhere),
  completion pays minutes of your own income once, the richest possible day
  is asserted under 12 minutes. The card sits in the left column under the
  session panel, disclosure-gated on upgrader1, and carries the hint line —
  the first unmet non-purchase milestone, which the guide (#100) will speak.

## 2. What only Studio can tell you

1. **The first sixty seconds, watched.** Fresh save: the screen should be the
   plot, the beacon, the status card, the toast and two touch buttons. Count
   what else leaks (the wave billboard at the dais is distance-limited and
   deliberately ungated — check it stays unread from the belt).
2. **Arrival pacing.** Buy dropper2 → terms toast; dropper3 → session panel.
   Do the toasts land close enough to the act that the earning reads?
3. **The siege's first siren.** Buy walls, wait out the half-rest: confirm
   the NEW: toast lands BEFORE the first siren, or the disclosure explains
   the thing after it happened.
4. **The help card on a phone.** Overlay-centred, CLOSE in the corner, grows
   with unlocks — check it at MinScale with everything unlocked.
5. **The undisclosed party invite.** Have a veteran invite a fresh player:
   the card must appear for the invite alone and stay after an accept.
6. **The reclaimed floor.** The right-hand run the cabinets held is empty
   now; walk a maxed plot and check nothing else assumed the cases (lights,
   wall clearances all pass the verifier, but the LOOK of the bare run is a
   read).
7. **The merchant.** A golden Tung near the spawn pad with a Browse prompt;
   check the prompt fires the shop open on a client and that the statue does
   not collide with the spawn walk.
8. **The shop card on a phone.** Ten rows plus headers at MinScale; the
   AFTER-x button states; a buy landing as a notify + the row flipping to
   OWNED on the next Stats push.
9. **The bat in hand after a shop buy.** grantBat now returns early with no
   Backpack (the headless guard); confirm a live buy still re-equips
   immediately, not on next spawn.
10. **The objectives beat.** Five-second cadence: complete an objective and
    watch the toast land within a beat; check the column still fits at
    MinScale with status card + session + party + objectives all up.
11. **The tower objective.** "Clear 3 tower floors" reads profile.tower.best,
    which only moves on recordClear — confirm a real climb ticks the row.
12. **The guide, met.** A small classic Tung beside the spawn aisle with a
    Talk prompt: confirm it faces the arriving player (it is rotated to face
    the gateway), the prompt reads at 10 studs, and the line lands as a
    toast. A visitor talking to it should hear THEIR hint.
13. **The guide vs the totem.** Both stand near the plot's front; check they
    read as two different things at a glance.
14. **The tag, read from outside.** Walk the belt past three plots: the rank
    should read beside the name from the grass, and NOT from across the map.
    A rebirth should repaint it within a beat of the pad firing.
15. **The rebirth card, felt.** Rebirth on a live plot: the card should land
    with the purple burst, read in under ten seconds, and be gone by
    fourteen; a rank-up rebirth (1st, 2nd, 3rd, 5th) should feel louder than
    a plain one. Check it does not fight the welcome-back modal for the
    overlay.
