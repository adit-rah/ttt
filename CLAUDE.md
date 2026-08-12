# CLAUDE.md — how to work in this repo

A Roblox tycoon, all Lua, no uploaded assets: every model is built from
primitives at runtime. `README.md` is for a human who wants to play it. This is
for whoever has to change it.

**Read `docs/dev/ARCHITECTURE.md` for the module map and
`docs/dev/INVARIANTS.md` before you touch code.** Between them they replace the
six handoff documents you would otherwise have to read to find out what is
load-bearing. The handoffs are history; those two are the contract.

---

## The three commands

```bash
python3 tools/verify.py            # ten passes, and it regenerates build/. Run before every commit.
python3 tools/test.py --plain      # the runtime specs alone
python3 tools/test.py --filter X   # one spec family
```

`tools/verify.py` needs the [Luau CLI](https://github.com/luau-lang/luau/releases)
on PATH (`luau`, `luau-compile`, `luau-analyze`). It is what CI runs, plus one
extra step: **CI fails if `build/` is stale**, so commit the regenerated paste
files with the change that caused them.

---

## The conventions, and why each one exists

**`src/` is the source of truth. `build/` is generated.** Never edit
`build/PasteInto_*.lua`; run the packer. They are committed so the no-Rojo
install path works from a clone.

**The import line is byte-identical everywhere.**

```lua
local Req = require(game:GetService("ReplicatedStorage"):WaitForChild("TungShared"):WaitForChild("Req"))
```

`tools/pack.py` pattern-matches that exact line to flatten the tree, and
`tools/test.py` matches the same regex to hand each module a `Req` parameter.
Reformat it and the module silently drops out of both.

**Config over code.** Every tunable number, and every piece of geometry, lives
in `src/shared/Config.lua`. Not for tidiness: `tools/verify_config.lua` reads
that one file and nothing else, so a number in Config is a number the verifier
can assert and a number in a builder is not. Adding content is a table row —
you should never edit `Tycoon` to add a dropper.

**Falsify every assertion you add.** Break the thing it watches; confirm it
fires with the message you wrote. Two rounds have found real bugs while doing
this, and four assertions have been found that *could not fail*. An assertion
nobody has seen fail is a guess with a `check()` around it.

**When a rule is enforceable by a lint, write the lint.** The style-ownership
pass exists because "pick one font and use it everywhere" is exactly the kind of
convention that decays silently. So does the undeclared-global pass, and it
exists because a document could not have caught what it caught.

**An invariant in a document is not enforcement.** `HANDOFF_v5` §2 stated the
generator's contract precisely and completely; the assignment it described was
never written, and the belt ran at stock speed for two rounds. When you add an
entry to `docs/dev/INVARIANTS.md`, ask what would fail if it were violated — if
the answer is "nothing", that is the work, and the entry goes in that document's
`[nothing]` backlog until it is done.

**Graduate a feature by DELETING its flag, never by setting it true.** The
verifier asserts every `Config.Prototypes` flag ships `false`, so a prototype
flag is one you cannot turn on. The sharp edge is that every `if not P.Whatever`
guard left behind then reads `nil` forever — pass 4 catches that, and pass 2
catches the require you delete with it.

**Commit messages explain the why.** Look at `git log`: they name the defect,
the mechanism, and what was rejected. Match that.

**One `ScreenGui`.** `src/client/HUD.lua` owns it and hands out `HUD.root()` and
`HUD.overlay()`. A panel outside those layers is outside mobile scaling and
outside the safe area, and it fails that way silently, on a phone, looking fine
on the machine it was written on.

**When the verifier structurally cannot catch it, write it down.** It sees
`Config.lua` and nothing else; its `Vector3` is a bare table with no arithmetic;
it cannot reach frame ordering, AI behaviour, or how anything looks. Those go in
the round's handoff under "what only Studio can tell you" — and that list is
meant to be *answered*, not appended to. Two rounds asked the same question
about belt speed and got no answer; the third found the shipped number was a
third value neither round had guessed.

---

## Where to change what

| Want to… | Change | What catches a mistake |
| --- | --- | --- |
| add a dropper / upgrader / bat tier | a row in the relevant `Config.*Buttons` table | duplicate ids, dangling `requires`, slot collisions, upstream upgraders |
| retune the curve | `price` values | the economy simulation: build length band, per-purchase waits, the floor's position |
| move the belt | `Config.Layout.BeltStart/BeltCorner/BeltEnd` | `inPlot`, machine spacing, trigger dwell, drop budget |
| change the plot's walls or roof | `Tycoon.INSTALLERS.Structure`, `Config.Layout.Roof*`, `GateCentre/GateWidth` | the doorway span, the gateway vs the belt, deck-vs-roof clearance |
| change the second floor | `Config.Floors[1]` | the mezzanine family: deck vs walls, belt legs vs zone, hatch vs guard |
| add a UI panel | build into `HUD.root()`; geometry in `Config.UI` | one-ScreenGui, card-scale literals, the column fits at `MinScale` |
| add a persisted field | **both** `defaultProfile()` and the explicit `save()` payload in `DataService` | nothing — this is in the `[nothing]` backlog. With only the first it works all session and is gone at next login |
| add a wave behaviour | `Config.Waves` | wave part budget, clear time, aggro/leash relationships |
| add a new kind of buyable | a row in `Tycoon.INSTALLERS` | `KNOWN_KINDS` in `verify_config.lua` |

---

## What the tooling cannot see

Know these before you trust a green run.

- `tools/verify_config.lua` reads **only** `src/shared/Config.lua`. A defect in a
  builder is invisible to it — that is exactly how the generator shipped doing
  nothing for two rounds with six Config assertions covering it.
- `tools/test.py` runs a real subset of the game headless. **`SERVER_MODULES` in
  that file is the list**, and `NPCService`, `PlotService`, `UpgradeService`,
  `VaultService`, `FloorService`, `AdminService` and all of `src/client` are
  outside it. Widening it is real work and belongs in its own PR.
- A mock is a claim about Roblox that only Roblox can settle. Where the game
  depends on one, the handoff names it.
