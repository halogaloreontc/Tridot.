import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// «Открыть в Tridot» со страницы склада (ADR-031): tridot://connect?…
  override func application(_ application: NSApplication, open urls: [URL]) {
    IncomingLinks.open(urls)
  }
}
