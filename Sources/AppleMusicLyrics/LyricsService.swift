import Foundation

/// Apple Music lyrics service backed by Music.app's local URL cache, with an
/// on-device English fallback when Apple has no translated lines.
final class LyricsService: @unchecked Sendable {
    private let provider: AppleMusicCacheLyricsProvider
    private let translator = OnDeviceLyricsTranslator()

    init(provider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()) {
        self.provider = provider
    }

    func lyrics(for track: TrackInfo) async -> LyricsDocument {
        let document = provider.lyrics(for: track)
        return await translator.addEnglishTranslations(to: document)
    }
}
