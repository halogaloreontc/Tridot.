import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/jobs/extension_card.dart';
import '../../core/jobs/job_placement.dart';
import '../../core/jobs/job_runner.dart';

/// Ход работы карточки: доля 0..1 (`null` — неизвестно) и стадия.
typedef JobTick = ({double? value, String? stage});

/// Связка задач расширений с интерфейсом: держит запущенные задачи по id
/// карточки, меняет состояние карточки на месте и сохраняет чат только при
/// смене состояния ([persist]). Ход работы живёт только в памяти
/// ([progressOf]) и обновляется не чаще 10 раз в секунду — экран чата от
/// него не перестраивается.
final class JobHub extends ChangeNotifier {
  JobHub({
    required this.runner,
    required this.persist,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final JobRunner runner;

  /// Сохранить чат [chatId] (карточка сменила состояние).
  final void Function(String chatId) persist;

  final DateTime Function() _now;

  final Map<String, ValueNotifier<JobTick?>> _progress =
      <String, ValueNotifier<JobTick?>>{};
  final Map<String, StreamSubscription<JobEvent>> _jobs =
      <String, StreamSubscription<JobEvent>>{};
  final Map<String, DateTime> _lastTick = <String, DateTime>{};

  /// Чат каждой идущей задачи: удаление чата отменяет его задачи.
  final Map<String, String> _chatOf = <String, String>{};

  /// Отложенное сохранение правок поля-текста (ссылка): не на каждую
  /// букву.
  final Map<String, Timer> _editTimers = <String, Timer>{};
  final Map<String, String> _editChats = <String, String>{};

  /// Через сколько после последней буквы сохраняется поле-текст.
  static const Duration editDelay = Duration(milliseconds: 800);

  /// Не чаще этого ход работы доходит до экрана.
  static const Duration tickInterval = Duration(milliseconds: 100);

  /// Ход работы карточки [cardId].
  ValueListenable<JobTick?> progressOf(String cardId) =>
      _progress.putIfAbsent(cardId, () => ValueNotifier<JobTick?>(null));

  bool isRunning(String cardId) => _jobs.containsKey(cardId);

  /// Запускает [request] для карточки [card] в чате [chatId]. [onFinished]
  /// — задача закончилась (готово, ошибка или отмена).
  void start(
    String chatId,
    ExtensionCard card,
    JobRequest request, {
    void Function(ExtensionCard card)? onFinished,
  }) {
    if (_jobs.containsKey(card.id)) return;
    card
      ..reset(_now())
      ..state = CardState.running
      ..cleanup = request.cleanup;
    (_progress[card.id] ??= ValueNotifier<JobTick?>(null)).value =
        (value: 0, stage: null);
    _flushEdit(card.id);
    persist(chatId);
    notifyListeners();
    _chatOf[card.id] = chatId;
    _jobs[card.id] = runner.start(request).listen(
      (JobEvent event) {
        switch (event) {
          case JobProgress(:final value, :final stage):
            _tick(card.id, value, stage);
          case JobDone():
            card
              ..state = CardState.done
              ..outputs = List<String>.of(event.outputs)
              ..outputDir = event.outputDir
              ..listing = List<String>.of(event.listing)
              ..listingMore = event.listingMore;
            _finish(chatId, card, onFinished);
          case JobFailed(:final code):
            card
              ..state = code == JobCodes.cancelled
                  ? CardState.cancelled
                  : CardState.failed
              ..errorCode = code == JobCodes.cancelled ? null : code;
            _finish(chatId, card, onFinished);
        }
      },
      onDone: () {
        // Поток кончился без итога: считаем ошибкой.
        if (card.state == CardState.running) {
          card
            ..state = CardState.failed
            ..errorCode = JobCodes.failed;
          _finish(chatId, card, onFinished);
        }
      },
    );
  }

  void _tick(String cardId, double? value, String? stage) {
    final now = _now();
    final last = _lastTick[cardId];
    final notifier = _progress[cardId];
    if (notifier == null) return;
    final sameStage = notifier.value?.stage == stage;
    if (last != null &&
        sameStage &&
        value != 1 &&
        now.difference(last) < tickInterval) {
      return;
    }
    _lastTick[cardId] = now;
    notifier.value = (value: value, stage: stage);
  }

  void _finish(
    String chatId,
    ExtensionCard card,
    void Function(ExtensionCard card)? onFinished,
  ) {
    unawaited(_jobs.remove(card.id)?.cancel());
    _chatOf.remove(card.id);
    _lastTick.remove(card.id);
    _progress[card.id]?.value = null;
    card
      ..cleanup = <String>[]
      ..progress = null
      ..stage = null
      ..updatedAt = _now();
    persist(chatId);
    notifyListeners();
    onFinished?.call(card);
  }

  /// «Отмена»: временные файлы убирает исполнитель.
  void cancel(String cardId) => runner.cancel(cardId);

  /// Чат [chatId] удаляют: его задачи останавливаются (ffmpeg и yt-dlp не
  /// работают дальше, распаковка не пишет в папку удалённой сессии).
  void cancelChat(String chatId) {
    for (final MapEntry(:key, :value) in _chatOf.entries.toList()) {
      if (value == chatId) runner.cancel(key);
    }
  }

  /// Все задачи останавливаются: «Очистить историю», выход из приложения.
  void cancelAll() {
    for (final id in _chatOf.keys.toList()) {
      runner.cancel(id);
    }
  }

  /// «Повторить»: снова форма с теми же значениями.
  void retry(String chatId, ExtensionCard card) {
    if (_jobs.containsKey(card.id)) return;
    card.reset(_now());
    persist(chatId);
    notifyListeners();
  }

  /// Значения формы поменялись: сохранить чат.
  void edited(String chatId, ExtensionCard card) {
    card.updatedAt = _now();
    persist(chatId);
    notifyListeners();
  }

  /// Поле-текст (ссылка) поменялось: значение уже в карточке, чат
  /// сохраняется через [editDelay] после последней буквы, экран не
  /// перестраивается на каждую букву.
  void editedLater(String chatId, ExtensionCard card) {
    card.updatedAt = _now();
    _editTimers.remove(card.id)?.cancel();
    _editChats[card.id] = chatId;
    _editTimers[card.id] = Timer(editDelay, () => _flushEdit(card.id));
  }

  void _flushEdit(String cardId) {
    _editTimers.remove(cardId)?.cancel();
    final chatId = _editChats.remove(cardId);
    if (chatId != null) persist(chatId);
  }

  /// Карточка, прерванная перезапуском: временные пути (`.part`,
  /// временные папки) удаляются один раз. `true` — что-то убрано.
  bool sweepInterrupted(String chatId, ExtensionCard card) {
    if (card.state != CardState.interrupted || card.cleanup.isEmpty) {
      return false;
    }
    if (_jobs.containsKey(card.id)) return false;
    for (final path in card.cleanup) {
      // Только временные пути этой карточки, не любой путь из файла чата.
      if (JobPlacement.isTempFor(path, card.id)) {
        IsolateJobRunner.removeQuietly(path);
      }
    }
    card.cleanup = <String>[];
    persist(chatId);
    return true;
  }

  @override
  void dispose() {
    for (final id in _editTimers.keys.toList()) {
      _flushEdit(id);
    }
    for (final job in _jobs.values) {
      unawaited(job.cancel());
    }
    for (final id in _jobs.keys.toList()) {
      runner.cancel(id);
    }
    _jobs.clear();
    for (final notifier in _progress.values) {
      notifier.dispose();
    }
    super.dispose();
  }
}
