import CryptoKit
import Darwin
import Foundation

struct OpenedFolder {
  let fd: Int32
  let path: String
  let id: String

  func close() { Darwin.close(fd) }
}

struct FolderRefusal: Error {
  let reason: String
}

enum ManifestRead: Equatable {
  case text(String)
  case missing, link, notFile, tooBig, unreadable

  var status: String {
    switch self {
    case .text: return "ok"
    case .missing: return "missing"
    case .link: return "link"
    case .notFile: return "notFile"
    case .tooBig: return "tooBig"
    case .unreadable: return "unreadable"
    }
  }
}

enum PluginFiles {
  static let logLimit: off_t = 1 << 20
  static let manifestName = "plugin.json"
  static let manifestLimit = 1 << 20

  static func openedPath(_ fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    return String(cString: buffer)
  }

  static func openFolder(_ path: String) -> OpenedFolder? {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0, let real = openedPath(fd) else {
      Darwin.close(fd)
      return nil
    }
    return OpenedFolder(fd: fd, path: real, id: "\(info.st_dev):\(info.st_ino)")
  }

  static func readManifest(in folder: OpenedFolder) -> ManifestRead {
    let fd = openat(folder.fd, manifestName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0 { return errno == ELOOP ? .link : errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return .unreadable }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return .notFile }
    guard info.st_size <= manifestLimit else { return .tooBig }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= manifestLimit {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        return .unreadable
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    guard data.count <= manifestLimit else { return .tooBig }
    guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
    return .text(text)
  }

  static func approvalHash(text: String, folderId: String) -> String {
    SHA256.hash(data: Data("\(text)\u{0}\(folderId)".utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func approvedFolder(_ path: String, folderId: String, approved: String) -> Result<OpenedFolder, FolderRefusal> {
    guard let folder = openFolder(path) else { return .failure(FolderRefusal(reason: "its folder is missing")) }
    guard folder.id == folderId else {
      folder.close()
      return .failure(FolderRefusal(reason: "its folder was replaced since you approved it"))
    }
    guard case .text(let text) = readManifest(in: folder), approvalHash(text: text, folderId: folder.id) == approved else {
      folder.close()
      return .failure(FolderRefusal(reason: "its plugin.json changed since you approved it"))
    }
    return .success(folder)
  }

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
