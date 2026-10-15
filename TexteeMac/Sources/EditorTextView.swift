import AppKit

/// Draws the extra carets of a multi-cursor. A subview, because NSTextView draws its text above draw(_:).
final class CaretOverlay: NSView {
    weak var textView: EditorTextView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { textView?.drawExtraCarets(in: dirtyRect) }
}

final class EditorTextView: NSTextView {
    weak var editorView: EditorView?

    /// Every cursor when there are 2 or more. Empty means 1 normal selection.
    private(set) var cursors: [NSRange] = []
    private var applyingMulti = false
    var isMulti: Bool { cursors.count > 1 }
    var allSelections: [NSRange] { isMulti ? cursors : selectedRanges.map(\.rangeValue) }

    static let indentUnit = "    "

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isAutomaticTextCompletionEnabled = false
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
        usesFontPanel = false
        usesRuler = false
        drawsBackground = true
        backgroundColor = Theme.background
        insertionPointColor = Theme.caret
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        textContainerInset = NSSize(width: 6, height: 6)
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainer?.lineFragmentPadding = 4
        layoutManager?.allowsNonContiguousLayout = true
        layoutManager?.showsControlCharacters = false
        typingAttributes = Document.baseAttributes
        let overlay = CaretOverlay(frame: bounds)
        overlay.textView = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        caretOverlay = overlay
    }

    private var caretOverlay: CaretOverlay?

    var softWrap: Bool = true {
        didSet {
            guard let tc = textContainer, let scroll = enclosingScrollView else { return }
            if softWrap {
                isHorizontallyResizable = false
                tc.widthTracksTextView = true
                tc.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
                frame.size.width = scroll.contentSize.width
                scroll.hasHorizontalScroller = false
            } else {
                tc.widthTracksTextView = false
                tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                isHorizontallyResizable = true
                maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                scroll.hasHorizontalScroller = true
            }
            needsDisplay = true
        }
    }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !isMulti, let lm = layoutManager, let tc = textContainer, let ev = editorView else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let s = string as NSString
        let lines = ev.document.lines
        let line = lines.line(at: sel.location)
        let r = lines.range(ofLine: line, in: s)
        var lineRect: NSRect
        if s.length == 0 || (sel.location == s.length && (s.length == 0 || s.character(at: s.length - 1) == 10)) {
            lineRect = lm.extraLineFragmentRect
        } else {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: max(r.length, 1)), actualCharacterRange: nil)
            lineRect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        guard lineRect.intersects(rect) else { return }
        Theme.lineHighlight.setFill()
        lineRect.fill(using: .sourceOver)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !applyingMulti, !cursors.isEmpty {
            cursors = []
            caretOverlay?.needsDisplay = true
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The current-line band moves with the caret.
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
    }

    // MARK: Multi-cursor

    func setCursors(_ ranges: [NSRange]) {
        var merged: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location < NSMaxRange(last) || r.location == last.location {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        applyingMulti = true
        defer { applyingMulti = false }
        if merged.count <= 1 {
            cursors = []
            if let r = merged.first { setSelectedRange(r) }
            caretOverlay?.needsDisplay = true
            return
        }
        cursors = merged
        let nonEmpty = merged.filter { $0.length > 0 }
        if nonEmpty.isEmpty {
            setSelectedRange(merged.last!)
        } else {
            setSelectedRanges(nonEmpty.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        }
        caretOverlay?.needsDisplay = true
        editorView?.selectionDidChange()
    }

    func clearMulti() {
        guard isMulti else { return }
        setCursors([NSRange(location: NSMaxRange(cursors.last!), length: 0)])
    }

    func drawExtraCarets(in dirtyRect: NSRect) {
        guard isMulti, let lm = layoutManager, let tc = textContainer else { return }
        let s = string as NSString
        Theme.accent.setFill()
        for c in cursors where c.length == 0 {
            var rect: NSRect
            if s.length == 0 || (c.location >= s.length && s.character(at: s.length - 1) == 10) {
                rect = lm.extraLineFragmentRect
            } else if c.location >= s.length {
                let g = lm.glyphIndexForCharacter(at: s.length - 1)
                rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                rect.origin.x = rect.maxX
            } else {
                let g = lm.glyphIndexForCharacter(at: c.location)
                rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            }
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            rect.size.width = 2
            if rect.intersects(dirtyRect) { rect.fill() }
        }
    }

    /// 1 edit per cursor as 1 undo step, then a cursor after each edit.
    private func multiEdit(_ make: (NSRange) -> (range: NSRange, text: String)?) {
        guard let storage = textStorage, isEditable else { return }
        var edits: [(range: NSRange, text: String)] = []
        var owner: [Int?] = []
        for c in cursors {
            guard let e = make(c), NSMaxRange(e.range) <= storage.length else { owner.append(nil); continue }
            if let last = edits.last, e.range.location < NSMaxRange(last.range) { owner.append(edits.count - 1); continue }
            edits.append(e)
            owner.append(edits.count - 1)
        }
        guard !edits.isEmpty,
              shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) else { return }
        applyingMulti = true
        storage.beginEditing()
        for e in edits.reversed() { storage.replaceCharacters(in: e.range, with: e.text) }
        storage.endEditing()
        didChangeText()
        applyingMulti = false
        var result: [NSRange] = []
        for (c, ei) in zip(cursors, owner) {
            var shift = 0
            if let ei {
                for k in 0..<ei { shift += (edits[k].text as NSString).length - edits[k].range.length }
                let e = edits[ei]
                result.append(NSRange(location: e.range.location + shift + (e.text as NSString).length, length: 0))
            } else {
                for e in edits where NSMaxRange(e.range) <= c.location { shift += (e.text as NSString).length - e.range.length }
                result.append(NSRange(location: c.location + shift, length: c.length))
            }
        }
        setCursors(result)
    }

    private func composed(before loc: Int) -> NSRange {
        guard loc > 0 else { return NSRange(location: 0, length: 0) }
        return (string as NSString).rangeOfComposedCharacterSequence(at: loc - 1)
    }

    private func composed(at loc: Int) -> NSRange {
        let s = string as NSString
        guard loc < s.length else { return NSRange(location: loc, length: 0) }
        return s.rangeOfComposedCharacterSequence(at: loc)
    }

    // AppKit doesn't offer ⌥ + letter to the menu, so ⌥D typed ∂ instead of deleting the line.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let item = MenuBuilder.optionItem(key, in: NSApp.mainMenu), performMenuAction(item) { return }
        super.keyDown(with: event)
    }

    /// Runs a menu item's action on the first responder that takes it, as the menu would.
    private func performMenuAction(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        var responder: NSResponder? = self
        while let r = responder {
            if r.responds(to: action) {
                if let v = r as? NSMenuItemValidation, !v.validateMenuItem(item) { return false }
                return NSApp.sendAction(action, to: r, from: item)
            }
            responder = r.nextResponder
        }
        return false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if isMulti, replacementRange.location == NSNotFound, !hasMarkedText() {
            let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
            multiEdit { ($0, text) }
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        guard isMulti else { return super.deleteBackward(sender) }
        multiEdit { c in
            if c.length > 0 { return (c, "") }
            guard c.location > 0 else { return nil }
            return (composed(before: c.location), "")
        }
    }

    override func deleteForward(_ sender: Any?) {
        guard isMulti else { return super.deleteForward(sender) }
        let len = (string as NSString).length
        multiEdit { c in
            if c.length > 0 { return (c, "") }
            guard c.location < len else { return nil }
            return (composed(at: c.location), "")
        }
    }

    /// Keeps the indentation of the current line.
    override func insertNewline(_ sender: Any?) {
        if isMulti { multiEdit { ($0, "\n") }; return }
        let s = string as NSString
        let sel = selectedRange()
        let lineStart = s.lineRange(for: NSRange(location: sel.location, length: 0)).location
        var i = lineStart
        while i < sel.location, i < s.length, s.character(at: i) == 32 || s.character(at: i) == 9 { i += 1 }
        let indent = s.substring(with: NSRange(location: lineStart, length: i - lineStart))
        insertText("\n" + indent, replacementRange: sel)
    }

    override func insertTab(_ sender: Any?) {
        if isMulti { multiEdit { ($0, Self.indentUnit) }; return }
        let sel = selectedRange()
        let s = string as NSString
        if sel.length > 0, s.substring(with: sel).contains("\n") { indentLines(outdent: false); return }
        insertText(Self.indentUnit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { indentLines(outdent: true) }

    override func moveLeft(_ sender: Any?) {
        guard isMulti else { return super.moveLeft(sender) }
        setCursors(cursors.map { $0.length > 0 ? NSRange(location: $0.location, length: 0) : NSRange(location: composed(before: $0.location).location, length: 0) })
    }

    override func moveRight(_ sender: Any?) {
        guard isMulti else { return super.moveRight(sender) }
        setCursors(cursors.map { $0.length > 0 ? NSRange(location: NSMaxRange($0), length: 0) : NSRange(location: NSMaxRange(composed(at: $0.location)), length: 0) })
    }

    override func cancelOperation(_ sender: Any?) {
        if isMulti { clearMulti(); return }
        editorView?.escapePressed()
    }

    /// ⌥-click adds a cursor.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: p)
            setCursors(allSelections + [NSRange(location: idx, length: 0)])
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Copy and paste

    /// Plain text only, from every selection (1 line per cursor).
    override func copy(_ sender: Any?) {
        let s = string as NSString
        let parts = allSelections.filter { $0.length > 0 }.map { s.substring(with: $0) }
        guard !parts.isEmpty else { return }
        Clip.set(parts.joined(separator: "\n"))
    }

    override func cut(_ sender: Any?) {
        guard isEditable, allSelections.contains(where: { $0.length > 0 }) else { return }
        copy(sender)
        if isMulti { multiEdit { ($0, "") } } else { insertText("", replacementRange: selectedRange()) }
    }

    /// Always plain text. With several cursors and as many clipboard lines, 1 line per cursor.
    override func paste(_ sender: Any?) {
        guard isEditable, let text = Clip.string else { return }
        if isMulti {
            let parts = text.components(separatedBy: "\n")
            if parts.count == cursors.count {
                var i = 0
                multiEdit { c in defer { i += 1 }; return (c, parts[i]) }
            } else {
                multiEdit { ($0, text) }
            }
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    // MARK: Occurrences

    private func wordRange(at loc: Int) -> NSRange {
        selectionRange(forProposedRange: NSRange(location: loc, length: 0), granularity: .selectByWord)
    }

    @objc func addNextOccurrence(_ sender: Any?) {
        let s = string as NSString
        var current = allSelections
        guard let last = current.last else { return }
        if current.count == 1, last.length == 0 {
            let w = wordRange(at: last.location)
            if w.length > 0 { setCursors([w]); scrollRangeToVisible(w) }
            return
        }
        let needle = s.substring(with: last)
        guard !needle.isEmpty else { return }
        var from = NSMaxRange(last)
        for _ in 0..<2 {
            let r = s.range(of: needle, options: [.literal], range: NSRange(location: from, length: s.length - from))
            if r.location != NSNotFound {
                if current.contains(where: { $0 == r }) { return }
                current.append(r)
                setCursors(current)
                scrollRangeToVisible(r)
                return
            }
            from = 0
        }
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        let s = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = wordRange(at: sel.location) }
        guard sel.length > 0 else { return }
        let needle = s.substring(with: sel)
        var found: [NSRange] = []
        var from = 0
        while from < s.length, found.count < 10_000 {
            let r = s.range(of: needle, options: [.literal], range: NSRange(location: from, length: s.length - from))
            if r.location == NSNotFound { break }
            found.append(r)
            from = NSMaxRange(r)
        }
        setCursors(found)
    }

    // MARK: Line commands

    /// Replaces `range` as its own undo step and selects `select`.
    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        guard isEditable else { return }
        // Before shouldChangeText: that's where NSTextView registers the undo, and merges it with the last edit.
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    /// Full lines covered by the selection, line break included when there is one.
    private func selectedLines() -> NSRange {
        let s = string as NSString
        var sel = selectedRange()
        if sel.length > 0, NSMaxRange(sel) > sel.location, s.character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        return s.lineRange(for: sel)
    }

    @objc func duplicateLine(_ sender: Any?) {
        let s = string as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            let text = s.substring(with: sel)
            replace(NSRange(location: NSMaxRange(sel), length: 0), with: text,
                    select: NSRange(location: NSMaxRange(sel), length: sel.length))
            return
        }
        let lines = selectedLines()
        var text = s.substring(with: lines)
        let hasBreak = text.hasSuffix("\n")
        if !hasBreak { text = "\n" + text }
        let insertAt = NSMaxRange(lines)
        let caret = sel.location + (text as NSString).length
        replace(NSRange(location: insertAt, length: 0), with: text, select: NSRange(location: caret, length: 0))
    }

    @objc func deleteLine(_ sender: Any?) {
        let s = string as NSString
        var lines = selectedLines()
        if NSMaxRange(lines) == s.length, lines.location > 0, !(s.substring(with: lines).hasSuffix("\n")) {
            lines = NSRange(location: lines.location - 1, length: lines.length + 1)
        }
        replace(lines, with: "", select: NSRange(location: min(lines.location, s.length - lines.length), length: 0))
    }

    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let s = string as NSString
        let sel = selectedRange()
        let block = selectedLines()
        var blockText = s.substring(with: block)
        if up {
            guard block.location > 0 else { return }
            let prev = s.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var prevText = s.substring(with: prev)
            if !blockText.hasSuffix("\n") { blockText += "\n"; prevText = String(prevText.dropLast()) }
            let whole = NSRange(location: prev.location, length: NSMaxRange(block) - prev.location)
            replace(whole, with: blockText + prevText,
                    select: NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            guard NSMaxRange(block) < s.length else { return }
            let next = s.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var nextText = s.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; blockText = String(blockText.dropLast()) }
            let whole = NSRange(location: block.location, length: NSMaxRange(next) - block.location)
            replace(whole, with: nextText + blockText,
                    select: NSRange(location: sel.location + (nextText as NSString).length, length: sel.length))
        }
    }

    @objc func indentSelection(_ sender: Any?) { indentLines(outdent: false) }
    @objc func outdentSelection(_ sender: Any?) { indentLines(outdent: true) }

    func indentLines(outdent: Bool) {
        let s = string as NSString
        let block = selectedLines()
        let text = s.substring(with: block)
        var parts = text.components(separatedBy: "\n")
        let trailing = text.hasSuffix("\n")
        if trailing { parts.removeLast() }
        parts = parts.map { line in
            if outdent {
                if line.hasPrefix(Self.indentUnit) { return String(line.dropFirst(4)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.drop(while: { $0 == " " }))
            }
            return line.isEmpty ? line : Self.indentUnit + line
        }
        let out = parts.joined(separator: "\n") + (trailing ? "\n" : "")
        replace(block, with: out, select: NSRange(location: block.location, length: (out as NSString).length - (trailing ? 1 : 0)))
    }

    /// Markdown bold: wraps each selection (or the word at the caret) in **.
    @objc func boldSelection(_ sender: Any?) {
        let s = string as NSString
        var r = selectedRange()
        if r.length == 0 { r = wordRange(at: r.location) }
        let inner = s.substring(with: r)
        if inner.hasPrefix("**"), inner.hasSuffix("**"), inner.count >= 4 {
            let plain = String(inner.dropFirst(2).dropLast(2))
            replace(r, with: plain, select: NSRange(location: r.location, length: (plain as NSString).length))
        } else {
            replace(r, with: "**\(inner)**", select: NSRange(location: r.location + 2, length: r.length))
        }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)): return isEditable && Clip.string != nil
        case #selector(boldSelection(_:)): return isEditable && editorView?.document.language == .markdown
        case #selector(duplicateLine(_:)), #selector(deleteLine(_:)), #selector(moveLineUp(_:)), #selector(moveLineDown(_:)),
             #selector(indentSelection(_:)), #selector(outdentSelection(_:)):
            return isEditable
        default: return super.validateMenuItem(item)
        }
    }
}
