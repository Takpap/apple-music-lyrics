import Foundation

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

    private let service: NowPlayingService
    private var timer: Timer?

    var onUpdate: ((Update) -> Void)?

    init(service: NowPlayingService = NowPlayingService()) {
        self.service = service
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        timer.tolerance = 0.04
        self.timer = timer

        // Window dragging and resizing use an event-tracking run loop mode.
        // Pausing synchronous Apple Events there keeps interaction responsive.
        RunLoop.main.add(timer, forMode: .default)
        sampleNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sampleNow() {
        switch service.fetch() {
        case .success(let track?):
            onUpdate?(.track(track))
        case .success(nil):
            onUpdate?(service.isMusicRunning ? .stopped : .musicNotRunning)
        case .failure(let error):
            onUpdate?(.failure(error))
        }
    }
}
