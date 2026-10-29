import AppKit
import Darwin

/// Offers to move Loomo into Applications when it's run from the disk image or Downloads.
///
/// From there macOS runs the app from a hidden, read-only copy at a random path ("App Translocation"), so the
/// path Claude Desktop is given for Loomo's MCP tool changes every launch, and the copy can't be updated in place.
/// From /Applications none of that happens.
enum AppLocation {
    private static let dontAskKey = "appLocation.dontAsk"

    /// Where the app really is, seeing through App Translocation.
    static var originalBundleURL: URL {
        let current = Bundle.main.bundleURL
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return current }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(current as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(current as CFURL, nil)?.takeRetainedValue() else { return current }
        return original as URL
    }

    /// True when Loomo is somewhere it should be moved from: a disk image, Downloads, or a translocated copy.
    static var shouldOffer: Bool {
        let path = Bundle.main.bundleURL.path
        // Builds from source (Xcode, scripts/build-app.sh) run from build folders: leave those alone.
        if path.contains("/DerivedData") || path.contains("/build/") || path.contains(".noindex/") { return false }
        let original = originalBundleURL.path
        let inApplications = original.hasPrefix("/Applications/")
            || original.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
        return !inApplications
    }

    /// Asks once per launch (until "Don't Ask Again"). Call when the app has finished launching.
    @MainActor
    static func offerMove() {
        guard shouldOffer, !UserDefaults.standard.bool(forKey: dontAskKey) else { return }
        let alert = NSAlert()
        alert.messageText = "Move Loomo to the Applications folder?"
        alert.informativeText = "Loomo works best from Applications: Claude and Finder can always find it there, and it isn't affected when you eject the disk image or clean up Downloads."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
        guard answer == .alertFirstButtonReturn else { return }
        do {
            try moveAndRelaunch()
        } catch {
            let failed = NSAlert(error: error)
            failed.messageText = "Loomo couldn't move itself"
            failed.informativeText = "Drag Loomo into the Applications folder in Finder, then open it from there. (\(error.localizedDescription))"
            failed.runModal()
        }
    }

    @MainActor
    private static func moveAndRelaunch() throws {
        let source = originalBundleURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // An older copy: put it in the Trash rather than deleting it.
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // From Downloads, move rather than copy; a disk image is read-only and stays as it is.
        if !source.path.hasPrefix("/Volumes/") { try? fm.trashItem(at: source, resultingItemURL: nil) }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
