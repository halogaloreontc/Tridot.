import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'tool_kit.dart';

/// Загрузчик видео (ADR-024, шаг 3): программа yt-dlp ([tool]) и папка
/// загрузок. По умолчанию — `<Загрузки>/Tridot`; другую папку выбирают в
/// «Настройки → Расширения → Загрузчик видео → Настроить», выбор хранится
/// в [settingsPath] (только путь папки — ссылки не хранятся нигде).
final class YtdlKit extends ChangeNotifier {
  YtdlKit({
    required this.tool,
    required this.settingsPath,
    required this.defaultRoot,
  });

  final ToolKit tool;

  /// Файл настроек загрузчика (`ytdl.json`).
  final String settingsPath;

  /// Системная папка загрузок или `null` (не найдена).
  final Future<String?> Function() defaultRoot;

  /// Имя подпапки по умолчанию.
  static const String subfolder = 'Tridot';

  String? _custom;
  bool _disposed = false;

  /// Папка, выбранная пользователем, или `null` — по умолчанию.
  String? get customFolder => _custom;

  /// Читает выбранную папку; повреждённый файл — папка по умолчанию.
  Future<void> load() async {
    try {
      final file = File(settingsPath);
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      final folder = decoded is Map ? decoded['folder'] : null;
      _custom = folder is String && folder.isNotEmpty && p.isAbsolute(folder)
          ? folder
          : null;
    } on Object {
      _custom = null;
    }
    _notify();
  }

  /// Куда скачивать: выбранная папка или `<Загрузки>/Tridot`.
  Future<String?> folder() async {
    final custom = _custom;
    if (custom != null) return custom;
    final root = await defaultRoot();
    return root == null ? null : p.join(root, subfolder);
  }

  /// Новая папка загрузок; `null` — снова по умолчанию.
  Future<void> setFolder(String? path) async {
    _custom = path != null && p.isAbsolute(path) ? path : null;
    try {
      final file = File(settingsPath);
      await file.parent.create(recursive: true);
      final temp = File('$settingsPath.tmp');
      await temp.writeAsString(
        jsonEncode(<String, Object?>{if (_custom != null) 'folder': _custom}),
        flush: true,
      );
      await temp.rename(settingsPath);
    } on Object {
      // Не сохранилось — выбор действует до перезапуска.
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
