import 'dart:convert';
import 'dart:io';

import '../personas/persona.dart';

export '../personas/persona.dart';

/// Пользовательские настройки интерфейса.
final class AppSettings {
  const AppSettings({
    this.reduceMotion = false,
    this.showTimestamps = true,
    this.disabledExtensions = const <String>{},
    this.enabledExtensions = const <String>{},
    this.personas = const PersonaSettings(),
    this.noticeDay,
  });

  /// Неизвестные или неверного типа значения заменяются значениями по
  /// умолчанию: битые настройки не должны мешать запуску.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final reduceMotion = json['reduce_motion'];
    final showTimestamps = json['show_timestamps'];
    return AppSettings(
      reduceMotion: reduceMotion is bool && reduceMotion,
      showTimestamps: showTimestamps is! bool || showTimestamps,
      disabledExtensions: _ids(json['disabled_extensions']),
      enabledExtensions: _ids(json['enabled_extensions']),
      personas: PersonaSettings.fromJson(json),
      noticeDay: _day(json['notice_day']),
    );
  }

  /// День вида `2026-11-06` или `null`.
  static String? _day(Object? value) =>
      value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
          ? value
          : null;

  /// [day] в виде `2026-11-06`.
  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Список id: не список — пусто, не строки и пустые строки пропускаются.
  static Set<String> _ids(Object? value) {
    if (value is! List) return const <String>{};
    return <String>{
      for (final item in value)
        if (item is String && item.trim().isNotEmpty && item.length <= 64)
          item.trim(),
    };
  }

  /// Не анимировать кубик и переходы, даже если система разрешает.
  final bool reduceMotion;

  /// Показывать время под сообщениями чата.
  final bool showTimestamps;

  /// Выключенные расширения из включённых по умолчанию
  /// (docs/EXTENSIONS.md). Новое расширение, включённое по умолчанию,
  /// сюда не попадает и после обновления появляется включённым.
  final Set<String> disabledExtensions;

  /// Явно включённые расширения из выключенных по умолчанию.
  final Set<String> enabledExtensions;

  /// Помощники: дуэт или соло, кто основной, стили, «вы»/«ты», эмодзи.
  final PersonaSettings personas;

  /// Служебное: день, когда второй помощник уже написал о просроченных
  /// задачах (`2026-11-06`). Не чаще раза в день, и смена настроек
  /// помощников не повторяет сообщение.
  final String? noticeDay;

  AppSettings copyWith({
    bool? reduceMotion,
    bool? showTimestamps,
    Set<String>? disabledExtensions,
    Set<String>? enabledExtensions,
    PersonaSettings? personas,
    String? noticeDay,
  }) =>
      AppSettings(
        reduceMotion: reduceMotion ?? this.reduceMotion,
        showTimestamps: showTimestamps ?? this.showTimestamps,
        disabledExtensions: disabledExtensions ?? this.disabledExtensions,
        enabledExtensions: enabledExtensions ?? this.enabledExtensions,
        personas: personas ?? this.personas,
        noticeDay: noticeDay ?? this.noticeDay,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'reduce_motion': reduceMotion,
        'show_timestamps': showTimestamps,
        'disabled_extensions': disabledExtensions.toList()..sort(),
        'enabled_extensions': enabledExtensions.toList()..sort(),
        ...personas.toJson(),
        if (noticeDay != null) 'notice_day': noticeDay,
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
  Future<void> _writes = Future<void>.value();

  @override
  Future<AppSettings> load() async {
    final file = File(filePath);
    if (!await file.exists()) return const AppSettings();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return AppSettings.fromJson(decoded);
    } on Object {
      // Повреждённый или нечитаемый файл: перезапишется при сохранении.
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) {
    final write = _writes.then((_) => _write(settings));
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> _write(AppSettings settings) async {
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
