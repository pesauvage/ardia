import AppKit
import ArdiaCore
import Foundation

struct PluginFolders {
  static let maxPlugins = 64
  static let manifestName = "plugin.json"
  private static let namePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,39}$")

  let config: String
  let appData: String
  let pluginsLexical: String

  static func current() -> PluginFolders? {
    guard let marker = try? DocumentStore.url("plugins.json") else { return nil }
    let appData = marker.deletingLastPathComponent().path
    let config = LaunchConfig.shared.configDirectory
    return PluginFolders(
      config: PluginSandbox.resolved(config) ?? config, appData: PluginSandbox.resolved(appData) ?? appData,
      pluginsLexical: (config as NSString).appendingPathComponent("plugins"))
  }

  static func isName(_ name: String) -> Bool {
    namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
  }

  func lexicalFolder(_ name: String) -> String? {
    Self.isName(name) ? (pluginsLexical as NSString).appendingPathComponent(name) : nil
  }

  func approvedFolder(_ name: String, folderId: String, approved: String) -> Result<OpenedFolder, FolderRefusal> {
    guard let path = lexicalFolder(name) else { return .failure(FolderRefusal(reason: "it has no folder")) }
    return PluginFiles.approvedFolder(path, folderId: folderId, approved: approved)
  }

  func dataRoot() -> String { (appData as NSString).appendingPathComponent("PluginData") }

  func dataFolder(_ name: String) -> String? {
    guard Self.isName(name) else { return nil }
    let folder = (dataRoot() as NSString).appendingPathComponent(name)
    for sub in ["home", "tmp"] {
      let path = (folder as NSString).appendingPathComponent(sub)
      do {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch {
        return nil
      }
    }
    var info = stat()
    guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { return nil }
    return PluginSandbox.resolved(folder)
  }

  func list() -> [[String: Any]] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: pluginsLexical) else { return [] }
    return names.filter(Self.isName).sorted().prefix(Self.maxPlugins).map { name in
      guard let folder = PluginFiles.openFolder((pluginsLexical as NSString).appendingPathComponent(name)) else { return ["name": name, "status": "missing"] }
      defer { folder.close() }
      let read = PluginFiles.readManifest(in: folder)
      var entry: [String: Any] = ["name": name, "status": read.status, "folderId": folder.id]
      if case .text(let text) = read { entry["text"] = text }
      return entry
    }
  }

  func remove(_ name: String) -> String? {
    guard Self.isName(name) else { return "That isn't a plugin's name." }
    let link = (pluginsLexical as NSString).appendingPathComponent(name)
    var info = stat()
    if lstat(link, &info) == 0 {
      do {
        if LaunchConfig.shared.dataDirectory != nil {
          try FileManager.default.removeItem(atPath: link)
        } else {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: link), resultingItemURL: nil)
        }
      } catch {
        return "Its folder couldn't be moved to the Trash (\(error.localizedDescription))."
      }
    }
    let data = (dataRoot() as NSString).appendingPathComponent(name)
    if lstat(data, &info) == 0 { try? FileManager.default.removeItem(atPath: data) }
    return nil
  }
}
