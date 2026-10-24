#!/usr/bin/env python3
"""Textee CLI for agents: status, open tabs, scratch files, and the textee:// actions. Python 3 standard library, runs on Python 3.9.

Reads ~/.textee/live.json, which the running app rewrites on every tab change (TEXTEE_HOME moves it), and the
scratch folder ~/txt (TEXTEE_TXT_DIR). Commands that change something go through the app (textee:// URLs, opened
in the background), so only the app writes files. Every command takes --json
(agent interface: ~/ai/.claude/skills/appee/references/agent-interface.md).

    textee status                # running, open tabs, unsaved tabs, newest scratch file
    textee tabs                  # the open tabs: path, unsaved, active
    textee scratches [-n 10]     # the newest scratch files in ~/txt
    textee new                   # a new empty scratch file, in a new tab
    textee new-from-clipboard    # a new scratch file with the clipboard text (Alfred `ca`)
    textee open <path>           # open a file in a tab
    textee save-all              # save every unsaved tab
    textee show                  # bring the Textee window to the front
    textee describe --json       # what Textee can do, for agents
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.parse
import uuid
from datetime import datetime
from pathlib import Path

HOME = Path(os.path.expanduser(os.environ.get("TEXTEE_HOME", "~/.textee")))
LIVE = HOME / "live.json"
TXT = Path(os.path.expanduser(os.environ.get("TEXTEE_TXT_DIR", "~/txt")))
APP = Path("/Applications/Textee.app")
OPEN_TOOL = os.environ.get("TEXTEE_OPEN_TOOL", "/usr/bin/open")
JSON = False

COMMANDS = [
    ("describe", "textee describe --json", "What Textee can do, for agents", "read", False),
    ("status", "textee status --json", "Running, open tabs, unsaved tabs, conflicts, newest scratch file", "read", False),
    ("tabs", "textee tabs [-n 50] --json", "The open tabs: path, unsaved, conflict, active", "read", True),
    ("scratches", "textee scratches [-n 10] --json", "The newest scratch files in ~/txt: path, modified_at, bytes", "read", False),
    ("new", "textee new [--show] --json", "Create an empty scratch file in ~/txt and open it in a new tab", "write", True),
    ("new-from-clipboard", "textee new-from-clipboard [--show] --json", "Create a scratch file with the clipboard text and open it", "write", True),
    ("open", "textee open <path> [--show] --json", "Open a file in a tab (or select its tab)", "write", True),
    ("save-all", "textee save-all --json", "Save every unsaved tab", "write", True),
    ("show", "textee show --json", "Bring the Textee window to the front (takes the screen)", "write", True),
]


def emit(data: dict, human: str = "") -> int:
    """Print the result: 1 JSON document with --json, else the human line."""
    if JSON:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    elif human:
        print(human)
    return 0


def fail(error: str, hint: str = "", code: int = 1) -> int:
    print(f"❌ {error}" + (f" {hint}" if hint else ""), file=sys.stderr)
    if JSON:
        print(json.dumps({"ok": False, "error": error, "hint": hint}, ensure_ascii=False))
    return code


def iso(ts: float | None) -> str | None:
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds") if ts else None


def read_live() -> dict:
    try:
        with open(LIVE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def installed_pid() -> int | None:
    """The pid of /Applications/Textee.app when it runs without live.json (a build before 1.0.1). Real home only."""
    if "TEXTEE_HOME" in os.environ:
        return None
    r = subprocess.run(["pgrep", "-f", str(APP / "Contents/MacOS/Textee")], capture_output=True, text=True)
    pids = [int(x) for x in r.stdout.split() if x.isdigit()]
    return pids[0] if pids else None


def app_version() -> str:
    try:
        with open(APP / "Contents/Info.plist", "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString", "")
    except (OSError, plistlib.InvalidFileException):
        return ""


def scratch_files(n: int) -> tuple:
    """The newest n scratch files (path, mtime, size), and whether there were more."""
    try:
        files = [p for p in TXT.iterdir() if p.is_file() and not p.name.startswith(".")]
    except OSError:
        return [], False
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return [(str(p), p.stat().st_mtime, p.stat().st_size) for p in files[:n]], len(files) > n


def send(action: str, params: dict | None = None, wait: float = 3.0) -> dict:
    """Open textee://<action> in the background and wait until live.json echoes the request id."""
    live = read_live()
    if not pid_alive(live.get("pid")):
        if installed_pid():
            return {"ok": False, "error": "This Textee build doesn't confirm actions", "hint": "Install Textee 1.0.1 or later: ./build.sh --install", "code": 1}
        return {"ok": False, "error": "Textee isn't running", "hint": "Start it: open -a Textee", "code": 4}
    rid = uuid.uuid4().hex[:12]
    query = urllib.parse.urlencode({**(params or {}), "rid": rid})
    # -a the running copy: a QA or build copy of Textee may also claim textee:// in LaunchServices.
    target = ["-a", live["bundle_path"]] if live.get("bundle_path") else []
    if subprocess.run([OPEN_TOOL, "-g", *target, f"textee://{action}?{query}"]).returncode != 0:
        return {"ok": False, "error": f"open textee://{action} failed", "hint": "", "code": 1}
    deadline = time.time() + wait
    while time.time() < deadline:
        last = read_live().get("last_action") or {}
        if last.get("rid") == rid:
            if not last.get("ok"):
                return {"ok": False, "error": f"Textee couldn't run '{action}'", "hint": "Check the Textee status bar", "code": 1}
            return {"ok": True, "confirmed": True, "action": action}
        time.sleep(0.05)
    return {"ok": False, "error": f"Textee didn't confirm '{action}' within {wait:.0f} s", "hint": "Check that Textee 1.0.1 or later runs", "code": 1}


def run_action(action: str, params: dict | None, human: str, with_path: bool = False) -> int:
    r = send(action, params)
    if not r["ok"]:
        return fail(r["error"], r.get("hint", ""), r.get("code", 1))
    tabs = read_live().get("tabs") or []
    r["tabs"] = len(tabs)
    r["unsaved"] = sum(1 for t in tabs if t.get("unsaved"))
    if with_path:
        r["path"] = read_live().get("active_path")
        human = f"{human}: {r['path']}" if r["path"] else human
    return emit(r, human)


def cmd_describe(args: argparse.Namespace) -> int:
    data = {
        "contract": 1, "app": "textee", "name": "Textee", "version": app_version(),
        "summary": "Native macOS text editor and clipboard scratchpad (replaces TextMate)", "kind": "macos-app",
        "bundle_id": "com.nicolasdeville.textee", "url_scheme": "textee", "port": None, "home": "~/.textee",
        "hotkeys": [{"keys": "⇧⌘N", "does": "New scratch file from the clipboard"},
                    {"keys": "⌘N", "does": "New empty scratch file"},
                    {"keys": "⌘P", "does": "Quick open"}],
        "commands": [{"name": n, "usage": u, "does": d, "effect": e, "needs_app": a} for n, u, d, e, a in COMMANDS],
        "privacy": "status prints counts only. tabs and scratches print file paths, never file contents.",
    }
    if JSON:
        return emit(data)
    for n, u, d, e, a in COMMANDS:
        print(f"{u:<44} {d}{'' if e == 'read' else f'  ({e})'}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    live = read_live()
    running = pid_alive(live.get("pid"))
    pid = live.get("pid") if running else installed_pid()
    tabs = (live.get("tabs") or []) if running else []
    newest, _ = scratch_files(1)
    data = {
        "ok": True, "app": "textee", "running": bool(pid), "pid": pid,
        "version": (live.get("version") if running else None) or app_version(),
        "live": running,
        "tabs": len(tabs) if running else None,
        "unsaved": sum(1 for t in tabs if t.get("unsaved")) if running else None,
        "conflicts": sum(1 for t in tabs if t.get("conflict")) if running else None,
        "newest_scratch": newest[0][0] if newest else None,
        "newest_scratch_at": iso(newest[0][1]) if newest else None,
        "scratch_dir": str(TXT), "home": str(HOME),
    }
    if not pid:
        human = "⏹  not running"
    elif not running:
        human = f"✅ running (pid {pid}), no live state: Textee {data['version']} predates the agent interface"
    else:
        human = f"✅ running, {data['tabs']} tabs, {data['unsaved']} unsaved" + (f", {data['conflicts']} conflicts" if data["conflicts"] else "")
    return emit(data, human)


def cmd_tabs(args: argparse.Namespace) -> int:
    live = read_live()
    if not pid_alive(live.get("pid")):
        return fail("Textee isn't running, or doesn't publish its tabs", "Start Textee 1.0.1 or later: open -a Textee", 4)
    tabs = live.get("tabs") or []
    shown = tabs[: max(args.n, 1)]
    if JSON:
        return emit({"ok": True, "count": len(tabs), "tabs": shown, "more": len(tabs) > len(shown)})
    for t in shown:
        flags = ("● " if t.get("unsaved") else "  ") + ("▶ " if t.get("active") else "  ")
        print(f"{flags}{t.get('path')}" + ("  (conflict)" if t.get("conflict") else ""))
    if len(tabs) > len(shown):
        print(f"… {len(tabs) - len(shown)} more")
    return 0


def cmd_scratches(args: argparse.Namespace) -> int:
    files, more = scratch_files(max(args.n, 1))
    if JSON:
        return emit({"ok": True, "scratch_dir": str(TXT), "more": more,
                     "files": [{"path": p, "modified_at": iso(m), "bytes": b} for p, m, b in files]})
    for p, m, b in files:
        print(f"{datetime.fromtimestamp(m):%d %b %H:%M}  {b:>9,} B  {p}")
    return 0


def show_params(args: argparse.Namespace) -> dict:
    return {"show": "1"} if getattr(args, "show", False) else {}


def cmd_new(args: argparse.Namespace) -> int:
    return run_action("new", show_params(args), "📝 New scratch", with_path=True)


def cmd_new_from_clipboard(args: argparse.Namespace) -> int:
    return run_action("new-from-clipboard", show_params(args), "📋 New scratch from the clipboard", with_path=True)


def cmd_open(args: argparse.Namespace) -> int:
    path = Path(os.path.expanduser(args.path)).resolve()
    if not path.is_file():
        return fail(f"No file at {path}", "Give the path of an existing file")
    return run_action("open", {"path": str(path), **show_params(args)}, "📂 Opened", with_path=True)


def cmd_save_all(args: argparse.Namespace) -> int:
    return run_action("save-all", None, "💾 Every tab saved")


def cmd_show(args: argparse.Namespace) -> int:
    return run_action("show", {"show": "1"}, "🪟 Textee in front")


def main() -> int:
    global JSON
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="print 1 JSON document (for agents)")
    p = argparse.ArgumentParser(prog="textee", description="Textee text editor: status, tabs, scratch files, actions.", parents=[common])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("describe", parents=[common], help="what Textee can do, for agents").set_defaults(func=cmd_describe)
    sub.add_parser("status", parents=[common], help="running, tabs, unsaved tabs").set_defaults(func=cmd_status)
    t = sub.add_parser("tabs", parents=[common], help="the open tabs")
    t.add_argument("-n", type=int, default=50)
    t.set_defaults(func=cmd_tabs)
    s = sub.add_parser("scratches", parents=[common], help="the newest scratch files")
    s.add_argument("-n", type=int, default=10)
    s.set_defaults(func=cmd_scratches)
    for name, func, text in (("new", cmd_new, "a new empty scratch file"),
                             ("new-from-clipboard", cmd_new_from_clipboard, "a new scratch file with the clipboard text")):
        a = sub.add_parser(name, parents=[common], help=text)
        a.add_argument("--show", action="store_true", help="bring Textee to the front")
        a.set_defaults(func=func)
    o = sub.add_parser("open", parents=[common], help="open a file in a tab")
    o.add_argument("path")
    o.add_argument("--show", action="store_true", help="bring Textee to the front")
    o.set_defaults(func=cmd_open)
    sub.add_parser("save-all", parents=[common], help="save every unsaved tab").set_defaults(func=cmd_save_all)
    sub.add_parser("show", parents=[common], help="bring the window to the front").set_defaults(func=cmd_show)
    args = p.parse_args()
    JSON = args.json
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
