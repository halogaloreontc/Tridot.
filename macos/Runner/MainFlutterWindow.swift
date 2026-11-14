import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Конвертер звука и видео средствами Mac и встроенный LAME (ADR-026).
    MediaChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
