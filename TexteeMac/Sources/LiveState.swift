import Foundation

/// The live state for agents: `~/.textee/live.json`, read by `textee status` (agent interface, SPEC.md 6.1).
/// `state.json` already holds the recent files and view settings, so the live state has its own file.
/// Written atomically on a background queue, coalesced to 1 write per run-loop turn.
enum LiveState {
    private static let queue = DispatchQueue(label: "com.nicolasdeville.textee.live", qos: .utility)
    private static let startedAt = Date()
    private static var scheduled = false
    weak static var controller: MainWindowController?
    /// The last URL action, echoed with the caller's request id so the CLI can confirm it ran.
    private static var lastAction: [String: Any]?

    static var url: URL { AppPaths.home.appendingPathComponent("live.json") }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    static func record(action: String, rid: String?, ok: Bool) {
        lastAction = ["name": action, "rid": rid ?? "", "ok": ok, "at": iso(Date())]
        publish()
    }

    /// Ask for a write. Many changes in 1 turn (10 files opened at once) make 1 write.
    static func publish() {
        if TextFile.readOnlyMode || scheduled { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            write()
        }
    }

    private static func write() {
        let docs = controller?.documents ?? []
        let active = controller?.activeDocument
        var state: [String: Any] = [
            "pid": Int(getpid()),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "started_at": iso(startedAt),
            "bundle_path": Bundle.main.bundlePath,
            "updated_at": iso(Date()),
            "tabs": docs.map { ["path": $0.url.path, "unsaved": $0.isDirty, "conflict": $0.conflict, "active": $0 === active] },
            "active_path": active.map { $0.url.path as Any } ?? NSNull(),
            "scratch_dir": AppPaths.scratchDir.path,
        ]
        if let lastAction { state["last_action"] = lastAction }
        let target = url
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }
}
