import AppKit
import WebKit

/// Loads images that only real browsers are given. Mouser's image server answers plain downloads with a
/// bot-check page; a web view runs the check, then the picture is read from the page it lands on.
@MainActor
final class WebImageLoader: NSObject, WKNavigationDelegate {
    static let shared = WebImageLoader()

    private lazy var webView: WKWebView = {
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: WKWebViewConfiguration())
        v.navigationDelegate = self
        return v
    }()
    private var finished: CheckedContinuation<Void, Never>?
    /// One image at a time; the web view is shared.
    private var queue: Task<Void, Never>?

    /// Hosts known to need this; anything else gets a plain download only.
    static func needsBrowser(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "mouser.com" || host.hasSuffix(".mouser.com") || host.contains(".mouser.")
    }

    func data(for url: URL) async -> Data? {
        guard Self.needsBrowser(url) else { return nil }
        let previous = queue
        let task = Task { () -> Data? in
            await previous?.value
            return await self.load(url)
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func load(_ url: URL) async -> Data? {
        await withCheckedContinuation { c in
            finished = c
            webView.load(URLRequest(url: url, timeoutInterval: 20))
        }
        // The bot check may reload the page a few times before the image itself is shown.
        for _ in 0..<24 {
            if let type = try? await webView.evaluateJavaScript("document.contentType") as? String, type.hasPrefix("image/") { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let script = """
        if (!document.contentType.startsWith("image/")) return null;
        const r = await fetch(location.href);
        const bytes = new Uint8Array(await r.arrayBuffer());
        let s = "";
        for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(s);
        """
        guard let base64 = try? await webView.callAsyncJavaScript(script, contentWorld: .page) as? String else { return nil }
        return Data(base64Encoded: base64)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }

    private func resume() {
        finished?.resume()
        finished = nil
    }
}
