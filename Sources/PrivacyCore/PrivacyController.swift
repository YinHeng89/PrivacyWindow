import AppKit
import Combine
import CoreGraphics

/// Drives the privacy blur: one overlay per screen, a display-linked cutout and
/// a background capture loop.
///
/// Also the single source of truth for every setting, and therefore an
/// `ObservableObject`: the settings window binds straight to it, so a change made
/// in the menu shows up in the window and vice versa. The alternative — a second
/// "settings model" mirroring this state — is how the two drift apart.
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
final class PrivacyController: ObservableObject {
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
    /// When the session last switched to the captured backend mid-run, while
    /// its first captured frame was still outstanding. The restart hint lives
    /// on this: a grant picked up mid-run is the one state where the effect
    /// looks armed but macOS will never let it draw. See `checkRestartHint`.
    private var backendSwitchedAwaitingFirstFrame: Date?
    private var hasDeliveredFrameSinceBackendSwitch = false
    private var captureAttemptsSinceBackendSwitch = 0

    private var enabled = false
    /// Which blur backend this session runs on.
    ///
    /// Picked when the session starts: with Screen Recording granted the blur
    /// is computed from captured pixels (`ScreenCapturer` + `BlurProcessor`),
    /// which is the precise, radius-tunable mode. Without it, the overlays run
    /// on the compositor's own blur (`NSVisualEffectView`), which needs no
    /// permission at all — so the app is never dead just because a permission
    /// was declined, and the power-saving side of that mode is a bonus.
    ///
    /// The two share everything downstream of the picture: the reveal set, the
    /// even-odd mask, the union rule, the window level. Only the backdrop
    /// differs.
    private var usesVibrancy = false
    private var blurRadius: Double = 20
    /// When true, the menu bar and the Dock are kept sharp (excluded from the
    /// blurred picture) instead of being blurred with everything else. On by
    /// default: they are the two things you reach for while the effect is
    /// running, and blurring them buys no privacy.
    private var keepChrome = true
    /// Keep a disc of the screen sharp around the cursor, so the pointer's own
    /// surroundings stay readable without turning the effect off. Off by
    /// default: a circle appearing under someone's pointer is a surprise to
    /// anyone who never asked for it, and surprising people with liability
    /// is the one thing this app must not do.
    private var cursorReveal = false
    /// Radius (points) of that disc. Deliberately generous for something meant
    /// to be looked *at*: enough that what the pointer is approaching is legible
    /// before it arrives.
    private var cursorRevealRadius: Double = 120
    private var pauseForFullScreenApps = true
    /// Apps the whole effect stands down for. While one of these is frontmost
    /// the desktop stays sharp everywhere — the same state as "no focused
    /// window", because the user has said this app has nothing to hide.
    private(set) var excludedApps = ExcludedApps()
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
    /// Where the pointer was when the current frame started, in the global
    /// top-left space. Sampled once per frame — see `displayLinkFired`.
    private var cursorPoint: CGPoint?
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
    /// Bounds the cursor disc, in points. Anything tighter than the lower bound
    /// is a dot rather than something to read through; the upper one keeps a
    /// menu choice from covering a display end to end and quietly disabling the
    /// app.
    private static let smallestCursorRevealRadius: Double = 20
    private static let largestCursorRevealRadius: Double = 400
    /// Silence after which the display link counts as dead. See `checkClock()`.
    private static let clockStallLimitNanos: UInt64 = 1_000_000_000

    var isEnabled: Bool { enabled }
    var currentBlurRadius: Double { blurRadius }
    var keepsChromeClear: Bool { keepChrome }
    var pausesForFullScreenApps: Bool { pauseForFullScreenApps }
    var revealsCursor: Bool { cursorReveal }
    var currentCursorRevealRadius: Double { cursorRevealRadius }

    /// Fired on every enable/disable flip, from whichever surface caused it —
    /// the menu, the settings window's master switch, a quit.
    ///
    /// The single outlet for the on/off state. Everything that *shows* the
    /// state subscribes here instead of patching its own reflection after each
    /// action it takes, because a patch-after-action is only correct for the
    /// surface the action came from: toggling in the settings window used to
    /// leave a menu that had already been built showing the old title, and
    /// nothing at all updating the menu bar icon. The other settings do not
    /// need this — the menu is rebuilt from scratch on every open — but the
    /// on/off flip is the one that changes while a menu is open and while the
    /// icon is staring at you.
    var onEnabledChanged: ((Bool) -> Void)?

    /// Whether macOS has granted Screen Recording. Read live rather than cached:
    /// the user revokes and re-grants it while we are running, and a settings
    /// window that insists everything is fine while nothing blurs is worse than
    /// no settings window at all.
    var hasScreenRecordingPermission: Bool { capturer.hasPermission }
    /// Whether the running session is on the system-blur fallback rather than
    /// on captured pixels. The settings window uses it to describe the mode
    /// honestly — the strength slider does not mean the same thing in both.
    var runsOnVibrancyFallback: Bool { enabled && usesVibrancy }

    /// Blur radius bounds, in points. Beyond the upper bound the blur has eaten
    /// the screen entirely and every extra step only costs pixels and CPU; below
    /// the lower one it reads as a smudge rather than privacy.
    static let smallestBlurRadius: Double = 5
    static let largestBlurRadius: Double = 60

    // MARK: - Persistence
    /// Settings are remembered across launches via `UserDefaults`, so the chosen
    /// blur strength, chrome handling, full-screen pause and the on/off state
    /// itself survive a quit.
    private enum SettingsKey {
        static let blurRadius = "blurRadius"
        static let keepChrome = "keepChrome"
        static let pauseFullScreen = "pauseFullScreen"
        static let enabled = "enabled"
        static let revealCursor = "revealCursor"
        static let cursorRevealRadius = "cursorRevealRadius"
        static let excludedApps = "excludedApps"
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
        // The one setting that is off until asked for.
        if defaults.object(forKey: SettingsKey.revealCursor) != nil {
            cursorReveal = defaults.bool(forKey: SettingsKey.revealCursor)
        }
        if defaults.object(forKey: SettingsKey.cursorRevealRadius) != nil {
            cursorRevealRadius = clampedCursorRevealRadius(
                defaults.double(forKey: SettingsKey.cursorRevealRadius)
            )
        }
        if let saved = defaults.stringArray(forKey: SettingsKey.excludedApps) {
            excludedApps = ExcludedApps(saved)
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
        objectWillChange.send()
        pauseForFullScreenApps = on
        UserDefaults.standard.set(on, forKey: SettingsKey.pauseFullScreen)
        settledFrames = 0
    }

    // MARK: Excluded apps

    /// Adds an app to the exclusion list and persists it. The effect reacts on
    /// its next focus pass — at most a frame or two later — so no rebuild is
    /// needed here.
    func addExcludedApp(bundleID: String) {
        guard !excludedApps.contains(bundleID) else { return }
        objectWillChange.send()
        excludedApps.insert(bundleID)
        saveExcludedApps()
        settledFrames = 0
    }

    /// Removes an app from the exclusion list and persists it.
    func removeExcludedApp(bundleID: String) {
        guard excludedApps.contains(bundleID) else { return }
        objectWillChange.send()
        excludedApps.remove(bundleID)
        saveExcludedApps()
        settledFrames = 0
    }

    private func saveExcludedApps() {
        UserDefaults.standard.set(Array(excludedApps.bundleIDs), forKey: SettingsKey.excludedApps)
    }

    /// Windows belonging to excluded apps, in global top-left coordinates.
    ///
    /// Excluding an app does **not** pause the effect while it is in front. It
    /// means this app's windows are never blurred, focused or not: switch from
    /// WeChat to another window and WeChat stays sharp *and* the newly focused
    /// window is sharp, with everything else still blurred.
    private var excludedWindows: [SharpWindow] = []
    /// Rebuilt every few frames, not every frame — see `refreshExcludedWindows`.
    private static let excludedRefreshInterval = 6

    private func refreshExcludedWindows() {
        guard !excludedApps.isEmpty else {
            excludedWindows = []
            return
        }
        // The window list walk is the expensive part, and an excluded app's
        // windows only move as fast as someone can drag them. Keeping the last
        // result in between is invisible at six refreshes a second.
        guard frameIndex % Self.excludedRefreshInterval == 0 || excludedWindows.isEmpty else { return }
        excludedWindows = Self.windows(of: excludedApps.bundleIDs)
    }

    /// On-screen windows owned by any of `bundleIDs`, in the global top-left
    /// space the rest of the app speaks.
    ///
    /// Each returned window carries the windows stacked *in front* of it
    /// (`coveredBy`): the list walks front-to-back, so whatever has already been
    /// seen is nearer the viewer. The hole for an excluded window is punched as
    /// its rounded rect *minus* those coverings, so a window that only peeks out
    /// from behind another stays sharp only where it actually shows.
    ///
    /// The app's own windows — the overlay (level 15) and Settings — are kept out
    /// of the occluder set on purpose: the overlay covers the whole screen and
    /// would otherwise subtract every excluded hole down to nothing, and Settings
    /// already gets its own hole, so its union with the excluded hole is correct
    /// without also clipping it away here.
    static func windows(of bundleIDs: Set<String>) -> [SharpWindow] {
        guard !bundleIDs.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let own = Bundle.main.bundleIdentifier
        // One look-up per process, not per window: an app with a dozen windows
        // would otherwise ask `NSWorkspace` the same question twelve times.
        var bundleIDByPID: [pid_t: String?] = [:]
        // Windows seen so far this pass, nearest the viewer first. They are the
        // occluders for anything we meet later in the list.
        var frontSoFar: [CGRect] = []
        var result: [SharpWindow] = []

        for entry in list {
            // Only ordinary windows, using the same ceiling the focus pick uses.
            // A menu bar item or a Dock tile belongs to the app but is not a
            // window anyone thinks of as "the app's window". The ceiling stops
            // at 19 on purpose: the Dock reports one window covering the entire
            // screen, so letting it through would subtract every excluded hole
            // down to nothing.
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0, layer <= 19 else { continue }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 40, rect.height > 30
            else { continue }

            let bundleID: String? = bundleIDByPID[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            bundleIDByPID[pid] = bundleID
            let isOwn = bundleID == own || pid == ProcessInfo.processInfo.processIdentifier
            if !isOwn, let id = ExcludedApps.normalized(bundleID), bundleIDs.contains(id) {
                // Whatever already seen overlaps this window is in front of it and
                // owns those pixels.
                let cover = frontSoFar.filter { blocker in
                    let overlap = rect.intersection(blocker)
                    return overlap.width > 0 && overlap.height > 0
                }
                result.append(SharpWindow(rect: rect, coveredBy: cover))
            }
            // Seen either way: every later window that this one sits in front of
            // must treat it as an occluder (the focus window included).
            if !isOwn { frontSoFar.append(rect) }
        }
        return result
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
        objectWillChange.send()
        keepChrome = on
        UserDefaults.standard.set(on, forKey: SettingsKey.keepChrome)
        for (_, overlay) in overlays { overlay.setChromeClear(on) }
        capturer.invalidateFilters()
        settledFrames = 0
    }

    func setBlurRadius(_ radius: Double) {
        let clamped = min(max(radius, Self.smallestBlurRadius), Self.largestBlurRadius)
        guard blurRadius != clamped else { return }
        objectWillChange.send()
        blurRadius = clamped
        UserDefaults.standard.set(clamped, forKey: SettingsKey.blurRadius)
        // The vibrancy backend applies a radius by picking the nearest system
        // material, so its overlays hear about the change directly; the
        // captured backend bakes the radius into the blur and is woken below.
        for (_, overlay) in overlays { overlay.setBlurRadius(clamped) }
        // Wakes the capture loop: a settled loop would otherwise take up to
        // 33ms to pick up the new radius.
        settledFrames = 0
    }

    private func clampedCursorRevealRadius(_ radius: Double) -> Double {
        min(max(radius, Self.smallestCursorRevealRadius), Self.largestCursorRevealRadius)
    }

    /// Turns the cursor's clear disc on or off.
    ///
    /// Nothing about this needs a new picture — the disc is a hole in the blur,
    /// and the pixels under it are the real ones — so the capture loop is left
    /// to run at whatever rate it already settled on. It wakes the mask on the
    /// next display-link tick by itself, since the reveal changed.
    func setRevealCursor(_ on: Bool) {
        guard cursorReveal != on else { return }
        objectWillChange.send()
        cursorReveal = on
        UserDefaults.standard.set(on, forKey: SettingsKey.revealCursor)
    }

    func setCursorRevealRadius(_ radius: Double) {
        let clamped = clampedCursorRevealRadius(radius)
        guard cursorRevealRadius != clamped else { return }
        objectWillChange.send()
        cursorRevealRadius = clamped
        UserDefaults.standard.set(clamped, forKey: SettingsKey.cursorRevealRadius)
    }

    func enable() {
        guard !enabled else { return }
        objectWillChange.send()
        enabled = true
        usesVibrancy = !capturer.hasPermission
        if !capturer.hasPermission { capturer.requestPermission() }
        screenSignature = Self.currentScreenSignature()
        rebuildOverlays()
        refreshFocus()

        startDisplayLink()
        startClockMonitor()
        // The capture loop is the captured backend's whole engine; on the
        // vibrancy one there is nothing to capture and nothing to pay for.
        if !usesVibrancy {
            startCaptureLoop()
            // Arm the restart watchdog for the session: TCC is read once per
            // launch, so a grant recorded while this process was already
            // running can leave the capture engine silent for the whole
            // session even though `hasPermission` says otherwise.
            backendSwitchedAwaitingFirstFrame = Date()
            hasDeliveredFrameSinceBackendSwitch = false
            captureAttemptsSinceBackendSwitch = 0
        }
        // If Screen Recording was never granted, the effect used to be
        // silently dead. On the vibrancy fallback it is not dead — it is
        // running on system blur — so the warning only belongs to the captured
        // backend, where a missing permission really does mean no blur.
        permissionWarnTask?.cancel()
        if !usesVibrancy {
            permissionWarnTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.enabled, !capturer.hasPermission else { return }
                self.warnNoScreenRecordingPermission()
            }
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

        // Last, so a subscriber reading back through the public getters sees a
        // session that is fully up rather than one that is half-built.
        onEnabledChanged?(true)
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
        alert.messageText = I18n.shared.t("需要「屏幕录制」权限")
        alert.informativeText = I18n.shared.t("隐私模糊通过截图来实现。请在「系统设置 › 隐私与安全性 › 屏幕录制」中打开「PrivacyWindow」，然后重新打开效果。")
        alert.addButton(withTitle: I18n.shared.t("打开系统设置"))
        alert.addButton(withTitle: I18n.shared.t("稍后"))
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
        objectWillChange.send()
        enabled = false
        usesVibrancy = false
        backendSwitchedAwaitingFirstFrame = nil
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
        // No frame is in flight, so the last sampled position goes with it: it
        // is a reading of a moment, and re-enabling must not resurrect a disc
        // wherever the pointer happened to be minutes ago.
        cursorPoint = nil
        // A session that ended takes its capture lease with it: nothing is in
        // flight any more, and the interval started by enable() must not look
        // like a pass that has been running for minutes.
        captureStartedAt = 0
        for observer in powerObservers { observer.center.removeObserver(observer.token) }
        powerObservers.removeAll()
        onEnabledChanged?(false)
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
        checkBackendMatchesPermission()
        checkRestartHint()
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

    /// Rebuilds the session on the other blur backend when the permission the
    /// current one was picked on has changed under us.
    ///
    /// The backend is chosen once per session, but Screen Recording is a living
    /// setting: granted while the effect runs (the TCC prompt this app raised
    /// on enable is exactly how), or revoked from System Settings. One
    /// preflight a second — piggybacking on the clock that already exists — is
    /// all it takes to notice, and the invariant is one comparison: vibrancy
    /// and "granted" can never both be true.
    private func checkBackendMatchesPermission() {
        let shouldUseVibrancy = !capturer.hasPermission
        guard usesVibrancy != shouldUseVibrancy else { return }
        usesVibrancy = shouldUseVibrancy
        objectWillChange.send()
        stopCaptureLoop()
        for (_, overlay) in overlays { overlay.close() }
        overlays.removeAll()
        lastCaptureNanos.removeAll()
        lastCoveredDisplays.removeAll()
        // No fade-in from empty: the effect is already on screen, and animating
        // the swap would flash the bare desktop for a quarter of a second.
        rebuildOverlays(animate: false)
        if !usesVibrancy {
            startCaptureLoop()
            // A grant picked up mid-run is exactly the case where macOS hands
            // out the permission but the running process never gets to use it:
            // TCC is read once per launch, so the capture engine can sit silent
            // until the app is restarted. Arm the watchdog that notices.
            backendSwitchedAwaitingFirstFrame = Date()
            hasDeliveredFrameSinceBackendSwitch = false
            captureAttemptsSinceBackendSwitch = 0
        } else {
            backendSwitchedAwaitingFirstFrame = nil
        }
    }

    /// Fires the restart hint if the captured backend never produced a frame.
    ///
    /// Two conditions must both hold, because "no picture yet" has innocent
    /// causes: there must have been real capture *attempts* (an empty desktop
    /// or an excluded app in front simply runs no captures), and enough time
    /// must have passed (ScreenCaptureKit's first frame can legitimately take
    /// a second or two to arrive). Attempts without a single delivery over
    /// six seconds is the signature of the stale-TCC case, and nothing else.
    private func checkRestartHint() {
        guard let switchedAt = backendSwitchedAwaitingFirstFrame else { return }
        guard enabled, !usesVibrancy, hasDeliveredFrameSinceBackendSwitch == false else {
            backendSwitchedAwaitingFirstFrame = nil
            return
        }
        guard Date().timeIntervalSince(switchedAt) > 6,
              captureAttemptsSinceBackendSwitch >= 5 else { return }
        backendSwitchedAwaitingFirstFrame = nil
        showRestartHint()
    }

    /// Tells the user that the grant arrived but the process cannot use it.
    private func showRestartHint() {
        let alert = NSAlert()
        alert.messageText = I18n.shared.t("需要重启隐私窗口")
        alert.informativeText = I18n.shared.t("「屏幕录制」权限已生效，但 macOS 只在应用启动时读取一次该授权——当前进程拿不到画面，所以模糊不会有变化。重新打开应用即可。")
        alert.addButton(withTitle: I18n.shared.t("重新打开"))
        alert.addButton(withTitle: I18n.shared.t("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        permissionAlert = alert
        let host = focus.flatMap { overlays[$0.displayID] }?.window ?? overlays.values.first?.window
        guard let host else {
            permissionAlert = nil
            let response = alert.runModal()
            permissionAlert = nil
            if response == .alertFirstButtonReturn { relaunch() }
            return
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            self?.permissionAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            self?.relaunch()
        }
    }

    /// Starts a fresh instance of this app and exits. `open -n` is issued from
    /// a short-lived shell so it fires *after* this process is already on its
    /// way out — `LSMultipleInstancesProhibited` makes a same-instant launch
    /// of the same bundle id merely activate the dying instance otherwise.
    private func relaunch() {
        disable()
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open -n '\(bundlePath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// One compositor frame: re-reads the focus and commits picture + cutout as
    /// a single unit.
    private func displayLinkFired() {
        guard enabled else { return }
        lastTickNanos = DispatchTime.now().uptimeNanoseconds
        frameIndex = (frameIndex + 1) % 1_000_000
        refreshFocus()
        // With no focus the overlays are already blank and the capture loop is
        // stopped; there is nothing to update until a window comes back. The
        // cursor disc dies with it too — an empty desktop is already entirely
        // sharp, so there would be nothing to reveal, and keeping it alive here
        // would mean paying for the read (and for sixty mask rebuilds a second)
        // for a benefit nobody can see.
        // Read before the focus test, because the cutout for our *own* windows
        // does not depend on there being a focused window at all. The settings
        // window sitting on an empty desktop is exactly that case: with no
        // focus we would return here, never commit, and leave the overlay
        // covering the one window of ours the user is trying to use.
        let ownWindows = Self.ownWindowRects()
        refreshExcludedWindows()
        guard focus != nil || !ownWindows.isEmpty || !excludedWindows.isEmpty else {
            cursorPoint = nil
            return
        }
        // Sampled once for the whole frame, not once per overlay: every display
        // then agrees about where the pointer was when this frame was built,
        // and a multi-screen setup pays for one read rather than one per
        // screen. Only read at all when it is going to be used.
        cursorPoint = cursorReveal ? Self.globalCursorPoint() : nil
        // Read once for the whole frame: it decides every display's cutout, and
        // one frame must not disagree with itself about who has the keyboard.
        // See `ownWindowHasKeyboard`.
        let keyboardIsOurs = ownWindowHasKeyboard
        for (id, overlay) in overlays {
            // A display the window has swallowed stops being *captured*, but
            // keeps the blur it is already showing. Emptying it instead would
            // flash the bare desktop — real, readable pixels — for the few
            // frames it takes to start capturing again.
            overlay.commit(reveal: Self.reveal(
                focusHole: localHole(for: id),
                cursorHole: cursorHole(for: id),
                ownWindows: ownWindowHoles(for: id, among: ownWindows),
                excluded: excludedHoles(for: id),
                ownWindowHasKeyboard: keyboardIsOurs
            ))
        }
    }

    /// Whether one of *our* windows currently holds the keyboard — the Settings
    /// window, in practice.
    ///
    /// The focus pick cannot choose our own windows (`FocusTracker.decode` drops
    /// them, because a hole cut for our own blur would be a hole in the wrong
    /// place), so while Settings is in front the scan falls through to the
    /// topmost window of *another* app — which is whatever was in front before
    /// Settings opened. Both windows then got a hole: the focused one because
    /// the scan picked it, ours because our own windows are always cut out. Two
    /// sharp windows on a blurred desktop, which is not what this app promises.
    ///
    /// The window with the keyboard is the one being used, so it is the one
    /// that stays sharp: while ours has it, the focused window's hole is
    /// dropped. The capture still excludes that window, so it is blurred
    /// *and* inpainted rather than merely left out of the cutout.
    private var ownWindowHasKeyboard: Bool {
        // Overlays can never be key (`OverlayWindow.canBecomeKey` is false), so
        // the only thing this has to rule out is a key window borrowed from
        // somebody else — there is none — and the check below would be
        // redundant. It is kept because the level an overlay sits at (15, under
        // the "keep system chrome clear" mode) is inside the band the focus pick
        // will accept, and a future change that lets an overlay become key
        // would otherwise hand the whole screen a hole.
        guard let key = NSApp.keyWindow else { return false }
        return !(key is OverlayWindow)
    }

    /// Assembles one display's reveal. Pure, so the rule that our own window
    /// outranks the focused one can be checked without a display attached.
    static func reveal(
        focusHole: CGRect?,
        cursorHole: CGRect?,
        ownWindows: [CGRect],
        excluded: [SharpWindow],
        ownWindowHasKeyboard: Bool
    ) -> Reveal {
        Reveal(
            window: ownWindowHasKeyboard ? nil : focusHole,
            cursor: cursorHole,
            ownWindows: ownWindows,
            excluded: excluded
        )
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
        captureAttemptsSinceBackendSwitch += 1

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
            hasDeliveredFrameSinceBackendSwitch = true
            // Only a picture that was actually shown refreshes the throttle.
            // Timing a discarded one would push the next refresh out by a full
            // period for a display that is still holding the old frame.
            lastCaptureNanos[id] = DispatchTime.now().uptimeNanoseconds
        }
    }

    // MARK: - Geometry

    /// The overlay-local hole in **points, top-left origin** — what
    /// `Reveal.window` expects. `nil` when the focused window is not on
    /// `displayID`.
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

    // MARK: - Cursor

    /// Where the pointer is right now, in global **top-left** coordinates — the
    /// same space as `CGDisplayBounds` and the window list, so a display's
    /// origin can simply be subtracted.
    ///
    /// Read from `CGEvent` rather than from `NSEvent.mouseLocation`, which is
    /// bottom-left origin and would ask for a conversion through the primary
    /// display's height first; and sampled per frame rather than through a
    /// global event monitor, because a monitor does not know about frames. Its
    /// callbacks either have to be stashed somewhere until the next tick — the
    /// same state, plus a detour — or they arrive faster than the compositor can
    /// take them.
    ///
    /// `nil` is not something to paper over. It means the pointer's location is
    /// genuinely unknown, and guessing the last one would park a sharp disc over
    /// the wrong pixels instead of revealing the right ones. Nobody should ever
    /// get a clear view of anything by accident.
    private static func globalCursorPoint() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// The disc of sharpness around the cursor, in overlay-local top-left
    /// points, for the display whose global rect is `bounds`.
    ///
    /// Pure so that the interesting part — "which display owns this pointer,
    /// and how big is the disc" — can be checked without a display attached.
    ///
    /// Only drawn on the display the cursor is actually on. Every overlay is
    /// exactly one screen with its own layer tree, so nothing shared exists: a
    /// disc reaching across a seam cannot be clipped by its neighbour, which has
    /// no idea it happened.
    static func cursorHole(point: CGPoint?, in bounds: CGRect, radius: CGFloat) -> CGRect? {
        guard let point, radius > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        // Our own comparison, not `CGRect.contains`: which edges count as inside
        // there is a system implementation detail, and this decides *which
        // screen draws*. Choosing [min, max) makes the halves exclusive, so a
        // cursor sitting exactly on a seam belongs to one display rather than to
        // both — and so every position belongs to exactly one.
        guard point.x >= bounds.minX, point.x < bounds.maxX,
              point.y >= bounds.minY, point.y < bounds.maxY else { return nil }
        let local = CGPoint(x: point.x - bounds.origin.x, y: point.y - bounds.origin.y)
        // Left deliberately un-clipped. See `Reveal.cursor`: clipping this to
        // the display would turn the circle near an edge into an ellipse whose
        // missing arc is replaced by a visibly flatter curve.
        return CGRect(
            x: local.x - radius,
            y: local.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    /// The cursor's disc for `displayID` this frame, or `nil` when there is none
    /// to draw.
    private func cursorHole(for displayID: CGDirectDisplayID) -> CGRect? {
        Self.cursorHole(
            point: cursorPoint,
            in: CGDisplayBounds(displayID),
            radius: CGFloat(cursorRevealRadius)
        )
    }

    /// Global (top-left) rects of this app's own on-screen windows — the
    /// Settings window, in practice.
    ///
    /// The overlay outranks ordinary windows, including ours, so anything we put
    /// on screen has to be cut out of the blur or it reads as broken. This is
    /// deliberately the only place that looks, once per frame, rather than a
    /// call the settings window makes on itself: the window knows nothing about
    /// displays, the overlay's geometry, or whether the effect is even running.
    ///
    /// Sheets are excluded (`parent == nil`). A sheet already paints above the
    /// window it belongs to, and the permission sheet hangs off an overlay —
    /// cutting a hole for it would punch through the blur behind its corners.
    static func ownWindowRects() -> [CGRect] {
        NSApp.windows
            // `level == .normal` is what keeps the status item out. Its window
            // comes first in `NSApp.windows`, so when only one hole was cut it
            // was cut for the menu bar widget — and Settings, further down the
            // list, stayed under the blur.
            .filter {
                !($0 is OverlayWindow) && $0.parent == nil && $0.isVisible &&
                    !$0.isMiniaturized && $0.level == .normal
            }
            .map { convertToCGCoordinates($0.frame) }
    }

    /// The parts of our own windows that land on `displayID`, in overlay-local
    /// points. Every one of them, not just the first: two windows of ours can be
    /// on the same display at once.
    private func ownWindowHoles(for displayID: CGDirectDisplayID, among rects: [CGRect]) -> [CGRect] {
        clipToDisplay(rects, displayID: displayID)
    }

    /// The parts of excluded windows that land on `displayID`, re-based to
    /// overlay-local points, carrying their covering windows with them so the
    /// hole can subtract them.
    private func excludedHoles(for displayID: CGDirectDisplayID) -> [SharpWindow] {
        let bounds = CGDisplayBounds(displayID)
        return excludedWindows.compactMap { win -> SharpWindow? in
            let visible = win.rect.intersection(bounds)
            guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
            let local = CGRect(
                x: visible.minX - bounds.minX,
                y: visible.minY - bounds.minY,
                width: visible.width,
                height: visible.height
            )
            let covered = win.coveredBy.compactMap { c -> CGRect? in
                let v = c.intersection(bounds)
                guard !v.isNull, v.width > 1, v.height > 1 else { return nil }
                return CGRect(
                    x: v.minX - bounds.minX,
                    y: v.minY - bounds.minY,
                    width: v.width,
                    height: v.height
                )
            }
            return SharpWindow(rect: local, coveredBy: covered)
        }
    }

    /// `rects` trimmed to `displayID` and re-based to overlay-local points.
    private func clipToDisplay(_ rects: [CGRect], displayID: CGDirectDisplayID) -> [CGRect] {
        let bounds = CGDisplayBounds(displayID)
        return rects.compactMap { rect in
            let visible = rect.intersection(bounds)
            guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
            return CGRect(
                x: visible.minX - bounds.minX,
                y: visible.minY - bounds.minY,
                width: visible.width,
                height: visible.height
            )
        }
    }

    /// Converts an AppKit window frame to the global top-left coordinates the
    /// rest of the app already speaks (`CGWindowList`, `CGDisplayBounds`).
    ///
    /// AppKit measures from the **bottom-left** of the primary display with Y
    /// growing upward; CoreGraphics measures from its **top-left**. One flip
    /// about the primary's far edge converts between them, and X passes through
    /// unchanged — including for displays sitting to the left, whose origins are
    /// negative in both systems.
    static func convertToCGCoordinates(_ frame: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first { $0.frame.contains(NSPoint.zero) }?.frame.height
            ?? NSScreen.main?.frame.height
        guard let primaryHeight, primaryHeight > 0 else { return frame }
        return convertToCGCoordinates(frame, primaryHeight: primaryHeight)
    }

    /// The pure form, so the flip can be checked without a screen attached.
    static func convertToCGCoordinates(_ frame: NSRect, primaryHeight: CGFloat) -> CGRect {
        guard primaryHeight > 0 else { return frame }
        return CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
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
            let overlay = BlurOverlay(
                screen: screen,
                animateAppearance: animate,
                vibrancy: usesVibrancy,
                blurRadius: blurRadius
            )
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
