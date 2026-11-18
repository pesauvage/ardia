import XCTest

@testable import ArdiaPluginCore

final class PluginFilesTests: XCTestCase {
  var root = ""

  override func setUpWithError() throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    root = PluginSandbox.resolved(made.path)!
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: root)
  }

  func testALogThatIsntARegularFileIsRefusedWithoutBlocking() {
    XCTAssertEqual(mkfifo("\(root)/plugin.log", 0o600), 0)
    let opened = expectation(description: "openLog returns")
    var fd: Int32 = 0
    Thread.detachNewThread {
      fd = PluginFiles.openLog(self.root)
      opened.fulfill()
    }
    wait(for: [opened], timeout: 2)
    XCTAssertLessThan(fd, 0, "a FIFO is never the log")
  }

  func testTheLogIsARegularFileOpenedForAppending() {
    let fd = PluginFiles.openLog(root)
    XCTAssertGreaterThanOrEqual(fd, 0)
    var info = stat()
    XCTAssertEqual(fstat(fd, &info), 0)
    XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
    close(fd)
  }
}
