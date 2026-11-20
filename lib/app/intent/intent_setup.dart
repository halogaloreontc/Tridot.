import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/intent/intent_fallback.dart';
import '../../core/intent/intent_io.dart';
import '../../core/passwords/secret_guard.dart';
import '../../core/services/clock.dart';
import 'intent_kit.dart' show IntentModelHost;
import 'onnx_intent_encoder.dart';

/// Запасной слой понимания в приложении (ADR-045): память в
/// `<поддержка>/assistant/intent/memory.json`, модель — из распакованного
/// пакета.
///
/// Где пакет:
/// 1. `TRIDOT_INTENT_PACK` — папка распакованного пакета: переменная
///    окружения (рабочий стол) или `--dart-define=TRIDOT_INTENT_PACK=…`
///    (телефон) — для разработки и проверки, загружается при любом уровне;
/// 2. скачанный уровень: `<поддержка>/assistant/intent/<уровень>-<версия>/`
///    по указателю `active.json` — выбирает и ставит [IntentKit] (шаг 3);
/// 3. `<поддержка>/assistant/intent/active/` — пакет, положенный руками.
///
/// Нет пакета — слой работает без модели: ответы правил те же, журнал
/// непонятых ведётся.
final class IntentSetup implements IntentModelHost {
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

  @override
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

  @override
  String? get devPack {
    final dir = devPackDir;
    return dir != null && DirectoryPackSource(dir).exists ? dir : null;
  }

  @override
  Future<bool> load(String dir) async => await loadModel(dir) != null;

  @override
  Future<void> unload() => unloadModel();

  /// Загрузить модель из [path]. Индекс разбирается в отдельном изоляте,
  /// модель живёт в своём; прежняя модель закрывается. Ошибка пакета —
  /// `null`, прежняя модель остаётся.
  Future<IntentModel?> loadModel(String path) async {
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
