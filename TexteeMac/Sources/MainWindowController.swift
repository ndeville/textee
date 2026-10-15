import AppKit

/// The window's content: tab bar, find bar, editor, status bar, laid out by hand.
final class RootView: NSView {
    weak var controller: MainWindowController?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        controller?.layoutContent()
    }
}

/// The 1 Textee window: tabs over 1 editor area. Each tab keeps its own editor view, so a switch is instant.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let root = RootView()
    let tabBar = TabBar()
    /// Built on first use: its search field and buttons cost launch time.
    private(set) var loadedFindBar: FindBar?
    var findBar: FindBar {
        if let f = loadedFindBar { return f }
        let f = FindBar()
        f.controller = self
        f.isHidden = true
        f.clipsToBounds = true
        root.addSubview(f, positioned: .below, relativeTo: statusBar)
        loadedFindBar = f
        return f
    }
    var findBarVisible: Bool { loadedFindBar.map { !$0.isHidden } ?? false }
    let statusBar = StatusBar()
    let emptyView = EmptyView()
    private(set) lazy var quickOpen: QuickOpen = {
        let q = QuickOpen()
        q.controller = self
        return q
    }()
    private var quickOpenVisible = false

    private(set) var documents: [Document] = []
    private(set) var activeIndex = -1
    var state = AppState.load()
    var showLineNumbers: Bool { state.lineNumbers }

    private var autosaveTimer: Timer?
    private var diskTimer: Timer?
    static let autosaveDelay: TimeInterval = 1.0

    var activeDocument: Document? { activeIndex >= 0 && activeIndex < documents.count ? documents[activeIndex] : nil }

    init() {
        let window = AppWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        Document.fontSize = CGFloat(state.fontSize)
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.chrome
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.title = "Textee"
        root.controller = self
        window.contentView = root
        tabBar.controller = self
        root.addSubview(tabBar)
        root.addSubview(emptyView)
        root.addSubview(statusBar)
        for v in [tabBar, emptyView, statusBar] as [NSView] { v.clipsToBounds = true }
        if !window.setFrameUsingName("TexteeMain") { window.center() }
        window.setFrameAutosaveName("TexteeMain")
        updateChrome()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    func layoutContent() {
        let b = root.bounds
        var y: CGFloat = 0
        tabBar.frame = NSRect(x: 0, y: y, width: b.width, height: TabBar.height)
        y += TabBar.height
        if let findBar = loadedFindBar, !findBar.isHidden {
            findBar.frame = NSRect(x: 0, y: y, width: b.width, height: FindBar.height)
            y += FindBar.height
        }
        let editorFrame = NSRect(x: 0, y: y, width: b.width, height: max(0, b.height - y - StatusBar.height))
        if let doc = activeDocument, doc.hasEditor { doc.editor.frame = editorFrame }
        emptyView.frame = editorFrame
        statusBar.frame = NSRect(x: 0, y: b.height - StatusBar.height, width: b.width, height: StatusBar.height)
        if quickOpenVisible {
            let w = min(1000, b.width - 60), h = min(640, b.height - 90)
            quickOpen.frame = NSRect(x: (b.width - w) / 2, y: TabBar.height + 10, width: w, height: max(200, h))
        }
    }

    // MARK: Opening

    @discardableResult
    func open(_ url: URL) -> Document? {
        let real = TextFile.canonical(url)
        if let i = documents.firstIndex(where: { $0.url == real }) {
            selectTab(i)
            showWindow()
            return documents[i]
        }
        let doc: Document
        do {
            doc = Document(url: real, loaded: try TextFile.load(real))
        } catch {
            showWindow()
            statusBar.flash("Can't open \(real.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        let at = activeIndex >= 0 ? activeIndex + 1 : documents.count
        documents.insert(doc, at: at)
        state.touch(real.path)
        scheduleStateSave()
        selectTab(at)
        // The window shows after the file is in it: no empty frame first.
        showWindow()
        return doc
    }

    /// A new file in the scratch folder, named YYMMDD-HHMMSS.txt, written at once.
    @discardableResult
    func createScratch(text: String) -> Document? {
        let dir = AppPaths.scratchDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmmss"
        let base = f.string(from: Date())
        var url = dir.appendingPathComponent("\(base).txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).txt")
            n += 1
        }
        do {
            try TextFile.write(text, to: url, lineEnding: .lf, hasBOM: false, expected: nil, checkConflict: false)
        } catch {
            statusBar.flash("Can't create \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        let doc = open(url)
        doc?.isNewScratch = text.isEmpty
        return doc
    }

    @objc func newScratch(_ sender: Any?) { createScratch(text: "") }

    @objc func newFromClipboard(_ sender: Any?) {
        createScratch(text: Clip.string ?? "")
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let d = activeDocument { panel.directoryURL = d.url.deletingLastPathComponent() }
        showWindow()
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK else { return }
            for u in panel.urls { self?.open(u) }
        }
    }

    func showWindow() {
        guard let window else { return }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    // MARK: Tabs

    func selectTab(_ i: Int) {
        guard i >= 0, i < documents.count else { return }
        if let old = activeDocument, old !== documents[i] {
            save(old, explicit: false)
            if old.hasEditor { old.editor.removeFromSuperview() }
        }
        activeIndex = i
        let doc = documents[i]
        let ev = doc.editor
        ev.controller = self
        if ev.superview !== root {
            root.addSubview(ev, positioned: .below, relativeTo: nil)
            ev.textView.softWrap = state.softWrap
            ev.updateBanner()
        }
        emptyView.isHidden = true
        layoutContent()
        ev.layoutSubtreeIfNeeded()
        ev.highlightVisible()
        if !quickOpenVisible { window?.makeFirstResponder(ev.textView) }
        loadedFindBar?.documentSwitched()
        updateChrome()
        updateStatus()
    }

    @objc func nextTab(_ sender: Any?) {
        guard documents.count > 1 else { return }
        selectTab((activeIndex + 1) % documents.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard documents.count > 1 else { return }
        selectTab((activeIndex - 1 + documents.count) % documents.count)
    }

    func moveTab(from: Int, to: Int) {
        let doc = documents.remove(at: from)
        documents.insert(doc, at: to)
        if activeIndex == from { activeIndex = to }
        else if from < activeIndex, to >= activeIndex { activeIndex -= 1 }
        else if from > activeIndex, to <= activeIndex { activeIndex += 1 }
        updateChrome()
    }

    @objc func closeTab(_ sender: Any?) {
        if quickOpenVisible { hideQuickOpen(); return }
        guard let doc = activeDocument else { window?.orderOut(nil); return }
        close(doc, force: false)
    }

    func closeTab(at i: Int) {
        guard i >= 0, i < documents.count else { return }
        close(documents[i], force: false)
    }

    func close(_ doc: Document, force: Bool) {
        guard let i = documents.firstIndex(where: { $0 === doc }) else { return }
        if !force { save(doc, explicit: false) }
        if doc.isDirty, !force, !doc.isReadOnly, !TextFile.readOnlyMode {
            // The save failed (conflict or empty-file guard): ask before losing edits.
            let a = NSAlert()
            a.messageText = "Close \(doc.name) without saving?"
            a.informativeText = "Textee couldn't save the last changes."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Close Without Saving")
            if a.runModal() == .alertFirstButtonReturn { return }
        }
        discardIfEmptyScratch(doc)
        if doc.hasEditor { doc.editor.removeFromSuperview() }
        documents.remove(at: i)
        if documents.isEmpty {
            activeIndex = -1
            emptyView.isHidden = false
            updateChrome()
            updateStatus()
            // As TextMate: closing the last tab closes the window.
            window?.orderOut(nil)
            return
        }
        let next = i < activeIndex ? activeIndex - 1 : (i == activeIndex ? min(i, documents.count - 1) : activeIndex)
        activeIndex = -1
        selectTab(next)
    }

    /// A New (⌘N) file that stayed empty is deleted when it closes.
    private func discardIfEmptyScratch(_ doc: Document) {
        guard doc.isNewScratch, doc.storage.length == 0, !TextFile.readOnlyMode,
              let st = DiskStamp.of(doc.url), st.size == 0 else { return }
        try? FileManager.default.removeItem(at: doc.url)
        state.recentFiles.removeAll { $0 == doc.url.path }
        scheduleStateSave()
    }

    @objc func closeWindow(_ sender: Any?) {
        _ = windowShouldClose(window!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for doc in documents { close(doc, force: false) }
        if documents.isEmpty { window?.orderOut(nil) }
        return false
    }

    // MARK: Saving

    /// Saves if there are changes (or always when `explicit`). Returns false when the file isn't saved.
    @discardableResult
    func save(_ doc: Document, explicit: Bool) -> Bool {
        guard doc.isDirty || explicit, !doc.isReadOnly, !doc.deletedOnDisk else { return !doc.isDirty }
        if doc.conflict && !explicit { return false }
        let text = doc.storage.string
        if text.isEmpty, !explicit, (doc.stamp?.size ?? 0) > 0 {
            statusBar.flash("Not saved: the file would be empty. Press ⌘S to save it.")
            return false
        }
        do {
            doc.stamp = try TextFile.write(text, to: doc.url, lineEnding: doc.lineEnding, hasBOM: doc.hasBOM,
                                           expected: doc.stamp, checkConflict: !explicit || !doc.conflict)
            doc.isDirty = false
            doc.conflict = false
            if doc.hasEditor { doc.editor.updateBanner() }
            updateTabTitles()
            return true
        } catch TextFileError.changedOnDisk {
            doc.conflict = true
            if doc.hasEditor { doc.editor.updateBanner() }
            return false
        } catch {
            statusBar.flash("Not saved: \(error.localizedDescription)")
            return false
        }
    }

    func saveAll() {
        for doc in documents where doc.isDirty { save(doc, explicit: false) }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        if doc.conflict { overwrite(doc); return }
        if save(doc, explicit: true) { statusBar.flash("Saved") }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = activeDocument, let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = doc.url.deletingLastPathComponent()
        panel.nameFieldStringValue = doc.name
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            do {
                doc.stamp = try TextFile.write(doc.storage.string, to: url, lineEnding: doc.lineEnding, hasBOM: doc.hasBOM, expected: nil, checkConflict: false)
                self.discardIfEmptyScratch(doc)
                doc.rename(to: TextFile.canonical(url))
                doc.isDirty = false
                doc.isNewScratch = false
                doc.conflict = false
                doc.deletedOnDisk = false
                self.state.touch(doc.url.path)
                self.scheduleStateSave()
                if doc.hasEditor { doc.editor.updateBanner(); doc.editor.highlightVisible() }
                self.updateChrome()
                self.updateStatus()
            } catch {
                self.statusBar.flash("Not saved: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay, repeats: false) { [weak self] _ in
            self?.saveAll()
        }
    }

    @objc private func appResigned() {
        saveAll()
        diskTimer?.invalidate()
        diskTimer = nil
    }

    /// settings.json saved: redraw the highlights with the new radius. The window corners refresh themselves.
    @objc private func settingsChanged() {
        tabBar.needsDisplay = true
        if quickOpenVisible { quickOpen.applyCorners() }
    }

    @objc private func appActivated() {
        checkDisk()
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkDisk() }
    }

    // MARK: Disk changes

    /// Reloads files that changed on disk; flags a conflict when there are unsaved edits.
    func checkDisk() {
        for doc in documents {
            guard let now = DiskStamp.of(doc.url) else {
                if !doc.deletedOnDisk {
                    doc.deletedOnDisk = true
                    if doc.hasEditor { doc.editor.updateBanner() }
                }
                continue
            }
            if doc.deletedOnDisk {
                doc.deletedOnDisk = false
                if doc.hasEditor { doc.editor.updateBanner() }
            }
            guard now != doc.stamp else { continue }
            if doc.isDirty {
                if !doc.conflict {
                    doc.conflict = true
                    if doc.hasEditor { doc.editor.updateBanner() }
                }
            } else {
                reloadFromDisk(doc, flash: true)
            }
        }
    }

    func reloadFromDisk(_ doc: Document) { reloadFromDisk(doc, flash: false) }

    private func reloadFromDisk(_ doc: Document, flash: Bool) {
        guard let loaded = try? TextFile.load(doc.url) else { return }
        let sel = doc.hasEditor ? doc.editor.textView.selectedRange() : NSRange(location: 0, length: 0)
        let origin = doc.hasEditor ? doc.editor.scrollView.contentView.bounds.origin : .zero
        doc.replaceAll(with: loaded)
        if doc.hasEditor {
            let ev = doc.editor
            let len = doc.storage.length
            ev.textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            ev.scrollView.contentView.scroll(to: origin)
            ev.scrollView.reflectScrolledClipView(ev.scrollView.contentView)
            ev.updateBanner()
            ev.needsLayout = true
            ev.highlightVisible()
            ev.gutter.needsDisplay = true
        }
        updateTabTitles()
        if doc === activeDocument {
            updateStatus()
            if flash { statusBar.flash("Reloaded: the file changed on disk") }
        }
    }

    func overwrite(_ doc: Document) {
        doc.conflict = false
        doc.stamp = DiskStamp.of(doc.url)
        doc.isDirty = true
        save(doc, explicit: true)
    }

    func saveAgain(_ doc: Document) {
        doc.deletedOnDisk = false
        doc.stamp = nil
        doc.isDirty = true
        save(doc, explicit: true)
    }

    // MARK: Events from the editor

    func documentDidChange(_ doc: Document) {
        if !doc.isDirty {
            doc.isDirty = true
            updateTabTitles()
        }
        if doc.isNewScratch, doc.storage.length > 0 { doc.isNewScratch = false }
        scheduleAutosave()
        if doc === activeDocument {
            scheduleStatus()
            loadedFindBar?.textChanged()
        }
    }

    func selectionDidChange(_ doc: Document) {
        if doc === activeDocument { scheduleStatus() }
    }

    func escapePressed() {
        if quickOpenVisible { hideQuickOpen() } else if findBarVisible { hideFindBar(nil) }
    }

    // MARK: Status

    private var statusScheduled = false

    private func scheduleStatus() {
        guard !statusScheduled else { return }
        statusScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.statusScheduled = false
            self?.updateStatus()
        }
    }

    func updateStatus() {
        guard let doc = activeDocument, doc.hasEditor else {
            statusBar.set(position: "", counts: "", charCount: 0, selection: "", info: "")
            return
        }
        let tv = doc.editor.textView!
        let s = doc.storage.string as NSString
        let sels = tv.allSelections
        let caret = sels.last?.location ?? 0
        let line = doc.lines.line(at: caret)
        let col = caret - doc.lines.starts[line] + 1
        var position = "Ln \(grouped(line + 1)), Col \(grouped(col))"
        if sels.count > 1 { position += " · \(sels.count) cursors" }

        let chars = s.length
        let countText = "\(plural(doc.lines.count, "line")) · \(plural(doc.lines.wordCount, "word")) · \(plural(chars, "char"))"
        var selText = ""
        let selected = sels.filter { $0.length > 0 }
        if !selected.isEmpty {
            let selChars = selected.reduce(0) { $0 + $1.length }
            let selWords = selChars > 5_000_000 ? 0 : selected.reduce(0) { $0 + Counter.words(s, $1) }
            selText = "Selection: \(plural(selWords, "word")) · \(plural(selChars, "char"))"
        }
        var info = "\(doc.language.rawValue) · \(doc.lineEnding.rawValue) · UTF-8"
        if doc.hasBOM { info += " BOM" }
        if doc.isReadOnly { info = "Read-only · " + info }
        statusBar.set(position: position, counts: countText, charCount: chars, selection: selText, info: info)
    }

    func updateTabTitles() {
        tabBar.titles = documents.map { ($0.name, ($0.url.path as NSString).abbreviatingWithTildeInPath, $0.isDirty) }
        tabBar.active = activeIndex
    }

    func updateChrome() {
        updateTabTitles()
        guard let window else { return }
        if let doc = activeDocument {
            window.title = doc.name
            window.subtitle = (doc.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            window.representedURL = doc.url
        } else {
            window.title = "Textee"
            window.subtitle = ""
            window.representedURL = nil
        }
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        let wasHidden = findBar.isHidden
        findBar.isHidden = false
        if wasHidden { layoutContent() }
        let tv = doc.editor.textView!
        let sel = tv.selectedRange()
        let text = sel.length > 0 && sel.length < 500 ? (tv.string as NSString).substring(with: sel) : nil
        findBar.focus(with: text)
    }

    @objc func hideFindBar(_ sender: Any?) {
        guard let findBar = loadedFindBar, !findBar.isHidden else { return }
        findBar.isHidden = true
        if let doc = activeDocument, doc.hasEditor {
            findBar.highlightMatches(in: doc.editor)
            window?.makeFirstResponder(doc.editor.textView)
        }
        layoutContent()
    }

    @objc func findNext(_ sender: Any?) { if findBarVisible { findBar.findNext(nil) } else { showFind(nil) } }
    @objc func findPrevious(_ sender: Any?) { if findBarVisible { findBar.findPrevious(nil) } else { showFind(nil) } }

    // MARK: Quick open

    @objc func showQuickOpen(_ sender: Any?) {
        showWindow()
        if quickOpenVisible { hideQuickOpen(); return }
        quickOpenVisible = true
        quickOpen.applyCorners()
        root.addSubview(quickOpen)
        layoutContent()
        quickOpen.begin()
        window?.makeFirstResponder(quickOpen.field)
    }

    func hideQuickOpen() {
        guard quickOpenVisible else { return }
        quickOpenVisible = false
        quickOpen.end()
        quickOpen.removeFromSuperview()
        if let doc = activeDocument, doc.hasEditor { window?.makeFirstResponder(doc.editor.textView) }
    }

    var isQuickOpenVisible: Bool { quickOpenVisible }

    // MARK: File commands

    @objc func openInNotee(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        save(doc, explicit: false)
        let notee = URL(fileURLWithPath: "/Applications/Notee.app")
        NSWorkspace.shared.open([doc.url], withApplicationAt: notee, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { self.statusBar.flash("Notee: \(error.localizedDescription)") } }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        NSWorkspace.shared.activateFileViewerSelecting([doc.url])
    }

    /// As Notee's ⇧⌘D: the path in angle brackets.
    @objc func copyPath(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        Clip.set("<\(doc.url.path)>")
        statusBar.flash("Copied <\(doc.url.path)>")
    }

    // MARK: View

    @objc func toggleSoftWrap(_ sender: Any?) {
        state.softWrap.toggle()
        scheduleStateSave()
        for d in documents where d.hasEditor { d.editor.textView.softWrap = state.softWrap }
        activeDocument?.editor.highlightVisible()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        state.lineNumbers.toggle()
        scheduleStateSave()
        for d in documents where d.hasEditor { d.editor.needsLayout = true }
    }

    @objc func zoomIn(_ sender: Any?) { setFontSize(min(40, state.fontSize + 1)) }
    @objc func zoomOut(_ sender: Any?) { setFontSize(max(8, state.fontSize - 1)) }
    @objc func zoomReset(_ sender: Any?) { setFontSize(Double(Theme.baseFontSize)) }

    private func setFontSize(_ size: Double) {
        state.fontSize = size
        scheduleStateSave()
        Document.fontSize = CGFloat(size)
        for d in documents {
            d.applyFont()
            if d.hasEditor { d.editor.applyZoom() }
        }
        activeDocument?.editor.highlightVisible()
        statusBar.flash("Font size \(Int(size)) pt", seconds: 1.5)
    }

    func validate(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSoftWrap(_:)): item.state = state.softWrap ? .on : .off; return true
        case #selector(toggleLineNumbers(_:)): item.state = state.lineNumbers ? .on : .off; return true
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(openInNotee(_:)), #selector(revealInFinder(_:)),
             #selector(copyPath(_:)), #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)):
            return activeDocument != nil
        case #selector(hideFindBar(_:)): return findBarVisible
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return documents.count > 1
        default: return true
        }
    }

    // MARK: State

    private var stateTimer: Timer?

    func scheduleStateSave() {
        stateTimer?.invalidate()
        // Short: it only merges the saves of a burst (10 files opened at once), and a late save looked like
        // work still running when the benchmark measured Textee from outside.
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in self?.state.save() }
    }

    /// Quit: save every tab, drop empty new scratch files, write the state.
    func prepareToQuit() {
        saveAll()
        for doc in documents { discardIfEmptyScratch(doc) }
        state.save()
    }
}
