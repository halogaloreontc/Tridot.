import 'dart:io';
import 'dart:typed_data';

import '../../core/chats/attachments.dart';
import '../../core/gen/gen_model.dart';
import '../../core/jobs/extension_card.dart';
import 'llama_gen_model.dart';

/// «Продвинутая» в приложении (ADR-046, шаг 2): откуда модель и как навык
/// «Таблица» читает вложения.
///
/// Модель пока — только для разработки: `TRIDOT_GEN_MODEL` (переменная
/// окружения или `--dart-define`) — путь к GGUF; библиотека обёртки —
/// `TRIDOT_LLAMA_LIB` или имя по платформе. Скачивание и настройки —
/// следующий шаг. Модель загружается при первом вопросе и остаётся в
/// памяти.
final class GenSetup {
  GenSetup({required this.attachments});

  final AttachmentStore attachments;

  Future<GenModel?>? _model;

  static String? _env(String name, String defined) {
    if (defined.isNotEmpty) return defined;
    final value = Platform.environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  static String? get devModelPath => _env(
        'TRIDOT_GEN_MODEL',
        const String.fromEnvironment('TRIDOT_GEN_MODEL'),
      );

  static String? get libraryPath => _env(
        'TRIDOT_LLAMA_LIB',
        const String.fromEnvironment('TRIDOT_LLAMA_LIB'),
      );

  /// Модель или `null`: нет файла, библиотеки или не загрузилась.
  Future<GenModel?> model() => _model ??= _open();

  Future<GenModel?> _open() async {
    final path = devModelPath;
    if (path == null || !File(path).existsSync()) return null;
    try {
      return await LlamaGenModel.open(path, library: libraryPath);
    } on GenModelException {
      _model = null;
      return null;
    }
  }

  /// Байты вложения или файла с диска; больше [maxBytes] — `null`.
  static const int maxBytes = 5 * 1024 * 1024;

  Future<Uint8List?> read(JobFile file) async {
    final path =
        file.attachment ? attachments.pathOfRelative(file.path) : file.path;
    if (path == null) return null;
    try {
      final f = File(path);
      if (await f.length() > maxBytes) return null;
      return await f.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }
}
