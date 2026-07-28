import Foundation
import QuartzCore

/// Produces low-frequency authoritative samples from Music.app. Visual
/// progress is interpolated by the renderers between these samples.
final class PlaybackMonitor {
    enum Update {
        case track(TrackInfo)
        case stopped
        case musicNotRunning
        case failure(Error)
    }

    private static let sampleInterval: TimeInterval = 0.25
    private static let helperName = "AppleMusicLyricsPlaybackHelper"

    private struct HelperResponse: Decodable {
        let kind: String
        let title: String?
        let artist: String?
        let album: String?
        let duration: TimeInterval?
        let position: TimeInterval?
        let state: String?
        let error: String?
    }

    private var timer: Timer?
    private var helperProcess: Process?
    private var helperInput: Pipe?
    private var helperOutput: Pipe?
    private var responseBuffer = Data()
    private var requestStartedAt: CFTimeInterval?
    private var isStopping = false

    var onUpdate: ((Update) -> Void)?

    func start() {
        guard timer == nil else { return }
        isStopping = false
        startHelperIfNeeded()

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        timer.tolerance = 0.04
        self.timer = timer

        // Menu tracking switches the main run loop out of its default mode.
        // Sampling through the helper is asynchronous, so keep it active while
        // the status menu is open to update its playback controls and lyrics.
        RunLoop.main.add(timer, forMode: .common)
        sampleNow()
    }

    func stop() {
        isStopping = true
        timer?.invalidate()
        timer = nil
        stopHelper()
    }

    func sampleNow() {
        if let requestStartedAt {
            guard CACurrentMediaTime() - requestStartedAt > 2 else { return }
            stopHelper()
        }
        startHelperIfNeeded()
        guard let input = helperInput?.fileHandleForWriting else { return }
        requestStartedAt = CACurrentMediaTime()
        input.write(Data("sample\n".utf8))
    }

    private func startHelperIfNeeded() {
        guard helperProcess == nil, let helperURL else { return }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isStopping else { return }
                self.stopHelper()
            }
        }

        do {
            try process.run()
            helperProcess = process
            helperInput = input
            helperOutput = output
        } catch {
            onUpdate?(.failure(error))
        }
    }

    private func stopHelper() {
        helperOutput?.fileHandleForReading.readabilityHandler = nil
        try? helperInput?.fileHandleForWriting.close()
        try? helperOutput?.fileHandleForReading.close()
        if helperProcess?.isRunning == true {
            helperProcess?.terminate()
        }
        helperProcess = nil
        helperInput = nil
        helperOutput = nil
        responseBuffer.removeAll(keepingCapacity: true)
        requestStartedAt = nil
    }

    private func consume(_ data: Data) {
        responseBuffer.append(data)
        while let newline = responseBuffer.firstIndex(of: 0x0A) {
            let line = responseBuffer[..<newline]
            responseBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let response = try? JSONDecoder().decode(HelperResponse.self, from: line) else {
                continue
            }
            requestStartedAt = nil
            deliver(response)
        }
    }

    private func deliver(_ response: HelperResponse) {
        switch response.kind {
        case "track":
            guard let title = response.title,
                  let artist = response.artist,
                  let album = response.album,
                  let duration = response.duration,
                  let position = response.position,
                  let state = response.state else { return }
            onUpdate?(
                .track(
                    TrackInfo(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        position: position,
                        state: PlayerState(appleScriptValue: state)
                    )
                )
            )
        case "stopped":
            onUpdate?(.stopped)
        case "musicNotRunning":
            onUpdate?(.musicNotRunning)
        default:
            onUpdate?(.failure(PlaybackMonitorError.helper(response.error ?? "Unknown helper error")))
        }
    }

    private var helperURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Self.helperName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent(Self.helperName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}

private enum PlaybackMonitorError: LocalizedError {
    case helper(String)

    var errorDescription: String? {
        guard case .helper(let message) = self else { return nil }
        return message
    }
}
