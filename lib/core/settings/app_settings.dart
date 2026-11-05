import 'dart:convert';
import 'dart:io';

/// Пользовательские настройки интерфейса.
final class AppSettings {
  const AppSettings({this.reduceMotion = false, this.showTimestamps = true});

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        reduceMotion: json['reduce_motion'] as bool? ?? false,
        showTimestamps: json['show_timestamps'] as bool? ?? true,
      );

  /// Не анимировать кубик и переходы, даже если система разрешает.
  final bool reduceMotion;

  /// Показывать время под сообщениями чата.
  final bool showTimestamps;

  AppSettings copyWith({bool? reduceMotion, bool? showTimestamps}) =>
      AppSettings(
        reduceMotion: reduceMotion ?? this.reduceMotion,
        showTimestamps: showTimestamps ?? this.showTimestamps,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'reduce_motion': reduceMotion,
        'show_timestamps': showTimestamps,
      };
}

abstract interface class SettingsStore {
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);
}

final class InMemorySettingsStore implements SettingsStore {
  AppSettings _value = const AppSettings();

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<void> save(AppSettings settings) async => _value = settings;
}

/// Настройки в JSON рядом с задачами. Повреждённый файл не мешает запуску:
/// используются значения по умолчанию.
final class JsonSettingsStore implements SettingsStore {
  JsonSettingsStore(this.filePath);

  final String filePath;

  @override
  Future<AppSettings> load() async {
    final file = File(filePath);
    if (!await file.exists()) return const AppSettings();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return AppSettings.fromJson(decoded);
    } on FormatException {
      // Повреждённый файл: перезапишется при следующем сохранении.
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final temporary = File('$filePath.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await temporary.rename(filePath);
  }
}
