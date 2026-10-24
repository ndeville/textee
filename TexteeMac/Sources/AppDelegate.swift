import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MainWindowController()
    private var pendingURLs: [URL] = []
    private var launched = false
    var launchedAt = ProcessInfo.processInfo.systemUptime

    func applicationWillFinishLaunching(_ notification: Notification) {
        Profile.mark("willFinishLaunching")
        SquareWindows.install()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // The full menu bar costs 25 to 80 ms: it's built after the window is on screen.
        NSApp.mainMenu = MenuBuilder.launchMenu()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Profile.mark("didFinishLaunching")
        launched = true
        LiveState.controller = controller
        let urls = pendingURLs
        pendingURLs = []
        for u in urls { route(u) }
        if urls.isEmpty { DispatchQueue.main.async { TextSystem.warmUp() } }
        // No session restore, no new document at launch (as TextMate was set up). The window shows empty.
        if controller.documents.isEmpty { controller.showWindow() }
        Profile.mark("window shown")
        LiveState.publish()
        if let qa = ProcessInfo.processInfo.environment["TEXTEE_QA"] {
            MenuBuilder.installFullMenu()
            Settings.watch()
            QAHarness.run(scriptPath: qa, app: self)
        } else {
            // After the first frame. Until then only ⌘Q works, for about 0.1 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MenuBuilder.installFullMenu()
                Settings.watch()
            }
        }
    }

    /// Dock click or `open -a Textee` with no window: show the window, without a new document.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller.showWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.prepareToQuit()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if launched { route(u) } else { pendingURLs.append(u) }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if launched { route(url) } else { pendingURLs.append(url) }
    }

    /// File URLs open in a tab. `textee://new-from-clipboard`, `textee://new`, `textee://open?path=...`,
    /// `textee://quick-open`, `textee://save-all`, `textee://show`.
    /// Agent interface: a URL with a request id (`rid`) is echoed in live.json, and it doesn't bring Textee to the
    /// front unless it also has `show=1` (`textee` CLI, `open -g`). URLs without `rid` (Alfred `ca`) activate as before.
    func route(_ url: URL) {
        if url.isFileURL {
            // No activation here: LaunchServices brings Textee to the front for a file it opens. Activating once
            // per file made a 9-file open wait up to 2 s on the window server.
            controller.open(url)
            return
        }
        var front = true
        if url.scheme == "textee" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let rid = q.first(where: { $0.name == "rid" })?.value
            if rid != nil { front = q.contains { $0.name == "show" && $0.value == "1" } }
            let action = url.host ?? url.path
            var ok = true
            switch action {
            case "new-from-clipboard": ok = controller.createScratch(text: Clip.string ?? "") != nil
            case "new": ok = controller.createScratch(text: "") != nil
            case "quick-open": controller.showQuickOpen(nil)
            case "save-all": controller.saveAll()
            case "show": front = true
            case "open":
                if let path = q.first(where: { $0.name == "path" })?.value {
                    ok = controller.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) != nil
                } else { ok = false }
            default: ok = false
            }
            if rid != nil { LiveState.record(action: action, rid: rid, ok: ok) }
        }
        guard front else { return }
        // `ca` from Alfred: Textee must come to the front with the new tab.
        if ProcessInfo.processInfo.environment["TEXTEE_QA"] == nil { NSApp.activate() }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // Commands that work with no window on screen (the responder chain ends here).
    @objc func newScratch(_ sender: Any?) { controller.newScratch(sender) }
    @objc func newFromClipboard(_ sender: Any?) { controller.newFromClipboard(sender) }
    @objc func openDocument(_ sender: Any?) { controller.openDocument(sender) }
    @objc func showQuickOpen(_ sender: Any?) { controller.showQuickOpen(sender) }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}

/// The menu bar. Standard titles (Copy, Paste, Find…), so Nic's global App Shortcuts apply to them;
/// the same keys are set here as well, as in Notee.
enum MenuBuilder {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    static func arrow(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code))!)) }

    /// The menu item whose shortcut is ⌥ + `key`.
    static func optionItem(_ key: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let found = optionItem(key, in: item.submenu) { return found }
            if item.keyEquivalent == key, item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .option { return item }
        }
        return nil
    }

    private static var fullMenuInstalled = false

    /// The menu bar during launch: the app menu with Quit only.
    static func launchMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Textee")
        app.addItem(item("Quit Textee", #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)
        return main
    }

    static func installFullMenu() {
        guard !fullMenuInstalled else { return }
        fullMenuInstalled = true
        Profile.mark("full menu")
        NSApp.mainMenu = build()
        Profile.mark("full menu set")
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Textee")
        app.addItem(item("About Textee", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(servicesItem)
        app.addItem(.separator())
        app.addItem(item("Hide Textee", #selector(NSApplication.hide(_:))))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Textee", #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("New Scratch File", #selector(MainWindowController.newScratch(_:)), "n"))
        file.addItem(item("New from Clipboard", #selector(MainWindowController.newFromClipboard(_:)), "n", [.command, .shift]))
        file.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        file.addItem(item("Quick Open…", #selector(MainWindowController.showQuickOpen(_:)), "p"))
        file.addItem(item("Recent Files…", #selector(MainWindowController.showQuickOpen(_:)), "h"))
        file.addItem(.separator())
        file.addItem(item("Save", #selector(MainWindowController.saveDocument(_:)), "s"))
        file.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        file.addItem(item("Close Tab ", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift]))
        file.addItem(item("Close Window", #selector(MainWindowController.closeWindow(_:)), "w", [.command, .control]))
        file.addItem(.separator())
        file.addItem(item("Open in Notee", #selector(MainWindowController.openInNotee(_:)), "o", [.command, .option]))
        file.addItem(item("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]))
        file.addItem(item("Copy Path", #selector(MainWindowController.copyPath(_:)), "d", [.command, .shift]))
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "d"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "f"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "f", [.option]))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(MainWindowController.showFind(_:)), "f", [.command, .shift]))
        edit.addItem(item("Find Next", #selector(MainWindowController.findNext(_:))))
        edit.addItem(item("Find Previous", #selector(MainWindowController.findPrevious(_:))))
        edit.addItem(item("Hide Find Bar", #selector(MainWindowController.hideFindBar(_:)), "f", [.control]))
        edit.addItem(.separator())
        edit.addItem(item("Duplicate Line or Selection", #selector(EditorTextView.duplicateLine(_:)), "t"))
        edit.addItem(item("Delete Line", #selector(EditorTextView.deleteLine(_:)), "d", [.option]))
        edit.addItem(item("Move Line Up", #selector(EditorTextView.moveLineUp(_:)), arrow(NSUpArrowFunctionKey), [.option]))
        edit.addItem(item("Move Line Down", #selector(EditorTextView.moveLineDown(_:)), arrow(NSDownArrowFunctionKey), [.option]))
        edit.addItem(item("Indent", #selector(EditorTextView.indentSelection(_:)), "]"))
        edit.addItem(item("Outdent", #selector(EditorTextView.outdentSelection(_:)), "["))
        edit.addItem(.separator())
        edit.addItem(item("Add Next Match", #selector(EditorTextView.addNextOccurrence(_:)), "\r", [.option]))
        edit.addItem(item("Select All Matches", #selector(EditorTextView.selectAllOccurrences(_:)), "a", [.command, .shift]))
        edit.addItem(item("Bold (Markdown)", #selector(EditorTextView.boldSelection(_:)), "b", [.command, .shift]))
        add(edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(item("Soft Wrap", #selector(MainWindowController.toggleSoftWrap(_:)), "z", [.option]))
        view.addItem(item("Line Numbers", #selector(MainWindowController.toggleLineNumbers(_:))))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="))
        view.addItem(item("Zoom In ", #selector(MainWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(MainWindowController.zoomReset(_:)), "0"))
        add(view, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]))
        window.addItem(item("Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift]))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        add(window, to: main)

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        main.addItem(i)
    }
}

/// The first text view of a process pays for loading the text system and the editor font (about 15 ms).
/// After a plain launch, Textee pays it while idle, so the first file opens as fast as the next ones.
enum TextSystem {
    static func warmUp() {
        let loaded = LoadedText(string: "warm up\n# **x** `y`\n")
        let doc = Document(url: URL(fileURLWithPath: "/tmp/textee-warm-up.md"), loaded: loaded)
        let ev = doc.editor
        ev.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        ev.layoutSubtreeIfNeeded()
        ev.highlightVisible()
        if let rep = ev.bitmapImageRepForCachingDisplay(in: ev.bounds) { ev.cacheDisplay(in: ev.bounds, to: rep) }
        _ = Counter.words(doc.storage.string as NSString, NSRange(location: 0, length: doc.storage.length))
    }
}
