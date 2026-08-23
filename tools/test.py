#!/usr/bin/env python3
"""
test.py — runs the headless spec suite.

    python3 tools/test.py [--filter offline] [--luau PATH] [--plain] [--keep]

WHY THIS EXISTS. Five consecutive handoffs open with "nothing in this round has
run in Roblox". The verifier covers Config against Config; it cannot execute a
line of game code. So every defect that lives in a .lua file rather than in a
number has shipped unchallenged -- see the generator, whose income multiplier
was asserted six ways in Config and never assigned in Tycoon.

HOW IT WORKS. The standalone luau CLI has no `io` library, so Lua cannot read
src/ itself; and its `require` is path-based, so the canonical

    local Req = require(game:GetService(...):WaitForChild("Req"))

cannot resolve -- the argument is an Instance, not a string. Both problems are
already solved by tools/pack.py, which rewrites that exact line and wraps every
module in a closure table. This file is a SECOND CONSUMER of that machinery: it
concatenates the mocks, the real src/ modules and the specs into one Lua chunk
and runs it under `luau`.

That reuse is deliberate and load-bearing. It means the specs execute through
the same flattening the paste-in build uses, so a pack.py regression surfaces
here as failing tests rather than as a build/ nobody reads.
"""

from pathlib import Path
import argparse
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack  # noqa: E402  -- the bootstrap rewrite must break in lockstep with the packer

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
TESTING = ROOT / "tools" / "testing"

# The modules the harness executes. Deliberately NOT the whole tree: NPCService
# and PlotService need Region3, Touched and a physics step -- an order of
# magnitude more mock, for services no round has graduated yet -- and
# UpgradeService, VaultService, FloorService and AdminService are simply not in
# the list. Widening it is a real piece of work and should be its own PR, not a
# quiet addition to someone else's.
#
# Tycoon, MapBuilder and CombatService ARE in it. The comment here used to say
# the opposite, two lines above the list that contradicted it.
SERVER_MODULES = ["DataService", "Analytics", "Economy", "SessionService", "SocialService", "MovementService",
                  "HelpService", "PartyService", "RaidService", "RecallService", "TowerService", "DisclosureService", "ShopService", "CombatService", "MapBuilder", "Tycoon"]

# ALL OF src/client, WHICH HAD NEVER EXECUTED ANYWHERE BUT ROBLOX.
#
# That absence is half of why the headline defect of this round shipped:
# SessionUI.lua evaluated `Config.UI` at module scope with its
# `local Config = Req("Config")` deleted, Req re-raises a failed require, and
# Main.client.lua requires SessionUI BEFORE it calls HUD.start() -- so the whole
# HUD was dead at boot for two rounds with a green CI. The other half was the
# analysis pass waving through the "Unknown global" class, which is closed now
# (see ROBLOX_GLOBALS in tools/verify.py). A LINT CATCHES AN UNDECLARED
# IDENTIFIER; IT DOES NOT CATCH A MODULE THAT RAISES FOR ANY OTHER REASON, and
# a require-only smoke over this list does.
#
# The list is EXHAUSTIVE and client_sources() fails the run if a file in
# src/client is missing from it -- the point of a boot smoke is that it covers
# everything that boots, and a new panel nobody added a line for is exactly the
# file that would be dead on arrival.
#
# Main.client.lua is in it, as CLIENT_ENTRY. It is a script rather than a
# module, so requiring it BOOTS the client: that is the boot order itself under
# test, in the file that owns it, rather than a spec's imitation of it.
#
# WHAT STILL CANNOT RUN, and it is more than the server's exclusions. The mock
# is a property bag, not a renderer: it resolves no UDim2 against a parent, so
# nothing here can see a panel overlap another one (that is
# tools/verify_config.lua's job and stays there). No tween advances, so
# HUD.toast and both modals are unreachable. The viewport never changes after
# boot, so rotation and resize are unreachable. RunService still answers
# IsServer() == true, so Net takes its server branch and the client's
# WaitForChild-for-a-remote path is unreachable. Every one of those is named,
# with what it costs, in tools/testing/mock/gui.lua's header.
# Main.client.lua IS in this list, and it is the only entry script the harness
# loads as a module. pack.py treats a `.client` stem as an entry point, but the
# bundle can hand it a Req like any other module -- and requiring it is what makes
# the client's BOOT ORDER covered rather than transcribed into a spec that would
# not notice a reordering.
CLIENT_MODULES = ["UiKit", "HUD", "CombatClient", "MovementClient", "PartyUI", "ShopUI", "UpgradeUI", "SessionUI", "Main.client"]
CLIENT_ENTRY = "Main.client"

# Mocks load in dependency order: the clock underpins everything, and the
# roblox facade hands out services the others define -- including gui's, which
# it requires directly rather than being handed.
MOCKS = ["clock", "vector3", "instance", "datastore", "players", "gui", "roblox"]

PRELUDE = """--!nolint
-- GENERATED by tools/test.py. Not written to disk except as a temp file.

local __MODULES = {}

--- A REALM is one independent load of the module tree: its own Config table,
--- its own DataService upvalues, its own SessionService state. The mock world
--- underneath is shared, which is exactly what lets two realms race one
--- DataStore key in the session-locking specs.
local function __newRealm()
\tlocal cache, loading = {}, {}
\tlocal function req(name)
\t\tlocal cached = cache[name]
\t\tif cached ~= nil then
\t\t\treturn cached
\t\tend
\t\tif loading[name] then
\t\t\terror("[Tung] circular dependency while loading " .. tostring(name), 2)
\t\tend
\t\tlocal factory = __MODULES[name]
\t\tif not factory then
\t\t\terror("[Tung] module not found in spec bundle: " .. tostring(name), 2)
\t\tend
\t\tloading[name] = true
\t\tlocal value = factory(req)
\t\tloading[name] = nil
\t\tcache[name] = value
\t\treturn value
\tend
\treturn req
end

"""


def module_block(name: str, source: str) -> str:
    """Same shape as pack.module_block, but the factory TAKES the requirer.

    pack.py can rewrite the bootstrap to a single global `__Req` because a
    packed build is one game with one module cache. The harness runs several
    REALMS over one Lua state, so `Req` arrives as a function parameter and the
    bootstrap line is deleted rather than rewritten -- rewriting it to
    `local Req = __Req` would shadow the parameter with a global that does not
    exist here.

    The REGEX is still pack.BOOTSTRAP, deliberately. If anyone changes the
    canonical import line, the packer and the harness must break together
    rather than one of them silently drifting.
    """
    body = pack.BOOTSTRAP.sub("-- Req: supplied by the harness realm", source)
    return f'__MODULES["{name}"] = function(Req)\n{pack.indent(body)}\nend\n\n'


def server_sources():
    """SERVER_MODULES by name, wherever the module actually lives.

    A module that has outgrown one file becomes a FOLDER of modules -- see
    src/server/tycoon/ -- and the name in SERVER_MODULES does not change,
    because Req resolves a NAME and searches one level of folder nesting.

    WHEN THE NAME RESOLVES INSIDE A FOLDER, THE WHOLE FOLDER COMES WITH IT. The
    aggregator requires its mixins through the realm's `req`, which can only
    hand back a module this bundle registered, so listing the aggregator alone
    would fail at load with "module not found in spec bundle: Class" -- and it
    would fail inside the first spec that touches a plot, reading like a game
    bug rather than a missing file.
    """
    out, seen = [], set()
    for name in SERVER_MODULES:
        direct = SRC / "server" / f"{name}.lua"
        nested = sorted((SRC / "server").rglob(f"{name}.lua"))
        siblings = [direct] if direct.exists() or not nested \
            else sorted(nested[0].parent.glob("*.lua"))
        for path in siblings:
            if path not in seen:
                seen.add(path)
                out.append((path.stem, path))
    return out


def client_sources():
    """CLIENT_MODULES by name, and nothing in src/client may be left out.

    A file in the folder that is not in the list would be a client module the
    boot smoke never requires -- which is the exact hole the smoke was written
    to fill. So it is an error rather than a silence, and the message names the
    list to add it to.

    ENTRY SCRIPTS ARE EXEMPT, and there is one: Main.client.lua. pack.py treats a
    `.client`/`.server` stem as an entry point rather than a module, Req cannot
    resolve it, and the bundle has nowhere to put it. What that costs is written
    above CLIENT_MODULES.
    """
    out = []
    for name in CLIENT_MODULES:
        out.append((name, SRC / "client" / f"{name}.lua"))
    listed = {path for _, path in out}
    for path in sorted((SRC / "client").glob("*.lua")):
        if path.stem.endswith(".client") or path.stem.endswith(".server"):
            continue
        if path not in listed:
            raise SystemExit(
                f"{path.relative_to(ROOT)} is not in CLIENT_MODULES: add it, so the "
                f"boot smoke in tools/testing/specs/hud_spec.lua requires it")
    return out


def client_manifest():
    """The client module list, as a module the spec bundle can read.

    Lua cannot see src/client, so a spec that smokes "every client module" would
    otherwise hold a second copy of the list -- and the copy that goes stale is
    always the one that decides what is covered. Generated from the list above
    instead, so a module added to CLIENT_MODULES is smoked by the spec that
    already exists.
    """
    names = ", ".join(f'"{name}"' for name in CLIENT_MODULES if name != CLIENT_ENTRY)
    return (f"return {{\n\tmodules = {{ {names} }},\n"
            f"\tentry = {CLIENT_ENTRY!r},\n}}\n").replace("'", '"')


def collect_sources(spec_filter=None):
    """Returns [(module_name, path)] in load order."""
    out = []
    for name in MOCKS:
        out.append((name, TESTING / "mock" / f"{name}.lua"))
    for name in ("runner", "world"):
        out.append((name, TESTING / f"{name}.lua"))

    for path in sorted((SRC / "shared").glob("*.lua")):
        if path.stem != "Req":
            out.append((path.stem, path))
    out.extend(server_sources())
    out.extend(client_sources())

    for path in sorted((TESTING / "specs").glob("*_spec.lua")):
        if spec_filter and spec_filter not in path.stem:
            continue
        out.append((path.stem, path))
    return out


def build_bundle(spec_filter=None, plain=False):
    """Returns (lua_source, line_map) where line_map is [(first_line, name)]."""
    chunks = [PRELUDE]
    line_map = []
    line = PRELUDE.count("\n") + 1

    sources = collect_sources(spec_filter)
    specs = []
    for name, path in sources:
        if not path.exists():
            raise SystemExit(f"missing harness file: {path.relative_to(ROOT)}")
        block = module_block(name, path.read_text(encoding="utf-8"))
        # +1 for the `__MODULES[...] = function(Req)` line the block opens with
        line_map.append((line + 1, name, path))
        chunks.append(block)
        line += block.count("\n")
        if name.endswith("_spec"):
            specs.append(name)

    # The one module in the bundle with no file behind it. Attributed to this
    # file in the line map, which is where it is written and where a wrong one
    # would be fixed.
    manifest = module_block("clients", client_manifest())
    line_map.append((line + 1, "clients", Path(__file__).resolve()))
    chunks.append(manifest)
    line += manifest.count("\n")

    if not specs:
        raise SystemExit("no specs matched")

    # The boot realm loads only harness modules. Game modules load inside
    # T.world()'s realm, so each spec gets its own Config and its own
    # DataService upvalues.
    boot = ['local __req = __newRealm()', 'local __T = __req("runner")']
    boot.append(f'__T.plain = {"true" if plain else "false"}')
    boot.append('__T.newRealm = __newRealm')
    boot.append('__T.clients = __req("clients")')
    boot.append('__req("world").install(__T, __req)')
    for name in specs:
        boot.append(f'__T.load({name!r}, __req)')
    boot.append('__T.report()')
    chunks.append("\n".join(boot) + "\n")

    return "".join(chunks), line_map


def make_trace_re(tmp_path: str):
    """Luau reports either the temp file's path or a [string "..."] chunk."""
    return re.compile(
        r'(?:' + re.escape(tmp_path) + r'|\[string "[^"]*"\]):(\d+)'
    )


def map_traceback(text: str, line_map, tmp_path: str) -> str:
    """Rewrite bundle line numbers back to real files.

    Without this every stack trace points into a 9,000-line temp file and the
    harness is unusable in practice -- which is the difference between a suite
    people run and a suite people delete.
    """
    def repl(match):
        n = int(match.group(1))
        best = None
        for start, name, path in line_map:
            if start <= n:
                best = (start, path)
            else:
                break
        if not best:
            return match.group(0)
        start, path = best
        try:
            rel = path.relative_to(ROOT)
        except ValueError:
            rel = path
        return f"{rel}:{n - start + 1}"

    return make_trace_re(tmp_path).sub(repl, text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default=None, help="only run specs whose name contains this")
    ap.add_argument("--luau", default="luau")
    ap.add_argument("--plain", action="store_true", help="no ANSI colour")
    ap.add_argument("--keep", action="store_true", help="print the bundle path instead of deleting it")
    args = ap.parse_args()

    source, line_map = build_bundle(args.filter, args.plain)

    tmp = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8")
    tmp.write(source)
    tmp.close()

    try:
        result = subprocess.run([args.luau, tmp.name], capture_output=True, text=True)
    except FileNotFoundError:
        print(f"missing tool: {args.luau}")
        return 2
    finally:
        if args.keep:
            print(f"  bundle kept at {tmp.name}")
        else:
            Path(tmp.name).unlink(missing_ok=True)

    out = map_traceback(result.stdout + result.stderr, line_map, tmp.name).rstrip()
    if out:
        print(out)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
