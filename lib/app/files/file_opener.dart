import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/jobs/extension_card.dart';

/// Запуск процесса: в тестах — подделка.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  bool runInShell,
  ProcessStartMode mode,
});

/// «Открыть» и «Открыть папку» под карточкой расширения.
///
/// На компьютере — системная программа отдельным процессом, со списком
/// аргументов и без оболочки (`xdg-open`, `explorer.exe`, `open`). На
/// Android — `tridot/files` в MainActivity: копия во временную папку и
/// FileProvider с правом только на чтение; «Открыть папку» там нет.
/// Путь вне [allowedRoots] (если они заданы) не открывается.
final class FileOpener {
  FileOpener({
    required this.platform,
    this.allowedRoots = const <String>[],
    ProcessStarter? start,
    MethodChannel? channel,
  })  : _start = start ?? _defaultStart,
        _channel = channel ?? const MethodChannel('tridot/files');

  final JobPlatform platform;

  /// Папки, внутри которых можно открывать файлы; пусто — любые
  /// (компьютер: результат лежит рядом с исходником).
  final List<String> allowedRoots;

  final ProcessStarter _start;
  final MethodChannel _channel;

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

  /// «Открыть папку» бывает только на компьютере.
  bool get canReveal => platform.isDesktop;

  /// Команда «открыть файл или папку» для [platform] или `null`.
  static (String, List<String>)? openArgv(JobPlatform platform, String path) =>
      switch (platform) {
        JobPlatform.linux => ('xdg-open', <String>[path]),
        JobPlatform.windows => ('explorer.exe', <String>[path]),
        JobPlatform.macos => ('open', <String>[path]),
        _ => null,
      };

  /// Команда «показать в папке» для [platform] или `null`.
  static (String, List<String>)? revealArgv(
    JobPlatform platform,
    String path,
  ) =>
      switch (platform) {
        JobPlatform.linux => (
            'xdg-open',
            <String>[
              FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path),
            ],
          ),
        JobPlatform.windows => ('explorer.exe', <String>['/select,$path']),
        JobPlatform.macos => ('open', <String>['-R', path]),
        _ => null,
      };

  /// Путь внутри разрешённых папок.
  bool allowed(String path) {
    if (allowedRoots.isEmpty) return true;
    final target = p.canonicalize(path);
    return allowedRoots.any(
      (String root) =>
          p.isWithin(p.canonicalize(root), target) ||
          p.equals(p.canonicalize(root), target),
    );
  }

  /// Открыть [path] в программе по умолчанию. `false` — не вышло.
  Future<bool> open(String path) async {
    if (!allowed(path)) return false;
    if (platform == JobPlatform.android) {
      try {
        return await _channel.invokeMethod<bool>(
              'open',
              <String, Object?>{'path': path},
            ) ??
            false;
      } on Object {
        return false;
      }
    }
    return _run(openArgv(platform, path));
  }

  /// Показать [path] в файловом менеджере (выделен, где это умеют).
  Future<bool> reveal(String path) async {
    if (!canReveal || !allowed(path)) return false;
    return _run(revealArgv(platform, path));
  }

  Future<bool> _run((String, List<String>)? argv) async {
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
