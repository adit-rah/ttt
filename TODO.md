# TODO

Round 8's five items are done (`docs/dev/HANDOFF_v9.md`), and so is round 9 —
the plot shell came off the ladder that pays for it (`HANDOFF_v10.md`). Two PRs
have landed since that document was written: `#74` (storey lighting, the guard
rails meeting the belt) and `#75` (archiving the spent brief). **`#74` has no
handoff**; it is the one gap in the chain.

The current round is the design split: product decisions moved out of the code
and into [#72](https://github.com/adit-rah/ttt/issues/72) and its five
pillars, mirrored in `docs/design/`. **The open questions that used to be
carried forward in handoff §"what only Studio can tell you" sections now live on
the decision each would change**, so they can be closed rather than appended to.

---

## What this round has left

1. **The migration is triage, not a purge, and it stopped at fifteen lines.**
   Blocks of 8–15 comment lines were not audited and carry no marker.
   `Config.lua` is still 1,891 comment lines in 3,711. Lowering `BLOCK_LIMIT` in
   `tools/verify.py` is the way to find out whether that matters.

2. **Player-facing copy is still hardcoded** across about fifteen service files;
   only a button's `name` and `blurb` are data. So are the machine silhouettes
   and both colour palettes. That is product content in code
   ([#80](https://github.com/adit-rah/ttt/issues/80)), and moving it is a real
   refactor with real risk.

3. **The five pillars are written but not argued.** They record what ships and
   why, reconstructed from the code and the handoffs. Nobody has sat down and
   disagreed with one yet, which is the actual point of having them.

## What was already here, and still is

4. **Widen `SERVER_MODULES` in `tools/test.py` to include `FloorService`.** The
   single biggest coverage gap in the repo: the deck/line split and the whole
   staged-arrival mechanism execute nowhere but Roblox. `HANDOFF_v9` §4 has the
   list.

5. **Rebirths 4–12 collapse into one-to-three-minute loops.** The largest open
   problem in the game's pacing, and no value of `BaseCost` or `CostGrowth`
   fixes it. Tracked at
   [#80](https://github.com/adit-rah/ttt/issues/80).
