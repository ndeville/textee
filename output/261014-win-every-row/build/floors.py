#!/usr/bin/env python3
"""Textee against a bare TextKit 1 and a bare TextKit 2 text view: launch time and memory, small file and 2 MB Markdown.

Needs the bench fixtures and the Textee bench copy that bench.py makes, and the 2 minimal apps from mini.swift
in $TMPDIR/textee-lang. Writes data/floors.json and data/fp-<app>-<file>.txt (footprint by category, 2 s after settle).
"""

import json
import os
import plistlib
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/Users/nic/ai/lab/textee")
import bench  # noqa: E402

T = Path(os.environ["TMPDIR"]).resolve()
FILES = T / "textee-bench/files"
DATA = Path(__file__).resolve().parent.parent / "data"
APPS_ALL = {
    "Textee": (bench.TEXTEE_COPY, ["--env", f"TEXTEE_HOME={bench.TEXTEE_HOME}"], True),
    "MiniTK1": (T / "textee-lang/MiniTK1.app", ["--env", "MINI_MODE=tk1"], False),
    "MiniTK1short": (T / "textee-lang/MiniTK1short.app", ["--env", "MINI_MODE=tk1short"], False),
    "MiniTK2": (T / "textee-lang/MiniTK2.app", ["--env", "MINI_MODE=tk2"], False),
    "MiniCT": (T / "textee-lang/MiniCT.app", ["--env", "MINI_MODE=ct"], False),
}
APPS = {k: v for k, v in APPS_ALL.items() if k in os.environ.get("APPS", ",".join(APPS_ALL)).split(",")}
IDS = ["com.nicolasdeville.textee.bench", "com.nicolasdeville.minitk1short", "com.nicolasdeville.minitk1", "com.nicolasdeville.minitk2", "com.nicolasdeville.minict"]
ROUNDS = int(os.environ.get("ROUNDS", "5"))
ONLY = os.environ.get("ONLY", "small,md,big").split(",")
OUT = os.environ.get("OUT", "floors")


def launch(name: str, file: Path) -> dict:
    app, pre, takes_file = APPS[name]
    if not takes_file:
        pre = pre + ["--env", f"MINI_FILE={file}"]
    subprocess.run(["defaults", "write", bench.TEXTEE_BENCH_ID, "NSWindow Frame TexteeMain", "-string", bench.FRAME], check=True)
    env = dict(os.environ, PROBE_OPEN_PRE=json.dumps(pre), PROBE_OPEN_POST=json.dumps(bench.NO_RESTORE))
    args = [str(bench.PROBE), "launch", str(app)] + ([str(file)] if takes_file else [])
    out = subprocess.run(args, capture_output=True, text=True, env=env, check=True).stdout
    return json.loads(out.strip().splitlines()[-1])


def main() -> None:
    DATA.mkdir(exist_ok=True)
    bench.make_textee_copy(force=True)
    floating = bench.amethyst_floating(IDS)
    print(f"load {[round(x, 1) for x in os.getloadavg()]}")
    res = {}
    try:
        for label, file in [("small", FILES / "scratch.txt"), ("md", FILES / "big.md"), ("big", FILES / "big.txt")]:
            if label not in ONLY:
                continue
            for rnd in range(ROUNDS):
                names = list(APPS)
                for name in names[rnd % len(names):] + names[:rnd % len(names)]:
                    r = launch(name, file)
                    time.sleep(2)
                    r["mem2s"] = json.loads(subprocess.run([str(bench.PROBE), "stat", str(r["pid"])], capture_output=True,
                                                           text=True, check=True).stdout)["footprintMB"]
                    if rnd == ROUNDS - 1:
                        fp = subprocess.run(["footprint", str(r["pid"])], capture_output=True, text=True).stdout
                        (DATA / f"fp-{name}-{label}.txt").write_text(fp, encoding="utf-8")
                    bench.kill(r["pid"])
                    time.sleep(1)
                    res.setdefault(f"{name}/{label}", []).append(r)
                    print(f"  {label} round {rnd + 1} {name:8} window {r['windowMs']:6.0f} ms  mem {r['footprintMB']:5.1f}  2 s {r['mem2s']:5.1f} MB  {r.get('windows')}")
    finally:
        bench.set_amethyst_floating(floating)
    summary = {}
    for k, rs in res.items():
        med = lambda f: round(statistics.median(x[f] for x in rs[1:]), 1)
        summary[k] = {f: med(f) for f in ("windowMs", "settleMs", "cpuMs", "footprintMB", "mem2s")}
        print(f"{k:16} {summary[k]}")
    print(f"load {[round(x, 1) for x in os.getloadavg()]}")
    (DATA / f"{OUT}.json").write_text(json.dumps({"summary": summary, "runs": res}, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
