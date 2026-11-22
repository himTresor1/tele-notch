import AppKit

/// If TeleNotch was opened from the disk image, Downloads, or anywhere outside Applications,
/// offer to move it into /Applications and reopen from there. Auto-updates need this too:
/// they can't replace an app on a read-only disk image or in macOS's temporary "translocated" copy.
@MainActor
enum MoveToApplications {
    private static let declinedKey = "moveToApplicationsDeclined"

    static func offerIfNeeded() {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = here.path
        guard !isInApplications(path), !isDevBuild(path),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        // When macOS runs a downloaded app from a temporary random location, find where it really is.
        let source = originalURL(of: here) ?? here
        let fromDiskImage = source.path.hasPrefix("/Volumes/")

        let a = NSAlert()
        a.messageText = "Move TeleNotch to your Applications folder?"
        a.informativeText = fromDiskImage
            ? "You opened TeleNotch from the disk image. Moving it to Applications lets it keep working after you eject the disk image, and lets it update itself."
            : "TeleNotch works best from your Applications folder, and needs to be there to update itself."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let choice = a.runModal()
        if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard choice == .alertFirstButtonReturn else { return }

        do {
            try move(from: source, deleteSource: !fromDiskImage)
        } catch {
            let e = NSAlert()
            e.messageText = "Couldn't move TeleNotch"
            e.informativeText = "\(error.localizedDescription)\n\nYou can drag TeleNotch into Applications in Finder instead."
            e.runModal()
        }
    }

    private static func isInApplications(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Builds run from the project's build folder while developing; leave those alone.
    private static func isDevBuild(_ path: String) -> Bool {
        path.contains("/build/TeleNotch.app") || path.contains("/.build/")
    }

    private static func move(from source: URL, deleteSource: Bool) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/TeleNotch.app")
        if fm.fileExists(atPath: dest.path) {
            // An older copy: put it in the Trash rather than deleting it outright.
            try fm.trashItem(at: dest, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: dest)
        if deleteSource { try? fm.trashItem(at: source, resultingItemURL: nil) }

        // Reopen from Applications, then quit this copy.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            DispatchQueue.main.async {
                if source.path.hasPrefix("/Volumes/") { ejectDiskImage(containing: source) }
                NSApp.terminate(nil)
            }
        }
    }

    private static func ejectDiskImage(containing url: URL) {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return }
        let volume = URL(fileURLWithPath: "/Volumes/\(parts[1])")
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }

    // MARK: App Translocation
    // A quarantined app opened where it was downloaded runs from a random read-only path
    // (/private/var/folders/.../AppTranslocation/...). Security.framework can tell us the original path.

    private typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static func originalURL(of url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(lib) }
        guard let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
        let original = unsafeBitCast(origSym, to: OriginalPathFn.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let out = original(url as CFURL, nil) else { return nil }
        return out.takeRetainedValue() as URL
    }
}
