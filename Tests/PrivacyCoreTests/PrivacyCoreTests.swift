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

    /// Never upsample: the divisor is always at least 1.
    func testNeverUpsamples() {
        for width in [800, 1600, 1920, 5120, 8000] {
            let divisor = ScreenCapturer.divisor(forNativeWidth: CGFloat(width), downscaleDisabled: false)
            XCTAssertGreaterThanOrEqual(divisor, 1)
            XCTAssertLessThanOrEqual(divisor, 4)
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
