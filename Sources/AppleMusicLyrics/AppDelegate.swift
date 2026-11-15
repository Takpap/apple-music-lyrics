import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let toggleImmersiveNotification = Notification.Name("local.applemusiclyrics.toggleFullScreenLyrics")

    private let menuBar = MenuBarController()
    private let floating = FloatingLyricsController()
    private let immersive = ImmersiveLyricsWindowController()
    private let userStore = UserLyricsStore()
    private var userFilesWatcher: DirectoryWatcher?
    private let playbackMonitor = PlaybackMonitor()
    private let lyricsService = LyricsService()
    private let playbackController = MusicPlaybackController()
    private let globalHotKeys = GlobalHotKeyController()
    private let updateService = UpdateService()
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
    private var updateTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.startSession()
        playbackMonitor.onUpdate = { [weak self] result in
            self?.handlePlaybackUpdate(result)
        }
        menuBar.onRefreshLyrics = { [weak self] in
            self?.forceRefreshLyrics()
        }
        menuBar.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates(manual: true)
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
        menuBar.onOpenMusic = { [weak self] in
            self?.openMusic()
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
        globalHotKeys.onToggleImmersive = { [weak self] in
            self?.immersive.toggle()
        }
        menuBar.onToggleImmersive = { [weak self] in
            self?.immersive.toggle()
        }
        configureImmersive()

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
        if CommandLine.arguments.contains("--full-screen-lyrics") {
            DispatchQueue.main.async { self.immersive.show() }
        }
        // A second launch (e.g. `open -n … --args --full-screen-lyrics` from a
        // Shortcut) asks the running copy to toggle the full-screen lyrics.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.toggleImmersiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.immersive.toggle() }
        }
        // No automatic update checks: an upstream release would replace this
        // customized build (full-screen lyrics, user translations).
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating")
        updateTask?.cancel()
        playbackMonitor.stop()
    }

    // MARK: - Updates

    private func checkForUpdates(manual: Bool) {
        if !manual,
           let lastCheck = AppPreferences.lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        guard updateTask == nil else { return }

        if manual { menuBar.setCheckingForUpdates(true) }
        updateTask = Task { [weak self, updateService] in
            do {
                let update = try await updateService.checkForUpdate()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                AppPreferences.lastUpdateCheck = Date()
                self.updateTask = nil
                self.menuBar.setCheckingForUpdates(false)
                if let update {
                    let version = update.version.description
                    if manual || AppPreferences.lastNotifiedUpdateVersion != version {
                        AppPreferences.lastNotifiedUpdateVersion = version
                        self.present(update: update)
                    }
                } else if manual {
                    self.presentMessage(
                        title: "You’re Up to Date",
                        message: "This copy of Apple Music Lyrics is the latest version."
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.menuBar.setCheckingForUpdates(false)
                self.logger.warning("Update check failed: \(error.localizedDescription)")
                if manual {
                    self.presentMessage(
                        title: "Couldn’t Check for Updates",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func present(update: AppUpdate) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Version \(update.version) Is Available"
        alert.informativeText = "The new disk image can be downloaded from GitHub. Its SHA-256 checksum is verified after download."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "View Release Page")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            download(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releasePageURL)
        default:
            break
        }
    }

    private func download(_ update: AppUpdate) {
        menuBar.setCheckingForUpdates(true)
        updateTask = Task { [weak self, updateService] in
            do {
                let fileURL = try await updateService.download(update)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.menuBar.setCheckingForUpdates(false)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                self.presentMessage(
                    title: "Update Downloaded",
                    message: "The disk image passed its integrity check and was saved to your Downloads folder."
                )
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.updateTask = nil
                self.menuBar.setCheckingForUpdates(false)
                self.logger.warning("Update download failed: \(error.localizedDescription)")
                self.presentMessage(title: "Couldn’t Download Update", message: error.localizedDescription)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openMusic() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music"
        ) else {
            logger.warning("Unable to locate Music.app")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [logger] _, error in
            if let error {
                logger.warning("Unable to open Music.app: \(error.localizedDescription)")
            }
        }
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

        if isLoadingLyrics, currentLyrics.lines.isEmpty, (currentLyrics.plainText ?? "").isEmpty {
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

    /// Reloads lyrics for the current track without clearing what is shown,
    /// e.g. after the user saves a translation or lyrics file.
    private func reloadLyricsQuietly() {
        guard let track = latestTrack, !isLoadingLyrics else { return }
        logger.info("User lyrics files changed; reloading quietly")
        loadLyrics(for: track, showLoading: false)
    }

    // MARK: - Full-screen lyrics

    private func configureImmersive() {
        let model = immersive.model
        model.onSeek = { [weak self] position in
            self?.playbackController.seek(to: position) {
                self?.playbackMonitor.sampleNow()
            }
        }
        model.onPreviousTrack = { [weak self] in
            self?.playbackController.previousTrack { self?.playbackMonitor.sampleNow() }
        }
        model.onTogglePlayPause = { [weak self] in
            self?.playbackController.togglePlayPause { self?.playbackMonitor.sampleNow() }
        }
        model.onNextTrack = { [weak self] in
            self?.playbackController.nextTrack { self?.playbackMonitor.sampleNow() }
        }
        model.onRefreshLyrics = { [weak self] in
            self?.forceRefreshLyrics()
        }
        model.onShowCompactLyrics = { [weak self] in
            self?.immersive.hide()
            self?.floating.setVisible(true)
        }
        model.onRevealLyricsFolder = { [weak self] in
            self?.revealUserLyricsFolder()
        }
        model.onEditTranslations = { [weak self] track, lyrics in
            self?.editTranslations(for: track, lyrics: lyrics)
        }
        model.onSaveTranslations = { [weak self] track, changes in
            guard let self else { return }
            do {
                try self.userStore.setTranslations(changes, for: track)
                self.logger.info("Saved \(changes.count) translation correction(s) for \(track.displayName)")
            } catch {
                self.logger.error("Could not save translations: \(error.localizedDescription)")
            }
        }
        model.onReloadLyrics = { [weak self] in
            self?.reloadLyricsQuietly()
        }

        for directory in [userStore.lyricsDirectoryURL, userStore.translationsDirectoryURL] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        userFilesWatcher = DirectoryWatcher(
            urls: [userStore.lyricsDirectoryURL, userStore.translationsDirectoryURL]
        ) { [weak self] in
            self?.reloadLyricsQuietly()
        }
    }

    private func editTranslations(for track: TrackInfo, lyrics: LyricsDocument) {
        do {
            let url = try userStore.ensureTranslationsFile(for: track, lyrics: lyrics)
            let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            if let textEdit {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: configuration)
            } else {
                NSWorkspace.shared.open(url)
            }
            logger.info("Opened translations file for \(track.displayName)")
        } catch {
            logger.error("Could not create translations file: \(error.localizedDescription)")
        }
    }

    private func revealUserLyricsFolder() {
        let folders = [userStore.lyricsDirectoryURL, userStore.translationsDirectoryURL]
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting(folders)
    }

    private func logPlaybackState(_ state: String) {
        guard lastLoggedPlaybackState != state else { return }
        lastLoggedPlaybackState = state
        logger.info("Playback state: \(state)")
    }

    private func apply(_ status: AppStatus) {
        immersive.model.apply(status: status)
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
