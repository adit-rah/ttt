#!/usr/bin/env python3
"""
verify.py — full pre-flight check for Tung Tung Tycoon.

    python3 tools/verify.py [--luau /path/to/luau] [--analyze /path/to/luau-analyze]

Runs, in order:
  1. syntax check on every source file (luau-compile)
  2. static analysis, ignoring the Roblox globals luau-analyze can't know about
  3. the Config integrity suite in tools/verify_config.lua
  4. regenerates the packed build and syntax-checks that too

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
    results = [
        check_syntax(args.compile, files, "src"),
        check_analysis(args.analyze, files),
        check_config(args.luau),
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
