import AppKit
import CoreGraphics
import CoreImage
import QuartzCore

/// A borderless window above everything. It never takes focus and never takes
/// clicks, so the focused window revealed through the hole stays interactive.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A full-screen blurred picture of one display, with a transparent rectangular
/// hole punched where the focused window sits.
@MainActor
final class BlurOverlay {
    let window: NSWindow

    private let hostLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let screen: NSScreen
    private let ciContext = CIContext()

    init(screen: NSScreen) {
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
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        hostLayer.frame = view.bounds
        hostLayer.contentsGravity = .resize
        hostLayer.mask = maskLayer
        view.layer = hostLayer

        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        self.window = window

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

    /// Replaces the blurred picture (expensive, done at low rate) and, as a
    /// convenience, re-applies the cutout. For high-rate tracking of a moving
    /// window, use `applyMask(hole:)` alone — it does no capture.
    /// `hole` is a top-left local rectangle (in points); `nil` or empty blurs
    /// the whole screen. `blurRadius` is in points.
    func update(image: CGImage, scale: CGFloat, hole: NSRect?, blurRadius: Double) {
        let base = CIImage(cgImage: image)
        // Blur in device pixels.
        let r = blurRadius * scale

        // Sample the *clamped* image (edge pixels repeated outward, rather than
        // transparent) when blurring. CIGaussianBlur otherwise feathers the
        // outermost ~r points toward transparent, leaving a clear border that
        // revealed the sharp live desktop on a "fully blurred" screen. Clamping
        // keeps the blur opaque right up to the bezel.
        let source = base.clampedToExtent()
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(r, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return }
        guard let blurred = ciContext.createCGImage(output, from: base.extent) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.contents = blurred
        hostLayer.contentsScale = scale
        hostLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        CATransaction.commit()

        applyMask(hole: hole)
    }

    /// Updates only the transparent cutout, without re-capturing or re-blurring.
    /// Cheap enough to run at ~30fps so the hole tracks a dragged window with
    /// near-zero lag, independent of the (slower) screenshot refresh.
    /// `hole` is a top-left local rectangle (in points); `nil` blurs all.
    func applyMask(hole: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screen.frame.size))
        if let hole, !hole.isEmpty {
            // `hole` arrives in top-left local coordinates (same space as the
            // screenshot and `CGWindowList`), but `CALayer` geometry uses a
            // bottom-left origin. Without flipping Y the hole is rendered
            // vertically mirrored — the window moves down while the hole moves
            // up. Flip to the layer's coordinate space.
            let flipped = CGRect(
                x: hole.origin.x,
                y: screen.frame.height - hole.maxY,
                width: hole.width,
                height: hole.height
            )
            let cr = min(cornerRadius, min(flipped.width, flipped.height) / 2)
            path.addRoundedRect(in: flipped, cornerWidth: cr, cornerHeight: cr)
        }
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        maskLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        CATransaction.commit()
    }

    /// Drops all content and the mask so the overlay renders nothing — the
    /// screen shows through fully sharp. Used when there is no window to focus
    /// (an otherwise-empty desktop).
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.contents = nil
        maskLayer.path = nil
        CATransaction.commit()
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

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
