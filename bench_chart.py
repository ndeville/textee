#!/usr/bin/env python3
"""Draws bench/results.json as 1 SVG in NicAI style: a heat map of the 5 editors, green for the best, red for the worst.

    python3 bench_chart.py                     # writes bench/editors.svg
    python3 bench_chart.py --out path/to.svg
    python3 bench_chart.py --icons             # take the app icons again (after an app update)

The fonts (Montserrat and Lato) are subset and embedded, and so are the app icons (bench/icons, taken from each
app by bench/appicons.swift), so the SVG looks the same in an <img> tag anywhere.
"""

import argparse
import base64
import io
import json
import math
import re
import subprocess
from datetime import date
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent
KIT = Path.home() / "ai/_shared/nicai-design/dist"
ICONS = ROOT / "bench/icons"
ICON_PX = 96  # the PNG size: 2x the 48 px the chart draws
APP_PATHS = {
    "Textee": "/Applications/Textee.app",
    "TextMate": "/Applications/TextMate.app",
    "CotEditor": "/Applications/CotEditor.app",
    "Sublime Text": "/Applications/Sublime Text.app",
    "TextEdit": "/System/Applications/TextEdit.app",
}

INK = "#000305"
MUTED = "#6b6b70"
LINE = "#e4e4e7"
BAND = "#f7f7f8"
RED = "#e74c3c"
GREEN = "#2f8a3a"
# Pale scale for the cells that didn't win: best to worst.
SCALE = [(0.0, "#d4ecd7"), (0.5, "#fbefc6"), (1.0, "#f6c6bf")]
TIE = 0.05  # within 5% of the best value counts as a win

GROUPS = [
    ("Open files in the running app", [
        ("open_one_ms", "Open 1 file"),
        ("open_one_cpu", "CPU for that open"),
        ("open_ten_ms", "Open 9 more files at once"),
    ]),
    ("Launch with a file", [
        ("launch_small_window", "2 KB file: window visible"),
        ("launch_small_cpu", "2 KB file: CPU"),
        ("launch_big_window", "22 MB file: window visible"),
        ("launch_big_settle", "22 MB file: work done"),
        ("launch_big_cpu", "22 MB file: CPU"),
        ("launch_md_settle", "2 MB Markdown: work done"),
        ("launch_md_cpu", "2 MB Markdown: CPU"),
    ]),
    ("Memory", [
        ("mem_small", "1 small file"),
        ("mem_small_2s", "1 small file, 2 s later"),
        ("mem_ten", "11 files"),
        ("mem_md", "2 MB Markdown file"),
        ("mem_md_2s", "2 MB Markdown, 2 s later"),
        ("mem_big", "22 MB file"),
        ("mem_big_2s", "22 MB file, 2 s later"),
    ]),
    ("Idle and size", [
        ("idle_cpu", "CPU at idle, 15 s, 11 files"),
        ("app_size", "App size"),
    ]),
]

W = 1200
PAD = 48
LABEL_W = 318
ROW_H = 40
GROUP_H = 38
HEAD_H = 98
ICON = 48


def font_face(family: str, weight: str, path: Path, text: str) -> str:
    """The font cut down to the characters the chart uses, as a WOFF2 data URI."""
    font = TTFont(path)
    opts = subset.Options()
    opts.flavor = "woff2"
    opts.layout_features = ["kern", "liga", "tnum", "lnum"]
    sub = subset.Subsetter(opts)
    sub.populate(text=text)
    sub.subset(font)
    buf = io.BytesIO()
    font.flavor = "woff2"
    font.save(buf)
    b64 = base64.b64encode(buf.getvalue()).decode()
    return f"@font-face{{font-family:'{family}';font-weight:{weight};src:url(data:font/woff2;base64,{b64}) format('woff2');}}"


def take_icons(apps: list, force: bool = False) -> None:
    """Writes bench/icons/<app>.png from each installed app, for the ones missing (or all, with force)."""
    todo = [a for a in apps if force or not (ICONS / f"{a}.png").exists()]
    if not todo:
        return
    ICONS.mkdir(parents=True, exist_ok=True)
    pairs = [f"{a}={APP_PATHS[a]}" for a in todo if a in APP_PATHS]
    subprocess.run(["swift", str(ROOT / "bench/appicons.swift"), str(ICONS), str(ICON_PX), *pairs], check=True)


def icon(app: str, x: float, y: float) -> str:
    """The app's icon as an embedded PNG, or nothing when there's no icon file."""
    path = ICONS / f"{app}.png"
    if not path.exists():
        return ""
    b64 = base64.b64encode(path.read_bytes()).decode()
    return f'<image x="{x:.1f}" y="{y:.1f}" width="{ICON}" height="{ICON}" href="data:image/png;base64,{b64}"/>'


def mix(a: str, b: str, t: float) -> str:
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))


def scale_colour(t: float) -> str:
    for (t0, c0), (t1, c1) in zip(SCALE, SCALE[1:]):
        if t <= t1:
            return mix(c0, c1, (t - t0) / (t1 - t0))
    return SCALE[-1][1]


def fmt(v: float, unit: str) -> str:
    if unit == "MB":
        return f"{v:.1f} MB" if v < 10 else f"{v:,.0f} MB"
    return f"{v:,.0f} ms"


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def logo(x: float, y: float, size: float) -> str:
    raw = (KIT / "logo/nic-logo.svg").read_text(encoding="utf-8")
    inner = re.search(r"<svg[^>]*>(.*)</svg>", raw, re.S).group(1)
    return f'<svg x="{x}" y="{y}" width="{size}" height="{size}" viewBox="0 0 1000 1000">{inner}</svg>'


def build(results: dict) -> str:
    apps = results["apps"]
    med = results["medians"]
    # Rows an older results file doesn't have (the 2 s memory rows came on 13th October 2026) are left out.
    groups = [(title, [r for r in rows if r[0] in med]) for title, rows in GROUPS]
    units = {r["key"]: r["unit"] for r in results["rows"]}
    col_w = (W - 2 * PAD - LABEL_W) / len(apps)
    x0 = PAD + LABEL_W
    out = []
    texts = []  # every string drawn, for the font subsets

    def text(x, y, s, size, weight=400, fill=INK, anchor="start", family="Lato", extra=""):
        texts.append(s)
        out.append(f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
                   f'fill="{fill}" text-anchor="{anchor}"{extra}>{esc(s)}</text>')

    # Header: logo, title, subtitle, red rule.
    y = PAD
    out.append(logo(PAD, y - 4, 56))
    text(PAD + 72, y + 26, "Textee against 4 Mac text editors", 32, 700, family="Montserrat")
    d = date.fromisoformat(results["date"][:10])
    when = f"{d.day}{'th' if 11 <= d.day <= 13 else {1: 'st', 2: 'nd', 3: 'rd'}.get(d.day % 10, 'th')} {d:%B %Y}"
    text(PAD + 72, y + 52, f"Speed and memory, measured from outside each app the same way. Lower is better on every row. "
                           f"{when}, {results['machine']}.", 15, 400, MUTED)
    y += 76
    out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="4" fill="{RED}"/>')
    y += 22

    # Column heads: black band, app icons and names.
    out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="{HEAD_H}" rx="4" fill="{INK}"/>')
    text(PAD + 16, y + 78, "Measure", 15, 700, "#ffffff")
    for i, app in enumerate(apps):
        cx = x0 + col_w * (i + 0.5)
        out.append(icon(app, cx - ICON / 2, y + 10))
        text(cx, y + 78, app, 17, 900 if app == "Textee" else 700, "#ffffff", "middle")
        if app == "Textee":
            out.append(f'<rect x="{cx - 24:.1f}" y="{y + 86}" width="48" height="3" rx="1.5" fill="{RED}"/>')
    y += HEAD_H + 6

    wins = {a: 0 for a in apps}
    gaps = {a: [] for a in apps}
    for title, rows in groups:
        out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="{GROUP_H - 6}" fill="{BAND}"/>')
        out.append(f'<rect x="{PAD}" y="{y}" width="4" height="{GROUP_H - 6}" fill="{RED}"/>')
        text(PAD + 16, y + 21, title.upper(), 12.5, 700, INK, extra=' letter-spacing="1.2"')
        y += GROUP_H
        for key, label in rows:
            vals = {a: max(med[key][a], 0.5) for a in apps}
            best, worst = min(vals.values()), max(vals.values())
            text(PAD + 16, y + ROW_H / 2 + 5, label, 15.5, 400)
            for i, app in enumerate(apps):
                v = vals[app]
                gaps[app].append(v / best)
                won = v <= best * (1 + TIE)
                t = math.log(v / best) / math.log(worst / best) if worst > best else 0
                cx = x0 + col_w * i + 4
                fill = GREEN if won else scale_colour(t)
                out.append(f'<rect x="{cx:.1f}" y="{y + 3}" width="{col_w - 8:.1f}" height="{ROW_H - 6}" rx="4" fill="{fill}"/>')
                text(x0 + col_w * (i + 0.5), y + ROW_H / 2 + 5, fmt(med[key][app], units[key]), 15,
                     700 if won else 400, "#ffffff" if won else INK, "middle", extra=' font-variant-numeric="tabular-nums"')
                if won:
                    wins[app] += 1
            out.append(f'<line x1="{PAD}" y1="{y + ROW_H}" x2="{W - PAD}" y2="{y + ROW_H}" stroke="{LINE}" stroke-width="1"/>')
            y += ROW_H
        y += 6

    # Summary: wins, and the average distance from the best (geometric mean of value / best).
    y += 8
    out.append(f'<rect x="{PAD}" y="{y}" width="{W - 2 * PAD}" height="{2 * ROW_H + 30}" rx="4" fill="{INK}"/>')
    n_rows = sum(len(r) for _, r in groups)
    text(PAD + 16, y + 34, f"Wins, out of {n_rows}", 16, 700, "#ffffff")
    text(PAD + 16, y + 34 + ROW_H + 4, "Average distance from the best", 16, 700, "#ffffff")
    text(PAD + 16, y + 34 + ROW_H + 24, "geometric mean of value / best value", 12, 400, "#a1a1a8")
    top = max(wins.values())
    geo = {a: math.exp(sum(math.log(g) for g in gaps[a]) / len(gaps[a])) for a in apps}
    best_geo = min(geo.values())
    for i, app in enumerate(apps):
        cx = x0 + col_w * (i + 0.5)
        lead = wins[app] == top
        text(cx, y + 38, str(wins[app]), 26 if lead else 22, 900 if lead else 700, RED if lead else "#ffffff", "middle")
        lead = geo[app] <= best_geo * 1.0001
        text(cx, y + 38 + ROW_H + 4, f"{geo[app]:.1f}x", 22 if lead else 19, 900 if lead else 700,
             RED if lead else "#ffffff", "middle")
    y += 2 * ROW_H + 30 + 22

    # Legend and notes.
    out.append(f'<rect x="{PAD}" y="{y}" width="34" height="18" rx="3" fill="{GREEN}"/>')
    text(PAD + 44, y + 14, "Best, or within 5% of the best", 13.5, 400, MUTED)
    lx = PAD + 290
    stops = "".join(f'<stop offset="{t}" stop-color="{c}"/>' for t, c in SCALE)
    out.append(f'<defs><linearGradient id="g" x1="0" x2="1">{stops}</linearGradient></defs>')
    out.append(f'<rect x="{lx}" y="{y}" width="160" height="18" rx="3" fill="url(#g)"/>')
    text(lx + 170, y + 14, "Closer to the best  →  further from it (log scale)", 13.5, 400, MUTED)
    y += 40
    load = results["load"]
    notes = [
        f"Medians of rounds 2 to {results['rounds']}: round 1 is a warm-up. Every app ran with its owner's settings, "
        f"no session restore, a 1920 × 1080 window and the same files.",
        f"The Mac was busy (load average {load[0]:.0f} to {load[1]:.0f}), so CPU time is steadier than clock time. "
        f"Launch times include about 1 s of macOS work.",
        "TextEdit doesn't colour Markdown or code; the 4 others do. Sublime Text's figures include its plugin processes.",
    ]
    for n in notes:
        text(PAD, y, n, 13.5, 400, MUTED)
        y += 22
    y += 10
    out.append(f'<line x1="{PAD}" y1="{y}" x2="{W - PAD}" y2="{y}" stroke="{LINE}" stroke-width="1"/>')
    y += 28
    text(PAD, y, "NicAI", 14, 900, INK, family="Montserrat")
    text(PAD + 52, y, "notes.nicolasdeville.com  ·  Textee", 13.5, 400, MUTED)
    text(W - PAD, y, "Lower is better", 13.5, 700, RED, "end")
    H = y + PAD - 12

    chars = "".join(texts) + "0123456789.,x "
    fonts = KIT / "fonts"
    style = "".join([
        font_face("Lato", "400", fonts / "lato-latin-400-normal.woff2", chars),
        font_face("Lato", "700", fonts / "lato-latin-700-normal.woff2", chars),
        font_face("Lato", "900", fonts / "lato-latin-900-normal.woff2", chars),
        font_face("Montserrat", "100 900", fonts / "montserrat-latin-wght-normal.woff2", chars),
    ])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'xmlns:xlink="http://www.w3.org/1999/xlink" role="img" aria-label="Textee against TextMate, CotEditor, Sublime Text and TextEdit: speed and memory">'
            f'<style>{style}text{{font-kerning:normal}}</style>'
            f'<rect width="{W}" height="{H}" fill="#ffffff"/>' + "".join(out) + "</svg>")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(ROOT / "bench/results.json"))
    ap.add_argument("--out", default=str(ROOT / "bench/editors.svg"))
    ap.add_argument("--icons", action="store_true", help="take every app icon again")
    args = ap.parse_args()
    results = json.loads(Path(args.results).read_text(encoding="utf-8"))
    take_icons(results["apps"], force=args.icons)
    svg = build(results)
    Path(args.out).write_text(svg, encoding="utf-8")
    print(f"✅ {args.out} ({len(svg) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
