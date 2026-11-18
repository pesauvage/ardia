import Foundation
import Security

final class PluginPageRelay {
  static let maxBody = 10 << 20
  static let maxChunk = 512 << 10
  static let maxOpen = 32
  static let keptRequestHeaders: Set<String> = ["accept", "accept-language", "range", "if-none-match", "if-modified-since"]
  static let keptResponseHeaders: Set<String> = ["content-type", "cache-control", "etag", "last-modified", "content-language", "content-range", "accept-ranges"]

  struct Head: Equatable {
    let status: Int
    let headers: [String: String]
  }

  struct Handlers {
    let head: (Head) -> Void
    let body: (Data) -> Void
    let finish: () -> Void
    let fail: (String) -> Void
  }

  private final class Pending {
    let handlers: Handlers
    var headed = false
    var received = 0

    init(_ handlers: Handlers) { self.handlers = handlers }
  }

  private var pending: [String: Pending] = [:]
  private var next = 0

  var openCount: Int { pending.count }

  static func line(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    data.append(10)
    return data
  }

  static func kept(_ headers: [String: String], _ allowed: Set<String>) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in headers where allowed.contains(key.lowercased()) && !value.contains("\r") && !value.contains("\n") { out[key.lowercased()] = value }
    return out
  }

  func begin(method: String, path: String, headers: [String: String], handlers: Handlers) -> (id: String, line: Data)? {
    guard pending.count < Self.maxOpen else { return nil }
    next += 1
    let id = "p\(next)"
    pending[id] = Pending(handlers)
    return (id, Self.line(["pageRequest": id, "method": method, "path": path, "headers": Self.kept(headers, Self.keptRequestHeaders)]))
  }

  func isHeaded(_ id: String) -> Bool { pending[id]?.headed ?? false }

  func expire(_ id: String, _ reason: String) -> Data? {
    guard let request = pending[id], !request.headed else { return nil }
    pending.removeValue(forKey: id)
    request.handlers.fail(reason)
    return Self.line(["pageCancel": id])
  }

  static func randomSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  func cancel(_ id: String) -> Data? {
    guard pending.removeValue(forKey: id) != nil else { return nil }
    return Self.line(["pageCancel": id])
  }

  func fail(_ id: String, _ reason: String) {
    pending.removeValue(forKey: id)?.handlers.fail(reason)
  }

  func failAll(_ reason: String) {
    let all = pending
    pending.removeAll()
    for request in all.values { request.handlers.fail(reason) }
  }

  private func deliver(_ id: String, _ request: Pending, _ encoded: Any?, more: Bool) -> String? {
    if let encoded {
      guard let text = encoded as? String, let data = Data(base64Encoded: text) else {
        fail(id, "its body wasn't base64")
        return "body must be base64"
      }
      guard data.count <= Self.maxChunk else {
        fail(id, "a body chunk was over 512 KB")
        return "a body chunk can be at most 512 KB"
      }
      request.received += data.count
      guard request.received <= Self.maxBody else {
        fail(id, "the page was over 10 MB")
        return "a page can be at most 10 MB"
      }
      if !data.isEmpty { request.handlers.body(data) }
    }
    if !more {
      pending.removeValue(forKey: id)
      request.handlers.finish()
    }
    return nil
  }

  func handle(method: String, params: [String: Any]) -> String? {
    guard let id = params["request"] as? String, let request = pending[id] else { return "there's no open page request with that id" }
    let more = params["more"] as? Bool ?? false
    switch method {
    case "page.respond":
      guard !request.headed else { return "this request already has its response" }
      guard let status = params["status"] as? Int, (100...599).contains(status) else { return "status must be an HTTP status from 100 to 599" }
      let given = params["headers"] as? [String: Any] ?? [:]
      let headers = Self.kept(given.compactMapValues { $0 as? String }, Self.keptResponseHeaders)
      request.headed = true
      request.handlers.head(Head(status: status, headers: headers))
      return deliver(id, request, params["body"], more: more)
    case "page.body":
      guard request.headed else { return "page.body comes after page.respond" }
      guard params["body"] != nil else { return "page.body needs a body" }
      return deliver(id, request, params["body"], more: more)
    default:
      return "not a page method"
    }
  }
}
