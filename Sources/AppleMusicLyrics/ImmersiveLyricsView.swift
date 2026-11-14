import AVKit
import QuartzCore
import SwiftUI
import Translation

/// Full-window player modelled on Music.app's full-screen lyrics view.
struct ImmersiveLyricsRootView: View {
    @ObservedObject var model: ImmersiveLyricsModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ImmersiveBackground(palette: model.palette)
                content(size: size)
                if model.chromeVisible {
                    chrome(size: size)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onContinuousHover { _ in model.pokeChrome() }
        .sheet(item: $model.translationEditor) { request in
            TranslationEditorSheet(model: model, request: request)
        }
        .modifier(TranslationDownloadHost(model: model))
    }

    // MARK: Layout

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let wide = size.width >= 760
        if !model.showLyrics || model.items.isEmpty && model.statusMessage == nil && !wide {
            centeredPlayer(size: size)
        } else if wide {
            let side = min(size.width * 0.28, size.height * 0.46)
            let lyricsX = size.width * 0.512
            let lyricsWidth = size.width * 0.41
            let fontSize = max(22, min(size.width * 0.037, size.height * 0.062, 60))
            ZStack(alignment: .topLeading) {
                PlayerPanel(model: model, side: side)
                    .frame(width: side)
                    .position(x: size.width * 0.25, y: size.height * 0.5)
                lyricsArea(fontSize: fontSize, width: lyricsWidth)
                    .frame(width: lyricsWidth + fontSize, height: size.height)
                    .offset(x: lyricsX)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            let fontSize = max(22, min(size.width * 0.056, size.height * 0.062, 60))
            let lyricsWidth = size.width * 0.74
            lyricsArea(fontSize: fontSize, width: lyricsWidth)
                .frame(width: lyricsWidth + fontSize, height: size.height)
                .offset(x: size.width * 0.144)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func centeredPlayer(size: CGSize) -> some View {
        let side = min(size.width * 0.42, size.height * 0.5)
        return PlayerPanel(model: model, side: side)
            .frame(width: side)
            .position(x: size.width / 2, y: size.height / 2)
    }

    @ViewBuilder
    private func lyricsArea(fontSize: CGFloat, width: CGFloat) -> some View {
        if let message = model.statusMessage, model.items.isEmpty {
            Text(message)
                .font(.system(size: fontSize * 0.62, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
        } else {
            ImmersiveLyricsColumn(
                model: model,
                metrics: LyricsMetrics(fontSize: fontSize, width: width),
                anchorFraction: 0.35
            )
            .id(model.track?.identityKey ?? "none")
            .transition(.opacity.animation(.easeInOut(duration: 0.5)))
        }
    }

    // MARK: Window chrome

    private func chrome(size: CGSize) -> some View {
        ZStack {
            // Top left: close and switch to the compact floating lyrics.
            GlassCapsule {
                HStack(spacing: 2) {
                    ChromeIconButton(systemName: "xmark", help: "Close") { model.onClose?() }
                    ChromeIconButton(systemName: "pip", help: "Show compact lyrics") {
                        model.onShowCompactLyrics?()
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 6)
            .padding(.top, 6)

            // Top right: output device and volume.
            GlassCapsule {
                HStack(spacing: 10) {
                    AirPlayRouteButton()
                        .frame(width: 22, height: 22)
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 16)
                    VolumeSlider(value: Binding(
                        get: { model.extras.volume },
                        set: { model.setVolume($0) }
                    ))
                    .frame(width: 80)
                    Image(systemName: model.extras.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 18)
                }
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 8)
            .padding(.top, 6)

            // Bottom right: translation, lyrics and Up Next.
            HStack(spacing: 8) {
                if model.items.contains(where: { $0.line?.translation != nil }) {
                    GlassCircleToggle(
                        systemName: "translate",
                        isOn: model.showTranslation,
                        help: model.showTranslation ? "Hide Translation" : "Show Translation"
                    ) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                            model.showTranslation.toggle()
                        }
                    }
                } else if let name = model.downloadableLanguageName {
                    GlassCircleToggle(
                        systemName: "translate",
                        isOn: false,
                        help: "Download \(name) to show translations"
                    ) {
                        model.requestTranslationDownload()
                    }
                }
                GlassCapsule {
                    HStack(spacing: 4) {
                        ToggleChip(systemName: "quote.bubble.fill", isOn: model.showLyrics, help: "Lyrics") {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
                                model.showLyrics.toggle()
                            }
                        }
                        ToggleChip(systemName: "list.bullet", isOn: false, help: "Open Music") {
                            model.openMusic()
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Player panel (artwork, title, progress, transport)

private struct PlayerPanel: View {
    @ObservedObject var model: ImmersiveLyricsModel
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(image: model.artwork, side: side, isPlaying: model.isPlaying)
                .padding(.bottom, side * 0.065)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.track?.title ?? "Not Playing")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 8)
                CircleGlyphButton(
                    systemName: model.extras.favorited ? "star.fill" : "star",
                    help: model.extras.favorited ? "Undo Favorite" : "Favorite"
                ) { model.toggleFavorite() }
                MoreMenuButton(model: model)
            }
            .padding(.bottom, 14)

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ProgressScrubber(model: model)
            }
            .padding(.bottom, 18)

            TransportControls(model: model)
        }
    }

    private var subtitle: String {
        guard let track = model.track else { return " " }
        if track.album.isEmpty { return track.artist }
        if track.artist.isEmpty { return track.album }
        return "\(track.artist) — \(track.album)"
    }
}

private struct ArtworkView: View {
    let image: NSImage?
    let side: CGFloat
    let isPlaying: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.36, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.025, style: .continuous))
        .shadow(color: .black.opacity(isPlaying ? 0.32 : 0.2), radius: isPlaying ? 32 : 16, y: isPlaying ? 18 : 8)
        .scaleEffect(isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: isPlaying)
        .animation(.easeInOut(duration: 0.4), value: image != nil)
    }
}

private struct ProgressScrubber: View {
    @ObservedObject var model: ImmersiveLyricsModel
    @State private var dragFraction: CGFloat?
    @State private var hovering = false

    var body: some View {
        let duration = max(model.duration, 0.01)
        let current = model.position()
        let fraction = dragFraction ?? CGFloat(min(max(current / duration, 0), 1))
        let shown = dragFraction.map { TimeInterval($0) * duration } ?? current

        VStack(spacing: 6) {
            GeometryReader { proxy in
                let height: CGFloat = hovering || dragFraction != nil ? 8 : 5
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white.opacity(hovering || dragFraction != nil ? 0.9 : 0.72))
                        .frame(width: max(height, proxy.size.width * fraction))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.isScrubbing = true
                            dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let final = min(max(value.location.x / proxy.size.width, 0), 1)
                            model.seek(to: TimeInterval(final) * duration)
                            model.isScrubbing = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dragFraction = nil }
                        }
                )
                .animation(.easeOut(duration: 0.15), value: height)
            }
            .frame(height: 12)
            .onHover { hovering = $0 }

            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TransportControls: View {
    @ObservedObject var model: ImmersiveLyricsModel

    var body: some View {
        HStack(spacing: 0) {
            ModeButton(systemName: "shuffle", isOn: model.extras.shuffle, help: "Shuffle") {
                model.toggleShuffle()
            }
            Spacer(minLength: 0)
            TransportButton(systemName: "backward.fill", size: 26, help: "Previous") { model.previousTrack() }
            Spacer(minLength: 0)
            TransportButton(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: 32, help: model.isPlaying ? "Pause" : "Play") {
                model.togglePlayPause()
            }
            .frame(width: 44)
            Spacer(minLength: 0)
            TransportButton(systemName: "forward.fill", size: 26, help: "Next") { model.nextTrack() }
            Spacer(minLength: 0)
            ModeButton(
                systemName: model.extras.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: model.extras.repeatMode != .off,
                help: "Repeat"
            ) { model.cycleRepeat() }
        }
    }
}

private struct MoreMenuButton: View {
    @ObservedObject var model: ImmersiveLyricsModel

    var body: some View {
        Menu {
            Button("Edit Translations…") { model.openTranslationEditor() }
                .disabled(model.track == nil || model.items.isEmpty)
            Button("Open Translations File in TextEdit") { model.editTranslationsFile() }
                .disabled(model.track == nil)
            Button(model.showTranslation ? "Hide Translation" : "Show Translation") {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { model.showTranslation.toggle() }
            }
            if let name = model.downloadableLanguageName {
                Button("Download \(name) Translation…") { model.requestTranslationDownload() }
            }
            Divider()
            Button("Refresh Lyrics") { model.onRefreshLyrics?() }
            Button("Show Lyrics Folder in Finder") { model.onRevealLyricsFolder?() }
            Divider()
            Text("Lyrics source: \(model.lyricsSource)")
            Button("Open Music") { model.openMusic() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.white.opacity(0.16)))
        .contentShape(Circle())
        .noFocusRing()
        .help("More")
    }
}

// MARK: - Buttons

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.9))
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ModeButton: View {
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.85 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .animation(.easeOut(duration: 0.2), value: isOn)
        .help(help)
    }
}

private struct CircleGlyphButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .help(help)
    }
}

private struct ChromeIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ToggleChip: View {
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.9 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .help(help)
    }
}

private struct GlassCircleToggle: View {
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.9 : 0)))
                .glassBackground(in: Circle())
        }
        .buttonStyle(PressableStyle())
        .noFocusRing()
        .help(help)
    }
}

private struct GlassCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: 38)
            .glassBackground(in: Capsule())
    }
}

extension View {
    /// Chrome buttons never take keyboard focus, so no focus ring appears
    /// on the close button when the window opens.
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusable(false).focusEffectDisabled()
        } else {
            self.focusable(false)
        }
    }
}

private extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

private struct VolumeSlider: View {
    @Binding var value: Double
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(min(max(value / 100, 0), 1))
            let knobWidth: CGFloat = 22
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 5)
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: max(5, (proxy.size.width - knobWidth) * fraction + knobWidth / 2), height: 5)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knobWidth, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: (proxy.size.width - knobWidth) * fraction)
                    .scaleEffect(dragging ? 1.1 : 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let x = drag.location.x - knobWidth / 2
                        value = Double(min(max(x / (proxy.size.width - knobWidth), 0), 1) * 100)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 20)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
    }
}

/// The system output picker (AirPlay and other devices).
private struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white.withAlphaComponent(0.85), for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.systemBlue, for: .active)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - Translation editor

/// Lets the user correct any line's translation. Saved corrections go to the
/// song's translations file and override Apple's and on-device translations.
private struct TranslationEditorSheet: View {
    @ObservedObject var model: ImmersiveLyricsModel
    let request: TranslationEditorRequest

    @State private var drafts: [String]
    @FocusState private var focused: Int?
    @Environment(\.dismiss) private var dismiss

    init(model: ImmersiveLyricsModel, request: TranslationEditorRequest) {
        self.model = model
        self.request = request
        _drafts = State(initialValue: request.rows.map(\.translation))
    }

    private var changes: [(original: String, translation: String)] {
        request.rows.compactMap { row in
            let draft = drafts[row.id].trimmingCharacters(in: .whitespacesAndNewlines)
            return draft == row.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                ? nil
                : (original: row.original, translation: draft)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translations")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.track.map { "\($0.title) — \($0.artist)" } ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(request.rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.original)
                                    .font(.system(size: 13, weight: .semibold))
                                    .textSelection(.enabled)
                                TextField("Translation", text: $drafts[row.id])
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focused, equals: row.id)
                            }
                            .id(row.id)
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    guard let index = request.focusIndex else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(index, anchor: .center)
                        focused = index
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("Leave a field empty to use the automatic translation.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveTranslations(changes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 540)
    }
}

// MARK: - On-device translation download

/// Shows the system prompt that downloads a translation language, then
/// reloads the lyrics so the new translations appear.
private struct TranslationDownloadHost: ViewModifier {
    @ObservedObject var model: ImmersiveLyricsModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(TranslationDownloadTask(model: model))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationDownloadTask: ViewModifier {
    @ObservedObject var model: ImmersiveLyricsModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { model.translationLanguageReady() }
                } catch {
                    DiagnosticLogger.shared.warning("Translation download did not finish: \(error.localizedDescription)")
                }
            }
            .onChange(of: model.translationDownloadRequest) { _ in
                guard let code = model.downloadableLanguage else { return }
                let source = Locale.Language(identifier: code)
                if configuration?.source == source {
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(
                        source: source,
                        target: Locale.Language(identifier: "en")
                    )
                }
            }
    }
}

// MARK: - Background

/// Slowly drifting, heavily blurred artwork. The blur is baked into a tiny
/// image once per song and Core Animation moves it on the GPU at a low frame
/// rate, so the background costs almost no CPU.
struct ImmersiveBackground: NSViewRepresentable {
    let palette: ArtworkPalette

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.apply(palette)
    }
}

final class BackdropView: NSView {
    private let base = CALayer()
    private let layersSpec: [(scale: CGFloat, period: CFTimeInterval, reversed: Bool, opacity: Float, drift: CGPoint)] = [
        (1.75, 140, false, 1.0, CGPoint(x: 0.05, y: -0.04)),
        (1.25, 105, true, 0.65, CGPoint(x: -0.16, y: 0.12)),
        (0.95, 80, false, 0.5, CGPoint(x: 0.2, y: 0.16))
    ]
    private var artLayers: [CALayer] = []
    private let shade = CALayer()
    private var currentImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        root.addSublayer(base)
        for (index, spec) in layersSpec.enumerated() {
            let art = CALayer()
            art.contentsGravity = .resizeAspectFill
            art.magnificationFilter = .linear
            art.minificationFilter = .linear
            art.opacity = spec.opacity
            // Different crops keep the three layers from moving in lockstep.
            if index == 1 { art.contentsRect = CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.7) }
            if index == 2 { art.contentsRect = CGRect(x: 0.0, y: 0.25, width: 0.6, height: 0.6) }
            root.addSublayer(art)
            artLayers.append(art)
        }
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        root.addSublayer(shade)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ palette: ArtworkPalette) {
        let baseColor = (palette.colors.first ?? .darkGray).cgColor
        guard palette.backdrop !== currentImage || base.backgroundColor != baseColor else { return }
        currentImage = palette.backdrop
        let fade = CABasicAnimation(keyPath: "contents")
        fade.duration = 1.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        base.backgroundColor = baseColor
        for art in artLayers {
            art.add(fade, forKey: "fade")
            art.contents = palette.backdrop
            art.isHidden = palette.backdrop == nil
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        base.frame = bounds
        shade.frame = bounds
        let longest = max(bounds.width, bounds.height)
        for (art, spec) in zip(artLayers, layersSpec) {
            let side = longest * spec.scale
            art.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            art.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        startAnimations()
    }

    private func startAnimations() {
        let range = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 20)
        for (art, spec) in zip(artLayers, layersSpec) {
            if art.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = (spec.reversed ? -2 : 2) * CGFloat.pi
                spin.duration = spec.period
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                spin.preferredFrameRateRange = range
                art.add(spin, forKey: "spin")
            }
            art.removeAnimation(forKey: "drift")
            let drift = CABasicAnimation(keyPath: "position")
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            drift.fromValue = NSValue(point: CGPoint(
                x: center.x - bounds.width * spec.drift.x,
                y: center.y - bounds.height * spec.drift.y
            ))
            drift.toValue = NSValue(point: CGPoint(
                x: center.x + bounds.width * spec.drift.x,
                y: center.y + bounds.height * spec.drift.y
            ))
            drift.duration = spec.period * 0.37
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.preferredFrameRateRange = range
            art.add(drift, forKey: "drift")
        }
    }
}
