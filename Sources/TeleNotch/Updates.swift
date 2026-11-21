import AppKit
import Sparkle

/// Auto-updates via Sparkle. Checks daily and installs in the background once a feed URL is set
/// (feed-url.txt at build time → SUFeedURL in Info.plist). Without one, updates are simply off.
@MainActor
final class Updates {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    var feedURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var isConfigured: Bool { feedURL != nil }
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        if CommandLine.arguments.contains("--check-updates") { controller?.updater.checkForUpdatesInBackground() }
    }

    func checkNow() {
        guard let controller else {
            let a = NSAlert()
            a.messageText = "Updates aren't set up yet"
            a.informativeText = "This copy of TeleNotch was built without an update feed. Add your appcast URL to feed-url.txt and rebuild."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
