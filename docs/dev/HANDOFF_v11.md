# HANDOFF v11 — the product decisions leave the code

One change, and it is about where writing lives rather than about what the game
does: **no line of Lua in this repo executes differently after this round.** The
economy curve is row-for-row identical — build 53 minutes, first rebirth at
minute 42 with six spine rungs unbought, the mezzanine at 67%.

Read `ARCHITECTURE.md` for the module map, `INVARIANTS.md` for what must not
break, and **`../design/README.md` for what may not be written in a comment.**

---

## 1. The defect

The repo had a strong engineering layer and no product layer. `ARCHITECTURE.md`
and `INVARIANTS.md` are good documents. What did not exist anywhere in a clone
was a statement of what the game *is*, who plays it, how long a session should
last, or why any number was chosen.

That intent did not vanish. It went to the four places that would take it:

1. **Code comments.** `Config.lua` was 3,933 lines, **2,110 of them
   comment-only — 53%**. `src/` held 86 comment blocks of ten or more
   consecutive lines. Many were mechanism. Many were product arguments:
   `Config.Rebirth` stated the session-design principle *"the session ends on a
   choice rather than on being finished"*; `Config.Offline` carried the
   retention thesis for the vault gauge; `Config.Social` re-derived Roblox's
   co-play ranking signal; `FloorService` argued that *"the animation is a
   reward for buying the thing"*.
2. **The verifier's assertion strings.** `MIN_REBIRTH_LEFTOVER = 2` means "end
   on wanting more, not on being done". The number is in `Config.lua`, the check
   is in `verify_config.lua`, and the *reason* was in a `check()` message.
3. **A gitignored file.** `docs/ideas/GROWTH.md` held the audience data (80%
   mobile, 56% under 16), the session-length reasoning and the **no-monetization
   decision** — *"That is a decision, not an oversight"* — and none of it was
   visible from a clone.
4. **Two orphaned documents.** `docs/growth/STORE_PAGE.md` holds the only pitch
   sentence in the repo, and `docs/README.md` did not know the directory existed.

A decision you can only find by reading a Lua table is a decision nobody can
review, disagree with, or supersede.

---

## 2. Where writing lives now

Four homes, no overlap. The rule is one sentence: **a comment may say what the
code does and what will break if you change it; it may not say why the game
should be this way.** The test is whether the sentence would survive a rewrite
of the code.

| Destination | What goes there |
| --- | --- |
| an issue under [#72](https://github.com/adit-rah/ttt/issues/72), mirrored in `docs/design/` | product intent |
| `INVARIANTS.md` | a constraint, with an enforcer named on it |
| a handoff (this file) | history — what a value used to be, and why it moved |
| the source file | mechanism |

**#72 is an index**, with ten sub-issues carrying `D-01`–`D-10`. `docs/design/`
holds `GAME.md` (the flow, with the real numbers), `SYSTEMS.md` (the eight
systems as a designer names them), and `DECISIONS.md` (the `D-NN` index, which
the verifier reads).

`docs/ideas/` is tracked now, as `docs/design/research/`, and marked as argument
rather than decision. `docs/growth/` moved under `docs/design/` and is linked.

---

## 3. What is enforced, and how each was falsified

Two new passes. `verify.py` runs **thirteen**.

**Pass 9 — design refs.** Every `design:D-NN` in `src/` or `tools/` must name a
row in `docs/design/DECISIONS.md`. Ten citations against ten decisions today.

*Falsified four ways*: a dangling id in `src/`, a dangling id in `tools/`, a
missing index file, and a changed table shape that would have made the lint go
blind while still reporting `ok`. All four fire with the message as written.

**Pass 10 — comment triage.** A run of more than fifteen consecutive comment
lines must declare itself `design:D-NN`, `invariant:` or `mechanism:` within its
first three lines. It does not read the prose and cannot tell you the call was
right; what it enforces is that somebody **made** the call.

*Falsified twice*: a fresh sixteen-line block with no marker, and a marker
deleted from a block that had one.

The threshold is fifteen rather than zero because a short comment is not where
this goes wrong. The blocks carrying product arguments were the long ones, every
time.

**What neither pass can do** is tell whether a citation is apt, or whether a
block marked `mechanism:` is actually mechanism. Those are review, not lint.

---

## 4. What actually moved, and what did not

The migration was **triage, not deletion**. Most long blocks in this repo are
genuinely mechanism or genuinely landmines, and those stayed — they just say so
now. `Config.lua` went from 2,110 comment lines to 1,891.

Three things came out of the code and are recorded in §6 below, or in the issue
named:

- **Product arguments** → the matching `D-NN`. The rebirth pad's session-design
  principle is `D-05`; the vault gauge's exit hook is `D-08`; the cabinets' first
  three minutes are `D-03`; the barren storey is `D-07`.
- **History** → §6.
- **Stale claims** → deleted, and they were the real find. See §5.

**The verifier's pacing bands now cite their decision instead of arguing for
it.** `MIN_TOTAL_MINUTES`, `CREDIT_CAP_MINUTES`, `MIN_REBIRTH_LEFTOVER`,
`SIDE_MAX_DETOUR_MINUTES`, `VENDING_MACHINE_RUNGS` and the flat-run guard all
carry a `design:` line now. The number stays in `Config.lua`, the check stays in
`verify_config.lua`, and the reason is one place.

---

## 5. The stale sentences, which are the reason to do this at all

Reading every long comment in the repo found five claims that had stopped being
true and were still being read as documentation:

1. **`tycoon/Buttons.lua` said "both side tracks name `floor = "mezzanine"`"**
   and described the nine cabinet pads as standing on the deck at y = 22. `#64`
   moved both cabinets downstairs. `ARCHITECTURE.md` §4.1 said the same thing.
2. **`Installers.lua` said "roof is minute 28 and floor is minute 6"**, which
   inverted the actual dependency — `Config.ButtonUnlock` gates `floor2` on
   `roof`, so the roof is bought first.
3. **`FloorService.lua` said the walls button is bought "around minute three and
   this floor around minute six"**. The floor lands at 67% of the build.
4. **`Config.lua`'s button-table banner listed six of nine `kind`s**, and its own
   comment two paragraphs above warns that a prose count "is a fact stored in the
   one place nothing reads". It had been wrong about the track count before.
5. **`README.md` said the mezzanine arrives "right after the walls — about six
   minutes in" and that the cabinets arrive with it.** Neither has been true for
   two rounds.

`ARCHITECTURE.md` carried about thirty more, listed in its own §7. The factual
ones are fixed. The line-number ones are not fixable in the general case, which
is its own finding — see §7.

---

## 6. History, moved out of the source

Recorded here so the code does not have to carry it.

**Progression.** Before the tracks split, every button `requires`d the one before
it in a single 21-long chain: `dropper5` was unreachable until you had bought a
weapon, and the weapon until `upgrader2`. The factory table has been 21, 24 and
20 rows long across three rounds, and a hand-typed "twenty links" was re-typed
wrong twice. The shell was positions 5, 6, 7 and 14 — mandatory and blocking;
`MAX_FLAT_RUN` exists because round 8 created that hazard and guarded it rather
than removing it.

**The second floor has moved four times**: a free reward for owning `dropper10`
at minute 80; a purchase at the halfway mark (`#29`); minute six (`#36`, because
`TrackUnlock` gated both cabinets on it, so moving one button fixed three); and
now 67% on its own merits, once the cabinets left. On the shipped ladder — floor
at six, roof at twenty-seven — every plot spent twenty-one minutes wearing upper
walls open to the sky.

**Rebirth.** `BaseCost` once claimed in a comment to be "derived from endgame
income". It was not: it was retyped by hand each round, and it drifted the moment
the generator doubled endgame income. `PriceRung` replaced it, was 4, and moved
to 6 when `mezz_line` and `mezz_dropper1` became the two most expensive spine
rungs.

**The plot.** The generator yard was 108 × 40 with three fences, a billboard and
four generator stands, all present from claim — 4,320 square studs of concrete
for a track you had no reason to care about. The walls were five boxes emitted at
a local literal `h = 13` against a roof underside of 20, so every plot had a
seven-stud open band all the way round, and none of the 2,309 config checks
looked at wall height at all. The storey arrived in one frame. The ladder was a
9 × 9 pair of teleport pads with a cooldown, an arrival lock and a `TouchEnded`
sweep against physics jitter; a `TrussPart` answered the question they raised by
not asking it. Belt guard rails existed once, ran each leg's full length, and
were deleted because leg 2's inboard rail crossed leg 1's path.

**The HUD.** The status card replaced two panels, `CashPanel` (280×126) and
`NextPanel` (280×74), always read together and in that order. It carried an
INVITE pill on a friend row, with four keys and five derived coordinates to fit
it. `SessionPanel` had a third height, `CompactHeight = 88`, for builds with
`Prototypes.Sessions` off; the flag graduated in `#50` and the local that chose
between heights went with it, but both reads were left behind in a file that had
also lost its `Req("Config")`.

**Two zones and a budget.** The mezzanine's front zone was named `armoury` for
the two display cases `#58` stood in it; `#64` took both downstairs, so every
containment check written against the name was measuring an empty rectangle and
passing for that reason. `shellPartCount`'s first version left out the trim, the
light strip and the sign anchor — 59 reported against 68 built, 107 against 124.

---

## 7. What only Studio can tell you

**This section is shorter than usual on purpose.** The open playtest questions
are not carried forward here any more; they are checkboxes on the decision each
would change, where they can be closed. About 45 were asked across six handoffs
and 3 were answered, and two fell out of the chain entirely and can no longer be
found by grep.

Nothing in this round needs Studio. It changed no behaviour.

---

## 8. Still open

- **Rebirths 4–12 collapse to one-to-three-minute loops.** Unchanged, and still
  the strongest candidate for the next round's item 1.
  [#80](https://github.com/adit-rah/ttt/issues/80).
- **`FloorService` is still outside `SERVER_MODULES`.**
- **`#74` has no handoff.** `HANDOFF_v10.md` was written at `#73`. It is named in
  `docs/README.md` rather than back-written, because a handoff written six PRs
  late is a reconstruction, not a record.
- **Line numbers in `ARCHITECTURE.md` cannot be linted.** All 42 citations were
  audited: none point past the end of a file, so none is *provably* broken — and
  that is exactly the problem, because nothing cheap distinguishes a citation
  that has drifted 200 lines from one that has not. §4.2 and §6 of that document
  no longer carry any; they name symbols instead. The rest are marked as hints.
- **Player-facing copy is still hardcoded** across about fifteen service files.
  Only a button's `name` and `blurb` are data. So are the machine silhouettes and
  both colour palettes. That is product content in code, and moving it is a real
  refactor with real risk — it is `D-09` and `D-10`, not this round.
