import Foundation

enum AppPreferences {
    private static let floatingVisibleKey = "floatingLyrics.visible"

    static var floatingLyricsVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: floatingVisibleKey) == nil {
                // Default: show floating window on first launch.
                return true
            }
            return UserDefaults.standard.bool(forKey: floatingVisibleKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: floatingVisibleKey)
        }
    }
}
