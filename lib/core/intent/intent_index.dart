import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Команда, которую знает модель: метка `<навык>:<команда>`.
final class IntentLabel {
  const IntentLabel({
    required this.id,
    this.connectorId = '',
    this.commandId = '',
    this.description = '',
  });

  /// `tasks:task.create`; у «не команды» — [none].
  final String id;

  /// `tasks`.
  final String connectorId;

  /// `task.create`.
  final String commandId;

  /// Что подставить в «Похоже, вы хотите …?»: «создать задачу или
  /// напоминание».
  final String description;

  bool get isNone => id == none;

  /// Метка фраз «не команда».
  static const String none = 'none';
}

/// `labels.json` пакета: метки по номерам, `none` — номер 0.
final class IntentLabels {
  IntentLabels(this.labels, {this.question = defaultQuestion})
      : _byId = <String, int>{
          for (final (index, label) in labels.indexed) label.id: index,
        };

  factory IntentLabels.parse(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?> || json['labels'] is! List<Object?>) {
      throw const FormatException('labels.json: нет списка меток');
    }
    final labels = <IntentLabel>[
      for (final item in json['labels']! as List<Object?>)
        if (item is Map<String, Object?> && item['id'] is String)
          IntentLabel(
            id: item['id']! as String,
            connectorId: item['connector'] as String? ?? '',
            commandId: item['command'] as String? ?? '',
            description: item['description'] as String? ?? '',
          )
        else
          throw const FormatException('labels.json: метка без id'),
    ];
    if (labels.isEmpty || !labels.first.isNone) {
      throw const FormatException('labels.json: номер 0 — не none');
    }
    return IntentLabels(
      labels,
      question: json['question'] as String? ?? defaultQuestion,
    );
  }

  static const String defaultQuestion = 'Похоже, вы хотите {description}?';

  final List<IntentLabel> labels;

  /// Шаблон вопроса из пакета (в ответе — каталог ответов, `intent.suggest`).
  final String question;

  final Map<String, int> _byId;

  int get length => labels.length;

  IntentLabel operator [](int index) => labels[index];

  /// Номер метки [id] или `null`.
  int? indexOf(String id) => _byId[id];

  IntentLabel? byId(String id) {
    final index = _byId[id];
    return index == null ? null : labels[index];
  }
}

/// Пример для kNN сверх индекса пакета: личный пример (ADR-041, п. 7).
final class IntentExtra {
  const IntentExtra(this.vector, this.label);

  /// Нормированный вектор той же модели.
  final Float32List vector;

  /// Номер метки в [IntentLabels].
  final int label;
}

/// Итог голосования k ближайших.
final class IntentVote {
  const IntentVote({required this.ranked, required this.best});

  /// Номера меток по убыванию суммы сходств (при равенстве — по id метки,
  /// как в tools/intent_model/knn.py).
  final List<int> ranked;

  /// Лучшее сходство примера каждой метки из [ranked].
  final Map<int, double> best;

  int get winner => ranked.first;

  /// Сходство лучшего примера победившей метки.
  double get similarity => best[winner]!;

  int? get second => ranked.length > 1 ? ranked[1] : null;
}

/// `index.bin` пакета: нормированные векторы примеров корпуса (fp16 →
/// fp32) и номера их меток. Формат — tools/intent_model/pack.py: `TRIX`,
/// uint16 версия 1, uint16 0, uint32 n, uint32 dims, n×dims fp16, n×uint16
/// номеров меток, little-endian.
final class IntentIndex {
  IntentIndex({
    required this.vectors,
    required this.labelIds,
    required this.dims,
    required this.labels,
  }) : assert(vectors.length == labelIds.length * dims);

  factory IntentIndex.parse(Uint8List bytes, IntentLabels labels) {
    if (bytes.length < 16 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != magic) {
      throw const FormatException('index.bin: не индекс TRIX');
    }
    final data = ByteData.sublistView(bytes);
    final version = data.getUint16(4, Endian.little);
    if (version != 1) {
      throw FormatException('index.bin: версия $version');
    }
    final n = data.getUint32(8, Endian.little);
    final dims = data.getUint32(12, Endian.little);
    if (dims == 0 || bytes.length != 16 + n * dims * 2 + n * 2) {
      throw const FormatException('index.bin: не тот размер');
    }
    final vectors = Float32List(n * dims);
    final halves = _halves;
    for (var i = 0; i < n * dims; i++) {
      vectors[i] = halves[data.getUint16(16 + i * 2, Endian.little)];
    }
    final labelIds = Uint16List(n);
    final base = 16 + n * dims * 2;
    for (var i = 0; i < n; i++) {
      final label = data.getUint16(base + i * 2, Endian.little);
      if (label >= labels.length) {
        throw FormatException('index.bin: метка $label вне labels.json');
      }
      labelIds[i] = label;
    }
    return IntentIndex(
      vectors: vectors,
      labelIds: labelIds,
      dims: dims,
      labels: labels,
    );
  }

  static const String magic = 'TRIX';

  /// Векторы подряд: пример i — `[i * dims, (i + 1) * dims)`.
  final Float32List vectors;
  final Uint16List labelIds;
  final int dims;
  final IntentLabels labels;

  int get length => labelIds.length;

  /// Голосование [k] ближайших к [query] среди примеров индекса и [extra]:
  /// голос примера — его сходство (не меньше нуля). Сходство — скалярное
  /// произведение нормированных векторов. При равном сходстве ближе
  /// пример с меньшим номером (индекс, потом [extra]).
  IntentVote vote(
    Float32List query,
    int k, {
    List<IntentExtra> extra = const <IntentExtra>[],
  }) {
    if (query.length != dims) {
      throw ArgumentError.value(query.length, 'query', 'не тот размер');
    }
    final total = length + extra.length;
    final count = math.min(k, total);
    // Отсортированные по убыванию сходства лучшие count примеров.
    final topSims = Float64List(count);
    final topIndex = Int32List(count);
    var filled = 0;
    void offer(int index, double sim) {
      if (filled == count && sim <= topSims[count - 1]) return;
      var at = filled < count ? filled++ : count - 1;
      while (at > 0 && topSims[at - 1] < sim) {
        topSims[at] = topSims[at - 1];
        topIndex[at] = topIndex[at - 1];
        at--;
      }
      topSims[at] = sim;
      topIndex[at] = index;
    }

    for (var i = 0; i < length; i++) {
      offer(i, dot(vectors, i * dims, query, dims));
    }
    for (var j = 0; j < extra.length; j++) {
      offer(length + j, dot(extra[j].vector, 0, query, dims));
    }
    final votes = <int, double>{};
    final best = <int, double>{};
    for (var i = 0; i < filled; i++) {
      final index = topIndex[i];
      final label =
          index < length ? labelIds[index] : extra[index - length].label;
      final sim = topSims[i];
      votes[label] = (votes[label] ?? 0) + math.max(sim, 0);
      best[label] = math.max(best[label] ?? -1, sim);
    }
    final ranked = votes.keys.toList()
      ..sort((int a, int b) {
        final byVotes = votes[b]!.compareTo(votes[a]!);
        return byVotes != 0 ? byVotes : labels[a].id.compareTo(labels[b].id);
      });
    return IntentVote(ranked: ranked, best: best);
  }

  /// Скалярное произведение `a[offset, offset + dims)` и [b].
  static double dot(Float32List a, int offset, Float32List b, int dims) {
    var sum = 0.0;
    for (var d = 0; d < dims; d++) {
      sum += a[offset + d] * b[d];
    }
    return sum;
  }

  /// Все 65 536 значений fp16: разбор индекса — поиск в таблице.
  static final Float32List _halves = Float32List.fromList(<double>[
    for (var half = 0; half < 0x10000; half++) halfToDouble(half),
  ]);

  /// IEEE 754 binary16 → double.
  static double halfToDouble(int half) {
    final sign = (half & 0x8000) != 0 ? -1.0 : 1.0;
    final exponent = (half >> 10) & 0x1F;
    final fraction = half & 0x3FF;
    if (exponent == 0) {
      return sign * fraction * math.pow(2, -24).toDouble();
    }
    if (exponent == 0x1F) {
      return fraction == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1 + fraction / 1024) * math.pow(2, exponent - 15).toDouble();
  }
}
