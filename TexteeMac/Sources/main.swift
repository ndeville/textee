import AppKit

Profile.mark("main")
let app = NSApplication.shared
Profile.mark("NSApplication.shared")
let delegate = AppDelegate()
Profile.mark("AppDelegate created")
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
