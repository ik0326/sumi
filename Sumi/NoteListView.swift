import SwiftUI

struct NoteListView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @AppStorage("sortKey") private var sortKey: SortKey = .updated
    @AppStorage("showFinished") private var showFinished = false
    @FocusState private var focus: Field?

    private enum Field { case search, list }

    private var title: String {
        switch app.sidebar ?? .all {
        case .all: L("All Notes")
        case .book(let id): store.book(id)?.name ?? L("Notebook")
        case .status(let s): s.label
        case .tag(let id): "#" + (store.tag(id)?.name ?? "tag")
        case .trash: L("Trash")
        }
    }

    private var notes: [Note] {
        store.filtered(app.sidebar, search: app.search, sort: sortKey, showFinished: showFinished,
                       tags: app.tagFilter, workspace: app.workspace)
    }

    var body: some View {
        @Bindable var app = app
        let notes = self.notes

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $app.search)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
                    .onSubmit {
                        if app.selectedNoteID == nil || !notes.contains(where: { $0.id == app.selectedNoteID }) {
                            app.selectedNoteID = notes.first?.id
                        }
                        focus = .list
                    }
                    .onExitCommand {
                        app.search = ""
                        focus = .list
                    }
                if !app.search.isEmpty {
                    Button {
                        app.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(8)

            if !app.tagFilter.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                        ForEach(app.tagFilter.compactMap { store.tag($0) }) { tag in
                            Button {
                                app.tagFilter.removeAll { $0 == tag.id }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(tag.name)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(tag.color.opacity(0.24), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Remove from filter")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }

            List(selection: Binding(
                get: { app.selection },
                set: { new in
                    app.selection = new
                    if new.isEmpty {
                        app.selectedNoteID = nil
                    } else if new.count == 1 || app.selectedNoteID.map(new.contains) != true {
                        app.selectedNoteID = notes.first { new.contains($0.id) }?.id ?? new.first
                    }
                }
            )) {
                ForEach(notes) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .draggable(dragText(note))
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                NoteActions(notes: notes.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                // Double-click: open the note in distraction-free mode.
                guard let id = ids.first else { return }
                app.select(id)
                withAnimation { app.distractionFree = true }
                DispatchQueue.main.async { app.editor.focus() }
            }
            .listStyle(.inset)
            .focused($focus, equals: .list)
            .onKeyPress(phases: [.down, .repeat]) { press in
                if press.modifiers == .control {
                    switch press.key.character {
                    case "h", "\u{8}": app.run("core:sidebar-focus"); return .handled
                    case "l", "\u{c}":
                        guard app.selectedNoteID != nil else { return .ignored }
                        app.editor.focus()
                        return .handled
                    default: return .ignored
                    }
                }
                if press.modifiers.contains(.command) {
                    switch press.key {
                    case .delete: app.trashSelected(); return .handled
                    case .leftArrow: app.run("core:navigate-back"); return .handled
                    case .rightArrow: app.run("core:navigate-forward"); return .handled
                    default: return .ignored
                    }
                }
                guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
                switch press.characters {
                case "j": move(1, in: notes); return .handled
                case "k": move(-1, in: notes); return .handled
                case "g": app.select(notes.first?.id); return .handled
                case "G": app.select(notes.last?.id); return .handled
                case "/": focus = .search; return .handled
                case "h": app.run("core:sidebar-focus"); return .handled
                case "\r", "l", "i":
                    guard app.selectedNoteID != nil else { return .ignored }
                    app.editor.focus()
                    return .handled
                default: return .ignored
                }
            }
            .onDeleteCommand { app.trashSelected() }
            .overlay {
                if notes.isEmpty {
                    ContentUnavailableView(
                        L(app.search.isEmpty ? "No Notes" : "No Results"),
                        systemImage: app.search.isEmpty ? "note.text" : "magnifyingglass"
                    )
                }
            }
            if app.selection.count > 1 {
                Divider()
                HStack {
                    Menu("\(app.selection.count) notes selected") {
                        NoteActions(notes: notes.filter { app.selection.contains($0.id) })
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button {
                        app.trashSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash (⌘⌫)")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $sortKey) {
                        ForEach(SortKey.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show Completed and Dropped", isOn: $showFinished)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Sort")

                if app.sidebar == .trash {
                    Button {
                        store.emptyTrash()
                        app.selectedNoteID = nil
                    } label: {
                        Image(systemName: "trash.slash")
                    }
                    .help("Empty Trash")
                } else {
                    Button {
                        app.newNote()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Note (⌘N)")
                }
            }
        }
        .onAppear { ensureSelection(notes) }
        .onChange(of: app.sidebar) {
            // Come back to the note last viewed in this list.
            let notes = self.notes
            if let sidebar = app.sidebar, let last = app.lastViewed[sidebar], notes.contains(where: { $0.id == last }) {
                app.select(last)
            } else {
                ensureSelection(notes)
            }
        }
        .onChange(of: app.tagFilter) { ensureSelection(self.notes) }
        .onChange(of: app.workspace) { ensureSelection(self.notes) }
        .onChange(of: app.searchFocusRequest) { focus = .search }
        .onChange(of: app.listFocusRequest) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            if app.selectedNoteID == nil { app.selectedNoteID = notes.first?.id }
            focus = .list
        }
    }

    private func ensureSelection(_ notes: [Note]) {
        if let id = app.selectedNoteID, notes.contains(where: { $0.id == id }) { return }
        app.select(notes.first?.id)
    }

    /// Dragged notes travel as Markdown links, so they can be dropped into other apps too.
    private func dragText(_ note: Note) -> String {
        let group = app.selection.contains(note.id) && app.selection.count > 1
            ? notes.filter { app.selection.contains($0.id) } : [note]
        return group.map { AppState.markdownLink(title: $0.displayTitle, id: $0.id) }.joined(separator: "\n")
    }

    private func move(_ delta: Int, in notes: [Note]) {
        guard !notes.isEmpty else { return }
        guard let i = notes.firstIndex(where: { $0.id == app.selectedNoteID }) else {
            app.select(notes.first?.id)
            return
        }
        app.select(notes[min(max(i + delta, 0), notes.count - 1)].id)
    }
}

struct NoteRow: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    let note: Note

    private static let taskRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#, options: [.anchorsMatchLines])

    private var tasks: (done: Int, total: Int) {
        let ns = note.body as NSString
        var done = 0, total = 0
        Self.taskRegex.enumerateMatches(in: note.body, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            total += 1
            if ns.substring(with: m.range(at: 1)) != " " { done += 1 }
        }
        return (done, total)
    }

    private var snippet: String {
        let head = note.body.prefix(240)
        return head
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-`| \t")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                if note.status != .none {
                    Image(systemName: note.status.symbol).font(.caption).foregroundStyle(note.status.color)
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(.relative(presentation: .named)))
                let t = tasks
                if t.total > 0 {
                    Label("\(t.done)/\(t.total)", systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                }
                ForEach(note.tagIds.compactMap { store.tag($0) }.prefix(3)) { tag in
                    Text(tag.name)
                        .padding(.horizontal, 5)
                        .background(tag.color.opacity(0.24), in: Capsule())
                        .onTapGesture { app.filter(byTag: tag.id) }
                        .help("Filter by this tag (⌥-click: only this tag)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            let s = snippet
            if !s.isEmpty {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shared actions for the note context menu and the Note menu; works on one note or many.
struct NoteActions: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    let notes: [Note]

    init(note: Note) { notes = [note] }
    init(notes: [Note]) { self.notes = notes }

    private func each(_ change: (inout Note) -> Void) {
        for n in notes { store.update(n.id, touch: false, change) }
    }

    private func deselect() {
        if let cur = app.selectedNoteID, notes.contains(where: { $0.id == cur }) { app.select(nil) }
    }

    var body: some View {
        if notes.isEmpty {
            EmptyView()
        } else if notes.allSatisfy(\.trashed) {
            Button("Restore") {
                for n in notes { store.restore(n.id) }
                deselect()
            }
            Button("Delete Permanently", role: .destructive) {
                for n in notes { store.deletePermanently(n.id) }
                deselect()
            }
        } else {
            let single = notes.count == 1 ? notes[0] : nil
            let allPinned = notes.allSatisfy(\.pinned)
            if notes.count > 1 {
                Text("\(notes.count) notes")
                Divider()
            }
            Button(L(allPinned ? "Unpin" : "Pin to Top")) { each { $0.pinned = !allPinned } }
            Menu("Status") {
                ForEach(NoteStatus.allCases) { status in
                    Button {
                        each { $0.status = status }
                    } label: {
                        Label(status.label, systemImage: single?.status == status ? "checkmark" : status.symbol)
                    }
                }
            }
            Menu("Move to Notebook") {
                Button("No Notebook") { each { $0.bookId = nil } }
                Divider()
                ForEach(store.flatBooks, id: \.book.id) { entry in
                    Button(String(repeating: "    ", count: entry.depth) + entry.book.name) {
                        each { $0.bookId = entry.book.id }
                    }
                }
            }
            Menu("Tags") {
                ForEach(store.tags) { tag in
                    let has = notes.allSatisfy { $0.tagIds.contains(tag.id) }
                    Button {
                        each { n in
                            if has { n.tagIds.removeAll { $0 == tag.id } } else if !n.tagIds.contains(tag.id) { n.tagIds.append(tag.id) }
                        }
                    } label: {
                        Label(tag.name, systemImage: has ? "checkmark" : "tag")
                    }
                }
                if store.tags.isEmpty { Text("No Tags") }
            }
            if let single {
                Button("Duplicate") {
                    if let id = store.duplicate(single.id) { app.select(id) }
                }
            }
            Button(L(notes.count > 1 ? "Copy Links" : "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    notes.map { AppState.markdownLink(title: $0.displayTitle, id: $0.id) }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                for n in notes where !n.trashed { store.trash(n.id) }
                deselect()
            }
        }
    }
}
