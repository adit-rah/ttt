# HANDOFF v16 — the week is walked

design:D-01 and D-03, via #90. The pacing simulation models the arc the game
is now selling: sittings of 30 minutes, offline gaps that pay the mirror's
discounted rate through the storage cap's own door, and the rebirth pad taken
whenever it is the cheapest move that still leaves a climb. The measured
week: frontier day 5, three rebirths, the first on day 3, worst save one
sitting.

## 1. What moved

| was | is |
| --- | --- |
| one 45–150-minute build, credit-capped at 60 | a 5–9 day frontier; the 60-minute platform fact binds each day's sitting |
| first rebirth minute 25–50 | first rebirth day 2–3, asserted by the week walk |
| MAX_SINGLE_WAIT 15 min | no purchase takes more than two sittings of pure saving, at the multiplier the player actually has |
| PriceRung 6, CostGrowth 3.4 | PriceRung 10, CostGrowth 2.8 — the pad is a mid-arc move, kept out of the early game by the first-rebirth-day floor |
| #98's KPI 1 checked at rebirth zero | checked inside the week, where tail rungs meet a rebirthed bank |

The one-life walk keeps a 60-minute FLOOR and its structural duties: the
flat-run guard, the detour model, the power return. Its ceilings are gone on
purpose — the ladder's tail is post-rebirth content, and "too grindy at
rebirth zero" is the design working.

## 2. Decisions the retune recorded

- The old rebirths-4-to-12 collapse (one-to-three-minute loops) is held off
  by the existing cost-ratio check: CostGrowth 2.8 against MultiplierPerRebirth
  2.25 makes each rebirth take ~1.24x as long as the last, and the check
  refuses a ratio under 1.2.
- The detour cap and side-track budget stay per-lifetime measures (the
  recorded default); the week's wall check is the per-sitting guarantee.
- The week model plays the free 8 offline hours only — Vault Timer purchases
  are upside it does not assume.

## 3. What only Studio can tell you

1. Whether 30 minutes of sitting FEELS like a sitting: the model buys
   greedily with no combat, no raids, no walking. Real sittings are longer
   per purchase.
2. The gap arrival clipped by the storage cap: an 8-hour grant collapses to
   ~30 minutes of income at the door. That is #98 working, and whether the
   welcome-back panel reads as a lie before the clip is #96's surface
   problem, named there.
3. Whether a 262-minute rebirth-zero grind reads as "a week of content" or
   "a wall" to a player who refuses the pad. The model says the pad is
   always the cheaper move; a player who hates resets is off the modelled
   path.
