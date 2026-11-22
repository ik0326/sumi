import SwiftUI

enum NoteStatus: String, Codable, CaseIterable, Identifiable {
    case none, active, onHold, completed, dropped

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: L("None")
        case .active: L("Active")
        case .onHold: L("On Hold")
        case .completed: L("Completed")
        case .dropped: L("Dropped")
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .active: "play.circle.fill"
        case .onHold: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .dropped: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .none: .secondary
        case .active: .blue
        case .onHold: .orange
        case .completed: .green
        case .dropped: .gray
        }
    }

    var isFinished: Bool { self == .completed || self == .dropped }
}

struct Note: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var bookId: String?
    var status: NoteStatus = .none
    var tagIds: [String] = []
    var pinned: Bool = false
    var trashed: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var displayTitle: String { title.isEmpty ? L("Untitled") : title }
}

struct Notebook: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var parentId: String?
}

struct Tag: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var colorName: String = "default"

    static let palette: [(name: String, color: Color)] = [
        ("default", Color(nsColor: .systemGray)), ("red", .red), ("orange", .orange), ("yellow", .yellow),
        ("olive", Color(red: 0.62, green: 0.70, blue: 0.10)), ("green", .green), ("teal", .teal),
        ("blue", .blue), ("violet", Color(red: 0.42, green: 0.27, blue: 0.86)), ("purple", .purple),
        ("pink", .pink), ("brown", .brown), ("grey", Color(white: 0.45)), ("black", Color(white: 0.16)),
    ]

    var color: Color { Tag.palette.first { $0.name == colorName }?.color ?? Tag.palette[0].color }
}

enum SidebarItem: Hashable {
    case all
    case book(String)
    case status(NoteStatus)
    case tag(String)
    case trash
}

enum SortKey: String, CaseIterable, Identifiable {
    case updated, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .updated: L("Date Updated")
        case .created: L("Date Created")
        case .title: L("Title")
        }
    }
}

enum ViewMode: String, CaseIterable {
    case edit, split, preview
}

struct EditorOptions: Equatable {
    var vim: Bool
    var lineNumbers: Bool
    var lineWrap: Bool
    var fontSize: Double
    var vimrc: String
    var imeSwitch: Bool
    var clipboard: Bool
    var toolbar: Bool
    var readable: Bool
    var theme = "default"
    var customCSS = ""
    var aiComplete = false
    var aiAvailable = false

    var json: [String: Any] {
        ["vim": vim, "lineNumbers": lineNumbers, "lineWrap": lineWrap, "fontSize": fontSize, "vimrc": vimrc,
         "clipboard": clipboard, "toolbar": toolbar, "readable": readable, "theme": theme, "customCSS": customCSS, "aiComplete": aiComplete, "ai": aiAvailable, "lang": AppLanguage.isJapanese ? "ja" : "en"]
    }
}
