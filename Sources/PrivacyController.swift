import AppKit
import CoreGraphics

/// Drives the privacy blur: one overlay per screen, a display-linked cutout and
/// a background capture loop.
///
/// Two independent timers used to run here — one chasing the cutout, one
/// re-screenshotting — and they were the root of both complaints this rewrite
/// fixes:
///
/// 1. **Not glued to the window.** The two ticks drifted apart, so the layer
///    tree was routinely committed half-updated, and nothing was aligned with
///    the compositor. Now a single display link commits the picture and the
///    cutout together, once per frame, and the cutout is re-read from the
///    window server on every one of those frames.
/// 2. **A flickering white halo.** The capture filter was keyed on the focused
///    window's rectangle, which changes every frame during a drag — so the
///    (slow) shareable-content snapshot was rebuilt constantly, and the window
///    was excluded by a pid/overlap guess that picked the wrong window often
///    enough for the real one to stay in the picture. Keying on the window id
///    makes exclusion exact and the filter stable for the whole drag, and
///    `BlurProcessor` additionally inpaints the cutout so no bright pixel can
///    bleed out of it even when exclusion misses.
@MainActor
final class PrivacyController {
    private let capturer = ScreenCapturer()
    private var overlays: [CGDirectDisplayID: BlurOverlay] = [:]

    /// The single clock: every frame it re-reads the focus and commits picture
    /// + cutout together, in step with the compositor.
    private var displayLink: DisplayLink?
    /// Serial capture loop. It is the only thing that captures, which is what
    /// keeps `ScreenCapturer`'s filter cache free of concurrent writers.
    private var captureTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Debounced rebuild of the overlays after a display change. Those
    /// notifications arrive in bursts — a single resolution animation fires
    /// several — and each one used to tear down and rebuild every overlay
    /// window, blanking the screen each time.
    private var displayChangeTask: Task<Void, Never>?
    /// Geometry of the display arrangement the overlays were last built for.
    private var screenSignature = ""

    private var enabled = false
    private var blurRadius: Double = 20
    /// When true, the menu bar and the Dock are kept sharp (excluded from the
    /// blurred picture) instead of being blurred with everything else.
    private var keepChrome = false
    /// Drop the blur on a display whose focused window already covers almost
    /// all of it — see `largeWindowCoverage`.
    private var autoPauseForLargeWindow = true
    /// Per display: whether it is being blurred, plus a pending reversal that
    /// has to hold for a few frames before it is adopted. Without that
    /// confirmation a window resized right at the threshold would flip
    /// capturing on and off every frame.
    private var blurDecisions: [CGDirectDisplayID: (blur: Bool, pending: Bool?, frames: Int)] = [:]
    /// Set while the machine is asleep, locked or running a screensaver.
    private var powerPaused = false
    /// Last time each display was captured, so secondary displays — which show
    /// a featureless full-screen blur — can be refreshed far less often than
    /// the one with the cutout.
    private var lastCaptureNanos: [CGDirectDisplayID: UInt64] = [:]
    /// Notification tokens paired with the centre they came from, so they can
    /// be removed again.
    private var powerObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private var focus: FocusedWindow?
    /// Consecutive frames whose focus has not changed. Once the desktop has
    /// been quiet for a while the expensive work is throttled back; the frame
    /// anything moves again it goes back to full rate.
    private var settledFrames = 0
    /// Frames since the window server last offered a focusable window.
    private var framesWithoutFocus = 0
    private var frameIndex = 0
    /// Bumped whenever the session is torn down (disable, display
    /// arrangement change). Work started before the bump must not write into
    /// the session that replaced it.
    private var generation = 0

    /// Full window-list scans are the only way to notice the focus *moving to a
    /// different window*, and they enumerate every window on the desktop — so
    /// they run on a subset of frames, and on a smaller subset once nothing is
    /// moving. In between, we only refresh the window we are already tracking.
    /// Staying at 4 rather than 6 keeps the worst-case delay before the cutout
    /// follows a click to ~66ms, which still reads as instant.
    /// With nothing focused there is no visual state to keep up with — only the
    /// arrival of a window matters, and that can afford to be a tenth of the
    /// rate.
    private var fullScanInterval: Int {
        if focus == nil { return 10 }
        return isSettled ? 4 : 3
    }
    /// Grace period before believing "there is no focusable window": a Space
    /// switch empties the window list for the length of its animation, and
    /// clearing the overlay on each of those flickers the whole screen back to
    /// sharp.
    private static let focusLossGraceFrames = 15
    /// Frames that must pass before the desktop counts as settled.
    private static let settledThreshold = 45
    /// How completely the focused window must cover a display before blurring
    /// it stops being worth the power.
    ///
    /// All three have to hold. Area alone is not enough: a window spanning the
    /// full width but only 87% of the height still leaves a desktop strip
    /// several hundred points tall, which is exactly the sort of thing this app
    /// exists to hide. Requiring the window to be nearly as wide and as tall as
    /// the display keeps the saving aimed at maximised and full-screen windows,
    /// where there is genuinely nothing left to see.
    private static let largeWindowCoverage: CGFloat = 0.90
    private static let largeWindowExtent: CGFloat = 0.92
    /// Frames a reversal of the blur decision must hold before it is adopted.
    private static let decisionConfirmationFrames = 8
    /// Refresh period for displays that show a full-screen blur with no cutout.
    /// Their content is unreadable by definition, so 15fps is indistinguishable
    /// from 60fps and costs a third as much.
    private static let secondaryDisplayIntervalNanos: UInt64 = 66_000_000

    var isEnabled: Bool { enabled }
    var currentBlurRadius: Double { blurRadius }
    var keepsChromeClear: Bool { keepChrome }
    var pausesForLargeWindows: Bool { autoPauseForLargeWindow }

    /// Turns the large-window power saving on or off.
    func setAutoPauseForLargeWindow(_ on: Bool) {
        guard autoPauseForLargeWindow != on else { return }
        autoPauseForLargeWindow = on
        settledFrames = 0
    }

    /// Whether `displayID` is worth blurring right now. It is not when the
    /// focused window leaves too little of it to bother hiding.
    private func shouldBlur(displayID: CGDirectDisplayID) -> Bool {
        blurDecisions[displayID]?.blur ?? true
    }

    /// Recomputes the blur decision for every display. Called once per frame
    /// from the display link — never from the capture loop, or the confirmation
    /// count would tick at the capture rate instead of the display rate.
    private func refreshBlurDecisions() {
        for id in overlays.keys {
            let raw = wantsBlur(displayID: id)
            var state = blurDecisions[id] ?? (blur: true, pending: nil, frames: 0)
            if state.blur == raw {
                state.pending = nil
                state.frames = 0
            } else if raw {
                // Turning blur back on is urgent: while it is off the display
                // is showing a frozen picture, and every extra frame of delay
                // is a frame of stale background. Adopt it at once.
                state.blur = true
                state.pending = nil
                state.frames = 0
            } else if state.pending == raw {
                // Turning blur off is the direction that saves power, so it is
                // worth insisting on a few confirming frames: a window resized
                // right at the threshold would otherwise flip capturing on and
                // off every frame.
                state.frames += 1
                if state.frames >= Self.decisionConfirmationFrames {
                    state.blur = false
                    state.pending = nil
                    state.frames = 0
                }
            } else {
                state.pending = raw
                state.frames = 1
            }
            blurDecisions[id] = state
        }
    }

    private func wantsBlur(displayID: CGDirectDisplayID) -> Bool {
        // No display check on the focus: a window spanning two displays can
        // cover the second one just as completely as the first, and
        // `intersection` below already rules out windows that are not on it.
        guard autoPauseForLargeWindow, let focus else { return true }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let visible = focus.rect.intersection(bounds)
        guard !visible.isNull else { return true }
        let coverage = (visible.width * visible.height) / (bounds.width * bounds.height)
        return coverage < Self.largeWindowCoverage ||
               visible.width / bounds.width < Self.largeWindowExtent ||
               visible.height / bounds.height < Self.largeWindowExtent
    }

    /// True once the focus has held still long enough that we can stop paying
    /// for full-rate work.
    private var isSettled: Bool { settledFrames >= Self.settledThreshold }

    /// Pause between captures. Busy runs as fast as the pipeline allows (the
    /// floor only guards against a pathological spin); settled drops to ~30fps,
    /// which is plenty for a static background and keeps the CPU — and the fan
    /// — quiet. With nothing to focus there is nothing to capture at all, so
    /// the loop barely wakes.
    private var captureDelayNanos: UInt64 {
        if focus == nil { return 200_000_000 }
        // Every display has been swallowed by its window: there is literally
        // nothing to capture, so stop waking up for it.
        if !overlays.keys.contains(where: { shouldBlur(displayID: $0) }) { return 200_000_000 }
        return isSettled ? 33_000_000 : 8_000_000
    }

    /// Toggles whether the menu bar and Dock stay sharp. Drops the overlays
    /// below the system chrome so it keeps rendering on top and rebuilds the
    /// capture filters; the running capture loop picks the change up on its
    /// next pass.
    func setKeepChrome(_ on: Bool) {
        guard keepChrome != on else { return }
        keepChrome = on
        for (_, overlay) in overlays { overlay.setChromeClear(on) }
        capturer.invalidateFilters()
        settledFrames = 0
    }

    func setBlurRadius(_ radius: Double) {
        guard blurRadius != radius else { return }
        blurRadius = radius
        // Wakes the capture loop: a settled loop would otherwise take up to
        // 33ms to pick up the new radius.
        settledFrames = 0
    }

    func enable() {
        guard !enabled else { return }
        enabled = true
        if !capturer.hasPermission { capturer.requestPermission() }
        screenSignature = Self.currentScreenSignature()
        rebuildOverlays()
        refreshFocus()

        startDisplayLink()
        startCaptureLoop()

        // `CVDisplayLink` silently stops ticking when the display set changes
        // or the machine wakes, which would freeze the cutout at its last
        // position. There is no reconnect, so build a fresh one.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayChange() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayChange() }
        }
        startPowerObservers()
    }

    /// Watches for the states where capturing is pure waste: the machine is
    /// asleep, the screen is locked, or a screensaver is running.
    ///
    /// These only ever *add* pauses — if a notification never arrives, the
    /// existing "no focusable window ⇒ stop" path still catches the idle case,
    /// so a missed signal costs power, never correctness. Toggling the effect
    /// off and on always clears the pause.
    private func startPowerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForPower() }
        }
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFromPower() }
        }
        powerObservers.append((
            workspace,
            workspace.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main,
                using: pause
            )
        ))
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didStart"] {
            powerObservers.append((
                distributed,
                distributed.addObserver(
                    forName: NSNotification.Name(name),
                    object: nil,
                    queue: .main,
                    using: pause
                )
            ))
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didStop"] {
            powerObservers.append((
                distributed,
                distributed.addObserver(
                    forName: NSNotification.Name(name),
                    object: nil,
                    queue: .main,
                    using: resume
                )
            ))
        }
    }

    private func suspendForPower() {
        guard enabled else { return }
        powerPaused = true
        stopCaptureLoop()
    }

    private func resumeFromPower() {
        guard enabled, powerPaused else { return }
        powerPaused = false
        if focus != nil { startCaptureLoop() }
    }

    private func handleDisplayChange() {
        displayChangeTask?.cancel()
        displayChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.applyDisplayChange()
        }
    }

    private func applyDisplayChange() {
        guard enabled else { return }
        // Waking up also means the power pause can be lifted.
        resumeFromPower()
        // A burst of notifications for one event leaves the geometry
        // unchanged; rebuilding then would blank the screen for nothing. The
        // display link still gets a fresh instance, since a wake is exactly
        // the case where the old one has stopped ticking.
        let signature = Self.currentScreenSignature()
        if signature != screenSignature {
            screenSignature = signature
            rebuildOverlays(animate: false)
        }
        restartDisplayLink()
    }

    private static func currentScreenSignature() -> String {
        NSScreen.screens.map { screen in
            let id = screen.displayID ?? 0
            let frame = screen.frame
            return "\(id):\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
        }.joined(separator: "|")
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        generation += 1
        displayLink?.stop()
        displayLink = nil
        captureTask?.cancel()
        captureTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        displayChangeTask?.cancel()
        displayChangeTask = nil
        screenSignature = ""
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        blurDecisions.removeAll()
        lastCaptureNanos.removeAll()
        capturer.invalidateFilters()
        focus = nil
        settledFrames = 0
        framesWithoutFocus = 0
        powerPaused = false
        for observer in powerObservers { observer.center.removeObserver(observer.token) }
        powerObservers.removeAll()
    }

    // MARK: - Clock

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Driven by the display's own refresh signal, so the cutout gets
        // exactly one update per frame instead of the uneven bursts a Timer
        // produces as it drifts against the compositor.
        let link = DisplayLink { [weak self] in
            self?.displayLinkFired()
        }
        link.start()
        displayLink = link
    }

    private func restartDisplayLink() {
        displayLink?.stop()
        displayLink = nil
        guard enabled else { return }
        startDisplayLink()
    }

    /// One compositor frame: re-reads the focus and commits picture + cutout as
    /// a single unit.
    private func displayLinkFired() {
        guard enabled else { return }
        frameIndex = (frameIndex + 1) % 1_000_000
        refreshFocus()
        // With no focus the overlays are already blank and the capture loop is
        // stopped; there is nothing to update until a window comes back.
        guard focus != nil else { return }
        refreshBlurDecisions()
        for (id, overlay) in overlays {
            // A display the window has swallowed stops being *captured*, but
            // keeps the blur it already has: clearing it would flash the bare
            // desktop the moment the window shrank again, which is the one
            // thing this app must never do.
            overlay.commit(hole: localHole(for: id))
        }
    }

    private func refreshFocus() {
        if frameIndex % fullScanInterval != 0 {
            // Cheap path: the window we already track, re-read every frame.
            // This is what keeps a dragged window welded to the cutout.
            if let current = focus, let refreshed = FocusTracker.refresh(current) {
                update(with: refreshed)
            } else {
                // The tracked window just went away (closed, minimized, moved
                // to another Space). Start the grace period now instead of
                // waiting for the next full scan, or the cutout would sit on
                // top of a window that no longer exists.
                update(with: nil)
            }
            return
        }
        // A full scan is the only way to discover that the focus moved to a
        // different window, or that one appeared after there was none. It
        // enumerates every window on the desktop, so it runs on a subset of
        // frames and less often still once nothing is moving.
        update(with: FocusTracker.focusedWindow())
    }

    private func update(with candidate: FocusedWindow?) {
        guard enabled else { return }
        guard let candidate else {
            framesWithoutFocus += 1
            guard framesWithoutFocus >= Self.focusLossGraceFrames, focus != nil else { return }
            focus = nil
            settledFrames = 0
            // Decisions are recomputed only while a focus exists, so drop them
            // here: otherwise a display paused by a maximised window stays
            // paused when the next window appears, and the screen would sit
            // sharp for the whole confirmation delay.
            blurDecisions.removeAll()
            for (_, overlay) in overlays { overlay.clear() }
            // Nothing to blur means nothing to capture. An empty desktop, a
            // locked screen and a running screensaver all land here, and all
            // three leave the app at effectively zero cost until a window
            // comes back.
            stopCaptureLoop()
            return
        }
        framesWithoutFocus = 0
        if let old = focus, Self.isSameFocus(old, candidate) {
            settledFrames += 1
            return
        }
        // The focus moved to another display: the one that lost it has just
        // revealed a hole-shaped patch of stale picture, and must not be left
        // waiting on its low refresh rate to fix it.
        if let old = focus, old.displayID != candidate.displayID {
            lastCaptureNanos.removeAll()
        }
        focus = candidate
        settledFrames = 0
        if captureTask == nil { startCaptureLoop() }
    }

    /// Whether the focus is unchanged. Compared with a sub-point tolerance:
    /// some windows report bounds that jitter by a fraction of a point, and
    /// treating that as movement would keep the desktop from ever counting as
    /// settled — and so never let the throttling kick in.
    private static func isSameFocus(_ a: FocusedWindow, _ b: FocusedWindow) -> Bool {
        guard a.windowID == b.windowID, a.displayID == b.displayID else { return false }
        return abs(a.rect.origin.x - b.rect.origin.x) < 0.5 &&
               abs(a.rect.origin.y - b.rect.origin.y) < 0.5 &&
               abs(a.rect.width - b.rect.width) < 0.5 &&
               abs(a.rect.height - b.rect.height) < 0.5
    }

    // MARK: - Capture

    private func stopCaptureLoop() {
        captureTask?.cancel()
        captureTask = nil
    }

    private func startCaptureLoop() {
        guard enabled, !powerPaused else { return }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.captureOnce()
                try? await Task.sleep(nanoseconds: self.captureDelayNanos)
            }
        }
    }

    /// Re-screenshots every display and stages the blurred results. Skipped
    /// entirely when there is no focused window (nothing to blur).
    private func captureOnce() async {
        guard enabled, let focus else { return }
        let generation = self.generation
        let snapshot = focus
        let radius = blurRadius
        let keepChrome = keepChrome
        // A snapshot, because the loop below awaits and the dictionary must not
        // change underneath it — and so results are written to the overlays
        // this pass started with, not to whatever replaced them meanwhile.
        let targets = overlays

        let now = DispatchTime.now().uptimeNanoseconds
        for (id, overlay) in targets where shouldBlur(displayID: id) {
            let isFocused = snapshot.displayID == id
            // A display with no cutout is one flat blur: refreshing it a third
            // as often is invisible and saves a full capture-and-blur per tick.
            if !isFocused, let last = lastCaptureNanos[id],
               now - last < Self.secondaryDisplayIntervalNanos { continue }
            // Only the display holding the window needs it excluded; keeping
            // the other displays' filters free of it means a focus change never
            // forces their (expensive) rebuild either.
            let windowID = isFocused ? snapshot.windowID : nil
            guard let (image, scale) = await capturer.capture(
                displayID: id,
                focusWindowID: windowID,
                keepChrome: keepChrome
            ) else { continue }
            lastCaptureNanos[id] = DispatchTime.now().uptimeNanoseconds
            guard generation == self.generation, !Task.isCancelled else { return }

            let size = CGSize(width: image.width, height: image.height)
            let hole = inpaintingHole(snapshot: snapshot, displayID: id, imageSize: size, scale: scale)
            // Blur off the main thread: this is the single most expensive step
            // of the frame and must never stall the cutout.
            let blurred = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    BlurProcessor.blur(image: image, scale: scale, hole: hole, blurRadius: radius)
                }
            }.value
            // A pass started against a window that is no longer the focus is
            // stale. Without this check, closing the last window (or switching
            // to an empty Space) can land a picture after the overlays were
            // cleared, painting a hole-less blur over the whole screen with
            // nothing left to refresh it.
            guard generation == self.generation, !Task.isCancelled else { return }
            guard let blurred, self.focus?.windowID == snapshot.windowID else { continue }
            overlay.setPicture(blurred)
        }
    }

    // MARK: - Geometry

    /// The overlay-local hole in **points, top-left origin** — what
    /// `BlurOverlay.commit(hole:)` expects. `nil` when the focused window is not
    /// on `displayID`.
    private func localHole(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let focus, focus.displayID == displayID else { return nil }
        // `CGWindowList` coordinates and `CGDisplayBounds` share the same
        // top-left-origin space, so subtracting the display origin yields the
        // overlay-local rect directly.
        let bounds = CGDisplayBounds(displayID)
        return CGRect(
            x: focus.rect.origin.x - bounds.origin.x,
            y: focus.rect.origin.y - bounds.origin.y,
            width: focus.rect.width,
            height: focus.rect.height
        )
    }

    /// The rectangle `BlurProcessor` should paint over, in **image pixels,
    /// bottom-left origin**.
    ///
    /// It covers where the window was when the screenshot was taken *and* where
    /// it is now. The picture is shown a frame or two after it was captured, so
    /// only painting the old position would leave the window's newest pixels
    /// sitting just outside the cutout — a halo that changes shape with the
    /// drag speed, which is exactly what "flickering" looked like.
    private func inpaintingHole(
        snapshot: FocusedWindow,
        displayID: CGDirectDisplayID,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGRect? {
        // A window on another display has no meaningful rectangle in this
        // display's image: subtracting the wrong origin would place the patch
        // somewhere arbitrary on the secondary screen.
        guard snapshot.displayID == displayID || focus?.displayID == displayID else { return nil }

        var captured: CGRect?
        if snapshot.displayID == displayID {
            captured = pixelHole(rect: snapshot.rect, displayID: displayID, imageSize: imageSize, scale: scale)
        }
        var current: CGRect?
        if let latest = focus, latest.displayID == displayID {
            current = pixelHole(rect: latest.rect, displayID: displayID, imageSize: imageSize, scale: scale)
        }
        switch (captured, current) {
        case (let a?, let b?): return a.union(b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    private func pixelHole(
        rect: CGRect,
        displayID: CGDirectDisplayID,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGRect? {
        let bounds = CGDisplayBounds(displayID)
        let left = (rect.minX - bounds.minX) * scale
        let right = (rect.maxX - bounds.minX) * scale
        let top = (rect.minY - bounds.minY) * scale
        let bottom = (rect.maxY - bounds.minY) * scale
        // The window server reports top-left origins; Core Image puts the
        // origin at the bottom-left, so the vertical axis has to be flipped.
        return CGRect(x: left, y: imageSize.height - bottom, width: right - left, height: bottom - top)
    }

    // MARK: - Screens

    /// (Re)builds one overlay per screen. Also called when the display
    /// arrangement changes, since a stale `NSScreen.frame` would leave the blur
    /// covering the wrong rectangle.
    private func rebuildOverlays(animate: Bool = true) {
        generation += 1
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        blurDecisions.removeAll()
        lastCaptureNanos.removeAll()
        capturer.invalidateFilters()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let overlay = BlurOverlay(screen: screen, animateAppearance: animate)
            overlay.setChromeClear(keepChrome)
            overlays[id] = overlay
        }
        settledFrames = 0
    }
}
