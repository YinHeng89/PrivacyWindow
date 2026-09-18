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
    /// Below this size a window is assumed to be a helper sliver (1px drag
    /// proxies, tooltips) rather than somewhere anybody is working.
    ///
    /// A *preference*, not a rule — see `preferred(_:frontmostPID:)`:
    /// preferring bigger windows keeps a sliver from taking the cutout from the
    /// real window behind it, while still letting a genuinely small window have
    /// one when it is all the desktop has.
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

    /// Where the *utility* band starts (19, `kCGUtilityWindowLevel`) — the
    /// floating tool panels applications park on screen permanently. The dialog
    /// band stops here: below `systemDialogLayerMinimum … utilityLayerMinimum`
    /// sits the stuff raised on purpose to interrupt you, while 19 is where apps
    /// put things that merely *stay* in front. A utility window belonging to a
    /// background app has no claim on the cutout while the user is working in
    /// another app, so it does not outrank the frontmost app's own windows — it
    /// still counts as a last resort, exactly as it always has.
    private static let utilityLayerMinimum = 19

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
    /// How close (points) a bar has to sit to a display edge to count as one.
    private static let barEdgeTolerance: CGFloat = 2

    static func isBar(_ rect: CGRect, on display: CGRect) -> Bool {
        let wide = rect.width >= display.width * barWidthFraction
        let short = rect.height <= display.height * barHeightFraction
        guard wide, short else { return false }
        // Shape alone is not enough. Both thresholds are pure proportions, so on
        // a wide display — anything from a 27" panel to a 5120px ultrawide — a
        // perfectly ordinary window dragged into the corner reads exactly like
        // Chrome's toolbar: 80% wide, a fifth of the height. Taking it for chrome
        // pushes the cutout onto whatever window happens to be behind it.
        //
        // Real bars are chrome, and chrome is *glued to an edge of the display*:
        // the slide-down toolbar sits flush with the very top of the screen.
        // Requiring that turns this into a test a window has to deliberately
        // satisfy, instead of one any wide short rectangle trips.
        let flushWithTop = abs(rect.minY - display.minY) <= barEdgeTolerance
        let flushWithBottom = abs(rect.maxY - display.maxY) <= barEdgeTolerance
        return flushWithTop || flushWithBottom
    }

    /// A window `decode` accepted, together with the only other fact the
    /// selection policy needs — the layer it sits on. Kept out of
    /// `FocusedWindow` because nothing downstream cares about the layer, and so
    /// the policy below can be checked without asking the window server for
    /// anything.
    struct FocusCandidate {
        let window: FocusedWindow
        let layer: Int
    }

    /// Walks the on-screen window list and picks the one that gets the cutout.
    /// `nil` only when the desktop has no qualifying window at all, in which
    /// case the screen stays sharp.
    static func focusedWindow() -> FocusedWindow? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = list.compactMap { decode($0, selfPID: selfPID, frontmostPID: frontmostPID) }

        // The size threshold is a preference, not a rule — see `preferred`.
        return preferred(candidates, frontmostPID: frontmostPID)
    }

    /// `select` over the sizeable candidates, widening to every candidate once
    /// none of them qualified. Helper slivers — 1px drag proxies, tooltips —
    /// must not take the cutout from the real window behind them, but rejecting
    /// small windows outright would leave a genuinely small one the user *is*
    /// working in (a mini player, a narrow tool palette below `minimumSize`)
    /// with nothing eligible at all, which drops every overlay and shows the
    /// whole desktop sharp. Both halves of that live here rather than in
    /// `focusedWindow` so the policy can be checked without a window server.
    static func preferred(_ candidates: [FocusCandidate], frontmostPID: pid_t?) -> FocusedWindow? {
        select(candidates, frontmostPID: frontmostPID)
            ?? select(candidates, frontmostPID: frontmostPID, allowSmall: true)
    }

    /// Chooses between the accepted windows. `candidates` is front-to-back —
    /// the order `CGWindowList` enumerates in, which is the same order the
    /// windows are stacked in — so inside one tier the first match really is the
    /// topmost window of that kind.
    ///
    /// The tiers themselves are ordered by *entitlement*, not by stacking, and
    /// getting that order wrong is the whole class of bug here:
    ///
    /// 1. **The dialog band (8…18), owned by anybody.** These are in front
    ///    because somebody deliberately put them there, and the frontmost
    ///    application is very often *not* the one asking: a background agent can
    ///    raise a modal panel without ever activating itself, in which case it
    ///    stays inactive while its dialog covers everything. Ranking this tier
    ///    first is what gates it: scanning for the frontmost app's windows first
    ///    returned the window *behind* the dialog, leaving the hole parked there
    ///    while the thing the user is answering stayed blurred — the same
    ///    failure as connecting to a server, from the other direction.
    /// 2. **The frontmost app's own windows.** This is what stops another app's
    ///    always-on-top decoration (a desktop pet, a lyrics HUD — see
    ///    `isEligibleLayer`) from owning the cutout while the user works in
    ///    something else. Stacked utility panels from background apps fall past
    ///    this tier deliberately: being visible is not the same as being asked
    ///    about.
    /// 3. **Anything else eligible** — mostly layer 0 windows belonging to other
    ///    apps, which is how the desktop, a menu-bar app and a panel raised by
    ///    an inactive agent get a hole at all. If literally nothing qualifies
    ///    the focus stays `nil` and the screen stays sharp: for this app, losing
    ///    the blur entirely is the one failure direction worth any amount of
    ///    care.
    ///
    /// `allowSmall` admits windows below `minimumSize`; see `preferred`.
    static func select(
        _ candidates: [FocusCandidate],
        frontmostPID: pid_t?,
        allowSmall: Bool = false
    ) -> FocusedWindow? {
        var dialog: FocusedWindow?
        var frontmost: FocusedWindow?
        var fallback: FocusedWindow?
        for candidate in candidates {
            let window = candidate.window
            let bigEnough = allowSmall ||
                (window.rect.width >= minimumSize.width && window.rect.height >= minimumSize.height)
            guard bigEnough else { continue }
            if dialog == nil,
               candidate.layer >= systemDialogLayerMinimum,
               candidate.layer < utilityLayerMinimum {
                dialog = window
            } else if frontmost == nil, window.pid == frontmostPID {
                frontmost = window
            } else if fallback == nil {
                fallback = window
            }
        }
        return dialog ?? frontmost ?? fallback
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
        // Window ids get recycled, and the description for a recycled id
        // describes somebody else's window — plausible enough that this asks
        // whose window it really is before trusting it. Without this the
        // cutout could be welded, for the rest of the session, to a window that
        // merely inherited the id of the one that closed.
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
              pid_t(ownerPID) == focus.pid else { return nil }
        // The window is already the one being tracked, so it counts as trusted
        // for the decoration band *and* for its size: re-deciding either here
        // could reject the very window it has been following — as happened to
        // any window dragged a little below `minimumSize` — clearing every
        // overlay mid-drag and leaving the whole desktop sharp. Only a genuinely
        // gone or minimized window may return nil.
        return decode(
            entry,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: focus.pid
        )?.window
    }

    /// Turns one `CGWindowList` entry into a candidate for the focus, or `nil`
    /// when the entry is not eligible at all. `frontmostPID` is used only to
    /// decide whether a window in the `1…7` decoration band counts (see
    /// `isEligibleLayer`).
    ///
    /// Deliberately says nothing about size: how much of the window there is
    /// decides nothing about whether it is eligible, and answering it here would
    /// take the decision away from `select`, which needs it to fall back rather
    /// than to reject.
    private static func decode(
        _ info: [String: Any],
        selfPID: pid_t,
        frontmostPID: pid_t?
    ) -> FocusCandidate? {
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

        return FocusCandidate(
            window: FocusedWindow(
                windowID: CGWindowID(windowID),
                pid: pid_t(ownerPID),
                rect: rect,
                displayID: displayID
            ),
            layer: layer
        )
    }

}
