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

final class PluginResponsibilityTests: XCTestCase {
  static let cli = """
    import os, subprocess, sys, time
    os.setsid()
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    open(sys.argv[1], "w").write(f"{os.getpid()} {child.pid}")
    time.sleep(60)
    """

  func testAHelpersCliAndItsChildAreFoundAfterTheCliParentExited() throws {
    guard PluginProcessTree.tracksResponsibility else { throw XCTSkip("this macOS has no responsibility calls") }
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)").path
    let script = "/usr/bin/python3 -c '\(Self.cli.replacingOccurrences(of: "'", with: "'\\''"))' \(marker) & exit 0"
    let helperScript = "/bin/sh -c \"$1\"; sleep 60"
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    XCTAssertTrue(PluginProcessTree.disclaim(&attributes))
    var helper: pid_t = 0
    let argv = ["/bin/sh", "-c", helperScript, "helper", script].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    XCTAssertEqual(posix_spawn(&helper, "/bin/sh", nil, &attributes, argv, environ), 0)
    defer {
      kill(helper, SIGKILL)
      waitpid(helper, nil, 0)
    }
    var pids: [pid_t] = []
    let deadline = Date().addingTimeInterval(10)
    while pids.count < 2 && Date() < deadline {
      pids = ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").split(separator: " ").compactMap { pid_t($0) }
      usleep(50_000)
    }
    XCTAssertEqual(pids.count, 2, "the CLI and its child started")
    defer { pids.forEach { kill($0, SIGKILL) } }
    XCTAssertEqual(PluginProcessTree.entry(pids[0])?.ppid, 1, "the CLI's parent shell has exited")
    let family = PluginProcessTree.family(of: helper)
    XCTAssertTrue(pids.allSatisfy { pid in family.contains { $0.pid == pid } }, "the orphaned CLI and its child are the helper's")
    PluginProcessTree.signal(family, SIGKILL)
    for pid in pids {
      let gone = Date().addingTimeInterval(3)
      while kill(pid, 0) == 0 && Date() < gone { usleep(20_000) }
      XCTAssertNotEqual(kill(pid, 0), 0)
    }
  }
}
