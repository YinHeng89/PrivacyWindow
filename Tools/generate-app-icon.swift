#!/usr/bin/env swift
//
// Renders the app icon set from a source image into a .iconset, which
// `iconutil` turns into the .icns embedded in the bundle:
//
//   swift Tools/generate-app-icon.swift [source.png]
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The artwork (logo.png) is a desktop scene: one window floating over a blurred
// wallpaper. That is literally what this app puts on screen, so the icon is the
// artwork itself — cropped to the window, rounded into Apple's squircle and
// scaled to every size macOS asks for.
//
// The menu bar glyph is a separate mark, drawn in
// `StatusItemController.eyePath(size:)`. A menu bar image has to be a
// monochrome template, which this artwork cannot be, so the two are
// deliberately not the same picture.

import AppKit
import Foundation

let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "logo.png"
guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write("cannot read \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// The square taken out of the source, as a fraction of its short side. The
/// scene is 1254 px with its window spanning x 25–75 % and y 27–69 %; this crop
/// centres on the window, leaves out the menu bar and the Dock (thin strips
/// that read as dirt once the icon is 32 px) and still fills the tile — the
/// card ends up about 78 % of its width, which is where it starts carrying at
/// small sizes instead of floating in the middle of a lot of wallpaper.
let cropSide = 0.64

/// Where the middle of that square sits in the source, as a fraction of its
/// size measured from the *bottom* left — the space `NSImage.draw(in:from:)`
/// works in. The window is the only bright, near-neutral region in the scene,
/// so its centre can be measured rather than eyeballed; it sits slightly above
/// the middle of the frame, and the crop follows it so the window ends up
/// centred in the icon.
let cropCentre = CGPoint(x: 0.50, y: 0.521)

/// Apple's icon grid leaves a margin around the artwork. A tile that runs to
/// the canvas edge reads as noticeably larger than every other icon beside it.
let tileInset = 0.055

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

/// The part of the source drawn into the tile: a square around the window,
/// clamped so it can never reach past the artwork's edge.
func cropRect(for size: NSSize) -> NSRect {
    let side = min(size.width, size.height) * cropSide
    let x = min(max(0, size.width * cropCentre.x - side / 2), size.width - side)
    let y = min(max(0, size.height * cropCentre.y - side / 2), size.height - side)
    return NSRect(x: x, y: y, width: side, height: side)
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

    let inset = px * tileInset
    let tileRect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let tile = squircle(in: tileRect)

    // The artwork, cropped to the window and scaled to fill the tile. Nothing
    // is drawn outside the squircle, so the corners stay transparent.
    context.saveGraphicsState()
    tile.addClip()
    source.draw(in: tileRect, from: cropRect(for: source.size), operation: .sourceOver, fraction: 1)
    context.restoreGraphicsState()

    // A hairline just inside the edge. The scene is pale along its top, and
    // without this the silhouette dissolves into a light background — Finder
    // windows, a white desktop. Stroked double width from inside the clip so
    // only the inner half survives and the tile keeps its exact size.
    context.saveGraphicsState()
    tile.addClip()
    NSColor.black.withAlphaComponent(0.07).set()
    let edge = squircle(in: tileRect)
    edge.lineWidth = max(1, px / 256)
    edge.stroke()
    context.restoreGraphicsState()

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
