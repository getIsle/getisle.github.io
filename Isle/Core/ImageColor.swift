//
//  ImageColor.swift
//  Isle
//
//  Pulls a single representative colour out of album art so the glow under the
//  island can take on the record's colour.
//

import AppKit

extension NSImage {

    /// Average colour of the image, saturation-boosted so that a mostly-dark cover
    /// still produces a visible glow rather than a grey smudge.
    ///
    /// Implemented by rendering the artwork into a 1×1 bitmap: one downsample by the
    /// graphics system is far cheaper — and far less code — than walking pixels, and
    /// this runs once per track.
    var dominantColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let color = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(
            &hue, saturation: &saturation, brightness: &brightness, alpha: &alpha
        )

        return NSColor(
            hue: hue,
            saturation: min(1, saturation * 1.7),
            brightness: max(0.45, min(1, brightness * 1.35)),
            alpha: 1
        )
    }
}
