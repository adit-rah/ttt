#!/usr/bin/env python3
"""
verify.py — full pre-flight check for Tung Tung Tycoon.

    python3 tools/verify.py [--luau /path/to/luau] [--analyze /path/to/luau-analyze]

Runs, in order:
  1. syntax check on every source file (luau-compile)
  2. static analysis, ignoring the Roblox globals luau-analyze can't know about
  3. style ownership: no file but Style.lua names a font, outline or view distance
  4. UI ownership: no card-scale literal in src/client, and one ScreenGui
  5. the Config integrity suite in tools/verify_config.lua
  6. the runtime specs in tools/testing
  7. regenerates the packed build and syntax-checks that too

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
    r"Unknown global|unknown require|Unknown type|could not be converted|"
    r"does not have key 'IsA'|does not have key 'FindFirstChild'"
)

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
    lines = [
        line for line in (result.stdout + result.stderr).splitlines()
        if line.strip() and not IGNORED_ANALYSIS.search(line)
    ]
    if lines:
        print(f"  {YELLOW}{len(lines)} finding(s){RESET}")
        for line in lines:
            print("    " + line)
        return False
    print(f"  {GREEN}ok{RESET}  no findings outside the Roblox-global noise")
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
        check_ui_geometry(files),
        check_single_screengui(files),
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
