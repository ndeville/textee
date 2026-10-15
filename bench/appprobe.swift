// appprobe: measures a Mac app from outside, with no special permission.
//
//   appprobe launch <app path> <file>...   open -n -g the app with files: window time, settle time, CPU, memory
//   appprobe open <pid> <app path> <file>... open files in the running app: settle time, CPU, memory
//   appprobe idle <pid> <seconds>          CPU time and wake-ups while idle
//   appprobe stat <pid>                    memory and threads now
//
// "Window" = the first normal window of the process is on screen.
// "Settle" = the process CPU time stopped growing (under 2 ms in 300 ms): the app finished the work.
// CPU, memory and threads include the app's child processes (Sublime Text's plugin hosts).
// PROBE_OPEN_PRE and PROBE_OPEN_POST (JSON arrays) add `open` options before `-a` and after the files.
import AppKit
import Darwin

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func now() -> Double { Date().timeIntervalSince1970 * 1000 }

struct Usage { var cpuMs: Double; var footprintMB: Double; var wakeups: UInt64 }

func ownUsage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    let ticks = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
    return Usage(cpuMs: ticks / 1e6, footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
                 wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups)
}

func allPids() -> [pid_t] {
    var buf = [pid_t](repeating: 0, count: 4096)
    let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return buf.prefix(Int(max(n, 0))).filter { $0 > 0 }
}

/// The app and every process below it. Rebuilt at most every 200 ms: listing all processes isn't free.
var treeCache: (root: pid_t, at: Double, pids: [pid_t]) = (0, 0, [])
func tree(_ root: pid_t) -> [pid_t] {
    if treeCache.root == root, now() - treeCache.at < 200 { return treeCache.pids }
    var children: [pid_t: [pid_t]] = [:]
    for p in allPids() {
        var info = proc_bsdinfo()
        if proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            children[pid_t(info.pbi_ppid), default: []].append(p)
        }
    }
    var out = [root], i = 0
    while i < out.count { out += children[out[i]] ?? []; i += 1 }
    treeCache = (root, now(), out)
    return out
}

func usage(_ pid: pid_t) -> Usage? {
    guard var total = ownUsage(pid) else { return nil }
    for p in tree(pid).dropFirst() {
        if let u = ownUsage(p) { total.cpuMs += u.cpuMs; total.footprintMB += u.footprintMB; total.wakeups += u.wakeups }
    }
    return total
}

func threads(_ pid: pid_t) -> Int {
    tree(pid).reduce(0) { sum, p in
        var t = proc_taskinfo()
        let n = proc_pidinfo(p, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
        return sum + (n > 0 ? Int(t.pti_threadnum) : 0)
    }
}

func pids(executable: String) -> Set<pid_t> {
    var out = Set<pid_t>()
    var path = [CChar](repeating: 0, count: 4096)
    for p in allPids() {
        if proc_pidpath(p, &path, UInt32(path.count)) > 0, String(cString: path) == executable { out.insert(p) }
    }
    return out
}

func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = w[kCGWindowBounds as String] as? [String: Double], (b["Height"] ?? 0) > 150 { return true }
    }
    return false
}

/// Sizes of the app's normal windows on screen, largest first: memory and layout work grow with the window.
func windowSizes(_ pid: pid_t) -> [[Int]] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w -> [Int]? in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double], (b["Height"] ?? 0) > 150 else { return nil }
        return [Int(b["Width"] ?? 0), Int(b["Height"] ?? 0)]
    }.sorted { $0[0] * $0[1] > $1[0] * $1[1] }
}

/// Waits until the CPU time of `pid` grows less than 2 ms over 300 ms. Returns the time of the last growth.
func settle(_ pid: pid_t, from start: Double, baseCPU: Double, timeout: Double = 20_000) -> (Double, Usage) {
    var lastCPU = baseCPU
    var lastGrowth = start
    while now() - start < timeout {
        usleep(5_000)
        guard let u = usage(pid) else { break }
        if u.cpuMs - lastCPU > 0.4 { lastGrowth = now() }
        lastCPU = u.cpuMs
        if now() - lastGrowth > 300 { return (lastGrowth - start, u) }
    }
    return (timeout, usage(pid) ?? Usage(cpuMs: 0, footprintMB: 0, wakeups: 0))
}

func json(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func envList(_ name: String) -> [String] {
    guard let s = ProcessInfo.processInfo.environment[name], let d = s.data(using: .utf8),
          let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
    return a
}

/// `open <options> -a <app> <files> <post>`: options and post come from PROBE_OPEN_PRE and PROBE_OPEN_POST.
func runOpen(_ options: [String], app: String, files: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = options + envList("PROBE_OPEN_PRE") + ["-a", app] + files + envList("PROBE_OPEN_POST")
    try! p.run()
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "launch":
    let app = a[2]
    let exe = URL(fileURLWithPath: Bundle(path: app)!.executablePath!).resolvingSymlinksInPath().path
        .replacingOccurrences(of: "^/var/", with: "/private/var/", options: .regularExpression)
    let before = pids(executable: exe)
    let start = now()
    runOpen(["-n", "-g"], app: app, files: Array(a.dropFirst(3)))
    var pid: pid_t = 0
    while now() - start < 15_000 {
        if let p = pids(executable: exe).subtracting(before).first { pid = p; break }
        usleep(1_000)
    }
    guard pid > 0 else { json(["error": "no process"]); exit(1) }
    let spawned = now() - start
    var window = -1.0
    while now() - start < 15_000 {
        if hasWindow(pid) { window = now() - start; break }
        usleep(2_000)
    }
    let (settled, u) = settle(pid, from: start, baseCPU: 0)
    json(["pid": pid, "spawnMs": spawned, "windowMs": window, "settleMs": settled, "cpuMs": u.cpuMs,
          "footprintMB": u.footprintMB, "threads": threads(pid), "windows": windowSizes(pid)])
case "open":
    let pid = pid_t(a[2])!
    let base = usage(pid)!
    let start = now()
    runOpen(["-g"], app: a[3], files: Array(a.dropFirst(4)))
    let (settled, u) = settle(pid, from: start, baseCPU: base.cpuMs)
    json(["settleMs": settled, "cpuMs": u.cpuMs - base.cpuMs, "footprintMB": u.footprintMB, "threads": threads(pid),
          "windows": windowSizes(pid)])
case "idle":
    let pid = pid_t(a[2])!
    let secs = Double(a[3])!
    let b = usage(pid)!
    usleep(UInt32(secs * 1e6))
    let e = usage(pid)!
    json(["cpuMs": e.cpuMs - b.cpuMs, "wakeupsPerSec": Double(e.wakeups - b.wakeups) / secs, "footprintMB": e.footprintMB, "threads": threads(pid)])
case "stat":
    let pid = pid_t(a[2])!
    let u = usage(pid)!
    json(["footprintMB": u.footprintMB, "cpuMs": u.cpuMs, "threads": threads(pid)])
default:
    print("usage: appprobe launch|open|idle|stat ...")
    exit(2)
}
