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

/// The window that currently holds the focus.
///
/// `windowID` is the piece the rest of the app cares about: it is the only
/// stable identity a window has while it is being dragged. Its rectangle
/// changes every frame, so anything keyed on the rectangle (a cached capture
/// filter, for instance) would be rebuilt continuously for no reason.
struct FocusedWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    /// Top-left global coordinates — the native space of `CGWindowList`, which
    /// is also the space `CGDisplayBounds` lives in.
    let rect: CGRect
    let displayID: CGDirectDisplayID
}

@MainActor
enum FocusTracker {
    /// Windows smaller than this are helper slivers (1px drag proxies,
    /// tooltips); ignoring them lets a real window behind them be picked.
    private static let minimumSize = CGSize(width: 120, height: 80)

    /// Walks the on-screen window list front-to-back and returns the first
    /// ordinary window belonging to another app. `nil` only when the desktop
    /// has no qualifying window at all, in which case the screen stays sharp.
    static func focusedWindow() -> FocusedWindow? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            if let focus = decode(info, selfPID: selfPID) { return focus }
        }
        return nil
    }

    /// Re-reads just the window we are already tracking.
    ///
    /// Tracking a dragged window means asking the window server for its frame
    /// every single frame, and a full `CGWindowListCopyWindowInfo` returns and
    /// deserialises every window on the desktop to answer. Asking about one
    /// known window id is several times cheaper. This can only ever refresh the
    /// *same* window — noticing that the focus moved elsewhere still needs the
    /// full scan in `focusedWindow()`, so the caller must keep doing that too.
    ///
    /// Returns `nil` when the window is gone, minimized, or no longer eligible.
    static func refresh(_ focus: FocusedWindow) -> FocusedWindow? {
        let ids = [NSNumber(value: focus.windowID)] as CFArray
        guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let entry = list.first else { return nil }
        return decode(entry, selfPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Turns one `CGWindowList` entry into a `FocusedWindow`, or `nil` when the
    /// entry is not an eligible focus candidate.
    private static func decode(_ info: [String: Any], selfPID: pid_t) -> FocusedWindow? {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID != selfPID else { return nil }
        guard let windowID = info[kCGWindowNumber as String] as? Int else { return nil }
        // Layer 0 = ordinary windows. Anything above belongs to menus,
        // tooltips, overlays, and must never become the focus.
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
        // The full list is queried with `optionOnScreenOnly`, but a
        // single-window lookup is not — and a minimized window keeps reporting
        // bounds near the Dock, which would drag the cutout there.
        if let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, !onScreen { return nil }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let w = (bounds["Width"] as? NSNumber)?.doubleValue,
              let h = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        guard rect.width >= minimumSize.width, rect.height >= minimumSize.height else { return nil }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let cgFrame = screen.cgFrame, let id = screen.displayID else { continue }
            if cgFrame.contains(center) {
                return FocusedWindow(
                    windowID: CGWindowID(windowID),
                    pid: pid_t(ownerPID),
                    rect: rect,
                    displayID: id
                )
            }
        }
        return nil
    }
}
