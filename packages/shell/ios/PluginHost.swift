import AppKit
import Foundation

final class PluginHost {
  static let shared = PluginHost()
  static let quitGrace: TimeInterval = 1

  typealias Sink = (_ name: String, _ body: [String: Any]) -> Void

  private let queue = DispatchQueue(label: "ardia.plugins", qos: .userInitiated)
  private var sink: (owner: ObjectIdentifier, send: Sink)?
  private let runs = PluginRuns<PluginProcess>()
  private var nextRun = 0
  private var quitObserver: NSObjectProtocol?

  func attach(_ owner: AnyObject, send: @escaping Sink) {
    let id = ObjectIdentifier(owner)
    queue.sync { sink = (id, send) }
    if quitObserver == nil {
      quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
        self?.queue.sync { self?.terminateAll() }
      }
    }
  }

  func detach(_ owner: AnyObject) {
    let id = ObjectIdentifier(owner)
    queue.async { [self] in
      guard sink?.owner == id else { return }
      sink = nil
      terminateAll()
    }
  }

  private func terminateAll() {
    let all = runs.all
    runs.removeAll()
    for process in all { process.terminateForQuit(within: Self.quitGrace / Double(max(1, all.count))) }
  }

  func start(_ spec: PluginProcess.Spec, done: @escaping ([String: Any]) -> Void) {
    queue.async { [self] in
      runs.stopAll(spec.name, graceMs: 0) { [self] in spawn(spec, done: done) }
    }
  }

  private func spawn(_ spec: PluginProcess.Spec, done: @escaping ([String: Any]) -> Void) {
    guard let folders = PluginFolders.current() else { return done(["ok": false, "reason": "Ardia has no data folder"]) }
    nextRun += 1
    let result = PluginProcess.spawn(
      spec, run: nextRun, folders: folders, queue: queue,
      onLine: { [weak self] process, line in
        self?.sink?.send("onLine", ["name": process.name, "run": process.run, "line": line])
      },
      onExit: { [weak self] process, status, signal, overMemory in
        guard let self else { return }
        self.runs.exited(process)
        self.sink?.send(
          "onExit",
          ["name": process.name, "run": process.run, "status": status.map { Int($0) } ?? NSNull(), "signal": signal.map { Int($0) } ?? NSNull(), "overMemory": overMemory])
      })
    switch result {
    case .success(let process):
      runs.installed(process)
      process.onPagePost = { process, post in
        let (plugin, run, approved) = (process.name, process.run, process.approved)
        DispatchQueue.main.async { PluginPageView.deliver(post, plugin: plugin, run: run, approved: approved) }
      }
      done(["ok": true, "run": process.run, "pid": Int(process.pid)])
    case .failure(let failure):
      NSLog("[plugins] %@ didn't start: %@", spec.name, failure.reason)
      done(["ok": false, "reason": failure.reason])
    }
  }

  func pageMessage(_ plugin: String, run: Int, approved: String, view: String, body: Any) {
    guard let line = PluginPageMessages.fromPage(body, view: view) else { return }
    queue.async { [self] in
      guard let process = runs.current[plugin], process.run == run, process.approved == approved, !process.exited else { return }
      process.connection?.send(line)
    }
  }

  func stop(_ name: String, run: Int, graceMs: Int, done: @escaping () -> Void) {
    queue.async { [self] in runs.stopAll(name, onlyRun: run, graceMs: graceMs, done: done) }
  }

  private static func framed(_ line: String) -> Data {
    var data = Data(line.utf8)
    data.append(10)
    return data
  }

  func reply(_ name: String, run: Int, _ line: String) {
    let data = Self.framed(line)
    queue.async { [self] in
      guard let process = runs.current[name], process.run == run else { return }
      process.connection?.reply(data, ticket: 0)
    }
  }

  func call(_ name: String, run: Int, _ line: String) {
    let data = Self.framed(line)
    queue.async { [self] in
      guard let process = runs.current[name], process.run == run else { return }
      process.connection?.send(data)
    }
  }

  func event(_ name: String, run: Int, _ line: String) {
    let data = Self.framed(line)
    queue.async { [self] in
      guard let process = runs.current[name], process.run == run else { return }
      process.connection?.event(data)
    }
  }

  func remove(_ name: String, done: @escaping (String?) -> Void) {
    queue.async { [self] in
      let finish = {
        let problem = PluginFolders.current().map { $0.remove(name) } ?? "Ardia has no data folder."
        DispatchQueue.main.async { done(problem) }
      }
      runs.stopAll(name, graceMs: 1000, done: finish)
    }
  }
}
