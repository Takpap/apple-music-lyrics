import AppKit
import Foundation

final class MusicPlaybackController {
    private let queue = DispatchQueue(label: "local.applemusiclyrics.playback-control")

    func seek(to position: TimeInterval, completion: @escaping () -> Void) {
        let clamped = max(0, position)
        execute(
            """
            tell application "Music"
                set player position to \(clamped)
            end tell
            """,
            completion: completion
        )
    }

    func previousTrack(completion: @escaping () -> Void) {
        execute("tell application \"Music\" to previous track", completion: completion)
    }

    func togglePlayPause(completion: @escaping () -> Void) {
        execute("tell application \"Music\" to playpause", completion: completion)
    }

    func nextTrack(completion: @escaping () -> Void) {
        execute("tell application \"Music\" to next track", completion: completion)
    }

    private func execute(_ source: String, completion: @escaping () -> Void) {
        queue.async {
            _ = AppleScriptRunner.run(source)
            DispatchQueue.main.async(execute: completion)
        }
    }
}
