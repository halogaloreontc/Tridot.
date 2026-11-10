/// Ошибки хранилища паролей (ADR-014).
///
/// Ни одна ошибка не несёт данных: ни фрагмента файла, ни ввода, ни
/// причины из нижнего слоя. [toString] — только имя кода. Всё, что
/// выходит из модуля `lib/core/passwords`, — [VaultError]; исключения
/// разбора (`FormatException` хранит кусок исходной строки) и ошибки
/// libsodium внутри модуля превращаются в [VaultErrorCode.corrupt] или
/// [VaultErrorCode.io] без `source`.
library;

/// Код ошибки хранилища.
enum VaultErrorCode {
  /// Мастер-пароль не подошёл (не снялась обёртка ключа).
  wrongPassword,

  /// Файл повреждён или подменён: тело, индекс, секрет, состав записей.
  corrupt,

  /// Параметры Argon2id в файле вне допустимых границ.
  kdfInvalid,

  /// Файл новее приложения: его не трогаем, «обновите приложение».
  tooNew,

  /// Ключ биометрии сбросился (новые отпечатки, ключ не найден).
  bioInvalidated,

  /// Биометрии на устройстве нет или она выключена.
  bioUnavailable,

  /// Вход по биометрии отменён.
  bioCanceled,

  /// Датчик временно заблокирован после попыток.
  bioLockedOut,

  /// Не прочитать или не записать файл.
  io,

  /// Хранилище заперто (или навык выключен).
  locked,

  /// Слишком много неверных вводов: пауза ([VaultRateLimited.until]).
  rateLimited,
}

/// Ошибка хранилища. Только код (и для паузы — время следующей попытки).
sealed class VaultError implements Exception {
  const VaultError();

  static const VaultError wrongPassword =
      VaultFailure(VaultErrorCode.wrongPassword);
  static const VaultError corrupt = VaultFailure(VaultErrorCode.corrupt);
  static const VaultError kdfInvalid = VaultFailure(VaultErrorCode.kdfInvalid);
  static const VaultError tooNew = VaultFailure(VaultErrorCode.tooNew);
  static const VaultError io = VaultFailure(VaultErrorCode.io);
  static const VaultError locked = VaultFailure(VaultErrorCode.locked);

  VaultErrorCode get code;

  @override
  String toString() => code.name;
}

/// Ошибка с одним кодом.
final class VaultFailure extends VaultError {
  const VaultFailure(this.code);

  @override
  final VaultErrorCode code;

  @override
  bool operator ==(Object other) => other is VaultFailure && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// Пауза после неверных вводов мастер-пароля (D25): до [until] попытки не
/// принимаются, даже верные.
final class VaultRateLimited extends VaultError {
  const VaultRateLimited(this.until);

  /// Когда можно попробовать снова.
  final DateTime until;

  @override
  VaultErrorCode get code => VaultErrorCode.rateLimited;
}
