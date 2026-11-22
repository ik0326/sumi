import AppKit
import SwiftUI

/// A key with modifiers, written like `cmd-shift-t` in keymap.json.
struct KeyCombo: Hashable {
    var mods: UInt // 1 cmd, 2 ctrl, 4 alt, 8 shift
    var key: String

    private static let special: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt = 0
        if f.contains(.command) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.option) { m |= 4 }
        if f.contains(.shift) { m |= 8 }
        if let s = Self.special[event.keyCode] {
            key = s
        } else if let c = event.characters(byApplyingModifiers: [])?.lowercased(), !c.isEmpty {
            key = c
        } else {
            return nil
        }
        mods = m
    }

    init?(string: String) {
        var text = string.lowercased().trimmingCharacters(in: .whitespaces)
        var last = ""
        if text.hasSuffix("-") { // the "-" key itself, e.g. "cmd--"
            last = "-"
            text.removeLast()
            if text.hasSuffix("-") { text.removeLast() }
        }
        var parts = text.split(separator: "-").map(String.init)
        if last.isEmpty {
            guard let k = parts.popLast() else { return nil }
            last = k
        }
        var m: UInt = 0
        for p in parts {
            switch p {
            case "cmd", "command", "meta": m |= 1
            case "ctrl", "control": m |= 2
            case "alt", "opt", "option": m |= 4
            case "shift": m |= 8
            default: return nil
            }
        }
        if last == "return" { last = "enter" }
        if last == "esc" { last = "escape" }
        let functionKey = last.count > 1 && last.hasPrefix("f") && Int(last.dropFirst()) != nil
        // Plain keys would swallow typing, so a real modifier is required.
        guard m & 7 != 0 || functionKey else { return nil }
        mods = m
        key = last
    }
}

extension KeyCombo {
    private static let codes: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        for (code, name) in special where code != 76 { m[name] = code }
        return m
    }()

    /// Virtual key code, for a system-wide hotkey.
    var keyCode: UInt16? { Self.codes[key] }

    var display: String {
        let names = ["enter": "↩", "tab": "⇥", "space": "Space", "backspace": "⌫", "escape": "⎋", "delete": "⌦",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return (mods & 2 != 0 ? "⌃" : "") + (mods & 4 != 0 ? "⌥" : "") + (mods & 8 != 0 ? "⇧" : "")
            + (mods & 1 != 0 ? "⌘" : "") + (names[key] ?? key.uppercased())
    }

    /// The same key as a menu shortcut (nil for keys menus cannot show).
    var shortcut: KeyboardShortcut? {
        let special: [String: KeyEquivalent] = [
            "enter": .return, "tab": .tab, "space": .space, "backspace": .delete, "escape": .escape,
            "delete": .deleteForward, "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
        ]
        guard let k = special[key] ?? (key.count == 1 ? KeyEquivalent(Character(key)) : nil) else { return nil }
        var m: EventModifiers = []
        if mods & 1 != 0 { m.insert(.command) }
        if mods & 2 != 0 { m.insert(.control) }
        if mods & 4 != 0 { m.insert(.option) }
        if mods & 8 != 0 { m.insert(.shift) }
        return KeyboardShortcut(k, modifiers: m)
    }

    /// The keymap.json spelling, e.g. `cmd-shift-c`.
    var string: String {
        (mods & 2 != 0 ? "ctrl-" : "") + (mods & 4 != 0 ? "alt-" : "") + (mods & 8 != 0 ? "shift-" : "")
            + (mods & 1 != 0 ? "cmd-" : "") + key
    }

    static let quickNoteDefault = "cmd-shift-c"
    /// The Quick Note key from Settings (falls back to the default when it cannot be used).
    static func quickNote(_ text: String) -> KeyCombo {
        if let c = KeyCombo(string: text), c.keyCode != nil { return c }
        return KeyCombo(string: quickNoteDefault)!
    }
}

/// Per-Mac customization: keymap.json, styles.css and plugins/ in Application Support/Sumi.
@MainActor @Observable
final class Customization {
    static let shared = Customization()

    private(set) var keymap: [KeyCombo: String] = [:]
    private(set) var keymapProblems: [String] = []
    private(set) var customCSS = ""
    private(set) var plugins: [(name: String, code: String)] = []
    /// Bumped when the plugin files change, so editors reload.
    private(set) var pluginVersion = 0
    var pluginCommands: [AppCommand] = []
    var loadedPlugins: [String] = []
    var pluginErrors: [String] = []

    @ObservationIgnored private var run: ((String) -> Void)?
    @ObservationIgnored private var monitor: Any?

    static var dir: URL { LibraryStore.localRoot }
    var keymapFile: URL { Self.dir.appendingPathComponent("keymap.json") }
    var stylesFile: URL { Self.dir.appendingPathComponent("styles.css") }
    var pluginsDir: URL { Self.dir.appendingPathComponent("plugins", isDirectory: true) }

    func start(run: @escaping (String) -> Void) {
        self.run = run
        reload()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.keymap.isEmpty, let combo = KeyCombo(event: event),
                  let id = self.keymap[combo] else { return event }
            if id != "none" { self.run?(id) }
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        var map: [KeyCombo: String] = [:]
        var problems: [String] = []
        if let data = try? Data(contentsOf: keymapFile) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj {
                    guard let combo = KeyCombo(string: k) else { problems.append(String(format: L("Cannot use key “%@”"), k)); continue }
                    guard let id = v as? String, !id.isEmpty else { problems.append(String(format: L("“%@” needs a command id"), k)); continue }
                    map[combo] = id
                }
            } else {
                problems.append(L("keymap.json is not valid JSON"))
            }
        }
        if map != keymap { keymap = map }
        if problems != keymapProblems { keymapProblems = problems.sorted() }

        let css = (try? String(contentsOf: stylesFile, encoding: .utf8)) ?? ""
        if css != customCSS { customCSS = css }

        let files = ((try? FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let found = files.compactMap { f in
            (try? String(contentsOf: f, encoding: .utf8)).map { (name: f.deletingPathExtension().lastPathComponent, code: $0) }
        }
        if found.map({ $0.name + "\u{0}" + $0.code }) != plugins.map({ $0.name + "\u{0}" + $0.code }) {
            plugins = found
            pluginCommands = []
            loadedPlugins = []
            pluginErrors = []
            pluginVersion += 1
        }
    }

    func openKeymap() {
        if !FileManager.default.fileExists(atPath: keymapFile.path) {
            try? "{\n  \"cmd-shift-j\": \"core:telescope-tags\"\n}\n".write(to: keymapFile, atomically: true, encoding: .utf8)
            reload()
        }
        NSWorkspace.shared.open(keymapFile)
    }

    func openStyles() {
        if !FileManager.default.fileExists(atPath: stylesFile.path) {
            let sample = """
            /* Custom styles for the editor and the preview. Saved changes apply when you return to Sumi.
               Colors:  --bg --fg --muted --border --accent --heading --link --code-bg --string --keyword --number --comment
               Example:
               :root { --heading: #c2410c; }
               .markdown-body h2 { border-bottom: 1px solid var(--border); }
               #editor .cm-content { letter-spacing: 0.01em; }
            */

            """
            try? sample.write(to: stylesFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(stylesFile)
    }

    func openPluginsFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let readme = pluginsDir.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try? Self.pluginReadme.write(to: readme, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(pluginsDir)
    }

    /// Writes the example plugin into the plugins folder and loads it.
    func addExamplePlugin() {
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let file = pluginsDir.appendingPathComponent("example.js")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Self.pluginExample.write(to: file, atomically: true, encoding: .utf8)
        }
        reload()
    }

    var hasExamplePlugin: Bool { plugins.contains { $0.name == "example" } }

    /// The plugin API, shown in Settings.
    static let pluginAPI: [(name: String, detail: String)] = [
        ("sumi.registerCommand(id, title, fn)", "Adds a command. It appears in Telescope (⌘K, then >) and can be bound to a key in keymap.json."),
        ("sumi.runCommand(id)", "Runs any command by its id."),
        ("sumi.insertText(text)", "Replaces the selection, or inserts at the cursor."),
        ("sumi.getText()  /  sumi.getSelection()", "The note text / the selected text."),
        ("sumi.addStyle(css)", "Adds CSS to the editor and the preview."),
        ("sumi.onPreviewRender(fn)", "fn(previewElement) runs after every preview render."),
        ("sumi.md", "The markdown-it instance of the preview. sumi.md.use(plugin) adds Markdown syntax."),
        ("sumi.view", "The CodeMirror 6 EditorView, for advanced editor changes."),
    ]

    private static let pluginReadme = """
    # Sumi plugins

    Every `*.js` file in this folder is loaded into the editor when Sumi starts or when you return to it
    after changing a file. A plugin is plain JavaScript; it receives one object named `sumi`:

    | Member | What it does |
    | --- | --- |
    | `sumi.md` | The markdown-it instance of the preview. `sumi.md.use(plugin)` adds syntax. |
    | `sumi.view` | The CodeMirror 6 `EditorView`. |
    | `sumi.registerCommand(id, title, fn)` | Adds a command. It appears in Telescope (`⌘K`, then `>`) and can be bound in keymap.json. |
    | `sumi.runCommand(id)` | Runs any command by id. |
    | `sumi.addStyle(css)` | Adds CSS to the editor and the preview. |
    | `sumi.onPreviewRender(fn)` | `fn(previewElement)` runs after every preview render. |
    | `sumi.getText()` / `sumi.getSelection()` | The note text / the selected text. |
    | `sumi.insertText(text)` | Replaces the selection (or inserts at the cursor). |

    Plugins run with full access to the editor, so only install code you trust.
    The same guide, with an example you can add in one click, is in Settings › Plugins.

    """

    static let pluginExample = """
    // Example plugin: two commands and one style.
    sumi.registerCommand('example:insert-date', 'Example: Insert Today’s Date', () => {
      sumi.insertText(new Date().toISOString().slice(0, 10))
    })

    sumi.registerCommand('example:upper-case', 'Example: Upper-case Selection', () => {
      const text = sumi.getSelection()
      if (text) sumi.insertText(text.toUpperCase())
    })

    // Open external links in the preview with a small arrow.
    sumi.addStyle('.markdown-body a[href^="http"]::after { content: " ↗"; font-size: 0.8em; }')

    """
}

/// A button that records the next key press as a shortcut.
struct ShortcutRecorder: View {
    @Binding var key: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Press the keys…") : KeyCombo.quickNote(key).display)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .help("Click, then press the shortcut you want. Esc cancels.")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                stop() // plain Esc cancels
                return nil
            }
            // Needs ⌘, ⌃ or ⌥ (or a function key) so it cannot swallow normal typing.
            guard let combo = KeyCombo(event: event), combo.keyCode != nil,
                  KeyCombo(string: combo.string) != nil else {
                NSSound.beep()
                return nil
            }
            key = combo.string
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
