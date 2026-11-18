import Foundation
import UniformTypeIdentifiers
import WebKit

final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "ardia-plugin"
  static let maxFile = 10 << 20

  let plugin: String
  let folderId: String
  let policy: String?

  init(plugin: String, folderId: String, policy: String?) {
    self.plugin = plugin
    self.folderId = folderId
    self.policy = policy
  }

  static func relativePath(of url: URL, plugin: String) -> String? {
    guard url.scheme == scheme, url.host == plugin, url.user == nil, url.port == nil else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
    return parts.joined(separator: "/")
  }

  static func read(_ relative: String, inside folder: OpenedFolder) -> Data? {
    let fd = PluginFiles.openBeneath(folder.fd, relative, flags: O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxFile else { return nil }
    let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: maxFile + 1)
    return data.count <= maxFile ? data : nil
  }


  func contents(of url: URL) -> (path: String, data: Data)? {
    guard let relative = Self.relativePath(of: url, plugin: plugin), let path = PluginFolders.current()?.lexicalFolder(plugin),
      let folder = PluginFiles.openFolder(path)
    else { return nil }
    defer { folder.close() }
    guard folder.id == folderId, let data = Self.read(relative, inside: folder) else { return nil }
    return (relative, data)
  }

  static func mimeType(_ path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "js" || ext == "mjs" { return "text/javascript" }
    return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
  }

  private func respond(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ text: String) {
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
    task.didReceive(response)
    task.didReceive(Data(text.utf8))
    task.didFinish()
  }

  private func headers(_ given: [String: String]) -> [String: String] {
    var headers = given
    headers["x-content-type-options"] = "nosniff"
    if let policy { headers["content-security-policy"] = policy }
    return headers
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    guard let (path, data) = contents(of: url) else { return respond(task, url, 404, "Not found") }
    let given = ["content-type": Self.mimeType(path), "content-length": String(data.count), "cache-control": "no-store"]
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers(given))!)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
