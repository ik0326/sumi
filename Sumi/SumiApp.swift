import SwiftUI

@main
struct SumiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: LibraryStore
    @State private var app: AppState

    init() {
        let store = LibraryStore()
        _store = State(initialValue: store)
        _app = State(initialValue: AppState(store: store))
    }

    var body: some Scene {
        Window("Sumi", id: "main") {
            ContentView()
                .environment(store)
                .environment(app)
                .frame(minWidth: 860, minHeight: 480)
        }
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands(app: app) }

        WindowGroup("Quick Note", id: "quick", for: String.self) { $noteID in
            QuickNoteView(noteID: noteID)
                .environment(store)
                .frame(minWidth: 420, minHeight: 300)
        }
        .defaultSize(width: 640, height: 520)

        WindowGroup("Markdown File", id: "file", for: URL.self) { $url in
            if let url {
                FileNoteView(url: url)
                    .frame(minWidth: 420, minHeight: 300)
            }
        }
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage("quickNoteHotkey") private var quickNoteHotkey = false
    @AppStorage("quickNoteKey") private var quickNoteKey = KeyCombo.quickNoteDefault
    @AppStorage("listWidth") private var listWidth = 290.0
    @AppStorage("appTheme") private var appTheme = "system"
    @State private var dragStart: Double?

    var body: some View {
        let visibility = Binding<NavigationSplitViewVisibility>(
            get: { app.distractionFree || !app.sidebarVisible ? .detailOnly : .all },
            set: { v in if !app.distractionFree { app.sidebarVisible = v != .detailOnly } }
        )
        NavigationSplitView(columnVisibility: visibility) {
            SidebarView()
                .modifier(ThemedPane(part: .sidebar))
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } detail: {
            HStack(spacing: 0) {
                if !app.distractionFree {
                    NoteListView()
                        .frame(width: listWidth)
                        .modifier(ThemedPane(part: .list))
                    Divider()
                        .overlay {
                            Color.clear
                                .frame(width: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { v in
                                    if dragStart == nil { dragStart = listWidth }
                                    listWidth = min(max((dragStart ?? listWidth) + v.translation.width, 220), 520)
                                }.onEnded { _ in dragStart = nil })
                        }
                }
                EditorPane()
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(ThemedPane(part: .editor))
            }
        }
        .modifier(NoteWindowChrome(app: app))
        .onChange(of: app.selectedNoteID) { old, new in
            app.recordHistory(from: old, to: new)
        }
        .onAppear {
            app.openQuickNoteWindow = { id in openWindow(id: "quick", value: id) }
            FileOpener.shared.handler = { url in openWindow(id: "file", value: url) }
            registerHotkey()
            applyTheme()
            Updater.shared.start()
            Customization.shared.start { [app] id in (AppState.focused ?? app).run(id) }
        }
        .onChange(of: appTheme) { applyTheme() }
        .onChange(of: quickNoteHotkey) { registerHotkey() }
        .onChange(of: quickNoteKey) { registerHotkey() }
    }

    private func applyTheme() {
        NSApp.appearance = appTheme == "light" ? NSAppearance(named: .aqua)
            : appTheme == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    private func registerHotkey() {
        GlobalHotKey.shared.set(enabled: quickNoteHotkey, combo: .quickNote(quickNoteKey)) { [app] in app.quickNote() }
    }
}

/// What every note window needs: Telescope, the sheets, and telling menus which window is in front.
struct NoteWindowChrome: ViewModifier {
    let app: AppState
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let mode = app.telescope {
                    TelescopeView(mode: mode).id(mode)
                }
            }
            .sheet(isPresented: Binding(get: { app.showRevisions }, set: { app.showRevisions = $0 })) {
                RevisionsView().environment(app)
            }
            .sheet(isPresented: Binding(get: { app.tagSettingsID != nil }, set: { if !$0 { app.tagSettingsID = nil } })) {
                if let id = app.tagSettingsID { TagSettingsView(tagID: id).environment(app) }
            }
            .sheet(item: Binding(get: { app.ai }, set: { app.ai = $0 })) { request in
                AIPanelView(request: request).environment(app)
            }
            .onAppear { if activeState == .key { AppState.focused = app } }
            .onChange(of: activeState) { if activeState == .key { AppState.focused = app } }
            .modifier(ThemedWindow())
    }
}

/// A single note in its own window.
struct QuickNoteView: View {
    let noteID: String?
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var app: AppState?

    var body: some View {
        Group {
            if let app {
                EditorPane()
                    .modifier(ThemedPane(part: .editor))
                    .modifier(NoteWindowChrome(app: app))
                    .environment(app)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard app == nil else { return }
            let state = AppState(store: store)
            state.selectedNoteID = noteID
            state.openQuickNoteWindow = { id in openWindow(id: "quick", value: id) }
            app = state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { state.titleFocusRequest += 1 }
        }
    }
}

struct AppCommands: Commands {
    let app: AppState
    @AppStorage("quickNoteKey") private var quickNoteKey = KeyCombo.quickNoteDefault

    private func item(_ title: String, _ id: String) -> Button<Text> {
        Button(L(title)) { (AppState.focused ?? app).run(id) }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.checkFromMenu() } }
            Button("Acknowledgements") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("editor/THIRD_PARTY_NOTICES.txt") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        CommandGroup(replacing: .newItem) {
            item("New Note", "core:new-note").keyboardShortcut("n")
            item("Quick Note", "application:quick-note").keyboardShortcut(KeyCombo.quickNote(quickNoteKey).shortcut)
            item("New Notebook…", "core:new-notebook").keyboardShortcut("n", modifiers: [.command, .shift])
            item("Choose a Template…", "core:choose-template").keyboardShortcut("t")
            Divider()
            Button("Open File…") { FileOpener.shared.choose() }.keyboardShortcut("o")
            Button("Import Markdown…") { app.importMarkdown() }
            Button("Export as Markdown…") { app.exportSelected() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            item("Export as HTML…", "export-as-html:export")
            item("Print / Save as PDF…", "export-print:print")
        }

        CommandGroup(replacing: .saveItem) {
            item("Save", "core:save-note").keyboardShortcut("s")
        }

        CommandGroup(replacing: .sidebar) {
            item("Toggle Preview", "view:toggle-preview").keyboardShortcut("e")
            item("Toggle Side by Side", "view:toggle-side-by-side").keyboardShortcut("p")
            item("Toggle Distraction Free", "view:toggle-distraction-free")
                .keyboardShortcut("d", modifiers: [.command, .shift])
            item("Toggle Sidebar", "view:toggle-sidebar").keyboardShortcut("/")
            Divider()
            item("Telescope", "core:toggle-telescope").keyboardShortcut("k")
            item("Search Notes", "core:find").keyboardShortcut("f", modifiers: [.command, .shift])
            item("Search All Notes", "core:find-global").keyboardShortcut("f", modifiers: [.command, .shift, .option])
            Divider()
            item("Back", "core:navigate-back")
            item("Forward", "core:navigate-forward")
            item("Focus Sidebar", "core:sidebar-focus")
            item("Focus Note List", "core:focus-note-list-bar").keyboardShortcut("1")
            item("Focus Editor", "editor:focus-mde").keyboardShortcut("2")
            Divider()
        }

        CommandMenu("Format") {
            item("Bold", "core:strong").keyboardShortcut("b")
            item("Italic", "core:emphasize").keyboardShortcut("i")
            item("Strikethrough", "core:strikethrough")
            item("Inline Code", "core:toggle-inline-code")
            item("Highlight", "core:toggle-inline-mark-tag")
            item("Link", "core:insert-link").keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
            item("Heading 1", "core:toggle-heading-1")
            item("Heading 2", "core:toggle-heading-2")
            item("Heading 3", "core:toggle-heading-3")
            item("Blockquote", "core:toggle-blockquote").keyboardShortcut("'")
            item("Bulleted List", "core:toggle-bulleted-list").keyboardShortcut("l", modifiers: [.command, .shift])
            item("Numbered List", "core:toggle-numbered-list")
            item("Task List", "core:toggle-task-list")
            Divider()
            item("Code Block", "core:insert-code-block")
            item("Horizontal Rule", "core:insert-horizontal-rule")
            Menu("Table") {
                item("Insert Table", "core:insert-table")
                item("Format", "table-editor:format")
                Divider()
                item("Insert Row", "table-editor:insert-row")
                item("Insert Column", "table-editor:insert-column")
                item("Delete Row", "table-editor:delete-row")
                item("Delete Column", "table-editor:delete-column")
                Divider()
                item("Move Row Up", "table-editor:move-row-up")
                item("Move Row Down", "table-editor:move-row-down")
                item("Move Column Left", "table-editor:move-column-left")
                item("Move Column Right", "table-editor:move-column-right")
                Divider()
                item("Align Left", "table-editor:align-left")
                item("Align Center", "table-editor:align-center")
                item("Align Right", "table-editor:align-right")
                item("Clear Alignment", "table-editor:align-none")
            }
        }

        CommandMenu("AI") {
            item("AI Actions…", "ai:menu").keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            ForEach(AIAction.allCases) { action in
                item(action.title, action.commandID)
            }
        }

        CommandMenu("Note") {
            item("Note Actions…", "core:show-editor-action-menu").keyboardShortcut("j")
            item("Duplicate", "core:duplicate-note").keyboardShortcut("d")
            item("Pin / Unpin", "core:pin-note-to-top")
            item("Copy Note Link", "editor:copy-link")
            item("Add Tags", "editor:focus-tags").keyboardShortcut("t", modifiers: [.command, .shift])
            item("Search Tags…", "core:telescope-tags")
            item("Table of Contents…", "core:telescope-toc")
            item("Revision History…", "core:show-revisions")
            Divider()
            item("Status: None", "editor:change-note-status-none").keyboardShortcut("1", modifiers: [.command, .control])
            item("Status: Active", "editor:change-note-status-active").keyboardShortcut("2", modifiers: [.command, .control])
            item("Status: On Hold", "editor:change-note-status-onhold").keyboardShortcut("3", modifiers: [.command, .control])
            item("Status: Completed", "editor:change-note-status-completed").keyboardShortcut("4", modifiers: [.command, .control])
            item("Status: Dropped", "editor:change-note-status-dropped").keyboardShortcut("5", modifiers: [.command, .control])
            Divider()
            item("Move to Trash", "core:delete-note")
        }
    }
}
