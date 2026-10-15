import json, os, subprocess, time, statistics
from pathlib import Path
T = Path(os.environ["TMPDIR"]).resolve()
D, B, F = T / "textee-lang", T / "textee-bench", T / "textee-bench" / "files"
PROBE = "/Users/nic/ai/lab/textee/build.noindex/appprobe"
NO_RESTORE = ["--args", "-ApplePersistenceIgnoreState", "YES"]
APPS = {
    "Textee": (B / "Textee Bench.app", ["--env", f"TEXTEE_HOME={B / 'textee-home'}"], [str(F / "scratch.txt")]),
    "MiniSwift": (D / "MiniSwift.app", ["--env", f"MINI_FILE={F / 'scratch.txt'}"], []),
    "MiniRust": (D / "MiniRust.app", ["--env", f"MINI_FILE={F / 'scratch.txt'}"], []),
}
print("load", [round(x, 1) for x in os.getloadavg()])
res = {a: [] for a in APPS}
names = list(APPS)
for rnd in range(7):
    order = names[rnd % 3:] + names[:rnd % 3]
    for a in order:
        app, pre, files = APPS[a]
        env = dict(os.environ, PROBE_OPEN_PRE=json.dumps(pre), PROBE_OPEN_POST=json.dumps(NO_RESTORE if a == "Textee" else []))
        r = json.loads(subprocess.run([PROBE, "launch", str(app), *files], capture_output=True, text=True, env=env, check=True).stdout.strip().splitlines()[-1])
        time.sleep(2)
        r["mem2s"] = json.loads(subprocess.run([PROBE, "stat", str(r["pid"])], capture_output=True, text=True, check=True).stdout)["footprintMB"]
        subprocess.run(["pkill", "-P", str(r["pid"])]); subprocess.run(["kill", str(r["pid"])])
        time.sleep(1.0)
        res[a].append(r)
for a, rs in res.items():
    med = lambda k: round(statistics.median(x[k] for x in rs), 1)
    print(f"{a:10} window {med('windowMs'):7} settle {med('settleMs'):7} cpu {med('cpuMs'):6} mem {med('footprintMB'):5} mem2s {med('mem2s'):5} sizes {rs[0]['windows']}")
print("load", [round(x, 1) for x in os.getloadavg()])
