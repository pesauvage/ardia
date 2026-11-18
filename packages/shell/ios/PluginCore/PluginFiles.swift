import Darwin
import Foundation

enum PluginFiles {
  static let logLimit: off_t = 1 << 20

  static func openLog(_ folder: String) -> Int32 {
    let path = (folder as NSString).appendingPathComponent("plugin.log")
    var info = stat()
    if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > logLimit {
      rename(path, path + ".1")
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { return -1 }
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(fd)
      errno = EFTYPE
      return -1
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    return fd
  }
}
