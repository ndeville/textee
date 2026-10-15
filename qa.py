#!/usr/bin/env python3
"""End-to-end QA for Textee.

Builds fixtures in $TMPDIR/textee-qa (copies, never the real ~/txt), runs the built app once per suite
with a JSON script (TEXTEE_QA), and checks the report. The app runs in the background (`open -g`) and uses
a private pasteboard, so QA never takes the screen or the clipboard.

    python3 qa.py                 # every suite
    python3 qa.py --only editing  # 1 suite
    python3 qa.py --keep          # keep the fixtures and screenshots
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT / "build.noindex" / "Textee.app"
QA = Path(tempfile.gettempdir()) / "textee-qa"
FILES = QA / "files"
TXT = QA / "txt"
HOME = QA / "home"
OUT = QA / "out"
REAL_TXT = Path.home() / "txt"
BIG = REAL_TXT / "250503-101225.txt"

BASELINE_SRC = r"""
import AppKit
func started() -> TimeInterval {
    var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let t = info.kp_proc.p_un.__p_starttime
    return TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6
}
final class D: NSObject, NSApplicationDelegate {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    func applicationDidFinishLaunching(_ n: Notification) {
        w.orderBack(nil)
        DispatchQueue.main.async {
            self.w.displayIfNeeded()
            let ms = String(format: "%.1f", (Date().timeIntervalSince1970 - started()) * 1000)
            try? ms.write(toFile: ProcessInfo.processInfo.environment["BASELINE_OUT"] ?? "/dev/stdout", atomically: false, encoding: .utf8)
            exit(0)
        }
    }
}
let app = NSApplication.shared
let d = D()
app.delegate = d
app.run()
"""

# Budgets from SPEC.md section 4. Launch is measured against an empty AppKit app on the same Mac at the
# same moment: the budget is that baseline plus 150 ms of Textee's own work (the Mac's load swings it a lot).
LAUNCH_OWN_WORK = 150
BUDGETS = {
    "launch": 250,
    "open typical": 20,
    "open 22 MB": 1500,
    "keystroke": 5,
    "keystroke 22 MB": 10,
    "keystroke 2 MB Markdown": 10,
    "scroll 22 MB": 16.7,
    "memory 10 tabs": 60,
}

MARKDOWN = """---
title: Textee test
tags: qa
---

# Heading one

Some **bold text**, some *italic*, a `code span` and a [link](https://example.com).

- list item
- [ ] task
1. numbered

> a quote

```python
def inside_fence():
    pass
```

| a | b |
| - | - |
<!-- comment -->
snake_case_word stays plain https://nicolasdeville.com
"""

JSON_TEXT = """{
  "name": "textee",
  "count": 42,
  "ok": true,
  "nothing": null
}
"""

YAML_TEXT = """# config
name: textee
version: 1.0
enabled: true
items:
  - first
  - "second"
anchor: &base
"""

PY_TEXT = '''#!/usr/bin/env python3
"""Docstring line one.
Docstring line two."""
import os


@decorator
def main(path: str) -> int:
    """Return 1."""
    name = f"hello {path}"  # comment
    if True and None is None:
        print(len(name), self)
    return 1
'''

SH_TEXT = """#!/bin/zsh
# build
set -euo pipefail
NAME="textee"
for f in *.txt; do
  echo "$NAME ${f}" | grep -c x
done
"""


def build_fixtures() -> None:
    """Fresh copies of everything QA touches."""
    if QA.exists():
        shutil.rmtree(QA)
    for d in (FILES, HOME, OUT):
        d.mkdir(parents=True)
    print("📁 cloning ~/txt into the fixture folder (APFS clone, no extra space)")
    subprocess.run(["cp", "-cRp", str(REAL_TXT), str(TXT)], check=True)
    (FILES / "sample.md").write_text(MARKDOWN, encoding="utf-8")
    (FILES / "sample.json").write_text(JSON_TEXT, encoding="utf-8")
    (FILES / "sample.yaml").write_text(YAML_TEXT, encoding="utf-8")
    (FILES / "sample.py").write_text(PY_TEXT, encoding="utf-8")
    (FILES / "sample.sh").write_text(SH_TEXT, encoding="utf-8")
    (FILES / "plain.txt").write_text("alpha beta\ngamma\n", encoding="utf-8")
    (FILES / "edit.txt").write_text("line one\nline two\nline three\n", encoding="utf-8")
    (FILES / "corners.txt").write_text("line one\nline two\n", encoding="utf-8")
    (FILES / "crlf.txt").write_bytes(b"first\r\nsecond\r\nthird\r\n")
    (FILES / "bom.txt").write_bytes(b"\xef\xbb\xbfwith bom\n")
    (FILES / "latin1.txt").write_bytes("caf\xe9 cr\xe8me\n".encode("latin-1"))
    (FILES / "emoji.txt").write_text("Hi 👋 there", encoding="utf-8")
    (FILES / "external.txt").write_text("version 1\n", encoding="utf-8")
    (FILES / "conflict.txt").write_text("disk 1\n", encoding="utf-8")
    (FILES / "deleted.txt").write_text("soon gone\n", encoding="utf-8")
    (FILES / "empty-guard.txt").write_text("keep me\n", encoding="utf-8")
    (FILES / "find.txt").write_text("cat Cat CAT\ndog cat\nfoo123 bar45\n", encoding="utf-8")
    # Textee reads files in 1 MB pieces (TextFile.pieceSize): these cross the piece boundaries.
    piece = 1 << 20
    (FILES / "pieces-utf8.txt").write_text("aé😀 b" * 300_000, encoding="utf-8")  # 9 bytes: cuts land mid-character
    (FILES / "pieces-lines.txt").write_text("".join(f"ligne {i} : café, crème, 👋\n" for i in range(80_000)), encoding="utf-8")
    (FILES / "pieces-crlf.txt").write_bytes(b"x" * (piece - 1) + b"\r\nnext\r\nlast\r\n")  # CR is the last byte of piece 1
    (FILES / "pieces-invalid.txt").write_bytes(b"valid line\n" * 200_000 + b"bad \xff byte\n")  # invalid in piece 3
    (FILES / "empty.txt").write_bytes(b"")
    md_lines = []
    for i in range(20000):
        md_lines.append(f"## Section {i}\n\nText with **bold** and `code` and a [link](https://x.com/{i}).\n\n```\nfenced {i}\n```\n")
    (FILES / "big.md").write_text("".join(md_lines), encoding="utf-8")
    subprocess.run(["cp", "-c", str(BIG), str(FILES / "big.txt")], check=True)
    for i in range(10):
        (FILES / f"tab{i}.txt").write_text(f"tab {i}\n" * 200, encoding="utf-8")


def f(name: str) -> str:
    return str(FILES / name)


def suites() -> dict:
    """Each suite is 1 app run."""
    s = {}

    s["visual"] = [
        {"op": "resize", "width": 1200, "height": 800},
        {"op": "open", "path": f("sample.md")},
        {"op": "assertDoc", "language": "Markdown"},
        {"op": "assertColor", "text": "# Heading one", "equals": "FF6400"},
        {"op": "assertColor", "text": "**bold text**", "equals": "FBDE2D"},
        {"op": "assertColor", "text": "*italic*", "equals": "8DA6CE"},
        {"op": "assertColor", "text": "`code span`", "equals": "61CE3C"},
        {"op": "assertColor", "text": "def inside_fence", "equals": "61CE3C"},
        {"op": "assertColor", "text": "snake_case_word", "equals": "F8F8F8"},
        {"op": "assertColor", "text": "title:", "equals": "FBDE2D"},
        {"op": "screenshot", "name": "markdown"},
        {"op": "open", "path": f("sample.json")},
        {"op": "assertDoc", "language": "JSON"},
        {"op": "assertColor", "text": "\"name\"", "equals": "8DA6CE"},
        {"op": "assertColor", "text": "\"textee\"", "equals": "61CE3C"},
        {"op": "assertColor", "text": "42", "equals": "D8FA3C"},
        {"op": "screenshot", "name": "json"},
        {"op": "open", "path": f("sample.yaml")},
        {"op": "assertDoc", "language": "YAML"},
        {"op": "assertColor", "text": "# config", "equals": "AEAEAE"},
        {"op": "assertColor", "text": "version", "equals": "8DA6CE"},
        {"op": "assertColor", "text": "true", "equals": "D8FA3C"},
        {"op": "screenshot", "name": "yaml"},
        {"op": "open", "path": f("sample.py")},
        {"op": "assertDoc", "language": "Python"},
        {"op": "assertColor", "text": "def main", "equals": "FBDE2D"},
        {"op": "assertColor", "text": "main(", "equals": "FF6400"},
        {"op": "assertColor", "text": "Docstring line two", "equals": "61CE3C"},
        {"op": "assertColor", "text": "# comment", "equals": "AEAEAE"},
        {"op": "assertColor", "text": "@decorator", "equals": "FF6400"},
        {"op": "assertColor", "text": "print", "equals": "8DA6CE"},
        {"op": "screenshot", "name": "python"},
        {"op": "open", "path": f("sample.sh")},
        {"op": "assertDoc", "language": "Shell"},
        {"op": "assertColor", "text": "$NAME", "equals": "FF6400"},
        {"op": "assertColor", "text": "# build", "equals": "AEAEAE"},
        {"op": "assertColor", "text": "for", "equals": "FBDE2D"},
        {"op": "screenshot", "name": "shell"},
        {"op": "open", "path": f("plain.txt")},
        {"op": "assertDoc", "language": "Plain Text"},
        {"op": "open", "path": str(TXT / "261012-155313.txt")},
        {"op": "assertDoc", "language": "Plain Text"},
        {"op": "assertColor", "text": "**", "equals": "F8F8F8", "label": "Markdown in .txt stays plain"},
        {"op": "selectText", "text": "Gemini"},
        {"op": "screenshot", "name": "scratch-txt"},
        {"op": "assertTabs", "count": 7},
    ]

    s["editing"] = [
        {"op": "open", "path": f("edit.txt")},
        {"op": "select", "location": 0},
        {"op": "key", "keys": "cmd+t", "label": "⌘T duplicates the line"},
        {"op": "assertText", "prefix": "line one\nline one\nline two"},
        {"op": "assertLineIndex"},
        {"op": "key", "keys": "opt+d", "label": "⌥D deletes the line"},
        {"op": "assertText", "equals": "line one\nline two\nline three\n"},
        {"op": "select", "location": 0},
        {"op": "keyEvent", "mods": ["opt"], "chars": "∂", "base": "d", "code": 2, "label": "⌥D key press deletes the line"},
        {"op": "assertText", "equals": "line two\nline three\n"},
        {"op": "key", "keys": "cmd+z"},
        {"op": "assertText", "equals": "line one\nline two\nline three\n"},
        {"op": "select", "location": 0},
        {"op": "keyEvent", "mods": ["opt"], "chars": "π", "base": "p", "code": 35, "label": "⌥P without a shortcut types π"},
        {"op": "assertText", "prefix": "πline one"},
        {"op": "key", "keys": "cmd+z"},
        {"op": "assertText", "equals": "line one\nline two\nline three\n"},
        {"op": "assertLineIndex"},
        {"op": "select", "location": 10},
        {"op": "key", "keys": "opt+up", "label": "⌥↑ moves the line up"},
        {"op": "assertText", "equals": "line two\nline one\nline three\n"},
        {"op": "key", "keys": "opt+down", "label": "⌥↓ moves the line down"},
        {"op": "assertText", "equals": "line one\nline two\nline three\n"},
        {"op": "assertLineIndex"},
        {"op": "select", "location": 0, "length": 8},
        {"op": "key", "keys": "cmd+]", "label": "⌘] indents"},
        {"op": "assertText", "prefix": "    line one\n"},
        {"op": "key", "keys": "cmd+[", "label": "⌘[ outdents"},
        {"op": "assertText", "prefix": "line one\n"},
        {"op": "select", "location": 0},
        {"op": "key", "keys": "opt+enter", "label": "⌥↩ selects the word"},
        {"op": "key", "keys": "opt+enter", "label": "⌥↩ adds the next match"},
        {"op": "key", "keys": "opt+enter"},
        {"op": "assertDoc", "cursors": 3},
        {"op": "type", "text": "LINE"},
        {"op": "assertText", "equals": "LINE one\nLINE two\nLINE three\n"},
        {"op": "assertLineIndex"},
        {"op": "key", "keys": "cmd+z", "label": "⌘Z undoes the multi-cursor edit"},
        {"op": "assertText", "equals": "line one\nline two\nline three\n", "label": "1 undo step, nothing more"},
        {"op": "select", "location": 0, "length": 4},
        {"op": "key", "keys": "cmd+shift+a", "label": "⇧⌘A selects every match"},
        {"op": "assertDoc", "cursors": 3},
        {"op": "type", "text": "row"},
        {"op": "assertText", "prefix": "row "},
        {"op": "select", "location": 0},
        {"op": "select", "location": 0, "length": 3},
        {"op": "key", "keys": "cmd+d", "label": "⌘D copies"},
        {"op": "assertPasteboard", "equals": "row"},
        {"op": "select", "location": -1},
        {"op": "key", "keys": "cmd+f", "label": "⌘F pastes"},
        {"op": "assertText", "notContains": "line"},
        {"op": "assertText", "prefix": "row "},
        {"op": "select", "location": -1},
        {"op": "type", "text": "\n    indented\nnext"},
        {"op": "assertText", "contains": "    indented\n    next", "label": "Return keeps the indentation"},
        {"op": "assertLineIndex"},
        {"op": "open", "path": f("sample.md")},
        {"op": "selectText", "text": "Some"},
        {"op": "key", "keys": "cmd+shift+b", "label": "⇧⌘B bolds in Markdown"},
        {"op": "assertText", "contains": "**Some** **bold text**"},
        {"op": "key", "keys": "cmd+shift+d", "label": "⇧⌘D copies <path>"},
        {"op": "assertPasteboard", "equals": f"<{os.path.realpath(f('sample.md'))}>"},
        {"op": "open", "path": f("emoji.txt")},
        {"op": "assertStatus", "contains": "3 words · 11 chars", "label": "LinkedIn count: the emoji counts 2"},
        {"op": "select", "location": 0, "length": 2},
        {"op": "assertStatus", "contains": "Selection: 1 word · 2 chars"},
        {"op": "key", "keys": "cmd+shift+]", "label": "⇧⌘] next tab"},
        {"op": "assertTabs", "active": "edit.txt"},
        {"op": "key", "keys": "cmd+shift+[", "label": "⇧⌘[ previous tab"},
        {"op": "assertTabs", "active": "emoji.txt"},
        {"op": "key", "keys": "opt+z", "label": "⌥Z toggles soft wrap"},
        {"op": "key", "keys": "opt+z"},
        {"op": "key", "keys": "cmd+=", "label": "⌘= zooms in"},
        {"op": "key", "keys": "cmd+0", "label": "⌘0 resets the zoom"},
    ]

    s["files"] = [
        {"op": "key", "keys": "cmd+n", "label": "⌘N creates a scratch file"},
        {"op": "assertTabs", "count": 1},
        {"op": "type", "text": "scratch text"},
        {"op": "wait", "wait": 1.4, "label": "auto-save after 1 s"},
        {"op": "assertDoc", "dirty": False},
        {"op": "assertRecentScratch", "contains": "scratch text", "nameMatches": "^\\d{6}-\\d{6}\\.txt$", "label": "saved as YYMMDD-HHMMSS.txt"},
        {"op": "key", "keys": "cmd+w"},
        {"op": "key", "keys": "cmd+n"},
        {"op": "key", "keys": "cmd+w"},
        {"op": "assertRecentScratch", "maxEmpty": 0, "label": "an empty new file is deleted on close"},
        {"op": "setPasteboard", "text": "from the clipboard\nline 2"},
        {"op": "url", "url": "textee://new-from-clipboard", "label": "textee://new-from-clipboard"},
        {"op": "assertText", "equals": "from the clipboard\nline 2"},
        {"op": "assertRecentScratch", "contains": "from the clipboard\nline 2", "label": "clipboard file written at once"},
        {"op": "open", "path": f("crlf.txt")},
        {"op": "assertDoc", "lineEnding": "CRLF", "lines": 4},
        {"op": "select", "location": -1},
        {"op": "type", "text": "fourth\n"},
        {"op": "save"},
        {"op": "assertFile", "path": f("crlf.txt"), "equals": "first\r\nsecond\r\nthird\r\nfourth\r\n", "label": "CRLF kept on save"},
        {"op": "open", "path": f("bom.txt")},
        {"op": "select", "location": -1},
        {"op": "type", "text": "x"},
        {"op": "save"},
        {"op": "assertFile", "path": f("bom.txt"), "bytesPrefix": "efbbbf", "label": "BOM kept on save"},
        {"op": "open", "path": f("pieces-utf8.txt"), "label": "1 MB pieces: no character split"},
        {"op": "assertTextEqualsFile", "path": f("pieces-utf8.txt")},
        {"op": "assertDoc", "lines": 1, "readOnly": False},
        {"op": "assertStatus", "contains": "1 line · 300,001 words · 1,800,000 chars"},
        {"op": "assertLineIndex"},
        {"op": "open", "path": f("pieces-lines.txt"), "label": "1 MB pieces: cut after a line break"},
        {"op": "assertTextEqualsFile", "path": f("pieces-lines.txt")},
        {"op": "assertStatus", "contains": "80,001 lines · 480,000 words"},
        {"op": "assertLineIndex"},
        {"op": "select", "location": 1048570},
        {"op": "type", "text": "inserted words here\n"},
        {"op": "assertLineIndex", "label": "word count after an edit"},
        {"op": "key", "keys": "cmd+z"},
        {"op": "assertStatus", "contains": "80,001 lines · 480,000 words", "label": "word count after undo"},
        {"op": "open", "path": f("pieces-crlf.txt"), "label": "1 MB pieces: CR and LF stay together"},
        {"op": "assertDoc", "lineEnding": "CRLF", "lines": 4},
        {"op": "assertTextEqualsFile", "path": f("pieces-crlf.txt"), "crlf": True},
        {"op": "assertLineIndex"},
        {"op": "open", "path": f("pieces-invalid.txt")},
        {"op": "assertDoc", "readOnly": True, "banner": True, "label": "invalid byte after 2 MB: read-only"},
        {"op": "open", "path": f("empty.txt")},
        {"op": "assertText", "equals": "", "label": "empty file"},
        {"op": "assertDoc", "lines": 1},
        {"op": "assertStatus", "contains": "1 line · 0 words · 0 chars"},
        {"op": "open", "path": f("latin1.txt")},
        {"op": "assertDoc", "readOnly": True, "banner": True, "label": "not UTF-8: read-only"},
        {"op": "open", "path": f("external.txt")},
        {"op": "externalWrite", "path": f("external.txt"), "text": "version 2\n", "wait": 0.1},
        {"op": "checkDisk"},
        {"op": "assertText", "equals": "version 2\n", "label": "reloads a file changed on disk"},
        {"op": "open", "path": f("conflict.txt")},
        {"op": "select", "location": -1},
        {"op": "type", "text": "mine"},
        {"op": "externalWrite", "path": f("conflict.txt"), "text": "disk 2\n", "wait": 0.1},
        {"op": "checkDisk"},
        {"op": "assertDoc", "conflict": True, "banner": True, "label": "conflict banner"},
        {"op": "save"},
        {"op": "assertFile", "path": f("conflict.txt"), "equals": "disk 2\n", "label": "auto-save never overwrites a conflict"},
        {"op": "key", "keys": "cmd+s", "label": "⌘S keeps mine"},
        {"op": "assertFile", "path": f("conflict.txt"), "equals": "disk 1\nmine"},
        {"op": "assertDoc", "conflict": False, "banner": False},
        {"op": "open", "path": f("deleted.txt")},
        {"op": "externalDelete", "path": f("deleted.txt")},
        {"op": "checkDisk"},
        {"op": "assertDoc", "banner": True, "label": "deleted-on-disk banner"},
        {"op": "open", "path": f("empty-guard.txt")},
        {"op": "key", "keys": "cmd+a"},
        {"op": "type", "text": "x"},
        {"op": "key", "keys": "cmd+z"},
        {"op": "select", "location": 0, "length": 8},
        {"op": "action", "name": "delete:"},
        {"op": "save"},
        {"op": "assertFile", "path": f("empty-guard.txt"), "equals": "keep me\n", "label": "auto-save never writes an empty file over content"},
    ]

    s["find"] = [
        {"op": "open", "path": f("find.txt")},
        {"op": "find", "query": "cat", "count": 4, "label": "case-insensitive"},
        {"op": "find", "query": "cat", "case": True, "count": 2, "label": "match case"},
        {"op": "find", "query": "[a-z]+\\d+", "regex": True, "count": 2, "label": "regex"},
        {"op": "screenshot", "name": "find"},
        {"op": "replaceAll", "with": "<$0>"},
        {"op": "assertText", "contains": "<foo123> <bar45>", "label": "regex replace with $0"},
        {"op": "find", "query": "dog", "count": 1},
        {"op": "replaceAll", "with": "wolf"},
        {"op": "assertText", "contains": "wolf cat"},
        {"op": "focusEditor"},
        {"op": "key", "keys": "cmd+z", "label": "replace all is 1 undo step"},
        {"op": "assertText", "contains": "dog cat"},
        {"op": "key", "keys": "ctrl+f", "label": "⌃F hides the find bar"},
    ]

    s["quickopen"] = [
        {"op": "open", "path": f("plain.txt")},
        {"op": "quickOpen", "query": "", "minResults": 100, "wait": 2.5},
        {"op": "screenshot", "name": "quickopen-empty"},
        {"op": "quickOpen", "query": "gemini flash", "minResults": 1, "label": "content search, 2 words"},
        {"op": "screenshot", "name": "quickopen-search"},
        {"op": "quickOpen", "query": "261012-155313", "firstName": "261012-155313.txt", "label": "name search"},
        {"op": "quickOpenEnter"},
        {"op": "assertTabs", "active": "261012-155313.txt"},
    ]

    perf = [
        {"op": "open", "path": f("plain.txt"), "label": "open typical"},
        {"op": "open", "path": f("tab0.txt"), "label": "open typical"},
        {"op": "type", "text": "the quick brown fox jumps over the lazy dog " * 3, "label": "keystroke"},
        {"op": "open", "path": f("big.txt"), "label": "open 22 MB"},
        {"op": "assertLineIndex"},
        {"op": "type", "text": "typing in the big file ", "label": "keystroke 22 MB"},
        {"op": "scroll", "pages": 60, "label": "scroll 22 MB"},
        {"op": "scrollToEnd", "label": "jump to end 22 MB"},
        {"op": "type", "text": "end ", "label": "keystroke 22 MB"},
        {"op": "assertLineIndex"},
        {"op": "assertStatus", "notContains": "… words", "label": "word count ready at once"},
        {"op": "open", "path": f("big.md"), "label": "open 2 MB Markdown"},
        {"op": "scrollToEnd", "label": "jump to end of 2 MB Markdown (colours)"},
        {"op": "assertColor", "text": "## Section 19999", "equals": "FF6400"},
        {"op": "select", "location": -1},
        {"op": "type", "text": "typing at the end of a long Markdown file", "label": "keystroke 2 MB Markdown"},
    ]
    for i in range(10):
        perf.append({"op": "open", "path": f(f"tab{i}.txt")})
    perf.append({"op": "memory", "label": "memory 10 tabs + 22 MB + 2 MB", "wait": 0.5})
    s["perf"] = perf

    # settings.json is saved while Textee runs: corners and radius change at once, the selection stays.
    settings = str(HOME / "settings.json")
    s["corners"] = [
        {"op": "open", "path": f("corners.txt")},
        {"op": "selectText", "text": "line two"},
        {"op": "assertCorners", "expect": "rounded", "radius": 4, "label": "defaults without settings.json"},
        {"op": "externalWrite", "path": settings, "text": '{"windowCorners": "square", "cornerRadius": 0}', "wait": 0.3},
        {"op": "assertCorners", "expect": "square", "radius": 0, "label": "square after a save"},
        {"op": "assertDoc", "selection": "line two", "label": "selection kept after a reload"},
        {"op": "screenshotTabs", "name": "tabs-square"},
        {"op": "externalWrite", "path": settings, "text": '{"windowCorners": "oval", "cornerRadius": 99}', "wait": 0.3},
        {"op": "assertCorners", "expect": "rounded", "radius": 10, "label": "unknown values clamped"},
        {"op": "externalWrite", "path": settings, "text": '{"windowCorners": "rounded", "cornerRadius": 4}', "wait": 0.3},
        {"op": "assertCorners", "expect": "rounded", "radius": 4, "label": "rounded again without a restart"},
        {"op": "assertDoc", "selection": "line two"},
        {"op": "writeInPlace", "path": settings, "text": '{"windowCorners": "square", "cornerRadius": 2}', "wait": 0.3},
        {"op": "assertCorners", "expect": "square", "radius": 2, "label": "a write in place reloads too"},
        {"op": "externalDelete", "path": settings},
    ]

    s["memory"] = [{"op": "open", "path": f(f"tab{i}.txt")} for i in range(10)] + [
        {"op": "wait", "wait": 1.0},
        {"op": "memory", "label": "memory 10 tabs"},
    ]
    return s


def launch_baseline(runs: int = 3) -> float:
    """Median launch-to-first-display of an empty AppKit app bundle, opened like Textee (`open -g -n -W`)."""
    app = ROOT / "build.noindex" / "LaunchBaseline.app"
    exe = app / "Contents" / "MacOS" / "LaunchBaseline"
    if not exe.exists():
        exe.parent.mkdir(parents=True, exist_ok=True)
        src = ROOT / "build.noindex" / "launch-baseline.swift"
        src.write_text(BASELINE_SRC, encoding="utf-8")
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True, capture_output=True)
        (app / "Contents" / "Info.plist").write_text(
            '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
            "<key>CFBundleIdentifier</key><string>com.nicolasdeville.textee.launchbaseline</string>"
            "<key>CFBundleExecutable</key><string>LaunchBaseline</string>"
            "<key>CFBundlePackageType</key><string>APPL</string></dict></plist>", encoding="utf-8")
        subprocess.run(["codesign", "-s", "-", "--force", str(app)], check=True, capture_output=True)
    out = QA / "baseline.txt"
    times = []
    for _ in range(runs):
        out.unlink(missing_ok=True)
        subprocess.run(["open", "-g", "-n", "-W", "--env", f"BASELINE_OUT={out}", str(app)], check=True, timeout=60)
        times.append(float(out.read_text(encoding="utf-8").strip() or 0))
    return sorted(times)[len(times) // 2]


def run_suite(name: str, steps: list) -> list:
    script = QA / f"{name}.json"
    script.write_text(json.dumps(steps, ensure_ascii=False), encoding="utf-8")
    out = OUT / name
    out.mkdir(parents=True, exist_ok=True)
    report = out / "report.json"
    env = {
        "TEXTEE_QA": str(script),
        "TEXTEE_QA_OUT": str(out),
        "TEXTEE_HOME": str(HOME),
        "TEXTEE_TXT_DIR": str(TXT),
        "TEXTEE_PASTEBOARD": "com.nicolasdeville.textee.qa",
    }
    args = ["open", "-g", "-n", "-W"]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    args.append(str(APP))
    try:
        subprocess.run(args, check=True, timeout=180)
    except subprocess.TimeoutExpired:
        print(f"❌ {name}: timed out", file=sys.stderr)
        return []
    if not report.exists():
        print(f"❌ {name}: no report (crash?)", file=sys.stderr)
        return []
    return json.loads(report.read_text(encoding="utf-8"))["steps"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="run 1 suite")
    ap.add_argument("--keep", action="store_true", help="keep fixtures")
    args = ap.parse_args()
    if not APP.exists():
        sys.exit("❌ build first: ./build.sh")
    build_fixtures()
    all_suites = suites()
    names = [args.only] if args.only else list(all_suites)
    passed = failed = 0
    timings: dict[str, list[float]] = {}
    started = time.time()
    deltas: list[float] = []
    for name in names:
        print(f"\n▶ {name}")
        base = launch_baseline(runs=1)
        results = run_suite(name, all_suites[name])
        launches = [r["ms"] for r in results if r["op"] == "launch"]
        if launches:
            deltas.append(launches[0] - base)
        if not results:
            failed += 1
            continue
        for r in results:
            label = r.get("label", "")
            key = label if label in BUDGETS or r["op"] == "launch" else None
            if r["op"] == "launch":
                key = "launch"
            if r["op"] == "memory":
                key = label or "memory"
            if key:
                timings.setdefault(key, []).append(r["ms"])
            if r["op"] in ("open", "type", "scroll", "scrollToEnd", "memory", "launch") and not label and r["op"] != "launch":
                continue
            ok = r["ok"]
            passed += ok
            failed += not ok
            mark = "✅" if ok else "❌"
            detail = r.get("detail", "")
            if not ok or label or r["op"] in ("launch",):
                extra = f" {r['ms']:.1f}" + (" MB" if r["op"] == "memory" else " ms") if r["op"] in ("launch", "open", "type", "scroll", "scrollToEnd", "memory") else ""
                print(f"  {mark} {r['op']:<14} {label}{extra}  {detail if not ok else ''}".rstrip())
    print("\n📊 Budgets")
    if deltas:
        # Textee's own launch work: each suite's launch minus an empty app launched just before it.
        own = sorted(deltas[1:] or deltas)[len(deltas[1:] or deltas) // 2]
        ok = own <= LAUNCH_OWN_WORK
        passed += ok
        failed += not ok
        print(f"  {'✅' if ok else '❌'} {'launch, minus an empty AppKit app':<34} {own:8.1f} ms  (budget {LAUNCH_OWN_WORK} ms, median of the warm launches)")
    for key, values in timings.items():
        budget = BUDGETS.get(key)
        worst = max(values)
        if key == "launch":
            # The 1st launch after a build pays for the code-signature check.
            print(f"  ·  {'launch, 1st after build':<34} {values[0]:8.1f} ms")
            print(f"  ·  {'launch, median of the others':<34} {sorted(values[1:] or values)[len(values[1:] or values) // 2]:8.1f} ms")
            continue
        unit = "MB" if "memory" in key else "ms"
        if budget is None:
            print(f"  ·  {key:<34} {worst:8.1f} {unit}")
            continue
        ok = worst <= budget
        passed += ok
        failed += not ok
        print(f"  {'✅' if ok else '❌'} {key:<34} {worst:8.1f} {unit}  (budget {budget} {unit})")
    print(f"\n{'✅' if failed == 0 else '❌'} {passed} passed, {failed} failed in {time.time() - started:.0f}s")
    print(f"   screenshots: {OUT}")
    if not args.keep and failed == 0:
        shutil.rmtree(TXT, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
