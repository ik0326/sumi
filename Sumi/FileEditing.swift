import SwiftUI
import UniformTypeIdentifiers

/// Routes Markdown files opened from Finder, the Dock or File › Open to a window.
@MainActor
final class FileOpener {
    static let shared = FileOpener()
    private var pending: [URL] = []
    /// Set once the first window exists; opens one file window.
    var handler: ((URL) -> Void)? {
        didSet {
            guard let handler else { return }
            let urls = pending
            pending = []
            urls.forEach(handler)
        }
    }

    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if let handler { handler(url) } else { pending.append(url) }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "txt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { open(panel.urls) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { FileOpener.shared.open(urls) }
    }
}

/// A window that edits one Markdown file in place. The file is not added to the library.
struct FileNoteView: View {
    let url: URL
    @State private var store: LibraryStore?
    @State private var app: AppState?
    @State private var failed = false

    var body: some View {
        Group {
            if let store, let app {
                EditorPane()
                    .modifier(ThemedPane(part: .editor))
                    .modifier(NoteWindowChrome(app: app))
                    .environment(store)
                    .environment(app)
            } else if failed {
                ContentUnavailableView("This file could not be opened", systemImage: "doc.questionmark",
                                       description: Text("Sumi opens text files saved as UTF-8."))
            } else {
                Color.clear
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationDocument(url)
        .onAppear {
            guard store == nil, !failed else { return }
            guard let opened = LibraryStore(file: url) else {
                failed = true
                return
            }
            let state = AppState(store: opened)
            state.selectedNoteID = LibraryStore.fileNoteID
            store = opened
            app = state
        }
        .onDisappear { store?.flush() }
    }
}
