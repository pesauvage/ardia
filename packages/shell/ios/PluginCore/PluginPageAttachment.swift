import Foundation

extension PageBinding {
  private static var issued = 0

  static func fresh(plugin: String, approved: String, run: Int) -> PageBinding {
    issued += 1
    return PageBinding(plugin: plugin, approved: approved, run: run, view: "b\(issued)")
  }
}
