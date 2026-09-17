import AppKit
import CoreGraphics
import QuartzCore

/// A borderless window above everything. It never takes focus and never takes
/// clicks, so the focused window revealed through the hole stays interactive.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A full-screen blurred picture of one display, with a transparent rectangular
/// hole punched where the focused window sits.
///
/// Content and cutout are deliberately committed together by `commit(hole:)`
/// from a single display-link tick. The old design updated the picture and the
/// mask from two independent timers, so the layer tree was routinely committed
/// half-updated: a fresh picture with a stale hole, or the other way round.
/// That mismatch is what read as "the cutout and the background are not part of
/// the same frame".
@MainActor
final class BlurOverlay {
    let window: OverlayWindow

    private let hostLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let screen: NSScreen
    /// Concentric rings drawn just outside the cutout. They live *inside* the
    /// masked layer, so the even-odd mask clips them to the blurred area —
    /// they can never spill over the sharp window.
    private let edgeLayers: [CAShapeLayer]

    /// A blurred picture waiting for the next display-link tick.
    private var pendingPicture: CGImage?
    private var pendingScale: CGFloat = 1
    /// Brightness outside the cutout from the last picture, smoothed so a
    /// momentary sample cannot flip the edge colour.
    private var surroundLuminance: CGFloat?
    /// Which side of the luminance threshold the edge is currently on. Kept
    /// across frames so a mid-grey background has to clearly cross over before
    /// the edge changes tone — otherwise it would flip every other frame.
    private var edgeIsDark: Bool?
    /// Whether a blurred picture is actually on screen. The edge is only drawn
    /// on top of one; drawing it before would leave a bare rounded outline
    /// floating over the sharp desktop during the first frames after enabling.
    private var hasPicture = false
    /// The hole last pushed to the mask, so an unchanged cutout costs nothing.
    private var committedHole: CGRect?
    private var hasCommittedHole = false

    /// - Parameter animateAppearance: fades the overlay in. Only right when
    ///   the effect is being switched on; a display change replaces the
    ///   overlays while the effect is already visible, and fading in from
    ///   empty would flash the sharp desktop for a quarter of a second.
    init(screen: NSScreen, animateAppearance: Bool = true) {
        self.screen = screen

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Self.shieldingLevel)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        hostLayer.frame = view.bounds
        hostLayer.contentsGravity = .resize
        hostLayer.mask = maskLayer
        // A layer created in code defaults to a contentsScale of 1, which would
        // rasterize the cutout's edges at half the display's resolution and
        // leave them visibly soft against the sharp window behind them.
        maskLayer.contentsScale = screen.backingScaleFactor
        view.layer = hostLayer

        edgeLayers = (0..<Self.edgeRingCount).map { _ in CAShapeLayer() }
        for layer in edgeLayers {
            // Frames are per-ring and set in `updateEdge`; start empty so
            // nothing is allocated until a ring actually needs drawing.
            layer.frame = .zero
            layer.contentsScale = screen.backingScaleFactor
            layer.fillColor = nil
            layer.lineWidth = Self.edgeRingWidth
            hostLayer.addSublayer(layer)
        }

        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.alphaValue = animateAppearance ? 0 : 1
        window.orderFrontRegardless()
        self.window = window

        guard animateAppearance else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Radius (points) of the focus-window cutout corners. macOS does not
    /// expose a window's true corner radius, so this is a close approximation
    /// that makes the clear hole hug standard rounded document windows.
    var cornerRadius: CGFloat = 18

    /// Stages a freshly blurred picture. It is not shown until the next
    /// `commit(hole:)`, which pairs it with the cutout position of that very
    /// frame.
    func setPicture(_ frame: BlurredFrame) {
        pendingPicture = frame.image
        pendingScale = frame.scale
        // The edge colour only needs to track slow changes in the background,
        // and a raw per-frame sample would make it flicker on busier desktops.
        if let sample = frame.surroundLuminance {
            surroundLuminance = surroundLuminance.map { $0 * 0.8 + sample * 0.2 } ?? sample
        }
    }

    /// Commits the pending picture and the cutout in one transaction.
    ///
    /// Called once per display link — i.e. in lockstep with the compositor — so
    /// the hole can never show a frame ahead of (or behind) the picture.
    /// `hole` is a top-left local rectangle (in points); `nil` or empty blurs
    /// the whole screen.
    func commit(hole: NSRect?) {
        let holeChanged = !hasCommittedHole || !Self.sameHole(committedHole, hole)
        guard holeChanged || pendingPicture != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var pictureArrived = false
        if let picture = pendingPicture {
            hostLayer.contents = picture
            hostLayer.contentsScale = pendingScale
            hostLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
            pendingPicture = nil
            pictureArrived = true
            hasPicture = true
        }
        if holeChanged {
            maskLayer.path = Self.maskPath(
                screen: screen.frame.size,
                hole: hole,
                cornerRadius: cutoutCornerRadius(for: hole)
            )
            maskLayer.fillRule = .evenOdd
            maskLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
            committedHole = hole
            hasCommittedHole = true
        }
        // The edge follows the cutout, and its colour follows the background —
        // so it is refreshed when either one changed.
        if holeChanged || pictureArrived {
            updateEdge(hole: hole)
        }
        CATransaction.commit()
    }

    /// Drops all content and the mask so the overlay renders nothing — the
    /// screen shows through fully sharp. Used when there is no window to focus
    /// (an otherwise-empty desktop).
    func clear() {
        pendingPicture = nil
        committedHole = nil
        hasCommittedHole = false
        hasPicture = false
        // Both halves of the edge's memory go together: keeping the hysteresis
        // seed while throwing away the brightness it was derived from lets a
        // previous desktop decide the edge tone for the next one.
        surroundLuminance = nil
        edgeIsDark = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.contents = nil
        maskLayer.path = nil
        for layer in edgeLayers { layer.path = nil }
        CATransaction.commit()
    }

    /// Draws a soft band around the cutout so the sharp window reads as a
    /// surface sitting above the blur.
    ///
    /// The focused window is excluded from the screenshot, and so is its drop
    /// shadow, so a window whose colours match what is behind it has no visible
    /// boundary at all — a white window on a white background simply dissolves
    /// into the blur. Real windows always cast a shadow, and restoring that
    /// cue is what makes the edge legible.
    ///
    /// The band is built from a few concentric stroked rings of decreasing
    /// opacity, which fades it outward without needing a gradient layer — and
    /// because the rings live inside the masked layer, the even-odd mask clips
    /// them to the outside of the hole, so nothing is ever drawn over the sharp
    /// window itself.
    private func updateEdge(hole: NSRect?) {
        guard let hole, !hole.isEmpty, hasPicture, surroundLuminance != nil else {
            // No honest reading of the surroundings for this frame — because
            // there is no cutout (the focus moved to another display), no
            // picture yet, or whatever sample we had belongs to a frame that
            // is no longer on screen.
            //
            // The stale value has to be dropped rather than kept: a sample
            // taken minutes ago, or one taken while the window was a different
            // size, tints the edge wrongly — and if it happens to be close to
            // the background the edge disappears entirely. Hysteresis would
            // then hold that wrong choice until the background clearly crossed
            // the threshold, so it would not self-correct.
            surroundLuminance = nil
            edgeIsDark = nil
            for layer in edgeLayers { layer.path = nil }
            return
        }
        let flipped = Self.flipped(hole, in: screen.frame.size)
        let visible = CGRect(origin: .zero, size: screen.frame.size)
        let base = edgeTone() ? NSColor.black : NSColor.white
        let corner = cutoutCornerRadius(for: hole)

        for (index, layer) in edgeLayers.enumerated() {
            // Ring `index` covers the band `index·w … (index+1)·w` outward from
            // the cutout, so the innermost edge sits exactly on the boundary.
            let outset = (CGFloat(index) + 0.5) * Self.edgeRingWidth
            let ring = flipped.insetBy(dx: -outset, dy: -outset)
            // Keep each layer's bounds to the ring's own footprint rather than
            // the whole screen: a full-screen shape layer per ring would cost a
            // full-screen surface each.
            let frame = ring.insetBy(dx: -Self.edgeRingWidth / 2, dy: -Self.edgeRingWidth / 2)
                .intersection(visible)
            guard frame.width > 0, frame.height > 0 else {
                layer.path = nil
                continue
            }
            let local = CGRect(
                x: ring.origin.x - frame.origin.x,
                y: ring.origin.y - frame.origin.y,
                width: ring.width,
                height: ring.height
            )
            let radius = min(corner + outset, min(local.width, local.height) / 2)
            layer.frame = frame
            layer.path = CGPath(
                roundedRect: local,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            layer.strokeColor = base.withAlphaComponent(Self.edgeRingAlphas[index]).cgColor
        }
    }

    /// Corner radius to cut the hole with.
    ///
    /// A full-screen window fills the display with **square** corners, so a
    /// rounded cutout leaves four blurred wedges sitting on top of its corners
    /// — very visible, and permanent once the window stops being captured.
    private func cutoutCornerRadius(for hole: NSRect?) -> CGFloat {
        guard let hole, !hole.isEmpty else { return cornerRadius }
        let size = screen.frame.size
        if hole.width >= size.width - 1, hole.height >= size.height - 1 { return 0 }
        return cornerRadius
    }

    /// Whether the edge should be dark. Held with hysteresis so a background
    /// sitting near the threshold cannot flip the whole edge every frame.
    private func edgeTone() -> Bool {
        // Reaching here with no sample means the caller is about to be turned
        // away anyway; never fall back on a remembered seed.
        guard let luminance = surroundLuminance else { return true }
        let dark: Bool
        if let current = edgeIsDark {
            dark = current ? luminance >= Self.lightBelow : luminance > Self.darkAbove
        } else {
            dark = luminance >= 0.5
        }
        edgeIsDark = dark
        return dark
    }

    /// Switches the overlay's window level. At the shielding level the overlay
    /// sits above the menu bar and Dock, so the system hides them and they are
    /// blurred as part of the picture. When `chrome` is cleared we drop the
    /// overlay *below* the Dock and menu bar (but still above ordinary windows)
    /// so those system UI elements keep rendering on top, crisp and untouched.
    func setChromeClear(_ on: Bool) {
        window.level = NSWindow.Level(rawValue: on ? Self.chromeClearLevel : Self.shieldingLevel)
    }

    private static let shieldingLevel = Int(CGShieldingWindowLevel())
    // Above normal app windows (0) yet below the Dock (20) and menu bar (24),
    // so the blur still covers every app window while letting system chrome
    // paint on top in the "keep clear" mode.
    private static let chromeClearLevel = 15

    /// Number, thickness and opacity of the rings making up the cutout's edge.
    /// Six thin rings on an exponential falloff over 12pt: dense enough to
    /// read as a shadow rather than a stroked border, since a hard plateau
    /// right at the edge is exactly what makes a ring look like an outline.
    ///
    /// Deliberately faint. The job is only to separate a window from a
    /// similarly coloured background — anything stronger starts to look like a
    /// drawn border around every window.
    private static let edgeRingCount = 6
    private static let edgeRingWidth: CGFloat = 2
    private static let edgeRingAlphas: [CGFloat] = [0.15, 0.10, 0.067, 0.045, 0.030, 0.020]
    /// Hysteresis band for the edge tone: switch to dark above `darkAbove`,
    /// back to light below `lightBelow`, hold in between.
    private static let darkAbove: CGFloat = 0.55
    private static let lightBelow: CGFloat = 0.45

    private static func sameHole(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return lhs == rhs
        default: return false
        }
    }

    /// `hole` arrives in top-left local coordinates (the same space as
    /// `CGWindowList` and the screenshot), but `CALayer` geometry uses a
    /// bottom-left origin — without flipping Y the hole renders vertically
    /// mirrored, moving down while the window moves up.
    private static func flipped(_ hole: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: hole.origin.x,
            y: size.height - hole.maxY,
            width: hole.width,
            height: hole.height
        )
    }

    /// An even-odd path covering the whole screen with the cutout subtracted.
    private static func maskPath(screen: CGSize, hole: NSRect?, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screen))
        if let hole, !hole.isEmpty {
            let flipped = Self.flipped(hole, in: screen)
            let cr = min(cornerRadius, min(flipped.width, flipped.height) / 2)
            path.addRoundedRect(in: flipped, cornerWidth: cr, cornerHeight: cr)
        }
        return path
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
