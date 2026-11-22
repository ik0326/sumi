import NaturalLanguage
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAction: String, CaseIterable, Identifiable {
    case summarize, keyPoints, improve, proofread, shorter, continueWriting, translateEN, translateJA, title, tags, ask

    var id: String { rawValue }
    var commandID: String { "ai:" + rawValue }

    var title: String {
        switch self {
        case .summarize: L("Summarize")
        case .keyPoints: L("Key Points")
        case .improve: L("Improve Writing")
        case .proofread: L("Fix Spelling and Grammar")
        case .shorter: L("Make Shorter")
        case .continueWriting: L("Continue Writing")
        case .translateEN: L("Translate to English")
        case .translateJA: L("Translate to Japanese")
        case .title: L("Suggest a Title")
        case .tags: L("Suggest Tags")
        case .ask: L("Ask About This Note…")
        }
    }

    var symbol: String {
        switch self {
        case .summarize: "text.justify.left"
        case .keyPoints: "list.bullet"
        case .improve: "wand.and.stars"
        case .proofread: "checkmark.circle"
        case .shorter: "arrow.down.right.and.arrow.up.left"
        case .continueWriting: "text.append"
        case .translateEN, .translateJA: "character.bubble"
        case .title: "textformat"
        case .tags: "tag"
        case .ask: "questionmark.bubble"
        }
    }

    var task: String {
        switch self {
        case .summarize: "Summarize the following text in a few sentences."
        case .keyPoints: "List the key points of the following text as a Markdown bullet list."
        case .improve: "Rewrite the following text so it is clearer and more natural. Keep the meaning, the language and the Markdown formatting."
        case .proofread: "Fix the typos and grammar mistakes in the following text. Change nothing else and keep the Markdown formatting."
        case .shorter: "Make the following text more concise. Keep the language and the Markdown formatting."
        case .continueWriting: "Continue writing from where the following text ends, in the same language and style. Output only the continuation."
        case .translateEN: "Translate the following text into English. Keep the Markdown formatting."
        case .translateJA: "Translate the following text into Japanese. Keep the Markdown formatting."
        case .title: "Suggest one short title for the following note. Output the title only, without quotes."
        case .tags: "Suggest up to five short tags for the following note. Output them on one line, separated by commas, nothing else."
        case .ask: "Answer the question using the following note."
        }
    }

    /// The result rewrites the source text (rather than being added next to it).
    var rewrites: Bool { [.improve, .proofread, .shorter, .translateEN, .translateJA].contains(self) }
}

struct AIRequest: Identifiable {
    let id = UUID()
    var action: AIAction
    var text: String
    var fromSelection: Bool
    var truncated: Bool
    var noteID: String
    var readOnly: Bool
}

@MainActor @Observable
final class AIRunner {
    var output = ""
    var running = false
    var error: String?
    @ObservationIgnored private var job: Task<Void, Never>?

    /// The on-device model has a small context window.
    static let maxCharacters = 3000

    /// nil when Apple Intelligence can be used, otherwise why not.
    static var unavailableReason: String? {
        // Asked on every editor refresh, so the answer is kept for a while.
        if let c = cachedReason, Date().timeIntervalSince(c.at) < 30 { return c.value }
        let value = checkAvailability()
        cachedReason = (value, Date())
        return value
    }

    private static var cachedReason: (value: String?, at: Date)?

    private static func checkAvailability() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return L("This Mac does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return L("Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri.")
            case .unavailable(.modelNotReady): return L("The Apple Intelligence model is still downloading. Try again later.")
            case .unavailable: return L("Apple Intelligence is not available right now.")
            }
        }
        #endif
        return L("Apple Intelligence needs macOS 26 or later.")
    }

    /// A short continuation of `before` for inline (ghost text) completion; nil when there is nothing useful.
    static func complete(before: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                You complete unfinished text in a Markdown note. The user sends a note that stops mid-sentence. \
                Reply with the last line of the note, completed: copy that last line exactly as written, then add the words that finish it. \
                One line only. No explanations. Same language as the note.
                """)
            var options = GenerationOptions()
            options.temperature = 0.2
            options.maximumResponseTokens = 60
            guard let response = try? await session.respond(to: before, options: options) else { return nil }
            return cleanCompletion(before: before, response: response.content)
        }
        #endif
        return nil
    }

    /// Turns a raw model reply into the text to suggest after `before` (nil when it is not usable).
    /// The model sometimes repeats the note before continuing, so that echo is removed first.
    static func cleanCompletion(before: String, response: String) -> String? {
        var head = before
        while head.last?.isWhitespace == true { head.removeLast() }
        var text = response
        var echoed = false
        let limit = min(head.count, text.count)
        if limit >= 4 {
            for n in stride(from: limit, through: 4, by: -1) where text.hasPrefix(String(head.suffix(n))) {
                text.removeFirst(n)
                echoed = true
                break
            }
        }
        let newLine = text.first?.isNewline == true && before.last?.isNewline != true
        guard var line = text.split(whereSeparator: \.isNewline).map(String.init).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        while line.last?.isWhitespace == true { line.removeLast() }

        // A reply that only restates what is already written is useless.
        func bare(_ s: String) -> String { s.filter { !$0.isWhitespace && !"*_#-`>".contains($0) }.lowercased() }
        let probe = bare(line)
        if probe.count >= 6, bare(before).contains(String(probe.prefix(12))) { return nil }

        let marker = line.range(of: #"^\s*([-*+] |\d+[.)] |#{1,6} |> )"#, options: .regularExpression) != nil
        if newLine, marker {
            line = "\n" + line // the next list item or heading goes on its own line
        } else if before.last?.isWhitespace == true || before.isEmpty {
            line = String(line.drop { $0.isWhitespace })
        } else if !echoed, let a = before.last, let b = line.first, a.isASCII, b.isASCII,
                  a.isLetter || a.isNumber || ",.;:".contains(a), b.isLetter || b.isNumber {
            line = " " + line
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.count > 200 ? nil : line
    }

    func cancel() {
        job?.cancel()
        job = nil
        running = false
    }

    func run(_ request: AIRequest, question: String, existingTags: [String]) {
        cancel()
        output = ""
        error = nil
        if let reason = Self.unavailableReason {
            error = reason
            return
        }
        var task = request.action.task
        if request.action == .ask { task += "\nQuestion: \(question)" }
        if request.action == .tags, !existingTags.isEmpty {
            task += "\nPrefer these existing tags when they fit: " + existingTags.prefix(40).joined(separator: ", ")
        }
        // The model tends to answer in English, so the language of the text is named explicitly.
        if ![.translateEN, .translateJA].contains(request.action) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(request.text.prefix(1000)))
            if let lang = recognizer.dominantLanguage,
               let name = Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue) {
                task += " Write your answer in \(name)."
            }
        }
        let prompt = task + "\n\n---\n" + request.text
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            running = true
            job = Task { [weak self] in
                do {
                    let instructions = "You are a writing assistant inside a Markdown note-taking app. Reply with only the requested result: no preamble, no explanations, no surrounding code fence. Unless asked to translate, answer in the same language as the text."
                    let session = LanguageModelSession(instructions: instructions)
                    for try await partial in session.streamResponse(to: prompt) {
                        if Task.isCancelled { return }
                        self?.output = partial.content
                    }
                } catch {
                    if !Task.isCancelled { self?.error = error.localizedDescription }
                }
                if !Task.isCancelled { self?.running = false }
            }
        }
        #endif
    }
}

struct AIPanelView: View {
    let request: AIRequest

    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var runner = AIRunner()
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    private var result: String { runner.output.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canApply: Bool { !result.isEmpty && !runner.running && !request.readOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                Text(request.action.title.replacingOccurrences(of: "…", with: "")).font(.headline)
                Spacer()
                Text(L(request.fromSelection ? "Selection" : "Whole note") + (request.truncated ? L(" (first part only)") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if runner.running { ProgressView().controlSize(.small) }
            }

            if request.action == .ask {
                HStack {
                    TextField("Ask a question about this note", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .focused($questionFocused)
                        .onSubmit { start() }
                    Button("Ask") { start() }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ScrollView {
                Group {
                    if let error = runner.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if runner.output.isEmpty {
                        Text(runner.running ? L("Thinking…") : "").foregroundStyle(.secondary)
                    } else {
                        Text(runner.output).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("On-device · Apple Intelligence").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { start() }.disabled(runner.running || (request.action == .ask && question.isEmpty))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }
                .disabled(result.isEmpty)
                applyButtons
            }
        }
        .padding(16)
        .frame(width: 620, height: 460)
        .onAppear {
            if request.action == .ask { questionFocused = true } else { start() }
        }
        .onDisappear { runner.cancel() }
    }

    @ViewBuilder
    private var applyButtons: some View {
        switch request.action {
        case .title:
            Button("Set as Title") {
                let title = result.split(whereSeparator: \.isNewline).first.map(String.init) ?? result
                store.update(request.noteID) { $0.title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」# ")) }
                close()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(canApply == false)
        case .tags:
            Button("Add Tags") {
                for name in result.split(whereSeparator: { ",、\n".contains($0) }) {
                    let tag = name.trimmingCharacters(in: CharacterSet(charactersIn: " #-*・"))
                    if !tag.isEmpty, tag.count <= 30 { store.addTag(named: tag, to: request.noteID) }
                }
                close()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(canApply == false)
        default:
            if request.action.rewrites {
                Button("Insert Below") { insertBelow() }.disabled(!canApply)
                Button(L(request.fromSelection ? "Replace Selection" : "Replace Note")) {
                    if request.fromSelection {
                        app.editor.call("insertText", ["text": result])
                    } else {
                        store.update(request.noteID) { $0.body = result }
                        app.editorReloadToken += 1
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || (!request.fromSelection && request.truncated))
            } else {
                Button("Insert Below") { insertBelow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
    }

    private func start() {
        runner.run(request, question: question, existingTags: store.tags.map(\.name))
    }

    private func insertBelow() {
        app.editor.call("insertAfter", ["text": result])
        close()
    }

    private func close() {
        runner.cancel()
        dismiss()
        DispatchQueue.main.async { app.editor.focus() }
    }
}
