import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1920, height: 1080),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let scroll = NSTextView.scrollableTextView()
let tv = scroll.documentView as! NSTextView
let path = ProcessInfo.processInfo.environment["MINI_FILE"] ?? ""
tv.string = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
app.run()
