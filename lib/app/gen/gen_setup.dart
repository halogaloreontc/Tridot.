import 'dart:io';
import 'dart:typed_data';

import '../../core/chats/attachments.dart';
import '../../core/gen/gen_model.dart';
import '../../core/jobs/extension_card.dart';
import 'llama_gen_model.dart';

/// «Продвинутая» в приложении (ADR-046): как открыть модель и как навык
/// «Таблица» читает вложения. Скачивание и переключатель — `GenKit`.
///
/// Для разработки: `TRIDOT_GEN_MODEL` (переменная окружения или
/// `--dart-define`) — путь к GGUF, работает без загрузки; библиотека
/// обёртки — `TRIDOT_LLAMA_LIB` или имя по платформе.
final class GenSetup {
  GenSetup({required this.attachments});

  final AttachmentStore attachments;

  static String? _env(String name, String defined) {
    if (defined.isNotEmpty) return defined;
    final value = Platform.environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  static String? get devModelPath {
    final path = _env(
      'TRIDOT_GEN_MODEL',
      const String.fromEnvironment('TRIDOT_GEN_MODEL'),
    );
    return path != null && File(path).existsSync() ? path : null;
  }

  static String? get libraryPath => _env(
        'TRIDOT_LLAMA_LIB',
        const String.fromEnvironment('TRIDOT_LLAMA_LIB'),
      );

  /// Модель из файла GGUF или `null`: нет библиотеки, не загрузилась.
  static Future<GenModel?> open(String path) async {
    try {
      return await LlamaGenModel.open(path, library: libraryPath);
    } on GenModelException {
      return null;
    }
  }

  /// Вложение больше этого не читается.
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
