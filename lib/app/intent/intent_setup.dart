import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/intent/intent_fallback.dart';
import '../../core/intent/intent_io.dart';
import '../../core/passwords/secret_guard.dart';
import '../../core/services/clock.dart';
import 'onnx_intent_encoder.dart';

/// Запасной слой понимания в приложении (ADR-041): память в
/// `<поддержка>/assistant/intent/memory.json`, модель — из распакованного
/// пакета.
///
/// Где пакет (шаг 2 — без скачивания, шаг 3 добавит выбор уровня):
/// 1. `TRIDOT_INTENT_PACK` — папка распакованного пакета: переменная
///    окружения (рабочий стол) или `--dart-define=TRIDOT_INTENT_PACK=…`
///    (телефон) — для разработки и проверки;
/// 2. `<поддержка>/assistant/intent/active/` — туда шаг 3 поставит
///    выбранный уровень.
///
/// Нет пакета — слой работает без модели: ответы правил те же, журнал
/// непонятых ведётся.
final class IntentSetup {
  IntentSetup._(this.fallback, this.root);

  /// Память и слой без модели; модель — [loadModel].
  static Future<IntentSetup> open(
    String supportDir, {
    FingerprintMatcher? knownSecret,
    Clock clock = const SystemClock(),
  }) async {
    final root = p.join(supportDir, 'assistant', 'intent');
    bool blocks(String text) => intentPrivate(text, knownSecret: knownSecret);
    final memory = IntentMemory(
      store: JsonIntentMemoryStore(p.join(root, 'memory.json')),
      clock: clock,
      blocks: blocks,
    );
    await memory.load();
    return IntentSetup._(IntentFallback(memory: memory, blocks: blocks), root);
  }

  final IntentFallback fallback;

  /// `<поддержка>/assistant/intent`.
  final String root;

  /// Папка пакета для разработки (см. описание класса).
  static String? get devPackDir {
    const defined = String.fromEnvironment('TRIDOT_INTENT_PACK');
    if (defined.isNotEmpty) return defined;
    final env = Platform.environment['TRIDOT_INTENT_PACK'];
    return env == null || env.isEmpty ? null : env;
  }

  /// Папка пакета, который нужно загрузить, или `null`.
  String? get packDir {
    for (final dir in <String?>[devPackDir, p.join(root, 'active')]) {
      if (dir != null && DirectoryPackSource(dir).exists) return dir;
    }
    return null;
  }

  /// Загрузить модель из [dir] (по умолчанию — [packDir]). Индекс
  /// разбирается в отдельном изоляте, модель живёт в своём. Ошибка пакета
  /// — модели нет, слой работает без неё; прежняя модель закрывается.
  Future<IntentModel?> loadModel([String? dir]) async {
    final path = dir ?? packDir;
    if (path == null) return null;
    try {
      final pack = await Isolate.run(
        () => IntentPack.load(DirectoryPackSource(path)),
        debugName: 'intent-index',
      );
      final encoder = await OnnxIntentEncoder.open(path, pack.manifest);
      final model = IntentModel(
        manifest: pack.manifest,
        index: pack.index,
        encoder: encoder,
      );
      final old = fallback.model;
      fallback.model = model;
      await old?.encoder.close();
      return model;
    } on Object {
      return null;
    }
  }

  /// Выгрузить модель (уровень «Выключено»).
  Future<void> unloadModel() async {
    final old = fallback.model;
    fallback.model = null;
    await old?.encoder.close();
  }
}
