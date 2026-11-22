import SwiftUI

struct TagChip: View {
    let tag: Tag
    var selected = false

    var body: some View {
        Text(tag.name)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tag.color.opacity(0.24), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor : tag.color.opacity(0.55), lineWidth: selected ? 1.5 : 0.5))
    }
}

/// The note's tags plus the "Add Tags" field with suggestions.
struct TagBar: View {
    let note: Note

    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var index = 0
    /// Tag picked with Backspace; a second Backspace removes it.
    @State private var marked: String?
    @FocusState private var focused: Bool

    private struct Suggestion: Identifiable {
        let id: String
        var tag: Tag?
        let title: String
        var count = 0
    }

    private var query: String { draft.trimmingCharacters(in: .whitespaces) }

    private var suggestions: [Suggestion] {
        let q = query.lowercased()
        let counts = store.tagCounts
        var scored: [(score: Int, tag: Tag)] = []
        for tag in store.tags where !note.tagIds.contains(tag.id) {
            let name = tag.name.lowercased()
            if q.isEmpty || name == q { scored.append((0, tag)) }
            else if name.hasPrefix(q) { scored.append((1, tag)) }
            else if name.contains(q) { scored.append((2, tag)) }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let a = counts[$0.tag.id] ?? 0, b = counts[$1.tag.id] ?? 0
            return a != b ? a > b : $0.tag.name.localizedStandardCompare($1.tag.name) == .orderedAscending
        }
        var out = scored.prefix(8).map { Suggestion(id: $0.tag.id, tag: $0.tag, title: $0.tag.name, count: counts[$0.tag.id] ?? 0) }
        if !q.isEmpty, !store.tags.contains(where: { $0.name.lowercased() == q }) {
            out.append(Suggestion(id: "+new", title: String(format: L("Create “%@”"), query)))
        }
        return out
    }

    var body: some View {
        let tags = note.tagIds.compactMap { store.tag($0) }
        let list = focused ? suggestions : []
        let selected = min(index, max(list.count - 1, 0))

        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            if !tags.isEmpty {
                // A plain row: measuring alternatives here (ViewThatFits) made every note switch slow.
                chips(tags)
            }
            TextField("Add Tags", text: $draft)
                .textFieldStyle(.plain)
                .frame(width: 130)
                .focused($focused)
                .onSubmit { commit(list, selected) }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    let ctrl = press.modifiers.contains(.control)
                    switch press.key {
                    case .downArrow, "n" where ctrl:
                        index = min(selected + 1, max(list.count - 1, 0)); return .handled
                    case .upArrow, "p" where ctrl:
                        index = max(selected - 1, 0); return .handled
                    case .tab:
                        guard !query.isEmpty else { return .ignored }
                        commit(list, selected)
                        return .handled
                    case .escape:
                        draft = ""
                        marked = nil
                        app.editor.focus()
                        return .handled
                    case .delete:
                        guard draft.isEmpty else { return .ignored }
                        if let m = marked {
                            store.update(note.id, touch: false) { $0.tagIds.removeAll { $0 == m } }
                            marked = nil
                        } else {
                            marked = note.tagIds.last
                        }
                        return .handled
                    case ",":
                        if !query.isEmpty { commit([], 0) }
                        return .handled
                    default:
                        marked = nil
                        return .ignored
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !list.isEmpty { popup(list, selected).offset(x: -8, y: 24) }
                }
        }
        .onChange(of: draft) { index = 0 }
        .onChange(of: note.id) {
            draft = ""
            marked = nil
        }
        .onChange(of: focused) { if !focused { marked = nil } }
        .onChange(of: app.tagFocusRequest) { focused = true }
    }

    private func chips(_ tags: [Tag]) -> some View {
        HStack(spacing: 6) {
            ForEach(tags) { tag in
                HStack(spacing: 3) {
                    Text(tag.name).lineLimit(1)
                    Button {
                        store.update(note.id, touch: false) { $0.tagIds.removeAll { $0 == tag.id } }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Remove tag")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tag.color.opacity(0.24), in: Capsule())
                .overlay(Capsule().stroke(marked == tag.id ? Color.accentColor : tag.color.opacity(0.55),
                                          lineWidth: marked == tag.id ? 1.5 : 0.5))
                .contentShape(Capsule())
                .onTapGesture { app.filter(byTag: tag.id) }
                .contextMenu {
                    Button("Show Notes with This Tag") { app.sidebar = .tag(tag.id) }
                    Button("Add to Filter") { app.addTagFilter(tag.id) }
                    Button("Tag Settings…") { app.tagSettingsID = tag.id }
                    Divider()
                    Button("Remove from Note") {
                        store.update(note.id, touch: false) { $0.tagIds.removeAll { $0 == tag.id } }
                    }
                }
            }
        }
    }

    private func popup(_ list: [Suggestion], _ selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 7) {
                    if let tag = s.tag {
                        Circle().fill(tag.color).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    }
                    Text(s.title).lineLimit(1)
                    Spacer(minLength: 8)
                    if s.tag != nil { Text("\(s.count)").opacity(0.6) }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(i == selected ? Color.white : Color.primary)
                .background(i == selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { commit(list, i, picked: true) }
            }
        }
        .padding(4)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func commit(_ list: [Suggestion], _ i: Int, picked: Bool = false) {
        let q = query
        // Plain Enter on an empty field goes back to the editor.
        if q.isEmpty, !picked, i == 0 {
            app.editor.focus()
            return
        }
        if list.indices.contains(i) {
            store.addTag(named: list[i].tag?.name ?? q, to: note.id)
        } else if !q.isEmpty {
            store.addTag(named: q, to: note.id)
        } else {
            return
        }
        draft = ""
        index = 0
    }
}
