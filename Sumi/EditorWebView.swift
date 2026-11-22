import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled editor (`sumi://app/…`) and note attachments (`sumi://attachment/…`).
final class SumiSchemeHandler: NSObject, WKURLSchemeHandler {
    let attachments: () -> URL
    /// The folder of the Markdown file being edited in place, so its relative images load.
    let document: () -> URL?

    init(attachments: @escaping () -> URL, document: @escaping () -> URL? = { nil }) {
        self.attachments = attachments
        self.document = document
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var file: URL?
        if url.host == "app", let base = Bundle.main.resourceURL?.appendingPathComponent("editor") {
            let candidate = base.appendingPathComponent(url.path).standardizedFileURL
            if candidate.path.hasPrefix(base.standardizedFileURL.path) { file = candidate }
            if let found = file, !FileManager.default.fileExists(atPath: found.path), let dir = document()?.standardizedFileURL {
                let beside = dir.appendingPathComponent(url.path).standardizedFileURL
                if beside.path.hasPrefix(dir.path + "/") { file = beside }
            }
        } else if url.host == "attachment" {
            file = attachments().appendingPathComponent(url.lastPathComponent)
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if mime.hasPrefix("text/") || mime.contains("javascript") { mime += "; charset=utf-8" }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct EditorWebView: NSViewRepresentable {
    let noteID: String?
    let readOnly: Bool
    let mode: ViewMode
    let options: EditorOptions
    let reloadToken: Int
    var pluginVersion = 0
    let store: LibraryStore
    let app: AppState

    func makeCoordinator() -> Coordinator { Coordinator(store: store, app: app) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SumiSchemeHandler(attachments: { [store] in MainActor.assumeIsolated { store.attachmentsDir } },
                                                         document: { [store] in MainActor.assumeIsolated { store.documentDir } }), forURLScheme: "sumi")
        config.userContentController.add(context.coordinator, name: "sumi")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.webView = webView
        app.editor.webView = webView
        webView.load(URLRequest(url: URL(string: "sumi://app/index.html")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        c.wantID = noteID
        c.wantReadOnly = readOnly
        c.wantMode = mode
        c.wantOptions = options
        c.wantToken = reloadToken
        c.setPluginVersion(pluginVersion)
        c.sync()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: LibraryStore
        let app: AppState
        weak var webView: WKWebView?

        var ready = false
        var wantID: String?
        var wantReadOnly = false
        var wantMode: ViewMode = .edit
        var wantOptions: EditorOptions?
        var wantToken = 0

        private var notePushed = false
        private var pushedID: String?
        private var pushedReadOnly = false
        private var pushedMode: ViewMode?
        private var pushedOptions: EditorOptions?
        private var pushedToken = 0
        private var clipboardCount = NSPasteboard.general.changeCount - 1

        init(store: LibraryStore, app: AppState) {
            self.store = store
            self.app = app
            super.init()
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pullClipboard() }
            }
        }

        private var pluginVersion: Int?
        private var completionJob: Task<Void, Never>?

        /// Plugins are loaded once per page, so a change reloads the editor.
        func setPluginVersion(_ v: Int) {
            defer { pluginVersion = v }
            guard let old = pluginVersion, old != v, let webView else { return }
            ready = false
            notePushed = false
            pushedMode = nil
            pushedOptions = nil
            webView.reload()
        }

        /// Mirrors the system clipboard into Vim's unnamed register.
        func pullClipboard() {
            guard ready, wantOptions?.clipboard == true, wantOptions?.vim == true else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount != clipboardCount else { return }
            clipboardCount = pb.changeCount
            if let text = pb.string(forType: .string) {
                app.editor.call("setClipboard", ["text": text])
            }
        }

        func sync() {
            guard ready else { return }
            let editor = app.editor
            if let wantOptions, pushedOptions != wantOptions {
                editor.call("setOptions", wantOptions.json)
                pushedOptions = wantOptions
                notePushed = false // editor state is rebuilt with the new options
            }
            if !notePushed || pushedID != wantID || pushedReadOnly != wantReadOnly || pushedToken != wantToken {
                if let id = wantID, let note = store.notes[id] {
                    editor.call("setNote", ["id": id, "body": note.body, "readOnly": wantReadOnly])
                } else {
                    editor.call("setNote", NSNull())
                }
                notePushed = true
                pushedID = wantID
                pushedReadOnly = wantReadOnly
                pushedToken = wantToken
            }
            if pushedMode != wantMode {
                // Only steal focus on a mode switch when the web view already has it.
                let hasFocus = webView?.window?.firstResponder === webView
                editor.call("setMode", ["mode": wantMode.rawValue, "focus": hasFocus && pushedMode != nil])
                pushedMode = wantMode
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let msg = message.body as? [String: Any], let type = msg["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                let plugins = Customization.shared.plugins
                if !plugins.isEmpty {
                    app.editor.call("loadPlugins", plugins.map { ["name": $0.name, "code": $0.code] })
                }
                sync()
                pullClipboard()
            case "change":
                if let id = msg["id"] as? String, let body = msg["body"] as? String {
                    store.setBody(id, body)
                }
            case "save":
                store.flush()
            case "vimMode":
                if wantOptions?.imeSwitch == true, (msg["mode"] as? String) == "normal" {
                    InputSource.selectASCII()
                }
                pullClipboard()
            case "notes":
                guard let req = msg["req"] as? Int else { break }
                let q = (msg["q"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let exclude = msg["exclude"] as? String
                let items = store.notes.values
                    .filter { !$0.trashed && $0.id != exclude && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(20)
                    .map { ["id": $0.id, "title": $0.displayTitle, "book": store.book($0.bookId)?.name ?? ""] }
                app.editor.call("notesResult", ["req": req, "items": Array(items)])
            case "createLinked":
                if let title = msg["title"] as? String, !title.isEmpty {
                    let id = store.createNote(title: title, bookId: app.selectedNote?.bookId)
                    app.editor.call("insertText", ["text": AppState.markdownLink(title: title, id: id)])
                }
            case "dropNote":
                if let id = msg["id"] as? String, let note = store.notes[id] {
                    app.editor.call("insertText", ["text": AppState.markdownLink(title: note.displayTitle, id: id)])
                }
            case "openNote":
                if let id = msg["id"] as? String { app.open(noteID: id) }
            case "ime":
                if wantOptions?.imeSwitch == true { InputSource.selectASCII() }
            case "command":
                if let id = msg["id"] as? String { app.run(id) }
            case "clipboard":
                if let text = msg["text"] as? String {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    clipboardCount = pb.changeCount
                }
            case "open":
                if let s = msg["url"] as? String, let url = URL(string: s),
                   ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            case "aiComplete":
                completionJob?.cancel()
                guard wantOptions?.aiComplete == true, let req = msg["req"] as? Int,
                      let before = msg["before"] as? String else { break }
                completionJob = Task { [weak self] in
                    guard let text = await AIRunner.complete(before: before), !Task.isCancelled else { return }
                    self?.app.editor.call("aiCompletion", ["req": req, "text": text])
                }
            case "plugins":
                let custom = Customization.shared
                custom.loadedPlugins = msg["loaded"] as? [String] ?? []
                custom.pluginErrors = (msg["errors"] as? [[String: Any]] ?? []).map {
                    "\($0["name"] as? String ?? "?"): \($0["message"] as? String ?? "")"
                }
                custom.pluginCommands = (msg["commands"] as? [[String: Any]] ?? []).compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return AppCommand(id: id, title: $0["title"] as? String ?? id)
                }
            case "file":
                if store.fileURL != nil {
                    if let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64),
                       let original = msg["name"] as? String,
                       let stored = store.saveBesideFile(data, name: URL(fileURLWithPath: original).lastPathComponent) {
                        let link = stored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stored
                        app.editor.call("insertText", ["text": "[\(stored)](\(link))"])
                    }
                } else if let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64),
                   let original = msg["name"] as? String, let stored = store.saveAttachment(data, name: original) {
                    let label = original.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                    app.editor.call("insertText", ["text": "[\(label)](sumi://attachment/\(stored))"])
                }
            case "fileTooLarge":
                NSSound.beep()
            case "openAttachment":
                if let name = msg["name"] as? String {
                    let file = store.attachmentsDir.appendingPathComponent(URL(fileURLWithPath: name.removingPercentEncoding ?? name).lastPathComponent)
                    guard FileManager.default.fileExists(atPath: file.path) else { NSSound.beep(); break }
                    // Anything that could run is only shown in Finder, never launched.
                    let type = UTType(filenameExtension: file.pathExtension)
                    let runnable = type.map { t in [UTType.executable, .application, .script, .bundle].contains { t.conforms(to: $0) } } ?? true
                    if runnable { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { NSWorkspace.shared.open(file) }
                }
            case "image":
                if store.fileURL != nil {
                    let ext = (msg["ext"] as? String ?? "png").filter { $0.isLetter || $0.isNumber }.lowercased()
                    if let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64),
                       let stored = store.saveBesideFile(data, name: "image." + (ext.isEmpty ? "png" : ext)) {
                        app.editor.call("insertText", ["text": "![image](\(stored))"])
                    }
                } else if let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64),
                   let name = store.saveAttachment(data, ext: msg["ext"] as? String ?? "png") {
                    app.editor.call("insertText", ["text": "![image](sumi://attachment/\(name))"])
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the editor page itself may load; a relative link in a note must not replace it.
            if let url = action.request.url, url.scheme == "sumi", url.host == "app", url.path == "/index.html" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            notePushed = false
            pushedMode = nil
            pushedOptions = nil
            webView.load(URLRequest(url: URL(string: "sumi://app/index.html")!))
        }
    }
}
