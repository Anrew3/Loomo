import CrimpCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Part photos from Octopart, cached in memory and on disk (~/Library/Caches/Loomo/PartImages)
/// so drawings and PDFs can show them synchronously once they have been fetched.
public final class PartImageCache: @unchecked Sendable {
    /// The cache drawings use by default. Quick Look extensions point it at the app's cache
    /// in the user's real Library folder (their own sandbox container has none).
    public static var shared = PartImageCache()

    private let memory = NSCache<NSURL, CGImage>()
    private let directory: URL
    private let lock = NSLock()
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    /// Fetches an image the plain download couldn't get, e.g. Mouser's, which answers non-browser clients
    /// with a bot-check page. The app sets this to a loader that uses a hidden web view.
    public var browserFetch: (@Sendable (URL) async -> Data?)?

    /// - Parameter directory: where photos are kept on disk; defaults to ~/Library/Caches/Loomo/PartImages
    ///   (the App Group container in the App Store build, so Quick Look can read it).
    public init(directory: URL? = nil) {
        self.directory = directory ?? SharedStorage.cacheDirectory.appendingPathComponent("PartImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// The image if it is already in memory or on disk; never touches the network.
    public func cached(_ url: URL) -> CGImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        // Custom photos are local files: read them directly.
        guard let data = try? Data(contentsOf: url.isFileURL ? url : file(for: url)), let img = Self.decode(data) else { return nil }
        memory.setObject(img, forKey: url as NSURL)
        return img
    }

    /// Fetches (once) and caches the image.
    public func image(for url: URL) async -> CGImage? {
        if let img = cached(url) { return img }
        let task: Task<CGImage?, Never> = lock.withLock {
            if let running = inFlight[url] { return running }
            let task = Task<CGImage?, Never> { [weak self] in
            guard let self else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Loomo", forHTTPHeaderField: "User-Agent")
            var data: Data?
            if let (d, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, Self.decode(d) != nil {
                data = d
            } else if let fetch = self.browserFetch {
                // A page came back instead of a picture (a bot check): try it the way a browser would.
                data = await fetch(url)
            }
            guard let data, let img = Self.decode(data) else { return nil }
            try? data.write(to: self.file(for: url), options: .atomic)
            self.memory.setObject(img, forKey: url as NSURL)
            return img
            }
            inFlight[url] = task
            return task
        }
        let result = await task.value
        lock.withLock { inFlight[url] = nil }
        return result
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Downscale large photos; drawings only need thumbnails.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 512,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
