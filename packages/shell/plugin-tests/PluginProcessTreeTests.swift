import XCTest

@testable import ArdiaPluginCore

final class PluginProcessTreeTests: XCTestCase {
  var root = ""

  override func setUpWithError() throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-tree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    root = made.path
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: root)
  }

  static let helper = """
    import os, subprocess, sys, time
    os.setpgid(0, 0)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
    open(sys.argv[1], "w").write(str(child.pid))
    time.sleep(60)
    """

  func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  func startHelper() throws -> (helper: Process, child: pid_t) {
    let marker = "\(root)/child.pid"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", Self.helper, marker]
    try process.run()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let text = try? String(contentsOfFile: marker, encoding: .utf8), let pid = pid_t(text) { return (process, pid) }
      usleep(50_000)
    }
    throw XCTSkip("the helper didn't start")
  }

  func waitGone(_ pid: pid_t) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if !alive(pid) { return true }
      usleep(20_000)
    }
    return false
  }

  func testStoppingAHelperEndsAChildThatLeftItsProcessGroup() throws {
    let (helper, child) = try startHelper()
    defer { kill(child, SIGKILL) }
    let family = PluginProcessTree.family(of: helper.processIdentifier)
    PluginProcessTree.signal(family, SIGKILL)
    helper.waitUntilExit()
    XCTAssertTrue(waitGone(child), "the child in its own session is stopped with the helper")
  }

  func testAFamilyRememberedBeforeTheHelperExitedIsStillEnded() throws {
    let (helper, child) = try startHelper()
    defer { kill(child, SIGKILL) }
    let family = PluginProcessTree.family(of: helper.processIdentifier)
    kill(helper.processIdentifier, SIGKILL)
    helper.waitUntilExit()
    XCTAssertTrue(alive(child), "orphaned onto launchd")
    PluginProcessTree.signal(family, SIGKILL)
    XCTAssertTrue(waitGone(child))
  }

  func testTheFamilyNeverTakesInThisProcessOrLaunchd() throws {
    let (helper, child) = try startHelper()
    defer {
      kill(child, SIGKILL)
      helper.terminate()
    }
    let pids = Set(PluginProcessTree.family(of: helper.processIdentifier).map(\.pid))
    XCTAssertTrue(pids.contains(child))
    XCTAssertFalse(pids.contains(getpid()))
    XCTAssertFalse(pids.contains(1))
  }
}
