import CoreGraphics
import CoreImage
import Foundation

/// Turns a raw screenshot into the blurred picture an overlay displays.
///
/// The interesting part is the cutout. Whatever sits inside that rectangle —
/// the focused window itself, or whatever happens to be stacked underneath it
/// once the window is excluded — must not bleed outward. A plain Gaussian blur
/// gladly smears a bright window's pixels into a glowing halo around the hole,
/// and because the screenshot always trails the (live, display-linked) cutout
/// by a frame or two, that halo flickers while the window is dragged.
///
/// So the hole is **inpainted before blurring**: its pixels are replaced by the
/// average colour of the ring that surrounds it. After that there is nothing
/// left in the source for the blur to smear — the worst it can produce is a
/// smooth gradient into the surrounding background, and it produces the same
/// gradient every frame regardless of whether window exclusion succeeded.
/// One finished frame: the blurred picture plus what the overlay needs to draw
/// a cutout edge that actually contrasts with it.
struct BlurredFrame {
    let image: CGImage
    /// Pixels per point of `image`.
    let scale: CGFloat
    /// Perceived brightness (0...1) of the background immediately outside the
    /// cutout, or `nil` when it could not be sampled. The overlay uses it to
    /// pick an edge colour that stays visible: a white window on a white
    /// background needs a dark edge, a dark window on a dark background a light
    /// one.
    let surroundLuminance: CGFloat?
}

enum BlurProcessor {
    private static let lock = NSLock()
    /// One context per colour space, capped — a mixed P3/sRGB display setup
    /// alternates between the two every frame, and a single slot would rebuild
    /// a context (which is not cheap) on every one of them.
    private static let maxCachedContexts = 4
    nonisolated(unsafe) private static var cachedContexts: [(space: CGColorSpace, context: CIContext)] = []

    /// A `CIContext` committed to `colorSpace` as both its working and output
    /// space.
    ///
    /// Pinning both ends matters: the ring average is taken *in the working
    /// space*, so if the working space drifts away from the image's own space
    /// the patch colour no longer matches the pixels surrounding the hole and
    /// the cutout grows a visible colour fringe. Screenshots from a P3 panel
    /// converted into a default (sRGB) working space would also be gamut
    /// clipped, so the whole background would sit at a different saturation
    /// than the real window showing through the hole.
    private static func context(for colorSpace: CGColorSpace) -> CIContext {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cachedContexts.first(where: { $0.space == colorSpace }) {
            return hit.context
        }
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            // The ring average is divided by the ring's share of the area,
            // which magnifies any quantisation error — an 8-bit intermediate
            // would be visibly off. Half floats are GPU-native, so this is
            // effectively free.
            .workingFormat: CIFormat.RGBAh,
            // Intermediate results are recreated every frame; caching them
            // would only grow a pile of buffers nobody reads twice.
            .cacheIntermediates: false,
        ])
        cachedContexts.append((colorSpace, context))
        if cachedContexts.count > maxCachedContexts { cachedContexts.removeFirst() }
        return context
    }

    /// Blurs `image`, painting over `hole` first so nothing inside it can bleed
    /// into the blurred result.
    ///
    /// - Parameters:
    ///   - scale: pixels per point of `image`, used to convert the point-based
    ///     blur radius and insetting into the image's own pixel space.
    ///   - hole: the cutout in **image pixel coordinates with a bottom-left
    ///     origin** (Core Image's convention). `nil` blurs the whole picture.
    ///   - blurRadius: blur radius in points.
    static func blur(image: CGImage, scale: CGFloat, hole: CGRect?, blurRadius: Double) -> BlurredFrame? {
        let base = CIImage(cgImage: image)
        let extent = base.extent
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = context(for: colorSpace)

        // The inpainting pass already measures the colour of the ring around
        // the cutout; hand it back so the overlay can pick a contrasting edge
        // without sampling the picture a second time.
        var luminance: CGFloat?
        let prepared: CIImage
        if let hole {
            (prepared, luminance) = inpainting(
                base,
                hole: hole,
                extent: extent,
                scale: scale,
                blurRadius: blurRadius,
                context: context,
                colorSpace: colorSpace
            )
        } else {
            prepared = base
        }

        // Sample the *clamped* image (edge pixels repeated outward, rather than
        // transparent) when blurring. CIGaussianBlur otherwise feathers the
        // outermost ~r points toward transparent, leaving a clear border that
        // revealed the sharp live desktop on a "fully blurred" screen. Clamping
        // keeps the blur opaque right up to the bezel.
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(prepared.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(blurRadius * Double(scale), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        guard let blurred = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return BlurredFrame(image: blurred, scale: scale, surroundLuminance: luminance)
    }

    /// Replaces `hole` with the average colour of the ring around it.
    ///
    /// 1. Punch the hole out of a copy of the picture, so its pixels contribute
    ///    exactly zero to the average.
    /// 2. Average the hole grown by a band, and divide out the ring's share of
    ///    the area to recover the ring's colour.
    /// 3. Fill the hole with that colour, so the blur sees a flat patch whose
    ///    brightness *is* the neighbourhood's brightness.
    private static func inpainting(
        _ image: CIImage,
        hole: CGRect,
        extent: CGRect,
        scale: CGFloat,
        blurRadius: Double,
        context: CIContext,
        colorSpace: CGColorSpace
    ) -> (CIImage, CGFloat?) {
        let hole = hole.integral.intersection(extent)
        guard hole.width >= 1, hole.height >= 1 else { return (image, nil) }

        // A band at least as wide as the blur, since that is how far the fill
        // has to hold out; widened further so the sample cannot be dominated by
        // whatever happens to sit in the first few pixels.
        let band = max(blurRadius, 24) * scale
        let sample = hole.insetBy(dx: -band, dy: -band).intersection(extent)
        guard sample.width >= 1, sample.height >= 1 else { return (image, nil) }

        let punched = punching(hole, outOf: image, extent: extent)
        guard let average = ringColor(of: punched, in: sample, context: context, colorSpace: colorSpace) else {
            return (image, nil)
        }

        // Fill the cutout itself, and nothing beyond it.
        //
        // The fill used to be padded outwards by a blur radius, meant to cover
        // the window's pixels after it moved between capture and display. But
        // that padding lies *outside* the cutout — where it is plainly visible —
        // and a flat band of average colour there is exactly the ring of grey
        // (or white) that shows around the window. The cutout itself is masked
        // away entirely, so filling it costs nothing visually.
        //
        // Nothing is lost by dropping the margin: the rectangle being filled is
        // already the union of where the window was captured and where it is now
        // (see `PrivacyController.inpaintingHole`), so the movement the margin
        // was meant to cover is painted over regardless.
        let fill = CIImage(color: average).cropped(to: hole)
        return (fill.composited(over: image), luminance(of: average))
    }

    /// Perceived brightness of `color`, on the usual Rec. 709 luma weights.
    ///
    /// Only used to decide whether the cutout's edge should be dark or light,
    /// so gamma-encoded components are close enough.
    private static func luminance(of color: CIColor) -> CGFloat {
        let r = min(max(color.red, 0), 1)
        let g = min(max(color.green, 0), 1)
        let b = min(max(color.blue, 0), 1)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The opaque average colour of the pixels inside `rect`, ignoring every
    /// pixel that was punched to alpha 0.
    ///
    /// Those pixels are zero in both the premultiplied and the straight-alpha
    /// representation, so the mean comes back as the real average scaled by the
    /// surviving pixels' share of the area — and that share *is* the mean's
    /// alpha. Dividing it back out therefore recovers the true colour under
    /// either convention, which is why this is done on the CPU in floating
    /// point rather than with `CIUnpremultiply`: an 8-bit intermediate divided
    /// by a small alpha loses enough precision to tint the whole patch.
    private static func ringColor(
        of image: CIImage,
        in rect: CGRect,
        context: CIContext,
        colorSpace: CGColorSpace
    ) -> CIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        // `CIAreaAverage` reduces to a single pixel; where that pixel lands has
        // varied across releases, so take the extent it actually reports.
        let unit = CGRect(
            x: output.extent.minX,
            y: output.extent.minY,
            width: min(output.extent.width, 1),
            height: min(output.extent.height, 1)
        )
        guard unit.width > 0, unit.height > 0 else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.stride * 4,
            bounds: unit,
            format: .RGBAf,
            colorSpace: colorSpace
        )

        let alpha = CGFloat(pixel[3])
        // Too little of the rectangle survived to say anything about the
        // surroundings — leave the picture alone rather than amplify noise.
        guard alpha > 0.02 else { return nil }

        return CIColor(
            red: clampedUnit(CGFloat(pixel[0]) / alpha),
            green: clampedUnit(CGFloat(pixel[1]) / alpha),
            blue: clampedUnit(CGFloat(pixel[2]) / alpha),
            alpha: 1,
            colorSpace: colorSpace
        )
    }

    /// Returns `image` with the pixels inside `hole` made fully transparent, so
    /// they contribute nothing to the average taken afterwards.
    private static func punching(_ hole: CGRect, outOf image: CIImage, extent: CGRect) -> CIImage {
        // Black inside the hole, white everywhere else...
        let shape = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: hole)
            .composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent))
        // ...turned into an alpha mask: opaque outside, transparent inside.
        let mask = shape.applyingFilter("CIMaskToAlpha")
        // The background is spelled out explicitly: `CIBlendWithAlphaMask`
        // relies on it defaulting to transparent, and if it ever defaulted to
        // opaque black instead, the hole would average into the result as a
        // dark blob instead of dropping out.
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage.empty(),
        ])
    }

    private static func clampedUnit(_ value: CGFloat) -> CGFloat {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}
