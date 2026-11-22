import AppKit
import Observation
import Sparkle
import SwiftUI

/// In-app updates through Sparkle. Updates are listed in an appcast published with each GitHub release
/// and must carry a signature made with the project's private key (see SUPublicEDKey in Info.plist).
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// The version of an update found by a background check, until the user has looked at it.
    private(set) var availableVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts the scheduled checks (at launch, then once a day while enabled).
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Shows the update, or tells the user that the app is up to date.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate — a quiet banner instead of a window that interrupts.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle may show its window; later finds only raise the banner.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in if !handleShowingUpdate { self.availableVersion = version } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}

/// "A new version is available" at the bottom of the sidebar; a click opens the update.
struct UpdateBanner: View {
    var body: some View {
        if let version = Updater.shared.availableVersion {
            Button {
                Updater.shared.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("A new version is available").fontWeight(.medium)
                        Text(String(format: L("Version %@ — click to update"), version)).font(.caption2).opacity(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}
