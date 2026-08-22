# CLAUDE.md — how to work in this repo

A Roblox tycoon, all Lua, no uploaded assets: every model is built from
primitives at runtime. `README.md` is for a human who wants to play it. This is
for whoever has to change it.

**Read `docs/dev/ARCHITECTURE.md` for the module map and
`docs/dev/INVARIANTS.md` before you touch code.** Between them they replace the
six handoff documents you would otherwise have to read to find out what is
load-bearing. The handoffs are history; those two are the contract.

**Read `docs/design/README.md` before you write a comment explaining why.** The
product decisions are not in this repo's code; they are in
[#72](https://github.com/adit-rah/ttt/issues/72) and its five pillars, mirrored
in `docs/design/`.

---

## How to write in this repo

Be concise, be direct, and get the information out for the least reading effort
it can be got out in. This applies to prose, commit messages, issues, docs and
code comments.

**Never use antithesis.** No "it's not X, it's Y", no "not a preference, a
fact", no "X rather than Y" as a rhetorical frame. The reader has to hold a
negation and a correction to extract one fact, and that costs understanding
time. State what is true and stop.

```
bad   The cap is not an opinion, it is a platform fact.
good  The platform enforces the cap.

bad   It arrives as an event, not a transaction.
good  It builds over 5.2 seconds while you watch.
```

Antithesis belongs in speeches and advertising. Assume the reader is competent
and in a hurry.

---

## The one rule about what goes where

> **A comment may say what the code does and what will break if you change it.
> It may not say why the game should be this way.**

Every paragraph in this project has exactly one home:

| Destination | What goes there |
| --- | --- |
| an issue under [#72](https://github.com/adit-rah/ttt/issues/72), then `docs/design/` | product intent — what the player should experience, and why |
| `docs/dev/INVARIANTS.md` | an engineering constraint, carrying the marker naming what enforces it |
| `docs/dev/HANDOFF_v*.md` | history — what a value used to be, and why it moved |
| the source file | mechanism — what this value *does*, in a line or two |

The test is whether the sentence would survive a rewrite of the code. "The pad
costs what the 6th most expensive spine rung costs" describes this
implementation and stays. "The session should end on a choice rather than on
being finished" is true of the game however it is built — that is a design
decision, and it lives in `D-05`.

Where a value is what it is *because of* a decision, cite it and stop:

```lua
-- design:D-03 — the 6th most expensive spine price, rounded to 2 s.f.
PriceRung = 6,
```

`docs/design/DECISIONS.md` is the index every `D-NN` resolves against, and the
verifier fails the build on one that does not appear there.

This rule exists because the intent was real and homeless, so it went to the
four places that would take it: code comments (`Config.lua` was 53% comment),
the verifier's assertion message strings, a gitignored research file, and two
orphaned documents nothing linked to. A decision you can only find by reading a
Lua table is a decision nobody can review, disagree with, or supersede.

---

## The three commands

```bash
python3 tools/verify.py            # eleven passes, and it regenerates build/. Run before every commit.
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
| decide something about the game rather than the code | a sub-issue of [#72](https://github.com/adit-rah/ttt/issues/72), then its `docs/design/` mirror and a row in `DECISIONS.md` — **never a comment** | the design-reference lint refuses a `design:D-NN` with no row behind it; nothing catches intent written into a comment except a reader |
| add a dropper / upgrader / bat tier | a row in the relevant `Config.*Buttons` table | duplicate ids, dangling `requires`, slot collisions, upstream upgraders |
| retune the curve | `price` values | the economy simulation: build length band, per-purchase waits, the floor's position |
| move the belt | `Config.Layout.BeltStart/BeltCorner/BeltEnd` | `inPlot`, machine spacing, trigger dwell, drop budget |
| change the plot's walls or roof | `Config.Structure` (`WallHeight`, `Openings`, `Window`), `GateCentre/GateWidth`; the builder is `buildWallRing` in `src/server/tycoon/Installers.lua`; the PURCHASES are `Config.StructureButtons` | the doorway span, the gateway vs the belt, openings staying on the centre span, the part budget at every land state |
| retune how walls and gates break | `Config.Structure.Health` | monotone health in level, wall out-lasts gate, no one-swing gate, a maxed gate breaks inside 90 s, repair inside the raid warning |
| buy the plot more ground | a row pair in `Config.LandLButtons`/`LandRButtons` — widths mirror, prices interleave | the land family: shrinking widths, the 2.5× sum, the pricing margins, the simulated buy order alternating, and the per-state shell checks |
| change what the room is lit by | `Config.Structure.Lights` | fixtures inside the ring, above the machines and the cabinet signs, `Range` under Roblox's silent 60 clamp, and a sampled coverage check per land state |
| change the belt's guard rails | `Config.Layout.BeltGuard` | a leg's rail may not overlap another leg's running surface — set `corner` to 0 and watch the deleted rails' bug come back |
| add a UI panel | build into `HUD.root()` — or `HUD.column()` if it belongs in the left stack — via `UiKit.dock`; geometry in `Config.UI` | one-ScreenGui, card-scale literals, the column fits at `MinScale` |
| put anything near a screen edge | a `UiKit.dock` corner; `Config.UI.TouchReserve` if it is near the bottom | the reserve assertions — both bottom corners are the engine's thumbstick and jump button |
| add a persisted field | **both** `defaultProfile()` and the explicit `save()` payload in `DataService` | nothing — this is in the `[nothing]` backlog. With only the first it works all session and is gone at next login |
| add a wave behaviour | `Config.Waves` | wave part budget, clear time, aggro/leash relationships |
| retune the mob bands or the plot raids | `Config.Mobs.Bands`, `Config.PlotWave`, `plotWaveLevel` | the open-world family: bands contiguous and weaker outward, roamer reach short of the belt, the spawn outside every band's notice, the world part ceiling, and the siren + breach-floor promise |
| retune the raid economics | `Config.Raid` | the raid family: the recovery promise, the empty-unit bounty floor, kill under spill, camping decay — plus `raid_spec`'s ledger arithmetic |
| add a kindness trigger, or retune its reward | a call into `HelpService.credit`; `Config.Help` | the help family: the boost stays a nudge, the pair cooldown outlasts the boost, the gap weight caps — plus `help_spec` |
| add a new kind of buyable | a case in `src/server/tycoon/Installers.lua`, **and** the `kind` list in `tycoon/Tycoon.lua`'s header | `KNOWN_KINDS` in `verify_config.lua`. The header list is checked by nobody — it is the copy to do by hand |
| reorder the factory ladder | move the ROW in `Config.FactoryButtons`; never add a `requires` | the chain-equals-table-order assertion, plus the economy simulation. The 60-minute credit cap binds before `MAX_TOTAL_MINUTES` does |
| reorder the plot shell | move the ROW in `Config.StructureButtons` — a PARALLEL track gated on `dropper1`, not part of the factory chain | the same chain assertion, plus `roof` needs `walls` and `gates`/`windows` need `walls` |
| gate one purchase on another ladder | `Config.ButtonUnlock` — never a cross-track `requires`, which the loader overwrites and the verifier refuses | the reachability fixpoint (it catches gate cycles the `requires` walk cannot), the gate's price order, and the roof-names-a-roof structural check |
| add a track | a row in **each** of `TrackOrder`, `Tracks` and `TrackInfo` | `TRACK_FIELDS` completeness, `keepOnRebirth == (furniture == "cabinet")`, and `paced` — which the spine simulation and `spinePricesDescending` both read, so a track is walked or priced as a detour by that field alone. `TrackOrder` POSITION sets `TrackRank`, which is what the beacon and the HUD card rank by; nothing can assert that a beacon points somewhere useful |

---

## What the tooling cannot see

Know these before you trust a green run.

- `tools/verify_config.lua` reads **only** `src/shared/Config.lua`. A defect in a
  builder is invisible to it — that is exactly how the generator shipped doing
  nothing for two rounds with six Config assertions covering it.
- `tools/test.py` runs a real subset of the game headless. **`SERVER_MODULES` in
  that file is the list**, and `NPCService`, `PlotService`, `UpgradeService`,
  `VaultService`, `FloorService` and `AdminService` are outside it. Widening it is
  real work and belongs in its own PR. All of `src/client` IS inside it — see
  `CLIENT_MODULES`, which `client_sources()` fails the run to keep exhaustive —
  but what executes there is behaviour, never layout: the GUI mock stores a
  `UDim2` and never resolves it, so no rectangle in this game has ever been
  measured against another one outside `verify_config.lua`.
- A mock is a claim about Roblox that only Roblox can settle. Where the game
  depends on one, the handoff names it.
