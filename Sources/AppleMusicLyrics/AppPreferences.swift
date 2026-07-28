import AppKit
import Foundation

enum FloatingLyricsMode: String, CaseIterable {
    case immersive
    case desktop

    var title: String {
        switch self {
        case .immersive: return "Immersive"
        case .desktop: return "Desktop"
        }
    }
}

enum FloatingLyricsSpaceBehavior: String, CaseIterable {
    case currentDesktop
    case allSpaces

    var title: String {
        switch self {
        case .currentDesktop: return "Current Desktop"
        case .allSpaces: return "All Desktops"
        }
    }
}

enum FloatingLyricsBlurStrength: String, CaseIterable {
    case subtle
    case regular
    case strong

    var title: String { rawValue.capitalized }

    var material: NSVisualEffectView.Material {
        switch self {
        case .subtle: return .sidebar
        case .regular: return .popover
        case .strong: return .hudWindow
        }
    }
}

enum AppPreferences {
    private enum Key {
        static let floatingVisible = "floatingLyrics.visible"
        static let locked = "floatingLyrics.locked"
        static let clickThrough = "floatingLyrics.clickThrough"
        static let mode = "floatingLyrics.mode"
        static let opacity = "floatingLyrics.opacity"
        static let blurStrength = "floatingLyrics.blurStrength"
        static let spaceBehavior = "floatingLyrics.spaceBehavior"
        static let showOverFullScreen = "floatingLyrics.showOverFullScreen"
        static let showTranslation = "floatingLyrics.showTranslation"
        static let showTransliteration = "floatingLyrics.showTransliteration"
        static let framesByDisplay = "floatingLyrics.framesByDisplay"
        static let lastDisplay = "floatingLyrics.lastDisplay"
        static let immersiveHeight = "floatingLyrics.immersiveHeight"
    }

    static var floatingLyricsVisible: Bool {
        get { defaultedBool(Key.floatingVisible, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.floatingVisible) }
    }

    static var floatingLyricsLocked: Bool {
        get { UserDefaults.standard.bool(forKey: Key.locked) }
        set { UserDefaults.standard.set(newValue, forKey: Key.locked) }
    }

    static var floatingLyricsClickThrough: Bool {
        get { UserDefaults.standard.bool(forKey: Key.clickThrough) }
        set { UserDefaults.standard.set(newValue, forKey: Key.clickThrough) }
    }

    static var floatingLyricsMode: FloatingLyricsMode {
        get { enumValue(Key.mode, default: .immersive) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.mode) }
    }

    static var floatingLyricsOpacity: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.opacity) != nil else { return 0.92 }
            return min(1, max(0.35, UserDefaults.standard.double(forKey: Key.opacity)))
        }
        set { UserDefaults.standard.set(min(1, max(0.35, newValue)), forKey: Key.opacity) }
    }

    static var floatingLyricsBlurStrength: FloatingLyricsBlurStrength {
        get { enumValue(Key.blurStrength, default: .strong) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.blurStrength) }
    }

    static var floatingLyricsSpaceBehavior: FloatingLyricsSpaceBehavior {
        get { enumValue(Key.spaceBehavior, default: .allSpaces) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.spaceBehavior) }
    }

    static var floatingLyricsShowOverFullScreen: Bool {
        get { defaultedBool(Key.showOverFullScreen, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showOverFullScreen) }
    }

    static var floatingLyricsShowTranslation: Bool {
        get { defaultedBool(Key.showTranslation, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTranslation) }
    }

    static var floatingLyricsShowTransliteration: Bool {
        get { defaultedBool(Key.showTransliteration, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTransliteration) }
    }

    static var floatingLyricsFramesByDisplay: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Key.framesByDisplay) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Key.framesByDisplay) }
    }

    static var floatingLyricsLastDisplay: String? {
        get { UserDefaults.standard.string(forKey: Key.lastDisplay) }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastDisplay) }
    }

    static var floatingLyricsImmersiveHeight: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.immersiveHeight) != nil else { return 380 }
            return max(220, UserDefaults.standard.double(forKey: Key.immersiveHeight))
        }
        set { UserDefaults.standard.set(max(220, newValue), forKey: Key.immersiveHeight) }
    }

    private static func defaultedBool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? value
            : UserDefaults.standard.bool(forKey: key)
    }

    private static func enumValue<T: RawRepresentable>(
        _ key: String,
        default value: T
    ) -> T where T.RawValue == String {
        guard let rawValue = UserDefaults.standard.string(forKey: key),
              let result = T(rawValue: rawValue) else { return value }
        return result
    }
}
