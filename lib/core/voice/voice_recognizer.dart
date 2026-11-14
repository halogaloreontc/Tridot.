/// Распознавание речи для голосового ввода (ADR-023): только ввод, без
/// озвучивания ответов. Звук живёт только в памяти: не сохраняется, не
/// отправляется и не пишется в журнал; распознанный текст — тоже.
library;

/// Доступен ли голосовой ввод на этой платформе.
enum VoiceSupport { supported, unsupported }

/// Ответ на запрос доступа к микрофону.
enum VoicePermission { granted, denied, permanentlyDenied }

/// Что пошло не так при распознавании.
enum VoiceErrorCode {
  /// Модель не загрузилась (повреждена, не хватило памяти).
  modelLoad,

  /// Микрофон недоступен: нет разрешения или занят.
  microphone,

  /// Сбой движка распознавания.
  engine,
}

/// Текст ошибки для пользователя. Распознанного текста в нём нет.
extension VoiceErrorText on VoiceErrorCode {
  String get message => switch (this) {
        VoiceErrorCode.modelLoad =>
          'Не удалось загрузить модель распознавания. Попробуйте удалить '
              'её и скачать заново',
        VoiceErrorCode.microphone =>
          'Микрофон недоступен. Проверьте разрешение или закройте '
              'приложение, которое его занимает',
        VoiceErrorCode.engine => 'Распознавание прервалось. Попробуйте ещё раз',
      };
}

/// Событие распознавания.
sealed class VoiceEvent {
  const VoiceEvent();
}

/// Промежуточный текст, пока говорят: показывается серым и меняется.
final class VoicePartial extends VoiceEvent {
  const VoicePartial(this.text);

  final String text;
}

/// Итог после [VoiceRecognizer.stop].
final class VoiceFinal extends VoiceEvent {
  const VoiceFinal(this.text);

  final String text;
}

final class VoiceError extends VoiceEvent {
  const VoiceError(this.code);

  final VoiceErrorCode code;
}

/// Распознаватель речи. Настоящий — Vosk через `dart:ffi`
/// (`lib/app/voice/vosk_voice_recognizer.dart`), в тестах — подделка.
abstract interface class VoiceRecognizer {
  /// Есть ли движок на этой платформе. Без него микрофон скрыт.
  VoiceSupport get support;

  /// Проверяет и при необходимости запрашивает доступ к микрофону.
  Future<VoicePermission> ensurePermission();

  /// Загружает модель из папки [modelDir]. Если эта модель уже загружена —
  /// ничего не делает (вызывать можно перед каждым началом). Ошибка —
  /// исключение.
  Future<void> load(String modelDir);

  /// Начинает слушать. Поток: [VoicePartial] по ходу речи, затем один
  /// [VoiceFinal] после [stop] или [VoiceError]; после этого закрывается.
  Stream<VoiceEvent> start();

  /// Заканчивает слушать: поток из [start] получит [VoiceFinal].
  Future<void> stop();

  /// Прерывает без итога: поток из [start] закрывается без [VoiceFinal].
  Future<void> cancel();

  /// Освобождает модель (перед удалением её файлов).
  Future<void> unload();

  Future<void> dispose();
}

/// Распознанный текст для поля ввода: без пробелов по краям, без двойных
/// пробелов, с заглавной первой буквой. Остальные буквы не трогаются.
String normalizeRecognized(String text) {
  final collapsed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.isEmpty) return '';
  final first = collapsed.runes.first;
  final head = String.fromCharCode(first);
  return head.toUpperCase() + collapsed.substring(head.length);
}

/// Исключение [VoiceRecognizer.load] и других вызовов движка.
final class VoiceEngineException implements Exception {
  const VoiceEngineException(this.code);

  final VoiceErrorCode code;

  @override
  String toString() => 'VoiceEngineException(${code.name})';
}
