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

    /// Replaces the picture. `hole` is a top-left local rectangle (in points);
    /// `nil` or empty blurs the whole screen. `blurRadius` is in points.
    func update(image: CGImage, scale: CGFloat, hole: NSRect?, blurRadius: Double) {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(blurRadius * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return }

        let extent = input.extent
        guard let blurred = ciContext.createCGImage(output, from: extent) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.contents = blurred
        hostLayer.contentsScale = scale
        hostLayer.frame = CGRect(origin: .zero, size: screen.frame.size)

        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screen.frame.size))
        if let hole, !hole.isEmpty {
            path.addRect(hole)
        }
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        maskLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        CATransaction.commit()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
