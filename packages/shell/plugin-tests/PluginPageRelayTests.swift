import XCTest

@testable import ArdiaPluginCore

final class PluginPageRelayTests: XCTestCase {
  final class Seen {
    var heads: [PluginPageRelay.Head] = []
    var body = Data()
    var finished = 0
    var failures: [String] = []

    var handlers: PluginPageRelay.Handlers {
      .init(head: { self.heads.append($0) }, body: { self.body.append($0) }, finish: { self.finished += 1 }, fail: { self.failures.append($0) })
    }
  }

  func decode(_ line: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
  }

  func testARequestStreamsItsResponseWithOnlySafeHeadersEitherWay() throws {
    let relay = PluginPageRelay()
    let seen = Seen()
    let (id, line) = try XCTUnwrap(relay.begin(method: "GET", path: "/chats/7?x=1", headers: ["Accept": "text/html", "Cookie": "a=b", "Authorization": "x"], handlers: seen.handlers))
    let asked = decode(line)
    XCTAssertEqual(asked["pageRequest"] as? String, id)
    XCTAssertEqual(asked["path"] as? String, "/chats/7?x=1")
    XCTAssertEqual(asked["headers"] as? [String: String], ["accept": "text/html"], "no cookie or credential leaves Ardia")
    XCTAssertNil(relay.handle(method: "page.respond", params: ["request": id, "status": 200, "headers": ["Content-Type": "text/html", "Link": "<https://x>; rel=preload", "Set-Cookie": "a=b"], "body": Data("<h1>".utf8).base64EncodedString(), "more": true]))
    XCTAssertEqual(seen.heads, [.init(status: 200, headers: ["content-type": "text/html"])], "no Link, Set-Cookie or anything else the helper sends")
    XCTAssertNil(relay.handle(method: "page.body", params: ["request": id, "body": Data("hi</h1>".utf8).base64EncodedString()]))
    XCTAssertEqual(String(data: seen.body, encoding: .utf8), "<h1>hi</h1>")
    XCTAssertEqual(seen.finished, 1)
    XCTAssertNotNil(relay.handle(method: "page.body", params: ["request": id, "body": ""]), "a finished request takes nothing more")
  }

  func testOutOfOrderOversizeAndUnknownAnswersAreRefused() throws {
    let relay = PluginPageRelay()
    let seen = Seen()
    let (id, _) = try XCTUnwrap(relay.begin(method: "GET", path: "/", headers: [:], handlers: seen.handlers))
    XCTAssertNotNil(relay.handle(method: "page.body", params: ["request": id, "body": ""]), "a body before its response")
    XCTAssertNotNil(relay.handle(method: "page.respond", params: ["request": "p99", "status": 200]))
    XCTAssertNotNil(relay.handle(method: "page.respond", params: ["request": id, "status": 99]))
    XCTAssertNil(relay.handle(method: "page.respond", params: ["request": id, "status": 200, "more": true]))
    let chunk = Data(count: PluginPageRelay.maxChunk).base64EncodedString()
    for _ in 0..<(PluginPageRelay.maxBody / PluginPageRelay.maxChunk) {
      XCTAssertNil(relay.handle(method: "page.body", params: ["request": id, "body": chunk, "more": true]))
    }
    XCTAssertNotNil(relay.handle(method: "page.body", params: ["request": id, "body": Data([1]).base64EncodedString(), "more": true]))
    XCTAssertEqual(seen.failures, ["the page was over 10 MB"])
    XCTAssertEqual(relay.openCount, 0)
  }

  func testAStoppedHelperFailsEveryOpenRequestAndACancelTellsTheHelper() throws {
    let relay = PluginPageRelay()
    let first = Seen()
    let second = Seen()
    let (a, _) = try XCTUnwrap(relay.begin(method: "GET", path: "/a", headers: [:], handlers: first.handlers))
    _ = try XCTUnwrap(relay.begin(method: "GET", path: "/b", headers: [:], handlers: second.handlers))
    XCTAssertEqual(decode(try XCTUnwrap(relay.cancel(a)))["pageCancel"] as? String, a)
    relay.failAll("the helper stopped")
    XCTAssertEqual(first.failures, [])
    XCTAssertEqual(second.failures, ["the helper stopped"])
  }
}
