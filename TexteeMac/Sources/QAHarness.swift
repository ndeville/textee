import AppKit

/// The pasteboard Textee reads and writes. QA sets TEXTEE_PASTEBOARD so it never touches Nic's clipboard.
enum Clip {
    static let board: NSPasteboard = {
        if let name = ProcessInfo.processInfo.environment["TEXTEE_PASTEBOARD"] { return NSPasteboard(name: NSPasteboard.Name(name)) }
        return .general
    }()

    static var string: String? { board.string(forType: .string) }

    static func set(_ s: String) {
        board.clearContents()
        board.setString(s, forType: .string)
    }
}

/// Runs a JSON list of steps against the live app (TEXTEE_QA), writes `report.json` to TEXTEE_QA_OUT, then quits.
/// Actions go straight to the window's responder chain, so QA works in the background without taking the screen.
final class QAHarness {
    private let steps: [[String: Any]]
    private let app: AppDelegate
    private let out: URL
    private var results: [[String: Any]] = []
    private var index = 0
    private var c: MainWindowController { app.controller }

    static func run(scriptPath: String, app: AppDelegate) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            FileHandle.standardError.write("❌ QA script unreadable: \(scriptPath)\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        let h = QAHarness(steps: steps, app: app)
        holder = h
        DispatchQueue.main.async { h.start() }
    }

    private static var holder: QAHarness?

    private init(steps: [[String: Any]], app: AppDelegate) {
        self.steps = steps
        self.app = app
        out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTEE_QA_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private func start() {
        Profile.mark("QA start")
        c.window?.displayIfNeeded()
        Profile.mark("first display")
        let launch = (Date().timeIntervalSince1970 - Self.processStart()) * 1000
        results.append(["op": "launch", "ok": true, "ms": launch])
        next()
    }

    static func processStart() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6
    }

    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func next() {
        guard index < steps.count else { finish(); return }
        let step = steps[index]
        index += 1
        let op = step["op"] as? String ?? "?"
        let t0 = ProcessInfo.processInfo.systemUptime
        var r: [String: Any] = ["op": op, "i": index]
        if let label = step["label"] { r["label"] = label }
        do {
            let detail = try perform(op, step)
            r["ok"] = true
            if let detail { r["detail"] = detail }
        } catch let e as QAError {
            r["ok"] = false
            r["detail"] = e.message
        } catch {
            r["ok"] = false
            r["detail"] = "\(error)"
        }
        if r["ms"] == nil { r["ms"] = (ProcessInfo.processInfo.systemUptime - t0) * 1000 }
        if let m = lastMeasure { r["ms"] = m; lastMeasure = nil }
        if let extra = lastExtra { r.merge(extra) { a, _ in a }; lastExtra = nil }
        results.append(r)
        // AppKit closes the undo group of an event when it finishes dispatching that event. QA steps aren't
        // events, so post 1 after each step, as a real key press would be.
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
        let wait = (step["wait"] as? Double) ?? 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.next() }
    }

    private var lastMeasure: Double?
    private var lastExtra: [String: Any]?

    struct QAError: Error { let message: String }

    private func fail(_ m: String) -> QAError { QAError(message: m) }

    private var tv: EditorTextView? {
        guard let d = c.activeDocument, d.hasEditor else { return nil }
        return d.editor.textView
    }

    private func path(_ step: [String: Any], _ key: String = "path") -> URL {
        URL(fileURLWithPath: ((step[key] as? String) ?? "") as NSString as String)
    }

    private func perform(_ op: String, _ s: [String: Any]) throws -> String? {
        switch op {
        case "open":
            let t0 = ProcessInfo.processInfo.systemUptime
            guard c.open(path(s)) != nil else { throw fail("open failed") }
            c.window?.displayIfNeeded()
            lastMeasure = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            return c.activeDocument?.name
        case "url":
            app.route(URL(string: s["url"] as! String)!)
            return c.activeDocument?.name
        case "setPasteboard":
            Clip.set(s["text"] as? String ?? "")
            return nil
        case "assertPasteboard":
            let v = Clip.string ?? ""
            if let e = s["equals"] as? String, v != e { throw fail("pasteboard is \(v.debugDescription)") }
            return nil
        case "type":
            guard let tv else { throw fail("no editor") }
            let text = s["text"] as? String ?? ""
            var times: [Double] = []
            for ch in text {
                let t0 = ProcessInfo.processInfo.systemUptime
                if ch == "\n" { tv.insertNewline(nil) } else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                // Draws the editor into a bitmap: a background window may skip drawing, and the time must include it.
                forceDraw()
                times.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            let sorted = times.sorted()
            lastMeasure = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            lastExtra = ["max": sorted.last ?? 0, "keys": times.count]
            return nil
        case "key":
            let keys = s["keys"] as! String
            guard let item = Self.menuItem(for: keys, in: NSApp.mainMenu!) else { throw fail("no menu item for \(keys)") }
            guard dispatch(item) else { throw fail("\(item.title): nobody handled it") }
            return item.title
        case "keyEvent":
            // A key press handed to the text view, as AppKit does after its menu pass. "key" goes through the menu.
            guard let window = c.window else { throw fail("no window") }
            var mods: NSEvent.ModifierFlags = []
            for m in (s["mods"] as? [String]) ?? [] {
                switch m {
                case "cmd": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt": mods.insert(.option)
                case "ctrl": mods.insert(.control)
                default: break
                }
            }
            guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: s["chars"] as! String,
                                            charactersIgnoringModifiers: s["base"] as! String, isARepeat: false,
                                            keyCode: UInt16(s["code"] as! Int)) else { throw fail("no event") }
            guard let tv else { throw fail("no editor") }
            tv.keyDown(with: ev)
            return "keyDown"
        case "action":
            let sel = Selector(s["name"] as! String)
            let item = NSMenuItem(title: "QA", action: sel, keyEquivalent: "")
            guard dispatch(item) else { throw fail("nobody handles \(sel)") }
            return nil
        case "select":
            guard let tv else { throw fail("no editor") }
            let loc = s["location"] as? Int ?? 0
            tv.setSelectedRange(NSRange(location: loc == -1 ? (tv.string as NSString).length : loc, length: s["length"] as? Int ?? 0))
            return nil
        case "selectText":
            guard let tv else { throw fail("no editor") }
            let r = (tv.string as NSString).range(of: s["text"] as! String)
            guard r.location != NSNotFound else { throw fail("text not found") }
            tv.setSelectedRange(r)
            return nil
        case "assertText":
            guard let tv else { throw fail("no editor") }
            try check(tv.string, s, what: "text")
            return nil
        case "assertFile":
            let u = path(s)
            if let exists = s["exists"] as? Bool {
                if FileManager.default.fileExists(atPath: u.path) != exists { throw fail("exists != \(exists)") }
                if !exists { return nil }
            }
            let data = (try? Data(contentsOf: u)) ?? Data()
            if let hex = s["bytesPrefix"] as? String {
                let got = data.prefix(hex.count / 2).map { String(format: "%02x", $0) }.joined()
                if got != hex { throw fail("bytes \(got)") }
            }
            try check(String(decoding: data, as: UTF8.self), s, what: "file")
            return nil
        case "assertStatus":
            let sb = c.statusBar
            let all = [sb.position, sb.counts, sb.selection, sb.info, sb.message].map(\.stringValue).joined(separator: " | ")
            try check(all, s, what: "status")
            return all
        case "assertTabs":
            if let n = s["count"] as? Int, c.documents.count != n { throw fail("\(c.documents.count) tabs") }
            if let name = s["active"] as? String, c.activeDocument?.name != name { throw fail("active is \(c.activeDocument?.name ?? "none")") }
            return c.documents.map(\.name).joined(separator: ", ")
        case "assertDoc":
            guard let d = c.activeDocument else { throw fail("no document") }
            if let lang = s["language"] as? String, d.language.rawValue != lang { throw fail("language \(d.language.rawValue)") }
            if let dirty = s["dirty"] as? Bool, d.isDirty != dirty { throw fail("dirty \(d.isDirty)") }
            if let conflict = s["conflict"] as? Bool, d.conflict != conflict { throw fail("conflict \(d.conflict)") }
            if let ro = s["readOnly"] as? Bool, d.isReadOnly != ro { throw fail("readOnly \(d.isReadOnly)") }
            if let le = s["lineEnding"] as? String, d.lineEnding.rawValue != le { throw fail("lineEnding \(d.lineEnding.rawValue)") }
            if let banner = s["banner"] as? Bool, d.editor.bannerVisible != banner { throw fail("banner \(d.editor.bannerVisible)") }
            if let lines = s["lines"] as? Int, d.lines.count != lines { throw fail("lines \(d.lines.count)") }
            if let cursors = s["cursors"] as? Int, d.editor.textView.allSelections.count != cursors { throw fail("cursors \(d.editor.textView.allSelections.count)") }
            if let sel = s["selection"] as? String {
                let r = d.editor.textView.selectedRange()
                let got = (d.editor.textView.string as NSString).substring(with: r)
                if got != sel { throw fail("selection \(got.debugDescription)") }
            }
            return nil
        case "assertLineIndex":
            // The incremental line index must equal a fresh rebuild.
            guard let d = c.activeDocument else { throw fail("no document") }
            let fresh = LineIndex(d.storage.string as NSString)
            if fresh.starts != d.lines.starts { throw fail("line index drifted: \(d.lines.count) vs \(fresh.count)") }
            if fresh.lineWords != d.lines.lineWords || fresh.wordCount != d.lines.wordCount {
                throw fail("word count drifted: \(d.lines.wordCount) vs \(fresh.wordCount)")
            }
            let full = Counter.words(d.storage.string as NSString, NSRange(location: 0, length: d.storage.length))
            if full != d.lines.wordCount { throw fail("word count \(d.lines.wordCount), full count \(full)") }
            return "\(fresh.count) lines, \(fresh.wordCount) words"
        case "assertTextEqualsFile":
            // The streamed load must give the same text as Foundation's own decoder.
            guard let tv else { throw fail("no editor") }
            var disk = try String(contentsOf: path(s), encoding: .utf8)
            if s["crlf"] as? Bool == true { disk = disk.replacingOccurrences(of: "\r\n", with: "\n") }
            if tv.string != disk { throw fail("text differs from the file: \(tv.string.utf16.count) vs \(disk.utf16.count) units") }
            return "\(disk.utf16.count) units"
        case "assertColor":
            // The colour drawn at the first occurrence of `text`.
            guard let tv, let lm = tv.layoutManager else { throw fail("no editor") }
            let r = (tv.string as NSString).range(of: s["text"] as! String)
            guard r.location != NSNotFound else { throw fail("text not found") }
            let attrs = lm.temporaryAttributes(atCharacterIndex: r.location + (s["offset"] as? Int ?? 0), effectiveRange: nil)
            let color = (attrs[.foregroundColor] as? NSColor) ?? Theme.foreground
            let hex = Self.hex(color)
            if let want = s["equals"] as? String, hex.lowercased() != want.lowercased() { throw fail("colour #\(hex)") }
            return "#\(hex)"
        case "assertCorners":
            // What AppKit gets when it asks the window for its shape: the square mask, or nil (rounded).
            let mask = c.window?.perform(WindowCorners.maskSelector)?.takeUnretainedValue() as? NSImage
            let got = mask == nil ? "rounded" : "square"
            let radius = Settings.current.cornerRadius
            if let want = s["expect"] as? String, got != want { throw fail("window corners \(got)") }
            if let want = s["radius"] as? Double, radius != CGFloat(want) { throw fail("cornerRadius \(radius)") }
            if mask != nil, mask?.size != NSSize(width: 3, height: 3) { throw fail("mask size \(mask!.size)") }
            return "\(got), cornerRadius \(radius)"
        case "wait":
            return nil
        case "describe":
            var parts: [String] = []
            parts.append("tabBar \(c.tabBar.frame) hidden=\(c.tabBar.isHidden) titles=\(c.tabBar.titles.count) super=\(c.tabBar.superview != nil)")
            if let d = c.activeDocument, d.hasEditor {
                let ev = d.editor
                parts.append("editor \(ev.frame) gutter \(ev.gutter.frame) hidden=\(ev.gutter.isHidden) scroll \(ev.scrollView.frame) text \(ev.textView.frame) clip \(ev.scrollView.contentView.bounds) visible \(ev.visibleCharacterRange())")
            }
            if let d = c.activeDocument { parts.append("undo level=\(d.undo.groupingLevel) canUndo=\(d.undo.canUndo) byEvent=\(d.undo.groupsByEvent) tvUM=\(tv?.undoManager === d.undo)") }
            if let tv { parts.append("selections \(tv.allSelections) text \(tv.string.debugDescription)") }
            parts.append("subviews: " + c.root.subviews.map { "\(type(of: $0))" }.joined(separator: ","))
            return parts.joined(separator: " | ")
        case "focusEditor":
            guard let tv else { throw fail("no editor") }
            c.window?.makeFirstResponder(tv)
            return nil
        case "assertRecentScratch":
            // Files in the scratch folder changed in the last 2 minutes.
            let dir = AppPaths.scratchDir
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let recent = urls.filter {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }.map { Date().timeIntervalSince($0) < 120 } ?? false
            }
            let texts = recent.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
            if let maxEmpty = s["maxEmpty"] as? Int, texts.filter(\.isEmpty).count > maxEmpty { throw fail("\(texts.filter(\.isEmpty).count) empty scratch files") }
            if let want = s["contains"] as? String, !texts.contains(where: { $0.contains(want) }) { throw fail("no recent scratch file has \(want.debugDescription)") }
            if let want = s["nameMatches"] as? String, !recent.contains(where: { $0.lastPathComponent.range(of: want, options: .regularExpression) != nil }) {
                throw fail("no recent scratch named like \(want)")
            }
            return recent.map(\.lastPathComponent).sorted().joined(separator: ", ")
        case "screenshot":
            screenshot(s["name"] as? String ?? "shot")
            return nil
        case "screenshotTabs":
            render(c.tabBar, s["name"] as? String ?? "tabs")
            return nil
        case "screenshotFrame":
            // The whole window, title bar included.
            guard let frame = c.window?.contentView?.superview else { throw fail("no frame view") }
            // A size here holds for the capture: a tiling window manager can't move the window within 1 step.
            if let w = s["width"] as? Double, let h = s["height"] as? Double {
                c.window?.setContentSize(NSSize(width: w, height: h))
                c.window?.layoutIfNeeded()
                c.window?.displayIfNeeded()
            }
            render(frame, s["name"] as? String ?? "frame", scale: s["scale"] as? Double)
            return "root \(c.root.frame) in frame \(frame.frame)"
        case "memory":
            let mb = Self.memoryMB()
            lastMeasure = mb
            if let max = s["maxMB"] as? Double, mb > max { throw fail(String(format: "%.0f MB", mb)) }
            return String(format: "%.1f MB", mb)
        case "find":
            c.showFind(nil)
            c.findBar.caseSensitive = s["case"] as? Bool ?? false
            c.findBar.useRegex = s["regex"] as? Bool ?? false
            c.findBar.findField.stringValue = s["query"] as? String ?? ""
            c.findBar.search()
            if let n = s["count"] as? Int, c.findBar.matches.count != n { throw fail("\(c.findBar.matches.count) matches") }
            return c.findBar.countLabel.stringValue
        case "replaceAll":
            c.findBar.replaceField.stringValue = s["with"] as? String ?? ""
            c.findBar.replaceAll(nil)
            return nil
        case "quickOpen":
            if !c.isQuickOpenVisible { c.showQuickOpen(nil) }
            c.quickOpen.field.stringValue = s["query"] as? String ?? ""
            c.quickOpen.filter()
            let n = c.quickOpen.results.count
            if let min = s["minResults"] as? Int, n < min { throw fail("\(n) results") }
            if let first = s["firstName"] as? String, c.quickOpen.results.first?.item.name != first {
                throw fail("first is \(c.quickOpen.results.first?.item.name ?? "none")")
            }
            return "\(n) results"
        case "quickOpenEnter":
            c.quickOpen.openSelected()
            return c.activeDocument?.name
        case "closeQuickOpen":
            c.hideQuickOpen()
            return nil
        case "externalWrite":
            try (s["text"] as? String ?? "").write(to: path(s), atomically: true, encoding: .utf8)
            return nil
        case "writeInPlace":
            // Same file, new bytes: what `echo >` and some editors do, unlike an atomic replace.
            let h = try FileHandle(forWritingTo: path(s))
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Data((s["text"] as? String ?? "").utf8))
            try h.close()
            return nil
        case "externalDelete":
            try FileManager.default.removeItem(at: path(s))
            return nil
        case "checkDisk":
            c.checkDisk()
            return nil
        case "save":
            c.saveAll()
            return nil
        case "scroll":
            // Scrolls through the document page by page and times each frame.
            guard let d = c.activeDocument, d.hasEditor else { throw fail("no editor") }
            let ev = d.editor
            let pages = s["pages"] as? Int ?? 50
            let total = ev.textView.frame.height
            let page = ev.scrollView.contentView.bounds.height
            var times: [Double] = []
            let start: CGFloat = (s["fromEnd"] as? Bool ?? false) ? max(0, total - page * CGFloat(pages + 1)) : 0
            for p in 0..<pages {
                let t0 = ProcessInfo.processInfo.systemUptime
                ev.scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(total - page, start + CGFloat(p) * page)))
                ev.scrollView.reflectScrolledClipView(ev.scrollView.contentView)
                forceDraw()
                times.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            let sorted = times.sorted()
            lastMeasure = sorted[sorted.count / 2]
            lastExtra = ["max": sorted.last ?? 0, "p95": sorted[min(sorted.count - 1, sorted.count * 95 / 100)]]
            return nil
        case "scrollToEnd":
            guard let tv else { throw fail("no editor") }
            let t0 = ProcessInfo.processInfo.systemUptime
            tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
            c.window?.displayIfNeeded()
            lastMeasure = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            return nil
        case "resize":
            c.window?.setContentSize(NSSize(width: s["width"] as? Double ?? 1100, height: s["height"] as? Double ?? 760))
            c.window?.displayIfNeeded()
            return nil
        case "tab":
            c.selectTab(s["index"] as? Int ?? 0)
            return c.activeDocument?.name
        default:
            throw fail("unknown op")
        }
    }

    private func check(_ value: String, _ s: [String: Any], what: String) throws {
        if let e = s["equals"] as? String, value != e { throw fail("\(what) is \(String(value.prefix(300)).debugDescription)") }
        if let e = s["contains"] as? String, !value.contains(e) { throw fail("\(what) lacks \(e.debugDescription): \(String(value.prefix(300)).debugDescription)") }
        if let e = s["notContains"] as? String, value.contains(e) { throw fail("\(what) has \(e.debugDescription)") }
        if let e = s["prefix"] as? String, !value.hasPrefix(e) { throw fail("\(what) starts \(String(value.prefix(80)).debugDescription)") }
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }

    /// Finds the menu item bound to "cmd+shift+f", "opt+up", "ctrl+cmd+w" ...
    static func menuItem(for keys: String, in menu: NSMenu) -> NSMenuItem? {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for part in keys.lowercased().split(separator: "+") {
            switch part {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "alt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            case "up": key = MenuBuilder.arrow(NSUpArrowFunctionKey)
            case "down": key = MenuBuilder.arrow(NSDownArrowFunctionKey)
            case "enter", "return": key = "\r"
            default: key = String(part)
            }
        }
        for item in menu.items {
            if let sub = item.submenu, let found = menuItem(for: keys, in: sub) { return found }
            if item.keyEquivalent.lowercased() == key, item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == mods {
                return item
            }
        }
        return nil
    }

    /// Sends a menu action down the responder chain of the window, as a key press would.
    private func dispatch(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let window = c.window else { return false }
        var responder: NSResponder? = window.firstResponder
        var chain: [AnyObject] = []
        while let r = responder { chain.append(r); responder = r.nextResponder }
        chain.append(c)
        chain.append(app)
        for target in chain where target.responds(to: action) {
            if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { continue }
            _ = target.perform(action, with: item)
            return true
        }
        return false
    }

    private var drawRep: NSBitmapImageRep?

    /// Layout and drawing of the visible editor, synchronously (an upper bound: it repaints everything).
    private func forceDraw() {
        guard let d = c.activeDocument, d.hasEditor else { return }
        let ev = d.editor
        if drawRep == nil || drawRep!.size != ev.bounds.size { drawRep = ev.bitmapImageRepForCachingDisplay(in: ev.bounds) }
        if let rep = drawRep { ev.cacheDisplay(in: ev.bounds, to: rep) }
    }

    /// `scale` 2 renders at Retina size on any screen (screenshots.py), otherwise at the screen's own scale.
    private func render(_ view: NSView, _ name: String, scale: Double? = nil) {
        var rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let scale, let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                               pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            r.size = view.bounds.size
            rep = r
        }
        guard let rep else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    private func screenshot(_ name: String) {
        guard let view = c.window?.contentView else { return }
        c.window?.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    private func finish() {
        let report: [String: Any] = ["steps": results]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
        if ProcessInfo.processInfo.environment["TEXTEE_QA_KEEP_OPEN"] != "1" { NSApp.terminate(nil) }
    }
}

/// Launch phases, written to TEXTEE_QA_OUT/profile.txt during QA only.
enum Profile {
    private static var lines: [String] = []
    static let enabled = ProcessInfo.processInfo.environment["TEXTEE_QA"] != nil

    static func mark(_ what: String) {
        guard enabled else { return }
        let ms = (Date().timeIntervalSince1970 - QAHarness.processStart()) * 1000
        lines.append(String(format: "%8.1f ms  %@", ms, what))
        if let out = ProcessInfo.processInfo.environment["TEXTEE_QA_OUT"] {
            try? lines.joined(separator: "\n").write(toFile: out + "/profile.txt", atomically: true, encoding: .utf8)
        }
    }
}
