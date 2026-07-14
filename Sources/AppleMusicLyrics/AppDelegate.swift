import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let floating = FloatingLyricsController()
    private let nowPlaying = NowPlayingService()
    private let lyricsService = LyricsService()

    private var pollTimer: Timer?
    private var currentTrackKey: String?
    private var currentLyrics: LyricsDocument = .empty
    private var isLoadingLyrics = false
    private var showsLoadingState = false
    private var lastLyricsAttempt = Date.distantPast
    private var forceRefresh = false
    private var lastDisplayedLine: String?
    private var lastTrackKeyForUI: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.onRefreshLyrics = { [weak self] in
            self?.forceRefreshLyrics()
        }
        menuBar.onToggleFloating = { [weak self] in
            self?.floating.toggle()
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        floating.onVisibilityChanged = { [weak self] visible in
            AppPreferences.floatingLyricsVisible = visible
            self?.menuBar.setFloatingVisible(visible)
        }

        let showFloating = AppPreferences.floatingLyricsVisible
        floating.setVisible(showFloating)
        menuBar.setFloatingVisible(showFloating)

        menuBar.apply(status: .idle)
        floating.apply(status: .idle)
        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    // MARK: - Polling

    private func startPolling() {
        // ~12 fps is enough for smooth 逐字 highlighting without heavy AppleScript load.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
        tick()
    }

    private func tick() {
        switch nowPlaying.fetch() {
        case .failure(let error):
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("not allowed")
                || message.localizedCaseInsensitiveContains("(-1743)")
                || message.localizedCaseInsensitiveContains("authorization") {
                apply(.error("Grant Automation access for Music in System Settings → Privacy & Security → Automation"))
            } else {
                apply(.error(message))
            }

        case .success(let track?):
            handle(track: track)

        case .success(nil):
            currentTrackKey = nil
            currentLyrics = .empty
            let runningScript = """
            tell application "System Events"
                return (name of processes) contains "Music"
            end tell
            """
            if case .success(let running) = AppleScriptRunner.run(runningScript),
               running.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                apply(.stopped)
            } else {
                apply(.musicNotRunning)
            }
        }
    }

    private func handle(track: TrackInfo) {
        let key = track.identityKey
        let trackChanged = currentTrackKey != key

        if trackChanged || forceRefresh {
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
                self.tick()
            }
        }
    }

    private func forceRefreshLyrics() {
        currentTrackKey = nil
        lastDisplayedLine = nil
        lastTrackKeyForUI = nil
        forceRefresh = true
        tick()
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
