# TODO

Round 8 (#64–#70) worked through the five items that were here. They are done;
`docs/dev/HANDOFF_v9.md` §1 says what each one turned into and §3 says what only
Studio can answer.

The next round's brief goes here. Two things this round left that are worth
being the start of it:

1. **Widen `SERVER_MODULES` in `tools/test.py` to include `FloorService`.** It
   is the single biggest coverage gap in the repo now: the deck/line split and
   the whole staged-arrival mechanism execute nowhere but Roblox. `HANDOFF_v9`
   §4 has the list.

2. **The mezzanine's `landing` zone is 116 × 76 studs of deliberately empty
   deck** — a stairwell and one buy pad. That is what "the second floor should
   start barren" asked for, and it is now the largest unused area on the plot.
   Whether it wants filling, and with what, is a design question rather than a
   defect.
