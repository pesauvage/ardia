import CryptoKit
import Foundation
import Security

enum PluginPageProof {
  static let path = "/.well-known/ardia-plugin-proof"
  static let cookie = "ardia_page_token"
  static let timeout: TimeInterval = 5

  static func randomHex(_ count: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return "" }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func answer(token: String, nonce: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  static func challenge(for page: URL, nonce: String) -> URL? {
    guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
    parts.path = path
    parts.query = "nonce=\(nonce)"
    parts.fragment = nil
    return parts.url
  }

  final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  static func verify(_ page: URL, token: String, done: @escaping (Bool) -> Void) {
    let nonce = randomHex()
    guard !token.isEmpty, !nonce.isEmpty, let url = challenge(for: page, nonce: nonce) else { return done(false) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    request.httpShouldHandleCookies = false
    session.dataTask(with: request) { data, response, _ in
      session.finishTasksAndInvalidate()
      let status = (response as? HTTPURLResponse)?.statusCode
      let body = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
      done(status == 200 && body == answer(token: token, nonce: nonce))
    }.resume()
  }
}
