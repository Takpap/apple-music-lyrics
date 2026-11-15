import AppKit
import CoreImage
import SwiftUI

/// Colours and a pre-blurred, darkened copy of the artwork used for the
/// animated background, computed once per track.
struct ArtworkPalette: Equatable {
    var colors: [NSColor]
    /// Small, heavily blurred artwork; Core Animation scales it up, so the
    /// background never needs a live blur filter.
    var backdrop: CGImage?
    /// The cover's main colours, brightened and saturated, most common first,
    /// for the glowing colour clouds of the background.
    var glows: [NSColor] = []
    /// Soft, blurred pieces of the cover for the moving background, in the
    /// order top-left, top-right, bottom-left, bottom-right, centre. Each is
    /// feathered to transparent at its edge, so overlapping pieces blend the
    /// cover's own colour regions into one another like a mesh gradient.
    var pieces: [CGImage] = []

    static let fallback = ArtworkPalette(
        colors: [
            NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.40, alpha: 1),
            NSColor(calibratedRed: 0.27, green: 0.27, blue: 0.31, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.44, alpha: 1),
            NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.26, alpha: 1),
            NSColor(calibratedRed: 0.32, green: 0.31, blue: 0.36, alpha: 1)
        ],
        backdrop: nil
    )

    static func == (lhs: ArtworkPalette, rhs: ArtworkPalette) -> Bool {
        lhs.colors == rhs.colors && lhs.backdrop === rhs.backdrop && lhs.glows == rhs.glows
            && lhs.pieces.count == rhs.pieces.count && zip(lhs.pieces, rhs.pieces).allSatisfy { $0 === $1 }
    }

    var swiftUIColors: [Color] { colors.map { Color(nsColor: $0) } }

    /// Extracts five dominant colours with a small k-means pass over a 24×24
    /// thumbnail, then tames brightness so white lyrics stay readable.
    static func make(from image: NSImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .fallback
        }
        let pixels = samplePixels(cgImage, side: 24)
        guard pixels.count >= 16 else { return .fallback }

        var centroids = stride(from: 0, to: pixels.count, by: max(1, pixels.count / 5))
            .prefix(5)
            .map { pixels[$0] }
        var assignments = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<8 {
            for (index, pixel) in pixels.enumerated() {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let d = distance(pixel, centroid)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                assignments[index] = best
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: centroids.count)
            var counts = [Int](repeating: 0, count: centroids.count)
            for (index, pixel) in pixels.enumerated() {
                sums[assignments[index]] += pixel
                counts[assignments[index]] += 1
            }
            for c in centroids.indices where counts[c] > 0 {
                centroids[c] = sums[c] / Double(counts[c])
            }
        }
        var counts = [Int](repeating: 0, count: centroids.count)
        assignments.forEach { counts[$0] += 1 }
        let ordered = centroids.indices
            .sorted { counts[$0] > counts[$1] }
            .map { centroids[$0] }

        let colors = ordered.map { rgb -> NSColor in
            let color = NSColor(calibratedRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return NSColor(
                calibratedHue: hue,
                saturation: min(1, saturation * 1.15),
                brightness: min(0.52, max(0.12, brightness * 0.62)),
                alpha: 1
            )
        }
        let glows = ordered.enumerated().compactMap { index, rgb -> NSColor? in
            // Skip clusters too small to matter, but always keep the main one.
            guard index == 0 || Double(counts[centroids.firstIndex(of: rgb) ?? 0]) / Double(pixels.count) > 0.04 else {
                return nil
            }
            let color = NSColor(calibratedRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return NSColor(
                calibratedHue: hue,
                saturation: min(1, saturation * 1.35 + 0.08),
                brightness: min(0.82, max(0.3, brightness * 0.95)),
                alpha: 1
            )
        }
        return ArtworkPalette(colors: colors, backdrop: backdrop(cgImage), glows: glows, pieces: pieces(cgImage))
    }

    private static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum()
    }

    private static func samplePixels(_ image: CGImage, side: Int) -> [SIMD3<Double>] {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var pixels: [SIMD3<Double>] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: buffer.count, by: 4) where buffer[index + 3] > 200 {
            pixels.append(SIMD3(Double(buffer[index]), Double(buffer[index + 1]), Double(buffer[index + 2])) / 255)
        }
        return pixels
    }

    /// A tiny, heavily blurred, darker and more saturated copy, close to the
    /// tone of Music.app's full-screen background. The blur is wide enough
    /// that no shapes from the cover survive, only its colour fields.
    /// Compresses highlights so white areas of a cover end up a soft grey
    /// at most, keeping white lyrics readable on light covers.
    static let highlightCap: [String: Any] = [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: 0.25, y: 0.25),
        "inputPoint2": CIVector(x: 0.5, y: 0.47),
        "inputPoint3": CIVector(x: 0.75, y: 0.62),
        "inputPoint4": CIVector(x: 1, y: 0.72)
    ]

    /// Regions of the cover (unit square, origin bottom-left as in Core
    /// Image) cut out for the background pieces; they overlap so the seams
    /// share colours.
    static let pieceRegions: [CGRect] = [
        CGRect(x: 0, y: 0.4, width: 0.6, height: 0.6),   // top left
        CGRect(x: 0.4, y: 0.4, width: 0.6, height: 0.6), // top right
        CGRect(x: 0, y: 0, width: 0.6, height: 0.6),     // bottom left
        CGRect(x: 0.4, y: 0, width: 0.6, height: 0.6),   // bottom right
        CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)  // centre
    ]

    private static func pieces(_ image: CGImage) -> [CGImage] {
        let side: CGFloat = 160
        let source = CIImage(cgImage: image)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let center = CIVector(x: side / 2, y: side / 2)
        guard let feather = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": side * 0.2,
            "inputRadius1": side * 0.5,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        ])?.outputImage else { return [] }
        return pieceRegions.compactMap { region in
            let crop = CGRect(
                x: source.extent.minX + region.minX * source.extent.width,
                y: source.extent.minY + region.minY * source.extent.height,
                width: region.width * source.extent.width,
                height: region.height * source.extent.height
            )
            let piece = source
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                    .concatenating(CGAffineTransform(scaleX: side / crop.width, y: side / crop.height)))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 11)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 2.0,
                    kCIInputContrastKey: 1.04
                ])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.5])
                .applyingFilter("CIToneCurve", parameters: ArtworkPalette.highlightCap)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: feather
                ])
                .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            return context.createCGImage(piece, from: piece.extent)
        }
    }

    private static func backdrop(_ image: CGImage) -> CGImage? {
        let side: CGFloat = 128
        let ciImage = CIImage(cgImage: image)
        let scale = side / max(ciImage.extent.width, ciImage.extent.height)
        let small = ciImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 20)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 2.0,
                kCIInputContrastKey: 1.06
            ])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.55])
            .applyingFilter("CIToneCurve", parameters: ArtworkPalette.highlightCap)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(small, from: small.extent)
    }
}
