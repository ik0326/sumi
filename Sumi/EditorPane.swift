import SwiftUI

struct EditorPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app

    @AppStorage("vimEnabled") private var vimEnabled = false
    @AppStorage("lineNumbers") private var lineNumbers = false
    @AppStorage("lineWrap") private var lineWrap = true
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("vimrc") private var vimrc = SettingsView.defaultVimrc
    @AppStorage("imeSwitch") private var imeSwitch = true
    @AppStorage("vimClipboard") private var vimClipboard = true
    @AppStorage("selectionToolbar") private var selectionToolbar = true
    @AppStorage("readableWidth") private var readableWidth = false
    @AppStorage("editorTheme") private var editorTheme = "default"
    @AppStorage("aiInlineCompletion") private var aiInlineCompletion = false

    @FocusState private var titleFocused: Bool

    private var note: Note? { app.selectedNoteID.flatMap { store.notes[$0] } }

    var body: some View {
        @Bindable var app = app
        let note = self.note

        VStack(spacing: 0) {
            if let note, let file = store.fileURL {
                fileHeader(file)
                Divider()
            } else if let note {
                header(note).zIndex(1)
                backlinks(note)
                Divider()
            }
            EditorWebView(
                noteID: note?.id,
                readOnly: note?.trashed ?? true,
                mode: app.viewMode,
                options: EditorOptions(vim: vimEnabled, lineNumbers: lineNumbers, lineWrap: lineWrap,
                                       fontSize: fontSize, vimrc: vimrc, imeSwitch: imeSwitch,
                                       clipboard: vimClipboard, toolbar: selectionToolbar, readable: readableWidth,
                                       theme: editorTheme, customCSS: Customization.shared.customCSS,
                                       aiComplete: aiInlineCompletion && AIRunner.unavailableReason == nil,
                                       aiAvailable: AIRunner.unavailableReason == nil),
                reloadToken: app.editorReloadToken &+ (note.flatMap { store.externalVersion[$0.id] } ?? 0),
                pluginVersion: Customization.shared.pluginVersion,
                store: store,
                app: app
            )
            .opacity(note == nil ? 0 : 1)
            .overlay {
                if note == nil {
                    ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil",
                                           description: Text("Press ⌘N to create a note."))
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
              if store.fileURL == nil {
                Button { app.run("core:navigate-back") } label: { Image(systemName: "chevron.left") }
                    .help("Back (⌘←)")
                Button { app.run("core:navigate-forward") } label: { Image(systemName: "chevron.right") }
                    .help("Forward (⌘→)")
              }
            }
            ToolbarItemGroup {
                Picker("View", selection: $app.viewMode) {
                    Image(systemName: "pencil").tag(ViewMode.edit).help("Editor")
                    Image(systemName: "rectangle.split.2x1").tag(ViewMode.split).help("Side by Side (⌘P)")
                    Image(systemName: "eye").tag(ViewMode.preview).help("Preview (⌘E)")
                }
                .pickerStyle(.segmented)
                if store.fileURL == nil {
                    Button { app.run("view:toggle-distraction-free") } label: {
                        Image(systemName: app.distractionFree ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Distraction Free (⌘⇧D)")
                }
                if let note, store.fileURL == nil {
                    Menu {
                        NoteActions(note: note)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Note Actions (⌘J)")
                }
            }
        }
        .onChange(of: app.titleFocusRequest) {
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    /// Shown instead of the note header when a Markdown file is edited in place.
    private func fileHeader(_ file: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(file.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(file.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func backlinks(_ note: Note) -> some View {
        let links = store.backlinks(to: note.id)
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Label("Linked from", systemImage: "arrow.uturn.left").foregroundStyle(.secondary)
                    ForEach(links) { n in
                        Button(n.displayTitle) { app.open(noteID: n.id) }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                }
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if note.trashed {
                HStack {
                    Label("This note is in the Trash.", systemImage: "trash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        store.restore(note.id)
                        app.selectedNoteID = nil
                    }
                }
                .font(.callout)
            }

            TextField("Untitled", text: Binding(
                get: { store.notes[note.id]?.title ?? "" },
                set: { v in store.update(note.id) { $0.title = v } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .bold))
            .focused($titleFocused)
            .disabled(note.trashed)
            .onSubmit { app.editor.focus() }

            HStack(spacing: 12) {
                Menu {
                    Button("No Notebook") { store.update(note.id, touch: false) { $0.bookId = nil } }
                    Divider()
                    ForEach(store.flatBooks, id: \.book.id) { entry in
                        Button(String(repeating: "    ", count: entry.depth) + entry.book.name) {
                            store.update(note.id, touch: false) { $0.bookId = entry.book.id }
                        }
                    }
                } label: {
                    Label(store.book(note.bookId)?.name ?? L("No Notebook"), systemImage: "book.closed")
                }
                .fixedSize()

                Menu {
                    ForEach(NoteStatus.allCases) { status in
                        Button {
                            store.update(note.id, touch: false) { $0.status = status }
                        } label: {
                            Label(status.label, systemImage: status.symbol)
                        }
                    }
                } label: {
                    Label(note.status == .none ? L("Status") : note.status.label, systemImage: note.status.symbol)
                        .foregroundStyle(note.status.color)
                }
                .fixedSize()

                TagBar(note: note)
                Spacer(minLength: 0)
            }
            .menuStyle(.borderlessButton)
            .font(.callout)
            .disabled(note.trashed)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
