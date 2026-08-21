# The decision index

**Every `D-NN` in this project resolves here.** Source code cites these ids and
`tools/verify.py` fails the build on one that does not appear in the table below,
so this file is machine-read as well as human-read.

The issue is authoritative. This row is a pointer to it.

| id | decision | issue | status |
| --- | --- | --- | --- |
| `D-01` | Pitch, audience, session shape | [#76](https://github.com/adit-rah/ttt/issues/76) | accepted |
| `D-02` | The core loop | [#77](https://github.com/adit-rah/ttt/issues/77) | accepted |
| `D-03` | Progression and the five ladders | [#78](https://github.com/adit-rah/ttt/issues/78) | accepted |
| `D-04` | Economy and pacing | [#79](https://github.com/adit-rah/ttt/issues/79) | accepted |
| `D-05` | Rebirth | [#80](https://github.com/adit-rah/ttt/issues/80) | accepted |
| `D-06` | Combat and raids | [#81](https://github.com/adit-rah/ttt/issues/81) | accepted |
| `D-07` | The plot and the world | [#82](https://github.com/adit-rah/ttt/issues/82) | accepted |
| `D-08` | Retention and sessions | [#83](https://github.com/adit-rah/ttt/issues/83) | accepted |
| `D-09` | UI and readability | [#84](https://github.com/adit-rah/ttt/issues/84) | accepted |
| `D-10` | Presentation and content | [#85](https://github.com/adit-rah/ttt/issues/85) | accepted |

The index issue is [#72](https://github.com/adit-rah/ttt/issues/72).

---

## The rules for this table

**An id is never reused and never deleted.** A superseded decision keeps its row
with `superseded by D-NN` in the status column, because the code that cited it is
in the history and a reader following that citation should land somewhere.

**Ids are `D-NN`, not issue numbers.** This repo interleaves issues and pull
requests in one number sequence, so an issue number cannot be reserved in
advance, and a decision that later splits in two would take its number with it.

**Status is one of** `accepted` · `open` · `superseded by D-NN`. "Accepted"
means shipped and deliberate. It does not mean settled — every decision in the
table above carries open questions, and several carry known defects.

**Adding a row means opening the issue first.** The issue is where a decision is
argued; this file only records that it exists.

## Citing one from code

```lua
-- design:D-05 — the 6th most expensive spine price, rounded to 2 s.f.
PriceRung = 6,
```

The lint checks that `D-05` is a row here. It cannot check that the citation is
apt — nothing can — but a dangling id is the failure that actually happens, and
that one is caught.
