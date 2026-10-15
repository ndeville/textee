import AppKit

/// `~/.textee/settings.json`: Nic's own settings. Textee only reads this file (state.json is the one it writes).
/// A save while Textee runs applies at once.
struct Settings: Equatable {
    var windowCorners = "rounded"   // "rounded" or "square"
    var cornerRadius: CGFloat = 4   // 0 (square) to 10: tabs, buttons, the quick-open panel

    static var url: URL { AppPaths.home.appendingPathComponent("settings.json") }
    static private(set) var current = Settings.load()
    static let changed = Notification.Name("TexteeSettingsChanged")

    /// Unknown corners read as rounded, the radius stays inside 0 to 10.
    static func load() -> Settings {
        var s = Settings()
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        if json["windowCorners"] as? String == "square" { s.windowCorners = "square" }
        if let r = json["cornerRadius"] as? Double { s.cornerRadius = CGFloat(min(max(r, 0), 10)) }
        return s
    }

    /// A highlight radius scaled from its design value: at the default of 4, nothing changes.
    static func radius(_ base: CGFloat) -> CGFloat { base * current.cornerRadius / 4 }

    static func reload() {
        let s = load()
        guard s != current else { return }
        current = s
        WindowCorners.refresh()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static var folderWatch: DispatchSourceFileSystemObject?
    private static var fileWatch: DispatchSourceFileSystemObject?

    /// 2 watches: the folder sees a save that replaces the file (most editors), the file sees a write in place.
    /// No polling, so no wake-ups at idle.
    static func watch() {
        guard folderWatch == nil else { return }
        try? FileManager.default.createDirectory(at: AppPaths.home, withIntermediateDirectories: true)
        folderWatch = source(AppPaths.home.path, [.write]) {
            reload()
            watchFile()
        }
        watchFile()
    }

    /// The file watch follows the file: a replaced file is a new file, so it's watched again.
    private static func watchFile() {
        fileWatch?.cancel()
        fileWatch = source(url.path, [.write, .extend, .delete, .rename]) {
            reload()
            watchFile()
        }
    }

    private static func source(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                               _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }
}

/// Square or rounded window corners. macOS 26 has no public API for the window shape: AppKit asks a window
/// for `_cornerMask`, and uses the answer only when the window's own class overrides it (Filee, 14th October 2026).
/// If a later macOS stops asking, the windows stay rounded and nothing else breaks.
enum WindowCorners {
    static let maskSelector = NSSelectorFromString("_cornerMask")
    private static let changedSelector = NSSelectorFromString("_cornerMaskChanged")

    static var square: Bool { Settings.current.windowCorners == "square" }

    /// 3 px of black, stretched by its cap insets to the whole window.
    private static let squareMask: NSImage = {
        let image = NSImage(size: NSSize(width: 3, height: 3), flipped: false) { r in
            NSColor.black.setFill()
            r.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        return image
    }()

    /// Square, or nil: AppKit then draws its own rounded shape. AppKit's own mask has a smaller radius: don't pass it on.
    static var mask: NSImage? { square ? squareMask : nil }

    /// Settings changed: every window asks for its mask again.
    static func refresh() {
        for w in NSApp.windows where w.responds(to: changedSelector) {
            w.perform(changedSelector)
            w.invalidateShadow()
            w.contentView?.superview?.needsDisplay = true
        }
    }
}

/// Every window Textee makes uses this class, so `windowCorners` reaches it.
class AppWindow: NSWindow {
    @objc func _cornerMask() -> NSImage? { WindowCorners.mask }
}

/// Every panel Textee makes uses this class (none today).
class AppPanel: NSPanel {
    @objc func _cornerMask() -> NSImage? { WindowCorners.mask }
}
