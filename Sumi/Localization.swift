import AppKit

/// Looks up a display string in the current app language. Unknown strings are returned unchanged.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

enum AppLanguage {
    /// The language the app is running in.
    static var isJapanese: Bool { Bundle.main.preferredLocalizations.first == "ja" }

    /// "system", "en" or "ja". Takes effect at the next launch.
    static func set(_ code: String) {
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
