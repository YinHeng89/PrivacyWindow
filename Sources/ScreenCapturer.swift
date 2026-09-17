import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures a screenshot of one display, excluding this app's own windows so
/// the overlay never feeds back into its own picture.
@MainActor
final class ScreenCapturer {
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the Screen Recording permission prompt if it has not been
    /// granted yet.
    func requestPermission() {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// A blurred screenshot of `displayID`, or `nil` if capture failed.
    func capture(displayID: CGDirectDisplayID) async -> (CGImage, CGFloat)? {
        guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else { return nil }
        if filters[displayID] == nil {
            await rebuild(displayID: displayID)
        }
        guard let filter = filters[displayID] else { return nil }

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

    private func rebuild(displayID: CGDirectDisplayID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let bundleID = Bundle.main.bundleIdentifier
            let own = content.applications.filter { $0.bundleIdentifier == bundleID }
            filters[displayID] = SCContentFilter(
                display: display,
                excludingApplications: own,
                exceptingWindows: []
            )
        } catch {
            filters[displayID] = nil
        }
    }
}
