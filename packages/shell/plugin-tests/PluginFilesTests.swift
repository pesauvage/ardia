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

final class PluginFolderBindingTests: XCTestCase {
  var root = ""

  override func setUpWithError() throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    root = PluginSandbox.resolved(made.path)!
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: root)
  }

  func makePlugin(_ path: String, manifest: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try manifest.write(toFile: "\(path)/plugin.json", atomically: false, encoding: .utf8)
  }

  func testTheManifestAndTheIdentityComeFromTheSameFolderEvenIfItIsSwappedMidScan() throws {
    let path = "\(root)/example"
    try makePlugin(path, manifest: "{\"name\":\"approved\"}")
    let folder = try XCTUnwrap(PluginFiles.openFolder(path))
    defer { folder.close() }
    try FileManager.default.moveItem(atPath: path, toPath: "\(root)/old")
    try makePlugin(path, manifest: "{\"name\":\"swapped\"}")
    XCTAssertEqual(PluginFiles.readManifest(in: folder), .text("{\"name\":\"approved\"}"))
    var info = stat()
    XCTAssertEqual(stat("\(root)/old", &info), 0)
    XCTAssertEqual(folder.id, "\(info.st_dev):\(info.st_ino)")
  }

  func testLaunchingIsBoundToTheApprovedFolderAndManifest() throws {
    let path = "\(root)/example"
    let manifest = "{\"name\":\"example\"}"
    try makePlugin(path, manifest: manifest)
    let scanned = try XCTUnwrap(PluginFiles.openFolder(path))
    let id = scanned.id
    scanned.close()
    let approved = PluginFiles.approvalHash(text: manifest, folderId: id)
    guard case .success(let bound) = PluginFiles.approvedFolder(path, folderId: id, approved: approved) else { return XCTFail("the approved folder launches") }
    bound.close()
    try FileManager.default.moveItem(atPath: path, toPath: "\(root)/old")
    try makePlugin(path, manifest: manifest)
    guard case .failure(let why) = PluginFiles.approvedFolder(path, folderId: id, approved: approved) else { return XCTFail("a swapped folder with the same manifest is refused") }
    XCTAssertTrue(why.reason.contains("replaced"))
    try FileManager.default.removeItem(atPath: path)
    try FileManager.default.moveItem(atPath: "\(root)/old", toPath: path)
    try "{\"name\":\"example\",\"permissions\":[\"network\"]}".write(toFile: "\(path)/plugin.json", atomically: false, encoding: .utf8)
    guard case .failure(let changed) = PluginFiles.approvedFolder(path, folderId: id, approved: approved) else { return XCTFail("a changed manifest is refused") }
    XCTAssertTrue(changed.reason.contains("changed"))
  }
}
