import SwiftUI

/// Quick finder: notes by default; `> ` commands, `b ` notebooks, `t ` tags.
struct TelescopeView: View {
    let mode: TelescopeMode

    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        var detail: String = ""
        var tint: Color?
        /// ⌘Return / ⇧Return variants.
        var alt: (() -> Void)?
        var shift: (() -> Void)?
        let action: () -> Void
    }

    private var placeholder: String {
        switch mode {
        case .all: L("Search notes…   ( > commands   b notebooks   t tags   # headings )")
        case .commands: L("Run a command…")
        case .notebooks: L("Go to notebook…   ( ⌘↩ open as workspace )")
        case .tags: L("Go to tag…   ( ⌘↩ add to filter   ⇧↩ tag this note )")
        case .noteActions: L("Note actions…")
        case .templates: L("Choose a template…")
        case .moveToBook: L("Move to notebook…")
        case .toc: L("Jump to heading…")
        case .ai: L("AI actions…   ( works on the selection, or the whole note )")
        }
    }

    private var headings: [(line: Int, level: Int, text: String)] {
        guard let body = app.selectedNote?.body else { return [] }
        var out: [(Int, Int, String)] = []
        var fence = false
        for (i, raw) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); continue }
            guard !fence, line.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(level)
            guard level <= 6, rest.hasPrefix(" ") else { continue }
            out.append((i + 1, level, rest.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    private func matches(_ text: String, _ q: String) -> Bool {
        q.split(separator: " ").allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    private var items: [Item] {
        var mode = mode
        var q = query
        if mode == .all {
            if q.hasPrefix(">") { mode = .commands; q.removeFirst() }
            else if q.hasPrefix("b ") { mode = .notebooks; q.removeFirst(2) }
            else if q.hasPrefix("t ") { mode = .tags; q.removeFirst(2) }
            else if q.hasPrefix("#") { mode = .toc; q.removeFirst() }
        }
        q = q.trimmingCharacters(in: .whitespaces)
        var out: [Item]
        switch mode {
        case .all:
            out = store.notes.values
                .filter { !$0.trashed }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { n in
                    Item(id: n.id, icon: "doc.text", title: n.displayTitle, detail: store.book(n.bookId)?.name ?? "") {
                        app.open(noteID: n.id)
                    }
                }
        case .commands:
            out = (AppState.commands + AIAction.allCases.map { AppCommand(id: $0.commandID, title: "AI: " + $0.title) }
                   + Customization.shared.pluginCommands).map { c in
                Item(id: c.id, icon: "command", title: c.title, detail: c.keys) { app.run(c.id) }
            }
        case .notebooks:
            out = store.flatBooks.map { e in
                Item(id: e.book.id, icon: "book.closed", title: String(repeating: "   ", count: e.depth) + e.book.name,
                     alt: {
                         app.search = ""
                         app.enterWorkspace(e.book.id)
                         app.focusList()
                     }) {
                    app.search = ""
                    app.workspace = nil
                    app.sidebar = .book(e.book.id)
                    app.focusList()
                }
            }
        case .tags:
            let counts = store.tagCounts
            out = store.tags.map { t in
                Item(id: t.id, icon: "tag.fill", title: t.name, detail: "\(counts[t.id] ?? 0)", tint: t.color,
                     alt: {
                         app.addTagFilter(t.id)
                         app.focusList()
                     },
                     shift: {
                         if let id = app.selectedNoteID { store.addTag(named: t.name, to: id) }
                     }) {
                    app.search = ""
                    app.workspace = nil
                    app.sidebar = .tag(t.id)
                    app.focusList()
                }
            }
        case .ai:
            out = AIAction.allCases.map { a in
                Item(id: a.commandID, icon: a.symbol, title: a.title) { app.startAI(a) }
            }
        case .templates:
            out = store.templates.map { n in
                Item(id: n.id, icon: "doc.on.doc", title: n.displayTitle) { app.applyTemplate(n.id) }
            }
        case .toc:
            out = headings.map { h in
                Item(id: "h\(h.line)", icon: "number", title: String(repeating: "   ", count: h.level - 1) + h.text,
                     detail: "Ln \(h.line)") {
                    app.editor.call("gotoLine", ["line": h.line, "text": h.text])
                    DispatchQueue.main.async { app.editor.focus() }
                }
            }
        case .moveToBook:
            out = [Item(id: "-", icon: "tray", title: L("No Notebook")) { move(to: nil) }]
            out += store.flatBooks.map { e in
                Item(id: e.book.id, icon: "book.closed", title: e.book.name) { move(to: e.book.id) }
            }
        case .noteActions:
            let trashed = app.selectedNote?.trashed == true
            out = [
                Item(id: "move", icon: "book.closed", title: L("Move to Notebook…")) { app.telescope = .moveToBook },
                Item(id: "dup", icon: "plus.square.on.square", title: L("Duplicate"), detail: "⌘D") { app.run("core:duplicate-note") },
                Item(id: "pin", icon: "pin", title: L(app.selectedNote?.pinned == true ? "Unpin" : "Pin to Top")) {
                    app.run("core:pin-note-to-top")
                },
            ]
            out += NoteStatus.allCases.enumerated().map { i, s in
                Item(id: "status-\(s.rawValue)", icon: s.symbol, title: String(format: L("Status: %@"), s.label), detail: "⌘⌃\(i + 1)") {
                    app.run("editor:change-note-status-\(s.rawValue.lowercased())")
                }
            }
            out += [
                Item(id: "ai", icon: "apple.intelligence", title: L("AI Actions…"), detail: "⌘⇧A") { app.telescope = .ai },
                Item(id: "link", icon: "link", title: L("Copy Note Link")) { app.run("editor:copy-link") },
                Item(id: "toc", icon: "list.bullet.indent", title: L("Table of Contents…")) { app.telescope = .toc },
                Item(id: "rev", icon: "clock.arrow.circlepath", title: L("Revision History…")) { app.run("core:show-revisions") },
                Item(id: "html", icon: "doc.richtext", title: L("Export as HTML…")) { app.run("export-as-html:export") },
                Item(id: "print", icon: "printer", title: L("Print / Save as PDF…")) { app.run("export-print:print") },
                Item(id: "export", icon: "square.and.arrow.up", title: L("Export as Markdown…"), detail: "⌘⇧E") {
                    app.exportSelected()
                },
                Item(id: "trash", icon: "trash", title: L(trashed ? "Delete Permanently" : "Move to Trash")) {
                    app.run("core:delete-note")
                },
            ]
            if trashed {
                out.insert(Item(id: "restore", icon: "arrow.uturn.backward", title: L("Restore")) {
                    if let id = app.selectedNoteID { store.restore(id) }
                }, at: 0)
            }
        }
        if !q.isEmpty { out = out.filter { matches($0.title, q) } }
        return Array(out.prefix(60))
    }

    private func open(_ note: Note) {
        if !app.currentList().contains(where: { $0.id == note.id }) {
            app.search = ""
            app.sidebar = .all
        }
        app.selectedNoteID = note.id
    }

    private func move(to bookId: String?) {
        if let id = app.selectedNoteID { store.update(id, touch: false) { $0.bookId = bookId } }
    }

    var body: some View {
        let items = self.items
        let selected = min(index, max(items.count - 1, 0))

        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { app.closeTelescope() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .onSubmit { run(items, selected) }
                        .onKeyPress(phases: [.down, .repeat]) { press in
                            let ctrl = press.modifiers.contains(.control)
                            switch press.key {
                            case .downArrow: index = min(selected + 1, max(items.count - 1, 0)); return .handled
                            case .upArrow: index = max(selected - 1, 0); return .handled
                            case .escape: app.closeTelescope(); return .handled
                            case .return where press.modifiers.contains(.command):
                                run(items, selected, \.alt); return .handled
                            case .return where press.modifiers.contains(.shift):
                                run(items, selected, \.shift); return .handled
                            case "n" where ctrl, "j" where ctrl:
                                index = min(selected + 1, max(items.count - 1, 0)); return .handled
                            case "p" where ctrl, "k" where ctrl:
                                index = max(selected - 1, 0); return .handled
                            default: return .ignored
                            }
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if !items.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    HStack(spacing: 8) {
                                        Image(systemName: item.icon).frame(width: 18)
                                            .foregroundStyle(i == selected ? Color.white : (item.tint ?? Color.primary))
                                        Text(item.title).lineLimit(1)
                                        Spacer()
                                        Text(item.detail).font(.callout).opacity(0.65)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(i == selected ? Color.white : Color.primary)
                                    .background(i == selected ? Color.accentColor : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(items, i) }
                                    .id(item.id)
                                }
                            }
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selected) { _, new in
                            if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .onExitCommand { app.closeTelescope() }
    }

    private func run(_ items: [Item], _ i: Int, _ variant: KeyPath<Item, (() -> Void)?>? = nil) {
        guard items.indices.contains(i) else { return }
        let before = app.telescope
        let item = items[i]
        app.closeTelescope()
        (variant.flatMap { item[keyPath: $0] } ?? item.action)()
        // An action may open another telescope page (e.g. "Move to Notebook…").
        if app.telescope == before { app.telescope = nil }
    }
}
