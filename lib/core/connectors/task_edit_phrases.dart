import '../models/task.dart';
import '../skills/talk/talk_phrases.dart';
import 'due_parser.dart';
import 'task_rephrase.dart';
import 'utterance.dart';

/// Что меняется в задаче (ADR-033).
enum TaskEditKind {
  /// Срок или напоминание: «поставь время 11:00», «напомни в 9», «на
  /// завтра» сразу после разговора о задаче.
  due,

  /// «Напомни про них» без времени: задача та же, спросить «Когда?».
  remind,

  /// «Выбрать время» — ответ кнопкой на «Когда напомнить?».
  pickTime,

  /// Заметка: «запиши, что…», «добавь, что…», «отметь, что…».
  note,

  /// «Переименуй в …».
  rename,

  /// Пункты чек-листа: «добавь пункт …».
  items,
}

/// Правка текущей или названной задачи — результат [TaskEditPhrases.parse].
final class TaskEdit {
  const TaskEdit({
    required this.kind,
    this.target,
    this.quotedTarget = false,
    this.text,
    this.rawText,
    this.items = const <String>[],
    this.dueAt,
    this.precision,
    this.dueIssue = DueIssue.none,
    this.bare = false,
    this.dueText,
    this.explicitSet = false,
  });

  final TaskEditKind kind;

  /// Названная задача: «в эссен», «к задаче Эссен», «по эссену», «в
  /// «Эссен»». `null` — текущая задача (чат задачи, только что созданная
  /// или выбранная).
  final String? target;

  /// [target] в кавычках — только точное совпадение.
  final bool quotedTarget;

  /// Заметка ([TaskRephrase.note]) или новое название ([TaskRephrase.title]).
  final String? text;

  /// Заметка словами пользователя — для «создать новую задачу» вместо неё.
  final String? rawText;

  final List<String> items;

  final DateTime? dueAt;
  final DuePrecision? precision;
  final DueIssue dueIssue;

  /// Фраза — один срок без глагола («на завтра», «в пятницу утром»): о
  /// задаче, только если разговор о ней шёл только что.
  final bool bare;

  /// Срок словами пользователя («завтра в 9») — для фразы кнопки выбора
  /// задачи.
  final String? dueText;

  /// «Поставь срок …», «установи время …»: слово срока названо явно —
  /// так правку не спутать с созданием («поставь «Отчёт» на завтра»).
  final bool explicitSet;

  /// Поля для корпуса (`form`): kind, target, text, items, due, precision.
  Map<String, String> get form => <String, String>{
        'kind': kind.name,
        if (target != null) 'target': target!,
        if (text != null) 'text': text!,
        if (items.isNotEmpty) 'items': items.join('|'),
        if (dueAt != null) 'due': _iso(dueAt!),
        if (precision != null && dueAt != null) 'precision': precision!.name,
        if (dueIssue != DueIssue.none) 'issue': dueIssue.name,
        if (bare) 'bare': 'true',
      };

  static String _iso(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:'
        '${two(d.minute)}';
  }
}

/// Распознавание правок задачи (ADR-033) — чистая функция без хранилища:
/// какую задачу менять, решает коннектор.
abstract final class TaskEditPhrases {
  /// Глаголы заметки: после них — «что …» или «заметку …».
  static const Set<String> _noteVerbs = <String>{
    'запиши',
    'запишите',
    'записать',
    'допиши',
    'добавь',
    'добавьте',
    'добавить',
    'отметь',
    'отметьте',
    'пометь',
    'внеси',
    'занеси',
    'зафиксируй',
  };

  static const Set<String> _noteNouns = <String>{
    'заметку',
    'заметка',
    'примечание',
    'комментарий',
  };

  static const Set<String> _itemNouns = <String>{
    'пункт',
    'пункты',
    'подпункт',
    'подпункты',
  };

  static const Set<String> _renameVerbs = <String>{
    'переименуй',
    'переименуйте',
    'переименовать',
  };

  static const Set<String> _setVerbs = <String>{
    'поставь',
    'поставьте',
    'установи',
    'назначь',
    'выстави',
    'укажи',
    'сделай',
  };

  static const Set<String> _setNouns = <String>{
    'время',
    'срок',
    'дедлайн',
    'напоминание',
    'дату',
  };

  static const Set<String> _remindVerbs = <String>{
    'напомни',
    'напомните',
    'напомнить',
  };

  /// Предлоги перед названием задачи.
  static const Set<String> _targetPrepositions = <String>{
    'в',
    'во',
    'к',
    'по',
    'для',
    'про',
    'о',
    'об',
  };

  static const Set<String> _taskNouns = <String>{
    'задаче',
    'задачу',
    'задача',
    'задачи',
    'задачке',
  };

  /// «Запиши в список, что…» — не название задачи.
  static const Set<String> _genericPlaces = <String>{
    'список',
    'заметки',
    'заметку',
    'блокнот',
    'задачи',
    'дела',
    'память',
    'напоминания',
  };

  /// Слова, которые не меняют смысла правки.
  static const Set<String> _extras = <String>{
    'пожалуйста',
    'мне',
    'ей',
    'ему',
    'им',
    'еще',
    'ещё',
    'тоже',
    'также',
    'давай',
    'тогда',
    'ну',
    'а',
    'и',
    'так',
    'туда',
    'сюда',
    'слушай',
    'еe',
  };

  /// Слова вокруг одного срока: «давай на завтра», «лучше в 9».
  static const Set<String> _bareExtras = <String>{
    'на',
    'давай',
    'тогда',
    'лучше',
    'пусть',
    'ну',
    'пожалуйста',
    'можно',
    'а',
    'и',
  };

  /// Правка в [utterance] или `null`, если фраза не о правке задачи.
  ///
  /// Одна дата без глагола ([TaskEdit.bare]) — только когда о задаче
  /// говорили только что ([Utterance.recentConnectorId] — задачи) или
  /// сообщение пришло в чате задачи.
  static TaskEdit? parse(Utterance utterance, {String tasksId = 'tasks'}) {
    if (utterance.isQuestion || utterance.unbalancedQuotes) return null;
    if (utterance.hashtags.isNotEmpty) return null;
    final tokens = utterance.tokens;
    if (tokens.isEmpty) return null;
    if (TalkPhrases.recognize(utterance.original) != null) return null;
    final words = utterance.words;

    final pick = _pickTime(utterance);
    if (pick != null) return pick;

    // Заметка: глагол и «что» (или «заметку») после него.
    for (var v = 0; v < tokens.length; v++) {
      final word = tokens[v].text;
      if (_noteVerbs.contains(word)) {
        final note = _note(utterance, v);
        if (note != null) return note;
        final items = _items(utterance, v);
        if (items != null) return items;
      }
      if (_renameVerbs.contains(word)) return _rename(utterance, v);
    }

    // Срок: «поставь время 11:00», «напомни в 9», «напомни про них».
    final remindAt = words.indexWhere(_remindVerbs.contains);
    final setAt = words.indexWhere(_setVerbs.contains);
    final verbAt = remindAt >= 0 ? remindAt : setAt;
    if (verbAt >= 0) return _due(utterance, verbAt, remind: remindAt >= 0);

    // Один срок без глагола — только в разговоре о задаче.
    if (utterance.chatTaskId == null &&
        utterance.recentConnectorId != tasksId) {
      return null;
    }
    // Одно слово («сегодня», «вчера») в главном чате — подсказка роли
    // (приходы склада), если только помощник не спросил «Когда?».
    if (utterance.chatTaskId == null &&
        !utterance.awaitingAnswer &&
        words.length < 2) {
      return null;
    }
    final due = utterance.due;
    if (due.spans.isEmpty || words.first == 'до') return null;
    final rest = utterance.tokensOutside(due.spans);
    if (!rest.every((UtteranceToken t) => _bareExtras.contains(t.text))) {
      return null;
    }
    return TaskEdit(
      kind: TaskEditKind.due,
      dueAt: due.dueAt,
      precision: due.dueAt == null ? null : due.precision,
      dueIssue: due.issue,
      bare: true,
      dueText: _dueText(utterance),
    );
  }

  static String? _dueText(Utterance utterance) {
    final spans = utterance.due.spans.where((CharSpan s) => s.length > 0);
    if (spans.isEmpty) return null;
    return spans
        .map((CharSpan s) => utterance.original.substring(s.start, s.end))
        .join(' ')
        .trim();
  }

  /// «Выбрать время», «выбрать время для «Эссен»» — кнопка вопроса
  /// «Когда напомнить?».
  static TaskEdit? _pickTime(Utterance utterance) {
    final words = utterance.words;
    if (words.length < 2 || words.length > 3) return null;
    if (!(words[0] == 'выбрать' || words[0] == 'выбери') ||
        words[1] != 'время') {
      return null;
    }
    if (words.length == 3 && words[2] != 'для') return null;
    final quoted = utterance.quotedTitles;
    if (quoted.length > 1) return null;
    return TaskEdit(
      kind: TaskEditKind.pickTime,
      target: quoted.isEmpty ? null : quoted.single.text,
      quotedTarget: quoted.isNotEmpty,
    );
  }

  /// Задача, названная словами [from]..[to) или кавычками: «в эссен»,
  /// «к задаче Эссен», «по эссену». `('', false)` — не названа; `null` —
  /// это не название (лишние слова).
  static (String?, bool)? _target(
    Utterance utterance,
    int from,
    int to, {
    bool allowBareName = false,
  }) {
    final tokens = utterance.tokens;
    final quoted = utterance.quotedTitles;
    var i = from;
    while (i < to && _extras.contains(tokens[i].text)) {
      i++;
    }
    var end = to;
    while (end > i && _extras.contains(tokens[end - 1].text)) {
      end--;
    }
    if (quoted.length == 1) {
      final span = quoted.single.span;
      final start = from < tokens.length
          ? tokens[from].span.start
          : utterance.original.length;
      final stop = to < tokens.length
          ? tokens[to].span.start
          : utterance.original.length;
      if (span.start >= start && span.end <= stop) {
        // Вокруг кавычек — только предлог и «задаче».
        for (var k = i; k < end; k++) {
          final w = tokens[k].text;
          if (!_targetPrepositions.contains(w) && !_taskNouns.contains(w)) {
            return null;
          }
        }
        return (quoted.single.text, true);
      }
    }
    if (i >= end) return (null, false);
    var hadPreposition = false;
    if (_targetPrepositions.contains(tokens[i].text)) {
      hadPreposition = true;
      i++;
    }
    if (i < end && _taskNouns.contains(tokens[i].text)) {
      hadPreposition = true;
      i++;
    }
    if (i >= end) return hadPreposition ? (null, false) : null;
    if (!hadPreposition && !allowBareName) return null;
    // «В среду запиши, что …» — срок, а не задача; «в список», «в
    // заметки» — просто «запиши».
    for (var k = i; k < end; k++) {
      if (Utterance.isCovered(tokens[k], utterance.due.spans)) {
        return (null, false);
      }
    }
    if (end - i == 1 && _genericPlaces.contains(tokens[i].text)) {
      return (null, false);
    }
    final name = <String>[
      for (var k = i; k < end; k++) tokens[k].original,
    ];
    if (name.length > 4) return null;
    final keys = <String>[for (var k = i; k < end; k++) tokens[k].text];
    if (keys.every(TaskRephrase.pronouns.contains)) return (null, false);
    if (keys.any(_noteVerbs.contains) || keys.any(_remindVerbs.contains)) {
      return null;
    }
    return (name.join(' '), false);
  }

  /// Заметка после глагола [v]: «… запиши, что …», «добавь заметку: …».
  static TaskEdit? _note(Utterance utterance, int v) {
    final tokens = utterance.tokens;
    var marker = -1;
    for (var k = v + 1; k < tokens.length; k++) {
      final w = tokens[k].text;
      if (w == 'что' || _noteNouns.contains(w)) {
        marker = k;
        break;
      }
    }
    if (marker < 0) return null;
    final before = _target(utterance, 0, v, allowBareName: true);
    final between = _target(utterance, v + 1, marker);
    if (before == null || between == null) return null;
    final (beforeName, beforeQuoted) = before;
    final (betweenName, betweenQuoted) = between;
    if (beforeName != null && betweenName != null) return null;
    final raw = utterance.original.substring(tokens[marker].span.end);
    final rawClean = raw.replaceFirst(RegExp(r'^[\s:,—–-]+'), '').trim();
    if (rawClean.isEmpty) return null;
    final text = TaskRephrase.note(rawClean);
    if (text.isEmpty) return null;
    return TaskEdit(
      kind: TaskEditKind.note,
      target: beforeName ?? betweenName,
      quotedTarget: beforeName != null ? beforeQuoted : betweenQuoted,
      text: text,
      rawText: rawClean,
    );
  }

  /// «Добавь пункт молоко», «добавь в «Покупки» пункты хлеб, сыр и чай».
  static TaskEdit? _items(Utterance utterance, int v) {
    final tokens = utterance.tokens;
    var marker = -1;
    for (var k = v + 1; k < tokens.length; k++) {
      if (_itemNouns.contains(tokens[k].text)) {
        marker = k;
        break;
      }
    }
    if (marker < 0) return null;
    final before = _target(utterance, 0, v, allowBareName: true);
    final between = _target(utterance, v + 1, marker);
    if (before == null || between == null) return null;
    final (beforeName, beforeQuoted) = before;
    final (betweenName, betweenQuoted) = between;
    if (beforeName != null && betweenName != null) return null;
    var raw = utterance.original.substring(tokens[marker].span.end);
    final quoted = utterance.quotedTitles;
    // Название задачи в кавычках после пунктов — не пункт.
    if (quoted.length == 1 &&
        quoted.single.span.start >= tokens[marker].span.end) {
      return null;
    }
    raw = raw.replaceFirst(RegExp(r'^[\s:,—–-]+'), '');
    final items = <String>[
      for (final part in raw.split(RegExp(r'\s*(?:[,;]|\s+и\s+)\s*')))
        if (part.replaceAll(RegExp(r'[\s.!…]+$'), '').trim() case final String p
            when p.isNotEmpty)
          p[0].toUpperCase() + p.substring(1),
    ];
    if (items.isEmpty) return null;
    return TaskEdit(
      kind: TaskEditKind.items,
      target: beforeName ?? betweenName,
      quotedTarget: beforeName != null ? beforeQuoted : betweenQuoted,
      items: items,
    );
  }

  /// «Переименуй в Отчёт», «переименуй её в «Отчёт за май»», «переименуй
  /// эссен в Эссен склад».
  static TaskEdit? _rename(Utterance utterance, int v) {
    final tokens = utterance.tokens;
    final quoted = utterance.quotedTitles;
    var into = -1;
    for (var k = v + 1; k < tokens.length; k++) {
      if (tokens[k].text == 'в' || tokens[k].text == 'на') {
        into = k;
        break;
      }
    }
    String? newTitle;
    var targetEnd = into < 0 ? tokens.length : into;
    if (into >= 0) {
      final rest = utterance.original.substring(tokens[into].span.end);
      newTitle = rest.trim();
    }
    String? target;
    var targetQuoted = false;
    if (quoted.length == 2) {
      target = quoted.first.text;
      targetQuoted = true;
      newTitle = quoted.last.text;
    } else if (quoted.length == 1 && into >= 0) {
      if (quoted.single.span.start > tokens[into].span.start) {
        newTitle = quoted.single.text;
      } else {
        target = quoted.single.text;
        targetQuoted = true;
      }
    }
    if (newTitle == null) return null;
    if (target == null) {
      final names = <String>[
        for (var k = v + 1; k < targetEnd; k++)
          if (!_extras.contains(tokens[k].text) &&
              !_taskNouns.contains(tokens[k].text) &&
              !TaskRephrase.pronouns.contains(tokens[k].text))
            tokens[k].original,
      ];
      if (names.length > 4) return null;
      if (names.isNotEmpty) target = names.join(' ');
    }
    final clean =
        TaskRephrase.title(newTitle.replaceAll(RegExp('[«»"“”„]'), ''));
    if (clean.isEmpty) return null;
    return TaskEdit(
      kind: TaskEditKind.rename,
      target: target,
      quotedTarget: targetQuoted,
      text: clean,
    );
  }

  /// Срок после «напомни» или «поставь»: всё, кроме срока, — слова правки
  /// и, может быть, название задачи («напомни про эссен в 9»).
  static TaskEdit? _due(Utterance utterance, int v, {required bool remind}) {
    final tokens = utterance.tokens;
    final due = utterance.due;
    // Будильник и таймер — навык «Будильник», не срок задачи.
    if (utterance.words.any(
      (String w) => w.startsWith('будильн') || w.startsWith('таймер'),
    )) {
      return null;
    }
    // «Поставь задачу на 30 февраля» — создание, а не правка.
    if (!remind && utterance.words.any(_taskNouns.contains)) return null;
    final rest = <UtteranceToken>[
      for (final t in utterance.tokensOutside(due.spans))
        if (t.index != v &&
            !_extras.contains(t.text) &&
            !_setNouns.contains(t.text) &&
            t.text != 'на')
          t,
    ];
    // До глагола — только обращение или название («по эссену напомни…»).
    String? target;
    var targetQuoted = false;
    final quoted = utterance.quotedTitles;
    final names = <UtteranceToken>[];
    var sawPreposition = false;
    for (final t in rest) {
      if (_targetPrepositions.contains(t.text)) {
        sawPreposition = true;
        continue;
      }
      if (_taskNouns.contains(t.text)) continue;
      if (TaskRephrase.pronouns.contains(t.text)) {
        sawPreposition = true;
        continue;
      }
      names.add(t);
    }
    if (quoted.length > 1) return null;
    if (quoted.length == 1) {
      if (names.isNotEmpty) return null;
      target = quoted.single.text;
      targetQuoted = true;
    } else if (names.isNotEmpty) {
      // «Напомни купить хлеб в 9» — новое дело, а не правка.
      if (!sawPreposition || names.length > 3 || !remind) return null;
      // «Напомни про эссен завтра» — задача названа; найдёт её коннектор,
      // а если такой нет — создаст новую по обычному разбору.
      target = names.map((UtteranceToken t) => t.original).join(' ');
    }
    if (!remind &&
        !tokens.any((UtteranceToken t) => _setNouns.contains(t.text))) {
      // «Поставь на завтра» без «время/срок» — тоже правка срока.
      if (due.spans.isEmpty) return null;
    }
    if (due.spans.isEmpty) {
      if (!remind) return null;
      // «Напомни» без срока и без названия — не правка: «напомни» —
      // просьба без предмета.
      if (target == null && !sawPreposition) return null;
      return TaskEdit(
        kind: TaskEditKind.remind,
        target: target,
        quotedTarget: targetQuoted,
      );
    }
    return TaskEdit(
      kind: TaskEditKind.due,
      target: target,
      quotedTarget: targetQuoted,
      dueAt: due.dueAt,
      precision: due.dueAt == null ? null : due.precision,
      dueIssue: due.issue,
      dueText: _dueText(utterance),
      explicitSet: !remind &&
          tokens.any((UtteranceToken t) => _setNouns.contains(t.text)),
    );
  }
}
