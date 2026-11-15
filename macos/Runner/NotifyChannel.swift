import Cocoa
import FlutterMacOS
import UserNotifications

/// Канал `tridot/notify` на Mac (ADR-029): разрешение на уведомления и
/// расписание напоминаний о задачах в UNUserNotificationCenter. Будильника
/// и таймера на Mac нет. Ничего не уходит в сеть: системе отдаются только
/// название задачи, время и имя помощника.
///
/// Делегат центра уведомлений ставится при создании окна — до конца
/// запуска, поэтому нажатие на уведомление, которым открыли приложение,
/// тоже доходит.
final class NotifyChannel: NSObject, UNUserNotificationCenterDelegate {
  private static var shared: NotifyChannel?

  private let channel: FlutterMethodChannel

  /// Задача из уведомления, нажатого до того, как Dart спросил.
  private var launchTask: String?

  /// Dart уже спросил о задаче запуска: дальше — сразу «openTask».
  private var dartReady = false

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = NotifyChannel(messenger: messenger)
    shared = instance
    UNUserNotificationCenter.current().delegate = instance
  }

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tridot/notify", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "status":
      status { result($0) }
    case "request":
      center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
        self?.status { result($0) }
      }
    case "exactStatus":
      result("notNeeded")
    case "openNotificationSettings":
      let id = Bundle.main.bundleIdentifier ?? ""
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
      {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "openExactAlarmSettings":
      result(nil)
    case "sync":
      let args = call.arguments as? [String: Any]
      sync(args?["reminders"] as? [[String: Any]] ?? [])
      result(nil)
    case "canSetAlarm", "setAlarm", "setTimer":
      result(false)
    case "takeLaunchTask":
      dartReady = true
      result(launchTask)
      launchTask = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// notDetermined — ещё не спрашивали; denied — вернуть можно только в
  /// «Системных настройках» (Mac спрашивает один раз).
  private func status(_ done: @escaping (String) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let value: String
      switch settings.authorizationStatus {
      case .notDetermined:
        value = "notAsked"
      case .denied:
        value = "permanentlyDenied"
      case .authorized, .provisional:
        value = "granted"
      @unknown default:
        value = "denied"
      }
      DispatchQueue.main.async { done(value) }
    }
  }

  /// Заменяет все ждущие напоминания (не больше 50 — у Mac предел 64).
  private func sync(_ list: [[String: Any]]) {
    let center = UNUserNotificationCenter.current()
    center.removeAllPendingNotificationRequests()
    for item in list.prefix(50) {
      guard let id = item["id"] as? String,
        let taskId = item["taskId"] as? String,
        let at = item["at"] as? NSNumber,
        let title = item["title"] as? String
      else { continue }
      let persona = item["persona"] as? String ?? ""
      let content = UNMutableNotificationContent()
      content.title = persona.isEmpty ? "Напоминание" : "\(persona) · напоминание"
      content.body = String(title.prefix(200))
      content.sound = .default
      content.userInfo = ["task_id": taskId]
      let date = Date(timeIntervalSince1970: at.doubleValue / 1000)
      let parts = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: date)
      let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let taskId = response.notification.request.content.userInfo["task_id"] as? String {
      DispatchQueue.main.async {
        if self.dartReady {
          self.channel.invokeMethod("openTask", arguments: taskId)
        } else {
          self.launchTask = taskId
        }
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    completionHandler()
  }
}
