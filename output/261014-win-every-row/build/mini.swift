// 1 window with 1 text view, as small as AppKit allows.
// MINI_MODE=tk1: NSTextView on TextKit 1, as Textee. tk2 (default): NSTextView on TextKit 2, as TextEdit.
// tk1short: TextKit 1, with the text view only as tall as its text; the clip view's layer colour fills the rest.
// ct: no NSTextView, a plain view that draws the visible lines with Core Text (the floor of a custom text view).
import AppKit

let env = ProcessInfo.processInfo.environment
let mode = env["MINI_MODE"] ?? "tk2"
let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

/// Draws only the lines in the dirty rect. No editing: this measures what a custom view would cost at rest.
final class LinesView: NSView {
    let text: NSString
    var starts: [Int] = [0]
    let lineHeight: CGFloat = 17
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

    init(text: NSString, width: CGFloat) {
        self.text = text
        for i in 0..<text.length where text.character(at: i) == 10 { starts.append(i + 1) }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(starts.count) * lineHeight))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(starts.count - 1, Int(dirtyRect.maxY / lineHeight))
        guard first <= last else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for i in first...last {
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : text.length
            let s = text.substring(with: NSRange(location: starts[i], length: max(0, min(end - starts[i], 400))))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.textPosition = CGPoint(x: 4, y: CGFloat(i + 1) * lineHeight - 4)
            CTLineDraw(line, ctx)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 3840, y: 41, width: 1920, height: 1080),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let scroll = NSScrollView(frame: window.contentLayoutRect)
scroll.hasVerticalScroller = true
let content = (try? String(contentsOfFile: env["MINI_FILE"] ?? "", encoding: .utf8)) ?? ""
if mode == "ct" {
    scroll.documentView = LinesView(text: content as NSString, width: scroll.contentSize.width)
} else {
    let tv = NSTextView(usingTextLayoutManager: !mode.hasPrefix("tk1"))
    tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
    tv.autoresizingMask = [.width]
    tv.isVerticallyResizable = true
    tv.textContainer?.widthTracksTextView = true
    tv.isRichText = false
    tv.font = font
    if mode.hasPrefix("tk1") { tv.layoutManager?.allowsNonContiguousLayout = true }
    tv.string = content
    scroll.documentView = tv
    if mode == "tk1short" {
        tv.minSize = NSSize(width: 0, height: 0)
        tv.drawsBackground = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        tv.sizeToFit()
    }
}
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
app.run()
