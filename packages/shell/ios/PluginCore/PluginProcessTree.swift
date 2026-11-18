import Darwin
import Foundation

struct PluginProcessMember: Hashable {
  let pid: pid_t
  let started: UInt64
}

enum PluginProcessTree {
  struct Entry {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let started: UInt64
  }

  static func entry(_ pid: pid_t) -> Entry? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Entry(pid: pid, ppid: pid_t(info.pbi_ppid), pgid: pid_t(info.pbi_pgid), started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
  }

  static func table() -> [Entry] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(0, got))).filter { $0 > 0 }.compactMap(entry)
  }

  static func family(of root: pid_t) -> Set<PluginProcessMember> {
    let entries = table()
    let excluded: Set<pid_t> = [0, 1, getpid()]
    var pids: Set<pid_t> = [root]
    var grew = true
    while grew {
      grew = false
      for e in entries where !pids.contains(e.pid) && !excluded.contains(e.pid) && (pids.contains(e.ppid) || pids.contains(e.pgid)) {
        pids.insert(e.pid)
        grew = true
      }
    }
    return Set(entries.filter { pids.contains($0.pid) && !excluded.contains($0.pid) }.map { PluginProcessMember(pid: $0.pid, started: $0.started) })
  }

  static func signal(_ members: Set<PluginProcessMember>, _ signal: Int32) {
    for member in members where entry(member.pid)?.started == member.started { kill(member.pid, signal) }
  }
}
