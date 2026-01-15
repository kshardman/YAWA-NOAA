import SwiftUI
import WebKit

struct RadarWebView: UIViewRepresentable {
    /// The URL you want to show (e.g., WeatherLoop centered on lat/lon)
    let url: URL

    /// Bump this to force a reload (e.g., reloadToken += 1)
    let reloadToken: Int

    @Binding var isLoading: Bool
    @Binding var estimatedProgress: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Radar pages can be scroll/zoom heavy; tweak as you like
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.alpha = 0

        // Observe progress
        webView.addObserver(
            context.coordinator,
            forKeyPath: #keyPath(WKWebView.estimatedProgress),
            options: [.new],
            context: nil
        )
        context.coordinator.isObservingProgress = true

        // Load once on creation
        context.coordinator.load(url: url, in: webView)
        context.coordinator.lastReloadToken = reloadToken

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // IMPORTANT:
        // Do NOT compare `webView.url` vs `url` — redirects change webView.url and cause loops.
        // Instead, track what *we asked it to load*.
        if context.coordinator.lastRequestedURL != url {
            context.coordinator.load(url: url, in: webView)
        } else if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        if coordinator.isObservingProgress {
            webView.removeObserver(coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress))
            coordinator.isObservingProgress = false
        }
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: RadarWebView

        // Tracks what the app requested (not what the web view may redirect to)
        fileprivate var lastRequestedURL: URL?
        fileprivate var lastReloadToken: Int = 0
        fileprivate var isObservingProgress = false

        init(_ parent: RadarWebView) {
            self.parent = parent
        }

        fileprivate func load(url: URL, in webView: WKWebView) {
            lastRequestedURL = url

            let request = URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            )
            webView.load(request)
        }

        // MARK: - KVO for progress

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey : Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == #keyPath(WKWebView.estimatedProgress),
                  let webView = object as? WKWebView else { return }

            parent.estimatedProgress = webView.estimatedProgress
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            webView.alpha = 0
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            UIView.animate(withDuration: 0.20) {
                webView.alpha = 1
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            webView.alpha = 1
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            webView.alpha = 1
        }
    }
}
