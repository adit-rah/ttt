# docs/

## `dev/` — the handoff chain

Read these in reverse order; each supersedes the one before it on the subjects
it covers, and each says explicitly what it does *not* supersede.

| File | Still the reference for |
| --- | --- |
| `dev/HANDOFF_v3.md` | procedural animation — read §2 before touching `SwingAnim.lua` |
| `dev/HANDOFF_v2.md` | plot geometry, combat, economy, tooling, the prototypes, the open list |
| `dev/HANDOFF.md` | the base game, and the original landmine list |

## `ideas/` — not tracked

`ideas/IDEAS.md` is the researched depth backlog that shipped in PR #4. It is
**deliberately gitignored** and lives only on working copies, so the references
to it in `dev/HANDOFF_v2.md` (§1, §6, §7) will not resolve from a fresh clone.
They are kept as written because that document is a historical record of what
each PR did, and rewriting it to hide a file that existed at the time would
make it a less useful record, not a more accurate one.

## `TODO.md`, at the repo root

The live work list. `docs/` is history and reference; `TODO.md` is what is
being built now.
