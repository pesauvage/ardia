import ExpoModulesCore

public class FaviconsModule: Module {
  public func definition() -> ModuleDefinition {
    Name(Self.calls.moduleName)

    Self.calls.function
  }

  static let calls = CallTable(domain: "favicons", handlers: [
    "get": { args, reply in ArdiaFaviconStore.lookUp(args.json, profile: args.profile) { reply.service($0, $1) } },
    "set": { args, reply in ArdiaFaviconStore.set(args.json, profile: args.profile) { reply.service($0, $1) } },
    "fetch": { args, reply in ArdiaFavicons.fetch(try args.text("url"), page: try args.optionalText("page"), profile: args.profile) { reply.ok($0) } },
    "forget": { args, reply in
      ArdiaFaviconStore.forget(args.profile, keeping: try args.strings("keeping"))
      reply.ok()
    },
    "counts": { _, reply in reply.ok(ArdiaFaviconStore.takeCounts()) },
  ])
}
