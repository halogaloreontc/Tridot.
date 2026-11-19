import 'dart:async';

import '../../app_info.dart';
import '../../connectors/connector.dart';
import '../../connectors/question_phrases.dart';
import '../../extensions/extension_registry.dart';
import '../../formatting/due_format.dart';
import '../../models/task.dart';
import '../../personas/persona.dart';
import '../../replies/reply_library.dart';
import '../../services/task_service.dart';
import 'talk_phrases.dart';

export 'talk_phrases.dart';

/// Навык «Беседа»: приветствия, прощания, «спасибо», «как дела», «кто
/// ты», «что умеешь», шутки из паков и просьбы о стиле общения.
///
/// Беседа заготовленная, а не свободная (ADR-001): понимает только
/// короткие реплики целиком ([TalkPhrases]) и отвечает записями каталога
/// ответов голосом главного, Лиорио или Ноды. Совпадения беседы — на
/// крайний случай ([ConnectorMatch.fallback]): любая команда задач,
/// калькулятора или подключения важнее.
final class TalkConnector implements Connector, ConnectorHealth {
  TalkConnector({TaskService? taskService}) : _tasks = taskService;

  static const String id = 'talk';

  static const String greetCommand = 'talk.greet';
  static const String byeCommand = 'talk.bye';
  static const String thanksCommand = 'talk.thanks';
  static const String howAreYouCommand = 'talk.howAreYou';
  static const String whoAreYouCommand = 'talk.whoAreYou';
  static const String capabilitiesCommand = 'talk.capabilities';
  static const String jokeCommand = 'talk.joke';
  static const String reactionCommand = 'talk.reaction';
  static const String rudeCommand = 'talk.rude';
  static const String settingCommand = 'talk.setting';

  /// «Открой мой Связной»: оболочка открывает раздел по этому intent.
  static const String openHubCommand = 'talk.openHub';

  /// Справочный вопрос («напомни, какая формула суммы в гугл-таблицах?»):
  /// без сети помощник на него не ответит и честно об этом говорит, а не
  /// заводит задачу из вопроса.
  static const String questionCommand = 'talk.question';

  /// Уверенность справочного вопроса: ниже реплик беседы — «как дела?»
  /// и «который час» понимаются точнее.
  static const double questionConfidence = 0.5;

  /// Ответ «да» на «Передать жалобу администратору?».
  static const String complaintCommand = 'talk.complaint';

  /// Все команды беседы: они же `intents` корпуса `test/corpus/talk.jsonl`.
  static const List<String> commands = <String>[
    greetCommand,
    byeCommand,
    thanksCommand,
    howAreYouCommand,
    whoAreYouCommand,
    capabilitiesCommand,
    jokeCommand,
    reactionCommand,
    rudeCommand,
    settingCommand,
    openHubCommand,
    questionCommand,
  ];

  /// Уверенность беседы. Ниже явных команд других навыков, а флаг
  /// `fallback` всё равно отдаёт фразу любому другому совпадению.
  static const double confidence = 0.6;

  /// Сколько последних шуток не повторять.
  static const int recentJokes = 10;

  /// Типы паков, из которых беседа берёт шутки.
  static const Set<String> jokeTypes = <String>{'jokes', 'puns'};

  /// Метка каламбура в паке шуток.
  static const String punTag = 'каламбур';

  static final Map<String, String> _commandOf = <String, String>{
    TalkTopic.greet.name: greetCommand,
    TalkTopic.bye.name: byeCommand,
    TalkTopic.thanks.name: thanksCommand,
    TalkTopic.howAreYou.name: howAreYouCommand,
    TalkTopic.whoAreYou.name: whoAreYouCommand,
    TalkTopic.capabilities.name: capabilitiesCommand,
    TalkTopic.joke.name: jokeCommand,
    TalkTopic.reaction.name: reactionCommand,
    TalkTopic.rude.name: rudeCommand,
    TalkTopic.setting.name: settingCommand,
    TalkTopic.openHub.name: openHubCommand,
  };

  final TaskService? _tasks;

  /// Тексты последних шуток разговора: они не повторяются.
  final List<String> _recent = <String>[];

  /// Сколько шуток уже рассказано: от него — какая следующая.
  int _jokesTold = 0;

  /// Сколько было приветствий и благодарностей: от него — добавить ли
  /// каламбур ([JokeFrequency]).
  int _smallTalk = 0;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Беседа',
        description: 'Здоровается, отвечает на «как дела» и «кто ты», '
            'рассказывает шутки из паков и меняет стиль общения по просьбе.',
        examples: <String>[
          'расскажи шутку',
          'привет',
          'как дела?',
          'что ты умеешь',
          'говори короче',
        ],
        kind: ExtensionKind.skill,
      );

  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  @override
  ConnectorMatch? match(Utterance utterance) {
    final request = TalkPhrases.recognize(utterance.original);
    if (request == null) {
      // «Который час?», «какой сегодня день недели» — ответ есть на самом
      // устройстве, без справочника.
      final clock = ClockQuestion.of(utterance);
      if (clock != null) {
        return ConnectorMatch(
          connectorId: id,
          commandId: questionCommand,
          confidence: confidence,
          payload: clock,
          fallback: true,
        );
      }
      final question = QuestionPhrases.detect(utterance);
      if (question == null || QuestionPhrases.aboutApp(utterance)) {
        return null;
      }
      return ConnectorMatch(
        connectorId: id,
        commandId: questionCommand,
        confidence: questionConfidence,
        payload: question,
        fallback: true,
      );
    }
    return ConnectorMatch(
      connectorId: id,
      commandId: _commandOf[request.topic.name]!,
      confidence: confidence,
      payload: request,
      fallback: true,
      // «Хорошо», «понял», «спасибо» в ответ на вопрос — не согласие:
      // маршрутизатор переспросит «да» или «нет», а не снимет вопрос.
      acknowledgement: request.topic == TalkTopic.reaction ||
          request.topic == TalkTopic.thanks,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) return _complaint(payload, session);
    if (payload is ClockQuestion) {
      final now = session.clock.now();
      return _say(
        session,
        payload == ClockQuestion.time ? 'talk.clock.time' : 'talk.clock.date',
        command: questionCommand,
        values: <String, String>{
          'time': formatTime(now),
          'date': '${ClockQuestion.weekdays[now.weekday - 1]}, '
              '${now.day} ${ClockQuestion.months[now.month - 1]}',
        },
      );
    }
    if (payload is QuestionMatch) {
      return _say(
        session,
        switch (payload.kind) {
          QuestionKind.recall => 'talk.question.recall',
          QuestionKind.units => 'talk.question.units',
          QuestionKind.info => 'talk.question.offline',
        },
        command: questionCommand,
        status: AssistantStatus.noAction,
      );
    }
    final request = payload! as TalkRequest;
    final command = match.commandId;
    // «Спасибо, Нода», «как дела, Нода?»: отвечает названный активный
    // помощник, его голосом, и он же становится адресатом чата
    // ([AssistantResponse.addressedPersonaId]). Имя помощника, выключенного
    // режимом, — просто текст. Просьбы «пусть отвечает Лиорио» и «включи
    // дуэт с Нодой» решают, кто ответит, сами (_setting): имя в них — не
    // обращение.
    final cast = session.personas.cast;
    final named = cast.find(request.persona);
    if (named == null ||
        !cast.isActive(named.id) ||
        request.setting == TalkSettingKind.main ||
        (request.setting?.isMode ?? false)) {
      return _run(request, command, session);
    }
    if (named.id == session.speaker.id) {
      return (await _run(request, command, session)).withAddressed(named.id);
    }
    session
      ..speaker = named
      ..voice = session.personas.voiceOf(named);
    final response = await _run(request, command, session);
    return response.withPersona(named.id).withAddressed(named.id);
  }

  Future<AssistantResponse> _run(
    TalkRequest request,
    String command,
    AssistantSession session,
  ) async {
    switch (request.topic) {
      case TalkTopic.greet:
        return _withPun(_greet(request, session, command), session);
      case TalkTopic.thanks:
        return _withPun(
          _say(session, 'talk.thanks', command: command),
          session,
        );
      case TalkTopic.bye:
        return _say(
          session,
          request.night ? 'talk.bye.night' : 'talk.bye',
          command: command,
        );
      case TalkTopic.howAreYou:
        return _status(session, command);
      case TalkTopic.whoAreYou:
        return _who(session, command);
      case TalkTopic.capabilities:
        return _capabilities(session, command);
      case TalkTopic.joke:
        return _joke(request, session, command);
      case TalkTopic.reaction:
        return _say(session, 'talk.reaction', command: command);
      case TalkTopic.rude:
        return _say(session, 'talk.rude', command: command);
      case TalkTopic.setting:
        return _setting(request, session, command);
      case TalkTopic.openHub:
        return _say(session, 'talk.openHub', command: command);
    }
  }

  AssistantResponse _say(
    AssistantSession session,
    String reply, {
    required String command,
    Map<String, String> values = const <String, String>{},
    AssistantStatus status = AssistantStatus.completed,
  }) =>
      session.reply(reply, values: values, intent: command, status: status);

  // ------------------------------------------------------------ приветствие

  AssistantResponse _greet(
    TalkRequest request,
    AssistantSession session,
    String command,
  ) {
    final now = session.clock.now();
    final part = DayPart.of(now);
    final said = request.saidPart;
    // «Доброе утро» в 22:00: шутливая поправка — только в дружеском
    // стиле; остальные просто здороваются по времени суток.
    if (said != null &&
        said.isFarFrom(part) &&
        session.voice.style == ReplyStyles.friendly) {
      return _say(
        session,
        'talk.greet.mismatch',
        command: command,
        values: <String, String>{
          'said': said.greeting,
          'daypart': part.greeting,
          'time': formatTime(now),
        },
      );
    }
    return _say(
      session,
      'talk.greet',
      command: command,
      values: <String, String>{'daypart': part.greeting},
    );
  }

  /// К приветствию и благодарности изредка — лёгкий каламбур из паков:
  /// «изредка» — каждый четвёртый раз, «чаще» — каждый второй, «нет» —
  /// никогда. Счёт детерминированный, поэтому проверяется тестами.
  AssistantResponse _withPun(
    AssistantResponse response,
    AssistantSession session,
  ) {
    final count = _smallTalk++;
    final due = switch (session.personas.jokes) {
      JokeFrequency.off => false,
      JokeFrequency.rare => count % 4 == 3,
      JokeFrequency.normal => count.isOdd,
    };
    if (!due) return response;
    final pool = _pool(session, puns: true, strictPuns: true);
    if (pool.isEmpty) return response;
    final pun = _pick(pool);
    final text = session.say('talk.pun', <String, String>{'pun': pun});
    return AssistantResponse(
      message: sentences(<String>[response.message, text]),
      intent: response.intent,
      status: response.status,
      replyId: response.replyId,
      values: response.values,
    );
  }

  // ------------------------------------------------------------- как дела

  Future<AssistantResponse> _status(
    AssistantSession session,
    String command,
  ) async {
    final parts = <String>[];
    final tasks = _tasks;
    if (tasks != null) {
      try {
        final active = await tasks.listActive();
        final now = session.clock.now();
        final overdue = active.where((Task t) => isOverdue(t, now)).length;
        parts.add(
          active.isEmpty
              ? session.say('talk.status.tasks.none')
              : overdue == 0
                  ? session.say('talk.status.tasks', <String, String>{
                      'active': '${active.length}',
                    })
                  : session.say('talk.status.tasks.overdue', <String, String>{
                      'active': '${active.length}',
                      'overdue': '$overdue',
                    }),
        );
      } on Object {
        // Задачи не прочитались: об этом скажет их проверка здоровья.
      }
    }
    final (problems, unchecked, pending) = await _problems(session);
    if (problems.isEmpty) {
      // Без проверки здоровья коннектор не проверен: «все работают» про
      // него не говорим, а называем его. Подключение, в которое ещё не
      // вошли, — не сбой: «все подключения работают» про него тоже не
      // говорим, а коротко подсказываем, где подключить.
      final okId = unchecked.isNotEmpty
          ? 'talk.status.okUnchecked'
          : pending.isEmpty
              ? 'talk.status.ok'
              : 'talk.status.okPending';
      final okValues = unchecked.isEmpty
          ? const <String, String>{}
          : <String, String>{'unchecked': unchecked.join(', ')};
      final ok = session.say(okId, okValues);
      return AssistantResponse(
        message: sentences(<String>[ok, ...parts, ...pending]),
        intent: command,
        status: AssistantStatus.completed,
        replyId: okId,
        values: okValues,
      );
    }
    final list = problems.join('; ');
    final values = <String, String>{'problems': list};
    final question = session.say('talk.status.problem', values);
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: complaintCommand,
        payload: list,
      ),
    );
    return AssistantResponse(
      message: sentences(<String>[...parts, question]),
      intent: command,
      status: AssistantStatus.needsClarification,
      replyId: 'talk.status.problem',
      values: values,
    );
  }

  /// Что не так у включённых коннекторов: ««Склад» не работает: нет
  /// связи с сервером (с 14:05)». Проверка, которая не ответила вовремя
  /// или упала, — тоже проблема. Второе — названия включённых
  /// коннекторов без [ConnectorHealth]: их проверить нельзя. Третье —
  /// подсказки для подключений роли, в которые ещё не вошли
  /// ([HealthStatus.notConnected]): «Склад ещё не подключён — Настройки →
  /// Роли → Кладовщик → Подключить склад.» Это не проблема и не повод для
  /// жалобы.
  Future<(List<String>, List<String>, List<String>)> _problems(
    AssistantSession session,
  ) async {
    // Недоступное в сборке ([ConnectorInfo.unavailable]) не проверяется
    // и не рекламируется.
    final connectors = <Connector>[
      for (final connector
          in session.extensions?.enabledConnectors ?? const <Connector>[])
        if (!connector.info.unavailable) connector,
    ];
    final now = session.clock.now();
    final checked = <Connector>[
      for (final connector in connectors)
        if (connector is ConnectorHealth) connector,
    ];
    final checks = <Future<HealthReport>>[
      for (final connector in checked) _check(connector as ConnectorHealth),
    ];
    final unchecked = <String>[
      for (final connector in connectors)
        if (connector is! ConnectorHealth) '«${connector.info.title}»',
    ];
    final results = await Future.wait(checks);
    final problems = <String>[];
    final pending = <String>[];
    for (var i = 0; i < results.length; i++) {
      final report = results[i];
      if (report.isOk) continue;
      final info = checked[i].info;
      if (!report.isNotConnected) {
        problems.add(describe(info.title, report, now));
        continue;
      }
      final role = session.extensions?.activeRoleOf(info.id);
      final link = role?.connection;
      if (role != null && link != null && link.extensionId == info.id) {
        pending.add(
          session.say('role.notConnected', <String, String>{
            'app': link.appTitle,
            'role': role.title,
            'button': link.connectLabel,
          }),
        );
      }
    }
    return (problems, unchecked, pending);
  }

  /// Фразы одной репликой через пробел. Фраза без знака конца
  /// предложения (например, кончалась эмодзи, а эмодзи выключены)
  /// получает точку, чтобы соседние фразы не слиплись.
  static String sentences(List<String> parts) => <String>[
        for (final part in parts)
          if (part.trim().isNotEmpty)
            ReplySchema.endsSentence(part) || _endsWithEmoji(part)
                ? part.trim()
                : '${part.trim()}.',
      ].join(' ');

  static bool _endsWithEmoji(String text) {
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) return false;
    final last = String.fromCharCodes(<int>[trimmed.runes.last]);
    return ReplyTemplate.pictographs.hasMatch(last);
  }

  static Future<HealthReport> _check(ConnectorHealth health) async {
    try {
      return await health.health().timeout(ConnectorHealth.timeout);
    } on TimeoutException {
      return const HealthReport(
        HealthStatus.degraded,
        detail: 'не ответил на проверку вовремя',
      );
    } on Object catch (error) {
      return HealthReport(
        HealthStatus.down,
        detail: 'проверка не удалась: $error',
      );
    }
  }

  /// Проблема одной строкой: «Склад» работает с перебоями: медленно
  /// отвечает (с 14:05).
  static String describe(String title, HealthReport report, DateTime now) {
    final state = report.status == HealthStatus.down
        ? 'не работает'
        : 'работает с перебоями';
    final detail = report.detail.trim();
    final since = report.since;
    final when = since == null
        ? ''
        : since.year == now.year &&
                since.month == now.month &&
                since.day == now.day
            ? ' (с ${formatTime(since)})'
            : ' (с ${since.day.toString().padLeft(2, '0')}.'
                '${since.month.toString().padLeft(2, '0')} '
                '${formatTime(since)})';
    return '«$title» $state${detail.isEmpty ? '' : ': $detail'}$when';
  }

  AssistantResponse _complaint(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) {
    // Жалоба — сигнал: о ней говорит ведущий оповещений (ADR-016).
    final notifier = session.personas.cast.notifier;
    if (notifier.id != session.speaker.id) {
      session
        ..speaker = notifier
        ..voice = session.personas.voiceOf(notifier);
    }
    return _complaintReply(answer, session).withPersona(notifier.id);
  }

  AssistantResponse _complaintReply(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) {
    if (!answer.confirmed) {
      return _say(
        session,
        'talk.complaint.declined',
        command: complaintCommand,
        status: AssistantStatus.noAction,
      );
    }
    // Передавать пока некуда: жалобу принимает сервер коннектора
    // (docs/CONNECTORS.md, «Жалобы»). Без сети и без обещаний.
    return _say(
      session,
      'talk.complaint.later',
      command: complaintCommand,
      values: <String, String>{
        'problems': answer.pending.payload as String? ?? '',
      },
      status: AssistantStatus.noAction,
    );
  }

  // ------------------------------------------------------- кто ты, умеешь

  /// Обязанности помощника [persona] для «кто ты» (`{duties}`): что он
  /// ведёт сейчас, с учётом режима. Фразы фиксированные, в именительном
  /// падеже, без рода — годятся и о себе, и о другом. Выключенные навыки
  /// ([registry]) не называются: склад, выключенный в «Расширениях», не
  /// упоминается ни в расширениях, ни в сигналах.
  static String dutiesOf(
    Persona persona,
    PersonaCast cast, [
    ExtensionRegistry? registry,
  ]) {
    bool on(String id) => registry == null || registry.isEnabled(id);
    final extensions = <String>[
      if (on('warehouse')) 'склад',
      if (on('passwords')) 'пароли',
    ];
    final parts = <String>[
      if (cast.extensionsLead.id == persona.id)
        extensions.isEmpty
            ? 'расширения (пока ни одно не включено)'
            : 'расширения (${extensions.join(', ')})',
      if (cast.notifier.id == persona.id)
        'оповещения (напоминания'
            '${on('alarm') ? ', будильник' : ''}, просрочки'
            '${on('warehouse') ? ', сигналы склада' : ''})',
    ];
    return parts.isEmpty
        ? 'закреплённых обязанностей нет, только обращение по имени'
        : parts.join(' и ');
  }

  /// «Кто ты» (ADR-016). Соло — Связной о себе (`talk.who.solo`). В Дуэте и
  /// Трио Связной говорит о себе (`talk.who.main`) и о каждом активном
  /// помощнике (`talk.who.helper` — в роде помощника), помощник — о себе
  /// (`talk.who.self.helper`) и о главном (`talk.who.mainRef` — в роде
  /// главного). Имена — текущие русские из настроек, только в именительном
  /// падеже; название приложения звучит один раз.
  AssistantResponse _who(AssistantSession session, String command) {
    final speaker = session.speaker;
    final cast = session.personas.cast;
    final app = AppInfo.namePrepositional;
    if (cast.mode == TeamMode.solo) {
      return _withRoles(
        session,
        _say(
          session,
          'talk.who.solo',
          command: command,
          values: <String, String>{
            'name': speaker.russianName,
            'appPrepositional': app,
          },
        ),
      );
    }
    final main = cast.responder;
    final String replyId;
    final List<String> parts;
    if (speaker.id == main.id) {
      replyId = 'talk.who.main';
      parts = <String>[
        session.say(replyId, <String, String>{
          'name': speaker.russianName,
          'appPrepositional': app,
        }),
        for (final helper in cast.active)
          if (helper.id != main.id)
            session.sayAs('talk.who.helper', helper.gender, <String, String>{
              'name': helper.russianName,
              'duties': dutiesOf(helper, cast, session.extensions),
            }),
        session.say('talk.who.byName'),
      ];
    } else {
      replyId = 'talk.who.self.helper';
      parts = <String>[
        session.say(replyId, <String, String>{
          'name': speaker.russianName,
          'duties': dutiesOf(speaker, cast, session.extensions),
          'appPrepositional': app,
        }),
        session.sayAs('talk.who.mainRef', main.gender, <String, String>{
          'main': main.russianName,
        }),
      ];
    }
    return _withRoles(
      session,
      AssistantResponse(
        message: sentences(parts),
        intent: command,
        status: AssistantStatus.completed,
        replyId: replyId,
        values: <String, String>{
          'name': speaker.russianName,
          'appPrepositional': app,
        },
      ),
    );
  }

  /// С чем помощник помогает сейчас («с задачами и со складом») — для
  /// «кто ты» и «что умеешь» (ADR-012); `null` — говорить не о чем:
  /// включено только «Личное» (о задачах и счёте помощник и так
  /// рассказывает). Роль, чей навык выключен в «Расширениях», не
  /// упоминается ([ExtensionRegistry.helpsWith]).
  static String? _roles(AssistantSession session) {
    final registry = session.extensions;
    if (registry == null) return null;
    final active = registry.activeRoles;
    if (active.isEmpty ||
        (active.length == 1 && active.single.id == Roles.personalId)) {
      return null;
    }
    final helps = registry.helpsWith;
    if (helps.isEmpty || helps == Roles.personal.helpsWith) return null;
    return helps;
  }

  /// «Сейчас помогаю с задачами и со складом.» после «кто ты»
  /// (`talk.roles`).
  AssistantResponse _withRoles(
    AssistantSession session,
    AssistantResponse response,
  ) {
    final helps = _roles(session);
    if (helps == null) return response;
    final tail = session.say('talk.roles', <String, String>{'roles': helps});
    return AssistantResponse(
      message: '${response.message} $tail',
      intent: response.intent,
      status: response.status,
      replyId: response.replyId,
      values: <String, String>{...response.values, 'roles': helps},
    );
  }

  /// Только включённые навыки и подключения, по одному примеру: выключенное
  /// не рекламируется.
  AssistantResponse _capabilities(AssistantSession session, String command) {
    // Недоступное в сборке ([ConnectorInfo.unavailable]) не проверяется
    // и не рекламируется.
    final connectors = <Connector>[
      for (final connector
          in session.extensions?.enabledConnectors ?? const <Connector>[])
        if (!connector.info.unavailable) connector,
    ];
    String title(Connector c) => c.info.title;
    final items = <String>[
      for (final connector in connectors)
        connector.info.examples.isEmpty
            ? '«${title(connector)}»'
            : '«${title(connector)}» — например, '
                '«${connector.info.examples.first}»',
    ];
    if (items.isEmpty) items.add('«$_selfTitle»');
    // С ролью сверх «Личного» — одна запись с обоими фактами, а не две
    // склеенные: так фраза читается целиком в каждом стиле.
    final helps = _roles(session);
    return _say(
      session,
      helps == null ? 'talk.capabilities' : 'talk.capabilities.roles',
      command: command,
      values: <String, String>{
        'skills': items.join('; '),
        if (helps != null) 'roles': helps,
      },
    );
  }

  static const String _selfTitle = 'Беседа';

  // ----------------------------------------------------------------- шутки

  Future<AssistantResponse> _joke(
    TalkRequest request,
    AssistantSession session,
    String command,
  ) async {
    final pool = _pool(session, puns: request.pun);
    if (pool.isEmpty) {
      return _say(
        session,
        'talk.joke.none',
        command: command,
        status: AssistantStatus.noAction,
      );
    }
    return _say(
      session,
      'talk.joke',
      command: command,
      values: <String, String>{'joke': _pick(pool)},
    );
  }

  /// Шутки включённых паков для того, кто говорит: `any` или он сам, и
  /// подходящие его стилю, если у записи указаны стили. [puns] — сначала
  /// каламбуры (пак `puns` или метка «каламбур»); [strictPuns] — только
  /// они. Порядок стабильный: паки и записи как в хранилище.
  List<String> _pool(
    AssistantSession session, {
    bool puns = false,
    bool strictPuns = false,
  }) {
    final registry = session.extensions;
    if (registry == null) return const <String>[];
    final persona = PackPersona.values
            .where((PackPersona p) => p.name == session.speaker.id)
            .firstOrNull ??
        PackPersona.any;
    final entries = <PackEntry>[
      for (final type in jokeTypes)
        ...registry.packEntries(type: type, persona: persona),
    ];
    final punTypeIds = <String>{
      for (final entry in registry.packEntries(type: 'puns', persona: persona))
        entry.text,
    };
    bool isPun(PackEntry e) =>
        punTypeIds.contains(e.text) || e.tags.contains(punTag);
    var pool = entries;
    if (puns) {
      final only = pool.where(isPun).toList();
      if (only.isNotEmpty || strictPuns) pool = only;
    }
    final style = PackStyle.values
        .where((PackStyle s) => s.name == session.voice.style)
        .firstOrNull;
    if (style != null) {
      final suited = pool
          .where(
            (PackEntry e) => e.styles.isEmpty || e.styles.contains(style),
          )
          .toList();
      if (suited.isNotEmpty) pool = suited;
    }
    return <String>{for (final entry in pool) entry.text}.toList();
  }

  /// Следующая шутка: не из последних [recentJokes] этого разговора, если
  /// есть из чего выбрать; иначе — та, что звучала давнее всех.
  String _pick(List<String> pool) {
    final fresh = pool.where((String t) => !_recent.contains(t)).toList();
    final String text;
    if (fresh.isNotEmpty) {
      text = fresh[
          (ReplyLibrary.stableHash('talk.joke') + _jokesTold) % fresh.length];
    } else {
      text = _recent.firstWhere(pool.contains);
    }
    _jokesTold++;
    _recent
      ..remove(text)
      ..add(text);
    while (_recent.length > recentJokes) {
      _recent.removeAt(0);
    }
    return text;
  }

  // ---------------------------------------------------------- стиль общения

  AssistantResponse _setting(
    TalkRequest request,
    AssistantSession session,
    String command,
  ) {
    final settings = session.personas;
    final kind = request.setting!;
    // Главный всегда Связной (ADR-016): «пусть отвечает Лио», «сделай Ноду
    // основной» настроек не меняют — ответ объясняет, где включить
    // помощников.
    if (kind == TalkSettingKind.main) return _mainFixed(session, command);
    if (kind.isMode) return _mode(request, session, command);
    final speaker = session.speaker;
    final (PersonaSettingsChange change, String reply) = switch (kind) {
      TalkSettingKind.style => (
          PersonaSettingsChange(
            stylePersona: speaker.id,
            style: request.style,
          ),
          'talk.set.${request.style}',
        ),
      TalkSettingKind.informal => (
          const PersonaSettingsChange(address: ReplyAddress.informal),
          'talk.set.informal',
        ),
      TalkSettingKind.formal => (
          const PersonaSettingsChange(address: ReplyAddress.formal),
          'talk.set.formal',
        ),
      TalkSettingKind.emojiOff => (
          const PersonaSettingsChange(emoji: false),
          'talk.set.emojiOff',
        ),
      TalkSettingKind.emojiOn => (
          const PersonaSettingsChange(emoji: true),
          'talk.set.emojiOn',
        ),
      TalkSettingKind.jokesLess => _jokes(settings.jokes.less),
      TalkSettingKind.jokesMore => _jokes(settings.jokes.more),
      TalkSettingKind.jokesOff => _jokes(JokeFrequency.off),
      TalkSettingKind.main ||
      TalkSettingKind.modeSolo ||
      TalkSettingKind.modeDuo ||
      TalkSettingKind.modeTrio =>
        throw StateError('обработано выше'),
    };
    if (change.isNoOpFor(settings)) {
      return _say(
        session,
        'talk.set.already',
        command: command,
        status: AssistantStatus.noAction,
      );
    }
    final updated = change.apply(settings);
    // Подтверждение звучит уже новым голосом: «без смайликов» — без
    // смайликов, «давай на ты» — на «ты».
    session.voice = updated.voiceOf(speaker);
    final response = session.reply(
      reply,
      intent: command,
      status: AssistantStatus.completed,
      settingsChange: change,
    );
    return response.withPersona(speaker.id);
  }

  /// «Пусть отвечает Лиорио»: главный — Связной, это не меняется
  /// (`talk.set.mainFixed`, в роде Связной, стилем говорящего).
  AssistantResponse _mainFixed(AssistantSession session, String command) {
    final main = session.personas.cast.responder;
    return AssistantResponse(
      message:
          session.sayAs('talk.set.mainFixed', main.gender, <String, String>{
        'main': main.russianName,
      }),
      intent: command,
      status: AssistantStatus.noAction,
      replyId: 'talk.set.mainFixed',
      values: <String, String>{'main': main.russianName},
    );
  }

  /// «Включи трио», «включи дуэт с Нодой», «включи соло»: режим меняет и
  /// подтверждает Связной — он есть в любом режиме.
  AssistantResponse _mode(
    TalkRequest request,
    AssistantSession session,
    String command,
  ) {
    final settings = session.personas;
    final cast = settings.cast;
    final main = cast.responder;
    session
      ..speaker = main
      ..voice = settings.voiceOf(main);
    final named = cast.find(request.persona);
    final helper = named != null && Personas.helperIds.contains(named.id)
        ? named.id
        : null;
    final mode = switch (request.setting!) {
      TalkSettingKind.modeSolo => TeamMode.solo,
      TalkSettingKind.modeDuo => TeamMode.duo,
      _ => TeamMode.trio,
    };
    final change = PersonaSettingsChange(
      teamMode: mode,
      duoHelper: mode == TeamMode.duo ? helper : null,
    );
    if (change.isNoOpFor(settings)) {
      return _say(
        session,
        'talk.set.already',
        command: command,
        status: AssistantStatus.noAction,
      ).withPersona(main.id);
    }
    final next = change.apply(settings).cast;
    final team = next.active.map((Persona p) => p.russianName).toList();
    final names = team.length <= 1
        ? team.join()
        : '${team.sublist(0, team.length - 1).join(', ')} и ${team.last}';
    final reply = switch (mode) {
      TeamMode.solo => 'talk.set.modeSolo',
      TeamMode.duo => 'talk.set.modeDuo',
      TeamMode.trio => 'talk.set.modeTrio',
    };
    return session
        .reply(
          reply,
          values: mode == TeamMode.solo
              ? const <String, String>{}
              : <String, String>{'team': names},
          intent: command,
          status: AssistantStatus.completed,
          settingsChange: change,
        )
        .withPersona(main.id);
  }

  static (PersonaSettingsChange, String) _jokes(JokeFrequency value) => (
        PersonaSettingsChange(jokes: value),
        'talk.set.jokes${value.name[0].toUpperCase()}${value.name.substring(1)}',
      );
}
