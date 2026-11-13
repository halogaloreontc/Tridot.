import '../../connectors/connector.dart';
import 'data_phrases.dart';

export 'data_phrases.dart';

/// Навык «Данные»: просьбы о данных приложения без опоры на пароли —
/// копия, восстановление, «хранилище» (решения владельца 3 и 5).
///
/// В приложении два набора данных с копиями: сейф с паролями (навык
/// «Пароли») и все остальные данные (задачи и сессии, Настройки →
/// «Данные и резервная копия»). На двусмысленную фразу («сделай бэкап»,
/// «открой хранилище») навык не отвечает «не понял», а переспрашивает с
/// вариантами ([Clarification]): «Копию чего: паролей или всех данных?».
/// Если в этом чате только что говорили о паролях (контекст сессии,
/// [Utterance.recentConnectorId]), не переспрашивает, а отдаёт фразу
/// сейфу ([Reroute]) с пометкой «Понял как копию паролей.». Навык «Пароли»
/// выключен — вопроса нет, ответ сразу про все данные.
///
/// Без сети, не работает с секретами, включён всегда. Двусмысленные
/// совпадения — без маркера ([ConnectorMatch.implicit]) и ниже порога
/// спора: уступают любой явной фразе других навыков («нужно сделать бэкап»
/// — задача).
final class DataConnector implements Connector, ConnectorHealth {
  const DataConnector();

  static const String id = 'data';

  /// Двусмысленная просьба: переспросить.
  static const String clarifyCommand = 'data.clarify';

  /// Просьба понята по контексту сессии: выполнить её как фразу о сейфе.
  static const String contextCommand = 'data.context';

  /// Уверенность явной просьбы («всех данных»).
  static const double explicitConfidence = 0.8;

  /// Уверенность двусмысленной: ниже порога спора коннекторов, чтобы не
  /// вызывать «к чему относится команда?».
  static const double vagueConfidence = 0.45;

  /// Уверенность команды с голым «хранилище» ([DataRequest.command]):
  /// явная и выше любой команды задач — «закрой хранилище» не завершение
  /// задачи «Хранилище» (раньше «хранилище» было якорем сейфа, и фразу
  /// забирал навык «Пароли»).
  static const double commandConfidence = 0.97;

  /// Id навыка «Пароли».
  static const String passwordsId = 'passwords';

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Данные',
        description: 'Подсказывает про резервную копию и данные приложения; '
            'если неясно, о чём речь — о сейфе с паролями или обо всех '
            'данных, — переспрашивает.',
        examples: <String>[
          'Сделай резервную копию всех данных',
          'Восстанови все данные из копии',
          'Открой данные приложения',
        ],
        kind: ExtensionKind.skill,
        required: true,
      );

  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  @override
  ConnectorMatch? match(Utterance utterance) {
    final request = DataPhrases.parse(utterance);
    if (request == null) return null;
    if (request.everything) {
      return ConnectorMatch(
        connectorId: id,
        commandId: request.dataCommand,
        confidence: explicitConfidence,
        payload: request,
      );
    }
    final confidence = request.command ? commandConfidence : vagueConfidence;
    switch (utterance.recentConnectorId) {
      case passwordsId:
        // Только что говорили о паролях: это просьба о сейфе.
        return ConnectorMatch(
          connectorId: id,
          commandId: contextCommand,
          confidence: confidence,
          implicit: !request.command,
          payload: Reroute(
            text: request.passwordsText,
            connectorId: passwordsId,
            noteReplyId: request.action == DataAction.backup
                ? 'data.context.backup'
                : 'data.context.passwords',
            orElse: request,
          ),
        );
      case id:
        // Только что говорили о данных: не переспрашиваем.
        return ConnectorMatch(
          connectorId: id,
          commandId: request.dataCommand,
          confidence: confidence,
          implicit: !request.command,
          payload: request,
        );
    }
    return ConnectorMatch(
      connectorId: id,
      commandId: clarifyCommand,
      confidence: confidence,
      implicit: !request.command,
      payload: request,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) {
      // Ответ на вопрос разбирает маршрутизатор; сюда «да» или «нет»
      // попадает, только если вопрос уже снят.
      return session.reply(
        'common.clarify.cancelled',
        intent: 'clarify.cancelled',
        status: AssistantStatus.noAction,
      );
    }
    final request = switch (payload) {
      final DataRequest request => request,
      Reroute(orElse: final DataRequest request) => request,
      _ => null,
    };
    if (request == null) {
      throw StateError('Нет разбора для ${match.commandId}');
    }
    final askable =
        match.commandId == clarifyCommand || match.commandId == contextCommand;
    if (askable && _passwordsOn(session)) return _ask(request, session);
    return _answer(request, session);
  }

  /// Навык «Пароли» включён: есть что выбирать.
  static bool _passwordsOn(AssistantSession session) =>
      session.extensions?.isEnabled(passwordsId) ?? false;

  AssistantResponse _ask(DataRequest request, AssistantSession session) {
    final question = switch (request.action) {
      DataAction.backup => 'data.clarify.backup',
      DataAction.restore => 'data.clarify.restore',
      _ => 'data.clarify.storage',
    };
    final copy = request.action == DataAction.backup ||
        request.action == DataAction.restore;
    final clarification = Clarification(
      questionId: question,
      options: <ClarifyOption>[
        ClarifyOption(
          label: copy ? 'Пароли' : 'Сейф',
          text: request.passwordsText,
          answers: _passwordsAnswers,
          connectorId: passwordsId,
        ),
        ClarifyOption(
          label: copy ? 'Все данные' : 'Данные',
          text: request.dataText,
          answers: _dataAnswers,
          connectorId: id,
        ),
      ],
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: clarifyCommand,
        payload: clarification,
      ),
    );
    return session.reply(
      question,
      intent: clarifyCommand,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  static const Set<String> _passwordsAnswers = <String>{
    'пароли',
    'паролей',
    'пароль',
    'паролям',
    'паролями',
    'сейф',
    'сейфа',
    'сейфе',
    'сейфу',
  };

  static const Set<String> _dataAnswers = <String>{
    'данные',
    'данных',
    'все',
    'всех',
    'всего',
    'приложение',
    'приложения',
    'задачи',
    'задач',
    'чаты',
    'сессии',
  };

  AssistantResponse _answer(DataRequest request, AssistantSession session) =>
      session.reply(
        request.dataCommand,
        intent: request.dataCommand,
        status: AssistantStatus.completed,
      );
}
