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
    /// When the current `captureOnce` pass started, or 0 when none is running.
    ///
    /// Guards against two `captureOnce` passes overlapping: `stopCaptureLoop`
    /// cancels without waiting, so a pass still inside `ScreenCapturer` when the
    /// loop restarts would interleave with the next one — two rebuilds racing to
    /// store their filter, and a frame excluded against the wrong window.
    ///
    /// A deadline rather than a plain flag on purpose. The `await`s inside a
    /// pass are only ever released by ScreenCaptureKit, and there are states
    /// where it never does: permission revoked mid-capture is the ordinary one.
    /// A flag nobody could clear would then hold the latch down for the rest of
    /// the session — every frame dropped at the first guard, the picture frozen,
    /// and toggling the effect off and on no help at all, because neither path
    /// touched the flag. Expiring instead turns a permanent hang into one bad
    /// frame and one risky overlap, and only after nothing has come back for
    /// far longer than a whole pass takes even at full size.
    private var captureStartedAt: TimeInterval = 0
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var displaysWokeObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// Last tick the display link delivered, so a clock that stopped ticking
    /// can be told apart from one that is merely quiet. See `checkClock()`.
    private var lastTickNanos: UInt64 = 0
    /// The independent check for exactly that. The clock cannot police itself:
    /// everything else in the app *is* the clock, so a link that stopped leaves
    /// nothing running to notice. One timer, once a second.
    private var clockTimer: Timer?
    /// Debounced rebuild of the overlays after a display change. Those
    /// notifications arrive in bursts — a single resolution animation fires
    /// several — and each one used to tear down and rebuild every overlay
    /// window, blanking the screen each time.
    private var displayChangeTask: Task<Void, Never>?
    /// Geometry of the display arrangement the overlays were last built for.
    private var screenSignature = ""
    /// The delayed "Screen Recording is not granted" warning, kept so that
    /// toggling the effect off cancels it instead of leaving it to appear over a
    /// session that no longer exists.
    private var permissionWarnTask: Task<Void, Never>?
    /// The permission sheet while it is up, so it outlives neither its own
    /// dismissal nor the session it belongs to.
    private var permissionAlert: NSAlert?

    private var enabled = false
    private var blurRadius: Double = 20
    /// When true, the menu bar and the Dock are kept sharp (excluded from the
    /// blurred picture) instead of being blurred with everything else. On by
    /// default: they are the two things you reach for while the effect is
    /// running, and blurring them buys no privacy.
    private var keepChrome = true
    /// Drop the blur on a display whose focused window is full-screen.
    private var pauseForFullScreenApps = true
    /// Set while the machine is asleep, locked or running a screensaver.
    private var powerPaused = false
    /// When the pause started, so a session that never receives its resume
    /// notification cannot stay paused indefinitely.
    private var powerPausedAt: TimeInterval = 0
    /// Last time each display was captured, so secondary displays — which show
    /// a featureless full-screen blur — can be refreshed far less often than
    /// the one with the cutout.
    private var lastCaptureNanos: [CGDirectDisplayID: UInt64] = [:]
    /// Which displays the focused window sat on last pass. See `captureOnce`.
    private var lastCoveredDisplays: Set<CGDirectDisplayID> = []
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
        if focus == nil { return 6 }
        return isSettled ? 4 : 3
    }
    /// Grace period before believing "there is no focusable window": a Space
    /// switch empties the window list for the length of its animation, and
    /// clearing the overlay on each of those flickers the whole screen back to
    /// sharp.
    private static let focusLossGraceFrames = 15
    /// Frames that must pass before the desktop counts as settled.
    private static let settledThreshold = 45
    /// Frames of stillness after which the desktop is treated as idle and
    /// capture drops to a trickle. ~15s at 60fps.
    private static let idleThreshold = 900
    /// Refresh period for displays that show a full-screen blur with no cutout.
    /// Their content is unreadable by definition, so ~15fps is indistinguishable
    /// from 60fps and costs a quarter as much.
    private static let secondaryDisplayIntervalNanos: UInt64 = 66_000_000
    /// Capture period once the desktop has been idle for `idleThreshold` frames.
    /// Nothing has moved for a quarter of a minute, so the background is a
    /// static blur; re-shooting it four times a second is already more than
    /// anyone can see. This is the difference between a menu bar utility that
    /// costs nothing and one that keeps the GPU awake all day.
    private static let idleDelayNanos: UInt64 = 250_000_000
    /// Smallest overlap (points) that counts as a window sitting on a display.
    /// A sub-point sliver does not: treating it as coverage would rebuild that
    /// display's expensive shareable-content filter every time an edge jitters
    /// across the boundary.
    private static let minimumCoverage: CGFloat = 2
    /// Overlap (points) below which a display stops counting as covered by the
    /// window — the release edge against `minimumCoverage`'s trigger.
    private static let releaseCoverage: CGFloat = 0.5
    /// Longest the power pause may last before a focused window is allowed to
    /// lift it anyway. The pause exists to save power, so it must never become
    /// a state the app cannot leave: if both the wake and the unlock
    /// notifications were missed, this lets it recover on its own.
    private static let maxPowerPause: TimeInterval = 10
    /// Longest a `captureOnce` pass may run before the next one is allowed to
    /// start anyway. A healthy pass finishes in well under a second even with
    /// several 5K displays to get through, so one still running after five will
    /// not be coming back.
    private static let captureStallLimit: TimeInterval = 5
    /// Silence after which the display link counts as dead. See `checkClock()`.
    private static let clockStallLimitNanos: UInt64 = 1_000_000_000

    var isEnabled: Bool { enabled }
    var currentBlurRadius: Double { blurRadius }
    var keepsChromeClear: Bool { keepChrome }
    var pausesForFullScreenApps: Bool { pauseForFullScreenApps }

    // MARK: - Persistence
    /// Settings are remembered across launches via `UserDefaults`, so the chosen
    /// blur strength, chrome handling, full-screen pause and the on/off state
    /// itself survive a quit.
    private enum SettingsKey {
        static let blurRadius = "blurRadius"
        static let keepChrome = "keepChrome"
        static let pauseFullScreen = "pauseFullScreen"
        static let enabled = "enabled"
    }

    /// Loads any previously saved settings. Called once at launch, before the
    /// status-bar menu is built, so the menu reflects the last choices. If the
    /// effect was on when the app last ran it is resumed here.
    func restoreSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKey.blurRadius) != nil {
            blurRadius = min(max(defaults.double(forKey: SettingsKey.blurRadius), 10), 40)
        }
        if defaults.object(forKey: SettingsKey.keepChrome) != nil {
            keepChrome = defaults.bool(forKey: SettingsKey.keepChrome)
        }
        if defaults.object(forKey: SettingsKey.pauseFullScreen) != nil {
            pauseForFullScreenApps = defaults.bool(forKey: SettingsKey.pauseFullScreen)
        }
        // Auto-resume the effect if it was on at quit. The on/off flag is
        // persisted from the menu toggle only, never from the quit/terminate
        // teardown, so quitting while blurred keeps it blurred next launch
        // instead of being reset to off by `disable()`.
        if defaults.bool(forKey: SettingsKey.enabled) {
            enable()
        }
    }

    /// Records the current on/off state so it survives a quit. Called from the
    /// menu toggle — not from the teardown at quit, which must not overwrite a
    /// "was on" value.
    func persistEnabled() {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.enabled)
    }

    /// Turns the full-screen rule on or off.
    func setPauseForFullScreenApps(_ on: Bool) {
        guard pauseForFullScreenApps != on else { return }
        pauseForFullScreenApps = on
        UserDefaults.standard.set(on, forKey: SettingsKey.pauseFullScreen)
        settledFrames = 0
    }

    /// Whether `displayID` is worth blurring right now.
    ///
    /// It is not when the focused window covers the display edge to edge. A
    /// full-screen app leaves nothing behind it to hide, and blurring the
    /// display anyway means capturing and blurring a screen whose entire
    /// content is already the focused window.
    ///
    /// Note this is a statement about *the window*, not about a percentage: a
    /// window that covers 90% of the display still leaves a strip of real
    /// desktop showing, and that strip is exactly what this app exists to
    /// hide.
    private func shouldBlur(displayID: CGDirectDisplayID) -> Bool {
        guard pauseForFullScreenApps, let focus else { return true }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let visible = focus.rect.intersection(bounds)
        guard !visible.isNull else { return true }
        return visible.width < bounds.width - 1 || visible.height < bounds.height - 1
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
        if settledFrames >= Self.idleThreshold { return Self.idleDelayNanos }
        return isSettled ? 33_000_000 : 8_000_000
    }

    /// Toggles whether the menu bar and Dock stay sharp. Drops the overlays
    /// below the system chrome so it keeps rendering on top and rebuilds the
    /// capture filters; the running capture loop picks the change up on its
    /// next pass.
    func setKeepChrome(_ on: Bool) {
        guard keepChrome != on else { return }
        keepChrome = on
        UserDefaults.standard.set(on, forKey: SettingsKey.keepChrome)
        for (_, overlay) in overlays { overlay.setChromeClear(on) }
        capturer.invalidateFilters()
        settledFrames = 0
    }

    func setBlurRadius(_ radius: Double) {
        guard blurRadius != radius else { return }
        blurRadius = radius
        UserDefaults.standard.set(radius, forKey: SettingsKey.blurRadius)
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
        startClockMonitor()
        startCaptureLoop()
        // If Screen Recording was never granted, the effect is silently dead.
        // Give the user a pointer to where it lives once the TCC prompt has
        // settled, rather than leaving the menu item looking broken.
        permissionWarnTask?.cancel()
        permissionWarnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.enabled, !capturer.hasPermission else { return }
            self.warnNoScreenRecordingPermission()
        }

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
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wake: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayChange() }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main,
            using: wake
        )
        // Both wake routes have to be watched, because they are different
        // events. `didWake` is the *machine* coming back; displays that slept on
        // their own — the energy saver turning panels off, `pmset displaysleep`,
        // a lid timer with an external display attached — announce their own
        // return with `screensDidWake` and nothing else. Display-only sleep was
        // therefore the hole in this: no notification arrived, the link was
        // still the dead one, and the picture sat frozen on its last frame with
        // the menu reporting the effect as happily running.
        displaysWokeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main,
            using: wake
        )
        startPowerObservers()

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        }
    }

    /// A Space switch — which is what entering or leaving full-screen is —
    /// invalidates everything the overlays are showing at once.
    ///
    /// The overlays are `.canJoinAllSpaces`, so they follow you into the new
    /// Space carrying the old Space's picture and cutout. Without this, a
    /// full-screen app can come up underneath a blur cut for a window that is
    /// no longer there. Dropping the focus as well means the cutout is rebuilt
    /// from whichever window the new Space actually has rather than fading out
    /// over the 15-frame grace period.
    private func handleSpaceChange() {
        guard enabled else { return }
        // Invalidate any in-flight capture so a result computed against the old
        // Space cannot land on the new one — same discipline as `rebuildOverlays`.
        generation += 1
        // Empty rather than freeze: the picture belongs to the Space we just
        // left, and showing it under a cutout cut for the new Space would put
        // the old Space's content on screen.
        for (_, overlay) in overlays { overlay.clear() }
        lastCaptureNanos.removeAll()
        lastCoveredDisplays.removeAll()
        capturer.invalidateFilters()
        focus = nil
        framesWithoutFocus = 0
        settledFrames = 0
        stopCaptureLoop()
        // The display link is tied to the display set; a Space switch is as
        // good a moment as any to make sure it is still ticking.
        restartDisplayLink()
        refreshFocus()
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
        powerPausedAt = Date.timeIntervalSinceReferenceDate
        stopCaptureLoop()
    }

    private func resumeFromPower() {
        guard enabled, powerPaused else { return }
        powerPaused = false
        if focus != nil { startCaptureLoop() }
    }

    /// Tells the user that nothing will blur until Screen Recording is granted.
    /// Opened from the "effect is on but doesn't work" dead end, so it goes
    /// straight to the right pane of System Settings.
    ///
    /// Presented as a **sheet on one of our own windows**, not with
    /// `runModal()`. A modal run loop owns the main thread for as long as the
    /// alert is up: display-link ticks, captures and menu actions all queue up
    /// behind it — including the very "然后重新打开效果" the alert asks the user
    /// to perform, which lives in the menu. This app has no ordinary window of
    /// its own, so the overlay it is already showing is what hosts the sheet:
    /// above the blur it is explaining, and visible by construction.
    private func warnNoScreenRecordingPermission() {
        guard !capturer.hasPermission else { return }
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "隐私模糊通过截图来实现。请在「系统设置 › 隐私与安全性 › 屏幕录制」中打开「PrivacyWindow」，然后重新打开效果。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        permissionAlert = alert
        // Prefer the display the user is looking at, which is where the
        // explanation belongs.
        let host = focus.flatMap { overlays[$0.displayID] }?.window ?? overlays.values.first?.window
        guard let host else {
            // Nothing of ours is on screen, so there is no blur to explain and
            // no window to hang a sheet off — and blocking the main actor to say
            // so would be the failure this avoids.
            permissionAlert = nil
            return
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            self?.permissionAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
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

    /// Whether the login session is currently locked (lock screen or screen
    /// saver lock). The lock screen paints its own window, which `update(with:)`
    /// would otherwise read as "a window came into focus" and use to lift the
    /// power pause early — leaving the effect capturing (and blurring) the lock
    /// screen instead of staying parked. A missed `screenIsLocked` signal is
    /// harmless here because the matching `screenIsUnlocked` / "didStop" signal
    /// still resumes normally on unlock.
    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        generation += 1
        displayLink?.stop()
        displayLink = nil
        captureTask?.cancel()
        captureTask = nil
        permissionWarnTask?.cancel()
        permissionWarnTask = nil
        // An effect that got switched off takes its explanation with it,
        // otherwise the sheet would sit over a session that no longer exists.
        if let sheet = permissionAlert?.window {
            sheet.sheetParent?.endSheet(sheet)
        }
        permissionAlert = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let displaysWokeObserver { NSWorkspace.shared.notificationCenter.removeObserver(displaysWokeObserver) }
        displaysWokeObserver = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        clockTimer?.invalidate()
        clockTimer = nil
        displayChangeTask?.cancel()
        displayChangeTask = nil
        screenSignature = ""
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        lastCaptureNanos.removeAll()
        lastCoveredDisplays.removeAll()
        capturer.invalidateFilters()
        focus = nil
        settledFrames = 0
        framesWithoutFocus = 0
        powerPaused = false
        // A session that ended takes its capture lease with it: nothing is in
        // flight any more, and the interval started by enable() must not look
        // like a pass that has been running for minutes.
        captureStartedAt = 0
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
        // A brand new link owes us nothing yet, so the deadline for its first
        // tick starts now — otherwise a link that never ticked once, right from
        // construction, would look indistinguishable from a fresh one.
        lastTickNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Watches the clock from the outside, because nothing inside the app can.
    ///
    /// A stopped `CVDisplayLink` is the worst failure this app has: the picture
    /// freezes on whatever was last committed, nothing changes, and the menu
    /// still says the effect is on — a state that looks exactly like working,
    /// and that nothing else ever questions, since the display link *is* the
    /// scheduled work. Wakes and display changes are covered by their
    /// notifications, but nobody can enumerate the reasons a link may die, so
    /// those are belt and this is braces.
    ///
    /// Deliberately does the least it can: it replaces the link and nothing
    /// else, leaving the overlays, filters and capture loop of the running
    /// session alone.
    private func startClockMonitor() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClock() }
        }
        // `.common` so a menu being held open does not stop the check.
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func checkClock() {
        // Not gated on having a focus: with none, nothing else in the app is
        // running either, and a dead clock then means the arrival of a window is
        // never noticed at all — the effect stays off while the menu says it is
        // on, with no evidence either way.
        guard enabled, !powerPaused, !Self.isScreenLocked() else { return }
        // Every display carrying an overlay is asleep, so there was nothing to
        // draw and nothing to repair. Checking this is what keeps a sleeping
        // machine from having its display link rebuilt once a second all night.
        guard overlays.keys.contains(where: { CGDisplayIsAsleep($0) == 0 }) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // A live link ticks sixty times a second even when every frame decides
        // there is nothing to do, so a full second of silence is not quiet — it
        // is death.
        guard now - lastTickNanos > Self.clockStallLimitNanos else { return }
        lastTickNanos = now
        restartDisplayLink()
        // Whatever each display is holding was stale when the clock stopped;
        // the throttles have no idea how long ago that was.
        lastCaptureNanos.removeAll()
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
        lastTickNanos = DispatchTime.now().uptimeNanoseconds
        frameIndex = (frameIndex + 1) % 1_000_000
        refreshFocus()
        // With no focus the overlays are already blank and the capture loop is
        // stopped; there is nothing to update until a window comes back.
        guard focus != nil else { return }
        for (id, overlay) in overlays {
            // A display the window has swallowed stops being *captured*, but
            // keeps the blur it is already showing. Emptying it instead would
            // flash the bare desktop — real, readable pixels — for the few
            // frames it takes to start capturing again.
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
        // A window coming into focus is itself proof the screen is awake and
        // unlocked — the one case where a missed `screenIsUnlocked`/
        // `screensaver.didStop` notification would otherwise leave capture
        // paused forever. The lock screen paints its own window, though, so
        // exclude that case: capturing the lock screen is pure waste, and the
        // dedicated unlock signal still resumes normally. The `maxPowerPause`
        // escape keeps a missed signal from parking the app for good.
        if candidate != nil, powerPaused,
           !Self.isScreenLocked() || Date.timeIntervalSinceReferenceDate - powerPausedAt > Self.maxPowerPause {
            resumeFromPower()
        }
        guard let candidate else {
            framesWithoutFocus += 1
            guard framesWithoutFocus >= Self.focusLossGraceFrames, focus != nil else { return }
            focus = nil
            settledFrames = 0
            // Decisions are recomputed only while a focus exists, so drop them
            // here: otherwise a display paused by a maximised window stays
            // paused when the next window appears, and the screen would sit
            // sharp for the whole confirmation delay.
            for (_, overlay) in overlays { overlay.clear() }
            // Nothing to blur means nothing to capture. An empty desktop, a
            // locked screen and a running screensaver all land here, and all
            // three leave the app at effectively zero cost until a window
            // comes back.
            stopCaptureLoop()
            return
        }
        framesWithoutFocus = 0
        // Checked before the early return below: capturing is stopped whenever
        // nothing is focused, and "the focus is unchanged" must not leave the
        // loop dead after a Space switch or a power pause.
        if captureTask == nil { startCaptureLoop() }
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
        // Start the exclusion rebuild now rather than inside the capture pass:
        // the filter has to stop excluding the previous window and start
        // excluding this one, which means enumerating every window on the
        // desktop, and doing that in the middle of `captureOnce` puts the whole
        // enumeration in front of this frame's picture.
        capturer.prepare(
            displayID: candidate.displayID,
            focusWindowID: candidate.windowID,
            keepChrome: keepChrome
        )
    }

    /// Whether the focus is unchanged. Compared with a sub-point tolerance:
    /// some windows report bounds that jitter by a fraction of a point, and
    /// treating that as movement would keep the desktop from ever counting as
    /// settled — and so never let the throttling kick in.
    ///
    /// `displayID` is deliberately not part of the comparison. It is derived
    /// from which display the window overlaps most, so a window straddling two
    /// displays can have it flip on that same sub-point jitter; counting each
    /// flip as a change would hold `settledFrames` at zero forever.
    private static func isSameFocus(_ a: FocusedWindow, _ b: FocusedWindow) -> Bool {
        guard a.windowID == b.windowID else { return false }
        return abs(a.rect.origin.x - b.rect.origin.x) < 0.5 &&
               abs(a.rect.origin.y - b.rect.origin.y) < 0.5 &&
               abs(a.rect.width - b.rect.width) < 0.5 &&
               abs(a.rect.height - b.rect.height) < 0.5
    }

    /// Which of `displays` the window is really sitting on.
    ///
    /// Membership has hysteresis: a display joins on `minimumCoverage` and leaves
    /// only once the overlap has fallen below `releaseCoverage`. Both edges cost
    /// real work — membership decides whether the window is excluded from that
    /// display's filter, so flipping rebuilds it — and a rectangle whose edge
    /// sits exactly on a display boundary can cross `minimumCoverage` and back
    /// every single frame, which would turn a resting desktop into a per-frame
    /// rebuild of every shareable-content snapshot.
    private func coveredDisplays(for rect: CGRect, among displays: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
        var covered = Set(displays.filter { Self.covers(rect, on: $0) })
        for id in displays where lastCoveredDisplays.contains(id) && Self.touches(rect, on: id) {
            covered.insert(id)
        }
        return covered
    }

    /// Whether the window is leaning on this display at all — the release edge of
    /// the hysteresis above.
    static func touches(_ rect: CGRect, in bounds: CGRect) -> Bool {
        let part = rect.intersection(bounds)
        return part.width >= Self.releaseCoverage && part.height >= Self.releaseCoverage
    }

    /// Whether `rect` really sits on `displayID`, rather than just clipping it.
    static func covers(_ rect: CGRect, on displayID: CGDirectDisplayID) -> Bool {
        covers(rect, in: CGDisplayBounds(displayID))
    }

    static func touches(_ rect: CGRect, on displayID: CGDirectDisplayID) -> Bool {
        touches(rect, in: CGDisplayBounds(displayID))
    }

    /// The pure form, so the threshold can be checked without a display.
    static func covers(_ rect: CGRect, in bounds: CGRect) -> Bool {
        let part = rect.intersection(bounds)
        return part.width >= Self.minimumCoverage && part.height >= Self.minimumCoverage
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
        let startTime = Date.timeIntervalSinceReferenceDate
        guard captureStartedAt == 0 || startTime - captureStartedAt > Self.captureStallLimit else { return }
        captureStartedAt = startTime
        defer { captureStartedAt = 0 }

        let generation = self.generation
        let snapshot = focus
        let radius = blurRadius
        let keepChrome = keepChrome
        // A snapshot, because the loop below awaits and the dictionary must not
        // change underneath it — and so results are written to the overlays
        // this pass started with, not to whatever replaced them meanwhile.
        let targets = overlays

        // Which displays the window actually sits on. When that set changes —
        // the window reaching onto a second display, or leaving one — the
        // displays involved are holding a picture that no longer matches the
        // cutout, so their throttling has to be dropped or the seam shows a
        // stale strip for up to a refresh period.
        let covered = coveredDisplays(for: snapshot.rect, among: Set(targets.keys))
        if covered != lastCoveredDisplays {
            let rejoinedOrLeft = covered.symmetricDifference(lastCoveredDisplays)
            lastCoveredDisplays = covered
            // Only the displays that joined or left have a stale relationship to
            // the window. Clearing every throttle instead meant that a window
            // parked with its edge on a display boundary — which is where snapped
            // and maximised windows live, and where their rectangles jitter by
            // fractions of a point — put *every* display back at full rate on
            // every one of those flips: a CPU spike and a visible refresh pattern
            // on secondary displays, for nothing.
            for id in rejoinedOrLeft { lastCaptureNanos.removeValue(forKey: id) }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        // The display holding the window goes first: its picture is the one
        // that has to keep up with the drag. Capturing in display order instead
        // would put a secondary display's capture ahead of it, adding that
        // capture's whole latency to the drag the user is watching.
        let ordered = targets.sorted { lhs, rhs in
            Self.covers(snapshot.rect, on: lhs.key) && !Self.covers(snapshot.rect, on: rhs.key)
        }

        for (id, overlay) in ordered where shouldBlur(displayID: id) {
            // A display that has gone to sleep has nothing worth showing.
            // (`CGDisplayIsAsleep` answers a C `boolean_t`, not a `Bool`.)
            guard CGDisplayIsAsleep(id) == 0 else { continue }
            let isFocused = covered.contains(id)
            // A display with no cutout is one flat blur: refreshing it a
            // quarter as often is invisible and saves a full capture-and-blur
            // per tick.
            if !isFocused, let last = lastCaptureNanos[id],
               now - last < Self.secondaryDisplayIntervalNanos { continue }
            // Only a display the window sits on needs it excluded; keeping the
            // others' filters free of it means a focus change never forces their
            // (expensive) rebuild either.
            let windowID = isFocused ? snapshot.windowID : nil
            guard let (image, scale) = await capturer.capture(
                displayID: id,
                focusWindowID: windowID,
                keepChrome: keepChrome
            ) else { continue }
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
            // Only a picture that was actually shown refreshes the throttle.
            // Timing a discarded one would push the next refresh out by a full
            // period for a display that is still holding the old frame.
            lastCaptureNanos[id] = DispatchTime.now().uptimeNanoseconds
        }
    }

    // MARK: - Geometry

    /// The overlay-local hole in **points, top-left origin** — what
    /// `BlurOverlay.commit(hole:)` expects. `nil` when the focused window is not
    /// on `displayID`.
    private func localHole(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let focus else { return nil }
        // `CGWindowList` coordinates and `CGDisplayBounds` share the same
        // top-left-origin space, so subtracting the display origin yields the
        // overlay-local rect directly. Clamp to the display: a window spanning
        // two displays only shows the part that actually sits on this one, so
        // the cutout on the other display must not reach past its edge.
        let bounds = CGDisplayBounds(displayID)
        let local = CGRect(
            x: focus.rect.origin.x - bounds.origin.x,
            y: focus.rect.origin.y - bounds.origin.y,
            width: focus.rect.width,
            height: focus.rect.height
        )
        let visible = local.intersection(CGRect(origin: .zero, size: bounds.size))
        guard !visible.isNull else { return nil }
        return visible
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
        // display's image — but a window that *spans* displays does, for every
        // display it covers. Gate on the geometry rather than on the single
        // `displayID` the tracker reported for the window's largest overlap.
        guard snapshot.rect.intersects(CGDisplayBounds(displayID)) else { return nil }

        // Painting over is cheap and a missed patch is a visible halo, so this
        // uses the plain geometric test rather than `covers`' minimum: even a
        // sliver of the window on this display gets inpainted.
        let captured = pixelHole(rect: snapshot.rect, displayID: displayID, imageSize: imageSize, scale: scale)
        var current: CGRect?
        if let latest = focus, latest.rect.intersects(CGDisplayBounds(displayID)) {
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
        lastCaptureNanos.removeAll()
        lastCoveredDisplays.removeAll()
        capturer.invalidateFilters()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let overlay = BlurOverlay(screen: screen, animateAppearance: animate)
            overlay.setChromeClear(keepChrome)
            overlays[id] = overlay
        }
        settledFrames = 0
    }

    // Deliberately no `deinit`. A `deinit` cannot clean this up: it runs with
    // the object already being destroyed, so a `[weak self]` captured in a Task
    // spawned from it is always nil, and the task would run after the teardown
    // anyway. `AppDelegate.applicationWillTerminate` is what actually calls
    // `disable()`, and it covers quitting however it happens.
}
