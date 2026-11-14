import AppKit
import Foundation

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
                        image = NSImage(data: data)
                    }
                }
            }
            if image == nil, let fallbackURL,
               let data = try? Data(contentsOf: fallbackURL) {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async { completion(image) }
        }
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
