import Cocoa
import FlutterMacOS

/// Канал `tridot/links` на Mac (ADR-030): своя страница погоды в браузере
/// и приложение «Погода» (macOS 13+). Только https; сам канал в сеть не
/// ходит — страницу грузит браузер. Песочница открытие через NSWorkspace
/// разрешает.
enum LinksChannel {
  static let weatherBundle = "com.apple.weather"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tridot/links", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "openUrl":
        result(openUrl(args?["url"] as? String))
      case "weatherApps":
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: weatherBundle) != nil {
          result([["id": weatherBundle, "label": "Погода"]])
        } else {
          result([])
        }
      case "openApp":
        openApp(args?["package"] as? String, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func openUrl(_ text: String?) -> Bool {
    guard let text = text, text.count <= 2048,
      let url = URL(string: text), url.scheme?.lowercased() == "https",
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
    else { return false }
    return NSWorkspace.shared.open(url)
  }

  private static func openApp(_ bundle: String?, result: @escaping FlutterResult) {
    guard let bundle = bundle, !bundle.isEmpty,
      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      result(false)
      return
    }
    NSWorkspace.shared.openApplication(
      at: app, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      DispatchQueue.main.async { result(error == nil) }
    }
  }
}
