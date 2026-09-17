#!/usr/bin/env swift
//
// Renders the app icon (a privacy "eye with a slash" on a rounded tile) into an
// .iconset, which `iconutil` turns into the .icns embedded in the bundle.
//
//   swift Tools/generate-app-icon.swift
//
// The same eye geometry is mirrored in `StatusItemController.eyePath(size:)` so
// the menu bar glyph stays in sync with the app icon.

import AppKit
import Foundation

let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// The almond outline of the eye, in a square of the given side length with its
/// centre at the middle of that square.
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

func render(px: CGFloat, background: Bool) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    if background {
        let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px), xRadius: px * 0.22, yRadius: px * 0.22)
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.36, green: 0.46, blue: 0.96, alpha: 1),
            ending: NSColor(srgbRed: 0.19, green: 0.27, blue: 0.74, alpha: 1)
        )!
        gradient.draw(in: tile, angle: 90)
    }

    let white = NSColor.white
    white.set()

    // Eye outline.
    let eye = eyePath(size: px)
    eye.lineWidth = px * 0.075
    eye.lineCapStyle = .round
    eye.lineJoinStyle = .round
    eye.stroke()

    // Pupil.
    let pupil = NSBezierPath(ovalIn: NSRect(x: px * 0.405, y: px * 0.405, width: px * 0.19, height: px * 0.19))
    pupil.fill()

    // Diagonal slash across the eye — the "no peeking" mark.
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: px * 0.20, y: px * 0.73))
    slash.line(to: NSPoint(x: px * 0.80, y: px * 0.27))
    slash.lineWidth = px * 0.085
    slash.lineCapStyle = .round
    slash.stroke()

    image.unlockFocus()

    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
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
    let data = render(px: px, background: true)
    try data.write(to: iconsetDir.appendingPathComponent(file))
    print("wrote \(file) (\(Int(px))px)")
}

print("iconset ready at \(iconsetDir.path)")
