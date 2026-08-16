# docs/

Three trees, and they do not overlap.

| | |
| --- | --- |
| **`design/`** | **what the game should be.** Product decisions, mirrored from the issues that own them |
| **`dev/`** | **how the code is built.** The module map, the invariants, and the round-by-round history |
| **`old/`** | spent briefs, kept until the round that superseded them has been read |

The rule that keeps them apart, in one sentence:

> **A comment may say what the code does and what will break if you change it.
> It may not say why the game should be this way.**

`design/README.md` is the long version, including where a paragraph goes when
you are holding one and do not know.

---

## `design/` — the product layer

**GitHub issues are authoritative.** [#72 — Design
Monolith](https://github.com/adit-rah/ttt/issues/72) is the index; ten
sub-issues hold the decisions. This tree is a maintained snapshot; if it
disagrees with an issue, the issue wins.

| File | What it is |
| --- | --- |
| `design/GAME.md` | the current flow, end to end — what a player does, in what order, with the real numbers |
| `design/SYSTEMS.md` | the product architecture — the eight systems, what each owns, where they touch |
| `design/DECISIONS.md` | `D-NN` → title → issue → status. **Source code cites these ids, and a lint checks them.** |
| `design/growth/` | acquisition and live ops: the store page, the update calendar |
| `design/research/` | the sourced backlogs the decisions were argued from. **Not decisions.** |

`design/research/` was untracked until this round. It holds the audience data,
the session-length reasoning and the no-monetization constraint, and none of
that was visible from a clone.

---

## `dev/` — the engineering layer

**Start here, and neither one is a handoff.**

| File | What it is |
| --- | --- |
| `dev/ARCHITECTURE.md` | the module map — every file in `src/`, who requires it, and the four ownership boundaries |
| `dev/INVARIANTS.md` | **the live contract.** Every load-bearing rule, grouped by subsystem, each naming what enforces it |

`INVARIANTS.md` exists because the rules used to live in six handoff
§-sections and you had to read all six, in reverse, resolving supersessions by
hand, to learn what you must not break. For *current* truth it supersedes those
sections. The handoffs remain the historical record of how each rule was arrived
at, which is often the part that makes it make sense.

### The handoff chain

History, newest first. Each round's document says what it changed and why, what
it could not prove, and what only Studio can tell you.

| File | The round it records |
| --- | --- |
| `dev/HANDOFF_v10.md` | the plot shell comes off the ladder that pays for it, and the mezzanine is gated on a roof |
| `dev/HANDOFF_v9.md` | the armoury moves downstairs, the shell sells in three rungs, the storey lands at two thirds |
| `dev/HANDOFF_v8.md` | the mobile and HUD layout round — the one time Studio was consulted and found a shipped bug |
| `dev/HANDOFF_v7.md` | the client boots again, the docs split, `Tycoon` becomes twelve files, the walls close |
| `dev/HANDOFF_v6.md` | two rounds in one file: mid-game pacing, the mezzanine ladder, the yard and admin commands (§1–§6), then retention, session locking, mobile UI, analytics and the shared boss (§G1–§G6) |
| `dev/RECONCILE_v6.md` | how those two parallel rounds divided the files, and where they touched |
| `dev/HANDOFF_v5.md` | the second floor becomes a purchase, world text, the belt's triggers, the generator yard |
| `dev/HANDOFF_v4.md` | progression splits into tracks; raider AI; the persistence landmines |
| `dev/HANDOFF_v3.md` | procedural animation — still the only correct account; read §2 before touching `SwingAnim.lua` |
| `dev/HANDOFF_v2.md` | plot geometry and the prototypes |
| `dev/HANDOFF.md` | the base game, and the original landmine list |

**Two gaps, named rather than hidden.** `#74` (storey lighting, the guard rails
meeting the belt) has no handoff — `HANDOFF_v10.md` was written at `#73` and the
round closed without one. And the handoffs' "what only Studio can tell you"
sections are a **live product queue trapped in history documents**: about 45
questions asked across six rounds, 3 answered. Those are now filed against the
design decision each would change, so they can be closed rather than carried
forward.

Handoff references to files that no longer exist (`IDEAS.md` at its old path,
`GROWTH-TODO.md`, the root `NEW_TODO.md`) are kept as written. Those documents
are a record of what each PR did, and rewriting them to hide a file that existed
at the time would make them a less useful record, not a more accurate one.

---

## The work list, at the repo root

`docs/` is reference; `TODO.md` is what is being built now. It is rewritten each
round, and it is a brief rather than a record — the record is the handoff.
