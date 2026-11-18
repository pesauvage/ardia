import AppKit
import ArdiaCore
import CryptoKit
import ExpoModulesCore
import WebKit

final class PluginPageMessageBridge: NSObject, WKScriptMessageHandler {
  static let live = NSHashTable<PluginPageMessageBridge>.weakObjects()

  let binding: PageBinding
  weak var webView: WKWebView?
  private(set) var revoked = false
  private let limit = PluginPageMessages.Limit()

  init(_ binding: PageBinding) {
    self.binding = binding
    super.init()
    Self.live.add(self)
    if binding.run > 0 { PluginHost.shared.bindPage(binding) }
  }

  func revoke() {
    guard !revoked else { return }
    revoked = true
    PluginHost.shared.revokePage(binding)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    let origin = message.frameInfo.securityOrigin
    guard !revoked, let webView, message.webView === webView, message.frameInfo.isMainFrame, origin.protocol == PluginSchemeHandler.scheme,
      origin.host == binding.plugin, binding.run > 0, limit.allow(now: ProcessInfo.processInfo.systemUptime)
    else { return }
    PluginHost.shared.pageMessage(binding, body: message.body)
  }

  static func deliver(_ binding: PageBinding, _ json: String, done: @escaping () -> Void) {
    guard let bridge = live.allObjects.first(where: { $0.binding == binding && !$0.revoked }), let webView = bridge.webView else { return done() }
    let script = "if (window.ardia) window.ardia.dispatchEvent(new MessageEvent(\"message\", { data: JSON.parse(\(PluginPageView.jsString(json))) }));"
    webView.evaluateJavaScript(script) { _, _ in done() }
  }
}

final class PluginPageView: ExpoView, WKNavigationDelegate, WKUIDelegate {
  static var live: [String: PluginPageView] = [:]
  private static var views = 0
  private var bridge: PluginPageMessageBridge?

  let onLoaded = EventDispatcher()

  var plugin = "" { didSet { if plugin != oldValue { rebuild() } } }
  var url = "" { didSet { if url != oldValue { load() } } }
  var network = false { didSet { if network != oldValue { rebuild() } } }
  var folderId = "" { didSet { if folderId != oldValue { rebuild() } } }
  var approved = "" { didSet { if approved != oldValue { rebuild() } } }
  var run = 0 { didSet { if run != oldValue { rebuild() } } }
  var context = "" { didSet { if context != oldValue { handOver() } } }
  let viewId: String

  static let offlinePolicy =
    "default-src 'self' ardia-plugin: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' ardia-plugin:; form-action 'self'; worker-src 'none'"

  static func holdOffline(_ configuration: WKWebViewConfiguration) -> Bool {
    let peers = NSSelectorFromString("_setPeerConnectionEnabled:")
    let hosts = NSSelectorFromString("_setAllowedNetworkHosts:")
    guard configuration.preferences.responds(to: peers), configuration.responds(to: hosts) else { return false }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(configuration.preferences.method(for: peers), to: Setter.self)(configuration.preferences, peers, false)
    configuration.perform(hosts, with: NSSet())
    return true
  }

  private var web: WKWebView?
  private var allowedOrigin: (scheme: String, host: String, port: Int?)?

  required init(appContext: AppContext? = nil) {
    Self.views += 1
    viewId = "v\(Self.views)"
    super.init(appContext: appContext)
    wantsLayer = true
  }

  deinit {
    bridge?.revoke()
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
    bridge?.revoke()
    bridge = nil
    web?.removeFromSuperview()
    web = nil
    if Self.live[plugin] === self { Self.live[plugin] = nil }
    guard PluginFolders.isName(plugin) else { return }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(plugin))
    configuration.setURLSchemeHandler(
      PluginSchemeHandler(plugin: plugin, folderId: folderId, approved: approved, policy: network ? nil : Self.offlinePolicy), forURLScheme: PluginSchemeHandler.scheme)
    let bridge = PluginPageMessageBridge(PageBinding(plugin: plugin, approved: approved, run: run, view: viewId))
    self.bridge = bridge
    configuration.userContentController.add(bridge, contentWorld: .page, name: "ardia")
    configuration.userContentController.addUserScript(pageScript())
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    if !network && !Self.holdOffline(configuration) {
      NSLog("[plugins] %@'s page isn't shown: this macOS can't hold a page without network offline", plugin)
      return
    }
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: bounds, configuration: configuration)
    bridge.webView = view
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

  static func jsString(_ text: String) -> String {
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



  private func load() {
    guard let web, let target = URL(string: url), let origin = Self.origin(of: target), origin.scheme == PluginSchemeHandler.scheme, origin.host == plugin else { return }
    allowedOrigin = origin
    web.load(URLRequest(url: target))
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let target = action.request.url, !action.shouldPerformDownload else { return decisionHandler(.cancel) }
    if isAllowed(target) && action.targetFrame != nil { return decisionHandler(.allow) }
    if target.scheme == "about" && action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    decisionHandler(response.canShowMIMEType ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onLoaded(["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""])
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
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
