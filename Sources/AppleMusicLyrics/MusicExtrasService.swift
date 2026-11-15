import AppKit
import Foundation
import ImageIO

enum MusicRepeatMode: String, Equatable, Sendable {
    case off
    case one
    case all

    init(appleScriptValue: String) {
        switch appleScriptValue.lowercased() {
        case "one": self = .one
        case "all": self = .all
        default: self = .off
        }
    }

    var next: MusicRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct MusicExtras: Equatable, Sendable {
    var shuffle = false
    var repeatMode: MusicRepeatMode = .off
    var volume: Double = 50
    var favorited = false
}

/// One of Music's AirPlay outputs, the Mac's own speakers included.
struct MusicAirPlayDevice: Equatable, Sendable {
    let name: String
    let kind: String
    let selected: Bool
    let available: Bool

    var isComputer: Bool { kind == "computer" }
}

/// Reads and changes the Music.app state the immersive player shows besides
/// the track and position: artwork, shuffle, repeat, volume and favourite.
/// Every call runs AppleScript on a private serial queue and reports back on
/// the main queue.
final class MusicExtrasService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.applemusiclyrics.music-extras", qos: .userInitiated)
    private let delimiter = "\u{1F}"

    private lazy var extrasScript = NSAppleScript(source: """
        tell application "Music"
            set delim to "\(delimiter)"
            set shuffleText to "false"
            set repeatText to "off"
            set volumeText to "50"
            set favouriteText to "false"
            try
                set shuffleText to (shuffle enabled as text)
            end try
            try
                set repeatText to (song repeat as text)
            end try
            try
                set volumeText to (sound volume as text)
            end try
            try
                set favouriteText to (favorited of current track as text)
            on error
                try
                    set favouriteText to (loved of current track as text)
                end try
            end try
            return shuffleText & delim & repeatText & delim & volumeText & delim & favouriteText
        end tell
        """)

    private lazy var artworkScript = NSAppleScript(source: """
        tell application "Music"
            try
                return raw data of artwork 1 of current track
            on error
                try
                    return data of artwork 1 of current track
                end try
            end try
            return ""
        end tell
        """)

    private lazy var airPlayScript = NSAppleScript(source: """
        tell application "Music"
            set delim to "\(delimiter)"
            set out to ""
            repeat with device in AirPlay devices
                try
                    set out to out & (name of device) & delim & (kind of device as text) & delim & (selected of device as text) & delim & (available of device as text) & linefeed
                end try
            end repeat
            return out
        end tell
        """)

    /// Music's AirPlay outputs, as its own AirPlay menu lists them.
    func fetchAirPlayDevices(completion: @escaping ([MusicAirPlayDevice]) -> Void) {
        queue.async { [self] in
            var devices: [MusicAirPlayDevice] = []
            if Self.isMusicRunning, let airPlayScript {
                var error: NSDictionary?
                let raw = airPlayScript.executeAndReturnError(&error).stringValue ?? ""
                if error == nil { devices = Self.parseAirPlayDevices(raw, delimiter: delimiter) }
            }
            DispatchQueue.main.async { completion(devices) }
        }
    }

    static func parseAirPlayDevices(_ raw: String, delimiter: String) -> [MusicAirPlayDevice] {
        raw.components(separatedBy: .newlines).compactMap { row in
            let fields = row.components(separatedBy: delimiter)
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return MusicAirPlayDevice(
                name: fields[0],
                kind: fields[1].lowercased(),
                selected: fields[2].lowercased() == "true",
                available: fields[3].lowercased() == "true"
            )
        }
    }

    /// Plays to exactly these outputs (Music allows several at once).
    func setAirPlayDevices(named names: [String], completion: (() -> Void)? = nil) {
        guard !names.isEmpty else { return }
        let list = names.map { "AirPlay device \"\(Self.appleScriptEscaped($0))\"" }.joined(separator: ", ")
        let source = "tell application \"Music\" to set current AirPlay devices to {\(list)}"
        queue.async {
            _ = AppleScriptRunner.run(source)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func fetchExtras(completion: @escaping (MusicExtras?) -> Void) {
        queue.async { [self] in
            guard Self.isMusicRunning, let extrasScript else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var error: NSDictionary?
            let descriptor = extrasScript.executeAndReturnError(&error)
            guard error == nil, let raw = descriptor.stringValue else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let fields = raw.components(separatedBy: delimiter)
            var extras = MusicExtras()
            if fields.count >= 4 {
                extras.shuffle = fields[0].lowercased() == "true"
                extras.repeatMode = MusicRepeatMode(appleScriptValue: fields[1])
                extras.volume = Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 50
                extras.favorited = fields[3].lowercased() == "true"
            }
            DispatchQueue.main.async { completion(extras) }
        }
    }

    func fetchArtwork(fallbackURL: URL?, completion: @escaping (NSImage?) -> Void) {
        queue.async { [self] in
            var image: NSImage?
            if Self.isMusicRunning, let artworkScript {
                var error: NSDictionary?
                let descriptor = artworkScript.executeAndReturnError(&error)
                if error == nil {
                    let data = descriptor.data
                    if data.count > 64 {
                        image = Self.decodeArtwork(data)
                    }
                }
            }
            if image == nil, let fallbackURL,
               let data = try? Data(contentsOf: fallbackURL) {
                image = Self.decodeArtwork(data)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Largest artwork side kept in memory, in pixels. The cover is drawn at
    /// most about 480 points wide, so this is enough for a 2x display.
    static let maxArtworkPixels = 1000

    /// Decodes artwork straight to a bounded bitmap. Music hands over the
    /// original file, often 3000 px or more, which as a full bitmap is ~36 MB.
    static func decodeArtwork(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxArtworkPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func setShuffle(_ enabled: Bool) {
        run("tell application \"Music\" to set shuffle enabled to \(enabled ? "true" : "false")")
    }

    func setRepeat(_ mode: MusicRepeatMode) {
        run("tell application \"Music\" to set song repeat to \(mode.rawValue)")
    }

    func setVolume(_ volume: Double) {
        let clamped = Int(max(0, min(100, volume)).rounded())
        run("tell application \"Music\" to set sound volume to \(clamped)")
    }

    func setFavorited(_ favorited: Bool) {
        let value = favorited ? "true" : "false"
        run("""
            tell application "Music"
                try
                    set favorited of current track to \(value)
                on error
                    try
                        set loved of current track to \(value)
                    end try
                end try
            end tell
            """)
    }

    func activateMusic() {
        run("tell application \"Music\" to activate")
    }

    private func run(_ source: String) {
        queue.async {
            _ = AppleScriptRunner.run(source)
        }
    }

    private static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }
}
