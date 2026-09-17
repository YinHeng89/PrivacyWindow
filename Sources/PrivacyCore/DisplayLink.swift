import CoreVideo
import Dispatch
import Foundation
import os

/// A vsync-aligned heartbeat that runs its handler on the main thread.
///
/// `CADisplayLink` is iOS-only, so on macOS this wraps the underlying
/// `CVDisplayLink`. Driving the overlay from the display's own refresh signal
/// rather than from a `Timer` matters more than it sounds: a 60Hz timer drifts
/// against the compositor, so in one frame the cutout gets updated twice and in
/// the next not at all. That unevenness is exactly what reads as "laggy" even
/// when the average rate looks fine. Here every frame gets one update,
/// delivered at the start of the frame.
///
/// Deliberately shared across threads: the callback fires on CoreVideo's own
/// high-priority thread and every mutable field is guarded by a lock.
final class DisplayLink: @unchecked Sendable {
    private struct State {
        /// A tick has been handed to the main queue and has not run yet.
        var pending = false
        var lastTickNanos: UInt64 = 0
    }

    /// Callback rate ceiling. ProMotion panels and multi-display setups can push
    /// `CVDisplayLink` well past 60Hz, and there is nothing to gain from
    /// tracking a mouse-driven window at 120Hz — only twice the CPU.
    private let minimumIntervalNanos: UInt64
    private let handler: @MainActor () -> Void

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Read by the display link's own thread. `CVDisplayLinkStop` does not
    /// promise to join an in-flight callback, so the callback itself has to
    /// check this before touching `self`.
    private let stopped = OSAllocatedUnfairLock(initialState: true)

    private var link: CVDisplayLink?
    /// The +1 reference handed to `CVDisplayLink`, released in `stop()` after
    /// the callback has been detached. This is what guarantees the callback can
    /// never dereference a freed `DisplayLink`.
    private var retainedContext: Unmanaged<DisplayLink>?
    /// Used only if `CVDisplayLink` cannot drive us (no active displays, e.g. a
    /// sleeping machine): a run-loop timer is not phase-aligned but keeps the
    /// overlay alive instead of freezing it.
    private var fallbackTimer: Timer?

    init(preferredFramesPerSecond: Int = 60, handler: @escaping @MainActor () -> Void) {
        let hz = max(1, preferredFramesPerSecond)
        // A hair under the true period so normal vsync jitter cannot make us
        // drop every other frame.
        minimumIntervalNanos = UInt64(max(1_000_000_000 / hz - 1_000_000, 1_000_000))
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard link == nil, fallbackTimer == nil else { return }
        stopped.withLock { $0 = false }

        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created else {
            startFallbackTimer()
            return
        }

        let context = Unmanaged.passRetained(self)
        retainedContext = context
        CVDisplayLinkSetOutputCallback(
            created,
            { _, _, _, _, _, rawContext in
                guard let rawContext else { return kCVReturnSuccess }
                let displayLink = Unmanaged<DisplayLink>.fromOpaque(rawContext).takeUnretainedValue()
                guard !displayLink.stopped.withLock({ $0 }) else { return kCVReturnSuccess }
                displayLink.schedule()
                return kCVReturnSuccess
            },
            context.toOpaque()
        )

        guard CVDisplayLinkStart(created) == kCVReturnSuccess else {
            // No runnable display to sync to (sleeping / headless). Detach the
            // callback and give the reference back before falling back.
            CVDisplayLinkSetOutputCallback(created, nil, nil)
            context.release()
            retainedContext = nil
            startFallbackTimer()
            return
        }
        link = created
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        stopped.withLock { $0 = true }

        if let link {
            // Detach first, then stop: `CVDisplayLinkStop` does not guarantee
            // that a callback already in flight has returned, so the callback
            // must be able to see `stopped` and bail out on its own.
            CVDisplayLinkSetOutputCallback(link, nil, nil)
            CVDisplayLinkStop(link)
            self.link = nil
        }
        // `CVDisplayLinkStop` does not promise to join a callback that is
        // already running, and the callback dereferences us. Handing the +1
        // back to the main queue a moment later — rather than right here —
        // guarantees any in-flight callback has returned, without blocking
        // this thread waiting for it.
        if let context = retainedContext {
            retainedContext = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { context.release() }
        }
        state.withLock { $0 = State() }
    }

    private func startFallbackTimer() {
        let timer = Timer(timeInterval: Double(minimumIntervalNanos) / 1_000_000_000, repeats: true) { [weak self] _ in
            self?.fire()
        }
        // `.common` so the overlay keeps tracking while the menu is held open.
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// Runs the handler on the main queue. Both drivers route through here so
    /// `MainActor.assumeIsolated` is asserted in exactly one place.
    private func fire() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.handler() }
        }
    }

    /// Called on the display link's own high-priority thread.
    private func schedule() {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldSchedule = state.withLock { state -> Bool in
            // The guard doubles as back-pressure: a busy main thread would
            // otherwise pile up queued ticks that all fire at once, later.
            guard !state.pending, now - state.lastTickNanos >= minimumIntervalNanos else { return false }
            state.pending = true
            state.lastTickNanos = now
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [self] in
            state.withLock { $0.pending = false }
            MainActor.assumeIsolated { self.handler() }
        }
    }
}
