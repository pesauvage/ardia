import XCTest

@testable import ArdiaPluginCore

final class PluginPageProofTests: XCTestCase {
  static let server = """
    import hashlib, hmac, http.server, sys, urllib.parse
    token, mode = sys.argv[1], sys.argv[2]
    class Page(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if mode == "redirect":
                self.send_response(302); self.send_header("Location", "http://127.0.0.1:1/"); self.end_headers(); return
            nonce = urllib.parse.parse_qs(url.query).get("nonce", [""])[0]
            body = hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest() if mode == "helper" else "ok"
            self.send_response(200); self.end_headers(); self.wfile.write(body.encode())
    server = http.server.HTTPServer(("127.0.0.1", 0), Page)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    """

  func serve(_ token: String, _ mode: String) throws -> (Process, URL) {
    let process = Process()
    let out = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", Self.server, token, mode]
    process.standardOutput = out
    try process.run()
    let line = String(data: out.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process, URL(string: "http://127.0.0.1:\(line)/app/?x=1#frag")!)
  }

  func verified(_ page: URL, token: String) -> Bool {
    let finished = expectation(description: "verified")
    var result = false
    PluginPageProof.verify(page, token: token) {
      result = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    return result
  }

  func testOnlyAServerHoldingThisRunsTokenIsTrustedWithThePage() throws {
    let token = PluginPageProof.randomHex()
    let (helper, url) = try serve(token, "helper")
    defer { helper.terminate() }
    XCTAssertTrue(verified(url, token: token), "the helper's own server proves it")
    XCTAssertFalse(verified(url, token: PluginPageProof.randomHex()), "a server holding another run's token doesn't")
    let (impostor, other) = try serve(token, "impostor")
    defer { impostor.terminate() }
    XCTAssertFalse(verified(other, token: token), "any other listener on a loopback port doesn't")
    let (redirect, moved) = try serve(token, "redirect")
    defer { redirect.terminate() }
    XCTAssertFalse(verified(moved, token: token), "a redirect is never followed")
  }
}
