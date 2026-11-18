import AppKit
import ArdiaCore
import CryptoKit
import ExpoModulesCore
import WebKit

final class PluginPageMessageBridge: NSObject, WKScriptMessageHandler {
  weak var view: PluginPageView?

  init(_ view: PluginPageView) { self.view = view }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    view?.received(message)
  }
}

final class PluginPageView: ExpoView, WKNavigationDelegate, WKUIDelegate {
  static var live: [String: PluginPageView] = [:]
  private static let all = NSHashTable<PluginPageView>.weakObjects()
  private static var views = 0

  let onOpenUrl = EventDispatcher()
  let onLoaded = EventDispatcher()

  var plugin = "" { didSet { if plugin != oldValue { rebuild() } } }
  var url = "" { didSet { if url != oldValue { load() } } }
  var network = false { didSet { if network != oldValue { rebuild() } } }
  var folderId = "" { didSet { if folderId != oldValue { rebuild() } } }
  var approved = "" { didSet { if approved != oldValue { rebuild() } } }
  var run = 0 { didSet { if run != oldValue { rebuild() } } }
  var context = "" { didSet { if context != oldValue { handOver() } } }
  let viewId: String
  private let limit = PluginPageMessages.Limit()

  static let offlinePolicy =
    "default-src 'self' ardia-plugin: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' ardia-plugin: http://127.0.0.1:* http://localhost:* ws://127.0.0.1:* ws://localhost:*; form-action 'self'; worker-src 'none'"

  private var web: WKWebView?
  private var allowedOrigin: (scheme: String, host: String, port: Int?)?

  required init(appContext: AppContext? = nil) {
    Self.views += 1
    viewId = "v\(Self.views)"
    super.init(appContext: appContext)
    wantsLayer = true
    Self.all.add(self)
  }

  static func storeIdentifier(_ plugin: String) -> UUID {
    let scope = LaunchConfig.shared.dataDirectory ?? ""
    var bytes = Array(SHA256.hash(data: Data("ardia.plugin-page|\(scope)|\(plugin)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
  }

  static func removeData(_ plugin: String, done: @escaping () -> Void) {
    WKWebsiteDataStore.remove(forIdentifier: storeIdentifier(plugin)) { _ in done() }
  }

  private func rebuild() {
    web?.removeFromSuperview()
    web = nil
    if Self.live[plugin] === self { Self.live[plugin] = nil }
    guard PluginFolders.isName(plugin) else { return }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(plugin))
    configuration.setURLSchemeHandler(
      PluginSchemeHandler(plugin: plugin, folderId: folderId, approved: approved, policy: network ? nil : Self.offlinePolicy), forURLScheme: PluginSchemeHandler.scheme)
    configuration.userContentController.add(PluginPageMessageBridge(self), contentWorld: .page, name: "ardia")
    configuration.userContentController.addUserScript(pageScript())
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: bounds, configuration: configuration)
    view.navigationDelegate = self
    view.uiDelegate = self
    view.autoresizingMask = [.width, .height]
    view.setValue(false, forKey: "drawsBackground")
    addSubview(view)
    web = view
    Self.live[plugin] = self
    load()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    web?.frame = bounds
  }

  override func removeFromSuperview() {
    if Self.live[plugin] === self { Self.live[plugin] = nil }
    super.removeFromSuperview()
  }

  private static func origin(of url: URL) -> (scheme: String, host: String, port: Int?)? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    return (scheme, host, url.port)
  }

  private func isAllowed(_ target: URL) -> Bool {
    guard let mine = allowedOrigin, let theirs = Self.origin(of: target) else { return false }
    return mine.scheme == theirs.scheme && mine.host == theirs.host && mine.port == theirs.port
  }

  private static func jsString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
    return literal
  }

  private var contextLiteral: String { context.isEmpty ? "null" : "JSON.parse(\(Self.jsString(context)))" }

  private func pageScript() -> WKUserScript {
    let source = """
      (() => { const port = window.webkit.messageHandlers.ardia; const ardia = new EventTarget(); ardia.context = \(contextLiteral); \
      ardia.send = (message) => port.postMessage(JSON.stringify(message)); \
      Object.defineProperty(window, "ardia", { value: ardia, writable: false, configurable: false }); })();
      """
    return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
  }

  private func handOver() {
    guard let web else { return }
    web.configuration.userContentController.removeAllUserScripts()
    web.configuration.userContentController.addUserScript(pageScript())
    let update = "if (window.ardia) { window.ardia.context = \(contextLiteral); window.ardia.dispatchEvent(new Event(\"context\")); }"
    web.evaluateJavaScript(update, completionHandler: nil)
  }

  func received(_ message: WKScriptMessage) {
    let origin = message.frameInfo.securityOrigin
    guard message.frameInfo.isMainFrame, origin.protocol == PluginSchemeHandler.scheme, origin.host == plugin, run > 0, !approved.isEmpty,
      limit.allow(now: ProcessInfo.processInfo.systemUptime)
    else { return }
    PluginHost.shared.pageMessage(plugin, run: run, approved: approved, view: viewId, body: message.body)
  }

  static func deliver(_ post: PagePost, plugin: String, run: Int, approved: String) {
    for view in all.allObjects where view.plugin == plugin && view.run == run && view.approved == approved && (post.view == nil || post.view == view.viewId) {
      let script = "if (window.ardia) window.ardia.dispatchEvent(new MessageEvent(\"message\", { data: JSON.parse(\(jsString(post.json))) }));"
      view.web?.evaluateJavaScript(script, completionHandler: nil)
    }
  }

  private func load() {
    guard let web, let target = URL(string: url), let origin = Self.origin(of: target), origin.scheme == PluginSchemeHandler.scheme, origin.host == plugin else { return }
    allowedOrigin = origin
    web.load(URLRequest(url: target))
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let target = action.request.url else { return decisionHandler(.cancel) }
    if isAllowed(target) && action.targetFrame != nil { return decisionHandler(.allow) }
    if target.scheme == "about" && action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
    if action.navigationType == .linkActivated, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
      onOpenUrl(["url": target.absoluteString])
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    decisionHandler(response.canShowMIMEType ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onLoaded(["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""])
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if action.navigationType == .linkActivated, let target = action.request.url, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
      onOpenUrl(["url": target.absoluteString])
    }
    return nil
  }

  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }

  func snapshot(to path: String, done: @escaping (Bool) -> Void) {
    guard let web else { return done(false) }
    web.takeSnapshot(with: nil) { image, _ in
      guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
        return done(false)
      }
      done((try? png.write(to: URL(fileURLWithPath: path))) != nil)
    }
  }
}
