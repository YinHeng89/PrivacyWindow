import AppKit
import CoreGraphics

/// Drives the privacy blur: one overlay per screen, refreshed on a timer, with
/// a transparent hole over the active window.
@MainActor
final class PrivacyController {
    private let capturer = ScreenCapturer()
    private var overlays: [CGDirectDisplayID: BlurOverlay] = [:]
    private var timer: Timer?
    private var tickInFlight = false

    private var enabled = false
    private var blurRadius: Double = 20

    /// The last known focused-window rectangle (Cocoa-global) and the display it
    /// lives on. Kept across ticks so opening our own menu does not flash a
    /// fully blurred screen.
    private var lastHole: NSRect?
    private var lastHoleDisplay: CGDirectDisplayID?

    var isEnabled: Bool { enabled }
    var currentBlurRadius: Double { blurRadius }

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

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        timer?.invalidate()
        timer = nil
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        lastHole = nil
        lastHoleDisplay = nil
    }

    private func tick() {
        guard !tickInFlight else { return }
        tickInFlight = true
        Task {
            await tickAsync()
            tickInFlight = false
        }
    }

    private func tickAsync() async {
        if let focus = FocusTracker.focusedWindowFrame() {
            lastHole = focus
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: focus.midX, y: focus.midY)) }),
               let id = screen.displayID {
                lastHoleDisplay = id
            }
        }

        for (id, overlay) in overlays {
            guard let (image, scale) = await capturer.capture(displayID: id) else { continue }
            var hole: NSRect?
            if let lastHole, id == lastHoleDisplay,
               let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                hole = CoordinateConverter.local(lastHole, in: screen)
            }
            overlay.update(image: image, scale: scale, hole: hole, blurRadius: blurRadius)
        }
    }
}
