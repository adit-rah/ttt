# docs/

## `dev/` — the handoff chain

Read these in reverse order; each supersedes the one before it on the subjects
it covers, and each says explicitly what it does *not* supersede.

| File | Still the reference for |
| --- | --- |
| `dev/HANDOFF_v4.md` | progression tracks, the cabinets, waves and raider AI, the verifier |
| `dev/HANDOFF_v3.md` | procedural animation — read §2 before touching `SwingAnim.lua` |
| `dev/HANDOFF_v2.md` | plot geometry, the prototypes, and the parts of the open list v4 does not restate |
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

Each is the plain version of one `ideas/` document — same list, none of the
sourcing or arithmetic. `docs/` is history and reference; these are what is being
built now.

| File | Plain version of |
| --- | --- |
| `TODO.md` | *(standalone — the round that produced `HANDOFF_v4.md`)* |
| `GROWTH-TODO.md` | `ideas/GROWTH.md` |
| `NEW_TODO.md` | `ideas/EXPANSION.md` |
