import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/intent/intent_http.dart';
import 'package:local_assistant/core/intent/intent_tokenizer.dart';

import '../intent/intent_index_test.dart' show trix;

/// Метки поддельного пакета `web`: склад, калькулятор и задачи — задач в
/// индексе `web` не бывает (`connectors` — warehouse, calc, talk), здесь
/// они проверяют, что ограничение уровня действует.
const List<Map<String, String>> webLabels = <Map<String, String>>[
  <String, String>{'id': 'none'},
  <String, String>{
    'id': 'warehouse:warehouse.today',
    'connector': 'warehouse',
    'command': 'warehouse.today',
    'description': 'узнать, что пришло на склад сегодня',
  },
  <String, String>{
    'id': 'calc:calc.evaluate',
    'connector': 'calc',
    'command': 'calc.evaluate',
    'description': 'посчитать на калькуляторе',
  },
  <String, String>{
    'id': 'tasks:task.create',
    'connector': 'tasks',
    'command': 'task.create',
    'description': 'создать задачу или напоминание',
  },
];

int get webDims => webLabels.length;

/// Нормированный вектор по весам меток.
Float32List webVector(Map<String, double> weights) {
  final v = Float32List(webDims);
  for (final MapEntry(:key, :value) in weights.entries) {
    v[webLabels.indexWhere((Map<String, String> l) => l['id'] == key)] = value;
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

/// Токенизатор поддельного пакета — урезанный словарь «Лёгкой».
String webTokenizerJson() =>
    File('test/fixtures/intent/tokenizer_light_mini.json').readAsStringSync();

/// Токенизатор поддельного пакета `web-accurate` — урезанный byte-level BPE
/// «Точной» (USER-base).
String webAccurateTokenizerJson() =>
    File('test/fixtures/intent/tokenizer_accurate_mini.json')
        .readAsStringSync();

/// Файлы поддельного пакета `web` (без манифеста) по 5 примеров на метку.
Map<String, Uint8List> webPackFiles({bool accurate = false}) {
  final vectors = <List<double>>[];
  final ids = <int>[];
  for (var label = 0; label < webLabels.length; label++) {
    for (var i = 0; i < 5; i++) {
      vectors.add(webVector(<String, double>{webLabels[label]['id']!: 1}));
      ids.add(label);
    }
  }
  return <String, Uint8List>{
    'model.int8.onnx':
        Uint8List.fromList(List<int>.generate(4096, (int i) => (i * 7) % 256)),
    'index.bin': trix(vectors, ids),
    'labels.json': Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'format': 'tridot-intent/1',
          'question': 'Похоже, вы хотите {description}?',
          'labels': webLabels,
        }),
      ),
    ),
    'tokenizer.json': Uint8List.fromList(
      utf8.encode(accurate ? webAccurateTokenizerJson() : webTokenizerJson()),
    ),
    if (!accurate)
      'vocab.txt': Uint8List.fromList(utf8.encode('[PAD]\n[UNK]\n')),
  };
}

String sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// `manifest.json` для [files].
Uint8List webManifest(
  Map<String, Uint8List> files, {
  String tier = 'web',
  String version = '1.0.0',
  double threshold = 0.9,
}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'format': IntentManifest.format,
          'tier': tier,
          'title': 'Веб-помощник',
          'version': version,
          'threshold': threshold,
          'k': 5,
          'dims': webDims,
          'max_length': 64,
          'inputs': <String>[
            'input_ids',
            'attention_mask',
            if (tier != 'web-accurate') 'token_type_ids',
          ],
          'output': 'embedding',
          'prefix': tier == 'web-accurate' ? 'query: ' : '',
          'connectors': <String>['warehouse', 'calc', 'talk'],
          'files': <String, Object?>{
            for (final MapEntry(:key, :value) in files.entries)
              key: <String, Object?>{
                'size': value.length,
                'sha256': sha(value),
              },
          },
        }),
      ),
    );

/// Указатель `current.json` на папку [dir].
String webPointer({
  String version = '1.0.0',
  String dir = '1.0.0-6dc650b6',
  String tier = 'web',
  List<int>? manifest,
}) =>
    jsonEncode(<String, Object?>{
      'format': IntentPointer.format,
      'tier': tier,
      'version': version,
      'dir': dir,
      if (manifest != null) 'manifest_sha256': sha(manifest),
    });

/// Файлы склада по адресу: `fetch` с байтами. Запросы запоминаются.
final class FakePackServer implements BytesFetcher {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final List<Uri> requests = <Uri>[];

  /// Положить пакет [pack] (с манифестом) в папку версии [dir] склада
  /// [base].
  void serve(
    Map<String, Uint8List> pack, {
    String base = 'https://warehouse.example/',
    String dir = '1.0.0-6dc650b6',
  }) {
    for (final MapEntry(:key, :value) in pack.entries) {
      files['${base}assistant/intent/web/$dir/$key'] = value;
    }
  }

  @override
  Future<BytesResponse> fetchBytes(
    Uri uri, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    requests.add(uri);
    final bytes = files[uri.toString()];
    return bytes == null
        ? BytesResponse(404, Uint8List(0))
        : BytesResponse(200, bytes);
  }
}

/// Поддельная среда выполнения: номера токенов фразы → вектор по таблице
/// фраз (токенизатор пакета считает номера так же), остальное — «не
/// команда». Запоминает фразы, которые ей показали.
final class FakeWebRuntime implements IntentRuntime {
  FakeWebRuntime(this.table, {bool accurate = false})
      : _tokenizer = IntentTokenizer.parse(
          accurate ? webAccurateTokenizerJson() : webTokenizerJson(),
        ),
        _prefix = accurate ? 'query: ' : '';

  /// Фраза → вектор.
  final Map<String, Float32List> table;
  final String _prefix;
  final IntentTokenizer _tokenizer;
  final List<String> seen = <String>[];
  int opened = 0;
  bool closed = false;
  Uint8List? model;

  Future<IntentRuntime> open(Uint8List model, IntentManifest manifest) async {
    opened++;
    this.model = model;
    return this;
  }

  @override
  Future<Float32List> run(TokenBatch batch, List<String> inputs) async {
    final out = Float32List(batch.rows * webDims);
    for (var row = 0; row < batch.rows; row++) {
      final ids = <int>[
        for (var i = 0; i < batch.length; i++)
          if (batch.mask[row * batch.length + i] == 1)
            batch.ids[row * batch.length + i],
      ];
      var vector = webVector(const <String, double>{'none': 1});
      for (final MapEntry(key: text, value: v) in table.entries) {
        if (_same(_tokenizer.encode('$_prefix$text'), ids)) {
          vector = v;
          seen.add(text);
        }
      }
      out.setRange(row * webDims, (row + 1) * webDims, vector);
    }
    return out;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> close() async => closed = true;
}
