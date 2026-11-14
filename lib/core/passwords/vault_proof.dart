import 'secret_bytes.dart';

/// Подтверждение человеком действия с открытым сейфом (ADR-025): снять
/// защиту, показать важную запись, выгрузить копию. Чем подтверждать,
/// зависит от защиты сейфа: ПИН-код, биометрия, код восстановления или
/// мастер-пароль (старый сейф), а при защите только устройством —
/// системная блокировка экрана или кнопка «Подтвердить».
///
/// Байты внутри затирает тот, кто создал подтверждение, сразу после
/// вызова.
sealed class VaultProof {
  const VaultProof();
}

/// Мастер-пароль старого сейфа или код восстановления: обёртка `wrap_pw`
/// и общий счётчик ошибок (D25).
final class SecretProof extends VaultProof {
  const SecretProof(this.secret);

  final SecretBytes secret;

  @override
  String toString() => 'SecretProof(•••)';
}

/// ПИН-код сейфа: слот `pin` и счётчик ПИН-кода.
final class PinProof extends VaultProof {
  const PinProof(this.pin);

  final SecretBytes pin;

  @override
  String toString() => 'PinProof(•••)';
}

/// Биометрия: слот `bio` — система спросит отпечаток, лицо или блокировку
/// экрана с причиной [reason].
final class BioProof extends VaultProof {
  const BioProof(this.reason);

  final String reason;

  @override
  String toString() => 'BioProof';
}

/// Сейф защищён только устройством: приложение уже спросило системную
/// блокировку экрана (или кнопку «Подтвердить», если блокировки нет).
/// Хранилище принимает его только у сейфа со слотом `dev`.
final class DeviceProof extends VaultProof {
  const DeviceProof();

  @override
  String toString() => 'DeviceProof';
}
