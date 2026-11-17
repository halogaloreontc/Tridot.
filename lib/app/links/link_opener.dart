import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/jobs/extension_card.dart';
import '../../core/skills/weather/weather_settings.dart';
import '../files/file_opener.dart';

export '../files/file_opener.dart' show ProcessStarter;

/// Короткий запуск процесса с ответом: проверка, есть ли программа.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Открывает страницу в браузере и приложение погоды (ADR-030).
///
/// Перед каждым открытием адрес снова проверяется: только https
/// ([WeatherLink.safe]). На компьютере — системная программа отдельным
/// процессом, со списком аргументов и без оболочки (`xdg-open`, на Windows
/// `rundll32 url.dll,FileProtocolHandler`: `explorer` теряет параметры
/// адреса). На Android и Mac — свой канал `tridot/links`.
final class LinkOpener {
  LinkOpener({
    required this.platform,
    ProcessStarter? start,
    ProcessRunner? run,
    MethodChannel? channel,
  })  : _start = start ?? _defaultStart,
        _run = run ?? _defaultRun,
        _channel = channel ?? const MethodChannel('tridot/links');

  final JobPlatform platform;
  final ProcessStarter _start;
  final ProcessRunner _run;
  final MethodChannel _channel;

  /// «Погода» на Mac (macOS 13+).
  static const String macWeather = 'com.apple.weather';

  /// «Погода MSN» на Windows — по своей схеме адреса.
  static const String msnWeather = 'msnweather';

  static Future<Process> _defaultStart(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) =>
      Process.start(
        executable,
        arguments,
        runInShell: runInShell,
        mode: mode,
      );

  static Future<ProcessResult> _defaultRun(
    String executable,
    List<String> arguments,
  ) =>
      Process.run(executable, arguments, runInShell: false);

  bool get _viaChannel =>
      platform == JobPlatform.android || platform == JobPlatform.macos;

  /// Команда «открыть адрес в браузере» для [platform] или `null`.
  static (String, List<String>)? urlArgv(JobPlatform platform, String url) =>
      switch (platform) {
        JobPlatform.linux => ('xdg-open', <String>[url]),
        JobPlatform.windows => (
            'rundll32',
            <String>['url.dll,FileProtocolHandler', url],
          ),
        _ => null,
      };

  /// Открыть [url] в браузере. `false` — адрес не https или открыть нечем.
  Future<bool> openUrl(String url) async {
    if (!WeatherLink.safe(url)) return false;
    if (_viaChannel) {
      return _invoke('openUrl', <String, Object?>{'url': url});
    }
    return _detached(urlArgv(platform, url));
  }

  /// Бывает ли здесь «Приложение погоды».
  bool get supportsApps =>
      platform == JobPlatform.android ||
      platform == JobPlatform.macos ||
      platform == JobPlatform.windows;

  /// «Другое приложение…» — системный выбор (только Android).
  bool get canPickApp => platform == JobPlatform.android;

  /// Приложения погоды, которые есть на устройстве: на Android — из
  /// списка известных пакетов, на Mac — «Погода», на Windows — «Погода
  /// MSN», если она установлена.
  Future<List<WeatherApp>> weatherApps() async {
    if (_viaChannel) {
      try {
        final list = await _channel.invokeListMethod<Object?>('weatherApps');
        return <WeatherApp>[
          for (final item in list ?? const <Object?>[])
            if (WeatherApp.fromJson(item) case final WeatherApp app) app,
        ];
      } on Object {
        return const <WeatherApp>[];
      }
    }
    if (platform == JobPlatform.windows) {
      try {
        final result = await _run(
          'reg',
          <String>['query', r'HKEY_CLASSES_ROOT\msnweather'],
        );
        if (result.exitCode == 0) {
          return const <WeatherApp>[
            WeatherApp(id: msnWeather, label: 'Погода MSN'),
          ];
        }
      } on Object {
        // Нет reg.exe — пункта нет.
      }
    }
    return const <WeatherApp>[];
  }

  /// Системный выбор приложения (Android); `null` — не выбрали.
  Future<WeatherApp?> pickApp() async {
    if (!canPickApp) return null;
    try {
      final picked = await _channel.invokeMethod<Object?>('pickApp');
      return WeatherApp.fromJson(picked);
    } on Object {
      return null;
    }
  }

  /// Открыть приложение [id]. `false` — не открылось (удалили).
  Future<bool> openApp(String id) async {
    if (id.isEmpty || id.length > 200) return false;
    if (_viaChannel) {
      return _invoke('openApp', <String, Object?>{'package': id});
    }
    if (platform == JobPlatform.windows && id == msnWeather) {
      return _detached(
        (
          'rundll32',
          const <String>['url.dll,FileProtocolHandler', '$msnWeather:']
        ),
      );
    }
    return false;
  }

  Future<bool> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on Object {
      return false;
    }
  }

  Future<bool> _detached((String, List<String>)? argv) async {
    if (argv == null) return false;
    try {
      await _start(
        argv.$1,
        argv.$2,
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on Object {
      return false;
    }
  }
}
