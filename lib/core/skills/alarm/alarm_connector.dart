import '../../connectors/connector.dart';
import '../../formatting/due_format.dart';
import '../../models/task.dart';
import '../../services/clock.dart';
import 'alarm_phrases.dart';

export 'alarm_phrases.dart';

/// Где ставится будильник: приложение «Часы» телефона (ADR-029). Ядро не
/// знает о платформе — интерфейс даёт lib/app (канал `tridot/notify`).
abstract interface class AlarmSetter {
  /// На этом устройстве будильник ставится в принципе (Android).
  bool get supported;

  /// Есть приложение «Часы», которое принимает будильник и таймер.
  Future<bool> canSet();

  /// Открывает «Часы» с заполненным будильником или таймером; человек
  /// подтверждает там. `false` — открыть не вышло.
  Future<bool> set(AlarmRequest request);
}

/// Навык «Будильник» (ADR-029): будильник и таймер в приложении «Часы».
///
/// Сам ничего не звонит и ничего не хранит: по кнопке «Поставить»
/// открываются «Часы» с заполненным будильником (Android,
/// `AlarmClock.ACTION_SET_ALARM`), и человек подтверждает там. День в
/// «Часах» не выбрать — будильник дальше чем через сутки («в пятницу в
/// 7») предлагается заменить напоминанием (задачей со сроком). Где «Часов»
/// нет (компьютер, телефон без них), предлагает то же напоминание.
///
/// Зона ведущего оповещений ([DutyZones.notifications]): отвечает Нода.
final class AlarmConnector implements Connector, ConnectorHealth, IntentTarget {
  AlarmConnector({this.setter, this.clock = const SystemClock()});

  /// Часы для «на 7» — ближайшие 7:00.
  final Clock clock;

  static const String id = 'alarm';

  /// Уверенность явной просьбы: «поставь будильник на 7», «таймер на 5
  /// минут».
  static const double confidence = 0.9;

  /// Где ставить; `null` — нигде (компьютер, тесты).
  final AlarmSetter? setter;

  /// Ответ на вопрос «Поставить …?».
  static const String confirmCommand = 'alarm.confirm';

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Будильник',
        description: 'Ставит будильник и таймер в приложении «Часы» — '
            'там их и подтверждаете.',
        examples: <String>[
          'поставь будильник на 7:00',
          'разбуди меня в 6:30',
          'будильник по будням на 7',
          'таймер на 5 минут',
        ],
        kind: ExtensionKind.skill,
      );

  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  /// Как выполнить команду по подсказке запасного слоя (ADR-045).
  static const Map<String, IntentRecipe> intentRecipes = <String, IntentRecipe>{
    'alarm.set': IntentRecipe(
      carriers: <String>['поставь будильник на', 'разбуди меня'],
      ask: 'поставь будильник',
      accepts: <String>{'alarm.date', 'alarm.clarify'},
      example: 'поставь будильник на 7:00',
    ),
    'alarm.date': IntentRecipe(
      carriers: <String>['поставь будильник', 'поставь будильник на'],
      ask: 'поставь будильник',
      accepts: <String>{'alarm.set', 'alarm.clarify'},
      example: 'поставь будильник в пятницу в 7',
    ),
    'alarm.timer': IntentRecipe(
      carriers: <String>['поставь таймер на', 'засеки'],
      ask: 'поставь таймер',
      accepts: <String>{'alarm.clarify'},
      example: 'таймер на 10 минут',
    ),
    'alarm.clarify': IntentRecipe(
      carriers: <String>['поставь будильник на', 'поставь таймер на'],
      ask: 'поставь будильник',
      accepts: <String>{'alarm.set', 'alarm.date', 'alarm.timer'},
      example: 'поставь будильник на 7:00',
    ),
  };

  @override
  ConnectorMatch? matchAs(
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  ) =>
      matchByRecipe(this, intentRecipes, commandId, utterance, analyze);

  @override
  String? intentExample(String commandId) =>
      intentRecipes[commandId]?.example ?? intentRecipes[commandId]?.ask;

  @override
  ConnectorMatch? match(Utterance utterance) {
    final request = AlarmPhrases.parse(utterance, clock.now());
    if (request == null) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: request.commandId,
      confidence: confidence,
      payload: request,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) return _answer(payload, session);
    final request = payload! as AlarmRequest;
    switch (request.issue) {
      case AlarmIssue.noTime:
        return session.reply(
          'alarm.clarify.time',
          intent: AlarmPhrases.clarifyCommand,
          status: AssistantStatus.needsClarification,
        );
      case AlarmIssue.noDuration:
        return session.reply(
          'alarm.clarify.duration',
          intent: AlarmPhrases.clarifyCommand,
          status: AssistantStatus.needsClarification,
        );
      case AlarmIssue.past:
        return session.reply(
          'alarm.past',
          values: <String, String>{'time': request.timeText},
          intent: AlarmPhrases.clarifyCommand,
          status: AssistantStatus.noAction,
        );
      case AlarmIssue.date:
        return _offerReminder(
          'alarm.date',
          request,
          session,
          intent: AlarmPhrases.dateCommand,
        );
      case AlarmIssue.none:
        break;
    }
    final setter = this.setter;
    if (setter == null || !setter.supported) {
      return _offerReminder(
        'alarm.unavailable.platform',
        request,
        session,
        intent: request.commandId,
      );
    }
    if (!await setter.canSet()) {
      return _offerReminder(
        'alarm.unavailable.noClock',
        request,
        session,
        intent: request.commandId,
      );
    }
    final clarification = Clarification(
      questionId: request.isTimer ? 'alarm.timer.confirm' : 'alarm.confirm',
      options: const <ClarifyOption>[
        ClarifyOption(
          label: 'Поставить',
          text: 'Поставить',
          answers: <String>{
            'поставь',
            'поставьте',
            'ставь',
            'ставьте',
            'запусти',
            'запустить',
            'запускай',
          },
          connectorId: id,
          answer: true,
        ),
        ClarifyOption(
          label: 'Отмена',
          text: 'Отмена',
          answers: <String>{'отмени', 'отменить'},
          connectorId: id,
          answer: false,
        ),
      ],
      context: request,
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: confirmCommand,
        payload: clarification,
      ),
    );
    return session.reply(
      clarification.questionId,
      values: _values(request),
      intent: request.commandId,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  /// «7:00», « по будням», « с подписью «спортзал»» — для текста ответа.
  static Map<String, String> _values(AlarmRequest request) {
    final label = request.label;
    final days = request.daysText;
    return request.isTimer
        ? <String, String>{
            'duration': request.durationText,
            'details': label == null ? '' : ' «$label»',
          }
        : <String, String>{
            'time': request.timeText,
            'details': '${days.isEmpty ? '' : ' $days'}'
                '${label == null ? '' : ' с подписью «$label»'}',
          };
  }

  /// Ответ на «Поставить …?».
  Future<AssistantResponse> _answer(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) async {
    final clarification = answer.pending.payload;
    final request =
        clarification is Clarification ? clarification.context : null;
    if (request is! AlarmRequest || !answer.confirmed) {
      return session.reply(
        'alarm.cancelled',
        intent: 'alarm.cancelled',
        status: AssistantStatus.noAction,
      );
    }
    final setter = this.setter;
    final done = setter != null && await setter.set(request);
    if (!done) {
      return _offerReminder(
        'alarm.unavailable.noClock',
        request,
        session,
        intent: request.commandId,
      );
    }
    return session.reply(
      request.isTimer ? 'alarm.timer.set' : 'alarm.set',
      values: _values(request),
      intent: request.commandId,
      status: AssistantStatus.completed,
    );
  }

  /// Будильник поставить нельзя — предложить напоминание: задачу со
  /// сроком. Вариант «Напомнить» разбирается заново как каноническая
  /// команда задач («напомни «Будильник» 06.11 в 7:00»).
  AssistantResponse _offerReminder(
    String replyId,
    AlarmRequest request,
    AssistantSession session, {
    required String intent,
  }) {
    final now = session.clock.now();
    final command = reminderCommand(request, now);
    final when = request.isTimer
        ? 'через ${request.durationText}'
        : request.at == null
            ? 'в ${request.timeText}'
            : formatDue(request.at!, DuePrecision.dateTime, now);
    final clarification = Clarification(
      questionId: replyId,
      options: <ClarifyOption>[
        ClarifyOption(
          label: 'Напомнить',
          text: command,
          answers: const <String>{'напомни', 'напомнить', 'давай'},
          connectorId: 'tasks',
        ),
        const ClarifyOption(
          label: 'Не надо',
          text: 'Не надо',
          connectorId: id,
          answer: false,
        ),
      ],
      context: request,
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: confirmCommand,
        payload: clarification,
      ),
    );
    return session.reply(
      replyId,
      values: <String, String>{'when': when},
      intent: intent,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  /// Каноническая команда задач для напоминания вместо будильника:
  /// «напомни «Будильник» 06.11 в 7:00», «напомни «Таймер» через 5 минут».
  /// Только шаблон с числами и подписью из кавычек.
  static String reminderCommand(AlarmRequest request, DateTime now) {
    final raw = (request.label ?? (request.isTimer ? 'Таймер' : 'Будильник'))
        .replaceAll('«', '"')
        .replaceAll('»', '"');
    // Название задачи — с заглавной, как у остальных задач.
    final title = raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);
    if (request.isTimer) {
      final seconds = request.seconds ?? 60;
      final minutes = (seconds / 60).ceil();
      return 'напомни «$title» через $minutes '
          '${minutes % 10 == 1 && minutes % 100 != 11 ? 'минуту' : 'минут'}';
    }
    final at = request.at ?? now;
    final day = '${at.day.toString().padLeft(2, '0')}.'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.year == now.year ? '' : '.${at.year}'}';
    return 'напомни «$title» $day в ${request.timeText}';
  }
}
