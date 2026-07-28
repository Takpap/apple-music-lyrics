import AppKit
import Foundation

final class MusicPlaybackController {
    private let queue = DispatchQueue(label: "local.applemusiclyrics.playback-control")

    func seek(to position: TimeInterval, completion: @escaping () -> Void) {
        let clamped = max(0, position)
        queue.async {
            _ = AppleScriptRunner.run("""
                tell application "Music"
                    set player position to \(clamped)
                end tell
                """)
            DispatchQueue.main.async(execute: completion)
        }
    }
}
