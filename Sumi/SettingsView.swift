import SwiftUI

struct SettingsView: View {
    static let defaultVimrc = """
    " One mapping per line. Supported: map / nmap / imap / vmap / noremap … / unmap / set
    " imap jj <Esc>
    " nmap H ^
    " nmap L $
    """

    static let themes: [(id: String, name: String)] = [
        ("default", "Default"), ("solarized", "Solarized"), ("nord", "Nord"), ("gruvbox", "Gruvbox"), ("sepia", "Sepia"),
        ("github", "GitHub"), ("one", "One"), ("dracula", "Dracula"), ("tokyonight", "Tokyo Night"),
        ("catppuccin", "Catppuccin"), ("rosepine", "Rosé Pine"),
    ]

    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var languageChanged = false
    @AppStorage("vimEnabled") private var vimEnabled = false
    @AppStorage("lineNumbers") private var lineNumbers = false
    @AppStorage("lineWrap") private var lineWrap = true
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("vimrc") private var vimrc = SettingsView.defaultVimrc
    @AppStorage("imeSwitch") private var imeSwitch = true
    @AppStorage("showFinished") private var showFinished = false
    @AppStorage("vimClipboard") private var vimClipboard = true
    @AppStorage("quickNoteHotkey") private var quickNoteHotkey = false
    @AppStorage("quickNoteKey") private var quickNoteKey = KeyCombo.quickNoteDefault
    @AppStorage("selectionToolbar") private var selectionToolbar = true
    @AppStorage("readableWidth") private var readableWidth = false
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("editorTheme") private var editorTheme = "default"
    @AppStorage("aiInlineCompletion") private var aiInlineCompletion = false

    @Environment(LibraryStore.self) private var store
    @State private var syncFailed = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            editor.tabItem { Label("Editor", systemImage: "pencil") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            keys.tabItem { Label("Keys", systemImage: "keyboard") }
            plugins.tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            ai.tabItem { Label("AI", systemImage: "apple.intelligence") }
        }
        .frame(width: 560, height: 520)
        .alert("iCloud Drive is not available", isPresented: $syncFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on iCloud Drive in System Settings › Apple Account › iCloud, then try again.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(L(text)).font(.caption).foregroundStyle(.secondary)
    }

    private var general: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    Text("Match System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "日本語").tag("ja")
                }
                .onChange(of: appLanguage) {
                    AppLanguage.set(appLanguage)
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        hint("The language changes the next time Sumi starts.")
                        Spacer()
                        Button("Relaunch Now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { Updater.shared.automaticallyChecks },
                    set: { Updater.shared.automaticallyChecks = $0 }
                ))
                HStack {
                    Text(String(format: L("Version %@"), Updater.currentVersion)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
                hint("Sumi asks GitHub once a day whether a newer release exists. Nothing about you or your notes is sent. Updates are accepted only when they carry the developer's signature.")
            }
            Section("Sync") {
                Toggle("Sync with iCloud Drive", isOn: Binding(
                    get: { store.usingICloud },
                    set: { on in if !store.setICloud(on) { syncFailed = true } }
                ))
                hint(store.usingICloud
                     ? "Notes are stored in iCloud Drive › Sumi and shared with your other Macs."
                     : "Notes are stored on this Mac only.")
            }
            Section("Quick Note") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(key: $quickNoteKey)
                    Button("Reset") { quickNoteKey = KeyCombo.quickNoteDefault }
                        .disabled(quickNoteKey == KeyCombo.quickNoteDefault)
                }
                hint("Click the button, then press the keys you want (with ⌘, ⌃ or ⌥). Esc cancels.")
                Toggle("Use this shortcut from any app (global hotkey)", isOn: $quickNoteHotkey)
            }
            Section("Notes") {
                Toggle("Show completed and dropped notes in lists", isOn: $showFinished)
            }
        }
        .formStyle(.grouped)
    }

    private var editor: some View {
        Form {
            Section("Editor") {
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 10...28)
                Toggle("Show line numbers", isOn: $lineNumbers)
                Toggle("Wrap long lines", isOn: $lineWrap)
                Toggle("Limit line length to a readable width", isOn: $readableWidth)
                Toggle("Show formatting toolbar when text is selected", isOn: $selectionToolbar)
            }
            Section("Vim") {
                Toggle("Enable Vim keybindings", isOn: $vimEnabled)
                Toggle("Switch to ASCII input when returning to normal mode", isOn: $imeSwitch)
                    .disabled(!vimEnabled)
                Toggle("Use system clipboard for yank and paste", isOn: $vimClipboard)
                    .disabled(!vimEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("vimrc")
                    TextEditor(text: $vimrc)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        .disabled(!vimEnabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Theme") {
                Picker("App appearance", selection: $appTheme) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Theme", selection: $editorTheme) {
                    ForEach(Self.themes, id: \.id) { Text(L($0.name)).tag($0.id) }
                }
                hint("Each theme has a light and a dark variant that follows the app appearance. For Solarized Dark, choose Solarized and set the app appearance to Dark.")
            }
            Section("Custom CSS") {
                HStack {
                    Text("styles.css")
                    Spacer()
                    Text(L(Customization.shared.customCSS.isEmpty ? "Not used" : "Loaded")).foregroundStyle(.secondary)
                    Button("Open") { Customization.shared.openStyles() }
                }
                hint("Your own CSS for the editor and the preview. Changes apply when you come back to Sumi.")
            }
        }
        .formStyle(.grouped)
    }

    private var keys: some View {
        let custom = Customization.shared
        return Form {
            Section("Keymap") {
                HStack {
                    Text("keymap.json")
                    Spacer()
                    Text("\(custom.keymap.count) custom bindings").foregroundStyle(.secondary)
                    Button("Open") { custom.openKeymap() }
                }
                hint("""
                Map keys to command ids, for example  { "cmd-shift-j": "core:telescope-tags", "cmd-e": "none" }
                Modifiers: cmd, ctrl, alt, shift. Keys: letters, digits, enter, tab, space, escape, backspace, left/right/up/down, f1–f12.
                Use "none" to turn a default shortcut off. Command ids are listed in Telescope (⌘K, then >).
                Changes apply when you come back to Sumi. Menus keep showing the default shortcuts.
                """)
                ForEach(custom.keymapProblems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Button("Copy All Command IDs") {
                    let all = AppState.commands + AIAction.allCases.map { AppCommand(id: $0.commandID, title: "AI: " + $0.title) }
                        + custom.pluginCommands
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(all.map { "\($0.id)\t\($0.title)" }.joined(separator: "\n"), forType: .string)
                }
            }
            Section("Vim") {
                hint("Vim mappings (map, nmap, imap…) are set in vimrc on the Editor tab.")
            }
        }
        .formStyle(.grouped)
    }

    private var plugins: some View {
        let custom = Customization.shared
        return Form {
            Section("Plugins") {
                HStack {
                    Text("Plugins folder")
                    Spacer()
                    Button("Open Folder") { custom.openPluginsFolder() }
                    Button("Reload") { custom.reload() }
                }
                hint("A plugin is a JavaScript file (.js) in this folder. It is loaded into the editor when Sumi starts, when you press Reload, or when you come back to Sumi. Plugins can do anything the editor can, so only add code you trust.")
            }
            Section("Installed") {
                if custom.plugins.isEmpty {
                    Text("No plugins installed").foregroundStyle(.secondary)
                }
                ForEach(custom.plugins, id: \.name) { p in
                    Label(p.name + ".js", systemImage: custom.loadedPlugins.contains(p.name) ? "checkmark.circle" : "circle.dotted")
                }
                ForEach(custom.pluginErrors, id: \.self) { e in
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Writing a plugin") {
                hint("Each plugin receives one object named sumi:")
                ForEach(Customization.pluginAPI, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        hint(item.detail)
                    }
                }
            }
            Section("Example") {
                Text(Customization.pluginExample)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    hint(custom.hasExamplePlugin
                         ? "example.js is installed. Try “Example: Insert Today’s Date” in Telescope (⌘K, then >)."
                         : "Adds this code to the plugins folder as example.js.")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Customization.pluginExample, forType: .string)
                    }
                    Button("Add Example Plugin") { custom.addExamplePlugin() }
                        .disabled(custom.hasExamplePlugin)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var ai: some View {
        Form {
            Section("Apple Intelligence") {
                if let reason = AIRunner.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Available on this Mac", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Toggle("Suggest the next words while typing (Tab to accept)", isOn: $aiInlineCompletion)
                    .disabled(AIRunner.unavailableReason != nil)
                hint(String(format: L("""
                AI actions run on this Mac with Apple Intelligence; note text is not sent to a server by Sumi.
                Open them with ⌘⇧A, the AI menu, or the AI button in the selection toolbar. They work on the selected text, or on the whole note.
                The on-device model reads about the first %d characters of long text.
                """), AIRunner.maxCharacters))
            }
        }
        .formStyle(.grouped)
    }
}
