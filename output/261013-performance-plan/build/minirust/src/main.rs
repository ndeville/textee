use objc2::rc::Retained;
use objc2::MainThreadMarker;
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSBackingStoreType, NSTextView, NSWindow, NSWindowStyleMask};
use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};

fn main() {
    let mtm = MainThreadMarker::new().unwrap();
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    let rect = NSRect::new(NSPoint::new(100.0, 100.0), NSSize::new(1920.0, 1080.0));
    let style = NSWindowStyleMask::Titled | NSWindowStyleMask::Closable | NSWindowStyleMask::Resizable | NSWindowStyleMask::Miniaturizable;
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(mtm.alloc(), rect, style, NSBackingStoreType::Buffered, false)
    };
    unsafe { window.setReleasedWhenClosed(false) };
    let scroll = NSTextView::scrollableTextView(mtm);
    let tv: Retained<NSTextView> = unsafe { Retained::cast_unchecked(scroll.documentView().unwrap()) };
    let path = std::env::var("MINI_FILE").unwrap_or_default();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    tv.setString(&NSString::from_str(&text));
    window.setContentView(Some(&scroll));
    window.makeKeyAndOrderFront(None);
    app.run();
}
