import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @AppStorage("showFinished") private var showFinished = false
    @AppStorage("collapsedBooks") private var collapsedBooks = ""

    private var collapsed: Set<String> { Set(collapsedBooks.split(separator: ",").map(String.init)) }

    private func toggleCollapsed(_ id: String) {
        var set = collapsed
        if !set.insert(id).inserted { set.remove(id) }
        collapsedBooks = set.sorted().joined(separator: ",")
    }

    private enum Prompt {
        case newBook(parent: String?)
        case renameBook(String)

        var title: String {
            switch self {
            case .newBook: L("New Notebook")
            case .renameBook: L("Rename Notebook")
            }
        }
    }

    @State private var prompt: Prompt = .newBook(parent: nil)
    @State private var showPrompt = false
    @State private var nameDraft = ""
    @State private var deletingBook: Notebook?
    @FocusState private var focused: Bool

    /// Notebooks shown: everything, or the sub-notebooks of the open workspace.
    private var bookEntries: [(book: Notebook, depth: Int)] {
        // Hide everything below a collapsed notebook.
        let closed = collapsed
        var hideBelow: Int?
        let all = store.flatBooks.filter { entry in
            if let d = hideBelow {
                if entry.depth > d { return false }
                hideBelow = nil
            }
            if closed.contains(entry.book.id) { hideBelow = entry.depth }
            return true
        }
        guard let ws = app.workspace else { return all }
        let inside = store.descendants(of: ws)
        let base = (all.first { $0.book.id == ws }?.depth ?? 0) + 1
        return all.filter { inside.contains($0.book.id) }.map { ($0.book, $0.depth - base) }
    }

    private var tagEntries: [Tag] {
        app.workspace.map { store.tags(in: $0) } ?? store.tags
    }

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebar) {
            if let ws = app.workspace, let book = store.book(ws) {
                Section {
                    row("All Notes", "tray.full", .all)
                } header: {
                    HStack(spacing: 4) {
                        Button {
                            app.exitWorkspace()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .help("Show all notebooks")
                        Spacer()
                        Image(systemName: "book.closed.fill")
                        Text(book.name).lineLimit(1)
                    }
                }
            } else {
                row("All Notes", "tray.full", .all)
            }

            Section {
                ForEach(bookEntries, id: \.book.id) { entry in
                    bookRow(entry.book, depth: entry.depth)
                }
            } header: {
                HStack {
                    Text(L(app.workspace == nil ? "Notebooks" : "Sub-notebooks"))
                        .dropDestination(for: String.self) { items, _ in
                            // Dropping a notebook on the heading moves it to the top level.
                            guard let dragged = items.first(where: { $0.hasPrefix("sumi-book:") }) else { return false }
                            return store.moveBook(String(dragged.dropFirst("sumi-book:".count)), under: app.workspace)
                        }
                    Spacer()
                    headerButton("line.3.horizontal.decrease", "Search Notebooks…") { app.showTelescope(.notebooks) }
                    headerButton("plus", "New Notebook") { ask(.newBook(parent: app.workspace), initial: "") }
                }
            }

            Section("Status") {
                ForEach(NoteStatus.allCases.filter { $0 != .none }) { status in
                    row(status.label, status.symbol, .status(status), tint: status.color)
                }
            }

            if !tagEntries.isEmpty {
                Section {
                    ForEach(tagEntries) { tag in
                        row(tag.name, "tag.fill", .tag(tag.id), tint: tag.color)
                            .dropDestination(for: String.self) { items, _ in
                                for id in AppState.noteIDs(in: items) where store.notes[id] != nil {
                                    store.addTag(named: tag.name, to: id)
                                }
                                return true
                            }
                            .contextMenu {
                                Button("Add to Filter") { app.addTagFilter(tag.id) }
                                Divider()
                                Button("Tag Settings…") { app.tagSettingsID = tag.id }
                                Menu("Color") {
                                    ForEach(Tag.palette, id: \.name) { entry in
                                        Button {
                                            store.updateTag(tag.id) { $0.colorName = entry.name }
                                        } label: {
                                            Label(entry.name.capitalized,
                                                  systemImage: tag.colorName == entry.name ? "checkmark" : "circle.fill")
                                        }
                                    }
                                }
                                Button("Copy Tag ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tag.id, forType: .string)
                                }
                                Divider()
                                Button("Delete Tag", role: .destructive) { app.deleteTag(tag.id) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Tags")
                        Spacer()
                        headerButton("line.3.horizontal.decrease", "Search Tags…") { app.showTelescope(.tags) }
                    }
                }
            }

            if app.workspace == nil {
                Section {
                    row("Trash", "trash", .trash, tint: .secondary)
                        .contextMenu {
                            Button("Empty Trash", role: .destructive) {
                                store.emptyTrash()
                                app.selectedNoteID = nil
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
          VStack(spacing: 0) {
            UpdateBanner()
            if store.usingICloud {
                HStack(spacing: 5) {
                    Image(systemName: "icloud")
                    Text(store.lastSync.map { String(format: L("Synced %@"), $0.formatted(date: .omitted, time: .shortened)) } ?? "iCloud Drive")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
          }
        }
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            if press.modifiers == .control, ["l", "\u{c}"].contains(press.key.character) {
                app.focusList()
                return .handled
            }
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters {
            case "j": move(1); return .handled
            case "k": move(-1); return .handled
            case "l": app.focusList(); return .handled
            case "h":
                guard app.workspace != nil else { return .ignored }
                app.exitWorkspace()
                return .handled
            case "\r":
                // Enter on a notebook opens it as a workspace.
                if case .book(let id) = app.sidebar { app.enterWorkspace(id) } else { app.focusList() }
                return .handled
            default: return .ignored
            }
        }
        .onChange(of: app.sidebarFocusRequest) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { focused = true }
        }
        .alert(prompt.title, isPresented: $showPrompt) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("OK") { commitPrompt() }
        }
        .confirmationDialog(
            "Delete “\(deletingBook?.name ?? "")”?",
            isPresented: Binding(get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } })
        ) {
            Button("Delete Notebook", role: .destructive) {
                if let book = deletingBook {
                    if app.workspace == book.id { app.workspace = nil }
                    app.sidebar = .all
                    store.deleteBook(book.id)
                }
                deletingBook = nil
            }
        } message: {
            Text("Its sub-notebooks are deleted and all notes inside are moved to the Trash.")
        }
        .onChange(of: app.newBookRequest) {
            var parent = app.workspace
            if case .book(let id) = app.sidebar { parent = store.book(id)?.parentId }
            ask(.newBook(parent: parent), initial: "")
        }
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help(L(help))
    }

    private func move(_ delta: Int) {
        var items: [SidebarItem] = [.all]
        items += bookEntries.map { .book($0.book.id) }
        items += NoteStatus.allCases.filter { $0 != .none }.map { .status($0) }
        items += tagEntries.map { .tag($0.id) }
        if app.workspace == nil { items.append(.trash) }
        let i = items.firstIndex(of: app.sidebar ?? .all) ?? 0
        app.sidebar = items[min(max(i + delta, 0), items.count - 1)]
    }

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem, tint: Color? = nil) -> some View {
        Label {
            Text(L(title)).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? Color.accentColor)
        }
        .badge(store.count(item, showFinished: showFinished, workspace: app.workspace))
        .tag(item)
    }

    private func bookRow(_ book: Notebook, depth: Int) -> some View {
        HStack(spacing: 2) {
            if store.books.contains(where: { $0.parentId == book.id }) {
                Button {
                    toggleCollapsed(book.id)
                } label: {
                    Image(systemName: collapsed.contains(book.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Label {
                Text(book.name).lineLimit(1)
            } icon: {
                Image(systemName: "book.closed")
            }
        }
        .padding(.leading, CGFloat(max(depth, 0)) * 14 - 6)
        .badge(store.count(.book(book.id), showFinished: showFinished))
        .tag(SidebarItem.book(book.id))
        .draggable("sumi-book:" + book.id)
        .dropDestination(for: String.self) { items, _ in
            // A notebook dropped here becomes a sub-notebook; notes are moved in.
            if let dragged = items.first(where: { $0.hasPrefix("sumi-book:") }) {
                return store.moveBook(String(dragged.dropFirst("sumi-book:".count)), under: book.id)
            }
            for id in AppState.noteIDs(in: items) where store.notes[id] != nil {
                store.update(id, touch: false) { $0.bookId = book.id; $0.trashed = false }
            }
            return true
        }
        .contextMenu {
            Button("Detail") { app.enterWorkspace(book.id) }
            if book.parentId != nil {
                Button("Move to Top Level") { store.moveBook(book.id, under: nil) }
            }
            Divider()
            Button("New Note") {
                app.sidebar = .book(book.id)
                app.newNote()
            }
            Button("New Sub-notebook…") { ask(.newBook(parent: book.id), initial: "") }
            Divider()
            Button("Rename…") { ask(.renameBook(book.id), initial: book.name) }
            Button("Delete…", role: .destructive) { deletingBook = book }
        }
    }

    private func ask(_ prompt: Prompt, initial: String) {
        self.prompt = prompt
        nameDraft = initial
        showPrompt = true
    }

    private func commitPrompt() {
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch prompt {
        case .newBook(let parent):
            let id = store.addBook(name: name, parentId: parent)
            app.sidebar = .book(id)
        case .renameBook(let id):
            store.renameBook(id, to: name)
        }
    }
}

/// Rename, recolor or delete a tag.
struct TagSettingsView: View {
    let tagID: String
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorName = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tag Settings").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 7), spacing: 10) {
                ForEach(Tag.palette, id: \.name) { entry in
                    Circle()
                        .fill(entry.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary, lineWidth: colorName == entry.name ? 2 : 0).padding(-3))
                        .onTapGesture { colorName = entry.name }
                        .help(entry.name.capitalized)
                }
            }
            Text("\(store.tagCounts[tagID] ?? 0) notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Delete Tag", role: .destructive) {
                    app.deleteTag(tagID)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 330)
        .onAppear {
            if let tag = store.tag(tagID) {
                name = tag.name
                colorName = Tag.palette.contains { $0.name == tag.colorName } ? tag.colorName : "default"
            }
        }
    }

    private func save() {
        // Renaming to an existing tag's name merges the two.
        let kept = store.renameTag(tagID, to: name)
        store.updateTag(kept) { $0.colorName = colorName }
        if kept != tagID {
            if app.sidebar == .tag(tagID) { app.sidebar = .tag(kept) }
            app.tagFilter.removeAll { $0 == tagID }
        }
        dismiss()
    }
}
