import Foundation

/// Apple-only lyrics service backed by Music.app's local URL cache.
final class LyricsService: @unchecked Sendable {
    private let provider: AppleMusicCacheLyricsProvider

    init(provider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()) {
        self.provider = provider
    }

    func lyrics(for track: TrackInfo) async -> LyricsDocument {
        provider.lyrics(for: track)
    }
}
