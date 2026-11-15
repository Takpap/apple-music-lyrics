import Foundation

/// Lyrics service. Source priority:
/// 1. the user's own `.lrc` file
/// 2. Music.app's local URL cache (Apple Music)
/// 3. LRCLIB (synced preferred)
/// Then user translations override, and the on-device translator fills the rest.
final class LyricsService: @unchecked Sendable {
    private let provider: AppleMusicCacheLyricsProvider
    private let lrclib: LRCLibLyricsProvider
    private let userStore: UserLyricsStore
    private let translator = OnDeviceLyricsTranslator()
    private let logger = DiagnosticLogger.shared

    init(
        provider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider(),
        lrclib: LRCLibLyricsProvider = LRCLibLyricsProvider(),
        userStore: UserLyricsStore = UserLyricsStore()
    ) {
        self.provider = provider
        self.lrclib = lrclib
        self.userStore = userStore
    }

    func lyrics(for track: TrackInfo) async -> LyricsDocument {
        var document = LyricsDocument.empty

        if let userDocument = userStore.userLyrics(for: track) {
            logger.info("Lyrics source: user file; track=\(track.displayName)")
            document = userDocument
        } else {
            let appleDocument = provider.lyrics(for: track)
            if !appleDocument.lines.isEmpty || !(appleDocument.plainText ?? "").isEmpty {
                logger.info("Lyrics source: \(appleDocument.source); track=\(track.displayName)")
                document = appleDocument
            } else if let remote = await lrclib.lyrics(for: track) {
                logger.info("Lyrics source: LRCLIB; synced=\(remote.isSynced); track=\(track.displayName)")
                document = remote
            } else {
                logger.info("Lyrics source: none; track=\(track.displayName)")
            }
        }

        let userTranslations = userStore.translations(for: track)
        if !userTranslations.isEmpty {
            document = userStore.applyingTranslations(userTranslations, to: document)
        }
        return await translator.addEnglishTranslations(to: document)
    }
}
