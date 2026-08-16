# TODO

Round 8's five items are done (`docs/dev/HANDOFF_v9.md`), and so is round 9 —
the plot shell came off the ladder that pays for it (`HANDOFF_v10.md`). Two PRs
have landed since that document was written: `#74` (storey lighting, the guard
rails meeting the belt) and `#75` (archiving the spent brief). **`#74` has no
handoff**; it is the one gap in the chain.

The current round is the design split: product decisions moved out of the code
and into [#72](https://github.com/adit-rah/ttt/issues/72) and its ten
sub-issues, mirrored in `docs/design/`. **The open questions that used to be
carried forward in handoff §"what only Studio can tell you" sections now live on
the decision each would change**, so they can be closed rather than appended to.

---

## What this round has left

1. **Finish the migration.** `src/shared/Config.lua` is still 53% comment and
   most of it argues for the game rather than describing the code.
   `docs/design/README.md` has the triage. `src/server/` and `src/client/` are
   behind it, and `tools/verify_config.lua`'s assertion messages carry more
   product policy than any single source file does.

2. **The comment-triage lint.** The design-reference lint ships in this round
   (pass 9). Its partner — a run of more than N consecutive comment lines must
   open with `design:`, `invariant:` or `mechanism:` — needs the migration done
   first, or it lands on 86 findings and gets turned off.

3. **`docs/dev/ARCHITECTURE.md` is stale in about thirty specifics.** It lists
   four tracks where there are five, describes the cabinets as standing on the
   mezzanine deck, contradicts itself on the `kind` count, and every
   `Config.lua` line citation in §6 is off by 200–1500 lines.

## What was already here, and still is

4. **Widen `SERVER_MODULES` in `tools/test.py` to include `FloorService`.** The
   single biggest coverage gap in the repo: the deck/line split and the whole
   staged-arrival mechanism execute nowhere but Roblox. `HANDOFF_v9` §4 has the
   list.

5. **Rebirths 4–12 collapse into one-to-three-minute loops.** The largest open
   problem in the game's pacing, and no value of `BaseCost` or `CostGrowth`
   fixes it. Tracked at
   [#80](https://github.com/adit-rah/ttt/issues/80).
