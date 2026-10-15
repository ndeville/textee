import AppKit

// MARK: Tab bar

/// 1 tab per open file. Drawn by hand: 1 view, no subviews per tab.
final class TabBar: NSView {
    weak var controller: MainWindowController?
    var titles: [(name: String, path: String, dirty: Bool)] = [] { didSet { rebuildTooltips(); needsDisplay = true } }
    var active = 0 { didSet { needsDisplay = true } }
    private var hover = -1
    private var hoverClose = false
    private var dragFrom: Int?
    private var tracking: NSTrackingArea?

    static let height: CGFloat = 32
    private let minWidth: CGFloat = 70
    private let maxWidth: CGFloat = 230

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var tabWidth: CGFloat {
        guard !titles.isEmpty else { return maxWidth }
        return max(minWidth, min(maxWidth, (bounds.width - 8) / CGFloat(titles.count)))
    }

    private func tabRect(_ i: Int) -> NSRect {
        NSRect(x: 4 + CGFloat(i) * tabWidth, y: 4, width: tabWidth - 2, height: bounds.height - 4)
    }

    private func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i)
        return NSRect(x: r.maxX - 22, y: r.midY - 8, width: 16, height: 16)
    }

    private func index(at p: NSPoint) -> Int? {
        for i in titles.indices where tabRect(i).contains(p) { return i }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        for i in titles.indices { addToolTip(tabRect(i), owner: titles[i].path as NSString, userData: nil) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildTooltips()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = index(at: p) ?? -1
        let hc = h >= 0 && closeRect(h).contains(p)
        if h != hover || hc != hoverClose { hover = h; hoverClose = hc; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = -1; hoverClose = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else {
            if event.clickCount == 2 { controller?.newScratch(nil) }
            return
        }
        if closeRect(i).contains(p) { controller?.closeTab(at: i); return }
        dragFrom = i
        controller?.selectTab(i)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        let p = convert(event.locationInWindow, from: nil)
        let to = max(0, min(titles.count - 1, Int((p.x - 4) / tabWidth)))
        if to != from {
            controller?.moveTab(from: from, to: to)
            dragFrom = to
        }
    }

    override func mouseUp(with event: NSEvent) { dragFrom = nil }

    override func otherMouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { controller?.closeTab(at: i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.chromeLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        for i in titles.indices {
            let r = tabRect(i)
            let isActive = i == active
            if isActive {
                Theme.background.setFill()
                NSBezierPath(roundedRect: r, xRadius: Settings.radius(5), yRadius: Settings.radius(5)).fill()
                NSRect(x: r.minX, y: r.maxY - 6, width: r.width, height: 6).fill()
                Theme.accent.setFill()
                NSRect(x: r.minX + 6, y: r.minY, width: r.width - 12, height: 2).fill()
            } else if i == hover {
                Theme.chromeRaised.setFill()
                NSBezierPath(roundedRect: r, xRadius: Settings.radius(5), yRadius: Settings.radius(5)).fill()
            }
            let t = titles[i]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isActive ? NSFont.systemFont(ofSize: 12, weight: .semibold) : Theme.uiFont,
                .foregroundColor: isActive ? Theme.chromeText : Theme.chromeMuted,
                .paragraphStyle: para,
            ]
            let textRect = NSRect(x: r.minX + 12, y: r.midY - 8, width: r.width - 40, height: 17)
            (t.name as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            let cr = closeRect(i)
            if i == hover || isActive {
                if i == hover, hoverClose {
                    Theme.accentDim.setFill()
                    NSBezierPath(roundedRect: cr, xRadius: Settings.radius(4), yRadius: Settings.radius(4)).fill()
                }
                let x = NSBezierPath()
                x.move(to: NSPoint(x: cr.minX + 5, y: cr.minY + 5)); x.line(to: NSPoint(x: cr.maxX - 5, y: cr.maxY - 5))
                x.move(to: NSPoint(x: cr.maxX - 5, y: cr.minY + 5)); x.line(to: NSPoint(x: cr.minX + 5, y: cr.maxY - 5))
                x.lineWidth = 1.4
                (isActive ? Theme.chromeText : Theme.chromeMuted).setStroke()
                x.stroke()
            } else if t.dirty {
                Theme.accent.setFill()
                NSBezierPath(ovalIn: cr.insetBy(dx: 4, dy: 4)).fill()
            }
        }
    }
}

// MARK: Status bar

final class StatusBar: NSView {
    let position = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    let selection = NSTextField(labelWithString: "")
    let info = NSTextField(labelWithString: "")
    let message = NSTextField(labelWithString: "")

    static let height: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [position, counts, selection, info, message] {
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.textColor = Theme.statusMuted
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        counts.textColor = Theme.statusText
        selection.textColor = Theme.statusText
        message.textColor = Theme.statusWarn
        counts.toolTip = "Characters as LinkedIn counts them (UTF-16: an emoji counts 2).\nGreen: fits an invitation note (300). Orange: over the post limit (3,000)."
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.statusBackground.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let y: CGFloat = 5
        var x: CGFloat = 12
        for f in [position, counts, selection] {
            f.sizeToFit()
            f.frame.origin = NSPoint(x: x, y: y)
            x += f.frame.width + (f.stringValue.isEmpty ? 0 : 18)
        }
        info.sizeToFit()
        info.frame.origin = NSPoint(x: bounds.width - info.frame.width - 12, y: y)
        message.sizeToFit()
        let room = info.frame.minX - 18 - x
        message.frame = NSRect(x: x, y: y, width: max(0, min(message.frame.width, room)), height: message.frame.height)
    }

    func set(position p: String, counts c: String, charCount: Int, selection s: String, info i: String) {
        position.stringValue = p
        counts.stringValue = c
        counts.textColor = charCount > 3000 ? Theme.statusWarn : (charCount > 0 && charCount <= 300 ? Theme.statusGood : Theme.statusText)
        selection.stringValue = s
        info.stringValue = i
        needsLayout = true
    }

    private var messageTimer: Timer?

    func flash(_ text: String, seconds: TimeInterval = 4) {
        message.stringValue = text
        needsLayout = true
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.message.stringValue = ""
        }
    }
}

// MARK: Empty state

final class EmptyView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        let lines = ["⌘N  New scratch file", "⇧⌘N  New from clipboard", "⌘P  Quick open", "⌘O  Open a file"]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: Theme.gutterText]
        var y = bounds.midY - CGFloat(lines.count) * 12
        for l in lines {
            let s = l as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: NSPoint(x: bounds.midX - w / 2, y: y), withAttributes: attrs)
            y += 24
        }
    }
}
