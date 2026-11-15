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
    // Напоминания о задачах (ADR-029): UNUserNotificationCenter, без сети.
    NotifyChannel.register(with: flutterViewController.engine.binaryMessenger)
    // Своя страница и приложение «Погода» (ADR-030): открывает система.
    LinksChannel.register(with: flutterViewController.engine.binaryMessenger)
    // Склад (ADR-031): ключи подключений в связке ключей, «Открыть в Tridot».
    KeychainChannel.register(with: flutterViewController.engine.binaryMessenger)
    IncomingLinks.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
