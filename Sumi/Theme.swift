import SwiftUI

/// Colors of the selected theme for the native parts of the window (sidebar, note list, headers).
/// The same palettes drive the editor and the preview (see web/src/themes.json).
struct Palette: Equatable {
    let background: Color
    let sidebar: Color
    let list: Color
    let foreground: Color
    let accent: Color
}

enum Themes {
    private static let table: [String: [String: [String: String]]] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("editor/themes.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data)
        else { return [:] }
        return json
    }()

    /// nil for the default theme, which keeps the standard macOS look.
    static func palette(_ id: String, dark: Bool) -> Palette? {
        guard id != "default", let colors = table[id]?[dark ? "dark" : "light"],
              let bg = rgb(colors["--bg"]), let fg = rgb(colors["--fg"]), let accent = rgb(colors["--accent"])
        else { return nil }
        return Palette(background: color(bg), sidebar: color(mix(bg, fg, 0.07)), list: color(mix(bg, fg, 0.03)),
                       foreground: color(fg), accent: color(accent))
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgb(_ hex: String?) -> RGB? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    private static func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette? = nil
}

extension EnvironmentValues {
    var palette: Palette? {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Paints one pane of the window in the theme's colors.
struct ThemedPane: ViewModifier {
    enum Part { case sidebar, list, editor }
    let part: Part
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let fill: Color? = palette.map { part == .sidebar ? $0.sidebar : part == .list ? $0.list : $0.background }
        // No branching on the palette: switching themes must not rebuild the pane.
        content
            .scrollContentBackground(palette == nil ? .automatic : .hidden)
            .background { (fill ?? Color.clear).ignoresSafeArea() }  // also under the toolbar
            .foregroundStyle(palette?.foreground ?? Color.primary)
    }
}

/// Reads the theme setting and hands the palette to everything inside one window.
struct ThemedWindow: ViewModifier {
    @AppStorage("editorTheme") private var theme = "default"
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = Themes.palette(theme, dark: colorScheme == .dark)
        let themed = content
            .environment(\.palette, palette)
            .tint(palette?.accent)
            .toolbarBackground(palette == nil ? .automatic : .hidden, for: .windowToolbar)
        if #available(macOS 15.0, *) {
            themed.containerBackground(palette?.background ?? Color(nsColor: .windowBackgroundColor), for: .window)
        } else {
            themed
        }
    }
}
