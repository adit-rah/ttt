# The decision index

**Every `D-NN` in this project resolves here.** Source code cites these ids and
`tools/verify.py` fails the build on one that does not appear in the table
below, so this file is machine-read as well as human-read.

The issue is authoritative. This row is a pointer to it.

| id | pillar | issue | status |
| --- | --- | --- | --- |
| `D-01` | The pitch, the player, and why they come back | [#76](https://github.com/adit-rah/ttt/issues/76) | accepted |
| `D-02` | The line | [#77](https://github.com/adit-rah/ttt/issues/77) | accepted |
| `D-03` | The ladder | [#78](https://github.com/adit-rah/ttt/issues/78) | accepted |
| `D-04` | The raid | [#79](https://github.com/adit-rah/ttt/issues/79) | accepted |
| `D-05` | Reading it | [#80](https://github.com/adit-rah/ttt/issues/80) | accepted |

The index issue is [#72](https://github.com/adit-rah/ttt/issues/72).

## Five, from ten

The first cut of this table had ten rows, and the overlap was real. What merged,
and why:

| merged away | into | because |
| --- | --- | --- |
| Economy & pacing · Rebirth | `D-03` | the ladder, the bands that measure it and the reset that ends it are one system — the rebirth pad is *priced off the spine* |
| The plot & the world | `D-03` | the shell, the storey and the yard are rungs. "Must scenery block income?" is a pacing question. The plot's *geometry* went to `D-02` |
| Retention & sessions | `D-01` | with nothing monetized, "why do they click" and "why do they come back" are one question about one relationship |
| Presentation & content | `D-05` | what the player is told and the constraint on how it can be said are the same subject |

Those five issues are closed, with a note on each naming where its content went.
**No decision was dropped in the merge** — only the filing changed.

---

## The rules for this table

**An id is never reused and never deleted.** A superseded pillar keeps its row
with `superseded by D-NN` in the status column, because the code that cited it
is in the history and a reader following that citation should land somewhere.

**Ids are `D-NN`, not issue numbers.** This repo interleaves issues and pull
requests in one number sequence, so an issue number cannot be reserved in
advance, and a pillar that later splits in two would take its number with it.

**Status is one of** `accepted` · `open` · `superseded by D-NN`. "Accepted"
means shipped and deliberate. It does not mean settled — every pillar above
carries open questions, and two carry known defects.

**Adding a row means opening the issue first**, and only if the subject is
genuinely not one of the five. The issue is where a decision is argued; this
file only records that it exists.

## Citing one from code

```lua
-- design:D-03 — the 6th most expensive spine price, rounded to 2 s.f.
PriceRung = 6,
```

The lint checks that `D-03` is a row here. It cannot check that the citation is
apt — nothing can — but a dangling id is the failure that actually happens, and
that one is caught.
