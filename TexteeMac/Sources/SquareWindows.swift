import AppKit
import ObjectiveC

/// Square corners on every titled window (NicAI design, 17th October 2026: no rounded window corners).
///
/// macOS 26 rounds window corners and has no public setting to turn that off. AppKit asks the window's
/// frame view (`NSThemeFrame`, private) for `_cornerRadius`, and this answers 0: the window, its mask
/// and its shadow become square. Call `SquareWindows.install()` before the first window opens.
/// If a later macOS removes the method, the call does nothing and the corners stay rounded.
///
/// Canonical copy: ~/ai/_shared/nicai-design/macos/SquareWindows.swift. Each app keeps its own copy.
enum SquareWindows {
    static func install() {
        guard let frame = NSClassFromString("NSThemeFrame"),
              let method = class_getInstanceMethod(frame, NSSelectorFromString("_cornerRadius")) else { return }
        let zero: @convention(block) (AnyObject) -> CGFloat = { _ in 0 }
        method_setImplementation(method, imp_implementationWithBlock(zero))
    }
}
