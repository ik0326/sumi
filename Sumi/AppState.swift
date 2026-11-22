import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class EditorController {
    weak var webView: WKWebView?

    var hasFocus: Bool {
        guard let webView else { return false }
        return webView.window?.firstResponder === webView
    }

    func call(_ function: String, _ arg: Any? = nil) {
        guard let webView else { return }
        var js = "window.sumi.\(function)()"
        if let arg,
           let data = try? JSONSerialization.data(withJSONObject: [arg]),
           let json = String(data: data, encoding: .utf8) {
            js = "window.sumi.\(function).apply(null, \(json))"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Evaluates JavaScript and returns its (JSON-like) result.
    func eval(_ js: String) async -> Any? {
        guard let webView else { return nil }
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { value, _ in cont.resume(returning: value) }
        }
    }

    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        call("focus")
    }
}

enum TelescopeMode: Hashable {
    case all, commands, notebooks, tags, noteActions, templates, moveToBook, toc, ai
}

struct AppCommand: Identifiable {
    let id: String
    /// The English name; `title` is what is shown.
    let name: String
    var keys: String = ""
    var title: String { L(name) }

    init(id: String, title: String, keys: String = "") {
        self.id = id
        self.name = title
        self.keys = keys
    }
}

@MainActor @Observable
final class AppState {
    @ObservationIgnored let store: LibraryStore
    /// The state of the window that has keyboard focus (main window or a Quick Note window).
    static weak var focused: AppState?

    var sidebar: SidebarItem? = .all {
        didSet { if sidebar != oldValue { tagFilter = [] } }
    }
    /// Extra tags the note list is narrowed by (all must match).
    var tagFilter: [String] = []
    /// Notebook opened as a workspace: the sidebar and lists only show what is inside it.
    var workspace: String?
    var tagSettingsID: String?
    var tagFocusRequest = 0
    var selectedNoteID: String? {
        didSet {
            if let id = selectedNoteID {
                if !selection.contains(id) { selection = [id] }
                if let sidebar { lastViewed[sidebar] = id }
            } else if !selection.isEmpty {
                selection = []
            }
        }
    }
    /// All notes selected in the list; `selectedNoteID` is the one shown in the editor.
    var selection: Set<String> = []
    var ai: AIRequest?
    /// The note last viewed in each sidebar item (until the app quits).
    @ObservationIgnored var lastViewed: [SidebarItem: String] = [:]
    var search = ""
    var viewMode: ViewMode = .edit
    var sidebarVisible = true
    var distractionFree = false
    var telescope: TelescopeMode?
    var editorReloadToken = 0
    var showRevisions = false

    var titleFocusRequest = 0
    var searchFocusRequest = 0
    var listFocusRequest = 0
    var sidebarFocusRequest = 0
    var newBookRequest = 0

    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored var openQuickNoteWindow: ((String) -> Void)?
    /// True for the state of a Quick Note window.
    @ObservationIgnored var isQuickNote = false
    @ObservationIgnored private var back: [String] = []
    @ObservationIgnored private var forward: [String] = []
    @ObservationIgnored private var navigating = false
    @ObservationIgnored private var telescopeFromEditor = false

    init(store: LibraryStore) { self.store = store }

    var selectedNote: Note? { selectedNoteID.flatMap { store.notes[$0] } }

    // MARK: Commands

    static let commands: [AppCommand] = [
        .init(id: "core:new-note", title: "New Note", keys: "⌘N"),
        .init(id: "application:quick-note", title: "Quick Note"),
        .init(id: "application:new-quick-note", title: "New Quick Note"),
        .init(id: "core:new-notebook", title: "New Notebook", keys: "⌘⇧N"),
        .init(id: "core:choose-template", title: "Choose a Template", keys: "⌘T"),
        .init(id: "view:toggle-preview", title: "Toggle Preview", keys: "⌘E"),
        .init(id: "view:toggle-side-by-side", title: "Toggle Side by Side", keys: "⌘P"),
        .init(id: "view:toggle-distraction-free", title: "Toggle Distraction Free", keys: "⌘⇧D"),
        .init(id: "view:toggle-sidebar", title: "Toggle Sidebar", keys: "⌘/"),
        .init(id: "core:find", title: "Search Notes", keys: "⌘⇧F"),
        .init(id: "core:find-global", title: "Search All Notes", keys: "⌘⌥⇧F"),
        .init(id: "core:navigate-back", title: "Go Back", keys: "⌘←"),
        .init(id: "core:navigate-forward", title: "Go Forward", keys: "⌘→"),
        .init(id: "core:open-next-note", title: "Open Next Note"),
        .init(id: "core:open-prev-note", title: "Open Previous Note"),
        .init(id: "core:sidebar-focus", title: "Focus Sidebar"),
        .init(id: "core:focus-note-list-bar", title: "Focus Note List", keys: "⌘1"),
        .init(id: "editor:focus-mde", title: "Focus Editor", keys: "⌘2"),
        .init(id: "editor:focus-title", title: "Focus Title"),
        .init(id: "core:show-editor-action-menu", title: "Note Actions…", keys: "⌘J"),
        .init(id: "core:telescope-toc", title: "Table of Contents"),
        .init(id: "ai:menu", title: "AI Actions…", keys: "⌘⇧A"),
        .init(id: "editor:focus-tags", title: "Add Tags", keys: "⌘⇧T"),
        .init(id: "core:telescope-tags", title: "Search Tags…"),
        .init(id: "core:telescope-notebooks", title: "Search Notebooks…"),
        .init(id: "core:clear-tag-filter", title: "Clear Tag Filter"),
        .init(id: "editor:copy-link", title: "Copy Note Link"),
        .init(id: "core:show-revisions", title: "Revision History…"),
        .init(id: "export-as-html:export", title: "Export as HTML…"),
        .init(id: "export-print:print", title: "Print / Save as PDF…"),
        .init(id: "core:toggle-inline-mark-tag", title: "Highlight"),
        .init(id: "core:duplicate-note", title: "Duplicate Note", keys: "⌘D"),
        .init(id: "core:pin-note-to-top", title: "Pin / Unpin Note"),
        .init(id: "core:delete-note", title: "Move Note to Trash", keys: "⌘⌫"),
        .init(id: "editor:change-note-status-none", title: "Status: None", keys: "⌘⌃1"),
        .init(id: "editor:change-note-status-active", title: "Status: Active", keys: "⌘⌃2"),
        .init(id: "editor:change-note-status-onhold", title: "Status: On Hold", keys: "⌘⌃3"),
        .init(id: "editor:change-note-status-completed", title: "Status: Completed", keys: "⌘⌃4"),
        .init(id: "editor:change-note-status-dropped", title: "Status: Dropped", keys: "⌘⌃5"),
        .init(id: "core:strong", title: "Bold", keys: "⌘B"),
        .init(id: "core:emphasize", title: "Italic", keys: "⌘I"),
        .init(id: "core:strikethrough", title: "Strikethrough"),
        .init(id: "core:toggle-inline-code", title: "Inline Code"),
        .init(id: "core:insert-link", title: "Insert Link", keys: "⌘⌥K"),
        .init(id: "core:toggle-blockquote", title: "Toggle Blockquote", keys: "⌘'"),
        .init(id: "core:toggle-bulleted-list", title: "Toggle Bulleted List", keys: "⇧⌘L"),
        .init(id: "core:toggle-numbered-list", title: "Toggle Numbered List"),
        .init(id: "core:toggle-task-list", title: "Toggle Task List"),
        .init(id: "core:toggle-heading-1", title: "Heading 1"),
        .init(id: "core:toggle-heading-2", title: "Heading 2"),
        .init(id: "core:toggle-heading-3", title: "Heading 3"),
        .init(id: "core:insert-code-block", title: "Insert Code Block"),
        .init(id: "core:insert-horizontal-rule", title: "Insert Horizontal Rule"),
        .init(id: "core:insert-table", title: "Insert Table"),
        .init(id: "core:insert-alert-note", title: "Insert Alert: Note"),
        .init(id: "core:insert-alert-tip", title: "Insert Alert: Tip"),
        .init(id: "core:insert-alert-important", title: "Insert Alert: Important"),
        .init(id: "core:insert-alert-warning", title: "Insert Alert: Warning"),
        .init(id: "core:insert-alert-caution", title: "Insert Alert: Caution"),
        .init(id: "table-editor:format", title: "Table: Format"),
        .init(id: "table-editor:format-all", title: "Table: Format All Tables"),
        .init(id: "table-editor:insert-row", title: "Table: Insert Row"),
        .init(id: "table-editor:insert-column", title: "Table: Insert Column"),
        .init(id: "table-editor:delete-row", title: "Table: Delete Row"),
        .init(id: "table-editor:delete-column", title: "Table: Delete Column"),
        .init(id: "table-editor:move-row-up", title: "Table: Move Row Up"),
        .init(id: "table-editor:move-row-down", title: "Table: Move Row Down"),
        .init(id: "table-editor:move-column-left", title: "Table: Move Column Left"),
        .init(id: "table-editor:move-column-right", title: "Table: Move Column Right"),
        .init(id: "table-editor:align-left", title: "Table: Align Column Left"),
        .init(id: "table-editor:align-center", title: "Table: Align Column Center"),
        .init(id: "table-editor:align-right", title: "Table: Align Column Right"),
        .init(id: "table-editor:align-none", title: "Table: Clear Column Alignment"),
        .init(id: "core:save-note", title: "Save", keys: "⌘S"),
    ]

    /// Commands that act on the library; they do nothing in a window that edits a file in place.
    private static let libraryOnly: Set<String> = [
        "core:new-note", "application:quick-note", "application:new-quick-note", "core:new-notebook", "core:choose-template", "core:delete-note",
        "core:duplicate-note", "core:pin-note-to-top", "editor:focus-tags", "editor:focus-title", "core:telescope-tags",
        "core:telescope-notebooks", "core:show-editor-action-menu", "core:show-revisions", "core:navigate-back",
        "core:navigate-forward", "core:open-next-note", "core:open-prev-note", "core:sidebar-focus",
        "core:focus-note-list-bar", "core:find", "core:find-global", "editor:copy-link", "core:clear-tag-filter",
        "view:toggle-sidebar", "view:toggle-distraction-free",
    ]

    func run(_ id: String) {
        if store.fileURL != nil, Self.libraryOnly.contains(id) || id.hasPrefix("editor:change-note-status-") {
            NSSound.beep()
            return
        }
        if id.hasPrefix("ai:"), let action = AIAction(rawValue: String(id.dropFirst(3))) {
            startAI(action)
            return
        }
        switch id {
        case "ai:menu": if selectedNote != nil { showTelescope(.ai) }
        case "core:new-note": if isQuickNote { quickNote(new: true) } else { newNote() }
        case "application:quick-note": quickNote()
        case "application:new-quick-note": quickNote(new: true)
        case "core:new-notebook": newBookRequest += 1
        case "core:choose-template": chooseTemplate()
        case "view:toggle-preview": viewMode = viewMode == .preview ? .edit : .preview
        case "view:toggle-side-by-side": viewMode = viewMode == .split ? .edit : .split
        case "view:show-editor": setMode(.edit)
        case "view:show-preview": setMode(.preview)
        case "view:show-side-by-side": setMode(.split)
        case "view:toggle-distraction-free": withAnimation { distractionFree.toggle() }
        case "view:toggle-sidebar":
            withAnimation {
                if distractionFree { distractionFree = false; sidebarVisible = true } else { sidebarVisible.toggle() }
            }
        case "core:find": focusSearch()
        case "core:find-global":
            sidebar = .all
            focusSearch()
        case "core:find-clear": search = ""
        case "core:toggle-telescope": toggleTelescope(.all)
        case "core:show-telescope": showTelescope(.all)
        case "core:telescope-commands": showTelescope(.commands)
        case "core:telescope-notebooks": showTelescope(.notebooks)
        case "core:telescope-tags": showTelescope(.tags)
        case "core:show-editor-action-menu": if selectedNote != nil { showTelescope(.noteActions) }
        case "core:telescope-toc": if selectedNote != nil { showTelescope(.toc) }
        case "editor:focus-tags": if selectedNote != nil { tagFocusRequest += 1 }
        case "core:clear-tag-filter": tagFilter = []
        case "editor:copy-link": copyLink()
        case "core:show-revisions":
            if selectedNote != nil {
                editor.call("flush")
                showRevisions = true
            }
        case "export-as-html:export": exportHTML()
        case "export-print:print": printNote()
        case "core:navigate-back": navigate(back: true)
        case "core:navigate-forward": navigate(back: false)
        case "core:open-next-note": step(1)
        case "core:open-prev-note": step(-1)
        case "core:open-first-note": selectedNoteID = currentList().first?.id
        case "core:sidebar-focus":
            exitDistractionFree()
            sidebarVisible = true
            sidebarFocusRequest += 1
        case "core:focus-note-list-bar": focusList()
        case "editor:focus-mde", "editor:focus": editor.focus()
        case "editor:focus-title": titleFocusRequest += 1
        case "core:duplicate-note":
            if let id = selectedNoteID, let copy = store.duplicate(id) { selectedNoteID = copy }
        case "core:pin-note-to-top":
            if let id = selectedNoteID { store.update(id, touch: false) { $0.pinned.toggle() } }
        case "core:delete-note": trashSelected()
        case "editor:change-note-status-none": setStatus(.none)
        case "editor:change-note-status-active": setStatus(.active)
        case "editor:change-note-status-onhold": setStatus(.onHold)
        case "editor:change-note-status-completed": setStatus(.completed)
        case "editor:change-note-status-dropped": setStatus(.dropped)
        case "core:save-note":
            editor.call("flush")
            store.flush()
        default:
            // Formatting / table commands live in the editor.
            guard selectedNote != nil else { return }
            if viewMode == .preview { viewMode = .edit }
            editor.call("command", ["id": id])
            editor.focus()
        }
    }

    private func setMode(_ mode: ViewMode) {
        viewMode = mode
        DispatchQueue.main.async { self.editor.focus() }
    }

    private func setStatus(_ status: NoteStatus) {
        if let id = selectedNoteID { store.update(id, touch: false) { $0.status = status } }
    }

    private func exitDistractionFree() {
        if distractionFree { distractionFree = false }
    }

    // MARK: Notes

    func newNote() {
        var bookId: String?
        var status = NoteStatus.none
        var tagIds: [String] = []
        switch sidebar ?? .all {
        case .book(let id): bookId = id
        case .status(let s): status = s
        case .tag(let t): tagIds = [t]
        case .trash: sidebar = .all
        case .all: break
        }
        if bookId == nil { bookId = workspace }
        for t in tagFilter where !tagIds.contains(t) { tagIds.append(t) }
        search = ""
        if viewMode == .preview { viewMode = .edit }
        selectedNoteID = store.createNote(bookId: bookId, status: status, tagIds: tagIds)
        titleFocusRequest += 1
    }

    /// Shows the quick note in its own window: the one used last time, or a new one when there is none.
    func quickNote(new: Bool = false) {
        let key = "quickNoteID"
        var id = UserDefaults.standard.string(forKey: key)
        if new || id.flatMap({ store.notes[$0] }).map({ $0.trashed }) ?? true {
            let inbox = store.books.first { $0.parentId == nil && $0.name == "Inbox" }?.id
            id = store.createNote(bookId: inbox)
            UserDefaults.standard.set(id, forKey: key)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let id { openQuickNoteWindow?(id) }
    }

    func select(_ id: String?) {
        selection = id.map { [$0] } ?? []
        selectedNoteID = id
    }

    /// Moves every selected note to the Trash (or deletes it for good when already there).
    func trashSelected() {
        var ids = selection
        if let id = selectedNoteID { ids.insert(id) }
        guard !ids.isEmpty else { return }
        let list = currentList()
        let index = list.firstIndex { ids.contains($0.id) }
        for id in ids {
            guard let note = store.notes[id] else { continue }
            if note.trashed { store.deletePermanently(id) } else { store.trash(id) }
        }
        let rest = list.filter { !ids.contains($0.id) }
        select(index.flatMap { i in rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id })
    }

    /// Note ids found in dragged text: Markdown links to notes, or bare ids.
    static func noteIDs(in items: [String]) -> [String] {
        let re = try! NSRegularExpression(pattern: #"sumi://note/([0-9A-Za-z-]+)"#)
        var out: [String] = []
        for item in items {
            let ns = item as NSString
            let found = re.matches(in: item, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            out += found.isEmpty ? item.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } : found
        }
        return out
    }

    // MARK: AI

    func startAI(_ action: AIAction) {
        guard let note = selectedNote else { return }
        Task {
            let ctx = await editor.eval("window.sumi.getContext()") as? [String: Any]
            let selected = (ctx?["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Titles, tags and questions are about the whole note.
            let useSelection = !selected.isEmpty && ![.title, .tags, .ask].contains(action)
            var text = useSelection ? selected : (ctx?["text"] as? String ?? note.body)
            if action == .title || action == .tags, !note.title.isEmpty { text = "# \(note.title)\n\n" + text }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }
            let truncated = text.count > AIRunner.maxCharacters
            if truncated {
                // "Continue writing" needs the end of the text, everything else the beginning.
                text = action == .continueWriting ? String(text.suffix(AIRunner.maxCharacters)) : String(text.prefix(AIRunner.maxCharacters))
            }
            ai = AIRequest(action: action, text: text, fromSelection: useSelection, truncated: truncated,
                           noteID: note.id, readOnly: note.trashed)
        }
    }

    func currentList() -> [Note] {
        let d = UserDefaults.standard
        let sort = SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .updated
        return store.filtered(sidebar, search: search, sort: sort, showFinished: d.bool(forKey: "showFinished"),
                              tags: tagFilter, workspace: workspace)
    }

    // MARK: Tags and workspace

    func addTagFilter(_ id: String) {
        if case .tag(let t) = sidebar, t == id { return }
        if !tagFilter.contains(id) { tagFilter.append(id) }
    }

    /// Clicking a tag narrows the current list by it; with Option held it becomes the only tag filter.
    func filter(byTag id: String) {
        if NSEvent.modifierFlags.contains(.option) {
            if case .tag = sidebar { sidebar = .tag(id) } else { tagFilter = [id] }
        } else {
            addTagFilter(id)
        }
    }

    func deleteTag(_ id: String) {
        if sidebar == .tag(id) { sidebar = .all }
        tagFilter.removeAll { $0 == id }
        store.deleteTag(id)
    }

    func enterWorkspace(_ bookID: String) {
        workspace = bookID
        sidebar = .all
    }

    func exitWorkspace() {
        let book = workspace
        workspace = nil
        sidebar = book.map { .book($0) } ?? .all
    }

    private func step(_ delta: Int) {
        let list = currentList()
        guard !list.isEmpty else { return }
        guard let i = list.firstIndex(where: { $0.id == selectedNoteID }) else {
            selectedNoteID = list.first?.id
            return
        }
        selectedNoteID = list[min(max(i + delta, 0), list.count - 1)].id
    }

    // MARK: Links

    static func markdownLink(title: String, id: String) -> String {
        let safe = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(safe)](sumi://note/\(id))"
    }

    func copyLink() {
        guard let note = selectedNote else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.markdownLink(title: note.displayTitle, id: note.id), forType: .string)
    }

    /// Opens a note, switching the list to a place where it is visible.
    func open(noteID id: String) {
        guard let note = store.notes[id] else {
            NSSound.beep()
            return
        }
        if !currentList().contains(where: { $0.id == id }) {
            search = ""
            tagFilter = []
            workspace = nil
            sidebar = note.trashed ? .trash : .all
            if !currentList().contains(where: { $0.id == id }), let book = note.bookId { sidebar = .book(book) }
        }
        selectedNoteID = id
    }

    // MARK: Print / HTML

    func printNote() {
        guard selectedNote != nil, let web = editor.webView, let window = web.window else { return }
        editor.call("preparePrint")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.topMargin = 40
            info.bottomMargin = 40
            info.leftMargin = 40
            info.rightMargin = 40
            let op = web.printOperation(with: info)
            op.view?.frame = web.bounds
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    func exportHTML() {
        guard let note = selectedNote, let web = editor.webView else { return }
        let attachments = store.attachmentsDir
        web.evaluateJavaScript("window.sumi.exportHTML()") { result, _ in
            guard var html = result as? String else { return }
            // Inline attachments so the file is self-contained.
            let re = try! NSRegularExpression(pattern: "sumi://attachment/([A-Za-z0-9._-]+)")
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let whole = Range(m.range, in: html), let nameRange = Range(m.range(at: 1), in: html) else { continue }
                let file = attachments.appendingPathComponent(String(html[nameRange]))
                guard let data = try? Data(contentsOf: file) else { continue }
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                html.replaceSubrange(whole, with: "data:\(mime);base64,\(data.base64EncodedString())")
            }
            let css = Bundle.main.resourceURL
                .flatMap { try? String(contentsOf: $0.appendingPathComponent("editor/editor.css"), encoding: .utf8) } ?? ""
            let title = note.displayTitle
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let page = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(title)</title>
            <style>\(css)
            html, body { height: auto; overflow: auto; } body { display: block; }
            .markdown-body { max-width: 820px; margin: 0 auto; padding: 40px 28px; } .copy-btn { display: none; }
            </style></head>
            <body><div class="markdown-body"><h1>\(title)</h1>\(html)</div></body></html>
            """
            let panel = NSSavePanel()
            panel.nameFieldStringValue = note.displayTitle.replacingOccurrences(of: "/", with: "-") + ".html"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? page.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: History

    func recordHistory(from old: String?, to new: String?) {
        if navigating {
            navigating = false
            return
        }
        guard let old, old != new, store.notes[old] != nil else { return }
        back.append(old)
        if back.count > 100 { back.removeFirst() }
        forward.removeAll()
    }

    private func navigate(back goBack: Bool) {
        while let id = goBack ? back.popLast() : forward.popLast() {
            guard store.notes[id] != nil, id != selectedNoteID else { continue }
            if let cur = selectedNoteID {
                if goBack { forward.append(cur) } else { back.append(cur) }
            }
            navigating = true
            if !currentList().contains(where: { $0.id == id }) {
                search = ""
                sidebar = store.notes[id]?.trashed == true ? .trash : .all
            }
            selectedNoteID = id
            return
        }
    }

    // MARK: Focus

    func focusSearch() {
        exitDistractionFree()
        searchFocusRequest += 1
    }

    func focusList() {
        exitDistractionFree()
        listFocusRequest += 1
    }

    // MARK: Telescope

    func showTelescope(_ mode: TelescopeMode) {
        if telescope == nil { telescopeFromEditor = editor.hasFocus }
        telescope = mode
    }

    func toggleTelescope(_ mode: TelescopeMode) {
        if telescope != nil { closeTelescope() } else { showTelescope(mode) }
    }

    func closeTelescope(restoreFocus: Bool = true) {
        telescope = nil
        if restoreFocus, telescopeFromEditor {
            DispatchQueue.main.async { self.editor.focus() }
        }
    }

    // MARK: Templates

    func chooseTemplate() {
        guard !store.templates.isEmpty else {
            NSSound.beep()
            return
        }
        showTelescope(.templates)
    }

    func applyTemplate(_ templateID: String) {
        // An empty note is filled in place; otherwise the template makes a new note.
        var target = selectedNote
        if let n = target, n.trashed || n.bookId == store.templatesBookID
            || !n.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target = nil
        }
        if target == nil {
            newNote()
            if let id = selectedNoteID, store.notes[id]?.bookId == store.templatesBookID {
                store.update(id, touch: false) { $0.bookId = nil }
            }
        }
        guard let id = selectedNoteID else { return }
        editor.call("flush")
        store.applyTemplate(templateID, to: id)
        if !currentList().contains(where: { $0.id == id }) { open(noteID: id) }
        editorReloadToken += 1
        DispatchQueue.main.async { self.editor.focus() }
    }

    // MARK: Import / export

    func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        var bookId: String?
        if case .book(let id) = sidebar { bookId = id }
        var last: String?
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            last = store.createNote(title: url.deletingPathExtension().lastPathComponent, body: text, bookId: bookId)
        }
        if let last { selectedNoteID = last }
    }

    func exportSelected() {
        editor.call("flush")
        guard let id = selectedNoteID, let note = store.notes[id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = store.notes[id]?.body ?? note.body
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Switches the keyboard input source to an ASCII one (used when Vim returns to normal mode).
enum InputSource {
    static func selectASCII() {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable) {
            let capable = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
            if CFBooleanGetValue(capable) { return }
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           TISSelectInputSource(ascii) == noErr {
            return
        }
        if let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            TISSelectInputSource(layout)
        }
    }
}

/// System-wide ⌘⇧C for Quick Note (opt-in).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var installed = false

    func set(enabled: Bool, combo: KeyCombo, handler: @escaping () -> Void) {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard enabled else { return }
        self.handler = handler
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x53554D49), id: 1)
        guard let code = combo.keyCode else { return }
        var mods = 0
        if combo.mods & 1 != 0 { mods |= cmdKey }
        if combo.mods & 2 != 0 { mods |= controlKey }
        if combo.mods & 4 != 0 { mods |= optionKey }
        if combo.mods & 8 != 0 { mods |= shiftKey }
        RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
    }
}
