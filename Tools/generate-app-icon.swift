#!/usr/bin/env swift
//
// Renders the app icon (a privacy "eye with a slash" on a gradient tile) into an
// .iconset, which `iconutil` turns into the .icns embedded in the bundle.
//
//   swift Tools/generate-app-icon.swift
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The eye geometry is mirrored in `StatusItemController.eyePath(size:)`: both
// draw the same shape into a square of a given side, so the menu bar glyph and
// the app icon stay the same mark at different scales.

import AppKit
import Foundation

let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// The almond outline of the eye, in a square of the given side length with its
/// centre at the middle of that square.
///
/// Mirrored in `StatusItemController.eyePath(size:)`.
func eyePath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let left = NSPoint(x: size * 0.16, y: size * 0.50)
    let right = NSPoint(x: size * 0.84, y: size * 0.50)
    path.move(to: left)
    path.curve(
        to: right,
        controlPoint1: NSPoint(x: size * 0.30, y: size * 0.27),
        controlPoint2: NSPoint(x: size * 0.70, y: size * 0.27)
    )
    path.curve(
        to: left,
        controlPoint1: NSPoint(x: size * 0.70, y: size * 0.73),
        controlPoint2: NSPoint(x: size * 0.30, y: size * 0.73)
    )
    path.close()
    return path
}

/// Apple's icon corners are a continuous-curvature "squircle", not a plain
/// rounded rectangle. Sampling the superellipse |x|ⁿ + |y|ⁿ = 1 at n = 5 lands
/// very close to the system shape — and unlike `roundedRect`, it stays smooth
/// exactly where the straight edge meets the corner, which is where an ordinary
/// corner radius looks visibly kinked at icon sizes.
func squircle(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let cx = rect.midX
    let cy = rect.midY
    let a = rect.width / 2
    let b = rect.height / 2
    let exponent = 2 / n
    let path = NSBezierPath()
    let steps = 480
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * CGFloat.pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = cx + a * copysign(pow(abs(cosT), exponent), cosT)
        let y = cy + b * copysign(pow(abs(sinT), exponent), sinT)
        if i == 0 {
            path.move(to: NSPoint(x: x, y: y))
        } else {
            path.line(to: NSPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

func render(px: CGFloat) -> Data {
    // Drawn into a bitmap in a known colour space rather than with `lockFocus()`,
    // which inherits the current screen's profile and used to tag the icon as
    // Display P3 — fine on this Mac, different everywhere else.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(px),
        pixelsHigh: Int(px),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high

    // The tile is inset rather than full-bleed. Apple's icon grid leaves a
    // margin around the artwork, and a tile touching the canvas edge reads as
    // noticeably larger than every other icon in the dock or Finder.
    let inset = px * 0.055
    let tileRect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let tile = squircle(in: tileRect)

    // Three stops rather than two for a richer vertical fall-off, with the
    // middle one set on the straight line between the ends — a middle stop that
    // sits off that line shows up as a faint horizontal band across the tile.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.45, green: 0.56, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.38, blue: 0.83, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.21, blue: 0.68, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: 90)

    // A soft highlight so the tile reads as a lit surface rather than a flat
    // fill. It spans the whole tile instead of the top half, which is what used
    // to leave a visible line where the highlight stopped.
    context.saveGraphicsState()
    tile.addClip()
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    gloss.draw(in: tileRect, angle: 90)
    context.restoreGraphicsState()

    // The glyph, centred in the tile and sized to the safe area. Every
    // proportion below is relative to the glyph's own square, so the mark is
    // identical to the menu bar one — only scaled.
    let side = tileRect.width * 0.56
    var shift = AffineTransform()
    shift.translate(x: tileRect.midX - side / 2, y: tileRect.midY - side / 2)

    NSColor.white.set()

    let eye = eyePath(size: side)
    eye.lineWidth = side * 0.11
    eye.lineCapStyle = .round
    eye.lineJoinStyle = .round
    eye.transform(using: shift)
    eye.stroke()

    let pupil = NSBezierPath(ovalIn: NSRect(x: side * 0.405, y: side * 0.405, width: side * 0.19, height: side * 0.19))
    pupil.transform(using: shift)
    pupil.fill()

    // Diagonal slash across the eye — the "no peeking" mark.
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: side * 0.20, y: side * 0.73))
    slash.line(to: NSPoint(x: side * 0.80, y: side * 0.27))
    slash.lineWidth = side * 0.125
    slash.lineCapStyle = .round
    slash.transform(using: shift)
    slash.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [.compressionFactor: 1.0])!
}

/// Pixel size -> iconutil file name. Each size is emitted under every name that
/// resolves to it, so the icon looks crisp at both 1x and 2x on every target.
let names: [(px: CGFloat, file: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, file) in names {
    let data = render(px: px)
    try data.write(to: iconsetDir.appendingPathComponent(file))
    print("wrote \(file) (\(Int(px))px)")
}

print("iconset ready at \(iconsetDir.path)")
