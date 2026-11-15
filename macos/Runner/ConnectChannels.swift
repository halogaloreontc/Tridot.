import Cocoa
import FlutterMacOS
import Security

/// Секреты подключений в связке ключей Mac (ADR-031): «общий пароль» на
/// каждый ключ, служба `Tridot connections`, доступ после первой
/// разблокировки и только на этом устройстве. Канал `tridot/keychain`.
///
/// Как в ADR-025: у сборки без подписи разработчика система может снова
/// спросить доступ к связке после пересборки. Сбой связки — ошибка канала;
/// Dart тогда остаётся на файле.
enum KeychainChannel {
  static let service = "Tridot connections"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tridot/keychain", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      guard let key = args?["key"] as? String, !key.isEmpty, key.count <= 128 else {
        result(FlutterError(code: "keychain", message: "key", details: nil))
        return
      }
      switch call.method {
      case "read":
        read(key, result: result)
      case "write":
        guard let value = args?["value"] as? String else {
          result(FlutterError(code: "keychain", message: "value", details: nil))
          return
        }
        write(key, value, result: result)
      case "delete":
        let status = SecItemDelete(query(key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
          result(nil)
        } else {
          result(FlutterError(code: "keychain", message: "\(status)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func read(_ key: String, result: FlutterResult) {
    var q = query(key)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound {
      result(nil)
    } else if status == errSecSuccess, let data = item as? Data,
      let text = String(data: data, encoding: .utf8)
    {
      result(text)
    } else {
      result(FlutterError(code: "keychain", message: "\(status)", details: nil))
    }
  }

  private static func write(_ key: String, _ value: String, result: FlutterResult) {
    let data = Data(value.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = query(key)
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      add[kSecAttrLabel as String] = "Tridot: \(key)"
      status = SecItemAdd(add as CFDictionary, nil)
    }
    if status == errSecSuccess {
      result(nil)
    } else {
      result(FlutterError(code: "keychain", message: "\(status)", details: nil))
    }
  }
}

/// «Открыть в Tridot» на Mac (ADR-031): ссылки `tridot://connect?…` из
/// браузера или приложения склада. Канал `tridot/incoming` только передаёт
/// текст ссылки; разбор и подтверждение — в Dart. Ссылка, пришедшая до
/// запуска Flutter, ждёт вопроса `initial`.
enum IncomingLinks {
  private static var channel: FlutterMethodChannel?
  private static var pending: [String: String]?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tridot/incoming", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "initial":
        result(pending)
        pending = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  static func open(_ urls: [URL]) {
    for url in urls {
      let text = url.absoluteString
      guard url.scheme?.lowercased() == "tridot", text.count <= 2048 else { continue }
      let item = ["kind": "link", "text": text]
      if let channel = channel {
        channel.invokeMethod("incoming", arguments: item)
      } else {
        pending = item
      }
    }
  }
}
