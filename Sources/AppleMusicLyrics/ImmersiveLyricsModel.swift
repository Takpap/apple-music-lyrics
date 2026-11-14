import AppKit
import Combine
import QuartzCore
import SwiftUI

/// One row in the immersive lyrics column: a sung line or the three-dot
/// interlude Apple Music shows during long instrumental gaps.
struct LyricDisplayItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case line(LyricLine)
        case interlude
    }

    let id: Int
    let kind: Kind
    let start: TimeInterval
    let end: TimeInterval

    var line: LyricLine? {
        if case .line(let line) = kind { return line }
        return nil
    }

    static let minimumInterludeGap: TimeInterval = 4.5
    static let minimumIntro: TimeInterval = 4.0

    static func makeItems(from document: LyricsDocument) -> [LyricDisplayItem] {
        guard document.isSynced else {
            let text = document.plainText
                ?? document.lines.map(\.text).joined(separator: "\n")
            return text
                .components(separatedBy: .newlines)
                .enumerated()
                .map { index, text in
                    LyricDisplayItem(
                        id: index,
                        kind: .line(LyricLine(time: 0, text: text)),
                        start: 0,
                        end: 0
                    )
                }
        }

        let lines = document.lines.sorted { $0.time < $1.time }
        var items: [LyricDisplayItem] = []
        func append(_ kind: Kind, _ start: TimeInterval, _ end: TimeInterval) {
            items.append(LyricDisplayItem(id: items.count, kind: kind, start: start, end: end))
        }

        if let first = lines.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.time >= minimumIntro {
            append(.interlude, 0, first.time)
        }

        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            let isEmpty = line.text.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty {
                // Empty LRC rows mark instrumental breaks.
                if let next, next.time - line.time >= 3, !items.isEmpty {
                    append(.interlude, line.time, next.time)
                }
                continue
            }
            let lineEnd: TimeInterval
            if let lastWord = line.words.last {
                lineEnd = max(line.time, lastWord.end)
            } else {
                lineEnd = next?.time ?? line.time + 5
            }
            append(.line(line), line.time, lineEnd)

            if let next, !line.words.isEmpty,
               !next.text.trimmingCharacters(in: .whitespaces).isEmpty,
               next.time - lineEnd >= minimumInterludeGap {
                append(.interlude, lineEnd, next.time)
            }
        }
        return items
    }
}

/// One editable row in the translation editor.
struct TranslationEditorRow: Identifiable, Equatable {
    let id: Int
    let original: String
    let translation: String
}

struct TranslationEditorRequest: Identifiable {
    let id = UUID()
    let rows: [TranslationEditorRow]
    let focusIndex: Int?
}

@MainActor
final class ImmersiveLyricsModel: ObservableObject {
    // Track and lyrics
    @Published private(set) var track: TrackInfo?
    @Published private(set) var items: [LyricDisplayItem] = []
    @Published private(set) var isSynced = false
    @Published private(set) var hasExactWordTiming = false
    @Published private(set) var lyricsSource = "none"
    @Published private(set) var statusMessage: String?
    @Published private(set) var activeIndex: Int?

    // Artwork
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: ArtworkPalette = .fallback

    // Player state
    @Published private(set) var isPlaying = false
    @Published private(set) var extras = MusicExtras()

    // Presentation
    @Published var showTranslation: Bool {
        didSet { UserDefaults.standard.set(showTranslation, forKey: Self.showTranslationKey) }
    }
    @Published var showLyrics = true
    @Published private(set) var chromeVisible = true
    @Published private(set) var manualScrollOffset: CGFloat = 0
    @Published private(set) var isUserScrolling = false
    @Published var isScrubbing = false
    @Published var translationEditor: TranslationEditorRequest?
    /// Source language (BCP-47) that macOS can translate once downloaded.
    @Published private(set) var downloadableLanguage: String?
    /// Incremented to ask the view to show the system download prompt.
    @Published private(set) var translationDownloadRequest = 0
    /// Allowed manual scroll range, published by the lyrics column.
    var scrollLimit: ClosedRange<CGFloat> = -2000 ... 2000

    // Actions wired by the app delegate.
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onRefreshLyrics: (() -> Void)?
    var onEditTranslations: ((TrackInfo, LyricsDocument) -> Void)?
    var onSaveTranslations: ((TrackInfo, [(original: String, translation: String)]) -> Void)?
    var onReloadLyrics: (() -> Void)?
    var onRevealLyricsFolder: (() -> Void)?
    var onShowCompactLyrics: (() -> Void)?
    var onClose: (() -> Void)?

    private static let showTranslationKey = "immersiveLyrics.showTranslation"
    /// Lines move slightly before they are sung, as in Music.app.
    static let scrollLead: TimeInterval = 0.12

    private let extrasService = MusicExtrasService()
    private var document: LyricsDocument = .empty
    private var artworkTrackKey: String?
    private var basePosition: TimeInterval = 0
    private var sampledAt: CFTimeInterval = CACurrentMediaTime()
    private var frozenPosition: TimeInterval?
    private var frozenUntil: CFTimeInterval = 0
    private var tickTimer: Timer?
    private var extrasTimer: Timer?
    private var chromeHideWork: DispatchWorkItem?
    private var scrollResetWork: DispatchWorkItem?
    private var pendingExtrasUntil: CFTimeInterval = 0
    private(set) var isActive = false

    init() {
        showTranslation = UserDefaults.standard.object(forKey: Self.showTranslationKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true
        tick()
        let extras = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExtras() }
        }
        RunLoop.main.add(extras, forMode: .common)
        extrasTimer = extras
        refreshExtras()
        loadArtworkIfNeeded(force: true)
        pokeChrome()
    }

    func deactivate() {
        isActive = false
        tickTimer?.invalidate()
        tickTimer = nil
        extrasTimer?.invalidate()
        extrasTimer = nil
    }

    // MARK: - Input from the app delegate

    func apply(status: AppStatus) {
        switch status {
        case .idle:
            update(track: nil, document: .empty, message: "Waiting for Music…")
        case .musicNotRunning:
            update(track: nil, document: .empty, message: "Music isn’t open")
        case .stopped:
            update(track: nil, document: .empty, message: "Nothing playing")
        case .loadingLyrics(let track):
            update(track: track, document: .empty, message: "Loading lyrics…")
        case .noLyrics(let track):
            update(track: track, document: .empty, message: "Lyrics aren’t available for this song")
        case .showing(let track, let lyrics, _):
            update(track: track, document: lyrics, message: nil)
        case .error(let message):
            update(track: track, document: document, message: message)
        }
    }

    private func update(track newTrack: TrackInfo?, document newDocument: LyricsDocument, message: String?) {
        let trackChanged = newTrack?.identityKey != track?.identityKey
        if let newTrack {
            ingestClock(newTrack, trackChanged: trackChanged)
        } else {
            isPlaying = false
        }
        // Position is tracked by the clock above; republishing `track` for
        // every playback sample would re-render every row several times a second.
        if trackChanged || track?.duration != newTrack?.duration || track?.album != newTrack?.album {
            track = newTrack
        }
        if statusMessage != message { statusMessage = message }

        if newDocument != document || trackChanged {
            document = newDocument
            isSynced = newDocument.isSynced
            hasExactWordTiming = newDocument.wordTiming == .exact
            lyricsSource = newDocument.source
            let sameTrackReload = !trackChanged && !items.isEmpty && !newDocument.lines.isEmpty
            items = LyricDisplayItem.makeItems(from: newDocument)
            if !sameTrackReload {
                activeIndex = nil
                manualScrollOffset = 0
                isUserScrolling = false
            }
            tick()
            refreshDownloadableLanguage()
        }
        if trackChanged {
            loadArtworkIfNeeded(force: false)
            refreshExtras()
        }
    }

    // MARK: - Clock

    private func ingestClock(_ sample: TrackInfo, trackChanged: Bool) {
        let now = CACurrentMediaTime()
        if let frozenPosition, abs(sample.position - frozenPosition) < 0.8 || now >= frozenUntil {
            self.frozenPosition = nil
        }
        let playing = sample.state == .playing
        let estimated = position(at: now)
        let error = sample.position - estimated
        if !trackChanged, playing, isPlaying, abs(error) < 0.75 {
            basePosition = estimated + error * 0.08
        } else {
            basePosition = sample.position
        }
        sampledAt = now
        if isPlaying != playing {
            isPlaying = playing
            tick()
        }
    }

    func position(at now: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        if let frozenPosition, now < frozenUntil {
            return frozenPosition
        }
        return basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }

    var duration: TimeInterval { track?.duration ?? 0 }

    /// Updates the current row, then sleeps until the next row is due
    /// instead of polling every frame.
    private func tick() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard isSynced, !items.isEmpty else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let position = position() + Self.scrollLead
        var low = 0
        var high = items.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if items[mid].start <= position {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if answer != activeIndex {
            activeIndex = answer
        }
        scheduleNextTick(after: answer)
    }

    private func scheduleNextTick(after index: Int?) {
        guard isActive else { return }
        // Re-check at least twice a second so seeks made in Music are caught.
        var delay: TimeInterval = 0.5
        if isPlaying {
            let next = (index ?? -1) + 1
            if items.indices.contains(next) {
                let due = items[next].start - Self.scrollLead - position()
                delay = min(max(due, 0.01), 0.5)
            }
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Artwork and extras

    private func loadArtworkIfNeeded(force: Bool) {
        guard isActive, let track else { return }
        let key = track.identityKey
        guard force || artworkTrackKey != key else { return }
        artworkTrackKey = key
        extrasService.fetchArtwork(fallbackURL: document.artworkURL) { [weak self] image in
            guard let self, self.track?.identityKey == key else { return }
            self.artwork = image
            if let image {
                let palette = ArtworkPalette.make(from: image)
                withAnimation(.easeInOut(duration: 1.2)) { self.palette = palette }
            } else {
                withAnimation(.easeInOut(duration: 1.2)) { self.palette = .fallback }
            }
        }
    }

    private func refreshExtras() {
        guard isActive, CACurrentMediaTime() >= pendingExtrasUntil else { return }
        extrasService.fetchExtras { [weak self] extras in
            guard let self, let extras, CACurrentMediaTime() >= self.pendingExtrasUntil else { return }
            if self.extras != extras { self.extras = extras }
        }
    }

    /// Optimistic local change; ignore polled values briefly so the control
    /// doesn't flicker back while Music applies it.
    private func holdExtras() {
        pendingExtrasUntil = CACurrentMediaTime() + 1.6
    }

    // MARK: - Playback actions

    func seek(to position: TimeInterval) {
        let clamped = max(0, min(position, max(duration - 0.5, 0)))
        frozenPosition = clamped
        frozenUntil = CACurrentMediaTime() + 1.5
        basePosition = clamped
        sampledAt = CACurrentMediaTime()
        endManualScroll(animated: true)
        tick()
        onSeek?(clamped)
    }

    func togglePlayPause() {
        isPlaying.toggle()
        basePosition = position()
        sampledAt = CACurrentMediaTime()
        onTogglePlayPause?()
    }

    func previousTrack() { onPreviousTrack?() }
    func nextTrack() { onNextTrack?() }

    func toggleShuffle() {
        holdExtras()
        extras.shuffle.toggle()
        extrasService.setShuffle(extras.shuffle)
    }

    func cycleRepeat() {
        holdExtras()
        extras.repeatMode = extras.repeatMode.next
        extrasService.setRepeat(extras.repeatMode)
    }

    func setVolume(_ volume: Double) {
        holdExtras()
        extras.volume = volume
        extrasService.setVolume(volume)
    }

    func toggleFavorite() {
        holdExtras()
        extras.favorited.toggle()
        extrasService.setFavorited(extras.favorited)
    }

    func openMusic() { extrasService.activateMusic() }

    /// Used by snapshot tests and previews, where Music.app is not queried.
    func setArtworkForPreview(_ image: NSImage) {
        artwork = image
        palette = ArtworkPalette.make(from: image)
    }

    /// Opens the full translations file in TextEdit.
    func editTranslationsFile() {
        guard let track else { return }
        onEditTranslations?(track, document)
    }

    // MARK: - Translation corrections

    /// Unique lyric lines with the translation currently shown for each.
    func translationRows() -> [TranslationEditorRow] {
        var seen = Set<String>()
        var rows: [TranslationEditorRow] = []
        for line in document.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(UserLyricsStore.normalizeKey(text)).inserted else { continue }
            rows.append(TranslationEditorRow(id: rows.count, original: text, translation: line.translation ?? ""))
        }
        return rows
    }

    /// Shows the translation editor, scrolled to `line` (the current line by default).
    func openTranslationEditor(focusing line: String? = nil) {
        guard track != nil, !document.lines.isEmpty else { return }
        let rows = translationRows()
        let target = line ?? activeIndex.flatMap { items.indices.contains($0) ? items[$0].line?.text : nil }
        let key = target.map(UserLyricsStore.normalizeKey)
        let focus = key.flatMap { key in rows.firstIndex { UserLyricsStore.normalizeKey($0.original) == key } }
        endManualScroll(animated: false)
        translationEditor = TranslationEditorRequest(rows: rows, focusIndex: focus ?? (rows.isEmpty ? nil : 0))
    }

    /// Saves corrected translations. They show at once, are written to the
    /// user's translations file, and override every automatic source.
    func saveTranslations(_ changes: [(original: String, translation: String)]) {
        guard let track, !changes.isEmpty else { return }
        var map: [String: String] = [:]
        for change in changes {
            let value = change.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { map[UserLyricsStore.normalizeKey(change.original)] = value }
        }
        if !map.isEmpty {
            let lines = document.lines.map { line -> LyricLine in
                guard let value = map[UserLyricsStore.normalizeKey(line.text)] else { return line }
                return LyricLine(
                    time: line.time,
                    text: line.text,
                    words: line.words,
                    translation: value,
                    transliteration: line.transliteration
                )
            }
            document = LyricsDocument(
                lines: lines,
                plainText: document.plainText,
                source: document.source,
                isSynced: document.isSynced,
                wordTiming: document.wordTiming,
                artworkURL: document.artworkURL
            )
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                items = LyricDisplayItem.makeItems(from: document)
            }
            if !showTranslation { showTranslation = true }
        }
        onSaveTranslations?(track, changes)
    }

    // MARK: - On-device translation languages

    private func refreshDownloadableLanguage() {
        let snapshot = document
        guard snapshot.isSynced, !snapshot.lines.isEmpty,
              !snapshot.lines.contains(where: { $0.translation != nil }) else {
            if downloadableLanguage != nil { downloadableLanguage = nil }
            return
        }
        Task { [weak self] in
            let language = await OnDeviceLyricsTranslator.downloadableSourceLanguage(for: snapshot)
            guard let self, self.document == snapshot else { return }
            if self.downloadableLanguage != language { self.downloadableLanguage = language }
        }
    }

    var downloadableLanguageName: String? {
        downloadableLanguage.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }

    /// Asks macOS to download the on-device model for this song's language.
    func requestTranslationDownload() {
        guard downloadableLanguage != nil else { return }
        translationDownloadRequest += 1
    }

    func translationLanguageReady() {
        downloadableLanguage = nil
        onReloadLyrics?()
    }

    // MARK: - Chrome and manual scrolling

    func pokeChrome() {
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true }
        }
        chromeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                withAnimation(.easeInOut(duration: 0.6)) { self.chromeVisible = false }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func scroll(by delta: CGFloat, limit: ClosedRange<CGFloat>) {
        guard isSynced || !items.isEmpty else { return }
        isUserScrolling = true
        manualScrollOffset = min(max(manualScrollOffset + delta, limit.lowerBound), limit.upperBound)
        scrollResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endManualScroll(animated: true) }
        }
        scrollResetWork = work
        if isSynced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
        }
    }

    func endManualScroll(animated: Bool) {
        scrollResetWork?.cancel()
        guard isUserScrolling || manualScrollOffset != 0 else { return }
        if animated {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                manualScrollOffset = 0
                isUserScrolling = false
            }
        } else {
            manualScrollOffset = 0
            isUserScrolling = false
        }
    }
}
