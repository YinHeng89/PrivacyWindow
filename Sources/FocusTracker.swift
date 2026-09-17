import AppKit
import CoreGraphics

@MainActor
enum FocusTracker {
    /// The frontmost on-screen window of the active application, in Cocoa-global
    /// coordinates, or `nil` when there is no suitable window (our own app is
    /// frontmost, or only the desktop is focused).
    static func focusedWindowFrame() -> NSRect? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        let pid = front.processIdentifier

        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: NSRect?
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == Int(pid) else { continue }
            guard (info[kCGWindowIsOnscreen as String] as? Bool) == true else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            let rect = CoordinateConverter.cocoaGlobal(from: CGRect(x: x, y: y, width: w, height: h))
            // The main window is usually the largest on-screen window of the app.
            if best == nil || rect.height >= best!.height {
                best = rect
            }
        }
        return best
    }
}
