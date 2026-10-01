import AppKit
import WebKit

/// Discord's own login page in a window. The user types their password into
/// Discord, never into aside; the page's later calls to Discord's API carry the
/// session token in an Authorization header, and this catches that one value.
final class DiscordLoginWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    static let handlerName = "asideToken"

    /// Runs before any of Discord's own script, so its first request is seen.
    /// Only requests to /api/ count, and only the header value leaves the page.
    static let hookScript = """
    (function () {
      if (window.__asideHook) { return; }
      window.__asideHook = true;
      function report(url, value) {
        try {
          if (typeof value !== 'string' || !value) { return; }
          if (String(url).indexOf('/api/') < 0) { return; }
          window.webkit.messageHandlers.\(handlerName).postMessage(value);
        } catch (e) {}
      }
      var realFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var value = null;
          var headers = init && init.headers;
          if (headers) {
            value = typeof headers.get === 'function' ? headers.get('Authorization')
                  : (headers['Authorization'] || headers['authorization']);
          }
          if (!value && input && input.headers && typeof input.headers.get === 'function') {
            value = input.headers.get('Authorization');
          }
          report(url, value);
        } catch (e) {}
        return realFetch.apply(this, arguments);
      };
      var realOpen = XMLHttpRequest.prototype.open;
      var realSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__asideURL = url;
        return realOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try {
          if (String(name).toLowerCase() === 'authorization') { report(this.__asideURL, value); }
        } catch (e) {}
        return realSet.apply(this, arguments);
      };
    })();
    """

    private var window: NSWindow?
    private var webView: WKWebView?
    private var done = false
    private let onToken: (String) -> Void
    /// Said in plain words when the page cannot load or draws nothing, so a blank
    /// window is never the only sign something is wrong.
    private let onProblem: (String) -> Void

    init(onToken: @escaping (String) -> Void, onProblem: @escaping (String) -> Void = { _ in }) {
        self.onToken = onToken
        self.onProblem = onProblem
        super.init()
    }

    private func problem(_ message: String) {
        NSLog("aside discord login: %@", message)
        DispatchQueue.main.async { [weak self] in self?.onProblem(message) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        problem("the page could not load (\(error.localizedDescription))")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        problem("the page failed (\(error.localizedDescription))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Discord draws its login with script after the page loads, so look a
        // few seconds later rather than at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak webView] in
            guard let self, let webView, !self.done else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText.length : -1") { result, _ in
                if let length = result as? Int, length <= 0 {
                    self.problem("the page loaded but drew nothing")
                }
            }
        }
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let config = WKWebViewConfiguration()
        let script = WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: Self.handlerName)

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: config)
        // The page is shown with WebKit's own browser identity. Forcing a Chrome
        // string onto WebKit left this window blank, so the login uses the
        // honest default and only the gateway announces the web client.
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "https://discord.com/login")!))

        let win = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Log in to Discord"
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        webView = web
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }

    func windowWillClose(_ notification: Notification) {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        window = nil
        webView = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !done, message.name == Self.handlerName,
              let value = message.body as? String, DiscordProtocol.looksLikeToken(value) else { return }
        done = true
        onToken(value)
        close()
    }
}
