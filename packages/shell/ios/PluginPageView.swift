import AppKit
import ArdiaCore
import CryptoKit
import ExpoModulesCore
import WebKit

final class PluginPageView: ExpoView, WKNavigationDelegate, WKUIDelegate {
  static var live: [String: PluginPageView] = [:]

  let onOpenUrl = EventDispatcher()
  let onLoaded = EventDispatcher()
  let onRefused = EventDispatcher()

  var plugin = "" { didSet { if plugin != oldValue { rebuild() } } }
  var url = "" { didSet { if url != oldValue { load() } } }
  var network = false { didSet { if network != oldValue { rebuild() } } }
  var folderId = "" { didSet { if folderId != oldValue { rebuild() } } }
  var pageToken = "" { didSet { if pageToken != oldValue { load() } } }

  static let offlinePolicy =
    "default-src 'self' ardia-plugin: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' ardia-plugin: http://127.0.0.1:* http://localhost:* ws://127.0.0.1:* ws://localhost:*; form-action 'self'; worker-src 'none'"

  private var web: WKWebView?
  private var allowedOrigin: (scheme: String, host: String, port: Int?)?
  private var loads = 0

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    wantsLayer = true
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
    configuration.setURLSchemeHandler(PluginSchemeHandler(plugin: plugin, folderId: folderId, policy: network ? nil : Self.offlinePolicy), forURLScheme: PluginSchemeHandler.scheme)
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

  private func load() {
    guard let web, let target = URL(string: url), let origin = Self.origin(of: target) else { return }
    let isPage = origin.scheme == PluginSchemeHandler.scheme && origin.host == plugin
    let isLoopback = origin.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(origin.host) && origin.port != nil
    guard isPage || (isLoopback && network) else { return }
    loads += 1
    let attempt = loads
    allowedOrigin = nil
    if isPage {
      allowedOrigin = origin
      web.load(URLRequest(url: target))
      return
    }
    let token = pageToken
    guard !token.isEmpty else { return }
    let shown = url
    PluginPageProof.verify(target, token: token) { [weak self] proven in
      DispatchQueue.main.async {
        guard let self, self.loads == attempt, let web = self.web else { return }
        guard proven, let cookie = Self.tokenCookie(token, for: target) else { return self.onRefused(["url": shown]) }
        web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
          guard let self, self.loads == attempt else { return }
          self.allowedOrigin = origin
          web.load(URLRequest(url: target))
        }
      }
    }
  }

  private static func tokenCookie(_ token: String, for target: URL) -> HTTPCookie? {
    guard let host = target.host else { return nil }
    return HTTPCookie(properties: [
      .name: PluginPageProof.cookie, .value: token, .domain: host, .path: "/", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
      HTTPCookiePropertyKey("HttpOnly"): "TRUE",
    ])
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
