import AppKit
import CryptoKit
import Observation
import SwiftUI

/// Checks the project's GitHub releases for a newer version and installs it in place.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repository = "ik0326/sumi"

    struct Release: Equatable {
        let version: String
        let zip: URL
        /// Hex SHA-256 published by GitHub for the download, when available.
        let sha256: String?
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, downloading, installing
        case failed(String)
    }

    /// A release newer than the running app, once one has been found.
    private(set) var available: Release?
    private(set) var state: State = .idle
    @ObservationIgnored private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var busy: Bool { state == .checking || state == .downloading || state == .installing }

    /// Checks at launch and once a day while the automatic check is enabled.
    func start() {
        guard timer == nil else { return }
        let tick = { [weak self] in
            guard UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true else { return }
            Task { await self?.check() }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    /// Looks for a newer release. Returns it, or nil when the app is up to date or the check failed
    /// (`state` is `.failed` in that case).
    @discardableResult
    func check() async -> Release? {
        guard !busy else { return available }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Sumi", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { throw URLError(.badServerResponse) }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let asset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            state = .idle
            guard Self.isNewer(version, than: Self.currentVersion),
                  let link = asset?["browser_download_url"] as? String, let zip = URL(string: link),
                  zip.scheme == "https", zip.host == "github.com"
            else {
                available = nil
                return nil
            }
            let digest = (asset?["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            let page = (json["html_url"] as? String).flatMap(URL.init) ?? URL(string: "https://github.com/\(Self.repository)/releases")!
            let release = Release(version: version, zip: zip, sha256: digest, page: page)
            available = release
            return release
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Downloads the release, replaces this app with it and relaunches.
    func install() async {
        guard let release = available, !busy else { return }
        let destination = Bundle.main.bundleURL
        // An app that macOS runs from a read-only copy, or one in a folder we cannot write to, cannot replace itself.
        guard !destination.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        else {
            state = .failed(L("Sumi cannot update itself from this location. Move it to the Applications folder, or download the new version."))
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading
        do {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("Sumi-update-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            var request = URLRequest(url: release.zip)
            request.setValue("Sumi", forHTTPHeaderField: "User-Agent")
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let zip = work.appendingPathComponent("Sumi.zip")
            try fm.moveItem(at: downloaded, to: zip)
            if let expected = release.sha256 {
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard actual == expected.lowercased() else { throw UpdateError.message(L("The download did not match the published checksum.")) }
            }
            state = .installing
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let app = unpacked.appendingPathComponent("Sumi.app")
            // Only accept the same app, in the announced version, with an intact signature.
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version
            else { throw UpdateError.message(L("The download is not a valid copy of Sumi.")) }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            // A helper waits for this process to quit, swaps the app and opens the new one.
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            if mv "$3" "$3.old"; then
              if mv "$2" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; fi
            fi
            open "$3"
            rm -rf "$4"
            """
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, destination.path, work.path]
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
        }
    }

    private enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let t) = self { return t } else { return "" } }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.message(L("The update could not be installed.")) }
        return p.terminationStatus
    }

    /// The menu command: always tells the user the outcome.
    func checkFromMenu() async {
        let release = await check()
        let alert = NSAlert()
        if let release {
            alert.messageText = L("A new version is available")
            alert.informativeText = String(format: L("Sumi %@ is available. You have %@."), release.version, Self.currentVersion)
            alert.addButton(withTitle: L("Update Now"))
            alert.addButton(withTitle: L("Later"))
            if alert.runModal() == .alertFirstButtonReturn { await install() }
        } else if case .failed(let reason) = state {
            alert.messageText = L("Could not check for updates")
            alert.informativeText = reason
            alert.runModal()
        } else {
            alert.messageText = L("Sumi is up to date")
            alert.informativeText = String(format: L("Version %@ is the latest version."), Self.currentVersion)
            alert.runModal()
        }
    }
}

/// "A new version is available" — one click downloads, installs and relaunches.
struct UpdateBanner: View {
    private var updater: Updater { Updater.shared }

    var body: some View {
        if let release = updater.available {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    Task { await updater.install() }
                } label: {
                    HStack(spacing: 6) {
                        if updater.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).fontWeight(.medium)
                            Text(String(format: L("Version %@ — click to update"), release.version))
                                .font(.caption2).opacity(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(updater.busy)
                if case .failed(let reason) = updater.state {
                    Text(reason).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }

    private var title: String {
        switch updater.state {
        case .downloading: L("Downloading…")
        case .installing: L("Installing…")
        default: L("A new version is available")
        }
    }
}
