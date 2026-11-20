import 'dart:convert';
import 'dart:typed_data';

import '../services/clock.dart';

/// Личный пример запасного слоя (ADR-045, п. 7): фраза пользователя и
/// команда, которую он подтвердил «Да» ([IntentMemory.positives]) или
/// отверг «Нет» ([IntentMemory.negatives]). Только на устройстве.
final class IntentExample {
  const IntentExample({
    required this.text,
    required this.label,
    required this.at,
    this.vector,
    this.modelKey,
  });

  factory IntentExample.fromJson(Map<String, Object?> json) => IntentExample(
        text: json['text']! as String,
        label: json['label']! as String,
        at: DateTime.parse(json['at']! as String),
        modelKey: json['model'] as String?,
        vector: switch (json['vector']) {
          final String encoded => decodeVector(encoded),
          _ => null,
        },
      );

  /// Фраза, как её написал пользователь: показывается в настройках, по ней
  /// пример пересчитывается для новой модели.
  final String text;

  /// Метка `<навык>:<команда>`.
  final String label;

  final DateTime at;

  /// Вектор фразы моделью [modelKey]; `null` — ещё не посчитан.
  final Float32List? vector;

  /// [IntentManifest.modelKey] модели, посчитавшей [vector].
  final String? modelKey;

  IntentExample withVector(Float32List vector, String modelKey) =>
      IntentExample(
        text: text,
        label: label,
        at: at,
        vector: vector,
        modelKey: modelKey,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'label': label,
        'at': at.toUtc().toIso8601String(),
        if (modelKey != null) 'model': modelKey,
        if (vector != null) 'vector': encodeVector(vector!),
      };

  /// float32 little-endian в base64: компактно и одинаково в вебе.
  static String encodeVector(Float32List vector) {
    final data = ByteData(vector.length * 4);
    for (var i = 0; i < vector.length; i++) {
      data.setFloat32(i * 4, vector[i], Endian.little);
    }
    return base64.encode(data.buffer.asUint8List());
  }

  static Float32List decodeVector(String encoded) {
    final bytes = base64.decode(encoded);
    final data = ByteData.sublistView(bytes);
    return Float32List.fromList(<double>[
      for (var i = 0; i + 4 <= bytes.length; i += 4)
        data.getFloat32(i, Endian.little),
    ]);
  }
}

/// Что случилось с фразой в журнале непонятых.
enum UnclearKind {
  /// Правила не поняли, подсказки не было.
  unknown,

  /// Подсказку отвергли «Нет».
  rejected,

  /// Подсказку приняли «Да»: фраза, которую правила не поняли, а модель
  /// исправила.
  accepted,
}

/// Запись журнала «Непонятые фразы» (ADR-045, п. 8).
final class UnclearPhrase {
  const UnclearPhrase({
    required this.text,
    required this.at,
    required this.kind,
    this.label,
  });

  factory UnclearPhrase.fromJson(Map<String, Object?> json) => UnclearPhrase(
        text: json['text']! as String,
        at: DateTime.parse(json['at']! as String),
        kind: UnclearKind.values.byName(json['kind']! as String),
        label: json['label'] as String?,
      );

  final String text;
  final DateTime at;
  final UnclearKind kind;

  /// Предложенная (и принятая или отвергнутая) метка.
  final String? label;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'at': at.toUtc().toIso8601String(),
        'kind': kind.name,
        if (label != null) 'label': label,
      };
}

/// Где лежит память запасного слоя: JSON-файл приложения
/// (`intent_memory_io.dart`), хранилище браузера веб-помощника (шаг 4),
/// память в тестах.
abstract interface class IntentMemoryStore {
  /// Сохранённое или `null`, если ничего нет (или файл повреждён).
  Future<Map<String, Object?>?> load();

  Future<void> save(Map<String, Object?> json);
}

final class InMemoryIntentMemoryStore implements IntentMemoryStore {
  Map<String, Object?>? value;

  /// Сколько раз сохраняли: тесты проверяют, что ничего не писалось.
  int saves = 0;

  @override
  Future<Map<String, Object?>?> load() async => value;

  @override
  Future<void> save(Map<String, Object?> json) async {
    saves++;
    // Копия через JSON: как у файла, без общих ссылок.
    value = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  }
}

/// Память запасного слоя на устройстве (ADR-045, пп. 7–8): переключатели
/// «Учиться на моих ответах» и «Собирать непонятые фразы» (оба включены по
/// умолчанию), личные примеры и журнал непонятых фраз.
///
/// Приватных фраз здесь не бывает: маршрутизатор не передаёт их сюда
/// (`RecognitionLayers.privateForModel`), а [blocks] — вторая проверка на
/// месте. Ничего отсюда не уходит с устройства.
final class IntentMemory {
  IntentMemory({
    IntentMemoryStore? store,
    this.clock = const SystemClock(),
    this.blocks,
  }) : store = store ?? InMemoryIntentMemoryStore();

  final IntentMemoryStore store;
  final Clock clock;

  /// Вторая проверка приватности: `true` — фразу не запоминать.
  final bool Function(String text)? blocks;

  /// Записей журнала не больше.
  static const int maxUnclear = 200;

  /// Записи журнала старше удаляются сами.
  static const Duration unclearAge = Duration(days: 90);

  /// Личных примеров каждого вида не больше: старые уходят.
  static const int maxExamples = 500;

  bool _learning = true;
  bool _logging = true;
  final List<IntentExample> _positives = <IntentExample>[];
  final List<IntentExample> _negatives = <IntentExample>[];
  final List<UnclearPhrase> _unclear = <UnclearPhrase>[];

  /// «Учиться на моих ответах»: выключено — новые примеры не сохраняются,
  /// а сохранённые не используются.
  bool get learning => _learning;

  /// «Собирать непонятые фразы».
  bool get logging => _logging;

  List<IntentExample> get positives => List.unmodifiable(_positives);
  List<IntentExample> get negatives => List.unmodifiable(_negatives);

  /// Журнал, новые первыми; старше [unclearAge] уже нет.
  List<UnclearPhrase> get unclear {
    _prune();
    return List.unmodifiable(_unclear);
  }

  Future<void> load() async {
    final json = await store.load();
    if (json == null) return;
    try {
      _learning = json['learning'] as bool? ?? true;
      _logging = json['logging'] as bool? ?? true;
      List<T> items<T>(String key, T Function(Map<String, Object?>) read) => [
            for (final item in (json[key] as List<Object?>?) ?? const [])
              if (item is Map<String, Object?>) read(item),
          ];
      _positives
        ..clear()
        ..addAll(items('positives', IntentExample.fromJson));
      _negatives
        ..clear()
        ..addAll(items('negatives', IntentExample.fromJson));
      _unclear
        ..clear()
        ..addAll(items('unclear', UnclearPhrase.fromJson))
        ..sort((UnclearPhrase a, UnclearPhrase b) => b.at.compareTo(a.at));
    } on Object {
      // Повреждённая память — как новая: перезапишется при сохранении.
      _positives.clear();
      _negatives.clear();
      _unclear.clear();
    }
    _prune();
  }

  Future<void> setLearning(bool value) async {
    if (_learning == value) return;
    _learning = value;
    await _save();
  }

  Future<void> setLogging(bool value) async {
    if (_logging == value) return;
    _logging = value;
    await _save();
  }

  /// «Да» на подсказку: [text] → [label] (если учиться разрешено).
  Future<void> remember(
    String text,
    String label, {
    Float32List? vector,
    String? modelKey,
  }) async {
    if (!_learning || _blocked(text)) return;
    _add(_positives, text, label, vector, modelKey);
    // Передумал: прежнее «Нет» той же фразе той же команды снимается.
    _negatives.removeWhere(
      (IntentExample e) => e.label == label && _same(e.text, text),
    );
    await _save();
  }

  /// «Нет» на подсказку: для похожих на [text] фраз [labels] больше не
  /// предлагаются (если учиться разрешено).
  Future<void> reject(
    String text,
    List<String> labels, {
    Float32List? vector,
    String? modelKey,
  }) async {
    if (!_learning || _blocked(text) || labels.isEmpty) return;
    for (final label in labels) {
      _add(_negatives, text, label, vector, modelKey);
      _positives.removeWhere(
        (IntentExample e) => e.label == label && _same(e.text, text),
      );
    }
    await _save();
  }

  /// Запись в журнал непонятых (если собирать разрешено). Та же фраза —
  /// одна запись, свежая.
  Future<void> note(String text, UnclearKind kind, {String? label}) async {
    if (!_logging || _blocked(text)) return;
    _unclear
      ..removeWhere((UnclearPhrase e) => _same(e.text, text))
      ..insert(
        0,
        UnclearPhrase(
          text: text.trim(),
          at: clock.now(),
          kind: kind,
          label: label,
        ),
      );
    _prune();
    await _save();
  }

  /// «Забыть выученное»: все личные примеры.
  Future<void> forgetLearned() async {
    if (_positives.isEmpty && _negatives.isEmpty) return;
    _positives.clear();
    _negatives.clear();
    await _save();
  }

  /// Сколько личных примеров («Да» и «Нет») — для «Забыть выученное».
  int get learnedCount => _positives.length + _negatives.length;

  /// Удалить одну запись журнала (та же фраза и время).
  Future<void> removeUnclear(UnclearPhrase phrase) async {
    final before = _unclear.length;
    _unclear.removeWhere(
      (UnclearPhrase e) =>
          identical(e, phrase) ||
          (e.at == phrase.at && _same(e.text, phrase.text)),
    );
    if (_unclear.length != before) await _save();
  }

  /// Очистить журнал непонятых.
  Future<void> clearUnclear() async {
    if (_unclear.isEmpty) return;
    _unclear.clear();
    await _save();
  }

  /// Примеры без вектора модели [modelKey]: их нужно посчитать заново.
  List<IntentExample> stale(String modelKey) => <IntentExample>[
        for (final e in <IntentExample>[..._positives, ..._negatives])
          if (e.modelKey != modelKey || e.vector == null) e,
      ];

  /// Векторы [examples] (из [stale]) посчитаны моделью [modelKey].
  Future<void> refresh(
    List<IntentExample> examples,
    List<Float32List> vectors,
    String modelKey,
  ) async {
    var changed = false;
    for (final (index, example) in examples.indexed) {
      for (final list in <List<IntentExample>>[_positives, _negatives]) {
        final at = list.indexWhere((IntentExample e) => identical(e, example));
        if (at < 0) continue;
        list[at] = example.withVector(vectors[index], modelKey);
        changed = true;
      }
    }
    if (changed) await _save();
  }

  bool _blocked(String text) =>
      text.trim().isEmpty || (blocks?.call(text) ?? false);

  void _add(
    List<IntentExample> list,
    String text,
    String label,
    Float32List? vector,
    String? modelKey,
  ) {
    list
      ..removeWhere(
        (IntentExample e) => e.label == label && _same(e.text, text),
      )
      ..add(
        IntentExample(
          text: text.trim(),
          label: label,
          at: clock.now(),
          vector: vector,
          modelKey: vector == null ? null : modelKey,
        ),
      );
    if (list.length > maxExamples) {
      list.removeRange(0, list.length - maxExamples);
    }
  }

  void _prune() {
    final oldest = clock.now().subtract(unclearAge);
    _unclear.removeWhere((UnclearPhrase e) => e.at.isBefore(oldest));
    if (_unclear.length > maxUnclear) {
      _unclear.removeRange(maxUnclear, _unclear.length);
    }
  }

  static bool _same(String a, String b) => _key(a) == _key(b);

  static String _key(String text) =>
      text.trim().toLowerCase().replaceAll('ё', 'е').replaceAll(_spaces, ' ');

  static final RegExp _spaces = RegExp(r'\s+');

  Future<void> _save() => store.save(<String, Object?>{
        'format': format,
        'learning': _learning,
        'logging': _logging,
        'positives': <Object?>[for (final e in _positives) e.toJson()],
        'negatives': <Object?>[for (final e in _negatives) e.toJson()],
        'unclear': <Object?>[for (final e in _unclear) e.toJson()],
      });

  static const String format = 'tridot-intent-memory/1';
}
