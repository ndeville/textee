#!/usr/bin/env python3
"""Textee against 4 other Mac text editors: speed and memory, measured from outside every app the same way.

Apps: Textee, TextMate, CotEditor, Sublime Text and TextEdit, each with Nic's own settings and no session restore.
Nic's running Textee and TextMate stay untouched: the benchmark runs copies of both with their own bundle ids
("Textee Bench" with its own config folder, "TextMate Bench" with Nic's TextMate preferences copied in).
CotEditor, Sublime Text and TextEdit run from where they are installed, so they must not be running.
What the run changes (recent documents, Sublime's session, window sizes, Amethyst's floating list) is put back at
the end.

    python3 bench.py               # 7 rounds, about 20 minutes
    python3 bench.py --rounds 3
    python3 bench_chart.py         # then draw bench/editors.svg from the results

Writes bench/results.json and prints a table. Round 1 is a warm-up and is left out of the medians.
"""

import argparse
import json
import os
import plistlib
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROBE_SRC = ROOT / "bench" / "appprobe.swift"
PROBE = ROOT / "build.noindex" / "appprobe"
WORK = Path(tempfile.gettempdir()) / "textee-bench"
REAL_TXT = Path.home() / "txt"


def signing_identity() -> str:
    """The identity build.sh uses: $TEXTEE_SIGN_IDENTITY, else .private/signing.env, else ad hoc ("-")."""
    if os.environ.get("TEXTEE_SIGN_IDENTITY"):
        return os.environ["TEXTEE_SIGN_IDENTITY"]
    env = Path(__file__).resolve().parent / ".private" / "signing.env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.startswith("TEXTEE_SIGN_IDENTITY="):
                return line.split("=", 1)[1].strip().strip('"')
    return "-"



TEXTEE = Path("/Applications/Textee.app")
TEXTEE_COPY = WORK / "Textee Bench.app"
TEXTEE_BENCH_ID = "com.nicolasdeville.textee.bench"
TEXTEE_HOME = WORK / "textee-home"

TEXTMATE = Path("/Applications/TextMate.app")
TM_COPY = WORK / "TextMate Bench.app"
TM_BENCH_ID = "com.macromates.TextMate.bench"
TM_SUPPORT = Path.home() / "Library/Application Support/TextMate"

SUBL_DATA = Path.home() / "Library/Application Support/Sublime Text"
SUBL_BACKUP = SUBL_DATA.with_name("Sublime Text.textee-bench-backup")

RECENTS = Path.home() / "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
RECENT_PREFIXES = ("com.apple.textedit.", "com.coteditor.coteditor.", "com.sublimetext.4.")
RECENT_BENCH_PREFIXES = ("com.nicolasdeville.textee.bench.", "com.macromates.textmate.bench.")

# Every app ignores its saved windows, as Textee (no session restore) and Nic's TextMate settings do.
NO_RESTORE = ["--args", "-ApplePersistenceIgnoreState", "YES"]

# Every app opens its window at 1920 x 1080: memory and layout work grow with the window, and Amethyst had left
# CotEditor at 2160 x 3809 and TextEdit at 673 x 439. TextEdit sizes its window in characters: 284 x 79 is 1920 x 1076.
FRAME = "3840 41 1920 1080 3840 41 1920 1080 "
WINDOW_PREFS = [
    # domain, key, value, defaults type
    (TEXTEE_BENCH_ID, "NSWindow Frame TexteeMain", FRAME, "-string"),
    (TM_BENCH_ID, "DocumentControllerWindowFrame", "{{3840, 41}, {1920, 1080}}", "-string"),
    ("com.coteditor.CotEditor", "NSWindow Frame Document", FRAME, "-string"),
    ("com.apple.TextEdit", "WidthInChars", "284", "-int"),
    ("com.apple.TextEdit", "HeightInChars", "79", "-int"),
]
AMETHYST = "com.amethyst.Amethyst"


@dataclass
class App:
    name: str
    path: Path
    open_pre: list = field(default_factory=list)

    @property
    def size_mb(self) -> float:
        source = {TEXTEE_COPY: TEXTEE, TM_COPY: TEXTMATE}.get(self.path, self.path)
        return int(sh("du", "-sk", str(source)).split()[0]) / 1024


APPS = [
    App("Textee", TEXTEE_COPY, ["--env", f"TEXTEE_HOME={TEXTEE_HOME}"]),
    App("TextMate", TM_COPY),
    App("CotEditor", Path("/Applications/CotEditor.app")),
    App("Sublime Text", Path("/Applications/Sublime Text.app")),
    App("TextEdit", Path("/System/Applications/TextEdit.app")),
]


def sh(*args: str, check: bool = True) -> str:
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout


def probe(app: App, *args: str) -> dict:
    env = {**os.environ, "PROBE_OPEN_PRE": json.dumps(app.open_pre), "PROBE_OPEN_POST": json.dumps(NO_RESTORE)}
    out = subprocess.run([str(PROBE), *args], check=True, capture_output=True, text=True, env=env).stdout
    return json.loads(out.strip().splitlines()[-1])


def build_probe() -> None:
    if not PROBE.exists() or PROBE.stat().st_mtime < PROBE_SRC.stat().st_mtime:
        print("🛠  compiling appprobe")
        PROBE.parent.mkdir(exist_ok=True)
        sh("swiftc", "-O", str(PROBE_SRC), "-o", str(PROBE))


def rebrand(app: Path, bundle_id: str, name: str) -> None:
    """New bundle id and name, no document or URL types: the copy must never become a handler for anything."""
    info = app / "Contents/Info.plist"
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleIdentifier"] = bundle_id
    plist["CFBundleName"] = name
    plist.pop("CFBundleDocumentTypes", None)
    plist.pop("CFBundleURLTypes", None)
    with open(info, "wb") as f:
        plistlib.dump(plist, f)


def make_textee_copy(force: bool = False) -> None:
    """A copy of the installed Textee (or of --textee), signed like the original, with its own config folder."""
    if not force and TEXTEE_COPY.exists() and TEXTEE_COPY.stat().st_mtime >= TEXTEE.stat().st_mtime:
        return
    print("📦 copying Textee.app to a bench copy")
    shutil.rmtree(TEXTEE_COPY, ignore_errors=True)
    shutil.copytree(TEXTEE, TEXTEE_COPY, symlinks=True)
    rebrand(TEXTEE_COPY, TEXTEE_BENCH_ID, "Textee Bench")
    sh("codesign", "--force", "--options", "runtime", "--preserve-metadata=entitlements", "-s", signing_identity(), str(TEXTEE_COPY))
    TEXTEE_HOME.mkdir(parents=True, exist_ok=True)
    state = Path.home() / ".textee/state.json"
    if state.exists():
        shutil.copy(state, TEXTEE_HOME / "state.json")  # Nic's zoom, wrap and line-number settings


def make_textmate_copy() -> None:
    if TM_COPY.exists():
        return
    print("📦 copying TextMate.app to a bench copy")
    shutil.copytree(TEXTMATE, TM_COPY, symlinks=True)
    rebrand(TM_COPY, TM_BENCH_ID, "TextMate Bench")
    sh("codesign", "--force", "--deep", "-s", "-", str(TM_COPY))
    # Nic's TextMate settings (font size, theme, no new document at launch, no session restore).
    prefs = sh("defaults", "export", "com.macromates.TextMate", "-")
    subprocess.run(["defaults", "import", TM_BENCH_ID, "-"], input=prefs, text=True, check=True)


def make_fixtures() -> dict:
    files = WORK / "files"
    if files.exists():
        shutil.rmtree(files)
    files.mkdir(parents=True)
    small = files / "scratch.txt"
    shutil.copy(REAL_TXT / "261012-155313.txt", small)  # 2 KB, an LLM answer: a typical `ca` file
    # 10 typical scratch files: the 10 newest between 300 bytes and 20 KB.
    candidates = sorted((p for p in REAL_TXT.glob("26*.txt") if 300 < p.stat().st_size < 20_000),
                        key=lambda p: p.stat().st_mtime, reverse=True)[:10]
    ten = []
    for i, p in enumerate(candidates):
        dst = files / f"tab{i}.txt"
        shutil.copy(p, dst)
        ten.append(str(dst))
    big = files / "big.txt"
    sh("cp", "-c", str(REAL_TXT / "250503-101225.txt"), str(big))  # 22 MB
    md = files / "big.md"
    md.write_text("".join(
        f"## Section {i}\n\nText with **bold** and `code` and a [link](https://x.com/{i}).\n\n```\nfenced {i}\n```\n"
        for i in range(20000)), encoding="utf-8")
    return {"small": str(small), "ten": ten, "big": str(big), "md": str(md)}


def descendants(pid: int) -> list:
    out = []
    for child in sh("pgrep", "-P", str(pid), check=False).split():
        out += [int(child)] + descendants(int(child))
    return out


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def kill(pid: int) -> None:
    """Ends the app and its child processes (Sublime Text's plugin hosts)."""
    pids = [pid] + descendants(pid)
    for p in pids:
        try:
            os.kill(p, 15)
        except ProcessLookupError:
            pass
    for _ in range(100):
        if not any(alive(p) for p in pids):
            return
        time.sleep(0.05)
    for p in pids:
        try:
            os.kill(p, 9)
        except ProcessLookupError:
            pass


def running(app: App) -> list:
    with open(app.path / "Contents/Info.plist", "rb") as f:
        exe = app.path / "Contents/MacOS" / plistlib.load(f)["CFBundleExecutable"]
    return [int(p) for p in sh("pgrep", "-f", f"^{exe}", check=False).split()]


def snapshot_textmate_state() -> dict:
    keys = set()
    db = TM_SUPPORT / "RecentProjects.db"
    if db.exists():
        with sqlite3.connect(db) as c:
            keys = {r[0] for r in c.execute("select key from kvdb")}
    session = (TM_SUPPORT / "Session/Info.plist").read_bytes() if (TM_SUPPORT / "Session/Info.plist").exists() else None
    return {"keys": keys, "session": session}


def restore_textmate_state(snap: dict) -> None:
    """Removes what the bench copy added to TextMate's shared files. Writes in place: Nic's TextMate keeps them open."""
    db = TM_SUPPORT / "RecentProjects.db"
    if db.exists():
        with sqlite3.connect(db) as c:
            for (k,) in list(c.execute("select key from kvdb")):
                if k not in snap["keys"]:
                    c.execute("delete from kvdb where key = ?", (k,))
    if snap["session"] is not None:
        with open(TM_SUPPORT / "Session/Info.plist", "wb") as f:
            f.write(snap["session"])


def sublime_bench_data() -> None:
    """Nic's Sublime Text data folder with an empty session and session restore off. The original waits aside.

    The session keeps Nic's window frame and nothing else: Sublime Text then opens a 1920 x 1081 window, the same
    size as the others. Without a session it opens 800 x 629.
    """
    if SUBL_BACKUP.exists():
        sys.exit(f"❌ {SUBL_BACKUP} exists: a previous run didn't restore it. Check it, then move it back.")
    SUBL_DATA.rename(SUBL_BACKUP)
    sh("cp", "-cR", str(SUBL_BACKUP), str(SUBL_DATA))
    session = json.loads((SUBL_BACKUP / "Local/Session.sublime_session").read_text(encoding="utf-8"))
    for old in (SUBL_DATA / "Local").glob("*.sublime_session"):
        old.unlink()
    window = session["windows"][0]
    window["buffers"] = []
    window["groups"] = [{"sheets": []}]
    session["windows"] = [window]
    (WORK / "sublime-session.json").write_text(json.dumps(session), encoding="utf-8")
    prefs = SUBL_DATA / "Packages/User/Preferences.sublime-settings"
    text = prefs.read_text(encoding="utf-8").rstrip().rstrip("}")
    prefs.write_text(text + '\t"hot_exit": "disabled",\n\t"remember_open_files": false,\n\t"update_check": false,\n}\n',
                     encoding="utf-8")


def sublime_restore() -> None:
    if not SUBL_BACKUP.exists():
        return
    shutil.rmtree(SUBL_DATA, ignore_errors=True)
    SUBL_BACKUP.rename(SUBL_DATA)


def pin_windows() -> None:
    """Sets every app's window to 1920 x 1080 before a launch: apps save a new frame when something moves them."""
    for domain, key, value, kind in WINDOW_PREFS:
        sh("defaults", "write", domain, key, kind, value)
    shutil.copy(WORK / "sublime-session.json", SUBL_DATA / "Local/Session.sublime_session")


def snapshot_window_prefs() -> dict:
    snap = {}
    for domain, key, _, _ in WINDOW_PREFS:
        if domain not in (TEXTEE_BENCH_ID, TM_BENCH_ID):
            r = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True)
            snap[(domain, key)] = plistlib.loads(r.stdout).get(key)
    return snap


def restore_window_prefs(snap: dict) -> None:
    for (domain, key), value in snap.items():
        if value is None:
            sh("defaults", "delete", domain, key, check=False)
        else:
            sh("defaults", "write", domain, key, "-int" if isinstance(value, int) else "-string", str(value))


def amethyst_floating(extra: list) -> list:
    """Adds apps to Amethyst's floating list, so it doesn't tile their windows. Returns the list as it was."""
    r = subprocess.run(["defaults", "export", AMETHYST, "-"], capture_output=True, check=False)
    if r.returncode or not r.stdout:
        return []
    before = plistlib.loads(r.stdout).get("floating", [])
    set_amethyst_floating(before + [{"id": i, "window-titles": []} for i in extra])
    return before


def set_amethyst_floating(entries: list) -> None:
    sh("defaults", "write", AMETHYST, "floating", plistlib.dumps(entries, fmt=plistlib.FMT_XML).decode())


def snapshot_recents() -> dict:
    return {p.name: p.read_bytes() for p in RECENTS.iterdir() if p.name.startswith(RECENT_PREFIXES)}


def restore_recents(snap: dict) -> None:
    """Puts back the recent-documents lists of the 3 installed apps and removes any list the run created."""
    for p in RECENTS.iterdir():
        if p.name.startswith(RECENT_PREFIXES + RECENT_BENCH_PREFIXES) and p.name not in snap:
            p.unlink()
    for name, data in snap.items():
        (RECENTS / name).write_bytes(data)


def memory_later(app: App, pid: int) -> float:
    """Memory 2 s after the launch settled: some apps release drawing buffers by then, some don't."""
    time.sleep(2)
    return probe(app, "stat", str(pid))["footprintMB"]


def run_round(app: App, fx: dict) -> dict:
    r = {}
    pin_windows()
    a = probe(app, "launch", str(app.path), fx["small"])
    r["launch_small"] = a
    pid = a["pid"]
    a["mem2s"] = memory_later(app, pid)
    r["open_one"] = probe(app, "open", str(pid), str(app.path), fx["ten"][0])
    time.sleep(0.3)
    r["open_ten"] = probe(app, "open", str(pid), str(app.path), *fx["ten"][1:])
    time.sleep(3)
    r["idle"] = probe(app, "idle", str(pid), "15")
    kill(pid)
    time.sleep(0.5)
    pin_windows()
    b = probe(app, "launch", str(app.path), fx["big"])
    r["launch_big"] = b
    b["mem2s"] = memory_later(app, b["pid"])
    kill(b["pid"])
    time.sleep(0.5)
    pin_windows()
    m = probe(app, "launch", str(app.path), fx["md"])
    r["launch_md"] = m
    m["mem2s"] = memory_later(app, m["pid"])
    kill(m["pid"])
    time.sleep(0.5)
    return r


ROWS = [
    # key, label, scenario, field, unit
    ("open_one_ms", "Open 1 file in the running app", "open_one", "settleMs", "ms"),
    ("open_one_cpu", "CPU for that open", "open_one", "cpuMs", "ms"),
    ("open_ten_ms", "Open 9 more files at once", "open_ten", "settleMs", "ms"),
    ("launch_small_window", "Launch with a 2 KB file: window visible", "launch_small", "windowMs", "ms"),
    ("launch_small_settle", "Launch with a 2 KB file: work done", "launch_small", "settleMs", "ms"),
    ("launch_small_cpu", "CPU for that launch", "launch_small", "cpuMs", "ms"),
    ("launch_big_window", "Launch with a 22 MB file: window visible", "launch_big", "windowMs", "ms"),
    ("launch_big_settle", "Launch with a 22 MB file: work done", "launch_big", "settleMs", "ms"),
    ("launch_big_cpu", "CPU for the 22 MB file", "launch_big", "cpuMs", "ms"),
    ("launch_md_settle", "Launch with a 2 MB Markdown file: work done", "launch_md", "settleMs", "ms"),
    ("launch_md_cpu", "CPU for the 2 MB Markdown file", "launch_md", "cpuMs", "ms"),
    ("mem_small", "Memory after launch, 1 file", "launch_small", "footprintMB", "MB"),
    ("mem_ten", "Memory with 11 files open", "open_ten", "footprintMB", "MB"),
    ("mem_md", "Memory with the 2 MB Markdown file", "launch_md", "footprintMB", "MB"),
    ("mem_big", "Memory with the 22 MB file", "launch_big", "footprintMB", "MB"),
    ("mem_small_2s", "Memory 2 s later, 1 file", "launch_small", "mem2s", "MB"),
    ("mem_md_2s", "Memory 2 s later, 2 MB Markdown file", "launch_md", "mem2s", "MB"),
    ("mem_big_2s", "Memory 2 s later, 22 MB file", "launch_big", "mem2s", "MB"),
    ("idle_cpu", "CPU at idle, 15 s with 11 files", "idle", "cpuMs", "ms"),
    ("idle_wakeups", "Wake-ups per second at idle", "idle", "wakeupsPerSec", "/s"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=7)
    ap.add_argument("--only", help="comma-separated app names, for a quick check")
    ap.add_argument("--textee", type=Path, help="Textee.app to measure instead of /Applications/Textee.app")
    args = ap.parse_args()
    if args.textee:
        global TEXTEE
        TEXTEE = args.textee.resolve()
    apps = [a for a in APPS if not args.only or a.name in args.only.split(",")]

    WORK.mkdir(exist_ok=True)
    build_probe()
    make_textee_copy(force=bool(args.textee))
    make_textmate_copy()
    for app in apps:
        if app.path in (TEXTEE_COPY, TM_COPY):
            for pid in running(app):
                kill(pid)  # a bench copy left over from an interrupted run
        elif running(app):
            sys.exit(f"❌ quit {app.name} first: the benchmark launches it fresh")
    fx = make_fixtures()

    tm_snap = snapshot_textmate_state()
    recents = snapshot_recents()
    window_prefs = snapshot_window_prefs()
    floating = amethyst_floating(["com.sublimetext.4", "com.coteditor.CotEditor", "com.apple.TextEdit",
                                  TEXTEE_BENCH_ID, TM_BENCH_ID])
    sublime_bench_data()
    load = os.getloadavg()[0]
    results = {a.name: [] for a in apps}
    started = time.time()
    try:
        for i in range(args.rounds):
            order = apps[i % len(apps):] + apps[:i % len(apps)]  # every app takes every slot in turn
            for app in order:
                print(f"⏱  round {i + 1}/{args.rounds}: {app.name}", flush=True)
                results[app.name].append(run_round(app, fx))
    finally:
        sublime_restore()
        restore_textmate_state(tm_snap)
        restore_recents(recents)
        restore_window_prefs(window_prefs)
        if floating:
            set_amethyst_floating(floating)
    load_end = os.getloadavg()[0]

    warm = {k: v[1:] if len(v) > 1 else v for k, v in results.items()}
    medians = {}
    for key, label, sc, fld, unit in ROWS:
        medians[key] = {name: statistics.median(r[sc][fld] for r in rounds) for name, rounds in warm.items()}
    medians["app_size"] = {a.name: a.size_mb for a in apps}

    names = [a.name for a in apps]
    print(f"\n📊 Medians of rounds 2-{args.rounds} (load average {load:.1f} at start, {load_end:.1f} at end)\n")
    print(f"| {'Measure':<44} | " + " | ".join(f"{n:>12}" for n in names) + " |")
    print(f"| {'-':<44} | " + " | ".join(f"{'-':>12}" for _ in names) + " |")
    for key, label, *_ , unit in ROWS + [("app_size", "App size", None, None, "MB")]:
        cells = []
        for n in names:
            v = medians[key][n]
            cells.append(f"{v:,.1f} {unit}" if unit in ("/s", "MB") and v < 10 else f"{v:,.0f} {unit}")
        print(f"| {label:<44} | " + " | ".join(f"{c:>12}" for c in cells) + " |")

    print("\n🪟 Main window sizes seen at the end of each launch:")
    for name, rounds in results.items():
        sizes = sorted({tuple(r[sc]["windows"][0]) for r in rounds for sc in ("launch_small", "launch_big", "launch_md")
                        if r[sc].get("windows")})
        print(f"   {name}: {', '.join(f'{w} x {h}' for w, h in sizes)}")

    out = ROOT / "bench" / "results.json"
    rows = [{"key": k, "label": lbl, "unit": u} for k, lbl, _, _, u in ROWS] + [{"key": "app_size", "label": "App size", "unit": "MB"}]
    out.write_text(json.dumps({
        "date": time.strftime("%Y-%m-%d %H:%M"), "load": [load, load_end], "rounds": args.rounds,
        "machine": f"{sh('sysctl', '-n', 'machdep.cpu.brand_string').strip()}, macOS {sh('sw_vers', '-productVersion').strip()}",
        "apps": names, "rows": rows, "medians": medians, "raw": results,
    }, indent=2), encoding="utf-8")
    print(f"✅ {out} in {time.time() - started:.0f}s")


if __name__ == "__main__":
    main()
