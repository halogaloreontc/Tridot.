import 'dart:io';

/// Файл [name] пакета уровня [tier], собранного локально (ADR-041, шаг 1),
/// или `null`: в CI пакетов нет, тесты с ними пропускаются.
///
/// Где искать: `TRIDOT_INTENT_PACKS/<уровень>/` (папка с распакованными
/// пакетами) или `tools/intent_model/out/<уровень>/model/` после сборки.
File? localPackFile(String tier, String name) {
  final root = Platform.environment['TRIDOT_INTENT_PACKS'];
  for (final path in <String>[
    if (root != null && root.isNotEmpty) '$root/$tier/$name',
    'tools/intent_model/out/$tier/model/$name',
  ]) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

/// Папка распакованного пакета [tier] (с `manifest.json`) или `null`.
Directory? localPackDir(String tier) {
  final root = Platform.environment['TRIDOT_INTENT_PACKS'];
  if (root == null || root.isEmpty) return null;
  final dir = Directory('$root/$tier');
  return File('${dir.path}/manifest.json').existsSync() ? dir : null;
}
