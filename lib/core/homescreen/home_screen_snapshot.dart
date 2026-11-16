/// Снимок для виджетов рабочего стола (ADR-034): что показать на «Сегодня»
/// сейчас и что — после каждой перемены (полночь, срок задачи, Новый
/// год), пока приложение закрыто.
///
/// Все слова и склонения — здесь: Android только выбирает кадр по
/// времени. Снимок лежит на устройстве (SharedPreferences
/// `tridot_homescreen`, вне резервной копии) и никуда не отправляется; с
/// выключенным «Показывать текст задач» в нём нет ни названий, ни id, ни
/// записей — только числа и готовые фразы.
library;

import 'dart:convert';

import '../formatting/due_format.dart';
import '../formatting/one_line.dart';
import '../formatting/plural.dart';
import '../formatting/today_format.dart';
import '../models/task.dart';

/// Задача в снимке: то, что человек увидит на виджете.
final class HomeScreenTask {
  const HomeScreenTask({required this.id, required this.title, this.note});

  final String id;

  /// Название в одну строку ([HomeScreenPlan.maxTitle]).
  final String title;

  /// Последняя запись в задаче (ADR-033) в одну строку
  /// ([HomeScreenPlan.maxNote]); `null` — записей нет.
  final String? note;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'note': note,
      };
}

/// Строка кадра: задача и подпись её срока на этот отрезок времени.
final class HomeScreenRow {
  const HomeScreenRow({
    required this.task,
    required this.due,
    required this.overdue,
    required this.counted,
  });

  final HomeScreenTask task;

  /// Срок коротко: «11:00», «вечером», «без времени», «вчера», «завтра
  /// в 10:00», «15 ноября». Без слова «просрочено»: его заменяет цвет.
  final String due;

  final bool overdue;

  /// Входит в число дел кадра: просрочена или на сегодня. Ближайшие
  /// задачи, которыми заполнены свободные строки, — нет.
  final bool counted;

  /// Срок для чтения с экрана: у просроченной — «вчера, просрочено»
  /// (цвета диктор не видит), иначе `null` — читается [due].
  String? get say => overdue ? '$due, просрочено' : null;

  String get _key => '${task.id}\n$due\n$overdue\n$counted';
}

/// Кадр: вид виджета с [from] до начала следующего кадра.
final class HomeScreenFrame {
  const HomeScreenFrame({
    this.from,
    required this.count,
    required this.summary,
    this.alert,
    this.rows = const <HomeScreenRow>[],
  });

  /// С какого момента кадр верен; `null` — первый кадр, с самого начала.
  final DateTime? from;

  /// Сколько дел: просроченные и на сегодня, все, а не только видимые.
  final int count;

  /// «3 дела», «дел нет».
  final String summary;

  /// «просрочена 1 задача»; `null` — просроченных нет.
  final String? alert;

  /// Строки по порядку, не больше [HomeScreenPlan.maxRows]; пусто, если
  /// текст задач показывать нельзя.
  final List<HomeScreenRow> rows;

  HomeScreenFrame startingAt(DateTime from) => HomeScreenFrame(
        from: from,
        count: count,
        summary: summary,
        alert: alert,
        rows: rows,
      );

  /// Тот же вид, что у [other] (начало не сравнивается).
  bool sameContent(HomeScreenFrame other) {
    if (count != other.count ||
        summary != other.summary ||
        alert != other.alert ||
        rows.length != other.rows.length) {
      return false;
    }
    for (var i = 0; i < rows.length; i++) {
      if (rows[i]._key != other.rows[i]._key) return false;
    }
    return true;
  }
}

/// Снимок: таблица задач и кадры по времени.
final class HomeScreenSnapshot {
  const HomeScreenSnapshot({
    required this.showText,
    required this.voice,
    required this.frames,
    this.until,
  });

  /// Версия формата (`v`).
  static const int version = 1;

  /// Текст задач показывать можно (`mode: "text"`); иначе — только числа
  /// (`mode: "counts"`), и ни одной задачи в снимке нет.
  final bool showText;

  /// Голосовой ввод на этом устройстве есть: микрофон на виджете нужен.
  final bool voice;

  /// После этого момента снимок устарел (кадров было больше
  /// [HomeScreenPlan.maxFrames]): виджет просит открыть Tridot. `null` —
  /// последний кадр верен без срока.
  final DateTime? until;

  /// Кадры по времени; первый — с [HomeScreenFrame.from] `null`.
  final List<HomeScreenFrame> frames;

  /// Задачи всех кадров без повторов, в порядке первого появления: строки
  /// в [toJson] ссылаются на них номером.
  List<HomeScreenTask> get tasks {
    final seen = <String>{};
    return <HomeScreenTask>[
      for (final frame in frames)
        for (final row in frame.rows)
          if (seen.add(row.task.id)) row.task,
    ];
  }

  /// Формат для канала `tridot/homescreen` (описан в
  /// `lib/app/homescreen/home_screen_channel.dart`).
  Map<String, Object?> toJson() {
    final table = tasks;
    final index = <String, int>{
      for (final (i, task) in table.indexed) task.id: i,
    };
    return <String, Object?>{
      'v': version,
      'mode': showText ? 'text' : 'counts',
      'voice': voice,
      'until': until?.millisecondsSinceEpoch,
      'tasks': <Object?>[for (final task in table) task.toJson()],
      'frames': <Object?>[
        for (final frame in frames)
          <String, Object?>{
            'from': frame.from?.millisecondsSinceEpoch ?? 0,
            'count': frame.count,
            'summary': frame.summary,
            'alert': frame.alert,
            'rows': <Object?>[
              for (final row in frame.rows)
                <String, Object?>{
                  't': index[row.task.id],
                  'due': row.due,
                  'overdue': row.overdue,
                  'counted': row.counted,
                  if (row.say case final String say) 'say': say,
                },
            ],
          },
      ],
    };
  }

  /// Снимок строкой JSON: так он уходит в канал и так сравнивается с уже
  /// отправленным.
  String encode() => jsonEncode(toJson());
}

/// Строит снимок из активных задач.
abstract final class HomeScreenPlan {
  /// Не больше стольких строк в кадре: выше виджет не растягивается.
  static const int maxRows = 12;

  /// Не больше стольких кадров: дальше — [HomeScreenSnapshot.until].
  static const int maxFrames = 40;

  static const int maxTitle = 120;
  static const int maxNote = 80;

  /// Снимок на момент [now].
  ///
  /// - Только активные задачи со сроком: без срока на виджет не попадают.
  /// - Порядок — просроченные, на сегодня, ближайшие (в каждой группе как
  ///   в [active], у ближайших — по сроку); не больше [maxRows].
  /// - [showText] выключен — в снимке только числа и фразы.
  /// - Кадры — на каждую перемену после [now] ([boundaries]); одинаковые
  ///   подряд сливаются. Больше [maxFrames] — остальное отбрасывается, а
  ///   [HomeScreenSnapshot.until] — первая отброшенная перемена.
  ///
  /// Перемены — моменты местного времени на устройстве в момент расчёта:
  /// сменили часовой пояс — кадры сдвинуты, пока Tridot не откроют (как и
  /// расписание напоминаний).
  static HomeScreenSnapshot from(
    Iterable<Task> active, {
    required DateTime now,
    required bool showText,
    required bool voice,
  }) {
    final dated = _dated(active);
    final shown = <Task, HomeScreenTask>{};
    final frames = <HomeScreenFrame>[_frame(dated, now, showText, shown)];
    DateTime? until;
    // Расчёт останавливается на первой отброшенной перемене, поэтому не
    // растёт без предела: между двумя переменами вида — считаные полуночи.
    for (final at in _boundaries(dated, now)) {
      final next = _frame(dated, at, showText, shown);
      if (next.sameContent(frames.last)) continue;
      if (frames.length == maxFrames) {
        until = at;
        break;
      }
      frames.add(next.startingAt(at));
    }
    return HomeScreenSnapshot(
      showText: showText,
      voice: voice,
      frames: frames,
      until: until,
    );
  }

  /// Вид виджета в момент [at] (без начала кадра).
  static HomeScreenFrame frameAt(
    Iterable<Task> active,
    DateTime at, {
    required bool showText,
  }) =>
      _frame(_dated(active), at, showText, <Task, HomeScreenTask>{});

  /// Моменты после [now], когда вид может измениться, по возрастанию:
  /// полуночи вокруг дня срока каждой задачи (за два дня до него подпись
  /// становится «послезавтра», через два дня после — датой вместо
  /// «вчера»), момент, с которого задача просрочена, и 1 января года срока
  /// и следующего (в подписи появляется или пропадает год).
  static List<DateTime> boundaries(Iterable<Task> active, DateTime now) =>
      _boundaries(_dated(active), now);

  static List<Task> _dated(Iterable<Task> active) => <Task>[
        for (final task in active)
          if (task.isActive && task.dueAt != null) task,
      ];

  static List<DateTime> _boundaries(List<Task> dated, DateTime now) {
    final from = now.millisecondsSinceEpoch;
    final moments = <int>{};
    void add(DateTime moment) {
      final at = moment.millisecondsSinceEpoch;
      if (at > from) moments.add(at);
    }

    for (final task in dated) {
      final due = task.dueAt!;
      for (var shift = -2; shift <= 2; shift++) {
        add(DateTime(due.year, due.month, due.day + shift));
      }
      add(_overdueFrom(task));
      add(DateTime(due.year));
      add(DateTime(due.year + 1));
    }
    final sorted = moments.toList()..sort();
    return <DateTime>[
      for (final at in sorted) DateTime.fromMillisecondsSinceEpoch(at),
    ];
  }

  /// Первый момент (целая миллисекунда), когда [isOverdue] уже верно.
  /// Срок со временем просрочен строго после него — отсюда плюс одна.
  static DateTime _overdueFrom(Task task) {
    final moment = overdueMoment(task)!;
    return task.duePrecision == DuePrecision.dateTime
        ? DateTime.fromMillisecondsSinceEpoch(
            moment.millisecondsSinceEpoch + 1,
          )
        : moment;
  }

  /// [shown] — уже подготовленные задачи: из кадра в кадр они те же.
  static HomeScreenFrame _frame(
    List<Task> dated,
    DateTime at,
    bool showText,
    Map<Task, HomeScreenTask> shown,
  ) {
    final overdue = <Task>[];
    final today = <Task>[];
    final upcoming = <(int, Task)>[];
    for (final (index, task) in dated.indexed) {
      switch (groupOf(task, at)) {
        case TaskGroup.overdue:
          overdue.add(task);
        case TaskGroup.today:
          today.add(task);
        case TaskGroup.tomorrow || TaskGroup.later:
          upcoming.add((index, task));
        case TaskGroup.noDate:
          break;
      }
    }
    final count = overdue.length + today.length;
    final rows = <HomeScreenRow>[];
    if (showText) {
      // Ближайшие — по сроку; при равном сроке — как в исходном списке.
      upcoming.sort(((int, Task) a, (int, Task) b) {
        final byDue = a.$2.dueAt!.compareTo(b.$2.dueAt!);
        return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
      });
      final ordered = <Task>[
        ...overdue,
        ...today,
        for (final (_, task) in upcoming) task,
      ];
      for (final (index, task) in ordered.take(maxRows).indexed) {
        rows.add(
          HomeScreenRow(
            task: shown[task] ??= _task(task),
            due: todayDueShort(task, at),
            overdue: index < overdue.length,
            counted: index < count,
          ),
        );
      }
    }
    return HomeScreenFrame(
      count: count,
      summary: count == 0 ? 'дел нет' : deeds(count),
      alert: overdue.isEmpty ? null : overdueSummary(overdue.length),
      rows: rows,
    );
  }

  static HomeScreenTask _task(Task task) {
    final note =
        task.notes.isEmpty ? '' : oneLine(task.notes.last.text, max: maxNote);
    return HomeScreenTask(
      id: task.id,
      title: oneLine(task.title, max: maxTitle),
      note: note.isEmpty ? null : note,
    );
  }
}
