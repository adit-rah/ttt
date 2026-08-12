# docs/

## Start here

Two documents, and neither of them is a handoff.

| File | What it is |
| --- | --- |
| `../CLAUDE.md` | the operating manual: the commands, the conventions, and where to change what |
| `dev/ARCHITECTURE.md` | the module map — every file in `src/`, who requires it, and the four ownership boundaries |
| `dev/INVARIANTS.md` | **the live contract.** Every load-bearing rule in the project, grouped by subsystem, each one naming what enforces it |

`INVARIANTS.md` exists because the rules used to live in six handoff §-sections
and you had to read all six, in reverse, resolving supersessions by hand, to
learn what you must not break. For *current* truth it supersedes those sections.
The handoffs below remain the historical record of how each rule was arrived at,
which is often the part that makes it make sense.

## `dev/` — the handoff chain

History, newest first. Each round's document says what it changed and why, what
it could not prove, and what only Studio can tell you.

| File | The round it records |
| --- | --- |
| `dev/HANDOFF_v6.md` | two rounds in one file: mid-game pacing, the mezzanine ladder, the generator yard and admin commands (§1–§6), then retention, session locking, mobile UI, analytics and the shared boss (§G1–§G6) |
| `dev/RECONCILE_v6.md` | how those two parallel rounds divided the files, and where they touched |
| `dev/HANDOFF_v5.md` | the second floor becomes a purchase, world text, the belt's triggers, the generator yard |
| `dev/HANDOFF_v4.md` | progression splits into tracks; raider AI; the persistence landmines |
| `dev/HANDOFF_v3.md` | procedural animation — still the only correct account; read §2 before touching `SwingAnim.lua` |
| `dev/HANDOFF_v2.md` | plot geometry and the prototypes |
| `dev/HANDOFF.md` | the base game, and the original landmine list |

## `ideas/` — not tracked

Three documents, **deliberately gitignored**, living only on working copies:

| File | What it asks |
| --- | --- |
| `ideas/IDEAS.md` | what should the game contain — researched depth backlog |
| `ideas/GROWTH.md` | why does anyone click, stay, or come back — researched |
| `ideas/EXPANSION.md` | the next block of work, specified — a design brief, not research |

Because they are untracked, the references to `IDEAS.md` in
`dev/HANDOFF_v2.md` (§1, §6, §7) will not resolve from a fresh clone. They are
kept as written because that document is a historical record of what each PR
did, and rewriting it to hide a file that existed at the time would make it a
less useful record, not a more accurate one.

## The work lists, at the repo root

`docs/` is history and reference; a root work list is what is being built now.
Each is the plain version of one `ideas/` document — same list, none of the
sourcing or arithmetic — except `TODO.md`, which has always been written
directly.

| File | Plain version of | State |
| --- | --- | --- |
| `TODO.md` | *(standalone)* | **live** — rewritten each round; the current one is round 7 |
| `GROWTH-TODO.md` | `ideas/GROWTH.md` | spent — worked by round 6's growth half, recorded in `HANDOFF_v6.md` §G1 |
| `NEW_TODO.md` | `ideas/EXPANSION.md` | spent — the mezzanine, the cabinets and the generator yard all landed |

A spent list is kept until the round that supersedes it has been read, then
deleted: it is a brief, not a record, and the record is the handoff.
