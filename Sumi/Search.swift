import Foundation

/// Search syntax: plain words, "quoted phrases", `book:` `tag:` `status:` `title:` `body:` qualifiers,
/// and a leading `-` to exclude.
struct SearchQuery {
    enum Field { case any, title, body, book, tag, status }

    struct Term {
        var field: Field
        var value: String
        var negated: Bool
    }

    var terms: [Term] = []
    var isEmpty: Bool { terms.isEmpty }

    init(_ text: String) {
        var tokens: [String] = []
        var cur = ""
        var quoted = false
        for ch in text {
            if ch == "\"" {
                quoted.toggle()
            } else if ch.isWhitespace && !quoted {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }

        let fields: [String: Field] = ["title": .title, "body": .body, "book": .book, "tag": .tag, "status": .status]
        for var token in tokens {
            var negated = false
            if token.hasPrefix("-"), token.count > 1 {
                negated = true
                token.removeFirst()
            }
            var field = Field.any
            if let colon = token.firstIndex(of: ":"),
               let f = fields[token[..<colon].lowercased()] {
                field = f
                token = String(token[token.index(after: colon)...])
            }
            if !token.isEmpty { terms.append(Term(field: field, value: token, negated: negated)) }
        }
    }

    /// `bookNames`: names of the note's notebook and its ancestors. `tagNames`: the note's tag names.
    func matches(_ note: Note, bookNames: [String], tagNames: [String]) -> Bool {
        for term in terms {
            let v = term.value
            let hit: Bool
            switch term.field {
            case .any: hit = note.title.localizedCaseInsensitiveContains(v) || note.body.localizedCaseInsensitiveContains(v)
            case .title: hit = note.title.localizedCaseInsensitiveContains(v)
            case .body: hit = note.body.localizedCaseInsensitiveContains(v)
            case .book: hit = bookNames.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
            case .tag: hit = tagNames.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
            case .status: hit = note.status.rawValue.caseInsensitiveCompare(v) == .orderedSame
            }
            if hit == term.negated { return false }
        }
        return true
    }
}
