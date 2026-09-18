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

/// The even-odd trap, the roundness of the cursor disc, and the display it
/// belongs to. Everything here is pure geometry: no display, no window server,
/// no Screen Recording permission.
@MainActor
final class RevealTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)
    private let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    /// `true` when the blur covers it, `false` when something is revealed there.
    /// Takes a **top-left** point and flips it the way `CALayer` wants it.
    private func blurred(_ point: CGPoint, reveal: Reveal, radius: CGFloat = 18) -> Bool {
        BlurOverlay.maskPath(screen: screen, reveal: reveal, cornerRadius: radius)
            .contains(CGPoint(x: point.x, y: screen.height - point.y), using: .evenOdd)
    }

    /// The whole path, sampled, so two reveals can be compared for sameness
    /// without pretending `CGPath` is `Equatable`.
    private func sampled(_ reveal: Reveal, step: CGFloat = 20) -> String {
        let path = BlurOverlay.maskPath(screen: screen, reveal: reveal, cornerRadius: 18)
        var rows: [String] = []
        var y: CGFloat = 0
        while y < screen.height {
            var row = ""
            var x: CGFloat = 0
            while x < screen.width {
                row += path.contains(CGPoint(x: x, y: y), using: .evenOdd) ? "1" : "0"
                x += step
            }
            rows.append(row)
            y += step
        }
        return rows.joined(separator: "/")
    }

    private func disc(centre: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }

    func testNothingRevealedBlursEverything() {
        XCTAssertTrue(blurred(CGPoint(x: 500, y: 400), reveal: .none))
        XCTAssertTrue(blurred(CGPoint(x: 1, y: 1), reveal: .none))
    }

    /// Two holes that do not touch behave exactly like one of them being there
    /// alone — checked here because it is the case a union could plausibly get
    /// wrong after unioning.
    func testSeparateHolesBothStaySharp() {
        let reveal = Reveal(window: window, cursor: disc(centre: CGPoint(x: 700, y: 550), radius: 80))
        XCTAssertFalse(blurred(CGPoint(x: 300, y: 250), reveal: reveal), "the window's cutout")
        XCTAssertFalse(blurred(CGPoint(x: 700, y: 550), reveal: reveal), "the cursor's disc")
        XCTAssertTrue(blurred(CGPoint(x: 550, y: 300), reveal: reveal), "the blur between them")
        XCTAssertTrue(blurred(CGPoint(x: 900, y: 750), reveal: reveal), "the blur outside them")
    }

    /// The regression this guards, and the one real trap in having a second
    /// revealed shape.
    ///
    /// Even-odd is an exclusive-or. A point lying in *both* holes crosses three
    /// boundaries and therefore reads as inside the mask, so the overlap is
    /// blurred back over: a lens of haze straddling the window's edge, appearing
    /// every time the cursor crosses it. Adding two separate subpaths instead of
    /// their union is what produces it.
    func testOverlappingHolesDoNotCancelEachOtherOut() {
        // Straddles the window's right edge, which is where the cursor spends
        // its time — changing a window's size, reaching for a scrollbar.
        let reveal = Reveal(window: window, cursor: disc(centre: CGPoint(x: 500, y: 300), radius: 100))
        XCTAssertFalse(blurred(CGPoint(x: 470, y: 300), reveal: reveal), "inside both")
        XCTAssertFalse(blurred(CGPoint(x: 520, y: 300), reveal: reveal), "inside both, past the edge")
        XCTAssertFalse(blurred(CGPoint(x: 450, y: 250), reveal: reveal), "inside both, upper corner")
        XCTAssertFalse(blurred(CGPoint(x: 555, y: 300), reveal: reveal), "inside the disc alone")
        XCTAssertFalse(blurred(CGPoint(x: 300, y: 250), reveal: reveal), "inside the window alone")
        XCTAssertTrue(blurred(CGPoint(x: 700, y: 300), reveal: reveal), "outside both")
    }

    /// A third shape joins the set — this app's own Settings window — and the
    /// rule has to keep holding: the mask deals in sets, so the union has to
    /// take all three, not just the first two it met.
    func testOwnWindowOverlappingBothStaysSharp() {
        let reveal = Reveal(
            window: window,
            cursor: disc(centre: CGPoint(x: 500, y: 300), radius: 100),
            ownWindow: CGRect(x: 420, y: 220, width: 260, height: 200)
        )
        XCTAssertFalse(blurred(CGPoint(x: 500, y: 300), reveal: reveal), "in all three")
        XCTAssertFalse(blurred(CGPoint(x: 470, y: 260), reveal: reveal), "in window and own window")
        XCTAssertFalse(blurred(CGPoint(x: 560, y: 380), reveal: reveal), "in cursor and own window")
        XCTAssertFalse(blurred(CGPoint(x: 640, y: 400), reveal: reveal), "in own window alone")
        XCTAssertTrue(blurred(CGPoint(x: 850, y: 650), reveal: reveal), "outside everything")
    }

    /// A disc entirely inside the window changes nothing at all — the whole point
    /// of unioning rather than punching a second hole.
    func testDiscInsideTheWindowChangesNothing() {
        let contained = Reveal(window: window, cursor: disc(centre: CGPoint(x: 300, y: 250), radius: 40))
        XCTAssertEqual(sampled(contained), sampled(Reveal(window: window)))
    }

    /// The other direction: a disc big enough to swallow the window leaves only
    /// the disc revealed, window included. Neither one may survive as a shape of
    /// its own and re-blur a patch inside the other.
    ///
    /// The window sits near the middle here on purpose. An earlier version used
    /// one whose left edge poked out past the circle, which silently turned this
    /// into a *different* test — unioning correctly draws their combination, and
    /// the assertion was comparing that against part of it.
    func testWindowInsideTheDiscChangesNothing() {
        let around = disc(centre: CGPoint(x: 450, y: 400), radius: 300)
        let devoured = Reveal(window: CGRect(x: 380, y: 320, width: 100, height: 80), cursor: around)
        // Every corner really is inside, so nothing of the window can survive.
        for corner in [
            CGPoint(x: 380, y: 320), CGPoint(x: 480, y: 320),
            CGPoint(x: 480, y: 400), CGPoint(x: 380, y: 400),
        ] {
            let distance = hypot(corner.x - 450, corner.y - 400)
            XCTAssertLessThan(distance, 300, "corner at \(corner) must be swallowed")
        }
        XCTAssertEqual(sampled(devoured), sampled(Reveal(cursor: around)))
    }

    /// The disc must not be clipped to the display before an ellipse is
    /// inscribed in it: near an edge that turns a circle into an egg, and the
    /// flat side sits where the cursor is busiest. (The overlay's own bounds do
    /// the clipping, which is the honest place for it.)
    func testDiscStaysRoundWhenItOverhangsTheEdge() {
        let reveal = Reveal(cursor: disc(centre: CGPoint(x: 10, y: 400), radius: 100))
        // Would be outside a box clipped to x ≥ 0, still well inside the circle.
        XCTAssertFalse(blurred(CGPoint(x: 2, y: 470), reveal: reveal))
        XCTAssertFalse(blurred(CGPoint(x: 2, y: 400), reveal: reveal))
        XCTAssertTrue(blurred(CGPoint(x: 200, y: 470), reveal: reveal), "outside the circle")
    }

    /// Where the disc is drawn, and how big. Split out as a pure function so
    /// this can be asked without a display attached.
    func testCursorHoleIsLocalAndSquare() {
        let bounds = CGRect(x: 1000, y: 0, width: 1024, height: 768)
        let hole = PrivacyController.cursorHole(point: CGPoint(x: 1500, y: 300), in: bounds, radius: 60)
        XCTAssertEqual(hole, CGRect(x: 440, y: 240, width: 120, height: 120))
    }

    /// Only one display may draw it. Each overlay is one screen with its own
    /// layer tree, so two halves clipped independently are not a whole disc.
    func testCursorOffThisDisplayDrawsNothing() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertNil(PrivacyController.cursorHole(point: CGPoint(x: 1200, y: 400), in: bounds, radius: 60))
        XCTAssertNil(PrivacyController.cursorHole(point: CGPoint(x: 500, y: 900), in: bounds, radius: 60))
        // A negative origin is how most arrangements look.
        XCTAssertNil(PrivacyController.cursorHole(point: CGPoint(x: -400, y: 400), in: bounds, radius: 60))
    }

    /// Halves are exclusive at a seam, so every position belongs to exactly one
    /// display: the right-hand one owns the shared column.
    func testCursorExactlyOnASeamBelongsToOneDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let seam = CGPoint(x: 1000, y: 400)
        XCTAssertNil(PrivacyController.cursorHole(point: seam, in: left, radius: 60))
        XCTAssertEqual(
            PrivacyController.cursorHole(point: seam, in: right, radius: 60),
            CGRect(x: -60, y: 340, width: 120, height: 120)
        )
    }

    /// No reading, no disc. Guessing the last position would park a sharp circle
    /// over pixels nobody asked to see.
    func testUnknownCursorPositionDrawsNothing() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertNil(PrivacyController.cursorHole(point: nil, in: bounds, radius: 60))
        XCTAssertNil(PrivacyController.cursorHole(point: CGPoint(x: 500, y: 400), in: bounds, radius: 0))
    }

    /// Sub-point jitter must not rebuild a path sixty times a second, but real
    /// movement — including a changed radius — has to.
    func testSameRevealToleratesSubPointJitter() {
        let base = Reveal(window: window, cursor: disc(centre: CGPoint(x: 500, y: 500), radius: 120))
        let jittered = Reveal(window: window, cursor: disc(centre: CGPoint(x: 500.4, y: 500.3), radius: 120))
        XCTAssertTrue(BlurOverlay.sameReveal(base, jittered))
        XCTAssertFalse(
            BlurOverlay.sameReveal(base, Reveal(window: window, cursor: disc(centre: CGPoint(x: 501, y: 500), radius: 120)))
        )
        XCTAssertFalse(
            BlurOverlay.sameReveal(base, Reveal(window: window, cursor: disc(centre: CGPoint(x: 500, y: 500), radius: 200)))
        )
        XCTAssertFalse(BlurOverlay.sameReveal(base, Reveal(window: window)))
        XCTAssertTrue(BlurOverlay.sameReveal(base, base))
    }
}

/// Only a focus *switch* may animate the cutout. A drag is a stream of tiny
/// deltas; interpolating any of them would leave the cutout trailing behind
/// the window it exists to hug.
final class JumpTests: XCTestCase {
    private let here = CGRect(x: 100, y: 100, width: 600, height: 400)

    func testSubPointDriftIsNotAJump() {
        let next = CGRect(x: 100.4, y: 100.3, width: 600, height: 400)
        XCTAssertFalse(BlurOverlay.isJump(from: here, to: next))
    }

    func testAFastDragFrameIsStillNotAJump() {
        // ~2000 pt/s at 60 Hz is about 33 pt per frame — faster than anyone
        // drags with intent, and it must stay unanimated.
        let next = here.offsetBy(dx: 33, dy: 0)
        XCTAssertFalse(BlurOverlay.isJump(from: here, to: next))
    }

    func testALeapToAnotherWindowIsAJump() {
        let elsewhere = CGRect(x: 1100, y: 300, width: 500, height: 350)
        XCTAssertTrue(BlurOverlay.isJump(from: here, to: elsewhere))
    }

    func testMaximisingInPlaceIsAJump() {
        // The centre barely moves when a window fills its display, but the
        // corners travel most of the screen — the resize fraction is what
        // catches this one.
        let maximised = CGRect(x: 0, y: 0, width: 1512, height: 900)
        XCTAssertTrue(BlurOverlay.isJump(from: here, to: maximised))
    }

    func testAppearingOrVanishingIsNeverAJump() {
        XCTAssertFalse(BlurOverlay.isJump(from: nil, to: here))
        XCTAssertFalse(BlurOverlay.isJump(from: here, to: nil))
        XCTAssertFalse(BlurOverlay.isJump(from: nil, to: nil))
    }
}

/// The fallback backend has no radius to set — only named system materials —
/// so a requested radius maps onto the nearest preset. The mapping has to keep
/// growing with the radius and never regress between neighbouring steps.
final class VibrancyMaterialTests: XCTestCase {
    func testRadiusMapsToAMaterial() {
        let materials = [
            BlurOverlay.vibrancyMaterial(forRadius: 5),
            BlurOverlay.vibrancyMaterial(forRadius: 15),
            BlurOverlay.vibrancyMaterial(forRadius: 30),
            BlurOverlay.vibrancyMaterial(forRadius: 55),
        ]
        // Four distinct bands, and each band's representative is distinct from
        // the others: a mapping that collapsed two bands would make a third of
        // the slider do nothing at all.
        XCTAssertEqual(Set(materials).count, 4)
    }

    func testStrongerRadiusNeverPicksAWeakerBand() {
        // Band boundaries are fixed, so crossing one can only move forward in
        // the switch's order — assert the neighbours land in the expected band
        // rather than comparing raw cases, which would couple the test to the
        // Material enum's own ordering.
        let weak = BlurOverlay.vibrancyMaterial(forRadius: 5)
        let strong = BlurOverlay.vibrancyMaterial(forRadius: 55)
        XCTAssertNotEqual(weak, strong)
        XCTAssertEqual(weak, BlurOverlay.vibrancyMaterial(forRadius: 11.9))
        XCTAssertEqual(strong, BlurOverlay.vibrancyMaterial(forRadius: 40))
    }
}

/// The window that has to stay readable: this app's own.
@MainActor
final class OwnWindowTests: XCTestCase {
    /// AppKit measures from the primary display's bottom-left, the window server
    /// from its top-left. A window sitting in the primary's top-left corner is
    /// the same rectangle in both, and is where a mistake shows up first.
    func testWindowAtTheTopOfThePrimaryDisplay() {
        let converted = PrivacyController.convertToCGCoordinates(
            NSRect(x: 0, y: 800, width: 200, height: 100),
            primaryHeight: 900
        )
        XCTAssertEqual(converted, CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    /// A display stacked above the primary has a *negative* top-left Y; AppKit
    /// reports it as a larger, positive Y. Getting this wrong puts the settings
    /// window's cutout on the wrong screen entirely.
    func testWindowOnADisplayAboveThePrimary() {
        let converted = PrivacyController.convertToCGCoordinates(
            NSRect(x: 0, y: 900, width: 1920, height: 1080),
            primaryHeight: 900
        )
        XCTAssertEqual(converted, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    /// X is untouched, including to the left of the primary, where both systems
    /// agree it is negative.
    func testHorizontalOriginPassesThrough() {
        let converted = PrivacyController.convertToCGCoordinates(
            NSRect(x: -1920, y: 0, width: 1920, height: 1080),
            primaryHeight: 1080
        )
        XCTAssertEqual(converted.origin.x, -1920)
        XCTAssertEqual(converted.origin.y, 0)
    }

    /// Nothing sensible to flip about: hand the frame back untouched rather than
    /// inventing a height.
    func testNoKnownPrimaryHeightKeepsTheFrame() {
        let frame = NSRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(PrivacyController.convertToCGCoordinates(frame, primaryHeight: 0), frame)
    }
}

/// Searching the settings window.
final class SettingsSearchTests: XCTestCase {
    /// Empty search shows everything.
    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(settingsSearchMatch("模糊 blur", search: ""))
    }

    /// Tokens are independent, and order does not matter: typing the two words
    /// the way you think of them has to work.
    func testEveryTokenMustAppear() {
        XCTAssertTrue(settingsSearchMatch("菜单栏 dock 清晰", search: "dock 菜单栏"))
        XCTAssertFalse(settingsSearchMatch("菜单栏 dock 清晰", search: "dock 全屏"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(settingsSearchMatch("Screen Recording 屏幕录制", search: "screen"))
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
