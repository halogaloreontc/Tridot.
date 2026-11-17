/// Распознавание речи для голосового ввода (ADR-023): только ввод, без
/// озвучивания ответов. Звук живёт только в памяти: не сохраняется, не
/// отправляется и не пишется в журнал; распознанный текст — тоже.
library;

import 'voice_text.dart';

export 'voice_text.dart';

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

  /// Распознавание телефона знает русский, но язык ещё не скачан.
  languageUnavailable,

  /// Распознавание телефона не знает русский без интернета.
  languageUnsupported,

  /// Распознавание телефона занято другим приложением.
  busy,
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
        VoiceErrorCode.languageUnavailable =>
          'Русский язык для распознавания ещё не скачан. Скачайте его '
              'в настройках',
        VoiceErrorCode.languageUnsupported =>
          'Распознавание телефона не знает русский. Выберите распознавание '
              'Tridot в настройках',
        VoiceErrorCode.busy => 'Распознавание занято. Попробуйте ещё раз',
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

/// Чем распознаётся речь (ADR-023).
enum VoiceEngine {
  /// Распознавание телефона: `createOnDeviceSpeechRecognizer`, Android 12+.
  device,

  /// Vosk: модель ~44 МБ скачивается один раз.
  vosk,
}

/// Что знает распознавание телефона о русском языке.
enum DeviceVoiceStatus {
  /// Android ниже 12, распознавания на устройстве нет или нет канала.
  unavailable,

  /// Русского нет среди языков на устройстве.
  unsupported,

  /// Русский можно скачать (Android скачает его сам).
  notInstalled,

  /// Android уже скачивает русский.
  pending,

  /// Русский установлен.
  ready,

  /// Узнать нельзя (Android 12): пробуем, сбой при начале уточнит.
  unknown,
}

/// Ход системной загрузки русского языка для распознавания телефона.
sealed class DeviceLanguageDownload {
  const DeviceLanguageDownload();
}

final class DeviceDownloadProgress extends DeviceLanguageDownload {
  const DeviceDownloadProgress(this.percent);

  final int percent;
}

/// Язык скачан и готов.
final class DeviceDownloadSuccess extends DeviceLanguageDownload {
  const DeviceDownloadSuccess();
}

/// Android скачает язык позже (например, по Wi-Fi); новостей больше не
/// будет.
final class DeviceDownloadScheduled extends DeviceLanguageDownload {
  const DeviceDownloadScheduled();
}

/// Загрузку начать не удалось.
final class DeviceDownloadError extends DeviceLanguageDownload {
  const DeviceDownloadError();
}

/// Распознавание телефона: модели не грузит, умеет сказать о языке и
/// попросить систему скачать его.
abstract interface class OnDeviceRecognizer implements VoiceRecognizer {
  /// Что телефон знает о русском. Ошибок не бросает.
  Future<DeviceVoiceStatus> checkStatus();

  /// Просит Android скачать русский язык. Поток кончается успехом,
  /// «скачает позже» или ошибкой.
  Stream<DeviceLanguageDownload> downloadLanguage();
}

/// Распознанный текст для поля ввода: без обрывков вроде «зэд» и «ээ»,
/// с временем цифрами («в девять» → «в 9», [VoiceText]), без пробелов по
/// краям и двойных пробелов, с заглавной первой буквой. Одинаково для
/// любого распознавателя.
String normalizeRecognized(String text) {
  final collapsed =
      VoiceText.clean(text.trim()).trim().replaceAll(RegExp(r'\s+'), ' ');
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
