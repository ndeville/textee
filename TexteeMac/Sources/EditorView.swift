import AppKit

/// Line numbers, drawn from the layout manager for the visible lines only.
final class Gutter: NSView {
    weak var editor: EditorView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var attrsCache: (size: CGFloat, normal: [NSAttributedString.Key: Any], current: [NSAttributedString.Key: Any])?

    private func attributes() -> ([NSAttributedString.Key: Any], [NSAttributedString.Key: Any]) {
        let size = max(10, Document.fontSize - 2)
        if let c = attrsCache, c.size == size { return (c.normal, c.current) }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterCurrent]
        attrsCache = (size, normal, current)
        return (normal, current)
    }

    /// Width for the current line count.
    func preferredWidth(lines: Int) -> CGFloat {
        let digits = max(3, String(lines).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, Document.fontSize - 2), weight: .regular)
        let w = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * w + 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let ev = editor, let tv = ev.textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let (normal, current) = attributes()
        let s = tv.string as NSString
        let lines = ev.document.lines
        let visible = tv.visibleRect.offsetBy(dx: -tv.textContainerOrigin.x, dy: -tv.textContainerOrigin.y)
        // Text view y to gutter y: both views are flipped, the scroll offset is in the conversion.
        let originY = convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), from: tv).y
        let caretLine = tv.isMulti ? -1 : lines.line(at: tv.selectedRange().location)
        let rightEdge = bounds.width - 10
        let lineHeight = ceil(lm.defaultLineHeight(for: Theme.editorFont(size: Document.fontSize)))

        func drawNumber(_ n: Int, _ rect: NSRect) {
            let label = String(n + 1) as NSString
            let attrs = n == caretLine ? current : normal
            let size = label.size(withAttributes: attrs)
            let y = rect.minY + originY + (min(rect.height, lineHeight) - size.height) / 2
            label.draw(at: NSPoint(x: rightEdge - size.width, y: y), withAttributes: attrs)
        }

        if s.length == 0 {
            drawNumber(0, lm.extraLineFragmentRect)
            return
        }
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = lines.line(at: chars.location)
        let lastChar = NSMaxRange(chars)
        while line < lines.count {
            let start = lines.starts[line]
            if start > lastChar { break }
            if start >= s.length {
                // The empty line after a final line break.
                drawNumber(line, lm.extraLineFragmentRect)
                break
            }
            let g = lm.glyphIndexForCharacter(at: start)
            let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true)
            drawNumber(line, rect)
            line += 1
        }
        Theme.chromeLine.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).intersection(dirtyRect).fill()
    }
}

/// A bar above the text for conflicts, deleted files and read-only files.
final class Banner: NSView {
    let label = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var actions: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.banner.cgColor
        label.font = Theme.uiFont
        label.textColor = Theme.chromeText
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, _ choices: [(String, () -> Void)]) {
        label.stringValue = text
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        actions = choices.map(\.1)
        for (i, c) in choices.enumerated() {
            let b = NSButton(title: c.0, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Theme.uiFontSmall
            addSubview(b)
            buttons.append(b)
        }
        needsLayout = true
    }

    @objc private func tap(_ sender: NSButton) { actions[sender.tag]() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 12, y: (bounds.height - label.frame.height) / 2)
        var x = bounds.width - 10
        for b in buttons.reversed() {
            b.sizeToFit()
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: (bounds.height - b.frame.height) / 2)
            x -= 6
        }
    }
}

/// The editor of 1 document: banner, gutter, text. Created the first time the tab shows.
final class EditorView: NSView, NSTextViewDelegate {
    unowned let document: Document
    let scrollView = NSScrollView()
    private(set) var textView: EditorTextView!
    let gutter = Gutter()
    let banner = Banner()
    var bannerVisible = false { didSet { banner.isHidden = !bannerVisible; needsLayout = true } }
    weak var controller: MainWindowController?

    init(document: Document) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        document.editorDidLoad()
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func build() {
        // Since macOS 14 views don't clip by default: the editor painted over the tab bar.
        clipsToBounds = true
        gutter.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.borderType = .noBorder

        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        let tc = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        document.storage.addLayoutManager(lm)
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: tc)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.configure()
        tv.editorView = self
        tv.delegate = self
        tv.isEditable = !document.isReadOnly
        textView = tv
        scrollView.documentView = tv

        gutter.editor = self
        addSubview(gutter)
        addSubview(scrollView)
        banner.isHidden = true
        addSubview(banner)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: tv)

        document.onEdit = { [weak self] _ in self?.textChangedInStorage() }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let bannerH: CGFloat = bannerVisible ? 32 : 0
        banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bannerH)
        let gw = controller?.showLineNumbers == false ? 0 : gutter.preferredWidth(lines: document.lines.count)
        gutter.isHidden = gw == 0
        gutter.frame = NSRect(x: 0, y: bannerH, width: gw, height: bounds.height - bannerH)
        scrollView.frame = NSRect(x: gw, y: bannerH, width: bounds.width - gw, height: bounds.height - bannerH)
        highlightVisible()
    }

    // MARK: Changes

    /// From the text storage, inside the edit: only cheap bookkeeping here.
    private func textChangedInStorage() {
        let w = gutter.preferredWidth(lines: document.lines.count)
        if w != gutter.frame.width, !gutter.isHidden { needsLayout = true }
    }

    func textDidChange(_ notification: Notification) {
        highlightVisible()
        gutter.needsDisplay = true
        controller?.documentDidChange(document)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionDidChange()
    }

    func selectionDidChange() {
        gutter.needsDisplay = true
        controller?.selectionDidChange(document)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { document.undo }

    func escapePressed() { controller?.escapePressed() }

    @objc private func boundsChanged() {
        highlightVisible()
        gutter.needsDisplay = true
    }

    // MARK: Colours

    func visibleCharacterRange() -> NSRange {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return NSRange(location: 0, length: 0) }
        let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private var colouring = false
    private var recolourQueued = false

    /// Adding colours can make AppKit lay out more text, resize the text view and post a frame change, which
    /// lands here again inside `apply` (a minified JSON file crashed on it, 31st October 2026). The nested
    /// call waits for the next run-loop turn instead.
    func highlightVisible() {
        guard !colouring else {
            if !recolourQueued {
                recolourQueued = true
                DispatchQueue.main.async { [weak self] in
                    self?.recolourQueued = false
                    self?.highlightVisible()
                }
            }
            return
        }
        colouring = true
        defer { colouring = false }
        guard let hl = document.highlighter, let lm = textView.layoutManager else { return }
        let vis = visibleCharacterRange()
        let s = textView.string as NSString
        // A margin of 4,000 characters on each side: short scrolls don't show uncoloured text.
        let start = max(0, vis.location - 4000)
        let end = min(s.length, NSMaxRange(vis) + 4000)
        hl.apply(lm, s, document.lines, visible: NSRange(location: start, length: end - start))
        controller?.loadedFindBar?.highlightMatches(in: self)
    }

    func applyZoom() {
        textView.typingAttributes = Document.baseAttributes
        needsLayout = true
        gutter.needsDisplay = true
    }

    // MARK: Banner

    func updateBanner() {
        if document.deletedOnDisk {
            banner.show("This file was deleted or moved on disk.", [
                ("Save Again", { [weak self] in self.map { $0.controller?.saveAgain($0.document) } }),
                ("Close", { [weak self] in self.map { $0.controller?.close($0.document, force: true) } }),
            ])
            bannerVisible = true
        } else if document.conflict {
            banner.show("The file changed on disk while you had unsaved edits.", [
                ("Take Disk Version", { [weak self] in self.map { $0.controller?.reloadFromDisk($0.document) } }),
                ("Keep Mine", { [weak self] in self.map { $0.controller?.overwrite($0.document) } }),
            ])
            bannerVisible = true
        } else if let why = document.readOnlyReason {
            banner.show(why, [])
            bannerVisible = true
        } else {
            bannerVisible = false
        }
    }
}
