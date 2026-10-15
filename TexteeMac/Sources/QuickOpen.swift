import AppKit

/// 1 file the quick-open panel can show.
struct QuickItem {
    let url: URL
    let name: String
    let mtime: Date
    let recent: Bool
    var title: String = ""
    /// Lowercased UTF-8 of the content, for search. Loaded in the background while the panel is open.
    var haystack: [UInt8] = []

    init(url: URL, mtime: Date, recent: Bool) {
        self.url = url
        name = url.lastPathComponent
        self.mtime = mtime
        self.recent = recent
    }
}

/// ⌘P: recent files and every file in the scratch folder, searched by name and by content.
/// The content index lives only while the panel is open, so it costs no memory at rest.
final class QuickOpen: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var controller: MainWindowController?
    let field = NSSearchField()
    let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let preview = NSTextView()
    private let previewScroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")

    private var items: [QuickItem] = []
    private(set) var results: [(item: QuickItem, snippet: String)] = []
    private var generation = 0
    private var indexReady = false
    private let queue = DispatchQueue(label: "textee.quickopen", qos: .userInitiated)

    static let contentLimit = 512 * 1024

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.chromeRaised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.accentDim.cgColor

        field.placeholderString = "Search file names and content (recent files and ~/txt)"
        field.font = NSFont.systemFont(ofSize: 15)
        field.delegate = self
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        addSubview(field)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        addSubview(tableScroll)

        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.drawsBackground = true
        preview.backgroundColor = Theme.background
        preview.textColor = Theme.foreground
        preview.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        preview.textContainerInset = NSSize(width: 8, height: 8)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.layoutManager?.allowsNonContiguousLayout = true
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.wantsLayer = true
        applyCorners()
        addSubview(previewScroll)

        hint.font = Theme.uiFontSmall
        hint.textColor = Theme.chromeMuted
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `cornerRadius` in settings.json: 10 and 6 at the default of 4.
    func applyCorners() {
        layer?.cornerRadius = Settings.radius(10)
        previewScroll.layer?.cornerRadius = Settings.radius(6)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        field.frame = NSRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: 30)
        let top = field.frame.maxY + 10
        let h = bounds.height - top - 30
        let listW = floor((bounds.width - 3 * pad) * 0.45)
        tableScroll.frame = NSRect(x: pad, y: top, width: listW, height: h)
        table.tableColumns.first?.width = listW - 4
        previewScroll.frame = NSRect(x: 2 * pad + listW, y: top, width: bounds.width - 3 * pad - listW, height: h)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: pad, y: bounds.height - 22)
    }

    // MARK: Open and close

    func begin() {
        field.stringValue = ""
        items = []
        indexReady = false
        let recents = controller?.state.recentFiles ?? []
        let txtDir = AppPaths.scratchDir
        let gen = generation + 1
        generation = gen
        // File list: fast enough to wait for (a directory listing with dates).
        var seen = Set<String>()
        var list: [QuickItem] = []
        let fm = FileManager.default
        for p in recents {
            guard !seen.contains(p), let st = DiskStamp.of(URL(fileURLWithPath: p)) else { continue }
            seen.insert(p)
            list.append(QuickItem(url: URL(fileURLWithPath: p), mtime: Date(timeIntervalSince1970: st.mtime), recent: true))
        }
        if let urls = try? fm.contentsOfDirectory(at: txtDir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            var scratch: [QuickItem] = []
            for u in urls {
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                let real = txtDir.appendingPathComponent(u.lastPathComponent)
                guard v?.isRegularFile == true, !seen.contains(real.path) else { continue }
                scratch.append(QuickItem(url: real, mtime: v?.contentModificationDate ?? .distantPast, recent: false))
            }
            scratch.sort { $0.mtime > $1.mtime }
            list += scratch
        }
        items = list
        hint.stringValue = "\(grouped(items.count)) files · ↑↓ choose · ↩ open · Esc close · reading content…"
        filter()
        loadIndex(gen)
    }

    func end() {
        generation += 1
        items = []
        results = []
        table.reloadData()
        preview.string = ""
    }

    /// Reads every file up to 512 KB (title + content), and the first 4 KB of larger files.
    private func loadIndex(_ gen: Int) {
        let work = items
        queue.async { [weak self] in
            var loaded: [QuickItem] = []
            loaded.reserveCapacity(work.count)
            for var item in work {
                guard self?.generation == gen else { return }
                if let h = FileHandle(forReadingAtPath: item.url.path) {
                    let data = (try? h.read(upToCount: QuickOpen.contentLimit + 1)) ?? Data()
                    try? h.close()
                    let text = String(decoding: data.prefix(QuickOpen.contentLimit), as: UTF8.self)
                    item.title = QuickOpen.firstLine(text)
                    item.haystack = data.count <= QuickOpen.contentLimit
                        ? Array(text.lowercased().utf8) : Array(String(text.prefix(4096)).lowercased().utf8)
                }
                loaded.append(item)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                let selected = self.selectedURL
                self.items = loaded
                self.indexReady = true
                self.hint.stringValue = "\(grouped(self.items.count)) files · ↑↓ choose · ↩ open · Esc close"
                self.needsLayout = true
                self.filter(keep: selected)
            }
        }
    }

    private var selectedURL: URL? {
        let row = table.selectedRow
        return row >= 0 && row < results.count ? results[row].item.url : nil
    }

    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*>-` "))
            if !t.isEmpty { return String(t.prefix(140)) }
        }
        return ""
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): controller?.hideQuickOpen(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let url = results[row].item.url
        controller?.hideQuickOpen()
        controller?.open(url)
    }

    /// Every word of the query must appear in the name, the title or the content.
    /// Runs on the main thread: about 5 ms over the 17 MB of ~/txt.
    func filter(keep: URL? = nil) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let words = query.split(separator: " ").map { Array($0.utf8) }
        if words.isEmpty {
            apply(items.prefix(500).map { ($0, "") }, keep: keep)
            return
        }
        var scored: [(QuickItem, String, Int)] = []
        for item in items {
            let name = Array(item.name.lowercased().utf8)
            let title = Array(item.title.lowercased().utf8)
            var score = 0
            var contentHit: Int?
            var ok = true
            for w in words {
                if let p = QuickOpen.find(w, in: name) { score += 100 - min(p, 50) }
                else if QuickOpen.find(w, in: title) != nil { score += 60 }
                else if let p = QuickOpen.find(w, in: item.haystack) { score += 10; if contentHit == nil { contentHit = p } }
                else { ok = false; break }
            }
            guard ok else { continue }
            if item.recent { score += 30 }
            scored.append((item, contentHit.map { QuickOpen.snippet(item.haystack, at: $0) } ?? "", score))
        }
        scored.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.mtime > $1.0.mtime }
        apply(scored.prefix(500).map { ($0.0, $0.1) }, keep: keep)
    }

    private func apply(_ list: [(item: QuickItem, snippet: String)], keep: URL?) {
        results = list
        table.reloadData()
        guard !results.isEmpty else { preview.string = ""; return }
        let row = keep.flatMap { u in results.firstIndex { $0.item.url == u } } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        showPreview()
    }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        return hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                guard let p = memmem(h.baseAddress, h.count, n.baseAddress, n.count) else { return nil }
                return h.baseAddress!.distance(to: p.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// The line around a content match.
    static func snippet(_ hay: [UInt8], at p: Int) -> String {
        var a = p, b = p
        while a > 0, hay[a - 1] != 10, p - a < 60 { a -= 1 }
        while b < hay.count, hay[b] != 10, b - p < 100 { b += 1 }
        return String(decoding: hay[a..<b], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? QuickCell) ?? QuickCell()
        cell.identifier = id
        let (item, snippet) = results[row]
        cell.title.stringValue = item.title.isEmpty ? item.name : item.title
        var sub = item.name + " · " + QuickOpen.age(item.mtime)
        if item.recent { sub += " · recent" }
        if item.url.deletingLastPathComponent().path != AppPaths.scratchDir.path {
            sub += " · " + (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
        if !snippet.isEmpty { sub = snippet + "  ·  " + item.name }
        cell.subtitle.stringValue = sub
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showPreview() }

    private func showPreview() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { preview.string = ""; return }
        let url = results[row].item.url
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        queue.async { [weak self] in
            var text = ""
            if let h = FileHandle(forReadingAtPath: url.path) {
                let data = (try? h.read(upToCount: 64 * 1024)) ?? Data()
                try? h.close()
                text = String(decoding: data, as: UTF8.self)
            }
            DispatchQueue.main.async {
                guard let self, self.table.selectedRow == row else { return }
                self.preview.string = text
                self.preview.textColor = Theme.foreground
                self.preview.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                let first = query.split(separator: " ").first.map(String.init) ?? ""
                if !first.isEmpty {
                    let r = (text as NSString).range(of: first, options: [.caseInsensitive])
                    if r.location != NSNotFound {
                        self.preview.layoutManager?.addTemporaryAttribute(.backgroundColor, value: Theme.findCurrent, forCharacterRange: r)
                        self.preview.scrollRangeToVisible(r)
                        return
                    }
                }
                self.preview.scroll(.zero)
            }
        }
    }

    static func age(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        if s < 86_400 * 60 { return "\(s / 86_400) d ago" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

final class QuickCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = Theme.chromeText
        subtitle.font = Theme.uiFontSmall
        subtitle.textColor = Theme.chromeMuted
        for f in [title, subtitle] {
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            addSubview(f)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 8, y: 20, width: bounds.width - 16, height: 17)
        subtitle.frame = NSRect(x: 8, y: 4, width: bounds.width - 16, height: 15)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { subtitle.textColor = backgroundStyle == .emphasized ? Theme.chromeText : Theme.chromeMuted }
    }
}
