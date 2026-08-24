#!/usr/bin/env python3
"""
verify.py — full pre-flight check for Tung Tung Tycoon.

    python3 tools/verify.py [--luau /path/to/luau] [--analyze /path/to/luau-analyze]

Runs SIXTEEN passes, in order. Keep this list and main() in step -- it has said
five, seven, eight and thirteen while main() ran nine, then fourteen, and a pass
count nobody can trust is a pass somebody can quietly delete. It was wrong again
when `ui colour` was added: the list had never carried `tycoon method
resolution` at all.

  1. syntax        every file in src/ and tools/testing/ compiles (luau-compile)
  2. analysis      luau-analyze, with the Roblox globals NAMED (see ROBLOX_GLOBALS)
                   rather than the whole "Unknown global" class waved through
  3. style         nothing but Style.lua names a font, an outline or a view distance
  4. prototypes    every Config.Prototypes flag read is a flag that exists
  5. config paths  every Config.<path> read in src/ names a key that exists
  6. module fields every UiKit.<field> and Style.Font.<face> read is one that exists
  7. mixin folders a split class's aggregator requires every file in its folder
  8. method res    a tycoon mixin does not shadow a method another mixin defines
  9. ui geometry   no card-scale literal in src/client; it comes from Config.UI
 10. ui colour     no Color3 literal in src/client; it comes from Config.UI.Role
 11. one screengui HUD.lua owns the only ScreenGui, so there is one UIScale
 12. design refs   every design:D-NN cited in source names a row in DECISIONS.md
 13. comment triage a long comment block declares which of the four homes it is
 14. config        the integrity suite in tools/verify_config.lua
 15. specs         the runtime specs in tools/testing, via tools/test.py
 16. packed build  regenerates build/ and syntax-checks the output

Exit code is non-zero if anything fails, so it drops straight into CI.
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

# luau-analyze has no Roblox type definitions, so these are expected noise.
IGNORED_ANALYSIS = re.compile(
    r"unknown require|Unknown type|could not be converted|"
    r"does not have key 'IsA'|does not have key 'FindFirstChild'"
)

# THE ROBLOX GLOBALS, NAMED RATHER THAN WAVED THROUGH.
#
# `Unknown global` used to be in the filter above, because luau-analyze has no
# Roblox definitions and reports every Vector3 and every Instance. Dropping the
# whole diagnostic class is what let `local UI = Config.UI` survive in a file
# whose `local Config = Req("Config")` had been deleted (#50, SessionUI.lua),
# together with two reads of a `compact` local deleted in the same hunk. Req
# re-raises a failed require and Main.client.lua requires SessionUI BEFORE it
# calls HUD.start(), so the whole client died at boot: no cash label, no
# NEXT UPGRADE panel, no toasts. The analyser had reported it, in as many words,
# once per read -- and the filter swallowed all three as noise.
#
# So the globals are listed. Anything not on this list is a real undeclared
# identifier: a deleted require, a typo, or a local removed with its uses left
# behind. Add a name here only when Roblox adds an API -- never to quiet a
# finding, because quieting a finding is what this list replaced.
ROBLOX_GLOBALS = frozenset(
    """
    game workspace script shared plugin
    Instance Enum Font BrickColor Random DateTime
    Vector2 Vector3 Vector2int16 Vector3int16 CFrame Color3 Color3uint8
    UDim UDim2 Rect Axes Faces Ray Region3 Region3int16 PathWaypoint
    NumberRange NumberSequence NumberSequenceKeypoint
    ColorSequence ColorSequenceKeypoint
    TweenInfo PhysicalProperties OverlapParams RaycastParams FloatCurveKey
    task warn tick time delay spawn wait typeof
    """.split()
)

UNKNOWN_GLOBAL = re.compile(r"Unknown global '(\w+)'")

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def sources():
    return sorted(p for p in SRC.rglob("*.lua"))


def harness_sources():
    """The spec harness. Compiled and analysed, but NOT style-linted.

    A mock is allowed to name an Enum.Font or assign a MaxDistance -- the style
    lint is about ownership inside the shipped game, and tools/ is not shipped.
    Syntax and analysis still apply: a mock that does not compile is worse than
    no mock, because it fails as a spec failure and reads as a game bug.
    """
    return sorted(p for p in (ROOT / "tools" / "testing").rglob("*.lua"))


def step(name):
    print(f"\n{DIM}──{RESET} {name}")


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", **kwargs)


def check_syntax(compiler, files, label):
    step(f"syntax: {label}")
    failed = 0
    for path in files:
        # --binary emits bytecode on stdout; we only care about stderr
        result = subprocess.run(
            [compiler, "--binary", str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
        )
        if result.returncode != 0 or result.stderr.strip():
            failed += 1
            print(f"  {RED}FAIL{RESET} {path.relative_to(ROOT)}")
            print("        " + result.stderr.strip().replace("\n", "\n        "))
    if failed == 0:
        print(f"  {GREEN}ok{RESET}  {len(files)} file(s) compile")
    return failed == 0


def check_analysis(analyzer, files):
    step("static analysis")
    result = run([analyzer, "--formatter=plain"] + [str(p) for p in files])
    findings = []
    for line in (result.stdout + result.stderr).splitlines():
        if not line.strip():
            continue
        unknown = UNKNOWN_GLOBAL.search(line)
        if unknown:
            name = unknown.group(1)
            if name in ROBLOX_GLOBALS:
                continue
            findings.append(
                (line, f"{name!r} is undeclared — was a require or a local deleted "
                       f"with its uses left behind?")
            )
            continue
        if IGNORED_ANALYSIS.search(line):
            continue
        findings.append((line, None))
    if findings:
        print(f"  {YELLOW}{len(findings)} finding(s){RESET}")
        for line, hint in findings:
            print("    " + line)
            if hint:
                print(f"      {DIM}{hint}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every global named is a Roblox global; nothing is undeclared")
    return True


# Fonts, outlines and view distances belong to src/shared/Style.lua and nowhere
# else. Before it existed every label picked its own as it was written, which is
# how the game ended up with three fonts, six outline settings and eleven view
# distances between 90 and 1200 studs. Nothing about that state was a decision,
# and nothing but a lint keeps it from happening again.
STYLE_OWNER = "src/shared/Style.lua"
STYLE_LITERALS = (
    (re.compile(r"Enum\.Font\."), "names a font"),
    (re.compile(r"\.TextStrokeTransparency\s*="), "sets an outline"),
    (re.compile(r"\.MaxDistance\s*="), "sets a view distance"),
)


def check_style(files):
    step("style ownership")
    findings = []
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        if rel == STYLE_OWNER:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            # A comment may say "MaxDistance"; only assignments are the problem.
            if line.lstrip().startswith("--"):
                continue
            # `gui.MaxDistance = maxDistance or Style.distance("plot")` is the
            # sanctioned form: the value still comes from the one owner.
            if "Style." in line:
                continue
            for pattern, what in STYLE_LITERALS:
                if pattern.search(line):
                    findings.append((rel, number, what, line.strip()))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, what, text in findings:
            print(f"    {rel}:{number} {what} directly — go through {STYLE_OWNER}")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  fonts, outlines and view distances all come from {STYLE_OWNER}")
    return True


# CARD-SCALE GEOMETRY BELONGS TO Config.UI.
#
# 80% of Roblox sessions are phones. A 470x330 card written as a literal in
# src/client is a number the verifier cannot see, cannot scale-check and cannot
# fit against the panel next to it -- which is exactly how the upgrade shop came
# to sit on top of the NEXT UPGRADE panel below 638 design pixels, with one of
# the two numbers in HUD.lua and the other in UpgradeUI.lua.
#
# Small offsets are none of this lint's business: an icon at 56x56 or a 5px
# accent bar is layout inside a card, not the card. The threshold is set at the
# size where a shape starts competing with other shapes for the screen.
UI_GEOMETRY_OWNER = "Config.UI."
UI_CARD_WIDTH, UI_CARD_HEIGHT = 300, 200
UI_GEOMETRY = re.compile(
    r"(UDim2\.fromOffset|Vector2\.new)\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)"
)


def client_sources(files):
    return [p for p in files if p.relative_to(ROOT).as_posix().startswith("src/client/")]


def check_ui_geometry(files):
    step("ui geometry")
    findings = []
    for path in client_sources(files):
        rel = path.relative_to(ROOT).as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            # `UDim2.fromOffset(UI.Modal.MaxWidth, 330)` is the sanctioned form:
            # the number still comes from the one place that can be asserted.
            if UI_GEOMETRY_OWNER in line:
                continue
            for match in UI_GEOMETRY.finditer(line):
                width, height = float(match.group(2)), float(match.group(3))
                if width >= UI_CARD_WIDTH and height >= UI_CARD_HEIGHT:
                    findings.append((rel, number, f"{width:g}x{height:g}", line.strip()))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, size, text in findings:
            print(f"    {rel}:{number} builds a {size} card from literals — name it in {UI_GEOMETRY_OWNER}")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every card-scale size in src/client comes from {UI_GEOMETRY_OWNER}")
    return True


# COLOUR IN src/client COMES FROM Config.UI.Role, AND FROM NOWHERE ELSE.
#
# UiKit.PALETTE was written out three times before it was merged, and the merge
# fixed the values while leaving nothing to stop a fourth copy. What actually
# grew back was worse than a fourth copy: twenty-six raw Color3 calls scattered
# across seven files, including three in MovementClient.lua for the only square,
# off-palette, wrong-font buttons in the game, and a `ko` toast colour sitting in
# a table whose other nine entries all read the palette.
#
# None of that was visible to anything. The style pass greps for Enum.Font,
# TextStrokeTransparency and MaxDistance; a colour is none of the three.
#
# The rule has teeth because the values now live in Config, where
# verify_config.lua holds every role against WCAG contrast on a composited card.
# A literal here is a colour outside that check -- so it is not merely
# inconsistent, it is unmeasured.
COLOUR_OWNER = "Config.UI.Role"
COLOUR_LITERAL = re.compile(r"Color3\s*\.\s*(fromRGB|new|fromHSV|fromHex)\s*\(")


def check_ui_colour(files):
    step("ui colour")
    findings = []
    for path in client_sources(files):
        rel = path.relative_to(ROOT).as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            if COLOUR_LITERAL.search(line):
                findings.append((rel, number, line.strip()))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, text in findings:
            print(f"    {rel}:{number} builds a colour from numbers — name a role in {COLOUR_OWNER}")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every colour in src/client resolves through {COLOUR_OWNER}")
    return True

# A FIELD READ OFF A MODULE TABLE MUST BE A FIELD THAT MODULE DEFINES.
#
# This is the shape of bug that survives everything else in this file. Pass 2
# names undeclared GLOBALS, and the thing that goes missing here is a key on a
# table. Pass 5 walks Config.<path> and stops there.
#
# It has now happened twice. `Style.Font.head` is read at five call sites and
# Style.lua defines `title` and `body` -- and because a nil value means the key
# never enters the props-table literal, UiKit.text's `for k, v in pairs(props)`
# loop never visits it and every heading in the shop, the help card and the
# rebirth report renders in the body face. Nothing errors, ever. Then the PR
# that moved the palette into Config deleted `UiKit.INK` and left three reads of
# it in HUD.lua, which WOULD have errored -- on the invite rail, on a device,
# after the change had shipped.
#
# The two owners here are the two that have failed. Widening this to every
# module means parsing every module's exports, and the honest limit is that a
# field assigned dynamically is invisible to it -- see INVARIANTS section 10.
FIELD_OWNERS = {
    "UiKit": "src/client/UiKit.lua",
    "Style": "src/shared/Style.lua",
}
# `Style.Font` is a table of faces rather than a flat field, and it is the one
# that shipped the defect, so its keys are collected as `Font.title` and read
# back the same way.
NESTED_TABLES = {("Style", "Font")}


def _defined_fields(path, module):
    text = path.read_text(encoding="utf-8")
    found = set()
    for match in re.finditer(rf"^(?:local\s+)?function\s+{module}\.(\w+)", text, re.M):
        found.add(match.group(1))
    for match in re.finditer(rf"^{module}\.(\w+)\s*=", text, re.M):
        found.add(match.group(1))
    for _, table in (p for p in NESTED_TABLES if p[0] == module):
        block = re.search(rf"^{module}\.{table}\s*=\s*\{{(.*?)^\}}", text, re.M | re.S)
        if block:
            for key in re.finditer(r"^\s*(\w+)\s*=", block.group(1), re.M):
                found.add(f"{table}.{key.group(1)}")
    return found


def check_module_fields(files):
    step("module fields")
    known = {}
    for module, rel in FIELD_OWNERS.items():
        path = ROOT / rel
        if not path.exists():
            print(f"  {RED}missing {rel}{RESET} — this pass names it as the owner of {module}.<field>")
            return False
        known[module] = _defined_fields(path, module)
        if not known[module]:
            print(f"  {RED}no fields parsed out of {rel}{RESET} — the file's shape changed and this pass went blind")
            return False

    findings = []
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        owner_of = {m: r for m, r in FIELD_OWNERS.items()}
        # Every module here opens with a --[[ ]] header that names the other
        # modules in prose, so block comments have to be skipped and not just
        # `--` lines. Line numbers are kept by blanking rather than dropping.
        in_block = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if in_block:
                if "]]" in line:
                    in_block = False
                continue
            if "--[[" in line:
                in_block = "]]" not in line.split("--[[", 1)[1]
                continue
            if line.lstrip().startswith("--"):
                continue
            for module, rel_owner in owner_of.items():
                if rel == rel_owner:
                    continue
                # `Config.Style.RaidSignHeight` is the Config table, not the Style
                # module. Anything with a dot or a word character in front of the
                # name is somebody else's field.
                for match in re.finditer(rf"(?<![\w.]){module}\.(\w+)(?:\.(\w+))?", line):
                    head, tail = match.group(1), match.group(2)
                    nested = f"{head}.{tail}" if tail and (module, head) in NESTED_TABLES else None
                    name = nested or head
                    if name not in known[module]:
                        findings.append((rel, number, module, name, rel_owner, line.strip()))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, module, name, rel_owner, text in findings:
            print(f"    {rel}:{number} reads {module}.{name}, which {rel_owner} does not define")
            print(f"      {DIM}{text}{RESET}")
        return False
    total = sum(len(v) for v in known.values())
    print(f"  {GREEN}ok{RESET}  every field read off {'/'.join(FIELD_OWNERS)} is one of the {total} they define")
    return True

# ONE ScreenGui MEANS ONE UIScale.
#
# HUD.lua builds the only ScreenGui in the game and hangs a Root and an Overlay
# layer off it, each carrying the UIScale that fits the design canvas to the
# device. A panel that makes its own ScreenGui is outside both, which means it
# is outside mobile scaling and outside the safe-area padding -- and it fails
# that way silently, on a phone, looking fine on the machine it was written on.
SCREENGUI_OWNER = "src/client/HUD.lua"
SCREENGUI = re.compile(r'Instance\.new\(\s*"ScreenGui"\s*\)')


def check_single_screengui(files):
    step("one screengui")
    findings = []
    for path in client_sources(files):
        rel = path.relative_to(ROOT).as_posix()
        if rel == SCREENGUI_OWNER:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            if SCREENGUI.search(line):
                findings.append((rel, number, line.strip()))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, text in findings:
            print(f"    {rel}:{number} builds a second ScreenGui — build into HUD.root() or HUD.overlay()")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  {SCREENGUI_OWNER} owns the only ScreenGui, so there is one UIScale")
    return True


# A CITED DESIGN DECISION MUST BE A DECISION THAT EXISTS.
#
# Product decisions live in GitHub issues under #72 and are mirrored in
# docs/design/. Code that needs to explain why a value is what it is cites the
# decision and stops:
#
#     -- design:D-03 -- the 6th most expensive spine price, rounded to 2 s.f.
#     PriceRung = 6,
#
# docs/design/DECISIONS.md is the index every id resolves against. A citation
# with no row behind it is the failure that actually happens -- a decision gets
# split, renumbered or superseded and the reader following the id lands nowhere
# -- so that one is caught. Whether a citation is APT cannot be checked by
# anything, and this pass does not pretend to.
#
# It reads docs/, so it is a lint over text and costs nothing. Scope is src/ and
# tools/: the verifier's own assertion messages carry more product policy than
# any single source file does, and a dangling id there is worse, because it is
# read at the moment somebody is arguing with the number.
DECISIONS_INDEX = "docs/design/DECISIONS.md"
DESIGN_REF = re.compile(r"design:(D-\d+)")
DESIGN_ROW = re.compile(r"^\|\s*`(D-\d+)`\s*\|", re.M)


def check_design_refs(files):
    step("design refs")
    index = ROOT / DECISIONS_INDEX
    if not index.is_file():
        print(f"  {RED}missing{RESET} {DECISIONS_INDEX} — every design:D-NN resolves against it")
        return False
    known = set(DESIGN_ROW.findall(index.read_text(encoding="utf-8")))
    if not known:
        print(f"  {RED}no rows{RESET} in {DECISIONS_INDEX} — the table shape changed and this lint went blind")
        return False

    findings = []
    cited = set()
    scanned = list(files) + sorted((ROOT / "tools").rglob("*.lua")) + sorted((ROOT / "tools").glob("*.py"))
    for path in scanned:
        rel = path.relative_to(ROOT).as_posix()
        if rel == "tools/verify.py":
            continue  # the examples in this file's own comments are not citations
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for ref in DESIGN_REF.findall(line):
                cited.add(ref)
                if ref not in known:
                    findings.append((rel, number, ref))
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, ref in findings:
            print(f"    {rel}:{number} cites {ref}, which is not a row in {DECISIONS_INDEX}")
        return False
    print(f"  {GREEN}ok{RESET}  {len(cited)} citation(s) against {len(known)} decision(s) in {DECISIONS_INDEX}")
    return True


# A LONG COMMENT BLOCK MUST SAY WHICH OF THE FOUR HOMES IT IS.
#
# docs/design/README.md: every paragraph in this project has exactly one home --
# an issue under #72 for product intent, INVARIANTS.md for a constraint with an
# enforcer named on it, a handoff for history, and the source file for mechanism.
# The rule for the source file is that a comment may say what the code does and
# what will break if you change it, and may not say why the game should be this
# way.
#
# This pass does not read the prose and cannot tell you the call was right. What
# it enforces is that somebody MADE the call: past BLOCK_LIMIT consecutive
# comment lines, the block opens by declaring itself.
#
#   design:D-NN   the reason lives in a decision; this is a pointer to it
#   invariant:    a constraint, and breaking it breaks something namable
#   mechanism:    what the code does
#
# The limit is a threshold rather than zero because a short comment is not where
# this goes wrong. Config.lua reached 2114 comment lines in 3933 -- 53% -- and
# the blocks that carried product arguments were the long ones, every time.
#
# The marker may sit anywhere in the block's first MARKER_WINDOW comment lines,
# so a banner rule above it still counts as part of the block.
BLOCK_LIMIT = 15
MARKER_WINDOW = 3
TRIAGE_MARKER = re.compile(r"^\s*--+\s*(design:D-\d+|invariant:|mechanism:)")
COMMENT_LINE = re.compile(r"^\s*--")


def check_comment_triage(files):
    step("comment triage")
    findings = []
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text(encoding="utf-8").split("\n")
        run, start = [], 0
        for number, line in enumerate(lines + [""], 1):
            if COMMENT_LINE.match(line):
                if not run:
                    start = number
                run.append(line)
                continue
            if len(run) > BLOCK_LIMIT and not any(
                TRIAGE_MARKER.match(l) for l in run[:MARKER_WINDOW]
            ):
                findings.append((rel, start, len(run), run[0].strip()))
            run = []
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, length, text in findings:
            print(f"    {rel}:{number} {length} comment lines with no design:/invariant:/mechanism: marker")
            print(f"      {DIM}{text[:78]}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every comment block over {BLOCK_LIMIT} lines declares which of the four homes it is")
    return True


# A MIXIN FOLDER'S AGGREGATOR MUST REQUIRE EVERY FILE IN IT.
#
# src/server/tycoon/ is one class split across twelve files: Class.lua builds the
# bare table and each mixin attaches its methods to it through Tycoon.__index.
# The aggregator's `Req("Belt")` lines are therefore load-bearing code, not
# imports — delete one and a dozen methods quietly stop existing.
#
# Nothing could see that. Pass 2 looks for undeclared identifiers, and the name
# that goes missing is a method on a table, not a local; pass 1 compiles a file
# nobody requires perfectly happily. The first symptom is a nil call in Studio,
# which is the same shape as the generator that shipped doing nothing for two
# rounds: a thing that reads as wired and is not.
#
# So the folder's file list and the aggregator's require list must be equal, and
# a new mixin that nobody added a line for fails the build instead of shipping
# dead. The reverse also fails: a require naming a file that no longer exists is
# a boot-time error in Roblox and a spec-bundle error in the harness.
MIXIN_FOLDERS = ("src/server/tycoon",)
MIXIN_REQ = re.compile(r'^\s*(?:local\s+\w+\s*=\s*)?Req\(\s*"(\w+)"\s*\)', re.M)


def check_mixin_folders():
    step("mixin folders")
    findings = []
    for folder in MIXIN_FOLDERS:
        directory = ROOT / folder
        name = Path(folder).name
        aggregator = directory / (name[0].upper() + name[1:] + ".lua")
        if not aggregator.exists():
            findings.append(f"{folder} has no aggregator at {aggregator.name}")
            continue
        text = aggregator.read_text(encoding="utf-8")
        # Strip the block header: it names the mixins in prose.
        body = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        required = set(MIXIN_REQ.findall(body))
        present = {p.stem for p in directory.glob("*.lua")} - {aggregator.stem}
        for missing in sorted(present - required):
            findings.append(
                f"{folder}/{missing}.lua is in the folder but {aggregator.name} does not "
                f"require it — its methods would silently not exist"
            )
        for absent in sorted(required - present):
            # A require may legitimately name a module elsewhere in src/ (Config,
            # Util); only a name that resolves nowhere is a finding.
            if any((ROOT / "src").rglob(f"{absent}.lua")):
                continue
            findings.append(
                f"{aggregator.name} requires {absent!r}, which resolves to no module — "
                f"Req raises at boot, and the spec bundle raises at load"
            )
    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for text in findings:
            print(f"    {text}")
        return False
    print(f"  {GREEN}ok{RESET}  every mixin in {'/'.join(MIXIN_FOLDERS)} is required by its aggregator")
    return True


# A METHOD CALL ON A CLASS TABLE IS A DYNAMIC LOOKUP, and deleting the method
# does not break the build — it breaks the first RUNTIME that reaches the call.
# That is not hypothetical: #108 deleted ensureCabinets and the constructor in
# Class.lua kept calling it, so Tycoon.new threw, PlotService.build died, the
# PlayerAdded wiring after it never ran, and every claim pad on main was dead
# with a green build. The harness never runs the real constructor (specs use
# metatable fakes), and the undeclared-global pass cannot see a method name.
#
# So: every `self:name(` call inside the mixin folder, and every `tycoon:name(`
# call anywhere in src/server, must resolve to a `function Tycoon:name` /
# `function Tycoon.name` definition somewhere in the mixin folder.
TYCOON_DEF = re.compile(r"^function\s+Tycoon[.:](\w+)\s*\(", re.M)
TYCOON_SELF_CALL = re.compile(r"self:(\w+)\s*\(")
TYCOON_VAR_CALL = re.compile(r"tycoon:(\w+)\s*\(")


def check_method_resolution(files):
    step("tycoon method resolution")
    mixin_dir = ROOT / "src" / "server" / "tycoon"
    defined = set()
    for path in sorted(mixin_dir.glob("*.lua")):
        defined |= set(TYCOON_DEF.findall(path.read_text(encoding="utf-8")))

    findings = []
    for path in sorted(mixin_dir.glob("*.lua")):
        text = _uncommented(path.read_text(encoding="utf-8"))
        for i, line in enumerate(text.split("\n"), 1):
            for name in TYCOON_SELF_CALL.findall(line):
                if name not in defined:
                    findings.append(
                        f"{path.relative_to(ROOT)}:{i} calls self:{name}() and no mixin defines it — "
                        f"the first runtime to reach this line throws on a nil method"
                    )
    for path in sorted((ROOT / "src" / "server").glob("*.lua")):
        text = _uncommented(path.read_text(encoding="utf-8"))
        for i, line in enumerate(text.split("\n"), 1):
            for name in TYCOON_VAR_CALL.findall(line):
                if name not in defined:
                    findings.append(
                        f"{path.relative_to(ROOT)}:{i} calls tycoon:{name}() and no mixin defines it"
                    )

    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for text in findings:
            print(f"    {text}")
        return False
    print(f"  {GREEN}ok{RESET}  every self:/tycoon: method call resolves to a mixin definition")
    return True


# A GRADUATED FEATURE'S FLAG IS DELETED, NOT SET FALSE — see FloorService.lua and
# verify_config.lua's "prototypes ship off" family. That is the right convention
# and it has one sharp edge: every `if not P.Whatever` guard left behind reads as
# nil, so `not nil` is true and the guard fires FOREVER.
#
# That is not hypothetical. Offline earnings graduated and VaultService kept three
# P.Offline guards, so VaultService.start() returned before wiring anything and the
# vault gauge was dead on main with a green build. SessionUI had the same defect and
# only survived because its file happened to conflict during the merge and a human
# read it. The two branches never conflicted with the graduation, because they
# touched different files — which is exactly why prose could not catch this.
PROTO_OWNER = "src/shared/Config.lua"
PROTO_TABLE = re.compile(r"Config\.Prototypes\s*=\s*\{(.*?)\n\}", re.S)
PROTO_KEY = re.compile(r"^\s*(\w+)\s*=", re.M)
PROTO_BIND = re.compile(r"^local\s+(\w+)\s*=\s*Config\.Prototypes\s*$", re.M)


def check_prototypes(files):
    step("prototype flags")
    source = (ROOT / PROTO_OWNER).read_text(encoding="utf-8")
    table = PROTO_TABLE.search(source)
    if not table:
        print(f"  {RED}FAIL{RESET} could not find Config.Prototypes in {PROTO_OWNER}")
        return False
    declared = set(PROTO_KEY.findall(table.group(1)))

    findings = []
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        if rel == PROTO_OWNER:
            continue
        text = path.read_text(encoding="utf-8")
        # Only a local actually bound to Config.Prototypes counts. DataService
        # binds `local P = Config.Persistence`, and P.AutosaveSeconds is fine.
        aliases = set(PROTO_BIND.findall(text)) | {"Config.Prototypes"}
        pattern = re.compile(
            r"\b(?:" + "|".join(re.escape(a) for a in aliases) + r")\.(\w+)")
        # Block comments matter here: every file that graduated a flag explains
        # itself in a --[[ ]] header that names the flag it deleted.
        in_block = False
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.lstrip()
            if in_block:
                if "]]" in line:
                    in_block = False
                continue
            if stripped.startswith("--[["):
                if "]]" not in stripped[4:]:
                    in_block = True
                continue
            if stripped.startswith("--"):
                continue
            for name in pattern.findall(line.split("--")[0]):
                if name not in declared:
                    findings.append((rel, number, name, line.strip()))

    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, name, text in findings:
            print(f"    {rel}:{number} reads Prototypes.{name}, which no longer exists —")
            print(f"      a graduated flag is nil, so this guard fires forever")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every prototype flag read is a flag that exists")
    return True


# EVERY Config.<path> READ NAMES A KEY THAT EXISTS.
#
# `PathTopY = Config.World.PathTopY` sat in the distinct-surface-heights check
# for two rounds. There is no PathTopY. The read was nil, so the entry never
# entered the table it was written into, pairs() never visited it, and a check
# that read as covering four surfaces covered three -- its own
# `type(y) == "number"` guard could not fire on a key that was not there. In Lua
# a misspelled key is not an error: it is nil, and nil is a value that every code
# path short of arithmetic is happy to carry to the end of the round.
#
# The prototypes lint above is this lint restricted to one table. This one walks
# the whole of Config.lua, and the ALIASES are the point: almost nothing reads
# `Config.Layout.BeltY` directly, it reads `L.BeltY` after `local L =
# Config.Layout`, so a lint that cannot follow that binding covers nothing worth
# the pass. Two shapes matter beyond the obvious one -- two-deep bindings
# (`local BTN = Config.Style.Button`) and scalar bindings
# (`local SHOP_ON = Config.Prototypes.PlayerUpgrades`, a boolean, which must
# never be treated as a table prefix).
#
# IT SKIPS WHAT IT CANNOT RESOLVE, ALWAYS. See config_index for the rules. A
# false positive here is what turns a pass into a pass somebody deletes, so an
# unresolvable parent means silence, not a finding.
CONFIG_OWNER = "src/shared/Config.lua"
# `Config.a.b = ...` anywhere: the table literals up top and the derived
# assignments at the bottom of Config.lua both match.
CONFIG_ASSIGN = re.compile(r"\bConfig((?:\.\w+)+)\s*=(?!=)")
CONFIG_FUNCTION = re.compile(r"\bfunction\s+Config[.:](\w+)")
# `Config.ButtonById[def.id] = def` -- a table filled through a computed key.
CONFIG_DYNAMIC = re.compile(r"\bConfig((?:\.\w+)+)\s*\[")
CONFIG_KEY = re.compile(r"([A-Za-z_]\w*)\s*=(?!=)")
# `local L = Config.Layout` / `local BTN = Config.Style.Button`, and nothing
# else on the line: `local FLOOR = Config.Floors and Config.Floors[1]` binds an
# element, not the table, and must not become a prefix.
CONFIG_ALIAS = re.compile(r"^[ \t]*local\s+(\w+)\s*=\s*Config((?:\.\w+)+)[ \t]*$", re.M)
CONFIG_REQUIRE = re.compile(r"^[ \t]*local\s+Config\s*=", re.M)


def _unshadowed(text, name):
    """True when `name` is bound once in the file and nothing rebinds it.

    Nothing in src/ shadows an alias today -- all twenty-one are bound once at
    the head of their file. The guard is here so that the first `local W` inside a
    function, or the first `function f(L)`, costs this lint its coverage of that
    name rather than costing it its credibility with a finding about a local that
    was never Config's.
    """
    escaped = re.escape(name)
    bindings = re.findall(rf"^[ \t]*local\b[^\n=]*\b{escaped}\b", text, re.M)
    parameters = re.findall(rf"\bfunction\b[^\n(]*\([^)\n]*\b{escaped}\b", text)
    loops = re.findall(rf"\bfor\b[^\n]*\b{escaped}\b[^\n]*\bin\b", text)
    return len(bindings) == 1 and not parameters and not loops


def _uncommented(text):
    """Config.lua with its comments and its string bodies removed.

    Both matter to a brace-counting parser: a `--[[ ]]` header naming a deleted
    key would be read as a declaration, and a `"{"` in a label would unbalance
    everything after it.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        char = text[i]
        if char in "\"'":
            out.append(char)
            i += 1
            while i < n and text[i] != char:
                i += 2 if text[i] == "\\" else 1
            i += 1
            out.append(char)
            continue
        if text.startswith("--", i):
            if text.startswith("--[[", i):
                end = text.find("]]", i)
                i = n if end < 0 else end + 2
            else:
                end = text.find("\n", i)
                i = n if end < 0 else end
            continue
        out.append(char)
        i += 1
    return "".join(out)


def _past_bracket(text, start):
    """Index just past the bracket that closes the one opened at `start`."""
    closers = {"{": "}", "(": ")", "[": "]"}
    stack, i = [closers[text[start]]], start + 1
    while i < len(text) and stack:
        char = text[i]
        if char in closers:
            stack.append(closers[char])
        elif char == stack[-1]:
            stack.pop()
        i += 1
    return i


def config_index(text):
    """Every key path Config.lua declares, and which of them are exhaustive.

    Returns (known, closed). `known` is the set of dotted paths that exist.
    `closed` is the subset whose key set is believed COMPLETE -- the only paths a
    missing child may be reported against. Everything else is skipped.

    A path is closed when its value is a table literal parsed to its matching
    brace, written with named keys only, and never written into through a
    computed key. That deliberately leaves out:

      * arrays and arrays of tables -- Config.Floors, Config.Bats,
        Config.FactoryButtons. They are read as `Config.Floors[1].button`, which
        this lint stops at the bracket anyway.
      * anything built in a loop -- Config.Buttons, Config.ButtonById,
        Config.TrackRank, Config.BatById. CONFIG_DYNAMIC opens them back up.
      * any value that is not a literal: `Config.World.PlotCount =
        Config.plotCountFor()` exists, but what it holds is not visible here, so
        no child of it is ever reported.

    Keys added through a local alias inside Config.lua are picked up too --
    `local ui = Config.UI` followed by `ui.ShopPanel.X = ...` declares
    Config.UI.ShopPanel.X, and eight of the UI layout numbers arrive that way.
    """
    source = _uncommented(text)
    known, closed = set(), set()

    def parse_table(body, prefix):
        """Collect this table's own keys. False if it holds unnamed entries."""
        named, i = True, 0
        while i < len(body):
            char = body[i]
            if char in "{([":
                # A `{...}` at this table's own depth is an array element and a
                # `[k] =` is a key this parser does not read, so either way the
                # table stops being a namespace whose keys are all accounted for.
                named = named and char == "("
                i = _past_bracket(body, i)
                continue
            match = CONFIG_KEY.match(body, i)
            if not match:
                i += 1
                continue
            path = f"{prefix}.{match.group(1)}"
            known.add(path)
            rest = match.end()
            while rest < len(body) and body[rest] in " \t\r\n":
                rest += 1
            if rest < len(body) and body[rest] == "{":
                end = _past_bracket(body, rest)
                if parse_table(body[rest + 1:end - 1], path):
                    closed.add(path)
                i = end
            else:
                i = match.end()
        return named

    for match in CONFIG_ASSIGN.finditer(source):
        path = "Config" + match.group(1)
        segments = path.split(".")
        for depth in range(2, len(segments) + 1):
            known.add(".".join(segments[:depth]))
        rest = match.end()
        while rest < len(source) and source[rest] in " \t\r\n":
            rest += 1
        if rest < len(source) and source[rest] == "{":
            end = _past_bracket(source, rest)
            if parse_table(source[rest + 1:end - 1], path):
                closed.add(path)

    for match in CONFIG_FUNCTION.finditer(source):
        known.add("Config." + match.group(1))

    for name, path in CONFIG_ALIAS.findall(source):
        target = "Config" + path
        if target not in closed:
            continue
        for match in re.finditer(rf"\b{re.escape(name)}((?:\.\w+)+)\s*=(?!=)", source):
            segments = (target + match.group(1)).split(".")
            for depth in range(2, len(segments) + 1):
                known.add(".".join(segments[:depth]))

    # A table anything writes into by computed key is open by definition: the
    # keys it ends up holding are not in this file's text.
    for match in CONFIG_DYNAMIC.finditer(source):
        closed.discard("Config" + match.group(1))

    return known, closed


def check_config_paths(files):
    step("config paths")
    known, closed = config_index((ROOT / CONFIG_OWNER).read_text(encoding="utf-8"))
    if not closed:
        print(f"  {RED}FAIL{RESET} resolved no tables at all in {CONFIG_OWNER}")
        return False

    findings = []
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        if rel == CONFIG_OWNER:
            continue
        text = path.read_text(encoding="utf-8")
        # Only a binding to a table whose keys are all accounted for can be a
        # prefix: `local SHOP_ON = Config.Prototypes.PlayerUpgrades` binds a
        # boolean, and SHOP_ON.anything is not a config read at all.
        prefixes = {name: "Config" + at for name, at in CONFIG_ALIAS.findall(text)
                    if "Config" + at in closed and _unshadowed(text, name)}
        # A file with no `local Config` has no Config to read; a name that only
        # looks like one is an undeclared global, which is pass 2's finding.
        if CONFIG_REQUIRE.search(text):
            prefixes["Config"] = "Config"
        if not prefixes:
            continue
        # Longest name first so BTN_LOCKED is not read as BTN.
        pattern = re.compile(
            r"\b(" + "|".join(re.escape(n) for n in sorted(prefixes, key=len, reverse=True))
            + r")((?:\.\w+)+)")

        in_block = False
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.lstrip()
            if in_block:
                if "]]" in line:
                    in_block = False
                continue
            # A --[[ ]] header is where a graduated key gets explained, by name,
            # after it was deleted -- exactly the text this lint must not read.
            if stripped.startswith("--[["):
                if "]]" not in stripped[4:]:
                    in_block = True
                continue
            if stripped.startswith("--"):
                continue
            for name, tail in pattern.findall(line.split("--")[0]):
                at = prefixes[name]
                for segment in tail.split(".")[1:]:
                    child = f"{at}.{segment}"
                    if child in known:
                        at = child
                        continue
                    if at in closed:
                        findings.append((rel, number, child, line.strip()))
                    break

    if findings:
        print(f"  {RED}{len(findings)} finding(s){RESET}")
        for rel, number, child, text in findings:
            print(f"    {rel}:{number} reads {child}, which {CONFIG_OWNER} does not declare —")
            print(f"      a misspelled key is nil, not an error, so nothing here will fail")
            print(f"      {DIM}{text}{RESET}")
        return False
    print(f"  {GREEN}ok{RESET}  every Config.<path> read in src/ names a key {CONFIG_OWNER} declares")
    return True


def check_config(luau):
    step("config integrity")
    harness = (ROOT / "tools" / "verify_config.lua").read_text(encoding="utf-8")

    marker = re.search(r"^\s*--@INJECT (.+)$", harness, re.MULTILINE)
    if not marker:
        print(f"  {RED}FAIL{RESET} verify_config.lua is missing its --@INJECT marker")
        return False

    injected = (ROOT / marker.group(1).strip()).read_text(encoding="utf-8")
    harness = harness[: marker.start()] + injected + harness[marker.end():]

    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
        f.write(harness)
        temp = f.name

    result = run([luau, temp])
    output = (result.stdout + result.stderr).strip()
    for line in output.splitlines():
        print("  " + line)
    Path(temp).unlink(missing_ok=True)
    return result.returncode == 0


def check_specs(luau):
    """Execute the game, rather than the numbers it is configured with.

    This is the pass that answers a sentence appearing in five consecutive
    handoffs: "nothing in this round has run in Roblox". The config suite below
    reads Config.lua and nothing else, so a defect living in a .lua file rather
    than in a number is structurally invisible to it -- which is exactly how the
    generator shipped for two rounds multiplying nothing.
    """
    step("runtime specs")
    result = run([sys.executable, str(ROOT / "tools" / "test.py"), "--plain", "--luau", luau])
    output = (result.stdout + result.stderr).strip()
    for line in output.splitlines():
        print("  " + line)
    return result.returncode == 0


def check_pack(compiler):
    step("packed build")
    result = run([sys.executable, str(ROOT / "tools" / "pack.py")])
    print(("  " + result.stdout.strip()).replace("\n", "\n  "))
    if result.returncode != 0:
        print(f"  {RED}FAIL{RESET} {result.stderr.strip()}")
        return False
    built = sorted((ROOT / "build").glob("*.lua"))
    return check_syntax(compiler, built, "packed output")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--luau", default=shutil.which("luau") or "luau")
    parser.add_argument("--compile", default=shutil.which("luau-compile") or "luau-compile")
    parser.add_argument("--analyze", default=shutil.which("luau-analyze") or "luau-analyze")
    args = parser.parse_args()

    for tool in (args.luau, args.compile, args.analyze):
        if not shutil.which(tool) and not Path(tool).exists():
            print(f"{RED}missing tool:{RESET} {tool}")
            print("get it from https://github.com/luau-lang/luau/releases")
            return 2

    files = sources()
    harness = harness_sources()
    results = [
        check_syntax(args.compile, files + harness, "src + harness"),
        check_analysis(args.analyze, files + harness),
        # style ownership is about the SHIPPED game; tools/ is not shipped
        check_style(files),
        check_prototypes(files),
        check_config_paths(files),
        check_module_fields(files),
        check_mixin_folders(),
        check_method_resolution(files),
        check_ui_geometry(files),
        check_ui_colour(files),
        check_single_screengui(files),
        check_design_refs(files),
        check_comment_triage(files),
        check_config(args.luau),
        # The config suite must report first: a broken Config makes every spec
        # fail in a confusing way, and the useful error is the one upstream.
        check_specs(args.luau),
        check_pack(args.compile),
    ]

    print()
    if all(results):
        print(f"{GREEN}ALL CHECKS PASSED{RESET}")
        return 0
    print(f"{RED}CHECKS FAILED{RESET}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
