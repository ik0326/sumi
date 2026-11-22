import SwiftUI

struct RevisionsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [LibraryStore.Revision] = []
    @State private var selected: LibraryStore.Revision.ID?

    private var current: LibraryStore.Revision? { revisions.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(revisions, selection: $selected) { rev in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rev.date.formatted(date: .abbreviated, time: .shortened))
                        Text("\(rev.body.count) chars").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(rev.id)
                }
                .frame(width: 210)
                Divider()
                Group {
                    if let rev = current {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(rev.title.isEmpty ? L("Untitled") : rev.title).font(.title3.bold())
                                Text(rev.body)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                        }
                    } else {
                        ContentUnavailableView(
                            L(revisions.isEmpty ? "No Revisions Yet" : "Select a Revision"),
                            systemImage: "clock.arrow.circlepath",
                            description: Text(revisions.isEmpty ? L("A copy is kept each time you start editing a note.") : ""))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(app.selectedNote?.displayTitle ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore This Version") {
                    if let rev = current, let id = app.selectedNoteID {
                        store.restore(rev, to: id)
                        app.editorReloadToken += 1
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil)
            }
            .padding(12)
        }
        .frame(width: 760, height: 520)
        .onAppear {
            revisions = app.selectedNoteID.map { store.revisions(for: $0) } ?? []
            selected = revisions.first?.id
        }
    }
}
