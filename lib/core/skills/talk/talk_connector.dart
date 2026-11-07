import 'dart:async';

import '../../app_info.dart';
import '../../connectors/connector.dart';
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
/// ответов голосом Liorio или Noda. Совпадения беседы — на крайний случай
/// ([ConnectorMatch.fallback]): любая команда задач, калькулятора или
/// подключения важнее.
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
    if (request == null) return null;
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
    final request = payload! as TalkRequest;
    final command = match.commandId;
    // «Спасибо, Нода», «как дела, Нода?»: в дуэте отвечает названный
    // помощник, его голосом, и он же становится адресатом чата
    // ([AssistantResponse.addressedPersonaId]). В соло имя — просто текст.
    // Просьба «пусть отвечает Лиорио» решает, кто подтвердит, сама (_setting):
    // имя в ней — не обращение, а новый основной.
    final named = Personas.byId(request.persona);
    if (named == null ||
        session.personas.mode != AssistantMode.duo ||
        request.setting == TalkSettingKind.main) {
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
    final (problems, unchecked) = await _problems(session);
    if (problems.isEmpty) {
      // Без проверки здоровья коннектор не проверен: «все работают» про
      // него не говорим, а называем его.
      final okId =
          unchecked.isEmpty ? 'talk.status.ok' : 'talk.status.okUnchecked';
      final okValues = unchecked.isEmpty
          ? const <String, String>{}
          : <String, String>{'unchecked': unchecked.join(', ')};
      final ok = session.say(okId, okValues);
      return AssistantResponse(
        message: sentences(<String>[ok, ...parts]),
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
  /// коннекторов без [ConnectorHealth]: их проверить нельзя.
  Future<(List<String>, List<String>)> _problems(
    AssistantSession session,
  ) async {
    final connectors =
        session.extensions?.enabledConnectors ?? const <Connector>[];
    final now = session.clock.now();
    final checks = <Future<String?>>[
      for (final connector in connectors)
        if (connector case final ConnectorHealth health)
          _check(health, connector.info.title, now),
    ];
    final unchecked = <String>[
      for (final connector in connectors)
        if (connector is! ConnectorHealth) '«${connector.info.title}»',
    ];
    final results = await Future.wait(checks);
    return (
      <String>[
        for (final result in results)
          if (result != null) result,
      ],
      unchecked,
    );
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

  static Future<String?> _check(
    ConnectorHealth health,
    String title,
    DateTime now,
  ) async {
    HealthReport report;
    try {
      report = await health.health().timeout(ConnectorHealth.timeout);
    } on TimeoutException {
      report = const HealthReport(
        HealthStatus.degraded,
        detail: 'не ответил на проверку вовремя',
      );
    } on Object catch (error) {
      report = HealthReport(
        HealthStatus.down,
        detail: 'проверка не удалась: $error',
      );
    }
    if (report.isOk) return null;
    return describe(title, report, now);
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

  AssistantResponse _who(AssistantSession session, String command) {
    final speaker = session.speaker;
    final settings = session.personas;
    // Помощник представляется вместе с приложением, но себя «связным» не
    // называет: роль — «помощник»/«помощница», название — «в Связном»
    // (ADR-009). О втором помощнике пары каталог говорит в обратном роде:
    // Liorio и Noda разного рода.
    final values = <String, String>{
      'name': speaker.name,
      'other': Personas.other(speaker).name,
      'appPrepositional': AppInfo.namePrepositional,
    };
    if (settings.mode == AssistantMode.solo) {
      return _say(
        session,
        'talk.who.solo',
        command: command,
        values: <String, String>{
          'name': speaker.name,
          'appPrepositional': AppInfo.namePrepositional,
        },
      );
    }
    return _say(
      session,
      settings.main.id == speaker.id ? 'talk.who.main' : 'talk.who.secondary',
      command: command,
      values: values,
    );
  }

  /// Только включённые навыки и подключения, по одному примеру: выключенное
  /// не рекламируется.
  AssistantResponse _capabilities(AssistantSession session, String command) {
    final connectors =
        session.extensions?.enabledConnectors ?? const <Connector>[];
    final items = <String>[
      for (final connector in connectors)
        connector.info.examples.isEmpty
            ? '«${connector.info.title}»'
            : '«${connector.info.title}» — например, '
                '«${connector.info.examples.first}»',
    ];
    if (items.isEmpty) items.add('«$_selfTitle»');
    return _say(
      session,
      'talk.capabilities',
      command: command,
      values: <String, String>{'skills': items.join('; ')},
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
    final speaker = session.speaker;
    final named = Personas.byId(request.persona);
    final duo = settings.mode == AssistantMode.duo;
    final (PersonaSettingsChange change, String reply) =
        switch (request.setting!) {
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
      TalkSettingKind.main => duo
          ? (
              PersonaSettingsChange(mainPersona: (named ?? speaker).id),
              'talk.set.main',
            )
          : (
              PersonaSettingsChange(soloPersona: (named ?? speaker).id),
              'talk.set.solo',
            ),
    };
    if (change.isNoOpFor(settings)) {
      if (request.setting != TalkSettingKind.main || !duo) {
        return _say(
          session,
          'talk.set.already',
          command: command,
          status: AssistantStatus.noAction,
        );
      }
      // «Пусть отвечает Лиорио», а Лиорио и так основной: настройки не меняются,
      // но просьба ясна — отвечает основной, и выбор адресата снимается
      // (адресат-основной — это `null`, [AssistantController.addresseeAfter]).
      final main = named ?? speaker;
      session
        ..speaker = main
        ..voice = settings.voiceOf(main);
      return _say(
        session,
        'talk.set.already',
        command: command,
        status: AssistantStatus.noAction,
      ).withPersona(main.id).withAddressed(main.id);
    }
    final updated = change.apply(settings);
    // Подтверждение звучит уже новым голосом: «без смайликов» — без
    // смайликов, «давай на ты» — на «ты». Новый основной отвечает сам.
    final responder =
        request.setting == TalkSettingKind.main ? (named ?? speaker) : speaker;
    session.voice = updated.voiceOf(responder);
    final response = session.reply(
      reply,
      values: request.setting == TalkSettingKind.main
          ? <String, String>{'name': responder.name}
          : const <String, String>{},
      intent: command,
      status: AssistantStatus.completed,
      settingsChange: change,
    );
    return response.withPersona(responder.id);
  }

  static (PersonaSettingsChange, String) _jokes(JokeFrequency value) => (
        PersonaSettingsChange(jokes: value),
        'talk.set.jokes${value.name[0].toUpperCase()}${value.name.substring(1)}',
      );
}
