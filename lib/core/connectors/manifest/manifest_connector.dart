import 'dart:async';
import 'dart:convert';

import '../../extensions/role.dart';
import '../connector.dart';
import '../http_transport.dart';
import '../secret_store.dart';
import '../social_prefix.dart';
import 'connection.dart';
import 'manifest_format.dart';
import 'manifest_matcher.dart';
import 'manifest_text.dart';
import 'manifest_view.dart';

/// Что `match` разобрал и передаёт в `run`: `run` фразу заново не разбирает.
final class ManifestPayload {
  const ManifestPayload({
    required this.command,
    required this.slots,
    required this.how,
    this.aliased = false,
  });

  /// Id команды описания: `where`.
  final String command;
  final Map<String, String> slots;

  /// `say`, `fallback` или `help` (своя фраза справки «Связного»).
  final String how;

  /// Фраза начиналась с обращения к приложению: «на складе …».
  final bool aliased;
}

/// Коннектор к любому приложению с описанием `assistant/1` (ADR-011):
/// склад halowarekeep, потом expeora. Фразы, запрос и ответ — из
/// описания; голос, защиты маршрутизации и тексты ошибок — «Связного».
///
/// Только чтение: действия — из `api.only`, других коннектор не зовёт.
/// Секреты (пароль приложения, личный ключ) — только в [SecretStore];
/// в ответах, логах и настройках их нет.
final class ManifestConnector implements Connector, ConnectorHealth, RoleHints {
  ManifestConnector({
    required this.slot,
    required HttpTransport transport,
    required SecretStore secrets,
    ManifestDescription? description,
    ConnectionRecord? record,
  })  : _transport = transport,
        _secrets = secrets,
        record = record ?? ConnectionRecord(appId: slot.appId) {
    if (description != null) load(description);
  }

  final ConnectionSlot slot;
  final HttpTransport _transport;
  final SecretStore _secrets;

  ManifestDescription? _description;
  ManifestMatcher? _matcher;

  /// Состояние подключения изменилось (успех, сбой): владелец сохраняет
  /// его без секретов.
  void Function(ConnectionRecord record)? onRecordChanged;

  /// Описание давно не проверялось (старше [staleAfter]): владелец
  /// обновляет его в фоне. Вызывается после успешного ответа.
  void Function()? onStale;

  /// Через сколько описание проверяется заново.
  static const Duration staleAfter = Duration(hours: 24);

  /// Сколько ждать сервер: подсчёт остатков на большом складе идёт
  /// несколько секунд.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// Длиннее этого сообщение не разбирается: регулярные выражения `shape`
  /// пришли извне.
  static const int maxLength = 200;

  ManifestDescription? get description => _description;

  /// Состояние подключения: меняют его вход и выход ([ConnectionService])
  /// и ответы сервера.
  ConnectionRecord record;

  /// Подсказки маршрутизации включённых ролей (ADR-012): `bareCodes` —
  /// голый артикул уверенно «где лежит», `bareWords` — однословные фразы
  /// команд без поля («сегодня», «вчера») без обращения «склад, …». Обе
  /// действуют, только пока приложение подключено.
  Set<String> _hints = const <String>{};

  Set<String> get roleHints => _hints;

  @override
  void applyRoleHints(Set<String> hints) {
    _hints = Set<String>.unmodifiable(hints);
  }

  bool _hint(String name) => record.connected && _hints.contains(name);

  /// Заменяет описание сразу целиком: `match` читает текущий снимок.
  void load(ManifestDescription description) {
    _matcher = ManifestMatcher(description);
    _description = description;
  }

  @override
  ConnectorInfo get info => ConnectorInfo(
        id: slot.id,
        title: slot.title,
        description: slot.description,
        examples: examples,
        requiresNetwork: true,
        access: ConnectorAccess.readOnly,
        kind: ExtensionKind.connector,
        defaultEnabled: false,
        replies: slot.replies,
        protectedReplies: slot.protectedReplies,
      );

  /// Примеры команд описания, кроме справки.
  List<String> get examples => <String>[
        for (final command
            in _description?.commands ?? const <ManifestCommand>[])
          if (!command.help) ...command.examples,
      ];

  // ------------------------------------------------------------- match

  /// Слова в начале, после которых идёт вопрос: «кстати, где лежит …»,
  /// «узнать, где лежит …».
  static const Set<String> _leadWords = <String>{
    'кстати',
    'слушай',
    'слушайте',
    'узнать',
    'узнай',
    'проверить',
    'проверь',
    'посмотреть',
    'посмотри',
    'уточнить',
    'уточни',
    'глянуть',
    'глянь',
  };

  /// Слова задач и чата «Связного»: «сколько у меня задач» — не товар.
  static bool _taskWord(String w) =>
      w.startsWith('задач') ||
      w.startsWith('напомн') ||
      w.startsWith('напомин') ||
      w.startsWith('чат') ||
      w == 'дел' ||
      w == 'дела' ||
      w == 'делам';

  /// Обращение к помощнику или о себе: «сколько тебе лет» — беседа.
  static const Set<String> _pronouns = <String>{
    'ты',
    'тебе',
    'тебя',
    'тобой',
    'твой',
    'твоя',
    'твои',
    'вы',
    'вам',
    'вас',
    'вами',
    'я',
    'меня',
    'мне',
    'мной',
    'мой',
    'моя',
    'мое',
    'мои',
  };

  /// Слова примеров: «сколько будет 2+2» — калькулятору.
  static const Set<String> _calcWords = <String>{
    'будет',
    'умножить',
    'умножь',
    'разделить',
    'раздели',
    'подели',
    'корень',
    'плюс',
    'минус',
    'равно',
    'процент',
    'процента',
    'процентов',
    'квадрате',
    'кубе',
    'степени',
  };

  /// Время и возраст: «сколько времени», «сколько дней до отпуска» — не
  /// остатки.
  static const Set<String> _timeWords = <String>{
    'время',
    'времени',
    'часов',
    'минут',
    'секунд',
    'дней',
    'недель',
    'месяцев',
    'лет',
  };

  /// Глаголы команд задач в начале: «напомни», «запиши», «добавь».
  static const Set<String> _commandVerbs = <String>{
    'запиши',
    'запишите',
    'записать',
    'добавь',
    'добавьте',
    'добавить',
    'создай',
    'создайте',
    'создать',
    'удали',
    'удалить',
    'отмени',
    'отменить',
    'перенеси',
    'перенести',
    'отметь',
    'отметить',
    'заверши',
    'завершить',
    'закрой',
    'закрыть',
    'поставь',
    'сделай',
    'измени',
    'переименуй',
  };

  /// Реплики беседы и ответы на вопрос: целиком из этих слов — не товар.
  static const Set<String> _chatWords = <String>{
    'спасибо',
    'благодарю',
    'да',
    'нет',
    'не',
    'ага',
    'угу',
    'пока',
    'привет',
    'здравствуй',
    'здравствуйте',
    'хорошо',
    'ок',
    'окей',
    'ok',
    'ладно',
    'понятно',
    'ясно',
    'готово',
    'сделано',
    'выполнено',
    'отлично',
    'супер',
    'класс',
    'стоп',
    'отмена',
    'доброе',
    'добрый',
    'утро',
    'день',
    'вечер',
    'ночи',
    'спокойной',
    'большое',
    'ещё',
    'еще',
    'раз',
    'конечно',
    'верно',
    'точно',
    'всё',
    'все',
    'помощь',
  };

  /// Остаток после обращения — не запрос товара: команда задач («напомни
  /// …») или реплика («спасибо», «да», «готово»).
  static bool _conversational(String value) {
    final words = askText(value)
        .split(_wordSplit)
        .where((String w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return true;
    final first = words.first;
    if (_commandVerbs.contains(first) ||
        first.startsWith('напомн') ||
        first.startsWith('напомин')) {
      return true;
    }
    return words.every(_chatWords.contains);
  }

  static final RegExp _calcSigns = RegExp('[+*/=^×÷%]');
  static final RegExp _wordSplit = RegExp('[^a-zа-я0-9]+');
  static final RegExp _code = RegExp(r'^\d{5,6}$');
  static final RegExp _spacedDash = RegExp(r'\s-|-\s');

  @override
  ConnectorMatch? match(Utterance utterance) {
    final matcher = _matcher;
    if (matcher == null) return null;
    final text = askText(SocialPrefix.rest(utterance) ?? utterance.original);
    if (text.isEmpty || text.length > maxLength) return null;
    final lead = _withoutLead(text);
    // «покажи мне, где лежит …»: запятая после связок мешает их снять.
    final plain = text.replaceAll(RegExp(r'\s*,\s*'), ' ');
    for (final candidate in <String>{text, if (lead != null) lead, plain}) {
      final found = _matchText(matcher, utterance, candidate, aliased: false);
      if (found != null) return found.match;
      final rest = _withoutAlias(candidate);
      if (rest != null) {
        final aliased = _matchText(matcher, utterance, rest, aliased: true);
        if (aliased != null) return aliased.match;
      }
    }
    return null;
  }

  /// «кстати, где лежит 64115» → «где лежит 64115».
  static String? _withoutLead(String text) {
    final space = text.indexOf(RegExp('[ ,]'));
    if (space < 0) return null;
    if (!_leadWords.contains(text.substring(0, space))) return null;
    final rest = text.substring(space).replaceFirst(RegExp(r'^[\s,]+'), '');
    return rest.isEmpty ? null : rest;
  }

  /// «на складе где стул» → «где стул».
  String? _withoutAlias(String text) {
    final aliases = slot.aliases.map(askText).toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    for (final alias in aliases) {
      if (!text.startsWith(alias) || text.length == alias.length) continue;
      final next = text[alias.length];
      if (next != ' ' && next != ',' && next != ':') continue;
      final rest =
          text.substring(alias.length).replaceFirst(RegExp(r'^[\s,:—-]+'), '');
      if (rest.isNotEmpty) return rest;
    }
    return null;
  }

  _Found? _matchText(
    ManifestMatcher matcher,
    Utterance utterance,
    String text, {
    required bool aliased,
  }) {
    final description = matcher.description;
    if (slot.helpPhrases.map(askText).contains(text)) {
      final help =
          description.commands.where((ManifestCommand c) => c.help).firstOrNull;
      return _found(
        help?.id ?? 'help',
        const <String, String>{},
        'help',
        0.9,
        aliased: aliased,
      );
    }
    final bare = matcher.strip(text);
    for (final pass
        in bare.isNotEmpty && bare != text ? [text, bare] : [text]) {
      for (final hit in matcher.hits(pass)) {
        final verdict = _judge(hit, utterance, pass, aliased: aliased);
        if (verdict == null) continue;
        if (verdict < 0) return const _Found(null);
        return _found(
          hit.command.id,
          hit.slots,
          hit.how,
          verdict,
          aliased: aliased,
        );
      }
    }
    final fallback = matcher.fallback;
    if (fallback == null) return null;
    final value = bare.isNotEmpty ? bare : text;
    final codeOnly = _code.hasMatch(value) && utterance.codes.length == 1;
    if (!codeOnly && !aliased) return null;
    // «склад, напомни купить хлеб», «склад, спасибо»: после обращения —
    // команда задач или реплика беседы, а не товар.
    if (aliased && !codeOnly && _conversational(value)) {
      return const _Found(null);
    }
    final name = fallback.slots.keys.first;
    final slotValue = matcher.slotValue(fallback.slots[name], value);
    if (slotValue.isEmpty) return null;
    final def = fallback.slots[name];
    if (def?.type != 'cell' &&
        def?.type != 'int' &&
        !_allowedText(slotValue, utterance)) {
      return const _Found(null);
    }
    return _found(
      fallback.id,
      <String, String>{name: slotValue},
      'fallback',
      // Роль «Кладовщик» и подключённый склад: голый артикул — уверенно
      // «где лежит».
      codeOnly ? (_hint('bareCodes') ? 0.9 : 0.7) : 0.75,
      aliased: aliased,
    );
  }

  _Found _found(
    String command,
    Map<String, String> slots,
    String how,
    double confidence, {
    required bool aliased,
  }) =>
      _Found(
        ConnectorMatch(
          connectorId: slot.id,
          commandId: '${slot.id}.$command',
          confidence: aliased
              ? (confidence + 0.05).clamp(0.0, 0.95).toDouble()
              : confidence,
          payload: ManifestPayload(
            command: command,
            slots: slots,
            how: how,
            aliased: aliased,
          ),
        ),
      );

  /// Уверенность для совпадения правила; `null` — правило не годится,
  /// искать дальше; меньше нуля — фраза точно не этого приложения.
  double? _judge(
    ManifestHit hit,
    Utterance utterance,
    String pass, {
    required bool aliased,
  }) {
    final rule = hit.rule!;
    final command = hit.command;
    if (command.help) return aliased ? 0.9 : null;
    if (rule.names.isEmpty) {
      // «сегодня», «вчера», «помощь» — слишком общие без обращения.
      if (rule.literalWords <= 1 && !aliased) {
        // Роль «Кладовщик» и подключённый склад: «сегодня» — приходы.
        return rule.literalWords == 1 &&
                command.call != null &&
                _hint('bareWords')
            ? 0.85
            : null;
      }
      return 0.9;
    }
    for (final name in rule.names) {
      final def = command.slots[name];
      if (def?.type == 'cell' || def?.type == 'int') continue;
      if (!_allowedText(hit.slots[name] ?? '', utterance)) return -1;
    }
    if (rule.literalWords == 0) {
      // Голое поле — только код по `shape`: «215-1-1-1», «без места».
      final shaped = rule.names.every(
        (String n) => command.slots[n]?.shape != null,
      );
      if (!shaped || _spacedDash.hasMatch(pass)) return null;
      return 0.85;
    }
    return rule.literalWords == 1 ? 0.75 : 0.9;
  }

  /// Текстовое поле не про задачи, беседу, пример или срок.
  static bool _allowedText(String value, Utterance utterance) {
    final normalized = askText(value);
    if (_calcSigns.hasMatch(normalized)) return false;
    final words =
        normalized.split(_wordSplit).where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) return false;
    final dueWords = <String>{
      for (final token in utterance.tokens)
        if (Utterance.isCovered(token, utterance.due.spans)) token.text,
    };
    for (final word in words) {
      if (_taskWord(word) ||
          _pronouns.contains(word) ||
          _calcWords.contains(word) ||
          _timeWords.contains(word)) {
        return false;
      }
      if (dueWords.contains(word) && !_code.hasMatch(word)) return false;
    }
    return true;
  }

  // --------------------------------------------------------------- run

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload! as ManifestPayload;
    final intent = match.commandId;
    AssistantResponse say(
      String name,
      AssistantStatus status, [
      Map<String, String> values = const <String, String>{},
    ]) =>
        session.reply(
          '${slot.id}.$name',
          values: values,
          intent: intent,
          status: status,
        );

    final description = _description;
    final command = description?.command(payload.command);
    if (payload.how == 'help' || (command?.help ?? false)) {
      return say('help', AssistantStatus.completed, <String, String>{
        'list': _helpList(),
      });
    }
    if (description == null || command == null) {
      return say('serverError', AssistantStatus.failed);
    }
    if (command.reply case final String text) {
      // Свой текст каталога — голосом помощника; текст описания (на «вы»,
      // о «помощнике» в третьем лице) — только для незнакомой команды.
      final own = slot.commandReplies[command.id];
      if (own != null) return say(own, AssistantStatus.completed);
      return say('reply', AssistantStatus.completed, <String, String>{
        'text': text,
      });
    }
    final call = command.call;
    final base = record.manifestUri;
    final token = await _secrets.read(slot.tokenKey);
    if (call == null || base == null || token == null || token.isEmpty) {
      // Подключение включила роль, а входа ещё нет: подсказать путь через
      // карточку роли (ADR-012), а не «не понял».
      final role = session.extensions?.activeRoleOf(slot.id);
      final link = role?.connection;
      if (role != null && link != null && link.extensionId == slot.id) {
        return session.reply(
          'role.notConnected',
          values: <String, String>{
            'app': link.appTitle,
            'role': role.title,
            'button': link.connectLabel,
          },
          intent: intent,
          status: AssistantStatus.noAction,
        );
      }
      return say('notConnected', AssistantStatus.noAction);
    }
    final needs =
        description.access[command.access]?.needs ?? const <String>['token'];
    final credentials = <String, String>{'token': token};
    for (final name in needs) {
      if (name == 'token') continue;
      final value = await _secrets.read(slot.secretKey(name));
      if (value == null || value.isEmpty) {
        // Без личного ключа команду `staff` не зовём (README формата).
        return say('auth.staff', AssistantStatus.noAction);
      }
      credentials[name] = value;
    }
    final now = session.clock.now();
    final vars = ManifestVars(now);
    final request = HttpRequestData(
      method: description.method,
      uri: actionUri(description, base, call.action),
      headers: headersFor(description, credentials),
      body: jsonEncode(askBody(call.body, payload.slots, vars)),
      timeout: requestTimeout,
    );
    final HttpResponseData response;
    try {
      response = await _transport.send(request);
    } on TimeoutException {
      _fail(ConnectionFailure.offline, now);
      return say('timeout', AssistantStatus.failed);
    } on Object {
      _fail(ConnectionFailure.offline, now);
      return say('offline', AssistantStatus.failed);
    }
    final json = _jsonObject(response.body);
    final status = response.statusCode;
    if (response.isSuccess) {
      if (json == null) {
        _fail(ConnectionFailure.server, now);
        return say('serverError', AssistantStatus.failed);
      }
      _succeed(now, staff: credentials.containsKey('sid'));
      return _answer(command, payload, json, vars, session, intent);
    }
    final error = _errorText(json?[description.errorField]);
    switch (status) {
      case 401:
        _fail(ConnectionFailure.token, now);
        return say('auth.token', AssistantStatus.failed);
      case 403:
        final need = json?[description.needField];
        if (need == 'login') {
          if (credentials.containsKey('sid')) {
            _fail(ConnectionFailure.expired, now);
            return say('auth.expired', AssistantStatus.failed);
          }
          return say('auth.staff', AssistantStatus.noAction);
        }
        if (need == 'role') return say('auth.role', AssistantStatus.noAction);
      case 429:
        return say('busy', AssistantStatus.noAction);
    }
    if (status >= 400 && status < 500 && error.isNotEmpty) {
      // Сервер работает и объяснил, что не так: «Нужен код ячейки».
      return say('serverSaid', AssistantStatus.completed, <String, String>{
        'error': error,
      });
    }
    _fail(ConnectionFailure.server, now);
    return say('serverError', AssistantStatus.failed);
  }

  AssistantResponse _answer(
    ManifestCommand command,
    ManifestPayload payload,
    Map<String, Object?> json,
    ManifestVars vars,
    AssistantSession session,
    String intent,
  ) {
    final view = ManifestView.of(command, json, payload.slots, vars);
    if (view.empty) {
      final fallback = payload.how == 'fallback';
      final id = '${slot.id}.${fallback ? 'fallbackEmpty' : 'empty'}';
      final values = <String, String>{
        'text': view.say,
        if (fallback) 'examples': _fallbackExamples(),
      };
      return session.reply(
        id,
        values: values,
        intent: intent,
        status: AssistantStatus.completed,
      );
    }
    final id = '${slot.id}.answer';
    final values = <String, String>{'text': view.say};
    final message = StringBuffer(session.say(id, values));
    for (final line in view.lines()) {
      message
        ..write('\n')
        ..write(line);
    }
    if (view.more.isNotEmpty) {
      message
        ..write('\n')
        ..write(session.say('${slot.id}.more'));
    }
    return AssistantResponse(
      message: message.toString(),
      intent: intent,
      status: AssistantStatus.completed,
      replyId: id,
      values: values,
    );
  }

  /// «где лежит товар — «где лежит 64115»; …».
  String _helpList() => <String>[
        for (final command
            in _description?.commands ?? const <ManifestCommand>[])
          if (!command.help && command.examples.isNotEmpty)
            '${_lowerFirst(command.title)} — «${command.examples.first}»',
      ].join('; ');

  String _fallbackExamples() => <String>[
        for (final command
            in _description?.commands ?? const <ManifestCommand>[])
          if (command.call != null && command.examples.isNotEmpty)
            '«${command.examples.first}»',
      ].take(3).join(', ');

  static String _lowerFirst(String text) =>
      text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

  /// Адрес действия: `api.url` относительно описания, имя действия — в
  /// параметре `api.action.name`.
  static Uri actionUri(ManifestDescription d, Uri manifestUri, String action) {
    final api = manifestUri.resolve(d.apiUrl);
    return api.replace(
      queryParameters: <String, String>{
        ...api.queryParameters,
        d.actionName: action,
      },
    );
  }

  /// Заголовки запроса: JSON и ключи входа по `auth.headers`. Заголовок,
  /// для которого нет ключа в [credentials], не отправляется.
  static Map<String, String> headersFor(
    ManifestDescription d,
    Map<String, String> credentials,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final field = RegExp(r'\{\$([a-z][a-z0-9_]*)\}', caseSensitive: false);
    for (final MapEntry(:key, :value) in d.headers.entries) {
      var missing = false;
      final filled = value.replaceAllMapped(field, (Match m) {
        final secret = credentials[m[1]!];
        if (secret == null || secret.isEmpty) missing = true;
        return secret ?? '';
      });
      if (!missing && filled.isNotEmpty) headers[key] = filled;
    }
    return headers;
  }

  static Map<String, Object?>? _jsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Управляющие символы и знаки направления текста.
  static final RegExp _controls =
      RegExp('[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e]');

  /// Текст ошибки сервера для ответа: одна строка, не длиннее 300 знаков.
  static String _errorText(Object? value) {
    if (value is! String) return '';
    final text =
        value.replaceAll(_controls, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 300 ? '${text.substring(0, 299)}…' : text;
  }

  /// Ответ пришёл. Команда без личного ключа ([staff] — `false`) не
  /// доказывает, что ключ снова годен: «ключ устарел» остаётся до
  /// успешной команды с ключом или нового входа.
  void _succeed(DateTime now, {required bool staff}) {
    final keep = !staff && record.failure == ConnectionFailure.expired;
    _update(record.copyWith(lastOk: now, clearFailure: !keep));
    final fetched = record.manifest.fetchedAt;
    if (fetched == null || now.difference(fetched) > staleAfter) {
      onStale?.call();
    }
  }

  void _fail(ConnectionFailure failure, DateTime now) {
    final since = record.failure == failure ? record.failureSince ?? now : now;
    _update(record.copyWith(failure: failure, failureSince: since));
  }

  void _update(ConnectionRecord record) {
    this.record = record;
    onRecordChanged?.call(record);
  }

  // ------------------------------------------------------------ health

  /// Из запомненного состояния, без сети: отвечает мгновенно.
  @override
  Future<HealthReport> health() async {
    final token = await _secrets.read(slot.tokenKey);
    if (token == null || token.isEmpty || !record.connected) {
      return const HealthReport(HealthStatus.down, detail: 'не подключён');
    }
    final since = record.failureSince;
    return switch (record.failure) {
      ConnectionFailure.offline => HealthReport(
          HealthStatus.down,
          detail: 'нет связи с сервером',
          since: since,
        ),
      ConnectionFailure.token => HealthReport(
          HealthStatus.down,
          detail: 'не принял пароль',
          since: since,
        ),
      ConnectionFailure.server => HealthReport(
          HealthStatus.degraded,
          detail: 'отвечает с ошибками',
          since: since,
        ),
      ConnectionFailure.expired => HealthReport(
          HealthStatus.degraded,
          detail: 'команды под логином недоступны: нужен новый вход',
          since: since,
        ),
      null => HealthReport(HealthStatus.ok, since: record.lastOk),
    };
  }
}

/// Итог разбора одного варианта текста: совпадение или «точно не моё»
/// (`match == null`).
final class _Found {
  const _Found(this.match);

  final ConnectorMatch? match;
}
