import 'dart:typed_data';

/// Ключ устройства для сейфа (ADR-025): секрет, который не покидает
/// защищённое хранилище системы (Android Keystore, DPAPI Windows) или —
/// честный запасной вариант — лежит файлом в профиле пользователя.
///
/// Хранилище знает о нём только [mac]: HMAC от сообщения ключом с именем
/// `alias`. Сам ключ наружу не выходит (на Android — никогда; на
/// компьютере — только внутри реализации). Из ответа [mac] сейф выводит
/// ключ, которым обёрнут ключ сейфа (слоты `dev`, `pin`, `bio`).
///
/// Ни ПИН-кода, ни кода восстановления, ни биометрических данных здесь нет:
/// в [mac] приходит уже выведенное Argon2id значение (для ПИН-кода) или
/// служебная строка.
abstract interface class VaultDeviceKey {
  /// Вид хранилища ключа — пишется в слот файла ([VaultDeviceKinds]).
  String get kind;

  /// Можно ли включить ПИН-код сейфа. Нельзя там, где ключ лежит файлом
  /// ([VaultDeviceKinds.fileKey]): скопировав папку, ПИН-код перебирают
  /// без ограничений, и он только создавал бы ложное чувство защиты.
  bool get pinAllowed;

  /// Можно ли привязать сейф к биометрии (ключ выдаёт ответ только после
  /// системного запроса отпечатка, лица или блокировки экрана).
  Future<bool> bioAvailable();

  /// Новый ключ; возвращает его имя (`alias`). [userAuth] — ключ отвечает
  /// только после системной проверки личности (слот `bio`).
  Future<String> create({bool userAuth = false});

  /// HMAC-SHA256 от [message] ключом [alias] (32 байта; вызывающий
  /// затирает). Для ключа с проверкой личности система сначала покажет
  /// запрос с причиной [reason]. Ошибки — [DeviceKeyException].
  Future<Uint8List> mac(String alias, Uint8List message, {String? reason});

  /// Удалить ключ (нет такого — не ошибка).
  Future<void> delete(String alias);
}

/// Виды хранилища ключа устройства (поле `kind` слота). Закрытый список:
/// другое значение в файле — файл испорчен.
abstract final class VaultDeviceKinds {
  static const String androidKeystore = 'android-keystore';
  static const String windowsDpapi = 'windows-dpapi';
  static const String macosKeychain = 'macos-keychain';
  static const String linuxSecret = 'linux-secret';
  static const String fileKey = 'file-key';

  static const Set<String> all = <String>{
    androidKeystore,
    windowsDpapi,
    macosKeychain,
    linuxSecret,
    fileKey,
  };
}

/// Почему ключ устройства не ответил.
enum DeviceKeyFailure {
  /// Ключа нет (удалён системой, приложение переустановлено).
  lost,

  /// Ключ с проверкой личности сброшен системой: добавили отпечаток или
  /// убрали блокировку экрана.
  invalidated,

  /// Человек отменил системный запрос.
  canceled,

  /// Датчик временно заблокирован после неудачных попыток.
  lockout,

  /// Защищённое хранилище недоступно (сбой системы).
  unavailable,
}

/// Ошибка ключа устройства: только код, без подробностей системы.
final class DeviceKeyException implements Exception {
  const DeviceKeyException(this.failure);

  final DeviceKeyFailure failure;

  @override
  String toString() => 'DeviceKeyException(${failure.name})';
}
