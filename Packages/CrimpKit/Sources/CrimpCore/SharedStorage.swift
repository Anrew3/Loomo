import Foundation

/// Where Loomo keeps data that the app, its Quick Look extensions and the `crimp` tool all read.
///
/// Two release channels share this code:
///   * Direct download (Developer ID, not sandboxed): `~/Library/Application Support/Loomo` and
///     `~/Library/Caches/Loomo`, as always.
///   * Mac App Store / TestFlight (sandboxed): every process has its own container, so shared data lives in an
///     App Group container instead. The group id comes from the `LoomoAppGroup` Info.plist key, which the
///     App Store build sets (see scripts/release.sh); it is empty in direct builds.
public enum SharedStorage {
    /// True when this process runs in the App Sandbox.
    public static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// The App Group shared by the app, its extensions and `crimp`, if this build has one.
    public static let appGroup: String? = {
        if let g = Bundle.main.object(forInfoDictionaryKey: "LoomoAppGroup") as? String, !g.isEmpty { return g }
        // `crimp` has no Info.plist of its own: read the app bundle it ships in.
        if let info = enclosingAppInfo, let g = info["LoomoAppGroup"] as? String, !g.isEmpty { return g }
        return nil
    }()

    /// The Info.plist of the .app this executable is inside (for `crimp`, which lives in Contents/MacOS).
    static var enclosingAppInfo: [String: Any]? {
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            }
        }
        return nil
    }

    private static var groupContainer: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// Application data: the parts library, custom photos, the live-editing socket.
    public static var dataDirectory: URL {
        if let g = groupContainer { return g.appendingPathComponent("Loomo", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loomo", isDirectory: true)
    }

    /// Re-downloadable data: part photos.
    public static var cacheDirectory: URL {
        if let g = groupContainer { return g.appendingPathComponent("Library/Caches/Loomo", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loomo", isDirectory: true)
    }

    /// The socket AI clients use to edit open harnesses (see LiveBridge in the app).
    /// A Unix socket path must fit in 104 bytes, so a sandboxed app without a group keeps it at the top of its
    /// container rather than deep in Application Support.
    public static var liveSocket: URL {
        if groupContainer != nil { return dataDirectory.appendingPathComponent("live.sock") }
        if isSandboxed { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("live.sock") }
        return dataDirectory.appendingPathComponent("live.sock")
    }

    /// Where `crimp` looks for a running Loomo, most specific first. `LOOMO_LIVE_SOCKET` overrides (for tests).
    public static var liveSocketCandidates: [URL] {
        if let forced = ProcessInfo.processInfo.environment["LOOMO_LIVE_SOCKET"] { return [URL(fileURLWithPath: forced)] }
        var list: [URL] = []
        if groupContainer != nil { list.append(liveSocket) }
        let home = realHome
        list.append(home.appendingPathComponent("Library/Application Support/Loomo/live.sock"))  // direct-download app
        list.append(home.appendingPathComponent("Library/Containers/com.loomo.Loomo/Data/live.sock"))  // sandboxed, no group
        return list
    }

    /// The user's real home folder, even inside a sandbox (where `homeDirectoryForCurrentUser` is the container).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
