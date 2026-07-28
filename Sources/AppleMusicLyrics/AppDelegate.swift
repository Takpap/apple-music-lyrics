import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let floating = FloatingLyricsController()
    private let playbackMonitor = PlaybackMonitor()
    private let lyricsService = LyricsService()
    private let playbackController = MusicPlaybackController()
    private let globalHotKeys = GlobalHotKeyController()
    private let logger = DiagnosticLogger.shared

    private var currentTrackKey: String?
    private var latestTrack: TrackInfo?
    private var currentLyrics: LyricsDocument = .empty
    private var isLoadingLyrics = false
    private var showsLoadingState = false
    private var lastLyricsAttempt = Date.distantPast
    private var forceRefresh = false
    private var lastDisplayedLine: String?
    private var lastTrackKeyForUI: String?
    private var lastLoggedPlaybackState: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.startSession()
        playbackMonitor.onUpdate = { [weak self] result in
            self?.handlePlaybackUpdate(result)
        }
        menuBar.onRefreshLyrics = { [weak self] in
            self?.forceRefreshLyrics()
        }
        menuBar.onToggleFloating = { [weak self] in
            self?.floating.toggle()
        }
        menuBar.onToggleFloatingLock = { [weak self] in
            self?.floating.toggleLocked()
        }
        menuBar.onToggleFloatingClickThrough = { [weak self] in
            self?.floating.toggleClickThrough()
        }
        menuBar.onSeek = { [weak self] position in
            self?.playbackController.seek(to: position) {
                self?.playbackMonitor.sampleNow()
            }
        }
        menuBar.onPreviousTrack = { [weak self] in
            self?.playbackController.previousTrack {
                self?.playbackMonitor.sampleNow()
            }
        }
        menuBar.onTogglePlayPause = { [weak self] in
            self?.playbackController.togglePlayPause {
                self?.playbackMonitor.sampleNow()
            }
        }
        menuBar.onNextTrack = { [weak self] in
            self?.playbackController.nextTrack {
                self?.playbackMonitor.sampleNow()
            }
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        floating.onSeek = { [weak self] position in
            self?.playbackController.seek(to: position) {
                self?.playbackMonitor.sampleNow()
            }
        }
        globalHotKeys.onToggleFloating = { [weak self] in
            self?.floating.toggle()
        }
        globalHotKeys.onToggleLock = { [weak self] in
            self?.floating.toggleLocked()
        }

        floating.onVisibilityChanged = { [weak self] visible in
            AppPreferences.floatingLyricsVisible = visible
            self?.menuBar.setFloatingVisible(visible)
        }
        floating.onInteractionChanged = { [weak self] locked, clickThrough in
            self?.menuBar.setFloatingInteraction(locked: locked, clickThrough: clickThrough)
        }

        let showFloating = AppPreferences.floatingLyricsVisible
        floating.setVisible(showFloating)
        menuBar.setFloatingVisible(showFloating)
        menuBar.setFloatingInteraction(
            locked: AppPreferences.floatingLyricsLocked,
            clickThrough: AppPreferences.floatingLyricsClickThrough
        )

        menuBar.apply(status: .idle)
        floating.apply(status: .idle)
        playbackMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating")
        playbackMonitor.stop()
    }

    // MARK: - Playback updates

    private func handlePlaybackUpdate(_ result: PlaybackMonitor.Update) {
        switch result {
        case .failure(let error):
            let message = error.localizedDescription
            let isNewError = lastLoggedPlaybackState != "error"
            logPlaybackState("error")
            if isNewError {
                logger.error("Music AppleScript request failed: \(message)")
            }
            if message.localizedCaseInsensitiveContains("not allowed")
                || message.localizedCaseInsensitiveContains("(-1743)")
                || message.localizedCaseInsensitiveContains("authorization") {
                apply(.error("Grant Automation access for Music in System Settings → Privacy & Security → Automation"))
            } else {
                apply(.error(message))
            }

        case .track(let track):
            logPlaybackState("track available")
            latestTrack = track
            handle(track: track)

        case .stopped:
            logPlaybackState("playback stopped")
            latestTrack = nil
            currentTrackKey = nil
            currentLyrics = .empty
            apply(.stopped)

        case .musicNotRunning:
            logPlaybackState("Music.app not running")
            latestTrack = nil
            currentTrackKey = nil
            currentLyrics = .empty
            apply(.musicNotRunning)
        }
    }

    private func handle(track: TrackInfo) {
        let key = track.identityKey
        let trackChanged = currentTrackKey != key

        if trackChanged || forceRefresh {
            logger.info(
                "Lyrics lookup triggered; reason=\(trackChanged ? "track changed" : "manual refresh"); "
                    + "track=\(track.displayName); duration=\(Int(track.duration.rounded()))"
            )
            currentTrackKey = key
            currentLyrics = .empty
            forceRefresh = false
            loadLyrics(for: track, showLoading: true)
            apply(.loadingLyrics(track))
            return
        }

        if isLoadingLyrics {
            apply(showsLoadingState ? .loadingLyrics(track) : .noLyrics(track))
            return
        }

        if currentLyrics.isSynced, let line = currentLyrics.line(at: track.position) {
            let text = line.text.isEmpty ? track.displayName : line.text
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: text))
        } else if currentLyrics.isSynced {
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: track.displayName))
        } else if let plain = currentLyrics.plainText, !plain.isEmpty {
            apply(.showing(track: track, lyrics: currentLyrics, currentLine: track.displayName))
        } else {
            // Music may write the lyrics response shortly after the track-change
            // notification. Rescan quietly until the local cache catches up.
            if Date().timeIntervalSince(lastLyricsAttempt) >= 2 {
                loadLyrics(for: track, showLoading: false)
            }
            apply(.noLyrics(track))
        }
    }

    private func loadLyrics(for track: TrackInfo, showLoading: Bool) {
        isLoadingLyrics = true
        showsLoadingState = showLoading
        lastLyricsAttempt = Date()
        let key = track.identityKey

        Task { [lyricsService] in
            let document = await lyricsService.lyrics(for: track)
            await MainActor.run {
                guard self.currentTrackKey == key else { return }
                self.currentLyrics = document
                self.isLoadingLyrics = false
                self.showsLoadingState = false
                if let latestTrack = self.latestTrack,
                   latestTrack.identityKey == key {
                    self.handle(track: latestTrack)
                }
            }
        }
    }

    private func forceRefreshLyrics() {
        logger.info("Manual lyrics refresh requested")
        currentTrackKey = nil
        lastDisplayedLine = nil
        lastTrackKeyForUI = nil
        forceRefresh = true
        playbackMonitor.sampleNow()
    }

    private func logPlaybackState(_ state: String) {
        guard lastLoggedPlaybackState != state else { return }
        lastLoggedPlaybackState = state
        logger.info("Playback state: \(state)")
    }

    private func apply(_ status: AppStatus) {
        // Skip full menu rebuild when the visible lyric line is unchanged.
        if case .showing(let track, let lyrics, let currentLine) = status {
            if lastTrackKeyForUI == track.identityKey, lastDisplayedLine == currentLine {
                menuBar.updateKaraokeProgress(track: track, lyrics: lyrics)
                floating.updateHighlight(for: track, lyrics: lyrics)
                return
            }
            lastTrackKeyForUI = track.identityKey
            lastDisplayedLine = currentLine
        } else {
            lastDisplayedLine = nil
            lastTrackKeyForUI = nil
        }

        menuBar.apply(status: status)
        floating.apply(status: status)
    }
}
