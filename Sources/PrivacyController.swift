import AppKit
import CoreGraphics

/// Drives the privacy blur: one overlay per screen, refreshed on a timer, with
/// a transparent hole over the active window.
@MainActor
final class PrivacyController {
    private let capturer = ScreenCapturer()
    private var overlays: [CGDirectDisplayID: BlurOverlay] = [:]
    // Two independent cadences: the mask (the clear hole) tracks the focused
    // window at high rate without capturing, while the blurred picture is
    // refreshed at a lower rate to save CPU.
    private var maskTimer: Timer?
    private var captureTimer: Timer?
    private var captureInFlight = false

    private var enabled = false
    private var blurRadius: Double = 20
    /// When true, the menu bar and the Dock are kept sharp (excluded from the
    /// blurred picture) instead of being blurred with everything else.
    private var keepChrome = false

    /// The last known focused-window rectangle (top-left global coordinates,
    /// as reported by `CGWindowList`) and the display it lives on. `nil` means
    /// there is currently no window to focus, so the screen stays clear.
    private var lastHole: CGRect?
    private var lastHolePID: pid_t?
    private var lastHoleDisplay: CGDirectDisplayID?
    /// Tracks whether we presently have a focus, so the screen is only cleared
    /// (and re-blurred) on the transition, not on every idle tick.
    private var hasFocus = false

    var isEnabled: Bool { enabled }
    var currentBlurRadius: Double { blurRadius }
    var keepsChromeClear: Bool { keepChrome }

    /// Toggles whether the menu bar and Dock stay sharp. Drops the overlays
    /// below the system chrome so it keeps rendering on top, rebuilds the
    /// capture filters, and refreshes the picture immediately.
    func setKeepChrome(_ on: Bool) {
        guard keepChrome != on else { return }
        keepChrome = on
        for (_, overlay) in overlays { overlay.setChromeClear(on) }
        capturer.invalidateFilters()
        tickCapture()
    }

    func setBlurRadius(_ radius: Double) {
        blurRadius = radius
    }

    func enable() {
        guard !enabled else { return }
        enabled = true
        if !capturer.hasPermission { capturer.requestPermission() }

        for screen in NSScreen.screens {
            if let id = screen.displayID {
                overlays[id] = BlurOverlay(screen: screen)
            }
        }

        // High-rate path: just chase the focused window's hole. ~30fps, no
        // capture, so dragging stays glued to the window.
        let maskTimer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFocus() }
        }
        RunLoop.main.add(maskTimer, forMode: .common)
        self.maskTimer = maskTimer

        // Low-rate path: re-screenshot + re-blur. Raised to ~30fps too so the
        // blurred background stays in step with the (also 30fps) hole.
        let captureTimer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCapture() }
        }
        RunLoop.main.add(captureTimer, forMode: .common)
        self.captureTimer = captureTimer

        tickFocus()
        tickCapture()
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        maskTimer?.invalidate()
        maskTimer = nil
        captureTimer?.invalidate()
        captureTimer = nil
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        lastHole = nil
        lastHolePID = nil
        lastHoleDisplay = nil
    }

    /// Cheap, high-rate: refresh the hole position from the focus tracker and
    /// push the mask to every overlay. When no window is focusable, clears the
    /// overlays so the screen stays sharp. Runs even when capture is in flight.
    private func tickFocus() {
        guard let focus = FocusTracker.focusedWindow() else {
            // No qualifying window on the desktop: clear once, then idle.
            if hasFocus {
                hasFocus = false
                lastHole = nil
                lastHolePID = nil
                lastHoleDisplay = nil
                for (_, overlay) in overlays { overlay.clear() }
            }
            return
        }
        hasFocus = true
        if let lastHole, lastHole == focus.rect, lastHoleDisplay == focus.displayID, lastHolePID == focus.pid {
            return
        }
        lastHole = focus.rect
        lastHolePID = focus.pid
        lastHoleDisplay = focus.displayID
        applyHoles()
    }

    /// Expensive, low-rate: re-capture each display and re-blur it. Also
    /// re-applies the current hole so the picture and cutout stay in sync.
    /// Skipped entirely when there is no focused window (nothing to blur).
    private func tickCapture() {
        guard !captureInFlight else { return }
        guard lastHole != nil else { return }
        captureInFlight = true
        Task {
            for (id, overlay) in overlays {
                // Exclude the focused window from the source picture so the
                // blur cannot smear its bright content into a halo around the
                // cutout. Only the display holding the window needs it.
                let focus: (pid: pid_t, rect: CGRect)? = {
                    guard let lastHole, let pid = lastHolePID, id == lastHoleDisplay else { return nil }
                    return (pid, lastHole)
                }()
                guard let (image, scale) = await capturer.capture(displayID: id, excludingFocused: focus, keepChrome: keepChrome) else { continue }
                overlay.update(image: image, scale: scale, hole: localHole(for: id), blurRadius: blurRadius)
            }
            captureInFlight = false
        }
    }

    /// The overlay-local (top-left) hole rect for `displayID`, or `nil` when the
    /// focused window is not on that display.
    private func localHole(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let lastHole, displayID == lastHoleDisplay else { return nil }
        // CGWindowList coordinates and CGDisplayBounds share the same
        // top-left-origin space, so subtracting the display origin yields the
        // overlay-local (top-left) hole directly.
        let bounds = CGDisplayBounds(displayID)
        return CGRect(
            x: lastHole.origin.x - bounds.origin.x,
            y: lastHole.origin.y - bounds.origin.y,
            width: lastHole.width,
            height: lastHole.height
        )
    }

    /// Pushes the current hole to every overlay's mask.
    private func applyHoles() {
        for (id, overlay) in overlays {
            overlay.applyMask(hole: localHole(for: id))
        }
    }
}
