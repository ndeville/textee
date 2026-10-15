import Foundation

enum AppPaths {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Config folder: `~/.textee`, or TEXTEE_HOME (QA).
    static var home: URL {
        if let h = env["TEXTEE_HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".textee")
    }

    /// Scratch folder: `~/txt`, or TEXTEE_TXT_DIR (QA). Real path, so it compares equal to opened files.
    static let scratchDir: URL = {
        let d = env["TEXTEE_TXT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("txt")
        return TextFile.canonical(d)
    }()
}

/// `~/.textee/state.json`: recent files, zoom, soft wrap, line numbers. No session restore (Nic's choice).
struct AppState: Codable {
    var recentFiles: [String] = []
    var fontSize: Double = 14
    var softWrap: Bool = true
    var lineNumbers: Bool = true

    static var url: URL { AppPaths.home.appendingPathComponent("state.json") }

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppState.self, from: data) else { return AppState() }
        return s
    }

    func save() {
        if TextFile.readOnlyMode { return }
        try? FileManager.default.createDirectory(at: AppPaths.home, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: AppState.url, options: .atomic) }
    }

    mutating func touch(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 300 { recentFiles.removeLast(recentFiles.count - 300) }
    }
}
