import SwiftUI
import WebKit
import UIKit

@main
struct MyMicApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainer()
                .ignoresSafeArea()
                .background(Color(red: 0.043, green: 0.047, blue: 0.063))
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}

// La interfaz (HTML/CSS/JS) es la misma de la app web; vive en la carpeta "web".
struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mymic")
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        let bg = UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)
        webView.isOpaque = false
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Puente página <-> Swift.
/// Página -> Swift: window.webkit.messageHandlers.mymic.postMessage({t: ...})
/// Swift -> página: window.onNative({t: ...})
final class Bridge: NSObject, WKScriptMessageHandler, WKUIDelegate {
    weak var webView: WKWebView?
    private let core = Core.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init() {
        super.init()
        core.toPage = { [weak self] obj in self?.push(obj) }
    }

    private func push(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.onNative && window.onNative(\(json))", completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let t = m["t"] as? String else { return }
        switch t {
        case "start":
            core.start(mode: m["mode"] as? String ?? "walkie", muted: (m["muted"] as? Bool) ?? false)
        case "state":
            let pressed = (m["pressed"] as? Bool) ?? false
            if pressed { haptic.impactOccurred() }
            core.setState(mode: m["mode"] as? String ?? "walkie",
                          muted: (m["muted"] as? Bool) ?? false,
                          pressed: pressed)
        case "ws":
            if let d = m["d"] as? String { core.sendText(d) }
        case "wsb":
            if let b = m["b64"] as? String, let data = Data(base64Encoded: b) { core.sendBinary(data) }
        case "cam":
            core.camera(on: (m["on"] as? Bool) ?? false,
                        facing: m["facing"] as? String ?? "user",
                        quality: m["quality"] as? String ?? "medium")
        case "camq":
            core.cameraQuality(m["quality"] as? String ?? "medium")
        case "dim":
            core.dim((m["on"] as? Bool) ?? false)
        case "manual":
            core.manual(m["host"] as? String ?? "")
        default:
            break
        }
    }

    // alert() y confirm() de la página
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
            completionHandler(); return
        }
        while let p = top.presentedViewController { top = p }
        top.present(alert, animated: true)
    }
}
