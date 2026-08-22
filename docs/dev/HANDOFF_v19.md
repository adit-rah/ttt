# HANDOFF v19 — the game reveals itself

Wave 5 opens with #96: progressive disclosure. This handoff grows with the
wave's remaining rounds.

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
