/// Ритм ленты чата (ADR-027): когда ставить метку времени над группой,
/// когда повторять имя помощника и какой промежуток над сообщением.
///
/// Чистый Dart без Flutter: одни правила у ленты приложения и у
/// веб-виджета, и их можно проверить таблицами без виджетов.
library;

import '../../core/formatting/due_format.dart';
import '../layout.dart';

/// Пауза, после которой над сообщением новая метка времени.
const Duration groupPause = Duration(minutes: 15);

/// Пауза, после которой имя помощника повторяется даже у того же автора.
const Duration authorPause = Duration(minutes: 10);

/// Один календарный день.
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// «14:05».
String chatTimeLabel(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

/// «Сегодня», «Вчера», «12 марта» — с заглавной: метка стоит отдельной
/// строкой.
String chatDayLabel(DateTime day, DateTime now) {
  final label = formatDay(day, now);
  return label[0].toUpperCase() + label.substring(1);
}

/// «Сегодня, 14:05» над группой сообщений.
String groupTimeLabel(DateTime at, DateTime now) =>
    '${chatDayLabel(DateTime(at.year, at.month, at.day), now)}, '
    '${chatTimeLabel(at)}';

/// Новая группа: первое сообщение, смена дня или пауза больше
/// [groupPause].
bool startsGroup(DateTime? previousAt, DateTime at) =>
    previousAt == null ||
    !sameDay(previousAt, at) ||
    at.difference(previousAt) > groupPause;

/// Имя помощника над ответом: в новой группе, при смене автора или после
/// паузы больше [authorPause] с его прошлого ответа. У сообщений
/// пользователя и неизвестных помощников ([authorId] `null`) имени нет.
bool showsAuthor({
  required String? authorId,
  required DateTime at,
  required bool newGroup,
  String? lastAuthorId,
  DateTime? lastReplyAt,
}) =>
    authorId != null &&
    (newGroup ||
        lastAuthorId != authorId ||
        lastReplyAt == null ||
        at.difference(lastReplyAt) > authorPause);

/// Промежуток над сообщением ([AppSpace]): в начале группы — 0 (отступ
/// даёт метка времени), после карточки — [AppSpace.afterCard], пузырь за
/// пузырём — [AppSpace.xs], ответ → пузырь и пузырь → ответ с именем —
/// [AppSpace.toUser], иначе [AppSpace.toReply].
double feedTopGap({
  required bool newGroup,
  required bool fromUser,
  required bool previousFromUser,
  required bool previousHadCard,
  required bool showAuthor,
}) {
  if (newGroup) return 0;
  if (previousHadCard) return AppSpace.afterCard;
  if (fromUser) return previousFromUser ? AppSpace.xs : AppSpace.toUser;
  return showAuthor && !previousFromUser ? AppSpace.toUser : AppSpace.toReply;
}

/// Индекс последнего элемента с каждым id: карточка списка или действия
/// стоит только под последним ответом с ней — после «кроме …» или «да»
/// текстом вопрос повторяется вместе с карточкой.
Map<String, int> lastIndexById<T>(List<T> items, String? Function(T) idOf) {
  final last = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    final id = idOf(items[i]);
    if (id != null) last[id] = i;
  }
  return last;
}

/// Как стоит сообщение в ленте.
typedef FeedBeat = ({bool newGroup, bool showAuthor, double topGap});

/// Проход по ленте сверху вниз: помнит, что было выше, и выдаёт
/// [FeedBeat] каждого сообщения. После строки — [placed] с тем, была ли
/// под ней карточка: от этого зависит промежуток над следующей.
final class ChatFeedRhythm {
  DateTime? _previousAt;
  bool _previousFromUser = false;
  bool _previousHadCard = false;
  String? _lastAuthorId;
  DateTime? _lastReplyAt;

  /// Выше ещё нет ни одного сообщения.
  bool get isEmpty => _previousAt == null;

  /// Помощник последнего ответа с известным автором.
  String? get lastAuthorId => _lastAuthorId;

  /// Место сообщения от [at]; [authorId] — помощник ответа или `null`.
  FeedBeat next({
    required DateTime at,
    required bool fromUser,
    String? authorId,
  }) {
    final newGroup = startsGroup(_previousAt, at);
    final showAuthor = showsAuthor(
      authorId: authorId,
      at: at,
      newGroup: newGroup,
      lastAuthorId: _lastAuthorId,
      lastReplyAt: _lastReplyAt,
    );
    final gap = feedTopGap(
      newGroup: newGroup,
      fromUser: fromUser,
      previousFromUser: _previousFromUser,
      previousHadCard: _previousHadCard,
      showAuthor: showAuthor,
    );
    _previousAt = at;
    _previousFromUser = fromUser;
    _previousHadCard = false;
    if (authorId != null) {
      _lastAuthorId = authorId;
      _lastReplyAt = at;
    }
    return (newGroup: newGroup, showAuthor: showAuthor, topGap: gap);
  }

  /// Под последней строкой стоит карточка (список, задача, ссылка).
  void placed({required bool hadCard}) => _previousHadCard = hadCard;

  /// Строка «думает…» под лентой: без метки времени, имя — если отвечает
  /// не тот, кто отвечал последним.
  FeedBeat working({String? authorId}) => (
        newGroup: false,
        showAuthor: authorId != null && authorId != _lastAuthorId,
        topGap: isEmpty ? 0 : AppSpace.toReply,
      );
}
