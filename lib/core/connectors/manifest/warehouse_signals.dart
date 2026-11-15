import 'dart:async';
import 'dart:convert';

import '../../services/clock.dart';
import '../http_transport.dart';
import '../secret_store.dart';
import 'connection.dart';
import 'connection_service.dart';
import 'manifest_connector.dart';
import 'manifest_format.dart';
import 'manifest_text.dart';

/// Что нового на складе: приходы за сегодня и что не проведено.
final class WarehouseSignal {
  const WarehouseSignal({
    required this.at,
    this.arrivals,
    this.arrivalsQty,
    this.unposted,
    this.newArrivals = 0,
  });

  final DateTime at;

  /// Приходов сегодня; `null` — склад не ответил на вопрос.
  final int? arrivals;
  final int? arrivalsQty;

  /// Не проведено за 30 дней; `null` — склад этого не умеет.
  final int? unposted;

  /// Новых приходов с прошлой проверки.
  final int newArrivals;

  /// «Сегодня 3 прихода · не проведено 2 · проверено в 14:05».
  String get line {
    final parts = <String>[
      if (arrivals case final int n)
        n == 0
            ? 'сегодня приходов нет'
            : 'сегодня ${askPlural(n, 'приход,прихода,приходов')}',
      if (unposted case final int n when n > 0) 'не проведено $n',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final local = at.toLocal();
    final time = '${two(local.hour)}:${two(local.minute)}';
    final head = parts.isEmpty ? 'Сигналы склада' : _capital(parts.join(' · '));
    return '$head · проверено в $time';
  }

  static String _capital(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
}

/// Сигналы склада, только пока приложение открыто (ADR-031): раз в
/// [interval] — по умолчанию минута — читающие вопросы встроенного
/// описания (`ask_arrivals` за сегодня, `ask_unposted`). Без фоновой
/// работы, WorkManager и уведомлений: [pause] при уходе приложения в фон
/// останавливает таймер, [resume] — снова запускает. Ошибка — пауза
/// растёт вдвое до [maxBackoff]; 429 — сразу [maxBackoff]. Только под
/// своим логином: приходы видны лишь сотруднику.
final class WarehouseSignals {
  WarehouseSignals({
    required this.service,
    required HttpTransport transport,
    required SecretStore secrets,
    Clock clock = const SystemClock(),
    this.interval = const Duration(minutes: 1),
    this.maxBackoff = const Duration(minutes: 15),
    Timer Function(Duration, void Function())? timer,
  })  : _transport = transport,
        _secrets = secrets,
        _clock = clock,
        _timer = timer ?? Timer.new;

  final ConnectionService service;
  final HttpTransport _transport;
  final SecretStore _secrets;
  final Clock _clock;
  final Timer Function(Duration, void Function()) _timer;

  final Duration interval;
  final Duration maxBackoff;

  /// Пределы интервала, если его задаст описание.
  static const Duration minInterval = Duration(seconds: 30);
  static const Duration maxInterval = Duration(minutes: 10);

  Timer? _next;
  bool _running = false;
  bool _busy = false;
  Duration _delay = Duration.zero;
  Set<String> _seen = <String>{};
  bool _first = true;

  /// Склад знает `ask_unposted` (DepotDesk); halowarekeep отвечает 400 —
  /// больше не спрашиваем до перезапуска.
  bool _askUnposted = true;

  /// Последний сигнал; `null` — ещё не спрашивали или вышли.
  WarehouseSignal? last;

  /// Новые приходы с прошлой проверки: [WarehouseSignal.newArrivals] > 0.
  void Function(WarehouseSignal signal)? onNews;

  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    service.signal = last?.line;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Сейчас пауза между вопросами — для тестов и экрана.
  Duration get delay => _delay == Duration.zero ? interval : _delay;

  bool get running => _running;

  /// Как часто освежать «кто я и что мне можно» (`ask_me`): права и
  /// «действия включены» меняют на складе, пока приложение открыто.
  static const Duration meEvery = Duration(minutes: 30);

  /// Вернулись на экран — права спросить заново при первом опросе.
  bool _meDue = false;
  DateTime? _meAskedAt;

  /// Приложение на экране: спрашивать сразу и потом по таймеру.
  void resume() {
    if (_running) return;
    _running = true;
    _meDue = true;
    _schedule(Duration.zero);
  }

  /// Приложение ушло в фон или закрывается: таймер снят, вопросов нет.
  void pause() {
    _running = false;
    _next?.cancel();
    _next = null;
  }

  void dispose() {
    pause();
    _listeners.clear();
  }

  void _schedule(Duration after) {
    _next?.cancel();
    if (!_running) return;
    _next = _timer(after, () => unawaited(tick()));
  }

  /// Один опрос. Публичный для тестов; сам переставляет таймер.
  Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final outcome = await _poll();
      switch (outcome) {
        case _Outcome.ok:
          _delay = Duration.zero;
        case _Outcome.idle:
          // Не подключён или без логина: без ошибок, раз в интервал.
          _delay = Duration.zero;
          if (last != null) {
            last = null;
            _seen = <String>{};
            _first = true;
            _notify();
          }
        case _Outcome.busy:
          _delay = maxBackoff;
        case _Outcome.failed:
          final doubled = (_delay == Duration.zero ? interval : _delay) * 2;
          _delay = doubled > maxBackoff ? maxBackoff : doubled;
      }
    } finally {
      _busy = false;
    }
    _schedule(delay);
  }

  Future<_Outcome> _poll() async {
    final record = service.record;
    final description = service.builtIn ?? service.description;
    final base = record.manifestUri;
    if (!record.connected ||
        record.level != ConnectionLevel.staff ||
        // Ключ отключили на складе или он истёк — молчим до нового входа,
        // а не стучимся раз в минуту мёртвым ключом.
        record.failure == ConnectionFailure.expired ||
        description == null ||
        base == null) {
      return _Outcome.idle;
    }
    final keys = await readConnectionKeys(_secrets, service.slot, record);
    final sid = keys?['sid'];
    if (keys == null || sid == null) return _Outcome.idle;
    final credentials = keys;
    final now = _clock.now();
    final meAt = record.me.at;
    final meAge = meAt == null ? null : now.difference(meAt);
    final asked = _meAskedAt;
    // Склад без `ask_me` (400) прав не скажет — и спрашиваем его не чаще
    // [meEvery], а не каждую минуту.
    final due = _meDue
        ? meAge == null || meAge >= const Duration(minutes: 1)
        : (asked == null || now.difference(asked) >= meEvery) &&
            (meAge == null || meAge >= meEvery);
    _meDue = false;
    if (due) {
      _meAskedAt = now;
      // Права, роль и «действия включены» — свежие; 403 «нужен вход»
      // отмечает ключ устаревшим (refreshMe), тогда опрос молчит.
      await service.refreshMe();
      if (service.record.failure == ConnectionFailure.expired) {
        return _Outcome.idle;
      }
    }
    final vars = ManifestVars(now);
    final today = description.command('today')?.call;
    final unposted = description.command('unposted')?.call;
    if (today == null) return _Outcome.idle;
    final arrivals = await _ask(description, base, today, credentials, vars);
    if (arrivals.status == 429) return _Outcome.busy;
    if (_keyGone(arrivals, description)) {
      service.connector.markExpired(_clock.now());
      return _Outcome.idle;
    }
    final json = arrivals.ok ? arrivals.json : null;
    if (json == null || json['ok'] == false) return _Outcome.failed;
    Map<String, Object?>? notPosted;
    if (unposted != null && _askUnposted) {
      final reply = await _ask(description, base, unposted, credentials, vars);
      if (reply.status == 400 || reply.status == 404) _askUnposted = false;
      notPosted = reply.ok ? reply.json : null;
    }
    final ids = <String>{
      if (json['items'] case final List<Object?> items)
        for (final item in items)
          if (item is Map && item['id'] != null) '${item['id']}',
    };
    final fresh = _first ? 0 : ids.difference(_seen).length;
    _seen = ids;
    _first = false;
    final signal = WarehouseSignal(
      at: _clock.now(),
      arrivals: _int(json['count']),
      arrivalsQty: _int(json['qty']),
      unposted: notPosted == null ? null : _int(notPosted['count']),
      newArrivals: fresh,
    );
    last = signal;
    _notify();
    if (fresh > 0) onNews?.call(signal);
    return _Outcome.ok;
  }

  /// Ключ больше не годится: 403 «нужен вход» или, без пароля склада
  /// (tokenless), 401.
  bool _keyGone(
    ({int status, bool ok, Map<String, Object?>? json}) reply,
    ManifestDescription d,
  ) =>
      (reply.status == 403 && reply.json?[d.needField] == 'login') ||
      (reply.status == 401 && service.record.tokenless);

  Future<({int status, bool ok, Map<String, Object?>? json})> _ask(
    ManifestDescription d,
    Uri base,
    ManifestCall call,
    Map<String, String> credentials,
    ManifestVars vars,
  ) async {
    // Только читающие вопросы из api.only; запись и расчёты — никогда.
    if (!d.only.contains(call.action) ||
        ManifestDescription.writeNames.contains(call.action) ||
        ManifestDescription.checkNames.contains(call.action)) {
      return (status: 0, ok: false, json: null);
    }
    try {
      final response = await _transport.send(
        HttpRequestData(
          method: d.method,
          uri: ManifestConnector.actionUri(d, base, call.action),
          headers: ManifestConnector.headersFor(d, credentials),
          body: jsonEncode(askBody(call.body, const <String, String>{}, vars)),
          timeout: ManifestConnector.requestTimeout,
        ),
      );
      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(response.body);
        json = decoded is Map<String, Object?> ? decoded : null;
      } on FormatException {
        json = null;
      }
      return (status: response.statusCode, ok: response.isSuccess, json: json);
    } on Object {
      return (status: 0, ok: false, json: null);
    }
  }

  static int? _int(Object? value) => value is int
      ? value
      : value is double && value == value.roundToDouble()
          ? value.toInt()
          : null;
}

enum _Outcome { ok, idle, busy, failed }
