import XCTest

@testable import ArdiaPluginCore

final class PluginPageMessagesTests: XCTestCase {
  func decode(_ line: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
  }

  func testAPageSendsOnlyBoundedJSONTextTaggedWithItsView() throws {
    let line = try XCTUnwrap(PluginPageMessages.fromPage("{\"ask\":\"hi\"}", view: "v3"))
    XCTAssertEqual(line.last, 10)
    XCTAssertEqual(decode(line)["view"] as? String, "v3")
    XCTAssertEqual(decode(line)["pageMessage"] as? [String: String], ["ask": "hi"])
    XCTAssertNil(PluginPageMessages.fromPage(["ask": "hi"], view: "v3"), "only text crosses, never an object the page built")
    XCTAssertNil(PluginPageMessages.fromPage("{not json", view: "v3"))
    XCTAssertNil(PluginPageMessages.fromPage("\"" + String(repeating: "a", count: PluginPageMessages.maxFromPage) + "\"", view: "v3"))
  }

  func testAHelperPostsBoundedJSONToOneViewOrAll() {
    guard case .success(let post) = PluginPageMessages.toPage(["view": "v3", "message": ["reply": "hello"]]) else { return XCTFail() }
    XCTAssertEqual(post.view, "v3")
    XCTAssertEqual(post.json, "{\"reply\":\"hello\"}")
    guard case .success(let all) = PluginPageMessages.toPage(["message": 7]) else { return XCTFail() }
    XCTAssertNil(all.view)
    XCTAssertEqual(PluginPageMessages.toPage([:]), .failure(.init(reason: "page.post needs a message")))
    XCTAssertEqual(PluginPageMessages.toPage(["view": 3, "message": 1]), .failure(.init(reason: "view must be the id a page message came with")))
    XCTAssertEqual(PluginPageMessages.toPage(["message": String(repeating: "a", count: PluginPageMessages.maxToPage)]), .failure(.init(reason: "a message to a page can be at most 256 KB")))
  }

  func testAPageCanSendAtMostAHundredMessagesASecond() {
    let limit = PluginPageMessages.Limit()
    XCTAssertEqual((0..<150).filter { _ in limit.allow(now: 10) }.count, 100)
    XCTAssertTrue(limit.allow(now: 11.01))
  }
}
