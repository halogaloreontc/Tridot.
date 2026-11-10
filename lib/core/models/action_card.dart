/// Карточка действия с записью во внешнем приложении (ADR-013): что именно
/// изменится, от чьего имени и до какого времени действует. Под ответом
/// помощника — кнопки «Подтвердить» и «Отмена»; запись уходит только по
/// кнопке.
///
/// Один объект на карточку: его держит ожидание подтверждения
/// (`PendingConfirmation.payload`) и сообщение чата. Поля записи
/// ([commit], [stamp], [exp]) живут только в памяти и в историю чата не
/// пишутся: восстановленная после перезапуска карточка физически не может
/// отправить запись.
library;

/// Вид действия.
enum ActionKind {
  /// Перемещение товара между ячейками.
  move,

  /// Отметка проведения прихода (SV, 1С).
  post;

  static ActionKind? parse(Object? value) =>
      ActionKind.values.where((ActionKind k) => k.name == value).firstOrNull;
}

/// Состояние карточки.
enum ActionCardState {
  /// Ждёт «Подтвердить» или «Отмена».
  pending,

  /// Запись ушла, ответа ещё нет.
  sending,

  /// Склад выполнил.
  applied,

  /// Человек отказался.
  cancelled,

  /// Вышел срок или вопрос снят другим сообщением.
  expired,

  /// Пока карточка ждала, на складе изменилось: её сменила новая.
  replaced,

  /// Склад отказал — ничего не изменилось.
  failed,

  /// Итог неизвестен (обрыв связи): кнопка «Проверить» спрашивает склад,
  /// чем кончилось, и никогда не повторяет запись.
  unknown;

  static ActionCardState? parse(Object? value) => ActionCardState.values
      .where((ActionCardState s) => s.name == value)
      .firstOrNull;
}

/// Строка карточки: код подписи и значение. Подпись («Что», «Откуда»)
/// ставит виджет по коду; значение — уже очищенный текст сервера.
final class ActionCardLine {
  const ActionCardLine(this.label, this.value, {this.note = ''});

  /// `what`, `sku`, `qty`, `from`, `to`, `entry`, `content`, `sv`, `odin_c`,
  /// `stage`, `who`.
  final String label;
  final String value;

  /// Пометка к строке по коду: `to_empty` — ячейка пустая.
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
        'label': label,
        'value': value,
        if (note.isNotEmpty) 'note': note,
      };

  static ActionCardLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final value = json['value'];
    final note = json['note'];
    if (label is! String || value is! String) return null;
    return ActionCardLine(
      label,
      ActionCard.cardText(value),
      note: note is String ? note : '',
    );
  }
}

/// Карточка действия.
final class ActionCard {
  ActionCard({
    required this.rid,
    required this.connectorId,
    required this.kind,
    required this.login,
    required this.name,
    required this.deadline,
    required this.lines,
    this.warn = const <String>[],
    this.state = ActionCardState.pending,
    this.result = '',
    this.commit,
    this.stamp,
    this.exp,
  });

  /// Одноразовый ключ записи: 16 знаков `[0-9a-z]`. Новая карточка —
  /// новый ключ. Он же — id карточки в чате.
  final String rid;

  /// Коннектор, который выполнит действие: `warehouse`.
  final String connectorId;
  final ActionKind kind;

  /// От чьего имени: логин и имя на складе.
  final String login;
  final String name;

  /// До какого времени карточка действует (по часам устройства).
  final DateTime deadline;

  final List<ActionCardLine> lines;

  /// Предупреждения по коду: `to_empty`, `unplaced`.
  final List<String> warn;

  ActionCardState state;

  /// Итог одной строкой: «ПЕР-00042», «Склад отказал: …».
  String result;

  /// Точные поля записи из ответа расчёта. Только в памяти.
  final Map<String, Object?>? commit;

  /// Подпись карточки сервером. Только в памяти.
  final String? stamp;

  /// Срок карточки в секундах эпохи сервера. Только в памяти.
  final int? exp;

  /// Сохранить карточку, когда она стала [ActionCardState.sending], — до
  /// того, как запись уйдёт на склад. Ставит интерфейс (историю чата
  /// пишет он): приложение закрыли посреди записи — после перезапуска
  /// карточка «итог неизвестен» с «Проверить», а не «устарела». Только в
  /// памяти.
  Future<void> Function()? onSending;

  String get id => rid;

  bool get isPending => state == ActionCardState.pending;

  /// Можно спросить склад, чем кончилось («Проверить»).
  bool get canSettle => state == ActionCardState.unknown;

  /// Запись ещё можно отправить: ждёт ответа, срок не вышел и поля записи
  /// есть в памяти.
  bool canSend(DateTime now) =>
      isPending && now.isBefore(deadline) && commit != null && stamp != null;

  /// Срок вышел: ждущая карточка устаревает. `true` — состояние сменилось.
  bool expireIfDue(DateTime now) {
    if (!isPending || now.isBefore(deadline)) return false;
    state = ActionCardState.expired;
    return true;
  }

  /// Управляющие знаки, знаки направления текста и переводы строк.
  static final RegExp _controls = RegExp(
    '[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u202a-\\u202e'
    '\\u2066-\\u2069\\u061c\\ufeff]',
  );

  /// Длиннее этого строка карточки обрезается.
  static const int maxText = 80;

  /// Текст сервера для карточки: без управляющих знаков и знаков
  /// направления, в одну строку, не длиннее [maxText] знаков.
  static String cardText(Object? value, {int max = maxText}) {
    if (value == null) return '';
    final text = (value is String ? value : '$value')
        .replaceAll(_controls, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.runes.length <= max) return text;
    return '${String.fromCharCodes(text.runes.take(max - 1))}…';
  }

  /// Для истории чата: без [commit], [stamp] и [exp].
  Map<String, Object?> toJson() => <String, Object?>{
        'rid': rid,
        'connector': connectorId,
        'kind': kind.name,
        'login': login,
        'name': name,
        'deadline': deadline.toIso8601String(),
        'lines': <Map<String, Object?>>[
          for (final line in lines) line.toJson(),
        ],
        if (warn.isNotEmpty) 'warn': warn,
        'state': state.name,
        if (result.isNotEmpty) 'result': result,
      };

  /// Карточка из истории чата. Ждущая — устаревшая: записи без
  /// [commit]/[stamp] не бывает. Отправленная без ответа — «итог
  /// неизвестен»: «Проверить» спросит склад по [rid]. Повреждённая запись —
  /// `null`.
  static ActionCard? fromJson(Object? json) {
    if (json is! Map) return null;
    final rid = json['rid'];
    final connector = json['connector'];
    final kind = ActionKind.parse(json['kind']);
    final deadline = DateTime.tryParse('${json['deadline']}');
    final rawLines = json['lines'];
    if (rid is! String ||
        !RegExp(r'^[0-9a-z]{16}$').hasMatch(rid) ||
        connector is! String ||
        kind == null ||
        deadline == null ||
        rawLines is! List) {
      return null;
    }
    final login = json['login'];
    final name = json['name'];
    final result = json['result'];
    final warn = json['warn'];
    final state =
        ActionCardState.parse(json['state']) ?? ActionCardState.expired;
    return ActionCard(
      rid: rid,
      connectorId: connector,
      kind: kind,
      login: login is String ? cardText(login) : '',
      name: name is String ? cardText(name) : '',
      deadline: deadline,
      lines: <ActionCardLine>[
        for (final raw in rawLines)
          if (ActionCardLine.fromJson(raw) case final ActionCardLine line) line,
      ],
      warn: <String>[
        if (warn is List)
          for (final item in warn)
            if (item is String) item,
      ],
      state: switch (state) {
        ActionCardState.pending => ActionCardState.expired,
        ActionCardState.sending => ActionCardState.unknown,
        _ => state,
      },
      result: result is String ? cardText(result, max: 300) : '',
    );
  }
}

/// «Проверить» под карточкой с неизвестным итогом: спросить склад, чем
/// кончилось ([ActionCard.rid]). Запись не повторяется никогда.
final class ActionCardSettle {
  const ActionCardSettle(this.card);

  final ActionCard card;
}
