import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/connectors/http_transport.dart';
import '../core/intent/bare_time.dart';
import '../core/intent/intent_fallback.dart';
import '../core/intent/intent_http.dart';
import '../core/services/clock.dart';
import 'widget_storage.dart';
import 'widget_store.dart' show widgetLoginKey;

export '../core/intent/intent_http.dart'
    show
        BytesFetcher,
        BytesResponse,
        IntentRuntimeFactory,
        Sha256Hasher,
        dartSha256;

/// Память запасного слоя веб-помощника (ADR-045, шаг 4) в хранилище
/// браузера: `svz:intent:<логин>` — у каждого сотрудника своя. Страница
/// склада стирает `svz:*` при выходе, как и остальной кэш помощника: на
/// общем компьютере выученное и журнал следующему не достаются.
///
/// `localStorage` мал (~5 МБ на всё): не влезает в [maxChars] — сначала
/// без векторов (их пересчитает модель при первой подсказке), потом без
/// старых примеров. Записать не вышло — память живёт до закрытия страницы.
final class WidgetIntentMemoryStore implements IntentMemoryStore {
  WidgetIntentMemoryStore(this.storage, String login)
      : key = '${widgetKeyPrefix}intent:${widgetLoginKey(login)}';

  final KeyValueStorage storage;
  final String key;

  /// Около 512 КБ в UTF-16 `localStorage`.
  static const int maxChars = 256 * 1024;

  @override
  Future<Map<String, Object?>?> load() async {
    final text = storage.read(key);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, Object?>) return json;
    } on Object {
      // Повреждённая запись — как новая.
    }
    return null;
  }

  @override
  Future<void> save(Map<String, Object?> json) async {
    try {
      storage.write(key, fit(json));
    } on Object {
      // Нет места или запрещено — память до закрытия страницы.
    }
  }

  /// [json] текстом не длиннее [maxChars].
  static String fit(Map<String, Object?> json) {
    var text = jsonEncode(json);
    if (text.length <= maxChars) return text;
    List<Object?> list(Object? value) =>
        value is List<Object?> ? List<Object?>.of(value) : <Object?>[];
    Map<String, Object?> withoutVector(Object? item) => item is Map
        ? <String, Object?>{
            for (final MapEntry(:key, :value) in item.entries)
              if (key != 'vector' && key != 'model') '$key': value,
          }
        : <String, Object?>{};
    final slim = <String, Object?>{
      ...json,
      'positives': <Object?>[
        for (final e in list(json['positives'])) withoutVector(e),
      ],
      'negatives': <Object?>[
        for (final e in list(json['negatives'])) withoutVector(e),
      ],
    };
    text = jsonEncode(slim);
    while (text.length > maxChars) {
      // Старые первыми: примеры — в порядке добавления, журнал — новые
      // первыми.
      final positives = list(slim['positives']);
      final negatives = list(slim['negatives']);
      final unclear = list(slim['unclear']);
      if (positives.isEmpty && negatives.isEmpty && unclear.isEmpty) break;
      if (positives.length >= negatives.length && positives.isNotEmpty) {
        positives.removeRange(0, (positives.length / 4).ceil());
      } else if (negatives.isNotEmpty) {
        negatives.removeRange(0, (negatives.length / 4).ceil());
      }
      if (unclear.length > 20) {
        unclear.removeRange(unclear.length * 3 ~/ 4, unclear.length);
      } else if (positives.isEmpty && negatives.isEmpty) {
        unclear.clear();
      }
      slim
        ..['positives'] = positives
        ..['negatives'] = negatives
        ..['unclear'] = unclear;
      text = jsonEncode(slim);
    }
    return text;
  }
}

/// Что с моделью понимания в веб-помощнике.
enum WidgetIntentState {
  /// Ещё не смотрели, есть ли модель на складе.
  unknown,

  /// Склад модель не ставил (или в этой сборке нет среды выполнения).
  none,

  /// Модель есть, сотрудник выключил подсказки.
  off,

  /// Скачиваем и проверяем пакет, запускаем onnxruntime-web.
  loading,
  ready,

  /// Пакет не прошёл проверку или среда не запустилась.
  failed,
}

/// Запасной слой понимания в веб-помощнике склада (ADR-045, шаг 4): тот
/// же [IntentFallback], что в приложении, с памятью в хранилище браузера
/// ([WidgetIntentMemoryStore]) и пакетом уровня `web` со своего склада
/// ([HttpPackSource]). Модель — onnxruntime-web в браузере
/// (`intent_web.dart`); ничего, кроме скачивания файлов со склада, в сеть не
/// уходит.
///
/// Модель загружается не сразу: сначала указатель (маленький файл), сама
/// модель — через [delay] после входа, чтобы не мешать первому ответу.
/// Пока она грузится, «не понял» — обычный, без подсказки.
final class WidgetIntent extends ChangeNotifier {
  WidgetIntent({
    required this.storage,
    required String login,
    required this.base,
    required this.transport,
    this.fetcher,
    this.runtime,
    this.prepare,
    this.hasher = dartSha256,
    this.delay = const Duration(seconds: 3),
    Clock clock = const SystemClock(),
  })  : _onKey = '${widgetKeyPrefix}intent-on:${widgetLoginKey(login)}',
        memory = IntentMemory(
          store: WidgetIntentMemoryStore(storage, login),
          clock: clock,
          blocks: intentPrivate,
        ) {
    // Голое время («7:30», «в 9») — не команда: веб-уровень путает его с
    // калькулятором. Память и журнал — как прежде (только приватность).
    fallback = IntentFallback(
      memory: memory,
      blocks: (String text) => intentPrivate(text) || bareTimePhrase(text),
    );
  }

  final KeyValueStorage storage;

  /// Адрес склада (`init.base`).
  final Uri base;

  /// Для указателя `current.json` (без кэша).
  final HttpTransport transport;

  /// Для файлов пакета; `null` — модель не загружается.
  final BytesFetcher? fetcher;

  /// Среда выполнения (onnxruntime-web); `null` — модель не загружается.
  final IntentRuntimeFactory? runtime;

  /// Подготовить среду до скачивания модели (загрузить onnxruntime-web):
  /// без среды 30 МБ модели качать незачем.
  final Future<void> Function()? prepare;
  final Sha256Hasher hasher;
  final Duration delay;

  final IntentMemory memory;
  late final IntentFallback fallback;
  final String _onKey;

  WidgetIntentState state = WidgetIntentState.unknown;

  /// Версия модели на складе (из указателя), если она есть.
  String? version;

  /// Почему модель не загрузилась — для настроек.
  String problem = '';

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// «Подсказывать команды»: по умолчанию включено, если склад поставил
  /// модель.
  bool get enabled => storage.read(_onKey) != '0';

  bool get ready => fallback.model != null;

  /// Память — сразу; указатель и модель — в фоне.
  Future<void> start() async {
    await memory.load();
    if (_disposed) return;
    notifyListeners();
    if (fetcher == null || runtime == null) {
      _set(WidgetIntentState.none);
      return;
    }
    _timer = Timer(delay, () => unawaited(load()));
  }

  /// Проверить склад и загрузить модель (если она есть и подсказки
  /// включены). Прежняя модель закрывается, если пакет другой.
  Future<void> load() async {
    _timer?.cancel();
    final fetch = fetcher;
    final make = runtime;
    if (_disposed || fetch == null || make == null) return;
    if (state == WidgetIntentState.loading) return;
    final generation = ++_generation;
    final HttpPackSource? source;
    try {
      source = await HttpPackSource.open(
        base: base,
        transport: transport,
        fetcher: fetch,
        hasher: hasher,
      );
    } on Object catch (error) {
      if (generation == _generation) _failed(error);
      return;
    }
    if (_disposed || generation != _generation) return;
    if (source == null) {
      version = null;
      await _unload();
      _set(WidgetIntentState.none);
      return;
    }
    version = source.manifest.version;
    if (!enabled) {
      await _unload();
      _set(WidgetIntentState.off);
      return;
    }
    if (fallback.model?.key == source.manifest.modelKey) {
      _set(WidgetIntentState.ready);
      return;
    }
    _set(WidgetIntentState.loading);
    try {
      await prepare?.call();
      if (_disposed || generation != _generation) return;
      final model = await loadIntentModel(source, source.manifest, make);
      if (_disposed || generation != _generation) {
        await model.encoder.close();
        return;
      }
      final old = fallback.model;
      fallback.model = model;
      await old?.encoder.close();
      problem = '';
      _set(WidgetIntentState.ready);
    } on Object catch (error) {
      if (generation == _generation) _failed(error);
    }
  }

  /// «Подсказывать команды».
  Future<void> setEnabled(bool on) async {
    try {
      if (on) {
        storage.remove(_onKey);
      } else {
        storage.write(_onKey, '0');
      }
    } on Object {
      // Не записалось — до закрытия страницы.
    }
    if (!on) {
      _generation++;
      await _unload();
      _set(version == null ? state : WidgetIntentState.off);
      return;
    }
    if (version != null || state == WidgetIntentState.off) await load();
  }

  Future<void> setLearning(bool on) async {
    await memory.setLearning(on);
    notifyListeners();
  }

  Future<void> setLogging(bool on) async {
    await memory.setLogging(on);
    notifyListeners();
  }

  Future<void> forgetLearned() async {
    await memory.forgetLearned();
    notifyListeners();
  }

  Future<void> removeUnclear(UnclearPhrase phrase) async {
    await memory.removeUnclear(phrase);
    notifyListeners();
  }

  Future<void> clearUnclear() async {
    await memory.clearUnclear();
    notifyListeners();
  }

  void _failed(Object error) {
    problem = error is IntentPackException ? error.message : '$error';
    _set(WidgetIntentState.failed);
  }

  Future<void> _unload() async {
    final old = fallback.model;
    fallback.model = null;
    await old?.encoder.close();
  }

  void _set(WidgetIntentState next) {
    state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _generation++;
    unawaited(_unload());
    super.dispose();
  }
}
