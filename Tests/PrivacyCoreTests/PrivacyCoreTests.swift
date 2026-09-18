import CoreGraphics
import XCTest
@testable import PrivacyCore

/// Guards the geometry and policy decisions that are easy to break silently:
/// nothing here needs a display, a window server or Screen Recording
/// permission, so it runs anywhere.
final class DownscaleTests: XCTestCase {
    /// Anything at or below the target width keeps every pixel it has.
    func testNarrowDisplayStaysNative() {
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 1440, downscaleDisabled: false), 1, accuracy: 0.001)
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 1600, downscaleDisabled: false), 1, accuracy: 0.001)
    }

    /// A 5K panel has to actually shrink; this is the regression that a wrong
    /// clamp silently disabled, leaving every Retina display capturing native.
    func testWideDisplayIsDownscaled() {
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 5120, downscaleDisabled: false), 3.2, accuracy: 0.001)
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 3200, downscaleDisabled: false), 2, accuracy: 0.001)
    }

    /// Very wide panels are capped, so the picture never gets too small to blur.
    func testDivisorIsCapped() {
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 20_000, downscaleDisabled: false), 4, accuracy: 0.001)
    }

    /// A display that refused to scale captures at native resolution.
    func testDisabledMeansNative() {
        XCTAssertEqual(ScreenCapturer.divisor(forNativeWidth: 5120, downscaleDisabled: true), 1, accuracy: 0.001)
    }

    /// Never upsample: asking for more pixels per point than the display has.
    func testNeverUpsamples() {
        for width in [800, 1600, 1920, 5120, 8000] {
            let divisor = ScreenCapturer.divisor(forNativeWidth: CGFloat(width), downscaleDisabled: false)
            XCTAssertGreaterThanOrEqual(divisor, 1)
            XCTAssertLessThanOrEqual(divisor, 4)
        }
    }

    /// The regression this guards: on a Retina panel the divisor (1.6 here) is
    /// *below* the display's own pixel scale, and a `min(1, …)` clamp then asked
    /// for 1.0 instead of 1.25 — 1280px instead of the intended 1600px, a
    /// quarter of the background's resolution thrown away for nothing.
    func testRetinaDisplayKeepsItsDownscaleTarget() {
        XCTAssertEqual(
            ScreenCapturer.requestedPixelsPerPoint(pointPixelScale: 2, divisor: 1.6),
            1.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ScreenCapturer.requestedPixelsPerPoint(pointPixelScale: 3, divisor: 2),
            1.5,
            accuracy: 0.001
        )
    }

    /// Whatever the divisor is, the request never exceeds the display's own
    /// scale — there is nothing to gain from asking for pixels it does not have.
    func testRequestedScaleNeverExceedsNative() {
        for scale in [CGFloat(1), 2, 3] {
            for divisor in [CGFloat(1), 1.6, 2, 3.2, 4] {
                let requested = ScreenCapturer.requestedPixelsPerPoint(pointPixelScale: scale, divisor: divisor)
                XCTAssertLessThanOrEqual(requested, scale + 0.001, "scale \(scale) divisor \(divisor)")
                XCTAssertGreaterThan(requested, 0)
            }
        }
    }
}

@MainActor
final class CutoutCornerTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)

    /// A window well inside the display is rounded on every corner.
    func testInteriorHoleKeepsAllCorners() {
        let hole = CGRect(x: 100, y: 100, width: 400, height: 300)
        let radii = BlurOverlay.cornerRadii(for: hole, in: screen, radius: 10)
        XCTAssertEqual(radii.bottomLeft, 10)
        XCTAssertEqual(radii.bottomRight, 10)
        XCTAssertEqual(radii.topRight, 10)
        XCTAssertEqual(radii.topLeft, 10)
    }

    /// The regression this guards: a window spanning two displays is clipped by
    /// each display's boundary. Rounding the corners that sit on the seam leaves
    /// a blurred notch where the two halves should meet seamlessly.
    func testHoleClippedAtLeftEdgeSquaresOnlyThoseCorners() {
        let hole = CGRect(x: 0, y: 100, width: 400, height: 300)
        let radii = BlurOverlay.cornerRadii(for: hole, in: screen, radius: 10)
        XCTAssertEqual(radii.bottomLeft, 0)
        XCTAssertEqual(radii.topLeft, 0)
        XCTAssertEqual(radii.bottomRight, 10)
        XCTAssertEqual(radii.topRight, 10)
    }

    func testHoleClippedAtRightEdgeSquaresOnlyThoseCorners() {
        let hole = CGRect(x: 600, y: 100, width: 400, height: 300)
        let radii = BlurOverlay.cornerRadii(for: hole, in: screen, radius: 10)
        XCTAssertEqual(radii.bottomRight, 0)
        XCTAssertEqual(radii.topRight, 0)
        XCTAssertEqual(radii.bottomLeft, 10)
        XCTAssertEqual(radii.topLeft, 10)
    }

    /// A hole reaching both the top and the bottom is squared on that side too.
    func testHoleClippedTopAndBottom() {
        let hole = CGRect(x: 100, y: 0, width: 400, height: 800)
        let radii = BlurOverlay.cornerRadii(for: hole, in: screen, radius: 10)
        XCTAssertEqual(radii.topLeft, 0)
        XCTAssertEqual(radii.topRight, 0)
        XCTAssertEqual(radii.bottomLeft, 0)
        XCTAssertEqual(radii.bottomRight, 0)
    }

    /// A radius larger than the shape would fold the corners over each other.
    func testRadiusIsClampedToHalfTheShortSide() {
        let hole = CGRect(x: 100, y: 100, width: 10, height: 8)
        let radii = BlurOverlay.cornerRadii(for: hole, in: screen, radius: 10)
        XCTAssertEqual(radii.bottomLeft, 4, accuracy: 0.001)
    }
}

@MainActor
final class FocusRuleTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Chrome's full-screen toolbar: full width, a sliver tall. Taking it for
    /// the focus cut a strip across the top of the screen.
    func testFullWidthShortStripIsABar() {
        XCTAssertTrue(FocusTracker.isBar(CGRect(x: 0, y: 0, width: 1920, height: 90), on: display))
    }

    /// Same width, but tall enough to be somewhere you are working.
    func testTallerWindowIsNotABar() {
        XCTAssertFalse(FocusTracker.isBar(CGRect(x: 0, y: 0, width: 1920, height: 400), on: display))
    }

    /// Short but not spanning the display — an ordinary small window.
    func testNarrowShortWindowIsNotABar() {
        XCTAssertFalse(FocusTracker.isBar(CGRect(x: 0, y: 0, width: 1200, height: 90), on: display))
    }

    /// Same shape, but floating in the middle of the screen. Pure proportions
    /// condemned this: on a wide display a browser dragged into the corner reads
    /// exactly like Chrome's toolbar, and taking it for chrome pushed the cutout
    /// onto whatever window was behind it. Bars are chrome, and chrome is glued
    /// to an edge.
    func testWideShortWindowAwayFromTheEdgesIsNotABar() {
        XCTAssertFalse(FocusTracker.isBar(CGRect(x: 0, y: 300, width: 1920, height: 90), on: display))
    }

    /// …including on a panel wide enough that 30% of the height is a roomy band.
    func testUltrawideCornerWindowIsNotABar() {
        let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        XCTAssertFalse(FocusTracker.isBar(CGRect(x: 0, y: 200, width: 4096, height: 400), on: ultrawide))
    }

    /// A bar flush with the bottom is a bar too — the overlay toolbars that hide
    /// downward land there.
    func testStripFlushWithTheBottomEdgeIsABar() {
        let strip = CGRect(x: 0, y: 990, width: 1920, height: 90)
        XCTAssertTrue(FocusTracker.isBar(strip, on: display))
    }

    /// An ordinary window counts whoever owns it.
    func testNormalLayerIsAlwaysEligible() {
        XCTAssertTrue(FocusTracker.isEligibleLayer(0, fromFrontmostApp: true))
        XCTAssertTrue(FocusTracker.isEligibleLayer(0, fromFrontmostApp: false))
    }

    /// The regression this guards: connecting to an SMB server puts a floating
    /// "正在连接" strip on screen and then raises a modal panel in front of it.
    /// System dialogs must win from any app — a ceiling of 3 refused them, so
    /// the cutout stayed parked on the little strip.
    func testModalPanelBeatsTheStripInFrontOfIt() {
        XCTAssertTrue(FocusTracker.isEligibleLayer(8, fromFrontmostApp: false))
        XCTAssertTrue(FocusTracker.isEligibleLayer(8, fromFrontmostApp: true))
        XCTAssertTrue(FocusTracker.isEligibleLayer(19, fromFrontmostApp: false))
    }

    /// Floating panels — Quick Look, palettes — count for the frontmost app, but
    /// a background app's pet or lyrics HUD parked in the same band does not.
    func testDecorationBandOnlyCountsForTheFrontmostApp() {
        XCTAssertTrue(FocusTracker.isEligibleLayer(3, fromFrontmostApp: true))
        XCTAssertFalse(FocusTracker.isEligibleLayer(3, fromFrontmostApp: false))
    }

    /// Chrome never becomes the focus: Dock (20), menu bar (24), status windows
    /// (25), pop-up menus (101), and anything below the normal level.
    func testChromeIsNeverEligible() {
        for layer in [20, 24, 25, 101, 1000, -1] {
            XCTAssertFalse(FocusTracker.isEligibleLayer(layer, fromFrontmostApp: true), "layer \(layer)")
        }
    }
}

/// A window as `FocusTracker.select` sees it: identity, layer, and nothing else.
private func candidate(id: Int, pid: Int32, layer: Int, rect: CGRect) -> FocusTracker.FocusCandidate {
    FocusTracker.FocusCandidate(
        window: FocusedWindow(windowID: CGWindowID(id), pid: pid, rect: rect, displayID: 1),
        layer: layer
    )
}

@MainActor
final class FocusSelectionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let frontmost: pid_t = 100
    private let other: pid_t = 200

    /// The regression this guards: a background agent raises a modal panel
    /// without activating itself, so the frontmost application is somebody else
    /// — whose own window sits right behind that panel. Looking for the
    /// frontmost app's windows first returned the window *behind* the dialog and
    /// left the hole there.
    func testAnotherAppsModalPanelBeatsTheFrontmostAppsWindow() {
        let pick = FocusTracker.select(
            [
                candidate(id: 1, pid: other, layer: 8, rect: CGRect(x: 400, y: 300, width: 500, height: 300)),
                candidate(id: 2, pid: frontmost, layer: 0, rect: window),
            ],
            frontmostPID: frontmost
        )
        XCTAssertEqual(pick?.pid, other)
        XCTAssertEqual(pick?.windowID, 1)
    }

    /// …but only within the dialog band. A background app's utility panel parked
    /// permanently on screen is merely visible, not something being answered, so
    /// it must not outrank the app the user is actually in — otherwise whichever
    /// app last opened a palette owns the cutout for good.
    func testBackgroundAppUtilityPanelDoesNotBeatTheFrontmostApp() {
        let pick = FocusTracker.select(
            [
                candidate(id: 1, pid: other, layer: 19, rect: window),
                candidate(id: 2, pid: frontmost, layer: 0, rect: window),
            ],
            frontmostPID: frontmost
        )
        XCTAssertEqual(pick?.windowID, 2)
    }

    /// The frontmost app's own windows still lose to nothing but dialogs:
    /// without this tier a floating decoration belonging to another app would
    /// take the cutout while the user works.
    func testFrontmostAppWinsOverAnotherAppsOrdinaryWindow() {
        let pick = FocusTracker.select(
            [
                candidate(id: 1, pid: other, layer: 0, rect: window),
                candidate(id: 2, pid: frontmost, layer: 3, rect: window),
            ],
            frontmostPID: frontmost
        )
        XCTAssertEqual(pick?.windowID, 2)
    }

    /// Nothing eligible means nothing focused, and the desktop stays sharp.
    func testNoCandidatesMeansNoFocus() {
        XCTAssertNil(FocusTracker.select([], frontmostPID: frontmost))
    }

    /// Below `minimumSize` a window only counts once nothing else qualified: a
    /// helper sliver must not take the cutout, but a genuinely small window must
    /// not leave the desktop with nothing to focus either — losing the blur
    /// entirely being the failure this app must never take.
    func testSmallWindowIsOnlyAFallback() {
        let tiny = candidate(id: 1, pid: frontmost, layer: 0, rect: CGRect(x: 0, y: 0, width: 90, height: 60))
        let normal = candidate(id: 2, pid: other, layer: 0, rect: window)
        // A sizeable window wins over a sliver in front of it…
        XCTAssertEqual(FocusTracker.preferred([tiny, normal], frontmostPID: frontmost)?.windowID, 2)
        // …and once it is alone, it is still better than no focus at all.
        XCTAssertEqual(FocusTracker.preferred([tiny], frontmostPID: frontmost)?.windowID, 1)
    }
}

@MainActor
final class CoverageTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testWindowWellInsideCounts() {
        XCTAssertTrue(PrivacyController.covers(CGRect(x: 100, y: 100, width: 400, height: 300), in: bounds))
    }

    /// A sub-point sliver must not count: treating it as coverage would rebuild
    /// that display's expensive shareable-content filter on every jitter of a
    /// window edge sitting on the boundary.
    func testHairlineOverlapDoesNotCount() {
        XCTAssertFalse(PrivacyController.covers(CGRect(x: 999.5, y: 100, width: 100, height: 200), in: bounds))
    }

    func testWindowOnAnotherDisplayDoesNotCount() {
        XCTAssertFalse(PrivacyController.covers(CGRect(x: 2000, y: 0, width: 200, height: 200), in: bounds))
    }

    /// A window straddling the boundary overlaps this display substantially, so
    /// it does count — that is what makes both displays cut a hole.
    func testStraddlingWindowCounts() {
        XCTAssertTrue(PrivacyController.covers(CGRect(x: 800, y: 100, width: 600, height: 400), in: bounds))
    }
}
