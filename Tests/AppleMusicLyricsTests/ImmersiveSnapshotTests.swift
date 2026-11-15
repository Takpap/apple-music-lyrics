import AppKit
import SwiftUI
import XCTest
@testable import AppleMusicLyrics

/// Renders the full-screen lyrics view to PNG files for visual review.
/// Runs only when IMMERSIVE_SNAPSHOT_DIR is set.
@MainActor
final class ImmersiveSnapshotTests: XCTestCase {
    /// The progress bar is an AppKit view, which `ImageRenderer` cannot draw,
    /// so it gets its own picture from its layer tree.
    func testRenderProgressBar() throws {
        guard let directory = ProcessInfo.processInfo.environment["IMMERSIVE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set IMMERSIVE_SNAPSHOT_DIR to render snapshots")
        }
        let model = ImmersiveLyricsModel()
        let track = TrackInfo(title: "T", artist: "A", album: "", duration: 200, position: 70, state: .paused)
        model.apply(status: .showing(track: track, lyrics: Self.sampleLyrics(), currentLine: ""))
        let size = NSSize(width: 360, height: 32)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.2, blue: 0.35, alpha: 1).cgColor
        window.contentView = container
        let bar = ProgressBarView(model: model)
        bar.frame = container.bounds
        container.addSubview(bar)
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        bar.refresh()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep), let barLayer = bar.layer else {
            return XCTFail("Could not make a bitmap")
        }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor(calibratedRed: 0.25, green: 0.2, blue: 0.35, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        // The bar view is flipped; flip the context to match its layers.
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        barLayer.render(in: cg)
        cg.restoreGState()
        // The time labels are subviews, drawn by AppKit.
        bar.displayIgnoringOpacity(bar.bounds, in: context)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG failed") }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("progress-bar.png"))
        XCTAssertEqual(ProgressBarView.format(70), "1:10")
    }

    /// Renders the animated background at a few moments. Uses the image at
    /// IMMERSIVE_ARTWORK when set, else the sample artwork.
    func testRenderBackdrop() throws {
        guard let directory = ProcessInfo.processInfo.environment["IMMERSIVE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set IMMERSIVE_SNAPSHOT_DIR to render snapshots")
        }
        let artwork = ProcessInfo.processInfo.environment["IMMERSIVE_ARTWORK"].flatMap(NSImage.init(contentsOfFile:))
            ?? Self.sampleArtwork()
        let palette = ArtworkPalette.make(from: artwork)
        let size = NSSize(width: 1200, height: 750)
        let view = BackdropView(frame: NSRect(origin: .zero, size: size))
        view.apply(palette)
        view.layout()
        for time in [0.0, 25, 60] {
            view.pose(at: time)
            let scale: CGFloat = 1
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep), let layer = view.layer else {
                return XCTFail("Could not make a bitmap")
            }
            view.layer?.removeAllAnimations()
            layer.render(in: context.cgContext)
            guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG failed") }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("backdrop-\(Int(time)).png"))
        }
    }

    func testRenderSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["IMMERSIVE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set IMMERSIVE_SNAPSHOT_DIR to render snapshots")
        }
        let model = ImmersiveLyricsModel()
        model.setArtworkForPreview(Self.sampleArtwork())
        let track = TrackInfo(
            title: "Le Vent du Soir",
            artist: "Exemple",
            album: "Démo",
            duration: 180,
            position: 13.1,
            state: .paused
        )
        model.apply(status: .showing(track: track, lyrics: Self.sampleLyrics(), currentLine: ""))

        for (name, size) in [("wide", CGSize(width: 1200, height: 750)), ("narrow", CGSize(width: 700, height: 760))] {
            let view = ImmersiveLyricsRootView(model: model).frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            // Let layout preferences settle, then render again.
            _ = renderer.nsImage
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                return XCTFail("Rendering failed")
            }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("immersive-\(name).png"))
        }
    }

    /// Hosts the real view tree in an off-screen window and renders its layer
    /// tree, so AppKit-backed pieces (the Core Animation karaoke line) show up.
    func testRenderHostedSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["IMMERSIVE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set IMMERSIVE_SNAPSHOT_DIR to render snapshots")
        }
        let model = ImmersiveLyricsModel()
        model.setArtworkForPreview(Self.sampleArtwork())
        let track = TrackInfo(title: "Le Vent du Soir", artist: "Exemple", album: "Démo",
                              duration: 180, position: 13.1, state: .paused)
        model.apply(status: .showing(track: track, lyrics: Self.sampleLyrics(), currentLine: ""))
        let size = CGSize(width: 1200, height: 750)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ImmersiveLyricsRootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        guard let layer = host.layer else { return XCTFail("No layer") }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        context.cgContext.translateBy(x: 0, y: size.height * 2)
        context.cgContext.scaleBy(x: 2, y: -2)
        layer.render(in: context.cgContext)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG failed") }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hosted-wide.png"))
    }

    static func sampleLyrics() -> LyricsDocument {
        func words(_ text: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
            let parts = text.split(separator: " ", omittingEmptySubsequences: true)
            let step = (end - start) / Double(parts.count)
            return parts.enumerated().map { index, part in
                let isLast = index == parts.count - 1
                return LyricWord(
                    text: isLast ? String(part) : String(part) + " ",
                    start: start + Double(index) * step,
                    end: start + Double(index + 1) * step
                )
            }
        }
        let rows: [(TimeInterval, TimeInterval, String, String)] = [
            (6, 9, "Le soleil se lève sur la ville", "The sun rises over the city"),
            (9.5, 12, "Je marche seul dans la rue", "I walk alone in the street"),
            (12, 15, "Le vent chante une chanson douce", "The wind sings a gentle song"),
            (15.5, 18, "Et mon cœur danse avec lui", "And my heart dances with it"),
            (27, 30, "Dans le bruit je cours encore", "In the noise I keep running"),
            (30.5, 33, "Et la nuit tombe doucement", "And night falls gently")
        ]
        let lines = rows.map { start, end, text, translation in
            LyricLine(time: start, text: text, words: words(text, start: start, end: end), translation: translation)
        }
        return LyricsDocument(lines: lines, plainText: nil, source: "Sample", isSynced: true, wordTiming: .exact)
    }

    static func sampleArtwork() -> NSImage {
        let size = NSSize(width: 600, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.65, alpha: 1),
            NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.55, alpha: 1)
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 200, y: 260, width: 200, height: 200)).fill()
        image.unlockFocus()
        return image
    }
}
