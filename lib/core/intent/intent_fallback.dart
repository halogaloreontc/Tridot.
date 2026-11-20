import 'dart:typed_data';

import '../connectors/utterance.dart';
import '../passwords/secret_guard.dart';
import '../scenario/recognition_layers.dart';
import 'intent_encoder.dart';
import 'intent_index.dart';
import 'intent_memory.dart';
import 'intent_pack.dart';

export 'intent_encoder.dart';
export 'intent_index.dart';
export 'intent_memory.dart';
export 'intent_pack.dart';

/// Загруженная модель понимания: манифест, индекс примеров и кодировщик.
final class IntentModel {
  IntentModel({
    required this.manifest,
    required this.index,
    required this.encoder,
    double? threshold,
  }) : threshold = threshold ?? manifest.threshold;

  final IntentManifest manifest;
  final IntentIndex index;
  final IntentEncoder encoder;

  /// Порог сходства лучшего примера победившей метки (из манифеста).
  final double threshold;

  int get k => manifest.k;

  String get key => manifest.modelKey;
}

/// Один вариант подсказки: команда и сходство лучшего её примера.
final class IntentChoice {
  const IntentChoice(this.label, this.similarity);

  final IntentLabel label;
  final double similarity;

  /// `tasks:task.create`.
  String get id => label.id;
  String get connectorId => label.connectorId;
  String get commandId => label.commandId;
  String get description => label.description;
}

/// Подсказка запасного слоя: «Похоже, вы хотите [first]?» и, может быть,
/// [second]. Откалиброван только [first] (порог пакета); [second] — ещё
/// одна кнопка, если и её лучший пример не ниже порога.
final class IntentSuggestion {
  const IntentSuggestion({
    required this.text,
    required this.first,
    required this.vector,
    required this.modelKey,
    this.second,
    this.personal = false,
  });

  /// Фраза, которую не поняли правила.
  final String text;

  final IntentChoice first;
  final IntentChoice? second;

  /// [first] дал личный пример пользователя, а не корпус.
  final bool personal;

  /// Вектор [text]: «Да» и «Нет» запоминают его без нового прогона модели.
  final Float32List vector;
  final String modelKey;

  /// Уверенность — сходство лучшего примера [first].
  double get confidence => first.similarity;

  List<IntentChoice> get choices => <IntentChoice>[
        first,
        if (second != null) second!,
      ];
}

/// Вопрос «Похоже, вы хотите …?» в ленте: лежит в
/// [Clarification.context] ожидания маршрутизатора, только в памяти.
final class IntentOffer {
  const IntentOffer(this.suggestion);

  final IntentSuggestion suggestion;
}

/// Фраза для модели закрыта (ADR-041, п. 2) — та же проверка, что у
/// маршрутизатора ([RecognitionLayers.privateForModel]). Время разбора
/// неважно: смотрят только слова.
bool intentPrivate(String text, {FingerprintMatcher? knownSecret}) =>
    RecognitionLayers.privateForModel(
      text,
      analyze: (String t) => Utterance.analyze(t, now: _anyDay),
      knownSecret: knownSecret,
    );

final DateTime _anyDay = DateTime(2026);

/// Запасной слой понимания (ADR-041): когда правила сказали «не понял»,
/// по вектору фразы ищет ближайшие примеры корпуса и личные примеры
/// пользователя и предлагает команду — или молчит.
///
/// Правило подсказки:
/// 1. «Нет» пользователя ([IntentMemory.negatives]) снимает метку для
///    фраз, сходство которых с отвергнутой не ниже порога;
/// 2. личный пример «Да» ([IntentMemory.positives]) со сходством не ниже
///    порога побеждает сразу;
/// 3. иначе — голосование [IntentModel.k] ближайших (корпус и личные
///    примеры, голос — сходство): победила не `none`, навык доступен, и
///    сходство лучшего примера победившей метки не ниже порога пакета.
///    Победил выключенный или чужой навык — подсказки нет;
/// 4. второй вариант — следующая метка голосования с тем же условием.
///
/// Выключено «Учиться на моих ответах» — личные примеры не используются.
/// Приватные фразы ([blocks]) модель не видит вовсе.
final class IntentFallback {
  IntentFallback({
    this.model,
    IntentMemory? memory,
    bool Function(String text)? blocks,
  })  : blocks = blocks ?? intentPrivate,
        memory = memory ?? IntentMemory(blocks: blocks ?? intentPrivate);

  /// Модель; `null` — не скачана или выключена: подсказок нет, журнал
  /// непонятых ведётся.
  IntentModel? model;

  final IntentMemory memory;

  /// Вторая проверка приватности (первая — у маршрутизатора).
  final bool Function(String text) blocks;

  String? _refreshed;

  bool get ready => model != null;

  /// Подсказка для [text] или `null`. [connectors] — включённые навыки
  /// (`null` — любые), [exclude] — метки, которые правила уже выполнили
  /// (справочный вопрос беседы).
  Future<IntentSuggestion?> suggest(
    String text, {
    Set<String>? connectors,
    Set<String> exclude = const <String>{},
  }) async {
    final current = model;
    if (current == null || text.trim().isEmpty || blocks(text)) return null;
    await _refreshMemory(current);
    final vectors = await current.encoder.embed(<String>[text]);
    if (!identical(model, current) || vectors.length != 1) return null;
    return decide(
      text,
      vectors.single,
      current,
      connectors: connectors,
      exclude: exclude,
    );
  }

  /// Решение по готовому вектору [vector] — без модели, для тестов и
  /// инструментов.
  IntentSuggestion? decide(
    String text,
    Float32List vector,
    IntentModel model, {
    Set<String>? connectors,
    Set<String> exclude = const <String>{},
  }) {
    final index = model.index;
    final labels = index.labels;
    final threshold = model.threshold;
    final only = model.manifest.connectors;
    final personal = memory.learning
        ? _usable(memory.positives, model)
        : const <(IntentExample, int)>[];
    final refused = memory.learning
        ? _usable(memory.negatives, model)
        : const <(IntentExample, int)>[];
    final suppressed = <int>{
      for (final (example, label) in refused)
        if (IntentIndex.dot(example.vector!, 0, vector, index.dims) >=
            threshold)
          label,
    };
    bool allowed(int id) {
      final label = labels[id];
      return !label.isNone &&
          !suppressed.contains(id) &&
          !exclude.contains(label.id) &&
          (connectors == null || connectors.contains(label.connectorId)) &&
          (only.isEmpty || only.contains(label.connectorId));
    }

    IntentChoice? first;
    var fromPersonal = false;
    // Личный пример «Да» побеждает голосование.
    var bestSim = -1.0;
    int? bestLabel;
    for (final (example, label) in personal) {
      if (suppressed.contains(label)) continue;
      final sim = IntentIndex.dot(example.vector!, 0, vector, index.dims);
      if (sim > bestSim) {
        bestSim = sim;
        bestLabel = label;
      }
    }
    if (bestLabel != null && bestSim >= threshold && allowed(bestLabel)) {
      first = IntentChoice(labels[bestLabel], bestSim);
      fromPersonal = true;
    }
    final vote = index.vote(
      vector,
      model.k,
      extra: <IntentExtra>[
        for (final (example, label) in personal)
          IntentExtra(example.vector!, label),
      ],
    );
    final ranked = <int>[
      for (final label in vote.ranked)
        if (!suppressed.contains(label)) label,
    ];
    if (first == null) {
      if (ranked.isEmpty) return null;
      final top = ranked.first;
      if (!allowed(top) || vote.best[top]! < threshold) return null;
      first = IntentChoice(labels[top], vote.best[top]!);
    }
    IntentChoice? second;
    for (final label in ranked) {
      if (labels[label].id == first.id) continue;
      if (allowed(label) && vote.best[label]! >= threshold) {
        second = IntentChoice(labels[label], vote.best[label]!);
      }
      break;
    }
    return IntentSuggestion(
      text: text,
      first: first,
      second: second,
      vector: vector,
      modelKey: model.key,
      personal: fromPersonal,
    );
  }

  /// «Да» на вариант [choice]: личный пример и запись «исправлено» в
  /// журнале.
  Future<void> accepted(
    IntentSuggestion suggestion,
    IntentChoice choice,
  ) async {
    await memory.remember(
      suggestion.text,
      choice.id,
      vector: suggestion.vector,
      modelKey: suggestion.modelKey,
    );
    await memory.note(
      suggestion.text,
      UnclearKind.accepted,
      label: choice.id,
    );
  }

  /// «Нет»: отрицательные примеры для всех предложенных меток и запись в
  /// журнале.
  Future<void> rejected(IntentSuggestion suggestion) async {
    await memory.reject(
      suggestion.text,
      <String>[for (final choice in suggestion.choices) choice.id],
      vector: suggestion.vector,
      modelKey: suggestion.modelKey,
    );
    await memory.note(
      suggestion.text,
      UnclearKind.rejected,
      label: suggestion.first.id,
    );
  }

  /// Правила не поняли, подсказки нет: запись в журнале.
  Future<void> unclear(String text) => memory.note(text, UnclearKind.unknown);

  /// Личные примеры с вектором этой модели и меткой из её индекса.
  static List<(IntentExample, int)> _usable(
    List<IntentExample> examples,
    IntentModel model,
  ) =>
      <(IntentExample, int)>[
        for (final example in examples)
          if (example.vector != null &&
              example.modelKey == model.key &&
              example.vector!.length == model.index.dims)
            if (model.index.labels.indexOf(example.label) case final int id)
              (example, id),
      ];

  /// Примеры, посчитанные другой моделью (или без вектора), — заново,
  /// один раз на модель.
  Future<void> _refreshMemory(IntentModel model) async {
    if (_refreshed == model.key || !memory.learning) return;
    _refreshed = model.key;
    final stale = <IntentExample>[
      for (final example in memory.stale(model.key))
        if (!blocks(example.text)) example,
    ];
    if (stale.isEmpty) return;
    final vectors = await model.encoder.embed(<String>[
      for (final example in stale) example.text,
    ]);
    await memory.refresh(stale, vectors, model.key);
  }
}
