import AppKit
import CoreGraphics

extension NSScreen {
    /// The CoreGraphics display identifier backing this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Display bounds in top-left-origin global coordinates — the same space
    /// `CGWindowList` reports window bounds in.
    var cgFrame: CGRect? {
        guard let id = displayID else { return nil }
        return CGDisplayBounds(id)
    }
}

@MainActor
enum FocusTracker {
    /// The frontmost *eligible* on-screen window, in top-left global
    /// coordinates (the native space of `CGWindowList`), plus its owner pid and
    /// the display it lives on. The window list is walked front-to-back and the
    /// first ordinary, sizable window belonging to another app is chosen — so
    /// when the topmost window is no longer eligible (our own menu opens, the
    /// window closes or is minimized), focus falls through to the next
    /// foreground window. `nil` only when the desktop has no qualifying window
    /// at all, in which case the screen should stay clear.
    static func focusedWindow() -> (pid: pid_t, rect: CGRect, displayID: CGDirectDisplayID)? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID != selfPID else { continue }
            // Layer 0 = ordinary windows. Anything above belongs to menus,
            // tooltips, overlays, and must not be treated as the focus.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            // Skip trivial slivers (1px helpers etc.) so a real window behind
            // them can still be picked.
            guard rect.width >= 120, rect.height >= 80 else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            for screen in NSScreen.screens {
                guard let cgFrame = screen.cgFrame, let id = screen.displayID else { continue }
                if cgFrame.contains(center) {
                    return (pid_t(ownerPID), rect, id)
                }
            }
        }
        return nil
    }
}
