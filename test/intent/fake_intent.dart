import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:local_assistant/core/intent/intent_fallback.dart';

/// Метки поддельной модели: `none` — номер 0.
final IntentLabels fakeLabels = IntentLabels(const <IntentLabel>[
  IntentLabel(id: IntentLabel.none),
  IntentLabel(
    id: 'tasks:task.create',
    connectorId: 'tasks',
    commandId: 'task.create',
    description: 'создать задачу или напоминание',
  ),
  IntentLabel(
    id: 'tasks:task.list',
    connectorId: 'tasks',
    commandId: 'task.list',
    description: 'посмотреть список задач',
  ),
  IntentLabel(
    id: 'calc:calc.evaluate',
    connectorId: 'calc',
    commandId: 'calc.evaluate',
    description: 'посчитать на калькуляторе',
  ),
  IntentLabel(
    id: 'weather:weather.now',
    connectorId: 'weather',
    commandId: 'weather.now',
    description: 'узнать погоду сейчас',
  ),
  IntentLabel(
    id: 'talk:talk.setting',
    connectorId: 'talk',
    commandId: 'talk.setting',
    description: 'изменить, как я общаюсь',
  ),
  IntentLabel(
    id: 'talk:talk.question',
    connectorId: 'talk',
    commandId: 'talk.question',
    description: 'задать справочный вопрос',
  ),
]);

/// Оси векторов: у каждой метки своя (dims = число меток).
int get fakeDims => fakeLabels.length;

/// Нормированный вектор из весов по меткам: `{'tasks:task.create': 1}`.
Float32List fakeVector(Map<String, double> weights) {
  final v = Float32List(fakeDims);
  for (final MapEntry(:key, :value) in weights.entries) {
    v[fakeLabels.indexOf(key)!] = value;
  }
  var norm = 0.0;
  for (final x in v) {
    norm += x * x;
  }
  norm = math.sqrt(norm);
  for (var i = 0; i < v.length; i++) {
    v[i] = v[i] / norm;
  }
  return v;
}

/// Индекс: по [perLabel] примеров на каждую ось.
IntentIndex fakeIndex({int perLabel = 5}) {
  final vectors = <double>[];
  final ids = <int>[];
  for (var label = 0; label < fakeLabels.length; label++) {
    for (var i = 0; i < perLabel; i++) {
      vectors.addAll(fakeVector(<String, double>{fakeLabels[label].id: 1}));
      ids.add(label);
    }
  }
  return IntentIndex(
    vectors: Float32List.fromList(vectors),
    labelIds: Uint16List.fromList(ids),
    dims: fakeDims,
    labels: fakeLabels,
  );
}

IntentManifest fakeManifest({
  double threshold = 0.9,
  List<String> connectors = const <String>[],
  String version = '0.0.1',
}) =>
    IntentManifest(
      tier: 'light',
      version: version,
      threshold: threshold,
      k: 5,
      dims: fakeDims,
      maxLength: 64,
      inputs: const <String>['input_ids', 'attention_mask'],
      files: const <String, IntentPackFile>{},
      connectors: connectors,
    );

/// Кодировщик по таблице: фраза → вектор; остальные — «не команда».
/// Запоминает всё, что ему показали.
final class FakeEncoder implements IntentEncoder {
  FakeEncoder(this.table);

  final Map<String, Float32List> table;
  final List<String> seen = <String>[];
  bool fail = false;
  bool closed = false;

  @override
  int get dims => fakeDims;

  @override
  Future<List<Float32List>> embed(List<String> texts) async {
    seen.addAll(texts);
    if (fail) throw StateError('модель сломалась');
    return <Float32List>[
      for (final text in texts)
        table[text] ?? fakeVector(const <String, double>{IntentLabel.none: 1}),
    ];
  }

  @override
  Future<void> close() async => closed = true;
}

IntentModel fakeModel(
  FakeEncoder encoder, {
  double threshold = 0.9,
  List<String> connectors = const <String>[],
  String version = '0.0.1',
  int perLabel = 5,
}) =>
    IntentModel(
      manifest: fakeManifest(
        threshold: threshold,
        connectors: connectors,
        version: version,
      ),
      index: fakeIndex(perLabel: perLabel),
      encoder: encoder,
    );

/// labels.json поддельной модели.
String fakeLabelsJson() => jsonEncode(<String, Object?>{
      'format': 'tridot-intent/1',
      'question': 'Похоже, вы хотите {description}?',
      'labels': <Object?>[
        for (final label in fakeLabels.labels)
          if (label.isNone)
            <String, Object?>{'id': label.id}
          else
            <String, Object?>{
              'id': label.id,
              'connector': label.connectorId,
              'command': label.commandId,
              'description': label.description,
            },
      ],
    });
