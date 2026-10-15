#!/usr/bin/env python3
"""Make the README screenshots: the built app on made-up files, captured from inside the app.

Builds a demo scratch folder and demo files in /Users/Shared/Textee (deleted at the end), runs build.noindex/Textee.app once with a
QA script (the same harness as qa.py, so it never takes the keyboard), and writes assets/screenshots/*.png.
Your ~/txt, ~/.textee and clipboard stay untouched. pngquant, if installed, shrinks the PNGs.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT / "build.noindex" / "Textee.app"
# A plain path, because the window title shows it.
WORK = Path("/Users/Shared/Textee")
FILES, TXT, HOME, OUT = WORK / "Notes", WORK / "txt", WORK / "home", WORK / "out"
DEST = ROOT / "assets" / "screenshots"

PLAN = """# Offsite plan

Venue: **Lakeside lodge**, 2 nights. Budget agreed with finance on Monday.

## Agenda

1. Day 1: arrivals, *strategy review*, dinner
2. Day 2: workshops in 3 groups, then the `retro` session
3. Day 3: wrap-up and travel

## Open points

- Confirm the coach from the station (`14:30` or `15:10`)
- Dietary list: 2 vegetarian, 1 gluten-free
- [Booking page](https://example.com/lodge) needs the final head count by Friday

> Keep the agenda light: the best ideas came from the walks last year.

```
headcount: 18
rooms: 9 twin
```
"""

SYNC = '''"""Sync the notes folder to the backup drive, newest first."""
import shutil
from dataclasses import dataclass
from pathlib import Path

SOURCE = Path.home() / "notes"
TARGET = Path("/Volumes/Backup/notes")


@dataclass
class Result:
    copied: int = 0
    skipped: int = 0


def sync(source: Path, target: Path) -> Result:
    result = Result()
    for f in sorted(source.rglob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True):
        dest = target / f.relative_to(source)
        if dest.exists() and dest.stat().st_mtime >= f.stat().st_mtime:
            result.skipped += 1  # already current
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dest)
        result.copied += 1
    return result


if __name__ == "__main__":
    r = sync(SOURCE, TARGET)
    print(f"copied {r.copied}, skipped {r.skipped}")
'''

SETTINGS = """{
  "editor": {
    "font": "SF Mono",
    "size": 14,
    "softWrap": true
  },
  "recent": ["plan.md", "sync.py"],
  "maxTabs": 30
}
"""

SCRATCH = {
    "261009-091204.txt": "Call notes, supplier review\n\nPrices up 4% from January. Ask for the volume discount again before we sign.\n",
    "261010-163015.txt": "Flight options for the Berlin trip\n\nTue 07:10 direct, back Thu 19:45. Hotel near the venue, 3 nights.\n",
    "261012-080245.txt": "Draft reply to the venue\n\nThanks for the quick answer. 18 people, 9 twin rooms, arriving by coach around 15:00.\n",
    "261013-112730.txt": "Ideas for the newsletter\n\n- 3 tools we stopped using, and why\n- A short guide to plain-text notes\n",
    "261014-174512.txt": "Budget check\n\nVenue 6,200, coach 900, dinner 1,400. Total 8,500, under the 9,000 cap.\n",
    "261015-102233.txt": "Book list from the offsite thread\n\nThe Mythical Man-Month, Shape Up, Working in Public.\n",
}


def build_demo() -> None:
    if WORK.exists():
        shutil.rmtree(WORK)
    for d in (FILES, TXT, HOME, OUT):
        d.mkdir(parents=True)
    (FILES / "plan.md").write_text(PLAN, encoding="utf-8")
    (FILES / "sync.py").write_text(SYNC, encoding="utf-8")
    (FILES / "settings.json").write_text(SETTINGS, encoding="utf-8")
    for name, text in SCRATCH.items():
        (TXT / name).write_text(text, encoding="utf-8")
    recent = [str(FILES / n) for n in ("plan.md", "sync.py", "settings.json")]
    (HOME / "state.json").write_text(json.dumps({"recentFiles": recent, "fontSize": 14, "softWrap": True,
                                                 "lineNumbers": True}), encoding="utf-8")


def steps() -> list:
    return [
        {"op": "open", "path": str(FILES / "settings.json")},
        {"op": "open", "path": str(FILES / "sync.py")},
        {"op": "open", "path": str(TXT / "261014-174512.txt")},
        {"op": "open", "path": str(FILES / "plan.md")},
        {"op": "selectText", "text": "Budget agreed with finance"},
        {"op": "screenshotFrame", "name": "hero", "scale": 2, "width": 980, "height": 600},
        {"op": "tab", "index": 1},
        {"op": "selectText", "text": "already current"},
        {"op": "screenshotFrame", "name": "python", "scale": 2, "width": 980, "height": 600},
        {"op": "tab", "index": 3},
        {"op": "quickOpen", "query": "venue"},
        {"op": "screenshotFrame", "name": "quick-open", "scale": 2, "width": 980, "height": 600},
        {"op": "closeQuickOpen"},
        {"op": "find", "query": "\\d+", "regex": True},
        {"op": "screenshotFrame", "name": "find", "scale": 2, "width": 980, "height": 600},
    ]


def run() -> None:
    script = WORK / "shots.json"
    script.write_text(json.dumps(steps()), encoding="utf-8")
    env = {"TEXTEE_QA": str(script), "TEXTEE_QA_OUT": str(OUT), "TEXTEE_HOME": str(HOME),
           "TEXTEE_TXT_DIR": str(TXT), "TEXTEE_PASTEBOARD": "com.nicolasdeville.textee.shots", "TEXTEE_READONLY": "1"}
    args = ["open", "-g", "-n", "-W"]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    subprocess.run(args + [str(APP)], check=True, timeout=120)
    report = json.loads((OUT / "report.json").read_text(encoding="utf-8"))["steps"]
    failed = [r for r in report if not r.get("ok")]
    for r in failed:
        print(f"❌ {r.get('op')}: {r.get('detail')}", file=sys.stderr)
    if failed:
        sys.exit(1)


def main() -> None:
    if not APP.exists():
        sys.exit("❌ build first: ./build.sh")
    print("📁 demo files in", WORK)
    build_demo()
    print("📸 running Textee in the background")
    run()
    DEST.mkdir(parents=True, exist_ok=True)
    shots = sorted(OUT.glob("*.png"))
    for png in shots:
        shutil.copy2(png, DEST / png.name)
        if shutil.which("pngquant"):
            subprocess.run(["pngquant", "--force", "--skip-if-larger", "--ext", ".png", str(DEST / png.name)])
        print(f"✅ {DEST / png.name}")
    shutil.rmtree(WORK)
    print(f"📊 {len(shots)} screenshots, demo folder deleted")


if __name__ == "__main__":
    main()
