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
    private struct Exclusion: Equatable {
        let focusPID: pid_t?
        let focusRect: CGRect?
        let keepChrome: Bool
    }

    private var filters: [CGDirectDisplayID: (exclusion: Exclusion?, filter: SCContentFilter)] = [:]

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
    }

    /// A screenshot of `displayID`, or `nil` if capture failed. When `focus` is
    /// given, that window is left out of the picture; when `keepChrome` is set,
    /// so are the menu bar and the Dock.
    func capture(displayID: CGDirectDisplayID, excludingFocused focus: (pid: pid_t, rect: CGRect)?, keepChrome: Bool) async -> (CGImage, CGFloat)? {
        guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else { return nil }
        let exclusion = Exclusion(focusPID: focus?.pid, focusRect: focus?.rect, keepChrome: keepChrome)
        if filters[displayID]?.exclusion != exclusion {
            await rebuild(displayID: displayID, excluding: exclusion)
        }
        guard let filter = filters[displayID]?.filter else { return nil }

        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, scale)
        } catch {
            filters[displayID] = nil
            return nil
        }
    }

    private func rebuild(displayID: CGDirectDisplayID, excluding exclusion: Exclusion) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

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

            // Drop the focused window by pid + frame overlap. `SCWindow.frame`
            // and `CGWindowList` bounds can disagree by the window-shadow
            // padding, so match by largest intersection rather than equality.
            if let pid = exclusion.focusPID, let rect = exclusion.focusRect {
                var best: (window: SCWindow, area: CGFloat)?
                for window in content.windows where window.isOnScreen {
                    guard window.owningApplication?.processID == pid else { continue }
                    let inter = window.frame.intersection(rect)
                    let area = inter.width * inter.height
                    if area > 0, best == nil || area > best!.area {
                        best = (window, area)
                    }
                }
                if let best = best {
                    excluded.append(best.window)
                }
            }

            filters[displayID] = (exclusion, SCContentFilter(display: display, excludingWindows: excluded))
        } catch {
            filters[displayID] = nil
        }
    }
}
