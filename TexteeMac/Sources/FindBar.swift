import AppKit

/// Find and replace in the current file: literal or regex, case on or off, every match coloured.
final class FindBar: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {
    weak var controller: MainWindowController?
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let caseButton = NSButton()
    let regexButton = NSButton()
    let countLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []

    static let height: CGFloat = 36
    static let matchLimit = 20_000

    private(set) var matches: [NSRange] = []
    private var current = -1
    private var matchesFor: ObjectIdentifier?
    private var searchTimer: Timer?
    private var paintedRange: NSRange?
    private weak var paintedEditor: EditorView?

    var caseSensitive = false { didSet { caseButton.state = caseSensitive ? .on : .off } }
    var useRegex = false { didSet { regexButton.state = useRegex ? .on : .off } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        findField.placeholderString = "Find"
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.focusRingType = .none
        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.focusRingType = .none
        replaceField.bezelStyle = .roundedBezel
        for f in [findField, replaceField] as [NSTextField] {
            f.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            f.controlSize = .regular
            addSubview(f)
        }
        configureToggle(caseButton, "Aa", "Match case")
        configureToggle(regexButton, ".*", "Regular expression")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.chromeMuted
        addSubview(countLabel)
        for (title, sel, tip) in [("‹", #selector(findPrevious(_:)), "Previous match (⇧↩)"), ("›", #selector(findNext(_:)), "Next match (↩)"),
                                   ("Replace", #selector(replaceOne(_:)), "Replace this match, go to the next"),
                                   ("All", #selector(replaceAll(_:)), "Replace every match"),
                                   ("✕", #selector(close(_:)), "Close (⌃F or Esc)")] {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.toolTip = tip
            addSubview(b)
            buttons.append(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureToggle(_ b: NSButton, _ title: String, _ tip: String) {
        b.title = title
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        b.toolTip = tip
        b.target = self
        b.action = #selector(toggled(_:))
        addSubview(b)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeRaised.setFill()
        bounds.fill()
        Theme.chromeLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 24
        let y = (bounds.height - h) / 2
        var x: CGFloat = 10
        let fieldW = max(140, min(360, (bounds.width - 420) / 2))
        findField.frame = NSRect(x: x, y: y, width: fieldW, height: h); x += fieldW + 6
        for b in [caseButton, regexButton] { b.sizeToFit(); b.frame.origin = NSPoint(x: x, y: (bounds.height - b.frame.height) / 2); x += b.frame.width + 2 }
        x += 6
        replaceField.frame = NSRect(x: x, y: y, width: fieldW, height: h); x += fieldW + 6
        for b in buttons { b.sizeToFit(); b.frame.origin = NSPoint(x: x, y: (bounds.height - b.frame.height) / 2); x += b.frame.width + 2 }
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: x + 8, y: (bounds.height - countLabel.frame.height) / 2)
    }

    // MARK: Actions

    @objc private func toggled(_ sender: NSButton) {
        caseSensitive = caseButton.state == .on
        useRegex = regexButton.state == .on
        search()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === findField else { return }
        searchTimer?.invalidate()
        let big = (controller?.activeDocument?.storage.length ?? 0) > 2_000_000
        if big {
            searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.search() }
        } else {
            search()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if control === replaceField { replaceOne(nil) } else if shift { findPrevious(nil) } else { findNext(nil) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(nil); return true }
        return false
    }

    @objc func close(_ sender: Any?) { controller?.hideFindBar(nil) }

    func focus(with selection: String?) {
        if let selection, !selection.isEmpty, !selection.contains("\n") { findField.stringValue = selection }
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        search()
    }

    // MARK: Search

    private func regex(for query: String) -> NSRegularExpression? {
        let pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines])
    }

    /// Finds every match in the current file and selects the first one after the caret.
    func search() {
        guard let doc = controller?.activeDocument, doc.hasEditor else { return }
        let ev = doc.editor
        clearPaint(ev)
        matches = []
        current = -1
        matchesFor = ObjectIdentifier(doc)
        let query = findField.stringValue
        guard !query.isEmpty else { countLabel.stringValue = ""; needsLayout = true; return }
        guard let re = regex(for: query) else { countLabel.stringValue = "Bad pattern"; needsLayout = true; return }
        let s = doc.storage.string as NSString
        var found: [NSRange] = []
        re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, stop in
            guard let r = m?.range, r.length > 0 else { return }
            found.append(r)
            if found.count >= FindBar.matchLimit { stop.pointee = true }
        }
        matches = found
        let caret = ev.textView.selectedRange().location
        current = matches.firstIndex(where: { $0.location >= caret }) ?? (matches.isEmpty ? -1 : 0)
        if current >= 0 { reveal(ev) }
        updateCount()
        highlightMatches(in: ev)
    }

    private func updateCount() {
        if matches.isEmpty {
            countLabel.stringValue = findField.stringValue.isEmpty ? "" : "No matches"
        } else {
            let more = matches.count >= FindBar.matchLimit ? "+" : ""
            countLabel.stringValue = "\(grouped(current + 1)) of \(grouped(matches.count))\(more)"
        }
        needsLayout = true
    }

    private func reveal(_ ev: EditorView) {
        guard current >= 0, current < matches.count else { return }
        let r = matches[current]
        ev.textView.setSelectedRange(r)
        ev.textView.scrollRangeToVisible(r)
        ev.textView.showFindIndicator(for: r)
    }

    private func ensureFresh() -> EditorView? {
        guard let doc = controller?.activeDocument, doc.hasEditor else { return nil }
        if matchesFor != ObjectIdentifier(doc) { search() }
        return doc.editor
    }

    @objc func findNext(_ sender: Any?) {
        guard let ev = ensureFresh(), !matches.isEmpty else { return }
        let sel = ev.textView.selectedRange()
        current = matches.firstIndex(where: { $0.location > sel.location }) ?? 0
        reveal(ev)
        updateCount()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let ev = ensureFresh(), !matches.isEmpty else { return }
        let sel = ev.textView.selectedRange()
        current = matches.lastIndex(where: { $0.location < sel.location }) ?? matches.count - 1
        reveal(ev)
        updateCount()
    }

    private func replacement(for r: NSRange, in s: NSString) -> String {
        guard useRegex, let re = regex(for: findField.stringValue),
              let m = re.firstMatch(in: s as String, options: [.anchored], range: r) else { return replaceField.stringValue }
        return re.replacementString(for: m, in: s as String, offset: 0, template: replaceField.stringValue)
    }

    @objc func replaceOne(_ sender: Any?) {
        guard let ev = ensureFresh(), ev.textView.isEditable, current >= 0, current < matches.count else { return }
        let tv = ev.textView!
        let r = matches[current]
        let s = tv.string as NSString
        let text = replacement(for: r, in: s)
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: r, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: r, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
        search()
    }

    @objc func replaceAll(_ sender: Any?) {
        guard let ev = ensureFresh(), ev.textView.isEditable, !matches.isEmpty else { return }
        let tv = ev.textView!
        let s = tv.string as NSString
        let texts = matches.map { replacement(for: $0, in: s) }
        let ranges = matches.map { NSValue(range: $0) }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(inRanges: ranges, replacementStrings: texts) else { return }
        tv.textStorage?.beginEditing()
        for (r, t) in zip(matches, texts).reversed() { tv.textStorage?.replaceCharacters(in: r, with: t) }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        let n = matches.count
        search()
        controller?.statusBar.flash("Replaced \(grouped(n))")
    }

    // MARK: Painting

    private func clearPaint(_ ev: EditorView) {
        let target = paintedEditor ?? ev
        if let lm = target.textView.layoutManager, let p = paintedRange {
            let len = (target.textView.string as NSString).length
            let r = NSIntersectionRange(p, NSRange(location: 0, length: len))
            if r.length > 0 { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        }
        paintedRange = nil
        paintedEditor = nil
    }

    /// Colours the matches on screen. Called after every scroll and edit.
    func highlightMatches(in ev: EditorView) {
        guard !isHidden, let lm = ev.textView.layoutManager, matchesFor == ObjectIdentifier(ev.document) else {
            if paintedRange != nil { clearPaint(ev) }
            return
        }
        clearPaint(ev)
        guard !matches.isEmpty else { return }
        let len = (ev.textView.string as NSString).length
        let vis = ev.visibleCharacterRange()
        let lo = max(0, vis.location - 2000), hi = min(len, NSMaxRange(vis) + 2000)
        var i = lowerBound(lo)
        while i < matches.count, matches[i].location < hi {
            let r = matches[i]
            if NSMaxRange(r) <= len {
                lm.addTemporaryAttribute(.backgroundColor, value: i == current ? Theme.findCurrent : Theme.findMatch, forCharacterRange: r)
            }
            i += 1
        }
        paintedRange = NSRange(location: lo, length: hi - lo)
        paintedEditor = ev
    }

    private func lowerBound(_ loc: Int) -> Int {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].location < loc { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Matches go stale when the text changes: search again after a short pause.
    func textChanged() {
        guard !isHidden, !findField.stringValue.isEmpty else { return }
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, let doc = self.controller?.activeDocument, doc.hasEditor else { return }
            let keep = doc.editor.textView.selectedRange()
            self.searchKeepingSelection(keep)
        }
    }

    private func searchKeepingSelection(_ sel: NSRange) {
        guard let doc = controller?.activeDocument, doc.hasEditor else { return }
        let ev = doc.editor
        let query = findField.stringValue
        guard let re = regex(for: query) else { return }
        clearPaint(ev)
        let s = doc.storage.string as NSString
        var found: [NSRange] = []
        re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, stop in
            guard let r = m?.range, r.length > 0 else { return }
            found.append(r)
            if found.count >= FindBar.matchLimit { stop.pointee = true }
        }
        matches = found
        matchesFor = ObjectIdentifier(doc)
        current = matches.firstIndex(where: { $0.location >= sel.location }) ?? -1
        updateCount()
        highlightMatches(in: ev)
    }

    func documentSwitched() {
        matchesFor = nil
        matches = []
        current = -1
        if !isHidden { search() }
    }
}
