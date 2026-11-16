/// Виджеты рабочего стола Android (ADR-034): канал `tridot/homescreen`.
///
/// Три виджета: «Сегодня» (`today`), «Быстрый ввод» (`quick`), «Сегодня и
/// ввод» (`combo`). Данные не уходят с устройства: приложение отдаёт
/// системе снимок ([HomeScreenSnapshot]), а нажатия на виджете возвращаются
/// очередью отметок ([HomeScreenOp]) и просьбами открыть поле или микрофон.
///
/// # Договор канала
///
/// Кодек — стандартный (`StandardMethodCodec`). Целые приходят в Android
/// как `Int` или `Long` — читать через `Number`.
///
/// ## Приложение → Android
///
/// | Метод        | Аргумент                 | Ответ                      |
/// |--------------|--------------------------|----------------------------|
/// | `state`      | —                        | `Map`, см. ниже            |
/// | `sync`       | `String` — снимок (JSON) | `null`                     |
/// | `pending`    | —                        | `List<Map>` — очередь      |
/// | `ack`        | `{"upTo": int}`          | `null`                     |
/// | `pin`        | `{"kind": String}`       | `bool`                     |
/// | `takeLaunch` | —                        | `"compose"`, `"voice"`, `null` |
///
/// `state` →
/// `{"supported": true, "canPin": true,
///   "installed": {"today": 1, "quick": 0, "combo": 0},
///   "needsSnapshot": false}`.
/// `canPin` — лаунчер умеет добавлять виджет по просьбе приложения
/// (`requestPinAppWidget`, Android 8+). `installed` — сколько виджетов
/// каждого вида стоит на рабочем столе. `needsSnapshot` — виджет с
/// задачами есть, а снимка у системы нет.
///
/// `sync` — снимок целиком, строкой JSON (формат ниже): её можно хранить
/// как есть. Android хранит снимок, только пока стоит «Сегодня» или
/// «Сегодня и ввод» (иначе стирает), перерисовывает виджеты и ставит
/// будильник на начало следующего кадра.
///
/// `pending` → все неподтверждённые записи по порядку номеров:
/// `[{"seq": 12, "op": "done", "task": "task_…", "at": 1763300000000},
///   {"seq": 13, "op": "undo", "task": "task_…", "at": 1763300002000,
///    "doneAt": 1763300000000}]`.
/// `at` — когда нажали, `doneAt` — `at` отменяемой отметки; время —
/// миллисекунды эпохи. Ту же структуру можно вернуть строкой JSON.
/// Android записи сам не применяет и не теряет их, когда виджет убрали.
///
/// `ack` — записи с номерами не больше `upTo` применены (или пропущены):
/// их можно стереть. Приходит после `sync` со снимком уже без этих задач.
///
/// `pin` — `kind`: `"today"`, `"quick"` или `"combo"`. `true` — лаунчер
/// принял просьбу (дальше спрашивает человека сам), `false` — не умеет.
///
/// `takeLaunch` — чем открыли приложение (холодный запуск с виджета), один
/// раз: второй вызов и запуск из «Недавних» — `null`.
///
/// ## Android → приложение
///
/// | Метод            | Аргумент                 | Когда                    |
/// |------------------|--------------------------|--------------------------|
/// | `launch`         | `"compose"` или `"voice"` | Нажали поле или микрофон, приложение уже работает |
/// | `pendingChanged` | —                        | В очереди новая запись   |
/// | `needSnapshot`   | —                        | Виджет поставили, снимка нет |
///
/// Задача по нажатию на строку открывается прежним путём — каналом
/// `tridot/notify` (`openTask`, `takeLaunchTask`).
///
/// ## Снимок
///
/// ```json
/// {
///   "v": 1,
///   "mode": "text",
///   "voice": true,
///   "until": null,
///   "tasks": [
///     {"id": "task_1763290000000000_0", "title": "Сдать реестр по складу",
///      "note": "22 шт в ОК, 1 шт в уценке, арт. 67782"},
///     {"id": "task_1763290000000000_1", "title": "Купить хлеб",
///      "note": null}
///   ],
///   "frames": [
///     {"from": 0, "count": 2, "summary": "2 дела",
///      "alert": "просрочена 1 задача",
///      "rows": [
///        {"t": 0, "due": "вчера", "overdue": true, "counted": true,
///         "say": "вчера, просрочено"},
///        {"t": 1, "due": "вечером", "overdue": false, "counted": true}
///      ]},
///     {"from": 1763326800000, "count": 2, "summary": "2 дела",
///      "alert": "просрочены 2 задачи",
///      "rows": [
///        {"t": 0, "due": "14 ноября", "overdue": true, "counted": true,
///         "say": "14 ноября, просрочено"},
///        {"t": 1, "due": "вчера", "overdue": true, "counted": true,
///         "say": "вчера, просрочено"}
///      ]}
///   ]
/// }
/// ```
///
/// - `mode` — `"text"` или `"counts"`. В `"counts"` списки `tasks` и
///   `rows` пусты: показываются только `count`, `summary` и `alert`.
/// - `voice` — `false`: микрофон на виджете скрыть.
/// - `frames` — по возрастанию `from` (миллисекунды эпохи; у первого 0).
///   Сейчас действует последний кадр с `from` не позже текущего времени;
///   следующая перерисовка — в `from` следующего кадра.
/// - `until` — миллисекунды эпохи или `null`. После `until` снимок
///   устарел: вместо списка — просьба открыть Tridot.
/// - Строка: `t` — номер задачи в `tasks`; `due` — готовая подпись срока;
///   `overdue` — подпись цветом ошибки; `counted` — задача входит в
///   `count` (иначе это ближайшая задача на свободной строке, и «ещё N»
///   её не считает); `say` — подпись срока для чтения с экрана, есть
///   только у просроченных.
/// - Строк в кадре не больше 12, кадров — не больше 40; название не
///   длиннее 120 знаков, запись — 80, всё в одну строку.
/// - Все слова и склонения — в снимке: Android только выбирает кадр.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/homescreen/home_screen_actions.dart';
import '../../core/homescreen/home_screen_snapshot.dart';

export '../../core/homescreen/home_screen_actions.dart'
    show HomeScreenOp, HomeScreenOpKind;
export '../../core/homescreen/home_screen_snapshot.dart'
    show HomeScreenSnapshot;

/// Вид виджета.
enum HomeScreenKind {
  /// «Сегодня»: ближайшие и просроченные задачи.
  today,

  /// «Быстрый ввод»: поле и микрофон.
  quick,

  /// «Сегодня и ввод».
  combo,
}

/// Чем открыли приложение с виджета.
enum HomeScreenLaunch {
  /// Нажали поле «Что сделать?»: открыть поле ввода с клавиатурой.
  compose,

  /// Нажали микрофон: начать голосовой ввод.
  voice;

  static HomeScreenLaunch? parse(Object? value) => switch (value) {
        'compose' => HomeScreenLaunch.compose,
        'voice' => HomeScreenLaunch.voice,
        _ => null,
      };
}

/// Что сейчас с виджетами на рабочем столе.
final class HomeScreenState {
  const HomeScreenState({
    this.supported = false,
    this.canPin = false,
    this.installed = const <HomeScreenKind, int>{},
    this.needsSnapshot = false,
  });

  factory HomeScreenState.fromMap(Object? value) {
    if (value is! Map) return const HomeScreenState();
    final installed = value['installed'];
    return HomeScreenState(
      supported: value['supported'] == true,
      canPin: value['canPin'] == true,
      installed: <HomeScreenKind, int>{
        if (installed is Map)
          for (final kind in HomeScreenKind.values)
            if (installed[kind.name] case final int count when count > 0)
              kind: count,
      },
      needsSnapshot: value['needsSnapshot'] == true,
    );
  }

  /// Виджеты на этом устройстве есть.
  final bool supported;

  /// Лаунчер добавляет виджет по просьбе приложения.
  final bool canPin;

  /// Сколько виджетов каждого вида стоит (нулей нет).
  final Map<HomeScreenKind, int> installed;

  /// Виджет с задачами стоит, а снимка у системы нет.
  final bool needsSnapshot;

  bool has(HomeScreenKind kind) => (installed[kind] ?? 0) > 0;
}

/// Виджеты рабочего стола (ADR-034).
abstract interface class HomeScreenPlatform {
  /// Для этой платформы: канал на Android, иначе [UnsupportedHomeScreen].
  factory HomeScreenPlatform.current() => Platform.isAndroid
      ? MethodChannelHomeScreen()
      : const UnsupportedHomeScreen();

  /// Виджеты на этой платформе есть.
  bool get supported;

  Future<HomeScreenState> state();

  /// Отдаёт системе снимок [snapshot] целиком.
  Future<void> sync(HomeScreenSnapshot snapshot);

  /// Отметки с виджета, которые ещё не подтверждены.
  Future<List<HomeScreenOp>> pending();

  /// Записи с номерами не больше [upTo] применены.
  Future<void> ack(int upTo);

  /// Просит лаунчер добавить виджет [kind]; `false` — не умеет.
  Future<bool> pin(HomeScreenKind kind);

  /// Чем открыли приложение (один раз).
  Future<HomeScreenLaunch?> takeLaunch();

  /// Нажали поле или микрофон на виджете, приложение уже работает.
  Stream<HomeScreenLaunch> get launches;

  /// В очереди отметок новая запись.
  Stream<void> get pendingChanged;

  /// Системе нужен снимок заново (виджет только что поставили).
  Stream<void> get snapshotWanted;
}

/// Канал `tridot/homescreen` (Android: homescreen/HomeScreenChannel.kt).
final class MethodChannelHomeScreen implements HomeScreenPlatform {
  MethodChannelHomeScreen({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('tridot/homescreen') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<HomeScreenLaunch> _launches =
      StreamController<HomeScreenLaunch>.broadcast();
  final StreamController<void> _pending = StreamController<void>.broadcast();
  final StreamController<void> _wanted = StreamController<void>.broadcast();

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'launch':
        final launch = HomeScreenLaunch.parse(call.arguments);
        if (launch != null) _launches.add(launch);
      case 'pendingChanged':
        _pending.add(null);
      case 'needSnapshot':
        _wanted.add(null);
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  bool get supported => true;

  @override
  Future<HomeScreenState> state() async =>
      HomeScreenState.fromMap(await _invoke<Object?>('state'));

  @override
  Future<void> sync(HomeScreenSnapshot snapshot) =>
      _invoke<void>('sync', snapshot.encode());

  @override
  Future<List<HomeScreenOp>> pending() async =>
      parsePending(await _invoke<Object?>('pending'));

  /// Очередь из ответа `pending`: список записей или он же строкой JSON.
  /// Не записи пропускаются.
  static List<HomeScreenOp> parsePending(Object? value) {
    var list = value;
    if (list is String) {
      try {
        list = jsonDecode(list);
      } on FormatException {
        return const <HomeScreenOp>[];
      }
    }
    if (list is! List) return const <HomeScreenOp>[];
    return <HomeScreenOp>[
      for (final item in list)
        if (HomeScreenOp.parse(item) case final HomeScreenOp op) op,
    ];
  }

  @override
  Future<void> ack(int upTo) =>
      _invoke<void>('ack', <String, Object?>{'upTo': upTo});

  @override
  Future<bool> pin(HomeScreenKind kind) async =>
      await _invoke<bool>('pin', <String, Object?>{'kind': kind.name}) ?? false;

  @override
  Future<HomeScreenLaunch?> takeLaunch() async =>
      HomeScreenLaunch.parse(await _invoke<Object?>('takeLaunch'));

  @override
  Stream<HomeScreenLaunch> get launches => _launches.stream;

  @override
  Stream<void> get pendingChanged => _pending.stream;

  @override
  Stream<void> get snapshotWanted => _wanted.stream;
}

/// Не Android: виджетов рабочего стола нет.
final class UnsupportedHomeScreen implements HomeScreenPlatform {
  const UnsupportedHomeScreen();

  @override
  bool get supported => false;

  @override
  Future<HomeScreenState> state() async => const HomeScreenState();

  @override
  Future<void> sync(HomeScreenSnapshot snapshot) async {}

  @override
  Future<List<HomeScreenOp>> pending() async => const <HomeScreenOp>[];

  @override
  Future<void> ack(int upTo) async {}

  @override
  Future<bool> pin(HomeScreenKind kind) async => false;

  @override
  Future<HomeScreenLaunch?> takeLaunch() async => null;

  @override
  Stream<HomeScreenLaunch> get launches =>
      const Stream<HomeScreenLaunch>.empty();

  @override
  Stream<void> get pendingChanged => const Stream<void>.empty();

  @override
  Stream<void> get snapshotWanted => const Stream<void>.empty();
}
