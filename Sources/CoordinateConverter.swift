import AppKit
import CoreGraphics

extension NSScreen {
    /// The CoreGraphics display identifier backing this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Helpers for moving between the two coordinate systems macOS uses for
/// windows and screens.
enum CoordinateConverter {
    /// CoreGraphics window bounds use a top-left origin on the primary display
    /// (y grows downward). Cocoa global coordinates use a bottom-left origin (y
    /// grows upward). Mirror across the primary display's height to convert.
    static func cocoaGlobal(from cgRect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        let x = cgRect.origin.x
        let y = primaryHeight - (cgRect.origin.y + cgRect.height)
        return NSRect(x: x, y: y, width: cgRect.width, height: cgRect.height)
    }

    /// Converts a Cocoa-global rectangle into a top-left local rectangle within
    /// the given screen, matching `NSView` / `CALayer` local coordinates.
    static func local(_ globalRect: NSRect, in screen: NSScreen) -> NSRect {
        let x = globalRect.origin.x - screen.frame.origin.x
        let y = (screen.frame.origin.y + screen.frame.height) - (globalRect.origin.y + globalRect.height)
        return NSRect(x: x, y: y, width: globalRect.width, height: globalRect.height)
    }
}
