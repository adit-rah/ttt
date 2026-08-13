# HANDOFF v10 — the building stops blocking the line

One change, and it is structural rather than numeric: **the plot shell is no
longer a rung on the ladder that pays for it.**

Read `ARCHITECTURE.md` for the module map and `INVARIANTS.md` for what must not
break. This file is why this round did what it did, and what it did not prove.

---

## 1. The defect

`Config.FactoryButtons` is a strict chain — the loader derives `requires` from
table order and the verifier asserts the chain IS that order. Four of its rungs
were the building:

```
dropper1 → dropper2 → upgrader1 → dropper3 → walls → gates → windows → dropper4
  → … → dropper6 → roof → dropper7 → upgrader4 → floor2 → …
```

So the shell was **mandatory and blocking**. You could not buy `dropper4` until
you had bought Plot Walls, Sliding Gates and Glazed Bays — three consecutive
purchases that drop, refine and multiply nothing, sitting on the one ladder the
player measures themselves by.

Round 8 created that run and guarded it rather than removing it: `MAX_FLAT_RUN`
exists for precisely these three rungs, and its own comment says "the player is
buying scenery while the thing they are measuring themselves by has stopped
moving." This round removes it instead.

**The shell is now a fifth track, `structure`, gated as a whole on `dropper1`
and parallel to the factory.** Prices and internal order are byte-identical.

---

## 2. What this cost, which was almost nothing, and why that is the point

**The simulated curve is row-for-row unchanged.** Build 53 min, credit-cap
headroom 7 min, first rebirth `1.2e+08` at minute 42 with 6 spine rungs left,
floor at 67%, side tracks 30% of a 35% budget. Not a single one of those moved,
because the spine simulation buys the cheapest available rung and 1500 / 1600 /
1900 still sit under `dropper4`'s 2600 while 690 000 still sits between
`power2` and `dropper7`.

That is the strongest thing available to say about a re-parenting: it is
provably pacing-neutral, so anything that *does* move later is the next
person's change and not this one.

**`paced = "spine"`, and the alternative was measured rather than argued.**
Priced as a detour the build reads **46.2 minutes against a `MIN_TOTAL_MINUTES`
of 45** — and the four purchases did not stop happening, the verifier just
stopped counting them. The detour model also assumes you can decline a track,
which stopped being true the moment `ButtonUnlock` put `roof` between the player
and the mezzanine.

**`Config.Rebirth.BaseCost` is unchanged at 120 000 000.** `roof` lands at spine
price rank 13; `PriceRung = 6` is `dropper9` at 115 000 000 either way. Worth
recording because `spinePricesDescending` now derives from `paced` rather than
naming factory and power, so the list genuinely did grow by four.

---

## 3. The sky hole, and a fix that died quietly

`FloorService` stands each storey's own wall ring up and **nothing else ever
roofs it**. Round 8 found that plots spent twenty-one minutes wearing upper
walls open to the sky, and fixed it by ORDERING — `roof` became an earlier row
on the same chain than `floor2`.

**A parallel track is one you can decline, so that fix left with the shell.**
Nothing would have stopped a player buying the mezzanine having never bought a
roof, and the config check guarding it would have gone on passing, because it
only ever compared two purchase minutes.

`Config.ButtonUnlock = { floor2 = "roof" }` replaces it — a precondition on a
purchase, deliberately not a `requires` (the loader would overwrite it and the
cross-track assertion would refuse it), evaluated in `requirementsMet` and
mirrored in the HUD's `cheapestAvailable`.

**Three things about it that are easy to get wrong, and are written into the
code rather than only here:**

- It is **not** in `refreshButtons`'s `standing` term. A false `standing`
  unparents the pad, which is right for a cabinet and wrong for `floor2` —
  its pedestal is the near end of a six-pad column that reads as purchase
  order, and hiding it leaves a gap. Left out, the existing preview branch
  already renders it dimmed and inert, which is the wanted behaviour.
- The blocker message checks the gate **first**. `floor2`'s chain requirement
  is `upgrader4`, which the player has just bought, so walking `requiresOf`
  alone finds nothing unmet and the pad reads the bare word "locked" beside a
  nine-million price tag. This was the single most likely silent defect in the
  change.
- It is **not sticky**, unlike `trackUnlocked`. Both tracks are
  `keepOnRebirth = false`, so rebirth takes `roof` and `floor2` together; a
  copied stickiness clause would be unreachable code.

**The old pacing assertion was DELETED, not retuned.** It said a deck bought
first "leaves the upper walls open to the sky for the N minutes in between."
Once the runtime refuses the purchase that state is unreachable and those
minutes do not exist. It would have gone on firing, for a reason that had
stopped being the reason — the same fault that got `at <= 10` deleted a round
ago, and the third time this file has recorded it.

---

## 4. What the verifier gained

The three that would have caught something nobody was looking for:

- **Reachability now counts the gates.** The old walk followed `requires` only,
  and was safe rather than correct — it relied on `TrackUnlock` naming a button
  on an ungated track. `ButtonUnlock` removes that guarantee, and
  `TrackUnlock.structure = "dropper8"` plus the shipped
  `ButtonUnlock.floor2 = "roof"` deadlocks the plot four rungs from the end with
  every structural check passing. It is a fixpoint from an empty save now.
- **`keepOnRebirth == (furniture == "cabinet")`**, which retires a `[nothing]`
  and is not a taste rule: only cabinet tracks build into `self.props`, and
  `rebirth()` clears `self.machines` unconditionally. A non-cabinet track that
  survives is a bought button whose model has just been destroyed — the pad
  hides itself and the plot keeps the hole for the session.
- **`roof` needs `walls`**, which was never asserted. `buildRoofModel` derives
  its columns from `Config.wallExtent`, so a roof with no wall under it is four
  columns and a slab in a field. Unfalsifiable while both lived on one chain.

Also: the spine interleave reads `paced` instead of naming two tracks and
dispatches income on `def.kind` rather than on which lane a rung came from (the
old form would have made a `Dropper` on the power track silently inert); spine
prices must be globally distinct, or the tie-break rather than the price decides
the order; the vending-machine check is scoped to `paced == "side"` (it fired
3-of-4 on the shell, for a non-defect — the shell is one building in three
instalments, not four interchangeable tiers); and the spawn-affordability check
is scoped to ungated tracks, where it had quietly become theatre for two of its
three iterations after round 8 gated both cabinets.

**Every new assertion was falsified**: broken once, confirmed to fire with the
message as written, reverted. Both runtime gates too — removing the server gate
fails three specs, removing the HUD gate fails two.

---

## 5. The analytics discontinuity, which is silent and is not a bug

`Analytics.Fields.buttonId` is filled from `Config.Tracks.factory`, so it went
from 24 values to 20 and the schema's combination cost dropped **2 520 → 2 400**.
Correct: no structure button can ever be a first purchase, because the track is
gated on `dropper1`. Four facets for a state the game cannot reach, refunded.

**`Analytics.milestoneOf` reports the owned button with the highest `def.order`,
and `roof` moved from order 14 to order 24.** It now out-ranks `dropper7`
through `dropper10`. Nothing breaks, but the `milestone` series has a
discontinuity at this deploy and a session that stopped at the roof files
differently than it did last week. Anyone reading that chart across the boundary
needs to know.

`milestone` itself did **not** move — 38 of a `MaxFieldValues` of 40, exactly as
before, because this re-parented buttons rather than adding any. Two left.

---

## 6. What only Studio can tell you

This list is meant to be answered, not appended to.

1. **Does the beacon swinging to the shell read as helpful or as nagging?**
   `structure` is at TrackOrder position **2**, which is load-bearing rather
   than cosmetic: `TrackRank` drives both the plot beacon and the HUD card, and
   at rank 5 the marker would have pointed at an eclipse bat while the ladder
   sat stalled on a roof. Nothing in the verifier can assert that a beacon
   points somewhere useful. The lever if it nags is the position.
2. **Is a declinable shell a shell anybody buys?** The whole argument for this
   change is that scenery should not block income. The risk on the other side is
   a player who reaches minute 30 in an open-air plot because nothing ever made
   them stop. `roof` gating the mezzanine is the only forcing function, and it
   does not bite until 67% of the build.
3. **Does the dimmed `floor2` pad read as an instruction?** It is the first
   cross-track blocker in the game — the pad says "locked — buy Sahur Roof +
   Sign first" while pointing at a purchase on a ladder the player may not have
   been thinking about. On a phone, at the near end of the misc column.
4. Carried forward unanswered from v9: the barren mezzanine at minute 35 (§3
   item 9), the 5.2-second storey (item 4), the armoury aisle (item 7), the
   rebirth pad's new position (item 8), and whether gates still slide (item 10).

---

## 7. Still open, and unchanged by this round

- **Rebirths 4–12 collapse to one-to-three-minute loops.** Still the strongest
  candidate for the next round's item 1. No value of `BaseCost` or `CostGrowth`
  fixes it; the lever is scaling prices by `profile.rebirths`.
- **`mezz_dropper1` is 0.002% of endgame income**, blocked behind the drop
  budget at 65 of 70.
- **`FloorService` is still outside `SERVER_MODULES`**, so the deck's four
  transitions and the whole staging mechanism execute nowhere but Roblox. This
  round adds a reason to care: `ButtonUnlock` decides whether the deck is
  buyable, and the spec for that tests `requirementsMet`, not the build.
- **`power4` returns 2.23× against a required 2.0×**, the thinnest margin in the
  curve.
