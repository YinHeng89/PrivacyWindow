import AppKit
import CoreGraphics
import QuartzCore

/// A borderless window above everything. It never takes focus and never takes
/// clicks, so the focused window revealed through the hole stays interactive.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What one overlay leaves sharp for one frame.
///
/// Named for what it does rather than for what it is: an overlay does not have
/// "a hole" any more, it has a *set* of places the blur is not allowed to cover.
/// Giving it a third member — around the text caret, say — means a field here
/// and nothing else, because the mask already deals in sets.
///
/// Coordinates are overlay-local points with a top-left origin, the same space
/// as `CGWindowList` and `CGDisplayBounds`.
struct Reveal: Equatable {
    /// The focused window's cutout.
    ///
    /// This is the only member the edge shadow is drawn around, and that is not
    /// an oversight: the shadow stands in for the drop shadow a window loses by
    /// being excluded from the screenshot. Neither of the others is standing in
    /// for anything, so tracing one would drag a grey ring around every mouse
    /// movement — or put a halo on the app's own settings window.
    var window: CGRect?
    /// The disc around the cursor, as its **bounding square**.
    ///
    /// The mask inscribes an ellipse in it, so the box has to stay square even
    /// when half the disc lies off this display — clamping it to the screen
    /// would squash the near edge of the circle into a straight-ish line. The
    /// overlay's own bounds do whatever clipping there is left to do.
    var cursor: CGRect?
    /// One of *our own* windows that the overlay would otherwise cover — the
    /// Settings window, in practice.
    ///
    /// The overlay sits above every ordinary window, including the ones this app
    /// puts on screen, so without this you would open Settings and find it
    /// sitting behind its own blur. Cutting them out is also why the settings
    /// window does not need a window level above the overlay, which is what
    /// breaks macOS's own screenshot tool for certain windows.
    var ownWindow: CGRect?

    /// Nothing revealed: the whole screen stays blurred.
    static let none = Reveal()
}

/// A full-screen blurred picture of one display, with a transparent rectangular
/// hole punched where the focused window sits.
///
/// Content and cutout are deliberately committed together by `commit(reveal:)`
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
    /// Present only in the vibrancy fallback: the compositor's own blur,
    /// standing in for a captured picture.
    private let vibrancyView: NSVisualEffectView?
    /// Whether this overlay draws a captured picture (`false`) or system blur
    /// (`true`). Decides what `setPicture` means and whether an edge can be
    /// drawn at all — with no pixels in hand there is nothing to sample a
    /// luminance from.
    private let usesVibrancy: Bool
    private let screen: NSScreen
    /// Concentric rings drawn just outside the cutout. They live *inside* the
    /// masked layer, so the even-odd mask clips them to the blurred area —
    /// they can never spill over the sharp window.
    private let edgeLayers: [CAShapeLayer]

    /// A blurred picture waiting for the next display-link tick.
    private var pendingPicture: CGImage?
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
    /// The reveal last pushed to the mask, so an unchanged one costs nothing.
    private var committedReveal: Reveal?
    private var hasCommittedReveal = false

    /// - Parameters:
    ///   - animateAppearance: fades the overlay in. Only right when the effect
    ///     is being switched on; a display change replaces the overlays while
    ///     the effect is already visible, and fading in from empty would flash
    ///     the sharp desktop for a quarter of a second.
    ///   - vibrancy: run on **system blur** (`NSVisualEffectView`) rather than
    ///     on captured pixels. Used when Screen Recording has not been granted:
    ///     the compositor blurs whatever is behind this window and needs no
    ///     permission, so the effect still works — just coarser, with the
    ///     strength chosen from the system's material presets instead of the
    ///     user's radius. See the fallback notes in `PrivacyController`.
    init(screen: NSScreen, animateAppearance: Bool = true, vibrancy: Bool = false, blurRadius: Double = 20) {
        self.screen = screen
        usesVibrancy = vibrancy

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

        if vibrancy {
            // The compositor's blur, sampled from whatever sits behind this
            // window. Masked with the very same even-odd shape the captured
            // picture is masked with, so every reveal rule — focus window,
            // cursor disc, own windows, the union fix — is shared by both
            // backends and none of it is written twice.
            let effect = NSVisualEffectView(frame: view.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.blendingMode = .behindWindow
            effect.material = Self.vibrancyMaterial(forRadius: blurRadius)
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.layer?.mask = maskLayer
            // Same reason as the captured branch below: a mask at its default
            // scale of 1 rasterizes the cutout's edges at half the display's
            // resolution, and soft edges against a sharp window read as dirt.
            maskLayer.contentsScale = screen.backingScaleFactor
            maskLayer.frame = view.bounds
            view.addSubview(effect)
            vibrancyView = effect
        } else {
            vibrancyView = nil
            hostLayer.frame = view.bounds
            hostLayer.contentsGravity = .resize
            hostLayer.mask = maskLayer
            // A layer created in code defaults to a contentsScale of 1, which would
            // rasterize the cutout's edges at half the display's resolution and
            // leave them visibly soft against the sharp window behind them.
            hostLayer.contentsScale = screen.backingScaleFactor
            maskLayer.contentsScale = screen.backingScaleFactor
            view.layer = hostLayer
        }

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

    /// The system material whose blur comes closest to a requested radius.
    ///
    /// `NSVisualEffectView` has no radius to set — only named materials, whose
    /// strength is the system's to define and does drift between releases. The
    /// mapping is therefore an approximation by design, and the settings window
    /// says so rather than implying the slider means the same thing it means in
    /// the captured mode.
    nonisolated static func vibrancyMaterial(forRadius radius: Double) -> NSVisualEffectView.Material {
        switch radius {
        case ..<12: return .hudWindow
        case ..<25: return .underWindowBackground
        case ..<40: return .fullScreenUI
        default: return .menu
        }
    }

    /// Radius (points) of the focus-window cutout corners.
    ///
    /// macOS does not expose a window's true corner radius, so this is an
    /// empirical value tuned by eye. It has to sit close enough to the real
    /// corner that the hole hugs the window, and it fails in two opposite
    /// directions: too large and the blur covers the window's own corners, which
    /// reads as the corners being bitten off; too small and a blurred wedge is
    /// left sitting on each of them.
    var cornerRadius: CGFloat = 18

    /// Stages a freshly blurred picture. It is not shown until the next
    /// `commit(reveal:)`, which pairs it with the revealed shapes of that very
    /// frame.
    ///
    /// A no-op in vibrancy mode: there is no capture loop to produce a picture,
    /// and the system material already owns the backdrop.
    func setPicture(_ frame: BlurredFrame) {
        guard !usesVibrancy else { return }
        pendingPicture = frame.image
        // The edge colour only needs to track slow changes in the background,
        // and a raw per-frame sample would make it flicker on busier desktops.
        if let sample = frame.surroundLuminance {
            surroundLuminance = surroundLuminance.map { $0 * 0.8 + sample * 0.2 } ?? sample
        }
    }

    /// Retunes the system material after a blur-radius change. Only meaningful
    /// in vibrancy mode; the captured backend applies the radius in the blur
    /// itself.
    func setBlurRadius(_ radius: Double) {
        guard let vibrancyView else { return }
        vibrancyView.material = Self.vibrancyMaterial(forRadius: radius)
    }

    /// Commits the pending picture and the revealed shapes in one transaction.
    ///
    /// Called once per display link — i.e. in lockstep with the compositor — so
    /// nothing here can show a frame ahead of (or behind) the picture. Both
    /// members of `reveal` are overlay-local top-left rectangles (in points);
    /// empty ones are ignored.
    func commit(reveal: Reveal) {
        // One comparison covers the whole set, so a resting desktop and a still
        // cursor cost nothing at all — this is what keeps a second revealed
        // shape from quietly turning into sixty path rebuilds a second.
        let revealChanged = !hasCommittedReveal || !Self.sameReveal(committedReveal ?? .none, reveal)
        // Tracked separately, because the edge hangs off the window alone (see
        // `Reveal.window`) and must not be redrawn — six stroked rings — every
        // half-point the pointer travels.
        let windowChanged = !hasCommittedReveal || !Self.sameRect(committedReveal?.window, reveal.window)
        guard revealChanged || pendingPicture != nil else { return }
        // A jump is a focus *switch* — the cutout leaping from one window to
        // another — as opposed to the sub-point jitter of a window being dragged.
        // Only jumps animate: interpolating a drag would leave the cutout
        // trailing behind the very window it exists to hug.
        let jump = windowChanged && Self.isJump(from: committedReveal?.window, to: reveal.window)

        var pictureArrived = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let picture = pendingPicture {
            hostLayer.contents = picture
            hostLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
            pendingPicture = nil
            pictureArrived = true
            hasPicture = true
        }
        CATransaction.commit()

        if revealChanged {
            // The mask animates in its own transaction rather than sharing the
            // picture's: a `path` change is only interpolable with actions
            // enabled, and the picture must never animate — it arrives one
            // whole frame at a time.
            CATransaction.begin()
            if jump {
                CATransaction.setAnimationDuration(Self.jumpDuration)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            maskLayer.path = Self.maskPath(
                screen: screen.frame.size,
                reveal: reveal,
                cornerRadius: cutoutCornerRadius(for: reveal.window)
            )
            maskLayer.fillRule = .evenOdd
            maskLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
            committedReveal = reveal
            hasCommittedReveal = true
            CATransaction.commit()
        }
        // The edge follows the *window* — see `Reveal.window` — and its colour
        // follows the background, so it is refreshed when either one changed.
        if windowChanged || pictureArrived {
            updateEdge(hole: reveal.window, animated: jump)
        }
    }

    /// Drops all content and the mask so the overlay renders nothing — the
    /// screen shows through fully sharp. Used when there is no window to focus
    /// (an otherwise-empty desktop).
    func clear() {
        pendingPicture = nil
        committedReveal = nil
        hasCommittedReveal = false
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
    private func updateEdge(hole: NSRect?, animated: Bool = false) {
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in edgeLayers { layer.path = nil }
            CATransaction.commit()
            return
        }
        let flipped = Self.flipped(hole, in: screen.frame.size)
        let visible = CGRect(origin: .zero, size: screen.frame.size)
        let base = edgeTone() ? NSColor.black : NSColor.white
        let corner = cutoutCornerRadius(for: hole)

        // The rings ride along with an animated cutout: committing them with
        // actions disabled would leave a 12pt halo sitting at the old position
        // for the length of the transition, then snapping over.
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Self.jumpDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
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
            // Radii come from the ring's position on screen, not from the
            // layer-local rect: only the screen-space rect knows whether the
            // cutout is clipped by a display edge.
            let radii = Self.cornerRadii(for: ring, in: visible.size, radius: corner + outset)
            layer.frame = frame
            layer.path = Self.roundedRectPath(local, radii)
            layer.strokeColor = base.withAlphaComponent(Self.edgeRingAlphas[index]).cgColor
        }
        CATransaction.commit()
    }

    /// Whether the window cutout moved far enough to be a focus *switch* rather
    /// than a drag.
    ///
    /// Two signals, because a switch comes in two shapes. A move to another
    /// window elsewhere on screen shows up as centre travel; maximising or
    /// un-maximising in place barely moves the centre at all but sends the
    /// corners flying, so a large proportional resize counts too.
    ///
    /// The threshold has to clear the fastest ordinary drag: at 60 Hz a window
    /// dragged at ~2000 pt/s moves about 33 pt per tick, so anything below that
    /// would catch real drags and make the cutout lag behind its own window.
    nonisolated static func isJump(from: CGRect?, to: CGRect?) -> Bool {
        guard let from, let to, !from.isEmpty, !to.isEmpty else { return false }
        let centreTravel = hypot(from.midX - to.midX, from.midY - to.midY)
        if centreTravel > Self.jumpCentreThreshold { return true }
        return abs(from.width - to.width) > from.width * Self.jumpResizeFraction
            || abs(from.height - to.height) > from.height * Self.jumpResizeFraction
    }

    private static let jumpCentreThreshold: CGFloat = 64
    private static let jumpResizeFraction: CGFloat = 0.3
    /// How long a focus switch takes to slide the cutout across.
    private static let jumpDuration: CFTimeInterval = 0.24

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
    /// right at the edge is exactly what makes a ring look like a border.
    ///
    /// Deliberately faint. The job is only to separate a window from a
    /// similarly coloured background — anything stronger starts to look like a
    /// drawn border around every window.
    private static let edgeRingCount = 6
    private static let edgeRingWidth: CGFloat = 2
    private static let edgeRingAlphas: [CGFloat] = [0.15, 0.10, 0.067, 0.045, 0.030, 0.020]
    /// Corner radius used for *our own* windows, which AppKit draws much
    /// tighter than the one `cornerRadius` is tuned to match.
    private static let ownWindowCornerRadius: CGFloat = 12
    /// Hysteresis band for the edge tone: switch to dark above `darkAbove`,
    /// back to light below `lightBelow`, hold in between.
    private static let darkAbove: CGFloat = 0.55
    private static let lightBelow: CGFloat = 0.45

    /// Compares two reveals, and two rectangles, with tolerance.
    ///
    /// Both members come from live sources — the window server's idea of a
    /// window rectangle, the compositor's idea of where the pointer is — and
    /// both jitter by fractions of a point while nothing visible is happening.
    /// Rebuilding a path per jitter would undo the whole point of comparing
    /// before committing. Half a point is below a pixel on any display, and it
    /// cannot accumulate: the comparison is always against what was last
    /// committed, not against a drifting baseline.
    static func sameReveal(_ a: Reveal, _ b: Reveal) -> Bool {
        sameRect(a.window, b.window) && sameRect(a.cursor, b.cursor) &&
            sameRect(a.ownWindow, b.ownWindow)
    }

    private static let revealTolerance: CGFloat = 0.5

    private static func sameRect(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let lhs?, let rhs?):
            return abs(lhs.origin.x - rhs.origin.x) < revealTolerance &&
                   abs(lhs.origin.y - rhs.origin.y) < revealTolerance &&
                   abs(lhs.width - rhs.width) < revealTolerance &&
                   abs(lhs.height - rhs.height) < revealTolerance
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

    /// Per-corner radii for `rect`, with any corner sitting on a display edge
    /// squared off.
    ///
    /// A window spanning two displays is clipped by each display's boundary, so
    /// on each display the cutout has one straight edge at the seam. Rounding
    /// that edge too leaves a blurred wedge at the top and bottom of the seam
    /// — two of them meeting to form a visible notch right where the two halves
    /// should join seamlessly.
    ///
    /// Corners are named for what the user sees (`top` is the far edge from the
    /// origin in the layer's bottom-left space, i.e. `maxY`).
    struct CornerRadii {
        let bottomLeft: CGFloat
        let bottomRight: CGFloat
        let topRight: CGFloat
        let topLeft: CGFloat
    }

    static func cornerRadii(for rect: CGRect, in size: CGSize, radius: CGFloat) -> CornerRadii {
        let clamped = min(max(radius, 0), min(rect.width, rect.height) / 2)
        let atLeft = rect.minX <= 0.5
        let atRight = rect.maxX >= size.width - 0.5
        let atBottom = rect.minY <= 0.5
        let atTop = rect.maxY >= size.height - 0.5
        return CornerRadii(
            bottomLeft: atLeft || atBottom ? 0 : clamped,
            bottomRight: atRight || atBottom ? 0 : clamped,
            topRight: atRight || atTop ? 0 : clamped,
            topLeft: atLeft || atTop ? 0 : clamped
        )
    }

    /// A closed rounded-rectangle path with a radius per corner.
    ///
    /// `CGPath` only offers a single uniform radius, so the corners are drawn
    /// one at a time; a zero radius falls back to a plain corner rather than
    /// relying on how `addArc` treats a degenerate radius.
    private static func roundedRectPath(_ r: CGRect, _ radii: CornerRadii) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + radii.bottomLeft, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radii.bottomRight, y: r.minY))
        if radii.bottomRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: r.maxX, y: r.minY),
                tangent2End: CGPoint(x: r.maxX, y: r.minY + radii.bottomRight),
                radius: radii.bottomRight
            )
        } else {
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radii.topRight))
        if radii.topRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: r.maxX, y: r.maxY),
                tangent2End: CGPoint(x: r.maxX - radii.topRight, y: r.maxY),
                radius: radii.topRight
            )
        } else {
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
        path.addLine(to: CGPoint(x: r.minX + radii.topLeft, y: r.maxY))
        if radii.topLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: r.minX, y: r.maxY),
                tangent2End: CGPoint(x: r.minX, y: r.maxY - radii.topLeft),
                radius: radii.topLeft
            )
        } else {
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radii.bottomLeft))
        if radii.bottomLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: r.minX, y: r.minY),
                tangent2End: CGPoint(x: r.minX + radii.bottomLeft, y: r.minY),
                radius: radii.bottomLeft
            )
        } else {
            path.addLine(to: CGPoint(x: r.minX, y: r.minY))
        }
        path.closeSubpath()
        return path
    }

    /// An even-odd path covering the whole screen with everything revealed
    /// subtracted.
    static func maskPath(screen: CGSize, reveal: Reveal, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screen))
        if let holes = Self.holePath(reveal: reveal, screen: screen, cornerRadius: cornerRadius) {
            path.addPath(holes)
        }
        return path
    }

    /// Everything revealed as **one** even-odd-ready path, or `nil` when nothing
    /// is. Being one path is the requirement, not a convenience: see the union
    /// below.
    static func holePath(reveal: Reveal, screen: CGSize, cornerRadius: CGFloat) -> CGPath? {
        var shapes: [CGPath] = []
        if let window = reveal.window, !window.isEmpty {
            let flipped = Self.flipped(window, in: screen)
            let radii = Self.cornerRadii(for: flipped, in: screen, radius: cornerRadius)
            shapes.append(Self.roundedRectPath(flipped, radii))
        }
        if let ownWindow = reveal.ownWindow, !ownWindow.isEmpty {
            let flipped = Self.flipped(ownWindow, in: screen)
            // Its own radius: `cornerRadius` is an empirical match for a
            // *window's* corners, and a real window is drawn by AppKit with a
            // tighter one. Cutting ours looser would leave blurred tips poking
            // into the settings window's corners.
            let radii = Self.cornerRadii(for: flipped, in: screen, radius: Self.ownWindowCornerRadius)
            shapes.append(Self.roundedRectPath(flipped, radii))
        }
        if let cursor = reveal.cursor, !cursor.isEmpty {
            let disc = CGMutablePath()
            disc.addEllipse(in: Self.flipped(cursor, in: screen))
            shapes.append(disc)
        }
        guard var merged = shapes.first else { return nil }
        // The one trap in having two revealed shapes.
        //
        // Even-odd is an exclusive-or: a point lying in both holes crosses
        // three boundaries and reads as *inside* the mask, so the overlap gets
        // blurred back over — a lens of haze straddling the boundary, appearing
        // and vanishing as the cursor crosses it. Dragging the pointer onto the
        // focused window's edge is an ordinary gesture that would hit this every
        // single time.
        //
        // Unioning first turns "either shape" into one region, so it crosses
        // exactly twice like a single hole does. `union` keeps curves as curves,
        // so this costs nothing in fidelity.
        for shape in shapes.dropFirst() { merged = merged.union(shape, using: .evenOdd) }
        return merged
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
