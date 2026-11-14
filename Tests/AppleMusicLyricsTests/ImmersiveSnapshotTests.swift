import AppKit
import SwiftUI
import XCTest
@testable import AppleMusicLyrics

/// Renders the full-screen lyrics view to PNG files for visual review.
/// Runs only when IMMERSIVE_SNAPSHOT_DIR is set.
@MainActor
final class ImmersiveSnapshotTests: XCTestCase {
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
