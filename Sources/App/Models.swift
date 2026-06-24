import Cocoa

let appVersion: String = {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    return "\(version) (\(build))"
}()
let githubURL = "https://github.com/nickustinov/itsypad-macos"

struct ShortcutKeys: Codable, Equatable {
    var modifiers: UInt
    var keyCode: UInt16
    var isTripleTap: Bool
    var tapModifier: String?
}

/// Number of rapid taps on a modifier key that triggers a tap-style shortcut.
/// 2 = double-tap. Bump to 3 to require a triple-tap (less prone to false triggers).
let modifierTapCount = 2

/// Maximum interval between consecutive taps for them to count as one multi-tap gesture.
/// 0.4s balances comfort (macOS double-click is ~0.5s) against accidental double-taps
/// from ordinary Option-key use (accented characters, compound shortcuts). Lower it to
/// make accidental triggers rarer; raise it if deliberate double-taps get missed.
let modifierTapWindow: TimeInterval = 0.4
