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

    /// Highest window layer a focus candidate may sit on: utility panels (19),
    /// the top of the *content* band. The Dock (20) and everything above it —
    /// menu bar (24), status windows (25), pop-up menus (101), the screen saver
    /// (1000) — is chrome, never content, and must never become the blurred-out
    /// "focus".
    private static let focusableLayerMaximum = 19 // kCGUtilityWindowLevel

    /// The lowest layer only system dialogs use: modal panels (8). Anything at
    /// or above this is in front because something deliberately put it there.
    private static let systemDialogLayerMinimum = 8 // kCGModalPanelWindowLevel

    /// Whether a window sitting on `layer` is allowed to take the focus.
    ///
    /// - **0** is ordinary application content.
    /// - **8 and up** is the system-dialog band: modal panels, authentication
    ///   prompts, volume pickers. These are exactly what the user is answering,
    ///   so they always count, whoever owns them. Refusing them is what left the
    ///   blur cutout parked on the small "正在连接 smb://…" strip: that strip is
    ///   a floating panel and could take the focus, while the volume picker it
    ///   raises is a modal panel — and a ceiling of 3 meant the picker could
    ///   never win, no matter how far in front of the strip it was.
    /// - **1…7** is the always-on-top *decoration* band — floating HUDs, desktop
    ///   pets, lyrics strips, sticky overlays. Admitting those unconditionally
    ///   would let some background app's pet steal the focus, so they count only
    ///   when they belong to the frontmost application: Quick Look previews and
    ///   floating palettes are in this band and are things the user really is
    ///   reading, while a pet parked over someone else's window is not.
    static func isEligibleLayer(_ layer: Int, fromFrontmostApp: Bool) -> Bool {
        guard (0...focusableLayerMaximum).contains(layer) else { return false }
        if layer == 0 || layer >= systemDialogLayerMinimum { return true }
        return fromFrontmostApp
    }

    /// A window spanning most of a display's width while taking up only a
    /// sliver of its height is a **bar**, not somewhere you are working.
    ///
    /// Chrome is the reason this exists: in full-screen it puts its slide-down
    /// toolbar in a window of its own, and that window sits *in front of* the
    /// browser window proper. Taking it for the focus cut a ~90pt strip across
    /// the top of the screen instead of revealing the window — and, because a
    /// strip covers almost none of the display, nothing downstream recognised
    /// the app as full-screen either.
    private static let barWidthFraction: CGFloat = 0.8
    private static let barHeightFraction: CGFloat = 0.3

    /// Walks the on-screen window list front-to-back and returns the first
    /// ordinary window belonging to another app. `nil` only when the desktop
    /// has no qualifying window at all, in which case the screen stays sharp.
    ///
    /// Done in two passes so a background app's always-on-top panel (a floating
    /// HUD parked in the `1…7` decoration band) cannot hijack the focus
    /// forever: pass 1 only considers windows owned by the frontmost
    /// application, pass 2 falls back to the full front-to-back scan when that
    /// app has no eligible window of its own (the desktop, a menu-bar app, or a
    /// dialog shown by a background agent that never activates itself). Both
    /// passes take system dialogs — layer 8 and up — from any app, because a
    /// modal panel is in front precisely because it is asking the user
    /// something.
    static func focusedWindow() -> FocusedWindow? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Pass 1 — the frontmost app only. This is what stops a stray HUD from a
        // background app (which may sit visually in front of everything) from
        // being reported as the focus. Quick Look stays covered because the
        // preview panel belongs to the frontmost app itself.
        if let frontmostPID, frontmostPID != selfPID {
            for info in list {
                if let focus = decode(info, selfPID: selfPID, frontmostPID: frontmostPID), focus.pid == frontmostPID {
                    return focus
                }
            }
        }
        // Pass 2 — the full front-to-back scan, used when the active app has no
        // eligible window of its own. Decoration-band windows only count here
        // when they are the frontmost app's, which is what keeps a desktop pet
        // or a lyrics HUD belonging to some other app from becoming the cutout;
        // system dialogs pass regardless of owner, so a modal panel put up by an
        // agent that never activates itself still gets the hole. If literally
        // nothing qualifies the focus is left nil and the desktop stays sharp —
        // the safe direction.
        for info in list {
            if let focus = decode(info, selfPID: selfPID, frontmostPID: frontmostPID) { return focus }
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
        // The window is already the one being tracked, so it counts as trusted
        // for the decoration band: re-deciding that here could reject it and drop
        // the focus, which clears every overlay for a frame. Only a genuinely
        // gone or minimized window may return nil.
        return decode(
            entry,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: focus.pid
        )
    }

    /// Turns one `CGWindowList` entry into a `FocusedWindow`, or `nil` when the
    /// entry is not an eligible focus candidate. `frontmostPID` is used only to
    /// decide whether a window in the `1…7` decoration band counts (see
    /// `isEligibleLayer`).
    private static func decode(
        _ info: [String: Any],
        selfPID: pid_t,
        frontmostPID: pid_t?
    ) -> FocusedWindow? {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID != selfPID else { return nil }
        guard let windowID = info[kCGWindowNumber as String] as? Int else { return nil }
        // Layer 0 = ordinary windows. Higher layers hold Quick Look previews,
        // floating palettes, modal panels and system dialogs, some of which are
        // exactly what the user is looking at; `isEligibleLayer` sorts that band
        // out. The ceiling is the Dock (20), which may never become the focus.
        guard let layer = info[kCGWindowLayer as String] as? Int,
              isEligibleLayer(layer, fromFrontmostApp: pid_t(ownerPID) == frontmostPID) else { return nil }
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

        // Which display the window belongs to is decided by *overlap*, not by
        // where its centre lands. A window dragged more than half off an edge
        // has its centre outside every display, and a centre test then discards
        // it: the scan moves on to whatever window is behind it and cuts the
        // hole there, or — if there is none — the focus is lost entirely, which
        // clears every overlay and leaves the whole desktop sharp. Losing the
        // blur is the one failure direction this app must never take.
        var bestArea: CGFloat = 0
        var bestFrame: CGRect?
        var bestID: CGDirectDisplayID?
        var covering = 0
        for screen in NSScreen.screens {
            guard let cgFrame = screen.cgFrame, let id = screen.displayID else { continue }
            let part = rect.intersection(cgFrame)
            guard !part.isNull, !part.isEmpty else { continue }
            covering += 1
            let area = part.width * part.height
            if area > bestArea {
                bestArea = area
                bestFrame = cgFrame
                bestID = id
            }
        }
        guard let displayID = bestID, let display = bestFrame else { return nil }

        // The bar test only means something against a single display: it looks
        // for a strip spanning that display's full width. A window spanning two
        // displays is by definition wider than either one, so measuring it
        // against a single display would condemn ordinary wide windows.
        if covering <= 1, isBar(rect, on: display) { return nil }

        return FocusedWindow(
            windowID: CGWindowID(windowID),
            pid: pid_t(ownerPID),
            rect: rect,
            displayID: displayID
        )
    }

    static func isBar(_ rect: CGRect, on display: CGRect) -> Bool {
        rect.width >= display.width * barWidthFraction && rect.height <= display.height * barHeightFraction
    }
}
