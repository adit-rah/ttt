# docs/design — the product layer

**This tree says what the game should be. `docs/dev/` says how the code is
built. Nothing belongs in both, and neither one may argue the other's case.**

That split is the whole point of this directory. Before it existed the product
decisions were real but homeless, so they went to the four places that would
take them: code comments (`Config.lua` was 53% comment), the verifier's
assertion messages, a gitignored research file, and two orphaned documents
nothing linked to. A decision you can only find by reading a Lua table is a
decision nobody can review, disagree with, or supersede.

---

## Where a decision lives

**GitHub issues are authoritative.** [#72 — Design
Monolith](https://github.com/adit-rah/ttt/issues/72) is the index; **five
pillars** hold the decisions, their intent, and their open questions. That is
where a decision is argued and changed.

| | |
| --- | --- |
| `D-01` | [The player](https://github.com/adit-rah/ttt/issues/76) |
| `D-02` | [The plot](https://github.com/adit-rah/ttt/issues/77) |
| `D-03` | [Progression](https://github.com/adit-rah/ttt/issues/78) |
| `D-04` | [The world](https://github.com/adit-rah/ttt/issues/79) |
| `D-05` | [Reading it](https://github.com/adit-rah/ttt/issues/80) |
| `D-06` | [Assets](https://github.com/adit-rah/ttt/issues/92) |

There were ten. `DECISIONS.md` records what merged into what, and why.

**This directory is derived.** It is a readable snapshot of what has been
accepted, maintained by hand. If it disagrees with an issue, the issue wins and
this tree is wrong.

| File | What it is |
| --- | --- |
| `GAME.md` | the current flow, end to end — what a player does, in what order, with the real numbers |
| `SYSTEMS.md` | the product architecture — the systems, what each owns, and where they touch |
| `DECISIONS.md` | the index: `D-NN` → title → issue → status. **Source code cites these IDs.** |
| `growth/` | acquisition and live-ops — the store page, the update calendar |
| `research/` | the sourced backlogs the decisions were argued from. Not decisions. |

`research/` is deliberately not authoritative. `IDEAS.md` and `GROWTH.md` are
well-sourced arguments; `EXPANSION.md` is a spent brief. They are tracked so the
reasoning is inspectable, not so it can be cited as settled.

---

## The separation contract

Every piece of writing in this project has exactly one home. When you are
holding a paragraph and do not know where it goes, it is one of these four:

| Destination | What goes there |
| --- | --- |
| **an issue, then `docs/design/`** | product intent — what the player should experience, and why |
| **`docs/dev/INVARIANTS.md`** | an engineering constraint, carrying the marker that names what enforces it |
| **`docs/dev/HANDOFF_v*.md`** | history — what a value used to be, and why it moved |
| **the source file** | mechanism — what this value *does*, in a line or two |

In one sentence, for the code:

> **A comment may say what the code does and what will break if you change it.
> It may not say why the game should be this way.**

The test is whether the sentence would survive a rewrite. "The pad costs what
the 6th most expensive spine rung costs" describes the code and stays. "The
session should end on a choice rather than on being finished" is true of the
game no matter how it is implemented — that is a design decision, and it lives
in `D-03`.

### Citing a decision from code

Where a value is what it is *because of* a design decision, the code says so and
stops:

```lua
-- design:D-03 — the 6th most expensive spine price, rounded to 2 s.f.
PriceRung = 6,
```

`tools/verify.py` fails the build if `D-03` is not a row in `DECISIONS.md`. It
does not check that the citation is apt — nothing can — but a dangling ID is the
failure mode that actually happens, and that one is caught.

---

## How a decision moves

```
open question  ──►  sub-issue of #72  ──►  accepted  ──►  DECISIONS.md row
   (a handoff's           (argued,            (the        (+ the code cites
    "what only Studio     decided)          Decision      it, + GAME.md and
    can tell you", a                        section is    SYSTEMS.md say it
    [nothing] marker,                       written)      in the player's
    a playtest note)                                      terms)
```

A decision is never edited in place here without the issue moving first. A
superseded decision keeps its ID and its row, with `superseded by D-NN` in the
status column — an ID is never reused and never deleted, because the code that
cited it is in the history.

**IDs are `D-NN`, not issue numbers.** GitHub interleaves issues and pull
requests in one sequence in this repo, so an issue number cannot be reserved in
advance, and a decision that later splits in two would take its number with it.
`DECISIONS.md` is the mapping.

---

## What is not decided here

Anything the verifier can settle is an engineering matter and belongs in
`docs/dev/INVARIANTS.md` with a marker on it. The reverse trap is the more
common one, and it has a name in this repo: **the verifier is full of product
opinions with a `check()` around them.** The 45–150 minute build band, the
four-minute detour cap, "at most two rungs affordable when a cabinet opens" —
those are design decisions that happen to be enforceable. The number lives in
`Config.lua`, the assertion lives in `tools/verify_config.lua`, and **the reason
lives here**, cited by both.
