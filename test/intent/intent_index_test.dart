import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';

import 'fake_intent.dart';

/// float → fp16 (без субнормальных: в тестах только «обычные» числа).
int toHalf(double value) {
  final data = ByteData(4)..setFloat32(0, value);
  final bits = data.getUint32(0);
  final sign = (bits >> 16) & 0x8000;
  final exponent = ((bits >> 23) & 0xFF) - 127 + 15;
  final mantissa = (bits >> 13) & 0x3FF;
  if (value == 0) return sign;
  return sign | (exponent << 10) | mantissa;
}

Uint8List trix(List<List<double>> vectors, List<int> labels) {
  final dims = vectors.first.length;
  final data = ByteData(16 + vectors.length * dims * 2 + labels.length * 2);
  data
    ..setUint8(0, 0x54)
    ..setUint8(1, 0x52)
    ..setUint8(2, 0x49)
    ..setUint8(3, 0x58)
    ..setUint16(4, 1, Endian.little)
    ..setUint32(8, vectors.length, Endian.little)
    ..setUint32(12, dims, Endian.little);
  var at = 16;
  for (final v in vectors) {
    for (final x in v) {
      data.setUint16(at, toHalf(x), Endian.little);
      at += 2;
    }
  }
  for (final l in labels) {
    data.setUint16(at, l, Endian.little);
    at += 2;
  }
  return data.buffer.asUint8List();
}

final class MapSource implements IntentPackSource {
  MapSource(this.files);

  final Map<String, Uint8List> files;

  @override
  Future<Uint8List> read(String name) async =>
      files[name] ?? (throw IntentPackException('нет $name'));
}

void main() {
  group('fp16 и index.bin', () {
    test('половинная точность', () {
      expect(IntentIndex.halfToDouble(0x3C00), 1.0);
      expect(IntentIndex.halfToDouble(0xBC00), -1.0);
      expect(IntentIndex.halfToDouble(0x3800), 0.5);
      expect(IntentIndex.halfToDouble(0x0000), 0.0);
      expect(IntentIndex.halfToDouble(0x0001), closeTo(5.96e-8, 1e-9));
      expect(IntentIndex.halfToDouble(0x7C00), double.infinity);
      expect(IntentIndex.halfToDouble(0x7E00).isNaN, isTrue);
    });

    test('разбор TRIX: векторы, метки, ошибки формата', () {
      final labels = IntentLabels.parse(fakeLabelsJson());
      final bytes = trix(
        <List<double>>[
          <double>[1, 0, 0, 0, 0, 0],
          <double>[0, 0.5, 0, 0, 0, 0],
        ],
        <int>[1, 2],
      );
      final index = IntentIndex.parse(bytes, labels);
      expect(index.length, 2);
      expect(index.dims, 6);
      expect(index.vectors.sublist(0, 6), <double>[1, 0, 0, 0, 0, 0]);
      expect(index.vectors[7], 0.5);
      expect(index.labelIds, <int>[1, 2]);
      expect(
        () =>
            IntentIndex.parse(Uint8List.fromList(utf8.encode('XXXX')), labels),
        throwsFormatException,
      );
      expect(
        () => IntentIndex.parse(bytes.sublist(0, bytes.length - 1), labels),
        throwsFormatException,
      );
      final badLabel = trix(<List<double>>[
        <double>[1, 0, 0, 0, 0, 0],
      ], <int>[
        99,
      ]);
      expect(() => IntentIndex.parse(badLabel, labels), throwsFormatException);
    });

    test('labels.json: номер 0 — none', () {
      final labels = IntentLabels.parse(fakeLabelsJson());
      expect(labels[0].isNone, isTrue);
      expect(labels.byId('calc:calc.evaluate')!.description, isNotEmpty);
      expect(
        () => IntentLabels.parse('{"labels":[{"id":"tasks:task.create"}]}'),
        throwsFormatException,
      );
    });
  });

  group('kNN', () {
    test('голос — сумма сходств, лучший пример, второе место', () {
      final index = fakeIndex(perLabel: 2);
      final query = fakeVector(<String, double>{
        'tasks:task.create': 0.8,
        'tasks:task.list': 0.6,
      });
      final vote = index.vote(query, 5);
      expect(fakeLabels[vote.winner].id, 'tasks:task.create');
      expect(vote.similarity, closeTo(0.8, 1e-6));
      expect(fakeLabels[vote.second!].id, 'tasks:task.list');
      expect(vote.best[vote.second!], closeTo(0.6, 1e-6));
    });

    test('ничья — по id метки, как в knn.py; k больше примеров', () {
      final index = fakeIndex(perLabel: 1);
      final query = fakeVector(<String, double>{
        'tasks:task.list': 1,
        'calc:calc.evaluate': 1,
      });
      final vote = index.vote(query, 50);
      expect(fakeLabels[vote.winner].id, 'calc:calc.evaluate');
    });

    test('личные примеры голосуют вместе с корпусом', () {
      final index = fakeIndex(perLabel: 1);
      final query = fakeVector(<String, double>{'tasks:task.list': 1});
      final calc = fakeLabels.indexOf('calc:calc.evaluate')!;
      final vote = index.vote(
        query,
        3,
        extra: <IntentExtra>[
          IntentExtra(query, calc),
          IntentExtra(query, calc),
        ],
      );
      expect(vote.winner, calc);
      expect(
        () => index.vote(Float32List(2), 3),
        throwsArgumentError,
      );
    });
  });

  group('манифест и пакет', () {
    Map<String, Object?> manifestJson(Map<String, Uint8List> files) =>
        <String, Object?>{
          'format': 'tridot-intent/1',
          'tier': 'light',
          'title': 'Лёгкая',
          'version': '0.1.0',
          'threshold': 0.91,
          'k': 5,
          'dims': 6,
          'max_length': 64,
          'inputs': <String>['input_ids', 'attention_mask', 'token_type_ids'],
          'output': 'embedding',
          'prefix': '',
          'connectors': <String>[],
          'files': <String, Object?>{
            for (final MapEntry(:key, :value) in files.entries)
              key: <String, Object?>{
                'size': value.length,
                'sha256': crypto.sha256.convert(value).toString(),
              },
          },
        };

    Map<String, Uint8List> packFiles() => <String, Uint8List>{
          'model.int8.onnx': Uint8List.fromList(<int>[1, 2, 3]),
          'index.bin': trix(<List<double>>[
            <double>[1, 0, 0, 0, 0, 0],
          ], <int>[
            1,
          ]),
          'labels.json': Uint8List.fromList(utf8.encode(fakeLabelsJson())),
          'tokenizer.json': Uint8List.fromList(utf8.encode('{}')),
        };

    test('разбор и загрузка с проверкой sha256', () async {
      final files = packFiles();
      final manifest = IntentManifest.parse(jsonEncode(manifestJson(files)));
      expect(manifest.modelKey, 'light@0.1.0');
      expect(manifest.threshold, 0.91);
      expect(manifest.inputs, contains('token_type_ids'));
      final pack = await IntentPack.load(
        MapSource(<String, Uint8List>{
          ...files,
          'manifest.json':
              Uint8List.fromList(utf8.encode(jsonEncode(manifestJson(files)))),
        }),
      );
      expect(pack.index.length, 1);
    });

    test('подменённый файл, чужой формат, нет обязательного файла', () async {
      final files = packFiles();
      final json = manifestJson(files);
      final tampered = <String, Uint8List>{
        ...files,
        'labels.json': Uint8List.fromList(
          utf8.encode(fakeLabelsJson().replaceFirst('задачу', 'задачи')),
        ),
        'manifest.json': Uint8List.fromList(utf8.encode(jsonEncode(json))),
      };
      await expectLater(
        IntentPack.load(MapSource(tampered)),
        throwsA(isA<IntentPackException>()),
      );
      expect(
        () => IntentManifest.parse(
          jsonEncode(<String, Object?>{...json, 'format': 'other/1'}),
        ),
        throwsA(isA<IntentPackException>()),
      );
      final noModel = Map<String, Object?>.of(
        json['files']! as Map<String, Object?>,
      )..remove('model.int8.onnx');
      expect(
        () => IntentManifest.parse(
          jsonEncode(<String, Object?>{...json, 'files': noModel}),
        ),
        throwsA(isA<IntentPackException>()),
      );
      final traversal = <String, Object?>{
        ...json,
        'files': <String, Object?>{
          ...json['files']! as Map<String, Object?>,
          '../evil': <String, Object?>{'size': 1, 'sha256': '00'},
        },
      };
      expect(
        () => IntentManifest.parse(jsonEncode(traversal)),
        throwsA(isA<IntentPackException>()),
      );
    });

    test('большой файл сверяется по размеру', () {
      final manifest = IntentManifest(
        tier: 'light',
        version: '1',
        threshold: 0.9,
        k: 5,
        dims: 6,
        maxLength: 64,
        inputs: const <String>['input_ids'],
        files: <String, IntentPackFile>{
          'model.int8.onnx': const IntentPackFile(
            size: IntentPack.hashLimit + 1,
            sha256: 'не считается',
          ),
        },
      );
      IntentPack.verify(
        manifest,
        'model.int8.onnx',
        Uint8List(IntentPack.hashLimit + 1),
      );
      expect(
        () => IntentPack.verify(manifest, 'model.int8.onnx', Uint8List(3)),
        throwsA(isA<IntentPackException>()),
      );
    });
  });

  group('решение запасного слоя', () {
    late IntentFallback fallback;
    late IntentModel model;

    setUp(() {
      model = fakeModel(FakeEncoder(<String, Float32List>{}));
      fallback = IntentFallback(
        model: model,
        memory: IntentMemory(blocks: (_) => false),
        blocks: (_) => false,
      );
    });

    IntentSuggestion? decide(
      Map<String, double> weights, {
      Set<String>? connectors,
      Set<String> exclude = const <String>{},
    }) =>
        fallback.decide(
          'фраза',
          fakeVector(weights),
          model,
          connectors: connectors,
          exclude: exclude,
        );

    test('уверенно — подсказка; ниже порога — молчит', () {
      expect(
        decide(<String, double>{'tasks:task.create': 1})?.first.id,
        'tasks:task.create',
      );
      expect(
        decide(<String, double>{'tasks:task.create': 0.8, 'none': 0.6}),
        isNull,
        reason: 'сходство 0,8 ниже порога 0,9',
      );
    });

    test('победила «не команда» — подсказки нет', () {
      expect(
        decide(<String, double>{'none': 1, 'tasks:task.create': 0.3}),
        isNull,
      );
    });

    test('выключенный навык и навык вне уровня — подсказки нет', () {
      expect(
        decide(
          <String, double>{'weather:weather.now': 1},
          connectors: <String>{'tasks', 'calc'},
        ),
        isNull,
      );
      final web = fakeModel(
        FakeEncoder(<String, Float32List>{}),
        connectors: <String>['calc'],
      );
      expect(
        fallback.decide(
          'x',
          fakeVector(<String, double>{'tasks:task.create': 1}),
          web,
        ),
        isNull,
      );
      expect(
        decide(
          <String, double>{'talk:talk.question': 1},
          exclude: <String>{'talk:talk.question'},
        ),
        isNull,
      );
    });

    test('второй вариант — если и его лучший пример не ниже порога', () {
      // По два примера на метку: среди пяти ближайших — обе метки.
      final lowModel = fakeModel(
        FakeEncoder(<String, Float32List>{}),
        threshold: 0.6,
        perLabel: 2,
      );
      final s = fallback.decide(
        'x',
        fakeVector(<String, double>{
          'tasks:task.create': 0.75,
          'tasks:task.list': 0.66,
        }),
        lowModel,
      )!;
      expect(s.first.id, 'tasks:task.create');
      expect(s.second?.id, 'tasks:task.list');
      expect(s.choices, hasLength(2));
      final one = fallback.decide(
        'x',
        fakeVector(<String, double>{
          'tasks:task.create': 0.9,
          'tasks:task.list': 0.43,
        }),
        lowModel,
      )!;
      expect(one.second, isNull);
    });

    test('«Нет» снимает метку для похожих фраз', () async {
      final v = fakeVector(<String, double>{'tasks:task.create': 1});
      await fallback.memory.reject(
        'фраза',
        <String>['tasks:task.create'],
        vector: v,
        modelKey: model.key,
      );
      expect(fallback.decide('фраза', v, model), isNull);
      // Отвергнутая метка снята — следующей по голосам предлагается своя.
      final mixed = fakeVector(<String, double>{
        'tasks:task.create': 0.7,
        'tasks:task.list': 0.69,
      });
      expect(fallback.decide('x', mixed, model), isNull);
    });

    test('личный пример «Да» побеждает голосование корпуса', () async {
      final v = fakeVector(<String, double>{
        'tasks:task.create': 0.95,
        'calc:calc.evaluate': 0.31,
      });
      await fallback.memory.remember(
        'фраза',
        'calc:calc.evaluate',
        vector: v,
        modelKey: model.key,
      );
      final s = fallback.decide('фраза', v, model)!;
      expect(s.first.id, 'calc:calc.evaluate');
      expect(s.personal, isTrue);
    });

    test('учиться выключено — личные примеры не используются', () async {
      final v = fakeVector(<String, double>{'tasks:task.create': 1});
      await fallback.memory.reject(
        'фраза',
        <String>['tasks:task.create'],
        vector: v,
        modelKey: model.key,
      );
      await fallback.memory.setLearning(false);
      expect(fallback.decide('фраза', v, model)?.first.id, 'tasks:task.create');
    });

    test('пример другой модели не используется, а пересчитывается', () async {
      final encoder = FakeEncoder(<String, Float32List>{
        'посчитай-ка': fakeVector(<String, double>{'calc:calc.evaluate': 1}),
      });
      final memory = IntentMemory(blocks: (_) => false);
      await memory.remember(
        'посчитай-ка',
        'calc:calc.evaluate',
        vector: fakeVector(<String, double>{'tasks:task.list': 1}),
        modelKey: 'light@старая',
      );
      final f = IntentFallback(
        model: fakeModel(encoder),
        memory: memory,
        blocks: (_) => false,
      );
      final s = await f.suggest('посчитай-ка');
      expect(encoder.seen, <String>['посчитай-ка', 'посчитай-ка']);
      expect(s?.first.id, 'calc:calc.evaluate');
      expect(memory.positives.single.modelKey, 'light@0.0.1');
      await f.suggest('посчитай-ка');
      expect(encoder.seen, hasLength(3), reason: 'пересчёт — один раз');
    });

    test('приватную фразу модель не видит; без модели — молчит', () async {
      final encoder = FakeEncoder(<String, Float32List>{});
      final f = IntentFallback(model: fakeModel(encoder));
      for (final phrase in <String>[
        'пароль от почты CANARY',
        'мой пин 4821 запиши',
        'код от домофона 1234',
        'логин для банка',
        'ключ Qwerty12345',
        '••••',
        'паролль от вк',
      ]) {
        expect(await f.suggest(phrase), isNull, reason: phrase);
      }
      expect(encoder.seen, isEmpty);
      expect(await IntentFallback().suggest('в кино сходить'), isNull);
    });
  });
}
