import AppKit
import Observation

/// On-disk library: `library.json` (notebooks + tags), `notes/<id>.json`, `attachments/`.
@MainActor @Observable
final class LibraryStore {
    private(set) var notes: [String: Note] = [:]
    private(set) var books: [Notebook] = []
    private(set) var tags: [Tag] = []

    /// True when the library lives in iCloud Drive.
    private(set) var usingICloud = false
    /// When a change made on another device was last picked up.
    private(set) var lastSync: Date?
    /// Bumped per note when its content is replaced from disk, so open editors reload.
    private(set) var externalVersion: [String: Int] = [:]

    @ObservationIgnored private(set) var root: URL
    @ObservationIgnored private var dirtyNotes = Set<String>()
    @ObservationIgnored private var removedNotes = Set<String>()
    @ObservationIgnored private var libraryDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stamps: [String: Date] = [:]
    @ObservationIgnored private var libraryStamp: Date?
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastRevisionAt: [String: Date] = [:]

    private struct Library: Codable {
        var books: [Notebook]
        var tags: [Tag]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var localRoot: URL {
        // SUMI_LOCAL_ROOT / SUMI_CLOUD_ROOT point the app at a scratch library (development and testing).
        if let path = ProcessInfo.processInfo.environment["SUMI_LOCAL_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sumi", isDirectory: true)
    }

    /// `iCloud Drive/Sumi`, or nil when iCloud Drive is not set up on this Mac.
    static var iCloudRoot: URL? {
        if let path = ProcessInfo.processInfo.environment["SUMI_CLOUD_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Sumi", isDirectory: true)
    }

    var notesDir: URL { root.appendingPathComponent("notes", isDirectory: true) }
    var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    var revisionsDir: URL { root.appendingPathComponent("revisions", isDirectory: true) }
    private var libraryFile: URL { root.appendingPathComponent("library.json") }

    /// Whole seconds, matching what the ISO 8601 files can represent.
    private static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    init() {
        // A scratch library (SUMI_LOCAL_ROOT) never follows the real iCloud setting.
        let env = ProcessInfo.processInfo.environment
        let scratch = env["SUMI_LOCAL_ROOT"] != nil && env["SUMI_CLOUD_ROOT"] == nil
        let cloud = !scratch && UserDefaults.standard.bool(forKey: "iCloudSync") ? Self.iCloudRoot : nil
        root = cloud ?? Self.localRoot
        usingICloud = cloud != nil
        openLibrary()
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    // MARK: Persistence

    private func openLibrary() {
        let fm = FileManager.default
        for dir in [notesDir, attachmentsDir, revisionsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        notes = [:]
        books = []
        tags = []
        stamps = [:]
        libraryStamp = nil
        dirtyNotes = []
        removedNotes = []
        libraryDirty = false
        rescan(initial: true)
        // A shared library is never seeded: an empty iCloud folder may just not be downloaded yet.
        if !usingICloud {
            if notes.isEmpty && books.isEmpty { seed() }
            ensureTemplates()
        }
        flush()
        startWatching()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        for id in dirtyNotes {
            guard let note = notes[id], let data = try? Self.encoder.encode(note) else { continue }
            let file = notesDir.appendingPathComponent("\(id).json")
            try? data.write(to: file, options: .atomic)
            stamps[id] = Self.mtime(file)
        }
        dirtyNotes.removeAll()
        for id in removedNotes {
            try? FileManager.default.removeItem(at: notesDir.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: revisionsDir.appendingPathComponent(id))
            stamps[id] = nil
        }
        removedNotes.removeAll()
        if libraryDirty {
            if let data = try? Self.encoder.encode(Library(books: books, tags: tags)) {
                try? data.write(to: libraryFile, options: .atomic)
                libraryStamp = Self.mtime(libraryFile)
            }
            libraryDirty = false
        }
    }

    private func touchLibrary() {
        libraryDirty = true
        scheduleSave()
    }

    // MARK: Sync (picking up changes made by another device)

    private func startWatching() {
        stopWatching()
        for dir in [root, notesDir] {
            let fd = Darwin.open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        if usingICloud {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            }
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        pollTimer?.invalidate()
        pollTimer = nil
        rescanTask?.cancel()
    }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            self?.rescan()
        }
    }

    /// Reads whatever changed on disk. The newer `updatedAt` wins; unsaved local edits always win.
    func rescan(initial: Bool = false) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: notesDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var seen = Set<String>()
        var changed = false

        func adopt(_ note: Note) {
            if let mine = notes[note.id] {
                if mine == note { return }
                if dirtyNotes.contains(note.id) || mine.updatedAt > note.updatedAt {
                    dirtyNotes.insert(note.id) // ours is newer: write it back
                    scheduleSave()
                    return
                }
            }
            notes[note.id] = note
            if !initial { externalVersion[note.id, default: 0] += 1 }
            changed = true
        }

        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                // Not downloaded yet: the note still exists, ask iCloud for it.
                seen.insert(String(name.dropFirst().dropLast(".json.icloud".count)))
                try? fm.startDownloadingUbiquitousItem(at: file)
                continue
            }
            guard file.pathExtension == "json" else { continue }
            let fileID = file.deletingPathExtension().lastPathComponent
            let stamp = Self.mtime(file)
            if stamp != nil, stamps[fileID] == stamp {
                seen.insert(fileID)
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let note = try? Self.decoder.decode(Note.self, from: data) else { continue }
            seen.insert(note.id)
            if note.id != fileID {
                // A conflict copy such as "<id> 2.json": keep the newer content, drop the copy.
                adopt(note)
                try? fm.removeItem(at: file)
                continue
            }
            stamps[fileID] = stamp
            adopt(note)
        }

        if !initial {
            for id in Array(notes.keys) where !seen.contains(id) && !dirtyNotes.contains(id) {
                notes[id] = nil // deleted on another device
                stamps[id] = nil
                changed = true
            }
        }

        let libStamp = Self.mtime(libraryFile)
        if libStamp != libraryStamp, !libraryDirty,
           let data = try? Data(contentsOf: libraryFile),
           let lib = try? Self.decoder.decode(Library.self, from: data) {
            libraryStamp = libStamp
            if lib.books != books || lib.tags != tags {
                books = lib.books
                tags = lib.tags
                changed = true
            }
        }
        let placeholder = root.appendingPathComponent(".library.json.icloud")
        if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: placeholder) }

        if changed, !initial { lastSync = Date() }
    }

    /// Moves the library between this Mac and iCloud Drive, merging into whatever is already there.
    @discardableResult
    func setICloud(_ enabled: Bool) -> Bool {
        let target: URL
        if enabled {
            guard let cloud = Self.iCloudRoot else { return false }
            target = cloud
        } else {
            target = Self.localRoot
        }
        guard target != root else { return true }
        if ProcessInfo.processInfo.environment["SUMI_LOCAL_ROOT"] != nil,
           ProcessInfo.processInfo.environment["SUMI_CLOUD_ROOT"] == nil { return false }
        flush()
        stopWatching()
        do {
            try Self.merge(from: root, into: target)
        } catch {
            startWatching()
            return false
        }
        root = target
        usingICloud = enabled
        UserDefaults.standard.set(enabled, forKey: "iCloudSync")
        openLibrary()
        return true
    }

    /// Copies a library into another one. Nothing in `dst` is lost: same-id notes keep the newer
    /// version, same-named notebooks and tags are reused, and identical notes are not duplicated.
    private static func merge(from src: URL, into dst: URL) throws {
        let fm = FileManager.default
        for sub in ["notes", "attachments", "revisions"] {
            try fm.createDirectory(at: dst.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        func library(_ root: URL) -> Library {
            (try? Data(contentsOf: root.appendingPathComponent("library.json")))
                .flatMap { try? decoder.decode(Library.self, from: $0) } ?? Library(books: [], tags: [])
        }
        func noteFiles(_ root: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("notes"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
        }
        func read(_ url: URL) -> Note? {
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Note.self, from: $0) }
        }

        let from = library(src)
        var into = library(dst)

        var bookMap: [String: String] = [:]
        var pending = from.books
        var progressed = true
        while !pending.isEmpty, progressed {
            progressed = false
            for book in pending {
                let parent = book.parentId.map { bookMap[$0] ?? $0 }
                if let p = book.parentId, bookMap[p] == nil, from.books.contains(where: { $0.id == p }) { continue }
                if into.books.contains(where: { $0.id == book.id }) {
                    bookMap[book.id] = book.id
                } else if let same = into.books.first(where: { $0.name == book.name && $0.parentId == parent }) {
                    bookMap[book.id] = same.id
                } else {
                    into.books.append(Notebook(id: book.id, name: book.name, parentId: parent))
                    bookMap[book.id] = book.id
                }
                pending.removeAll { $0.id == book.id }
                progressed = true
            }
        }

        var tagMap: [String: String] = [:]
        for tag in from.tags {
            if into.tags.contains(where: { $0.id == tag.id }) {
                tagMap[tag.id] = tag.id
            } else if let same = into.tags.first(where: { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }) {
                tagMap[tag.id] = same.id
            } else {
                into.tags.append(tag)
                tagMap[tag.id] = tag.id
            }
        }

        var existing: [String: Note] = [:]
        for file in noteFiles(dst) {
            if let n = read(file) { existing[n.id] = n }
        }
        for file in noteFiles(src) {
            guard var note = read(file) else { continue }
            note.bookId = note.bookId.flatMap { bookMap[$0] }
            note.tagIds = note.tagIds.compactMap { tagMap[$0] }
            if let there = existing[note.id] {
                if there.updatedAt >= note.updatedAt { continue }
            } else if existing.values.contains(where: { $0.title == note.title && $0.body == note.body && $0.trashed == note.trashed }) {
                continue
            }
            try encoder.encode(note).write(to: dst.appendingPathComponent("notes/\(note.id).json"), options: .atomic)
            existing[note.id] = note
        }

        for sub in ["attachments", "revisions"] {
            let items = (try? fm.contentsOfDirectory(at: src.appendingPathComponent(sub), includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let target = dst.appendingPathComponent(sub).appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
            }
        }
        try encoder.encode(into).write(to: dst.appendingPathComponent("library.json"), options: .atomic)
    }

    // MARK: Revisions

    struct Revision: Codable, Identifiable, Hashable {
        var id: String
        var date: Date
        var title: String
        var body: String
    }

    /// Saves a copy of the note as it is now (at most 50 are kept per note).
    private func snapshot(_ note: Note) {
        guard !note.body.isEmpty else { return }
        let dir = revisionsDir.appendingPathComponent(note.id, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rev = Revision(id: String(Int(Date().timeIntervalSince1970 * 1000)), date: note.updatedAt,
                           title: note.title, body: note.body)
        if let data = try? Self.encoder.encode(rev) {
            try? data.write(to: dir.appendingPathComponent("\(rev.id).json"), options: .atomic)
        }
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in files.dropLast(50) { try? fm.removeItem(at: old) }
    }

    func revisions(for id: String) -> [Revision] {
        let dir = revisionsDir.appendingPathComponent(id, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? Self.decoder.decode(Revision.self, from: $0) } }
            .sorted { $0.id > $1.id }
    }

    func restore(_ revision: Revision, to id: String) {
        guard let current = notes[id] else { return }
        snapshot(current)
        lastRevisionAt[id] = Date()
        update(id) { n in
            n.body = revision.body
            n.title = revision.title
        }
    }

    // MARK: Backlinks

    func backlinks(to id: String) -> [Note] {
        let needle = "sumi://note/\(id)"
        return notes.values
            .filter { !$0.trashed && $0.id != id && $0.body.contains(needle) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Queries

    var flatBooks: [(book: Notebook, depth: Int)] {
        var out: [(Notebook, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            let children = books
                .filter { $0.parentId == parent }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for b in children {
                out.append((b, depth))
                walk(b.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    func book(_ id: String?) -> Notebook? {
        guard let id else { return nil }
        return books.first { $0.id == id }
    }

    func tag(_ id: String) -> Tag? { tags.first { $0.id == id } }

    func descendants(of id: String) -> Set<String> {
        var result = Set<String>()
        var queue = [id]
        while let cur = queue.popLast() {
            for b in books where b.parentId == cur && !result.contains(b.id) {
                result.insert(b.id)
                queue.append(b.id)
            }
        }
        return result
    }

    func filtered(_ item: SidebarItem?, search: String = "", sort: SortKey = .updated, showFinished: Bool,
                  tags filterTags: [String] = [], workspace: String? = nil, sorted: Bool = true) -> [Note] {
        let item = item ?? .all
        let query = SearchQuery(search)
        var result: [Note]
        var hideFinished = !showFinished && query.isEmpty
        switch item {
        case .trash:
            result = notes.values.filter { $0.trashed }
            hideFinished = false
        case .all:
            let templates = workspace == nil ? (templatesBookID.map { descendants(of: $0).union([$0]) } ?? []) : []
            result = notes.values.filter { !$0.trashed && $0.bookId.map(templates.contains) != true }
        case .book(let id):
            let ids = descendants(of: id).union([id])
            result = notes.values.filter { !$0.trashed && $0.bookId.map(ids.contains) == true }
        case .status(let s):
            result = notes.values.filter { !$0.trashed && $0.status == s }
            hideFinished = false
        case .tag(let t):
            result = notes.values.filter { !$0.trashed && $0.tagIds.contains(t) }
        }
        if let workspace, item != .trash {
            let inside = descendants(of: workspace).union([workspace])
            result.removeAll { $0.bookId.map(inside.contains) != true }
        }
        for t in filterTags { result.removeAll { !$0.tagIds.contains(t) } }
        if hideFinished { result.removeAll { $0.status.isFinished } }
        if !query.isEmpty {
            let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
            var bookNames: [String: [String]] = [:]
            for b in books {
                var names: [String] = []
                var cur: Notebook? = b
                while let c = cur, names.count < 32 {
                    names.append(c.name)
                    cur = book(c.parentId)
                }
                bookNames[b.id] = names
            }
            result = result.filter { n in
                query.matches(n, bookNames: n.bookId.flatMap { bookNames[$0] } ?? [],
                              tagNames: n.tagIds.compactMap { tagNames[$0] })
            }
        }
        guard sorted else { return result } // counting does not need the order
        result.sort { a, b in
            if item != .trash, a.pinned != b.pinned { return a.pinned }
            switch sort {
            case .updated: return a.updatedAt > b.updatedAt
            case .created: return a.createdAt > b.createdAt
            case .title: return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            }
        }
        return result
    }

    func count(_ item: SidebarItem, showFinished: Bool, workspace: String? = nil) -> Int {
        filtered(item, showFinished: showFinished, workspace: workspace, sorted: false).count
    }

    // MARK: Notes

    @discardableResult
    func createNote(title: String = "", body: String = "", bookId: String? = nil,
                    status: NoteStatus = .none, tagIds: [String] = []) -> String {
        var note = Note(title: title, body: body, bookId: bookId, status: status, tagIds: tagIds)
        note.createdAt = Self.now()
        note.updatedAt = note.createdAt
        notes[note.id] = note
        dirtyNotes.insert(note.id)
        scheduleSave()
        return note.id
    }

    func update(_ id: String, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        let before = note
        change(&note)
        guard note != before else { return }
        if touch { note.updatedAt = Self.now() }
        if note.body != before.body {
            // Keep the pre-edit text once per editing burst (5 minutes).
            let last = lastRevisionAt[id]
            if last == nil || Date().timeIntervalSince(last!) > 300 {
                snapshot(before)
                lastRevisionAt[id] = Date()
            }
        }
        notes[id] = note
        dirtyNotes.insert(id)
        scheduleSave()
    }

    func setBody(_ id: String, _ body: String) {
        update(id) { $0.body = body }
    }

    func trash(_ id: String) { update(id, touch: false) { $0.trashed = true; $0.pinned = false } }
    func restore(_ id: String) {
        update(id, touch: false) { n in
            n.trashed = false
            if self.book(n.bookId) == nil { n.bookId = nil }
        }
    }

    func deletePermanently(_ id: String) {
        guard notes.removeValue(forKey: id) != nil else { return }
        dirtyNotes.remove(id)
        removedNotes.insert(id)
        scheduleSave()
    }

    func emptyTrash() {
        for n in notes.values where n.trashed { deletePermanently(n.id) }
    }

    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let n = notes[id] else { return nil }
        return createNote(title: n.displayTitle + L(" copy"), body: n.body, bookId: n.bookId,
                          status: n.status, tagIds: n.tagIds)
    }

    // MARK: Notebooks

    @discardableResult
    func addBook(name: String, parentId: String? = nil) -> String {
        let book = Notebook(name: name, parentId: parentId)
        books.append(book)
        touchLibrary()
        return book.id
    }

    func renameBook(_ id: String, to name: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].name = name
        touchLibrary()
    }

    /// Moves a notebook under another one (nil = top level). Refuses to move it into itself.
    @discardableResult
    func moveBook(_ id: String, under parent: String?) -> Bool {
        guard let i = books.firstIndex(where: { $0.id == id }), books[i].parentId != parent else { return false }
        if let parent {
            guard parent != id, !descendants(of: id).contains(parent), book(parent) != nil else { return false }
        }
        books[i].parentId = parent
        touchLibrary()
        return true
    }

    /// Deletes the notebook and its sub-notebooks; their notes go to the trash.
    func deleteBook(_ id: String) {
        let ids = descendants(of: id).union([id])
        for n in notes.values where n.bookId.map(ids.contains) == true && !n.trashed {
            trash(n.id)
        }
        books.removeAll { ids.contains($0.id) }
        touchLibrary()
    }

    // MARK: Tags

    func addTag(named raw: String, to noteID: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tagID: String
        if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            tagID = existing.id
        } else {
            let tag = Tag(name: name)
            tags.append(tag)
            tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            touchLibrary()
            tagID = tag.id
        }
        update(noteID) { if !$0.tagIds.contains(tagID) { $0.tagIds.append(tagID) } }
    }

    /// Number of notes (outside the Trash) carrying each tag.
    var tagCounts: [String: Int] {
        var out: [String: Int] = [:]
        for n in notes.values where !n.trashed {
            for t in n.tagIds { out[t, default: 0] += 1 }
        }
        return out
    }

    /// Tags used by the notes of a notebook and its sub-notebooks.
    func tags(in bookID: String) -> [Tag] {
        let inside = descendants(of: bookID).union([bookID])
        var used = Set<String>()
        for n in notes.values where !n.trashed && n.bookId.map(inside.contains) == true { used.formUnion(n.tagIds) }
        return tags.filter { used.contains($0.id) }
    }

    /// Renames a tag. If another tag already has that name the two are merged; returns the id that remains.
    @discardableResult
    func renameTag(_ id: String, to raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = tags.firstIndex(where: { $0.id == id }) else { return id }
        if let other = tags.first(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            for n in notes.values where n.tagIds.contains(id) {
                update(n.id, touch: false) { note in
                    note.tagIds = note.tagIds.map { $0 == id ? other.id : $0 }
                    var seen = Set<String>()
                    note.tagIds.removeAll { !seen.insert($0).inserted }
                }
            }
            tags.remove(at: i)
            touchLibrary()
            return other.id
        }
        tags[i].name = name
        tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        touchLibrary()
        return id
    }

    func updateTag(_ id: String, _ change: (inout Tag) -> Void) {
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return }
        change(&tags[i])
        touchLibrary()
    }

    func deleteTag(_ id: String) {
        tags.removeAll { $0.id == id }
        for n in notes.values where n.tagIds.contains(id) {
            update(n.id, touch: false) { $0.tagIds.removeAll { $0 == id } }
        }
        touchLibrary()
    }

    // MARK: Templates

    /// Notes in the top-level "Templates" notebook are templates.
    var templatesBookID: String? {
        books.first { $0.parentId == nil && $0.name == "Templates" }?.id
    }

    var templates: [Note] {
        guard let id = templatesBookID else { return [] }
        return notes.values
            .filter { !$0.trashed && $0.bookId == id }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    func applyTemplate(_ templateID: String, to noteID: String) {
        guard let template = notes[templateID] else { return }
        let (meta, raw) = Self.frontMatter(template.body)
        let body = Self.expand(raw)
        let status = meta["status"].flatMap { v in
            NoteStatus.allCases.first { $0.rawValue.lowercased() == v.lowercased().replacingOccurrences(of: " ", with: "") }
        }
        let destination = meta["notebook"].flatMap { bookNamed($0) }
        update(noteID) { n in
            n.body = body
            if n.title.isEmpty { n.title = Self.expand(meta["title"] ?? template.title) }
            if let status { n.status = status } else if n.status == .none { n.status = template.status }
            for t in template.tagIds where !n.tagIds.contains(t) { n.tagIds.append(t) }
            if let destination { n.bookId = destination }
        }
        if let names = meta["tags"] {
            for name in names.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",") {
                addTag(named: name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")), to: noteID)
            }
        }
    }

    /// A notebook by name, or by path such as `Projects/Sumi`.
    private func bookNamed(_ path: String) -> String? {
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        if parts.count == 1 {
            return (books.first { $0.name == first && $0.parentId == nil } ?? books.first { $0.name == first })?.id
        }
        var parent: String?
        for name in parts {
            guard let next = books.first(where: { $0.name == name && $0.parentId == parent }) else { return nil }
            parent = next.id
        }
        return parent
    }

    /// A leading `---` block of `title:`, `tags:`, `status:`, `notebook:` lines presets the new note.
    static func frontMatter(_ text: String) -> (meta: [String: String], body: String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { return ([:], text) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["title", "tags", "status", "notebook"].contains(key) else { return ([:], text) }
            meta[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var rest = String(text[end.upperBound...])
        while rest.hasPrefix("\n") { rest.removeFirst() }
        return (meta, rest)
    }

    /// Expands `{{ 'now' | date: '%Y-%m-%d' }}` and `{% uuid %}`.
    static func expand(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\{%\s*uuid\s*%\}"#, with: UUID().uuidString.lowercased(),
                                            options: .regularExpression)
        let re = try! NSRegularExpression(pattern: #"\{\{\s*'now'\s*\|\s*date:\s*'([^']*)'\s*\}\}"#)
        while let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let whole = Range(m.range, in: out), let fmt = Range(m.range(at: 1), in: out) {
            var now = time(nil)
            var parts = tm()
            localtime_r(&now, &parts)
            var buf = [CChar](repeating: 0, count: 128)
            strftime(&buf, buf.count, String(out[fmt]), &parts)
            out.replaceSubrange(whole, with: String(cString: buf))
        }
        return out
    }

    private func ensureTemplates() {
        guard templatesBookID == nil else { return }
        let book = addBook(name: "Templates")
        let date = "{{ 'now' | date: '%Y-%m-%d' }}"
        if AppLanguage.isJapanese {
            createNote(title: "Daily Report \(date)", body: """
            ## やったこと

            - 

            ## わかったこと

            - 

            ## 明日やること

            - [ ] 
            """, bookId: book)
            createNote(title: "Bug fix", body: """
            ## 症状

            ## 再現手順

            1. 

            ## 原因

            ## 修正

            - [ ] 修正する
            - [ ] テストを追加する
            """, bookId: book)
            createNote(title: "Meeting \(date)", body: """
            | 項目   | 内容 |
            | ------ | ---- |
            | 日時   | \(date) |
            | 参加者 |      |

            ## アジェンダ

            - 

            ## 決定事項

            - 

            ## TODO

            - [ ] 
            """, bookId: book)
        } else {
            createNote(title: "Daily Report \(date)", body: """
            ## Done

            - 

            ## Learned

            - 

            ## Tomorrow

            - [ ] 
            """, bookId: book)
            createNote(title: "Bug fix", body: """
            ## Symptom

            ## Steps to reproduce

            1. 

            ## Cause

            ## Fix

            - [ ] Fix it
            - [ ] Add a test
            """, bookId: book)
            createNote(title: "Meeting \(date)", body: """
            | Item      | Details |
            | --------- | ------- |
            | Date      | \(date) |
            | Attendees |         |

            ## Agenda

            - 

            ## Decisions

            - 

            ## TODO

            - [ ] 
            """, bookId: book)
        }
    }

    // MARK: Attachments

    func saveAttachment(_ data: Data, ext: String) -> String? {
        let safeExt = ext.filter { $0.isLetter || $0.isNumber }.lowercased()
        let name = UUID().uuidString.prefix(12).lowercased() + "." + (safeExt.isEmpty ? "png" : safeExt)
        do {
            try data.write(to: attachmentsDir.appendingPathComponent(String(name)), options: .atomic)
            return String(name)
        } catch {
            return nil
        }
    }

    /// Stores any file as an attachment, keeping a readable name.
    func saveAttachment(_ data: Data, name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.filter { $0.isLetter || $0.isNumber }.lowercased()
        var base = url.deletingPathExtension().lastPathComponent
            .map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        base = String(base.prefix(40))
        let stored = UUID().uuidString.prefix(8).lowercased() + "-" + (base.isEmpty ? "file" : base) + (ext.isEmpty ? "" : "." + ext)
        do {
            try data.write(to: attachmentsDir.appendingPathComponent(stored), options: .atomic)
            return stored
        } catch {
            return nil
        }
    }

    // MARK: First launch

    private func seed() {
        let inbox = addBook(name: "Inbox")
        addBook(name: "Projects")
        if AppLanguage.isJapanese {
            createNote(title: "Sumi へようこそ", body: Self.welcomeJA, bookId: inbox, status: .active)
        } else {
            createNote(title: "Welcome to Sumi", body: Self.welcomeEN, bookId: inbox, status: .active)
        }
        flush()
    }

    private static let welcomeEN = #"""
    # Welcome to Sumi

    A simple, native Markdown notes app for macOS. Vim keybindings are available too.
    This note is also a tour of the features. Press `⌘E` for the preview or `⌘P` for side by side.

    > [!TIP]
    > When in doubt, press `⌘K` (Telescope). It finds notes and commands.

    ## 1. Layout and moving around

    From left to right: **sidebar → note list → editor**.

    | Key | Action |
    | --- | --- |
    | `Ctrl+H` / `Ctrl+L` | Move to the pane on the left / right |
    | `⌘1` / `⌘2` | Go to the note list / the editor |
    | `j` `k` | Move up and down in the list and the sidebar |
    | `Enter` `l` `i` | From the list to the editor |
    | `/` | Search field, from the list |
    | `⌘/` | Show or hide the sidebar |
    | `⌘⇧D` | Distraction free (double-clicking a note in the list also works) |
    | `⌘←` `⌘→` | Previous / next note you looked at |

    ## 2. Vim

    - Turn on **Vim keybindings** in Settings (`⌘,`) › Editor (off at first). Then the usual Vim commands work (`hjkl`, `dd`, `ciw`, `.`, macros, registers, `/` search, `:s` substitute …)
    - `:w` save / `:n` `:prev` next and previous note / `:p` preview / `:side` side by side / `:cmd {command id}`
    - Returning to normal mode switches the input source back to ASCII
    - Yank and paste share the macOS clipboard
    - Add mappings such as `imap jj <Esc>` to the vimrc in Settings (`⌘,`) › Editor

    ## 3. Writing

    | Key | Action |
    | --- | --- |
    | `⌘N` | New note |
    | `⌘B` `⌘I` | Bold / italic |
    | `⌘⌥K` | Link |
    | `⌘'` | Blockquote |
    | `⇧⌘L` | Bulleted list |
    | `⌘T` | Start from a template |
    | `⌘D` | Duplicate the note |

    - **Slash commands**: type `/` on an empty line to insert headings, tables, code blocks, the date and more
    - **Emoji**: type `:smile` to get suggestions :tada:
    - **Selection toolbar**: select text to get formatting buttons and the AI button
    - **Images and files**: paste or drop to attach them (double-click an image in the preview to enlarge it)

    ### Tables

    Press `Tab` in a cell to move to the next one; the table is formatted for you. When the cursor is in a table, a toolbar for adding and moving rows and columns appears.

    | Feature | Key | Notes |
    | :--- | :---: | ---: |
    | Next cell | `Tab` | Formats the table |
    | Previous cell | `⇧Tab` | |
    | Next row | `Enter` | |

    ### Tasks

    Click a checkbox in the preview and the text is updated. Progress is shown in the note list.

    - [x] Open a note
    - [ ] Click a checkbox in the preview
    - [ ] Paste an image
    - [ ] Try AI with `⌘⇧A`

    ### Code, math and diagrams

    ```swift
    let greeting = "Hello, Sumi"
    print(greeting)
    ```

    Write math like $E = mc^2$.

    $$
    \int_0^1 x^2 \, dx = \frac{1}{3}
    $$

    ```mermaid
    graph LR
      A[Write] --> B[Organize] --> C[Find]
    ```

    ### Alerts

    > [!NOTE]
    > Besides `> [!NOTE]` there are `TIP`, `IMPORTANT`, `WARNING` and `CAUTION`.

    Also: <mark>highlight</mark>, footnotes[^1], and color swatches for codes like `#2f6fde`.

    [^1]: A footnote looks like this.

    ## 4. Organizing

    - **Notebooks**: can be nested. Drag to change the nesting, use the triangle to collapse. Select one in the sidebar and press `Enter` to show only that notebook (a workspace)
    - **Status**: `⌘⌃1`–`5` for None / Active / On Hold / Completed / Dropped. Completed and dropped notes are hidden from lists
    - **Tags**: `⌘⇧T` goes to the tag field, which completes existing tags. Click a tag in the list to filter (several tags are combined with AND; `⌥`-click for that tag only)
    - **Pinning**: `⌘J` › Pin to Top
    - **Multiple selection**: `⌘`- or `⇧`-click, then right-click to move, tag or delete them together
    - **Note links**: type `[[` to search for a note and insert a link. The linked note shows “Linked from”

    ## 5. Finding

    `⌘K` opens Telescope.

    | Type | Finds |
    | --- | --- |
    | (anything) | Notes |
    | `>` | Commands |
    | `b ` | Notebooks |
    | `t ` | Tags |
    | `#` | Headings in this note |

    `⌘⇧F` searches the list. These qualifiers narrow it down.

    | Syntax | Meaning |
    | --- | --- |
    | `book:Inbox` | In a notebook |
    | `tag:work` | With a tag |
    | `status:active` | With a status |
    | `title:minutes` / `body:TODO` | Title only / body only |
    | `-tag:done` | Exclude |
    | `"hello world"` | Exact phrase |

    ## 6. AI (Apple Intelligence)

    Available only on Macs that support Apple Intelligence (Settings › AI shows whether yours does). It runs on this Mac, so your notes are not sent anywhere.

    - `⌘⇧A`: summarize, key points, improve, proofread, translate, title and tag suggestions, questions about the note
    - **Suggestions while typing**: turn it on in Settings › AI, then pause at the end of a line to see a faint continuation. `Tab` accepts it
    - It works on the selection, or on the whole note when nothing is selected

    ## 7. More

    - **Quick Note**: start writing in a separate window. Change the key in Settings › General; it can also be called from other apps
    - **Revision history**: `⌘J` › Revision History brings back earlier content
    - **iCloud sync**: turn it on in Settings › General to share notes with your other Macs
    - **Export**: Markdown / HTML / PDF (print) from `⌘J`
    - **Appearance**: themes and your own CSS in Settings › Appearance
    - **Key bindings**: keymap.json in Settings › Keys
    - **Plugins**: Settings › Plugins has a guide and an example you can add with one click

    > [!NOTE]
    > Feel free to rewrite this note. Revision history can bring the original back.
    """#

    private static let welcomeJA = #"""
    # Sumi へようこそ

    シンプルな macOS ネイティブの Markdown ノートアプリです。Vim キーバインドでも書けます。
    このノート自体が機能の見本になっています。`⌘E` でプレビュー、`⌘P` で左右分割にして読んでみてください。

    > [!TIP]
    > 迷ったら `⌘K`（Telescope）。ノートもコマンドもここから探せます。

    ## 1. 画面と移動

    画面は左から **サイドバー → ノート一覧 → エディタ** の3つです。

    | キー | 動作 |
    | --- | --- |
    | `Ctrl+H` / `Ctrl+L` | 左 / 右のペインへ移動 |
    | `⌘1` / `⌘2` | ノート一覧 / エディタへ移動 |
    | `j` `k` | 一覧・サイドバーで上下に移動 |
    | `Enter` `l` `i` | 一覧からエディタへ |
    | `/` | 一覧で検索欄へ |
    | `⌘/` | サイドバーの表示切替 |
    | `⌘⇧D` | 集中モード（一覧のノートをダブルクリックでも入れます） |
    | `⌘←` `⌘→` | 前 / 次に見ていたノートへ |

    ## 2. Vim

    - 設定（`⌘,`）› エディタ で **Vim キーバインド** をオンにできます（最初はオフです）。オンにすると Vim の操作が使えます（`hjkl`, `dd`, `ciw`, `.`, マクロ, レジスタ, `/` 検索, `:s` 置換 …）
    - `:w` 保存 / `:n` `:prev` 次・前のノート / `:p` プレビュー / `:side` 左右分割 / `:cmd {コマンドID}`
    - ノーマルモードに戻ると、日本語入力が自動で英数に切り替わります
    - ヤンクとペーストは macOS のクリップボードと共通です
    - 設定（`⌘,`）› エディタ の vimrc に `imap jj <Esc>` などのキーマップを書けます

    ## 3. 書く

    | キー | 動作 |
    | --- | --- |
    | `⌘N` | 新規ノート |
    | `⌘B` `⌘I` | 太字 / 斜体 |
    | `⌘⌥K` | リンク |
    | `⌘'` | 引用 |
    | `⇧⌘L` | 箇条書き |
    | `⌘T` | テンプレートから作る |
    | `⌘D` | ノートを複製 |

    - **スラッシュコマンド**：空行で `/` を打つと、見出し・表・コードブロック・日付などを挿入できます
    - **絵文字**：`:smile` のように打つと候補が出ます :tada:
    - **選択ツールバー**：文字を選択すると、書式ボタンと AI ボタンが出ます
    - **画像・ファイル**：ペーストかドロップで添付されます（画像はプレビューでダブルクリックすると拡大）

    ### 表

    セルの中で `Tab` を押すと次のセルへ進み、表が自動で整形されます。カーソルが表にあると、行・列の追加や移動のツールバーが出ます。

    | 機能 | キー | メモ |
    | :--- | :---: | ---: |
    | 次のセル | `Tab` | 自動整形 |
    | 前のセル | `⇧Tab` | |
    | 次の行 | `Enter` | |

    ### タスク

    プレビューでチェックボックスをクリックすると、本文も更新されます。進み具合はノート一覧に表示されます。

    - [x] ノートを開く
    - [ ] プレビューでチェックボックスをクリックしてみる
    - [ ] 画像をペーストしてみる
    - [ ] `⌘⇧A` で AI を試してみる

    ### コード・数式・図

    ```swift
    let greeting = "Hello, Sumi"
    print(greeting)
    ```

    数式は $E = mc^2$ のように書けます。

    $$
    \int_0^1 x^2 \, dx = \frac{1}{3}
    $$

    ```mermaid
    graph LR
      A[書く] --> B[整理する] --> C[見つける]
    ```

    ### アラート

    > [!NOTE]
    > `> [!NOTE]` のほか、`TIP` `IMPORTANT` `WARNING` `CAUTION` が使えます。

    その他：<mark>ハイライト</mark>、脚注[^1]、`#2f6fde` のような色コードの色見本表示。

    [^1]: 脚注はこのように書きます。

    ## 4. 整理する

    - **ノートブック**：入れ子にできます。ドラッグで入れ子を変更、三角で折りたたみ。サイドバーで選んで `Enter` を押すと、そのノートブックだけの表示（ワークスペース）になります
    - **ステータス**：`⌘⌃1`〜`5` で なし / 進行中 / 保留 / 完了 / 中止。完了・中止したノートは一覧から隠れます
    - **タグ**：`⌘⇧T` でタグ欄へ。打つと既存タグが補完されます。一覧のタグをクリックすると絞り込み（複数で AND、`⌥` クリックでそのタグだけ）
    - **ピン留め**：`⌘J` › 一番上にピン留め
    - **複数選択**：`⌘` / `⇧` クリックで選び、右クリックでまとめて移動・タグ付け・削除
    - **ノートリンク**：`[[` と打つとノートを検索してリンクを挿入。リンクされた側には「リンク元」が出ます

    ## 5. 見つける

    `⌘K` で Telescope が開きます。

    | 入力 | 探すもの |
    | --- | --- |
    | （そのまま） | ノート |
    | `>` | コマンド |
    | `b ` | ノートブック |
    | `t ` | タグ |
    | `#` | このノートの見出し |

    `⌘⇧F` は一覧の検索です。次の書き方で絞り込めます。

    | 書き方 | 意味 |
    | --- | --- |
    | `book:Inbox` | ノートブックで絞る |
    | `tag:work` | タグで絞る |
    | `status:active` | ステータスで絞る |
    | `title:議事録` / `body:TODO` | タイトルだけ / 本文だけ |
    | `-tag:done` | 除外 |
    | `"hello world"` | 語句をそのまま検索 |

    ## 6. AI（Apple Intelligence）

    Apple Intelligence に対応した Mac でだけ使えます（使えるかどうかは 設定 › AI に表示されます）。この Mac の中だけで動くので、ノートの内容は外部に送られません。

    - `⌘⇧A`：要約、要点、推敲、誤字修正、翻訳、タイトル案、タグ案、ノートへの質問
    - **入力中の提案**：設定 › AI でオンにすると、行末で手を止めたときに続きが薄く表示されます。`Tab` で確定
    - 選択範囲があればそこだけ、なければノート全体が対象です

    ## 7. そのほか

    - **クイックノート**：別ウインドウですぐ書き始めます。キーは設定 › 一般 で変更でき、他のアプリから呼び出すこともできます
    - **変更履歴**：`⌘J` › 変更履歴 で以前の内容に戻せます
    - **iCloud 同期**：設定 › 一般 でオンにすると、他の Mac と共有されます
    - **書き出し**：`⌘J` から Markdown / HTML / PDF（印刷）
    - **見た目**：設定 › 外観 でテーマと独自 CSS
    - **キーの変更**：設定 › キー の keymap.json
    - **プラグイン**：設定 › プラグイン に書き方と、ワンクリックで追加できる例があります

    > [!NOTE]
    > このノートは自由に書き換えて構いません。元に戻したくなったら変更履歴から戻せます。
    """#
}
