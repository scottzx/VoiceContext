import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Scoped local resources and an explicit CSP keep generated HTML a display
/// surface; it has no native tool bridge, microphone, playback or remote fetch.
struct AppArtifactHTMLView: UIViewRepresentable {
    let fileURL: URL
    let onReady: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(fileURL: fileURL, onReady: onReady, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "yima-content")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        FusionAudio.registerWebView(webView)
        var components = URLComponents()
        components.scheme = "yima-content"
        components.host = "artifact"
        components.path = "/" + fileURL.lastPathComponent
        if let url = components.url { webView.load(URLRequest(url: url)) }
        else { onError("网页文件地址无效。") }
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.closed = true
        webView.stopLoading()
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView.setCameraCaptureState(.none, completionHandler: nil)
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate {
        let fileURL: URL
        let root: URL
        let onReady: () -> Void
        let onError: (String) -> Void
        var closed = false
        init(fileURL: URL, onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.fileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            root = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            self.onReady = onReady
            self.onError = onError
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            do {
                guard !closed, let url = urlSchemeTask.request.url, url.scheme == "yima-content", url.host == "artifact" else {
                    throw AppArtifactError.invalid("网页资源地址无效。")
                }
                let file = root.appendingPathComponent(String(url.path.dropFirst())).resolvingSymlinksInPath().standardizedFileURL
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard file.path.hasPrefix(root.path + "/"), values.isRegularFile == true,
                      let size = values.fileSize, size <= 33_554_432 else { throw AppArtifactError.invalid("网页资源越过范围、丢失或过大。") }
                var data = try Data(contentsOf: file)
                if file == fileURL {
                    guard let html = String(data: data, encoding: .utf8) else { throw AppArtifactError.invalid("网页文件不是 UTF-8。") }
                    let policy = "default-src 'none'; img-src yima-content: data:; style-src yima-content: 'unsafe-inline'; script-src yima-content: 'unsafe-inline'; font-src yima-content: data:; connect-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
                    data = Data(("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">" + html).utf8)
                }
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(error) }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if !closed { onReady() } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !closed { onError(error.localizedDescription) } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !closed { onError(error.localizedDescription) } }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            decisionHandler(url.scheme == "yima-content" && url.host == "artifact" || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
