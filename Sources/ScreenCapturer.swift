import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures a screenshot of one display, excluding this app's own windows (so
/// the overlay never feeds back into its own picture) and, optionally, the
/// focused window itself — otherwise the Gaussian blur would smear the
/// window's bright content into a glowing halo around the cutout. When chrome
/// is kept clear, the menu bar and the Dock are also left out of the picture.
@MainActor
final class ScreenCapturer {
    /// Identifies what is currently excluded from the cached filter, so we only
    /// pay for a `SCShareableContent` rebuild when something actually changes.
    ///
    /// The focused window is identified by its **window id**, deliberately not
    /// by its rectangle: while a window is dragged its rectangle changes every
    /// single frame, and keying on it rebuilt the (expensive) shareable-content
    /// snapshot continuously — which both wasted CPU and delayed every capture
    /// by the rebuild's latency, so the blurred picture always trailed the
    /// cutout. The id is stable for the whole drag.
    private struct Exclusion: Equatable {
        let focusWindowID: CGWindowID?
        let keepChrome: Bool
    }

    /// Screenshots are downscaled to roughly this width. A blur throws away the
    /// detail the extra pixels would carry, so they cost latency and power for
    /// nothing — and on a 5K panel this is the difference between reading back
    /// about 14 MB and about 3 MB every frame.
    private static let targetCaptureWidth: CGFloat = 1600
    /// Set if ScreenCaptureKit ever refuses to scale into the requested buffer.
    /// From then on we capture at native resolution: slower, but never wrong.
    private var downscaleDisabled = false

    private var filters: [CGDirectDisplayID: (exclusion: Exclusion?, filter: SCContentFilter)] = [:]
    /// Quiet period after a failure, per display. Without it a persistently
    /// failing capture — no Screen Recording permission, a display that just
    /// went away — turns the capture loop into a tight retry storm, rebuilding
    /// the (expensive) shareable-content snapshot every few milliseconds for
    /// nothing.
    private var failures: [CGDirectDisplayID: (count: Int, retryAfter: TimeInterval)] = [:]

    /// How much to shrink a display this wide. Scales with the panel so a
    /// 1080p screen keeps every pixel it has while a 6K one does not pay for
    /// four times the pixels of a 1440p one.
    private func divisor(forNativeWidth width: CGFloat) -> CGFloat {
        guard !downscaleDisabled, width > Self.targetCaptureWidth else { return 1 }
        // Fractional on purpose: rounding to whole divisors makes the step
        // between panels uneven (a 1080p screen would keep every pixel while a
        // 1440p one is halved), which is the opposite of the intent.
        return min(4, max(1, width / Self.targetCaptureWidth))
    }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the Screen Recording permission prompt if it has not been
    /// granted yet.
    func requestPermission() {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Forces the next capture to rebuild its filter (e.g. after a settings
    /// toggle). Cheap; the new filter is built lazily on demand.
    func invalidateFilters() {
        filters.removeAll()
        failures.removeAll()
        // A display change is a fresh start: whatever made us distrust the
        // downscale (a resolution switch mid-flight, most likely) no longer
        // applies, so let it try again.
        downscaleDisabled = false
    }

    /// A screenshot of `displayID` together with the pixel scale it was taken
    /// at, or `nil` if capture failed. When `focusWindowID` is given, that
    /// window is left out of the picture; when `keepChrome` is set, so are the
    /// menu bar and the Dock.
    func capture(
        displayID: CGDirectDisplayID,
        focusWindowID: CGWindowID?,
        keepChrome: Bool
    ) async -> (CGImage, CGFloat)? {
        guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else { return nil }
        guard !isBackingOff(displayID) else { return nil }

        let exclusion = Exclusion(focusWindowID: focusWindowID, keepChrome: keepChrome)
        if filters[displayID]?.exclusion != exclusion {
            await rebuild(displayID: displayID, excluding: exclusion)
        }
        guard let filter = filters[displayID]?.filter else {
            registerFailure(displayID)
            return nil
        }

        // Requested pixels per point — the downscale that buys back the
        // latency. Only a request: the actual scale is measured from the bitmap
        // below rather than assumed, so a display whose scale ScreenCaptureKit
        // rounds or clamps differently still maps onto the point geometry.
        let divisor = divisor(forNativeWidth: filter.contentRect.width * CGFloat(filter.pointPixelScale))
        let requested = max(1, CGFloat(filter.pointPixelScale) / divisor)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(filter.contentRect.width * requested))
        configuration.height = max(1, Int(filter.contentRect.height * requested))
        // Ask for the whole display scaled down into the smaller buffer;
        // without this the stream would crop instead of fit.
        configuration.scalesToFit = true
        configuration.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            failures[displayID] = nil

            // If ScreenCaptureKit ever declines to scale into the requested
            // buffer, the picture turns into a magnified crop of the display's
            // top-left corner — an unmistakable, very visible breakage. Drop
            // the downscale rather than ship that; the cost is a slower blur,
            // not a wrong one.
            // Only "did not downscale at all" counts as a failure — the width
            // then comes back near native. A few pixels of alignment
            // difference is normal and must not trip this.
            if !downscaleDisabled, divisor > 1,
               CGFloat(image.width) > CGFloat(configuration.width) * 1.5 {
                downscaleDisabled = true
                invalidateFilters()
            }

            // Measure, don't trust: callers convert point rects into this
            // bitmap's pixels, so the two must agree exactly.
            let measured = CGFloat(image.width) / max(filter.contentRect.width, 1)
            return (image, measured > 0 ? measured : requested)
        } catch {
            registerFailure(displayID)
            return nil
        }
    }

    private func isBackingOff(_ displayID: CGDirectDisplayID) -> Bool {
        guard let failure = failures[displayID] else { return false }
        return Date.timeIntervalSinceReferenceDate < failure.retryAfter
    }

    /// Backs off exponentially (0.25s, doubling to a 2s ceiling) so a
    /// permanently failing display costs almost nothing instead of being
    /// retried on every capture tick.
    private func registerFailure(_ displayID: CGDirectDisplayID) {
        let count = (failures[displayID]?.count ?? 0) + 1
        let delay = min(2.0, 0.25 * pow(2, Double(min(count - 1, 3))))
        failures[displayID] = (count, Date.timeIntervalSinceReferenceDate + delay)
    }

    private func rebuild(displayID: CGDirectDisplayID, excluding exclusion: Exclusion) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                // The display is gone (unplugged, sleeping). Leaving the old
                // filter behind would hand back one whose exclusions no longer
                // match what was asked for — and since the key would still
                // differ, the next tick would rebuild all over again without
                // ever backing off.
                filters[displayID] = nil
                return
            }

            // Always drop our own overlay windows from the picture.
            var excluded = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }

            // Keep the menu bar and the Dock sharp when requested.
            if exclusion.keepChrome {
                // The Dock is its own app — exclude every window it owns.
                excluded.append(contentsOf: content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == "com.apple.dock"
                })
                // The menu bar is a full-width strip flush with a display's top
                // edge. Match it geometrically (owner/title vary across macOS
                // versions) rather than by bundle or name.
                for d in content.displays {
                    let b = CGDisplayBounds(d.displayID)
                    let strip = CGRect(x: b.origin.x, y: b.origin.y, width: b.width, height: 28)
                    let match = content.windows.first { window in
                        let f = window.frame
                        return abs(f.minX - strip.minX) < 2 &&
                               abs(f.width - strip.width) < 2 &&
                               abs(f.minY - strip.minY) < 2 &&
                               (f.maxY - strip.minY) >= 16 && (f.maxY - strip.minY) <= 40
                    }
                    if let match = match {
                        excluded.append(match)
                    }
                }
            }

            // Drop the focused window by id — an exact match, unlike the old
            // "same pid, largest overlapping frame" heuristic, which happily
            // picked the wrong window whenever the focused app stacked several
            // of them. When it picked wrong, the real window stayed in the
            // picture and the blur painted a halo around the cutout that
            // blinked on and off between consecutive frames.
            if let windowID = exclusion.focusWindowID,
               let window = content.windows.first(where: { $0.windowID == windowID }) {
                excluded.append(window)
            }

            filters[displayID] = (exclusion, SCContentFilter(display: display, excludingWindows: excluded))
        } catch {
            filters[displayID] = nil
        }
    }
}
