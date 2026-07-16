import AppKit

/// Polls Music.app for the currently playing track via AppleScript.
final class NowPlayingService: @unchecked Sendable {
    private let delimiter = "\u{1F}"
    private let musicBundleIdentifier = "com.apple.Music"

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty
    }

    func fetch() -> Result<TrackInfo?, Error> {
        // Avoid launching Music if it isn't already running.
        guard isMusicRunning else { return .success(nil) }

        let script = """
        tell application "Music"
            if player state is stopped then
                return "STOPPED"
            end if
            set t to current track
            set delim to "\(delimiter)"
            return (name of t) & delim & (artist of t) & delim & (album of t) & delim & (player state as text) & delim & (player position as text) & delim & (duration of t as text)
        end tell
        """

        switch AppleScriptRunner.run(script) {
        case .failure(let error):
            return .failure(error)
        case .success(let raw):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value == "STOPPED" {
                return .success(nil)
            }
            let parts = value.components(separatedBy: delimiter)
            guard parts.count >= 6 else {
                return .failure(NowPlayingError.unexpectedFormat(value))
            }
            let title = parts[0]
            let artist = parts[1]
            let album = parts[2]
            let state = PlayerState(appleScriptValue: parts[3])
            let position = TimeInterval(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            let duration = TimeInterval(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            return .success(
                TrackInfo(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    position: position,
                    state: state
                )
            )
        }
    }
}

enum NowPlayingError: LocalizedError {
    case unexpectedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedFormat(let value):
            return "Unexpected Music response: \(value)"
        }
    }
}
