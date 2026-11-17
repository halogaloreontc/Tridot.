part of 'manifest_connector.dart';

// Действия с записью на складе (ADR-013): перемещение между ячейками и
// отметка проведения прихода. Фразы — только из встроенной копии описания
// (`actions[]`), тела запросов, карточка и ответы — код «Tridot» по виду
// действия. Ход: фраза → шлюзы без сети → расчёт `act_*_check` (чтение) →
// вопрос или карточка → запись `act_*` только по кнопке «Подтвердить»,
// ровно одним запросом → итог; неизвестный итог — `act_settle`.

/// Разобранная фраза действия: что `match` передаёт в `run`.
final class ActRequest {
  const ActRequest({
    required this.action,
    required this.slots,
    this.marks = const <String>[],
    this.what,
  });

  final ManifestAction action;

  /// Поля фразы: `from`, `to` — ячейки заглавными, `no` — номер прихода.
  final Map<String, String> slots;

  /// Для проведения: какие отметки ставить (`sv`, `odin_c`) — по
  /// литералу в сработавшей фразе: «1с» — только 1С, «sv» — только SV, без
  /// литерала — обе.
  final List<String> marks;

  /// Для перемещения: количество, товар и класс из `{what}`.
  final ActWhat? what;
}

/// Количество, товар и класс из поля `{what}` («3 венских стула уценка»).
final class ActWhat {
  const ActWhat({this.qty, this.sku, this.q, this.cls});

  /// Число 1…9999 или `"all"` («все», «целиком»); `null` — не сказано.
  final Object? qty;

  /// Артикул: 5–6 цифр.
  final String? sku;

  /// Название или его часть для поиска на складе.
  final String? q;

  /// Код класса: `UCENKA`, `BRAK`, `REAL`, `SAMPLE`, `UTIL`.
  final String? cls;

  static const Map<String, int> _numbers = <String, int>{
    'один': 1,
    'одну': 1,
    'одна': 1,
    'два': 2,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
    'десять': 10,
    'одиннадцать': 11,
    'двенадцать': 12,
  };

  static const Set<String> _all = <String>{'все', 'целиком'};

  static const Set<String> _pieces = <String>{
    'шт',
    'штук',
    'штуки',
    'штука',
    'штуку',
  };

  static const Set<String> _skuWords = <String>{
    'арт',
    'артикул',
    'артикула',
    'артикулом',
  };

  /// Класс — завершающим словом; коды как `ASK_CLASSES` склада.
  static const Map<String, String> classes = <String, String>{
    'уценка': 'UCENKA',
    'уценку': 'UCENKA',
    'уценки': 'UCENKA',
    'брак': 'BRAK',
    'брака': 'BRAK',
    'реализация': 'REAL',
    'реализацию': 'REAL',
    'реализации': 'REAL',
    'образец': 'SAMPLE',
    'образцы': 'SAMPLE',
    'образца': 'SAMPLE',
    'утиль': 'UTIL',
  };

  static final RegExp _digits = RegExp(r'^\d+$');
  static final RegExp _code = RegExp(r'^\d{5,6}$');

  /// Число 1…9999, число словами или «все»; `null` — не количество.
  static Object? quantity(String word) {
    final text = askText(word);
    if (_all.contains(text)) return 'all';
    if (_digits.hasMatch(text) && text.length < 5) {
      final n = int.parse(text);
      return n >= 1 && n <= 9999 ? n : null;
    }
    return _numbers[text];
  }

  /// Разбор `{what}`. Количество — ведущее («3», «3 шт», «три», «все»);
  /// число из 5–6 цифр — артикул, не количество; класс — завершающее
  /// слово. Остаток — запрос по названию, если он не про задачи, беседу,
  /// пример или срок ([allowed]). `null` — фраза не про товар.
  static ActWhat? parse(String raw, bool Function(String text) allowed) {
    final words =
        askText(raw).split(' ').where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    Object? qty;
    String? sku;
    String? cls;
    if (words.length > 1 && classes.containsKey(words.last)) {
      cls = classes[words.removeLast()];
    }
    final first = words.first;
    if (_code.hasMatch(first)) {
      sku = words.removeAt(0);
    } else if (_digits.hasMatch(first)) {
      final n = int.tryParse(first);
      if (n == null || n < 1) return null;
      qty = n;
      words.removeAt(0);
    } else if (quantity(first) case final Object found) {
      qty = found;
      words.removeAt(0);
    }
    if (qty != null && words.isNotEmpty && _pieces.contains(words.first)) {
      words.removeAt(0);
    }
    if (sku == null && words.isNotEmpty && _skuWords.contains(words.first)) {
      words.removeAt(0);
    }
    if (sku == null && words.isNotEmpty && _code.hasMatch(words.first)) {
      sku = words.removeAt(0);
    }
    if (qty == null && words.isNotEmpty && words.last == 'целиком') {
      qty = 'all';
      words.removeLast();
    }
    if (words.length == 1 && classes.containsKey(words.single)) {
      cls ??= classes[words.removeLast()];
    }
    final rest = words.join(' ');
    if (sku == null && rest.isEmpty && qty == null) return null;
    if (sku == null && rest.isNotEmpty && !allowed(rest)) return null;
    return ActWhat(
      qty: qty,
      sku: sku,
      q: sku == null && rest.isNotEmpty ? rest : null,
      cls: cls,
    );
  }
}

/// Черновик действия: что уже известно и о чём последний вопрос. Ответ на
/// вопрос («2», «все», «215-3-2-1») уточняет черновик, и расчёт идёт снова.
final class ActDraft {
  ActDraft({
    required this.action,
    this.from = '',
    this.to = '',
    this.q,
    this.sku,
    this.cls,
    this.qty,
    this.no = '',
    this.id,
    this.set = const <String>[],
  });

  final ManifestAction action;
  String from;
  String to;
  String? q;
  String? sku;
  String? cls;
  Object? qty;
  String no;
  String? id;
  List<String> set;

  /// Последний вопрос: `row`, `qty`, `to`, `entry`; `null` — вопроса нет.
  String? asked;

  /// Варианты последнего вопроса «какой?» в том виде, как их прислал
  /// склад.
  List<Map<String, Object?>> options = const <Map<String, Object?>>[];

  /// Сколько вопросов задано: больше [maxQuestions] — «скажи целиком».
  int questions = 0;

  /// Запись каталога и факты последнего вопроса — повторить его.
  String? questionId;
  Map<String, String> questionValues = const <String, String>{};

  static const int maxQuestions = 4;

  bool get isMove => action.kind == 'move';

  /// Тело расчёта: только известные поля, числа — числами.
  Map<String, Object?> checkBody(ManifestVars vars) => isMove
      ? <String, Object?>{
          'v': 1,
          'from': from,
          if (to.isNotEmpty) 'to': to,
          if (sku != null) 'sku': sku,
          if (sku == null && q != null) 'q': q,
          if (cls != null) 'cls': cls,
          if (qty != null) 'qty': qty,
        }
      : <String, Object?>{
          'v': 1,
          if (id != null) 'id': id else 'no': no,
          'set': set,
          'tz': vars.tz,
        };
}

/// Ответ на вопрос черновика: какой вариант, сколько или куда.
final class ActFollow {
  const ActFollow(this.draft, {this.option, this.qty, this.to, this.from});

  final ActDraft draft;
  final int? option;
  final Object? qty;
  final String? to;

  /// Ответ на «Из какой ячейки?» (склад требует `from`, ADR-031).
  final String? from;
}

/// Правило фразы действия: одна фраза `say` встроенной копии.
final class _ActRule {
  _ActRule({
    required this.action,
    required this.names,
    required this.pattern,
    required this.weight,
    required this.marks,
  });

  final ManifestAction action;
  final List<String> names;
  final RegExp pattern;
  final int weight;
  final List<String> marks;
}

/// Ответ сервера на запрос действия: код и JSON-объект или сбой связи.
final class _ActHttp {
  const _ActHttp(this.status, this.json) : network = null;

  const _ActHttp.failed(String this.network)
      : status = 0,
        json = null;

  final int status;
  final Map<String, Object?>? json;

  /// `offline` или `timeout`; `null` — ответ пришёл.
  final String? network;

  bool get ok => network == null && status >= 200 && status < 300;
}

extension _Actions on ManifestConnector {
  static final Expando<ActDraft> _drafts = Expando<ActDraft>('act-draft');

  static final RegExp _stamp = RegExp(r'^[0-9a-f]{64}$');

  /// Коды 5xx записи, после которых точно ничего не изменилось:
  /// хранилище не приняло запись, самопроверка не сошлась. Любой другой
  /// 5xx — итог неизвестен (`act_settle`).
  static const Set<String> _definite = <String>{'storage', 'selfcheck'};

  /// Адрес для сравнения: заглавными, «Ё» как «Е», пробелы одиночные.
  /// Фраза приходит с «е» («приемки»), склад отвечает адресом схемы
  /// («ПРИЁМКИ») — это одна ячейка.
  static String _cellKey(String cell) => cell
      .trim()
      .toUpperCase()
      .replaceAll('Ё', 'Е')
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Правила фраз действий встроенной копии. Поля-ячейки с `shape`
  /// вшиваются в выражение: «стул из бука из 215-1-1-1 в …» режется по
  /// той « из », после которой идёт ячейка, а не по первой.
  static List<_ActRule> compile(ManifestDescription? builtIn) {
    final rules = <_ActRule>[];
    for (final action in builtIn?.actions ?? const <ManifestAction>[]) {
      if (!ManifestDescription.writeActions.containsKey(action.kind)) continue;
      for (final phrase in action.say) {
        final text = askText(phrase);
        final names = <String>[];
        final literals = <String>[];
        final pattern = StringBuffer('^');
        var last = 0;
        for (final m in askSlotPattern.allMatches(text)) {
          literals.add(text.substring(last, m.start));
          pattern.write(_escape(text.substring(last, m.start)));
          final name = m[1]!;
          final def = action.slots[name];
          final shape = def?.type == 'cell' ? def?.shape : null;
          final group = 's${names.length}';
          pattern.write(
            shape == null
                ? '(?<$group>.+?)'
                : '(?<$group>(?:${_inner(shape)}))',
          );
          names.add(name);
          last = m.end;
        }
        literals.add(text.substring(last));
        pattern
          ..write(_escape(text.substring(last)))
          ..write(r'$');
        final words = literals
            .join(' ')
            .split(' ')
            .where((String w) => w.trim().isNotEmpty)
            .toList();
        rules.add(
          _ActRule(
            action: action,
            names: names,
            pattern: RegExp(pattern.toString(), caseSensitive: false),
            weight: literals.join().length,
            marks: action.kind != 'post'
                ? const <String>[]
                : words.contains('1с') || words.contains('1c')
                    ? const <String>['odin_c']
                    : words.contains('sv') || words.contains('св')
                        ? const <String>['sv']
                        : const <String>['sv', 'odin_c'],
          ),
        );
      }
    }
    rules.sort((_ActRule a, _ActRule b) => b.weight.compareTo(a.weight));
    return List<_ActRule>.unmodifiable(rules);
  }

  static String _escape(String text) =>
      text.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}');

  /// `shape` без привязки к началу и концу — чтобы вшить в фразу.
  static String _inner(String shape) {
    var s = shape;
    if (s.startsWith('^')) s = s.substring(1);
    if (s.endsWith(r'$') && !s.endsWith(r'\$')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  // ------------------------------------------------------------ match

  /// Фраза действия или `null`. Понимается, пока включена роль (иначе
  /// коннектор не спрашивают вовсе), даже при выключенном «Разрешить
  /// действия»: запрет объясняет `run`, а фраза не уходит в задачи.
  ConnectorMatch? matchAction(String text, Utterance utterance) {
    if (_actRules.isEmpty) return null;
    final plain = text.replaceAll(RegExp(r'\s*,\s*'), ' ');
    for (final candidate in <String>{text, plain}) {
      final found = _actHit(candidate, utterance, aliased: false);
      if (found != null) return found;
      final rest = _withoutAlias(candidate);
      if (rest != null) {
        final aliased = _actHit(rest, utterance, aliased: true);
        if (aliased != null) return aliased;
      }
    }
    return null;
  }

  ConnectorMatch? _actHit(
    String text,
    Utterance utterance, {
    required bool aliased,
  }) {
    for (final rule in _actRules) {
      final m = rule.pattern.firstMatch(text);
      if (m == null) continue;
      final slots = <String, String>{};
      var ok = true;
      ActWhat? what;
      for (var i = 0; i < rule.names.length; i++) {
        final name = rule.names[i];
        final raw = m.namedGroup('s$i') ?? '';
        final def = rule.action.slots[name];
        if (def?.type == 'cell') {
          final value = _cellValue(def!, raw);
          if (value.isEmpty) ok = false;
          slots[name] = value;
        } else if (name == 'what') {
          what = ActWhat.parse(
            raw,
            (String rest) => ManifestConnector._allowedText(rest, utterance),
          );
          if (what == null) ok = false;
        } else {
          final value = raw.trim();
          final shape = def?.shape;
          if (value.isEmpty ||
              (shape != null &&
                  !RegExp(shape, caseSensitive: false).hasMatch(value))) {
            ok = false;
          }
          slots[name] = value;
        }
      }
      if (!ok) continue;
      final kind = rule.action.kind;
      return ConnectorMatch(
        connectorId: slot.id,
        commandId: '${slot.id}.act.$kind',
        confidence: aliased ? 0.95 : 0.9,
        payload: ActRequest(
          action: rule.action,
          slots: slots,
          marks: rule.marks,
          what: what,
        ),
      );
    }
    return null;
  }

  /// Ячейка по `shape` поля, заглавными, без пробелов вокруг «-».
  static String _cellValue(ManifestSlot def, String raw) {
    final shape = def.shape;
    if (shape == null) return '';
    if (!RegExp(shape, caseSensitive: false).hasMatch(askText(raw))) return '';
    return raw
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'\s*-\s*'), '-')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Ответ на вопрос черновика или `null` — сообщение о другом.
  ConnectorMatch? followUpAction(Utterance utterance, ActDraft draft) {
    final text = askText(utterance.original);
    if (text.isEmpty || text.length > 40) return null;
    ActFollow? follow;
    switch (draft.asked) {
      case 'row' || 'entry':
        final index = _optionIndex(text, draft);
        if (index != null) follow = ActFollow(draft, option: index);
      case 'qty':
        final words = text.split(' ');
        final qty = words.length <= 2 &&
                (words.length == 1 || ActWhat._pieces.contains(words.last))
            ? ActWhat.quantity(words.first)
            : null;
        if (qty != null) follow = ActFollow(draft, qty: qty);
      case 'to':
        final def = draft.action.slots['to'];
        final words = text.split(' ');
        final raw =
            words.length > 1 && (words.first == 'в' || words.first == 'ячейку')
                ? words
                    .sublist(words.first == 'в' && words[1] == 'ячейку' ? 2 : 1)
                    .join(' ')
                : text;
        final cell = def == null ? '' : _cellValue(def, raw);
        if (cell.isNotEmpty) follow = ActFollow(draft, to: cell);
      case 'from':
        final def = draft.action.slots['from'];
        final words = text.split(' ');
        final raw =
            words.length > 1 && (words.first == 'из' || words.first == 'с')
                ? words
                    .sublist(words[1] == 'ячейки' && words.length > 2 ? 2 : 1)
                    .join(' ')
                : text;
        final cell = def == null ? '' : _cellValue(def, raw);
        if (cell.isNotEmpty) follow = ActFollow(draft, from: cell);
    }
    if (follow == null) return null;
    return ConnectorMatch(
      connectorId: slot.id,
      commandId: '${slot.id}.act.${draft.action.kind}',
      confidence: 1,
      payload: follow,
    );
  }

  static const List<String> _ordinals = <String>[
    'первый',
    'второй',
    'третий',
    'четвертый',
    'пятый',
    'шестой',
    'седьмой',
    'восьмой',
    'девятый',
  ];

  /// Номер варианта: «2», «второй», «2-й», артикул или номер прихода из
  /// списка. `null` — не вариант.
  static int? _optionIndex(String text, ActDraft draft) {
    final options = draft.options;
    final word = text
        .replaceFirst(RegExp(r'^(номер|вариант)\s+'), '')
        .replaceFirst(RegExp(r'-?(й|я|е|ой|ая)$'), '');
    final n = int.tryParse(word);
    if (n != null && n >= 1 && n <= options.length && word.length <= 2) {
      return n - 1;
    }
    for (var i = 0; i < _ordinals.length && i < options.length; i++) {
      if (text == _ordinals[i] || text.startsWith('${_ordinals[i]} ')) {
        return i;
      }
    }
    final field = draft.asked == 'entry' ? 'no' : 'sku';
    final hits = <int>[
      for (var i = 0; i < options.length; i++)
        if (askText(options[i][field]) == text) i,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  // -------------------------------------------------------------- run

  /// Действия разрешены для этого входа: роль включена, «Разрешить
  /// действия» — для логина подключения, вход под своим логином.
  bool get actionsActive =>
      _actionsLogin != null &&
      record.connected &&
      record.level == ConnectionLevel.staff &&
      record.login != null &&
      record.login!.toLowerCase() == _actionsLogin!.toLowerCase();

  AssistantResponse _actSay(
    AssistantSession session,
    String name,
    String intent,
    AssistantStatus status, {
    Map<String, String> values = const <String, String>{},
    ActionCard? card,
    String? prefix,
  }) =>
      session.reply(
        '${slot.id}.$name',
        values: values,
        intent: intent,
        status: status,
        card: card,
        prefix: prefix,
      );

  /// Ключи входа для действия или ответ-отказ без единого запроса.
  /// [card] — карточка перед записью: её логин обязан совпасть со входом.
  Future<(Map<String, String>?, AssistantResponse?)> _actGate(
    AssistantSession session,
    String intent, {
    ActionCard? card,
    bool settle = false,
  }) async {
    final keys = await readConnectionKeys(_secrets, slot, record);
    if (record.manifestUri == null || keys == null || !record.connected) {
      return (null, _notConnected(session, intent));
    }
    final sid = keys['sid'];
    if (record.level != ConnectionLevel.staff ||
        sid == null ||
        record.login == null) {
      return (
        null,
        _actSay(session, 'act.needLogin', intent, AssistantStatus.noAction),
      );
    }
    final login = record.login!;
    if (!settle) {
      final allowed = _actionsLogin;
      if (allowed == null) {
        return (
          null,
          _actSay(session, 'act.off', intent, AssistantStatus.noAction),
        );
      }
      if (allowed.toLowerCase() != login.toLowerCase()) {
        return (
          null,
          _actSay(
            session,
            'act.otherLogin',
            intent,
            AssistantStatus.noAction,
            values: <String, String>{'login': allowed, 'now': login},
          ),
        );
      }
    }
    if (card != null && card.login.toLowerCase() != login.toLowerCase()) {
      return (
        null,
        _actSay(
          session,
          'act.otherLogin',
          intent,
          AssistantStatus.noAction,
          values: <String, String>{'login': card.login, 'now': login},
        ),
      );
    }
    if (builtIn == null) {
      return (
        null,
        _actSay(session, 'act.unsupported', intent, AssistantStatus.noAction),
      );
    }
    return (keys, null);
  }

  /// Запрос действия: только заголовки ключей (не адрес), без
  /// автоповторов и переадресаций.
  Future<_ActHttp> _actPost(
    String action,
    Map<String, Object?> body,
    Map<String, String> credentials, {
    Duration timeout = ManifestConnector.requestTimeout,
  }) async {
    final d = builtIn!;
    final request = HttpRequestData(
      method: 'POST',
      uri: ManifestConnector.actionUri(d, record.manifestUri!, action),
      headers: ManifestConnector.headersFor(d, credentials),
      body: jsonEncode(body),
      timeout: timeout,
    );
    final now = DateTime.now();
    try {
      final response = await _transport.send(request);
      return _ActHttp(
        response.statusCode,
        ManifestConnector._jsonObject(response.body),
      );
    } on TimeoutException {
      _fail(ConnectionFailure.offline, now);
      return const _ActHttp.failed('timeout');
    } on Object {
      _fail(ConnectionFailure.offline, now);
      return const _ActHttp.failed('offline');
    }
  }

  /// Фраза действия: шлюзы, затем расчёт.
  Future<AssistantResponse> startAction(
    ActRequest request,
    AssistantSession session,
    String intent,
  ) async {
    final action = request.action;
    final ActDraft draft;
    if (action.kind == 'move') {
      final what = request.what ?? const ActWhat();
      draft = ActDraft(
        action: action,
        from: request.slots['from'] ?? '',
        to: request.slots['to'] ?? '',
        q: what.q,
        sku: what.sku,
        cls: what.cls,
        qty: what.qty,
      );
      if (draft.from == 'БЕЗ МЕСТА' || draft.to == 'БЕЗ МЕСТА') {
        return _actSay(
          session,
          'act.noPlace',
          intent,
          AssistantStatus.noAction,
        );
      }
      if (draft.to.isNotEmpty && _cellKey(draft.to) == _cellKey(draft.from)) {
        return _actSay(
          session,
          'act.sameCell',
          intent,
          AssistantStatus.noAction,
        );
      }
    } else {
      draft = ActDraft(
        action: action,
        no: (request.slots['no'] ?? '').toUpperCase(),
        set: request.marks,
      );
    }
    final (credentials, refused) = await _actGate(session, intent);
    if (refused != null) return refused;
    // Права входа известны и свежи (`ask_me`, ADR-031): без права — сразу
    // «нет права», без расчёта на сервере. Неизвестны или старше
    // [meFresh] — решает сервер: действия включают и права выдают на
    // складе уже после входа.
    final me = record.me;
    final meAt = me.at;
    final fresh =
        meAt != null && session.clock.now().difference(meAt) < meFresh;
    if (!fresh) return _check(draft, credentials!, session, intent);
    if (me.actions == false) {
      return _actSay(
        session,
        'act.serverOff',
        intent,
        AssistantStatus.noAction,
      );
    }
    if (action.right.isNotEmpty && me.has(action.right) == false) {
      return _actSay(
        session,
        'act.denied',
        intent,
        AssistantStatus.noAction,
        values: <String, String>{'right': rightTitle(action.right)},
      );
    }
    return _check(draft, credentials!, session, intent);
  }

  /// Сколько верить запомненным правам (`ask_me`) для отказа без запроса.
  static const Duration meFresh = Duration(minutes: 10);

  /// Право склада по-человечески: «перемещать товар».
  static String rightTitle(String right) => switch (right) {
        'post' => 'отмечать проведение',
        'moves' => 'перемещать товар',
        'price' => 'ставить цены',
        _ => right,
      };

  /// Ответ на вопрос черновика: уточнить и посчитать снова.
  Future<AssistantResponse> followAction(
    ActFollow follow,
    AssistantSession session,
    String intent,
  ) async {
    final draft = follow.draft;
    if (follow.option case final int index) {
      final option = draft.options[index];
      if (draft.isMove) {
        draft
          ..sku = _string(option['sku'])
          ..cls = _string(option['cls'])
          ..q = null;
        final cell = _string(option['cell']);
        if (cell.isNotEmpty) draft.from = cell;
      } else {
        draft
          ..id = _string(option['id'])
          ..no = _string(option['no']);
      }
    }
    if (follow.qty != null) draft.qty = follow.qty;
    if (follow.from case final String from) {
      if (from == 'БЕЗ МЕСТА') {
        return _actSay(
          session,
          'act.noPlace',
          intent,
          AssistantStatus.noAction,
        );
      }
      if (draft.to.isNotEmpty && _cellKey(draft.to) == _cellKey(from)) {
        return _actSay(
          session,
          'act.sameCell',
          intent,
          AssistantStatus.noAction,
        );
      }
      draft.from = from;
    }
    if (follow.to case final String to) {
      if (to == 'БЕЗ МЕСТА') {
        return _actSay(
          session,
          'act.noPlace',
          intent,
          AssistantStatus.noAction,
        );
      }
      draft.to = to;
    }
    final (credentials, refused) = await _actGate(session, intent);
    if (refused != null) return refused;
    return _check(draft, credentials!, session, intent);
  }

  /// Ответ «да»/«нет» на вопрос черновика: «нет» — отказ, «да» — тот же
  /// вопрос ещё раз (на «Сколько?» «да» не ответ).
  AssistantResponse answerDraft(
    ConfirmationAnswer answer,
    ActDraft draft,
    AssistantSession session,
    String intent,
  ) {
    if (!answer.confirmed || draft.questionId == null) {
      return _actSay(
        session,
        'act.declined',
        intent,
        AssistantStatus.completed,
      );
    }
    if (++draft.questions > ActDraft.maxQuestions) {
      return _actSay(session, 'act.tooMany', intent, AssistantStatus.noAction);
    }
    session.requestConfirmation(answer.pending);
    return session.reply(
      draft.questionId!,
      values: draft.questionValues,
      intent: intent,
      status: AssistantStatus.needsClarification,
    );
  }

  /// Расчёт `act_*_check`: вопрос, «уже отмечено», отказ или карточка.
  /// [prefix] — начало ответа (например «на складе изменилось»).
  Future<AssistantResponse> _check(
    ActDraft draft,
    Map<String, String> credentials,
    AssistantSession session,
    String intent, {
    String? prefix,
  }) async {
    if (draft.isMove && draft.from.isEmpty) {
      // Склад требует «откуда» (DepotDesk `act_move_check`): спросить
      // самим, не ходя на сервер.
      return _askFrom(draft, session, intent, prefix: prefix);
    }
    final vars = ManifestVars(session.clock.now());
    final reply = await _actPost(
      draft.action.check,
      draft.checkBody(vars),
      credentials,
    );
    if (reply.network != null) {
      return say(session, reply.network!, intent, AssistantStatus.failed);
    }
    final json = reply.json;
    if (!reply.ok || json == null) {
      return _refusal(
        reply.status,
        json,
        session,
        intent,
        check: true,
        prefix: prefix,
      );
    }
    _succeed(session.clock.now(), staff: true);
    return _checked(draft, json, session, intent, prefix: prefix);
  }

  /// Карточка устарела на складе (`stale`): новая — расчётом заново по
  /// черновику, если в черновике «все» (склад считает `fresh` по прежнему
  /// числу, а человек просил всё, что есть сейчас), иначе — из `fresh`.
  /// Черновика нет (после перезапуска) — «повторите команду».
  Future<AssistantResponse> _restale(
    ActionCard card,
    Object? fresh,
    Map<String, String> credentials,
    AssistantSession session,
    String intent,
  ) async {
    final next = _drafts[card];
    if (next == null) {
      card.state = ActionCardState.expired;
      return _actSay(
        session,
        'act.expired',
        intent,
        AssistantStatus.noAction,
        card: card,
      );
    }
    card.state = ActionCardState.replaced;
    next
      ..questions = 0
      ..asked = null;
    final prefix = session.say('${slot.id}.act.stale');
    if ((next.isMove && next.qty == 'all') || fresh is! Map<String, Object?>) {
      return _check(next, credentials, session, intent, prefix: prefix);
    }
    return _checked(next, fresh, session, intent, prefix: prefix);
  }

  AssistantResponse say(
    AssistantSession session,
    String name,
    String intent,
    AssistantStatus status, [
    Map<String, String> values = const <String, String>{},
  ]) =>
      session.reply(
        '${slot.id}.$name',
        values: values,
        intent: intent,
        status: status,
      );

  /// Ответ расчёта (или `fresh` из `stale`) — в вопрос или карточку.
  AssistantResponse _checked(
    ActDraft draft,
    Map<String, Object?> json,
    AssistantSession session,
    String intent, {
    String? prefix,
  }) {
    if (json[builtIn!.codeField] is String && json['ok'] != true) {
      // `fresh` бывает и отказом: «остатка нет», «приход открыт».
      return _refusal(409, json, session, intent, check: true, prefix: prefix);
    }
    if (json['ok'] != true) {
      return _actSay(
        session,
        'act.mismatch',
        intent,
        AssistantStatus.failed,
        prefix: prefix,
      );
    }
    if (json['already'] == true && !draft.isMove) {
      final entry = _map(json['entry']);
      return _actSay(
        session,
        'act.already',
        intent,
        AssistantStatus.completed,
        values: <String, String>{
          'no': _clean(entry['no'], fallback: draft.no),
          'stage': _stage(json['stage']),
        },
        prefix: prefix,
      );
    }
    if (json['ready'] == true) {
      final card = draft.isMove
          ? _moveCard(draft, json, session)
          : _postCard(draft, json, session);
      if (card == null) {
        return _actSay(
          session,
          'act.mismatch',
          intent,
          AssistantStatus.failed,
          prefix: prefix,
        );
      }
      _drafts[card] = draft;
      session.requestConfirmation(
        PendingConfirmation(
          connectorId: slot.id,
          commandId: intent,
          itemId: card.rid,
          payload: card,
          onDropped: () {
            if (card.isPending) card.state = ActionCardState.expired;
          },
        ),
      );
      final commit = card.commit!;
      return _actSay(
        session,
        draft.isMove ? 'act.ask.move' : 'act.ask.post',
        intent,
        AssistantStatus.needsClarification,
        values: draft.isMove
            ? <String, String>{
                'qty': '${commit['qty']}',
                'from': '${commit['from']}',
                'to': '${commit['to']}',
              }
            : <String, String>{
                'marks': _marks(commit['set']),
                'no': '${commit['no']}',
              },
        card: card,
        prefix: prefix,
      );
    }
    return _question(draft, json, session, intent, prefix: prefix);
  }

  /// Вопрос по ходу: какой вариант, сколько, куда, какой приход.
  AssistantResponse _question(
    ActDraft draft,
    Map<String, Object?> json,
    AssistantSession session,
    String intent, {
    String? prefix,
  }) {
    final ask = json['ask'];
    if (++draft.questions > ActDraft.maxQuestions) {
      return _actSay(
        session,
        'act.tooMany',
        intent,
        AssistantStatus.noAction,
        prefix: prefix,
      );
    }
    final String id;
    final Map<String, String> values;
    switch (ask) {
      case 'row' when draft.isMove:
        final options = _options(json['options']);
        if (options.isEmpty) continue mismatch;
        draft.options = options;
        id = 'act.ask.row';
        values = <String, String>{
          'place': draft.from.isEmpty ? 'на складе' : 'в ${draft.from}',
          'list': _list(options, (Map<String, Object?> o) {
            final cls = _string(o['cls']);
            return <String>[
              if (draft.from.isEmpty) _clean(o['cell']),
              _clean(o['sku']),
              _clean(o['name'], max: 40),
              if (cls.isNotEmpty && cls != 'NONE') _clean(o['clsLabel']),
              '${_int(o['qty']) ?? 0} шт.',
            ].where((String s) => s.isNotEmpty).join(' · ');
          }),
        };
      case 'qty' when draft.isMove:
        final row = _map(json['row']);
        final cell = _clean(row['cell'], fallback: draft.from);
        if (draft.from.isEmpty && cell.isNotEmpty) draft.from = cell;
        draft
          ..sku = _string(row['sku'], fallback: draft.sku ?? '')
          ..cls = _string(row['cls'], fallback: draft.cls ?? '')
          ..q = null;
        id = 'act.ask.qty';
        values = <String, String>{
          'from': cell,
          'have': '${_int(json['have']) ?? 0}',
        };
      case 'to' when draft.isMove:
        final row = _map(json['row']);
        final cell = _clean(row['cell'], fallback: draft.from);
        if (draft.from.isEmpty && cell.isNotEmpty) draft.from = cell;
        draft
          ..sku = _string(row['sku'], fallback: draft.sku ?? '')
          ..cls = _string(row['cls'], fallback: draft.cls ?? '')
          ..q = null;
        final qty = _int(json['qty']);
        if (qty != null) draft.qty = qty;
        id = 'act.ask.to';
        values = <String, String>{'qty': '${qty ?? draft.qty ?? ''}'};
      case 'entry' when !draft.isMove:
        final options = _options(json['options']);
        if (options.isEmpty) continue mismatch;
        draft.options = options;
        id = 'act.ask.entry';
        values = <String, String>{
          'no': _clean(json['no'], fallback: draft.no),
          'list': _list(
            options,
            (Map<String, Object?> o) => <String>[
              _clean(o['no']),
              _clean(o['kindLabel']),
              _day(o['day']),
              _clean(o['buyer'], max: 30),
            ].where((String s) => s.isNotEmpty).join(' · '),
          ),
        };
      mismatch:
      default:
        return _actSay(
          session,
          'act.mismatch',
          intent,
          AssistantStatus.failed,
          prefix: prefix,
        );
    }
    draft
      ..asked = ask as String
      ..questionId = '${slot.id}.$id'
      ..questionValues = values;
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: slot.id,
        commandId: intent,
        payload: draft,
      ),
    );
    return _actSay(
      session,
      id,
      intent,
      AssistantStatus.needsClarification,
      values: values,
      prefix: prefix,
    );
  }

  /// «Из какой ячейки переместить?» — вопрос без сервера.
  AssistantResponse _askFrom(
    ActDraft draft,
    AssistantSession session,
    String intent, {
    String? prefix,
  }) {
    if (++draft.questions > ActDraft.maxQuestions) {
      return _actSay(
        session,
        'act.tooMany',
        intent,
        AssistantStatus.noAction,
        prefix: prefix,
      );
    }
    draft
      ..asked = 'from'
      ..questionId = '${slot.id}.act.ask.from'
      ..questionValues = const <String, String>{};
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: slot.id,
        commandId: intent,
        payload: draft,
      ),
    );
    return _actSay(
      session,
      'act.ask.from',
      intent,
      AssistantStatus.needsClarification,
      prefix: prefix,
    );
  }

  static String _list(
    List<Map<String, Object?>> options,
    String Function(Map<String, Object?>) line,
  ) =>
      <String>[
        for (var i = 0; i < options.length; i++)
          '${i + 1}) ${line(options[i])}',
      ].join('; ');

  static List<Map<String, Object?>> _options(Object? raw) =>
      <Map<String, Object?>>[
        if (raw is List)
          for (final item in raw.take(9))
            if (item is Map<String, Object?>) item,
      ];

  /// Карточка перемещения. Значения, которые сказал человек (откуда,
  /// куда, сколько, класс), сверяются с `commit` сервера: не сошлось —
  /// `null` («склад ответил не про то»). В карточке «откуда», «куда» и
  /// «сколько» — из `commit`.
  ActionCard? _moveCard(
    ActDraft draft,
    Map<String, Object?> json,
    AssistantSession session,
  ) {
    final card = _map(json['card']);
    final commit = _map(json['commit']);
    final from = commit['from'];
    final to = commit['to'];
    final sku = commit['sku'];
    final cls = commit['cls'];
    final qty = commit['qty'];
    final exp = json['exp'];
    final stamp = json['stamp'];
    if (from is! String ||
        to is! String ||
        sku is! String ||
        cls is! String ||
        qty is! int ||
        qty < 1 ||
        qty > 9999 ||
        exp is! int ||
        stamp is! String ||
        !_stamp.hasMatch(stamp)) {
      return null;
    }
    final fromCard = _map(card['from']);
    final toCard = _map(card['to']);
    final have = _int(fromCard['now']);
    if (draft.from.isNotEmpty && _cellKey(from) != _cellKey(draft.from)) {
      return null;
    }
    if (to.isEmpty ||
        _cellKey(to) != _cellKey(draft.to) ||
        _cellKey(from) == _cellKey(to)) {
      return null;
    }
    if (draft.qty is int && qty != draft.qty) return null;
    if (draft.qty == 'all' && qty != have) return null;
    if (draft.cls != null && draft.cls!.isNotEmpty && cls != draft.cls) {
      return null;
    }
    if (fromCard['cell'] != from ||
        toCard['cell'] != to ||
        _int(card['qty']) != qty) {
      return null;
    }
    final who = _map(card['who']);
    final login = _clean(who['login']);
    if (login.toLowerCase() != (record.login ?? '').toLowerCase()) return null;
    final name = _clean(who['name'], fallback: login);
    final warn = _strings(card['warn']);
    final clsLabel =
        cls.isEmpty || cls == 'NONE' ? '' : _clean(card['clsLabel']);
    return ActionCard(
      rid: _newRid(),
      connectorId: slot.id,
      kind: ActionKind.move,
      login: login,
      name: name,
      deadline: _deadline(exp, session),
      lines: <ActionCardLine>[
        ActionCardLine('what', _clean(card['name'], max: 80)),
        // Артикул и класс — отдельной строкой: на узком экране длинное
        // название не прячет класс.
        ActionCardLine(
          'sku',
          <String>[_clean(sku), clsLabel]
              .where((String s) => s.isNotEmpty)
              .join(' · '),
        ),
        ActionCardLine('qty', '$qty шт.'),
        ActionCardLine(
          'from',
          '${_clean(from)} — было ${have ?? '?'}, станет '
              '${_int(fromCard['after']) ?? '?'}',
        ),
        ActionCardLine(
          'to',
          '${_clean(to)} — было ${_int(toCard['now']) ?? '?'}, станет '
              '${_int(toCard['after']) ?? '?'}',
          note: warn.contains('to_empty') ? 'to_empty' : '',
        ),
        ActionCardLine('who', ActionCard.cardText('$name ($login)')),
      ],
      warn: warn,
      commit: <String, Object?>{
        'from': from,
        'to': to,
        'sku': sku,
        'cls': cls,
        'qty': qty,
      },
      stamp: stamp,
      exp: exp,
    );
  }

  /// Карточка проведения: приход и отметки из ответа; `commit.set` —
  /// только из того, что просили; приход — тот, что выбран в вопросе.
  ActionCard? _postCard(
    ActDraft draft,
    Map<String, Object?> json,
    AssistantSession session,
  ) {
    final card = _map(json['card']);
    final commit = _map(json['commit']);
    final id = commit['id'];
    final set = commit['set'];
    final exp = json['exp'];
    final stamp = json['stamp'];
    if (id is! String ||
        id.isEmpty ||
        set is! List ||
        set.isEmpty ||
        set.any((Object? s) => s is! String || !draft.set.contains(s)) ||
        set.toSet().length != set.length ||
        exp is! int ||
        stamp is! String ||
        !_stamp.hasMatch(stamp)) {
      return null;
    }
    if (draft.id != null && id != draft.id) return null;
    if (card['id'] != id) return null;
    final who = _map(card['who']);
    final login = _clean(who['login']);
    if (login.toLowerCase() != (record.login ?? '').toLowerCase()) return null;
    final name = _clean(who['name'], fallback: login);
    final now = _map(card['now']);
    final after = _map(card['after']);
    String mark(String field) {
      final was = now[field] == true;
      final will = was || set.contains(field);
      if (was) return 'отмечено — без изменений';
      return will ? 'нет → отмечено' : 'нет — без изменений';
    }

    final warn = _strings(card['warn']);
    return ActionCard(
      rid: _newRid(),
      connectorId: slot.id,
      kind: ActionKind.post,
      login: login,
      name: name,
      deadline: _deadline(exp, session),
      lines: <ActionCardLine>[
        ActionCardLine(
          'entry',
          ActionCard.cardText(
            <String>[
              _clean(card['no'], fallback: draft.no),
              _clean(card['kindLabel']),
              _day(card['day']),
              _clean(card['buyer'], max: 40),
            ].where((String s) => s.isNotEmpty).join(' · '),
          ),
        ),
        ActionCardLine(
          'content',
          '${_int(card['positions']) ?? 0} поз., ${_int(card['qty']) ?? 0} шт.',
        ),
        ActionCardLine('sv', mark('sv')),
        ActionCardLine('odin_c', mark('odin_c')),
        ActionCardLine(
          'stage',
          'приход станет «${_capital(_stage(card['stage']))}»',
        ),
        ActionCardLine('who', ActionCard.cardText('$name ($login)')),
      ],
      warn: warn,
      commit: <String, Object?>{
        'id': id,
        'set': List<String>.unmodifiable(set.cast<String>()),
        'no': _clean(card['no'], fallback: draft.no),
        // Совпадает ли состояние после записи с тем, что в карточке.
        'after': '${after['sv'] == true}/${after['odin_c'] == true}',
      },
      stamp: stamp,
      exp: exp,
    );
  }

  /// Срок карточки по часам устройства: столько, сколько склад дал
  /// (`exp`), но не больше 5 минут; часы устройства и склада могут
  /// расходиться — тогда 5 минут, а настоящий срок проверит склад.
  DateTime _deadline(int exp, AssistantSession session) {
    final now = session.clock.now();
    var ttl = exp - now.millisecondsSinceEpoch ~/ 1000;
    if (ttl <= 0 || ttl > 300) ttl = 300;
    return now.add(Duration(seconds: ttl));
  }

  String _newRid() {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final random = _random;
    return String.fromCharCodes(<int>[
      for (var i = 0; i < 16; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }

  /// Ответ на карточку: «Подтвердить» — запись, «нет» — отказ, «да»
  /// текстом — просьба нажать кнопку, карточка ждёт дальше.
  Future<AssistantResponse> answerCard(
    ConfirmationAnswer answer,
    ActionCard card,
    AssistantSession session,
    String intent,
  ) async {
    if (!answer.confirmed) {
      if (card.isPending) card.state = ActionCardState.cancelled;
      return _actSay(
        session,
        'act.declined',
        intent,
        AssistantStatus.completed,
        card: card,
      );
    }
    if (!answer.viaButton) {
      // Текстовое согласие запись не вызывает (ADR-013): набор согласий
      // широк, а «отметь» — ещё и глагол команды.
      if (card.isPending) session.requestConfirmation(answer.pending);
      return _actSay(
        session,
        card.isPending ? 'act.pressButton' : 'act.expired',
        intent,
        AssistantStatus.needsClarification,
        card: card,
      );
    }
    final now = session.clock.now();
    if (card.expireIfDue(now) || !card.canSend(now)) {
      if (card.isPending) card.state = ActionCardState.expired;
      return _actSay(
        session,
        'act.expired',
        intent,
        AssistantStatus.noAction,
        card: card,
      );
    }
    final (credentials, refused) = await _actGate(session, intent, card: card);
    if (refused != null) {
      card
        ..state = ActionCardState.failed
        ..result = refused.message;
      return AssistantResponse(
        message: refused.message,
        intent: refused.intent,
        status: refused.status,
        replyId: refused.replyId,
        values: refused.values,
        card: card,
      );
    }
    return _write(card, credentials!, session, intent);
  }

  /// Запись: ровно один POST, тело — из `commit` карточки с типами.
  Future<AssistantResponse> _write(
    ActionCard card,
    Map<String, String> credentials,
    AssistantSession session,
    String intent,
  ) async {
    final commit = card.commit!;
    final draft = _drafts[card];
    final action = draft?.action ??
        builtIn!.actions.firstWhere(
          (ManifestAction a) => a.kind == card.kind.name,
        );
    final body = card.kind == ActionKind.move
        ? <String, Object?>{
            'v': 1,
            'rid': card.rid,
            'from': commit['from'],
            'to': commit['to'],
            'sku': commit['sku'],
            'cls': commit['cls'],
            'qty': commit['qty'],
            'exp': card.exp,
            'stamp': card.stamp,
          }
        : <String, Object?>{
            'v': 1,
            'rid': card.rid,
            'id': commit['id'],
            'set': commit['set'],
            'exp': card.exp,
            'stamp': card.stamp,
            'tz': ManifestVars(session.clock.now()).tz,
          };
    card.state = ActionCardState.sending;
    // Сначала — в историю чата (sending → после перезапуска unknown с
    // «Проверить»), потом запрос. Сбой сохранения запись не держит.
    final persist = card.onSending;
    card.onSending = null;
    if (persist != null) {
      try {
        await persist().timeout(ManifestConnector.persistLimit);
      } on Object {
        // История не записалась — запись всё равно одна, итог в ответе.
      }
    }
    final reply = await _actPost(
      action.write,
      body,
      credentials,
      timeout: ManifestConnector.writeTimeout,
    );
    final json = reply.json;
    final code = json?[builtIn!.codeField];
    if (reply.network != null ||
        (reply.status >= 500 && !_definite.contains(code))) {
      // Не знаем, дошло ли: обрыв, 5xx без тела, `unknown` («итог
      // неизвестен») или сбой без кода. Одна проверка через settleDelay,
      // запись не повторяется никогда.
      card.state = ActionCardState.unknown;
      await Future<void>.delayed(settleDelay);
      return _settle(card, credentials, session, intent);
    }
    if (reply.ok && json != null && json['done'] == true) {
      _succeed(session.clock.now(), staff: true);
      return _applied(card, json, session, intent);
    }
    if (reply.ok) {
      card.state = ActionCardState.unknown;
      return _settle(card, credentials, session, intent);
    }
    switch (code) {
      case 'stale':
        return _restale(card, json?['fresh'], credentials, session, intent);
      case 'expired':
        card.state = ActionCardState.expired;
        return _actSay(
          session,
          'act.expired',
          intent,
          AssistantStatus.noAction,
          card: card,
        );
      case 'void' || 'rid_reused' || 'in_progress':
        card.state = ActionCardState.unknown;
        return _settle(card, credentials, session, intent);
    }
    final refusal = _refusal(reply.status, json, session, intent, write: true);
    card
      ..state = ActionCardState.failed
      ..result = refusal.message;
    return AssistantResponse(
      message: refusal.message,
      intent: refusal.intent,
      status: AssistantStatus.failed,
      replyId: refusal.replyId,
      values: refusal.values,
      card: card,
    );
  }

  /// Склад выполнил: итог в карточку и ответ.
  AssistantResponse _applied(
    ActionCard card,
    Map<String, Object?> json,
    AssistantSession session,
    String intent,
  ) {
    card.state = ActionCardState.applied;
    final commit = card.commit;
    if (card.kind == ActionKind.move) {
      final from = _map(json['from']);
      final left = _int(from['left']);
      final doc = _clean(json['doc']);
      card.result = doc;
      if (left == null || commit == null) {
        return _actSay(
          session,
          'act.settled',
          intent,
          AssistantStatus.completed,
          values: <String, String>{'result': doc.isEmpty ? 'перемещение' : doc},
          card: card,
        );
      }
      return _actSay(
        session,
        'act.moved',
        intent,
        AssistantStatus.completed,
        values: <String, String>{
          'doc': doc,
          'qty': '${commit['qty']}',
          'from':
              _clean(_map(json['from'])['cell'], fallback: '${commit['from']}'),
          'to': _clean(_map(json['to'])['cell'], fallback: '${commit['to']}'),
          'left': '$left',
        },
        card: card,
      );
    }
    final no = _clean(json['no'], fallback: '${commit?['no'] ?? ''}');
    final stage = _stage(json['stage']);
    final changed = json['changed'];
    card.result = 'Теперь: ${_stage(json['stage'])}';
    if (json['stage'] == null || no.isEmpty) {
      return _actSay(
        session,
        'act.settled',
        intent,
        AssistantStatus.completed,
        values: <String, String>{'result': no.isEmpty ? 'проведение' : no},
        card: card,
      );
    }
    if (changed is List && changed.isEmpty) {
      return _actSay(
        session,
        'act.already',
        intent,
        AssistantStatus.completed,
        values: <String, String>{'no': no, 'stage': stage},
        card: card,
      );
    }
    return _actSay(
      session,
      'act.posted',
      intent,
      AssistantStatus.completed,
      values: <String, String>{
        'marks': _marks(changed is List ? changed : commit?['set']),
        'no': no,
        'stage': stage,
      },
      card: card,
    );
  }

  /// «Проверить» после перезапуска или обрыва: шлюзы без переключателя
  /// (проверка ничего не пишет), затем `act_settle`.
  Future<AssistantResponse> settleCard(
    ActionCard card,
    AssistantSession session,
    String intent,
  ) async {
    final (credentials, refused) = await _actGate(
      session,
      intent,
      card: card,
      settle: true,
    );
    if (refused != null) {
      return AssistantResponse(
        message: refused.message,
        intent: refused.intent,
        status: refused.status,
        replyId: refused.replyId,
        values: refused.values,
        card: card,
      );
    }
    return _settle(card, credentials!, session, intent);
  }

  /// Чем кончилась запись с [ActionCard.rid].
  Future<AssistantResponse> _settle(
    ActionCard card,
    Map<String, String> credentials,
    AssistantSession session,
    String intent,
  ) async {
    final reply = await _actPost(
      ManifestDescription.settleAction,
      <String, Object?>{'v': 1, 'rid': card.rid},
      credentials,
    );
    final json = reply.json;
    AssistantResponse unknown(String name) {
      card.state = ActionCardState.unknown;
      return _actSay(
        session,
        name,
        intent,
        AssistantStatus.failed,
        card: card,
      );
    }

    if (reply.network != null || !reply.ok || json == null) {
      return unknown('act.unknown');
    }
    switch (json['state']) {
      case 'done':
        final result = _map(json['result']);
        return _applied(
          card,
          <String, Object?>{
            for (final e in result.entries) '${e.key}': e.value,
          },
          session,
          intent,
        );
      case 'void':
        card
          ..state = ActionCardState.failed
          ..result = 'не выполнено';
        return _actSay(
          session,
          'act.voided',
          intent,
          AssistantStatus.failed,
          card: card,
        );
      case 'failed':
        // Склад отказал, а ответ потерялся: тот же разбор отказа, что у
        // записи, — по коду в запись каталога, не код как есть.
        final d = builtIn!;
        final refusal = <String, Object?>{
          for (final e in _map(json['refusal']).entries) '${e.key}': e.value,
        };
        refusal[d.codeField] ??= json['code'];
        refusal[d.errorField] ??= json['error'];
        switch (refusal[d.codeField]) {
          case 'stale':
            return _restale(card, null, credentials, session, intent);
          case 'expired':
            card.state = ActionCardState.expired;
            return _actSay(
              session,
              'act.expired',
              intent,
              AssistantStatus.noAction,
              card: card,
            );
        }
        final out = _refusal(
          _int(json['http']) ?? 409,
          refusal,
          session,
          intent,
          write: true,
        );
        card
          ..state = ActionCardState.failed
          ..result = out.message;
        return AssistantResponse(
          message: out.message,
          intent: out.intent,
          status: AssistantStatus.failed,
          replyId: out.replyId,
          values: out.values,
          card: card,
        );
      case 'pending':
        return unknown('act.pending');
    }
    return unknown('act.unknown');
  }

  /// Отказ склада по коду (`api.errors.code`) — в запись каталога. Склад
  /// без действий отвечает на расчёт 400 без кода — «нужно обновление».
  AssistantResponse _refusal(
    int status,
    Map<String, Object?>? json,
    AssistantSession session,
    String intent, {
    bool check = false,
    bool write = false,
    String? prefix,
  }) {
    final d = builtIn!;
    final code = json?[d.codeField];
    final error = ManifestConnector._errorText(json?[d.errorField]);
    final now = session.clock.now();
    AssistantResponse out(
      String name,
      AssistantStatus status, [
      Map<String, String> values = const <String, String>{},
    ]) =>
        _actSay(
          session,
          name,
          intent,
          write && status != AssistantStatus.failed
              ? AssistantStatus.failed
              : status,
          values: values,
          prefix: prefix,
        );
    if (status == 401) {
      // Без пароля склада (tokenless) 401 — не принят ключ помощника.
      if (record.tokenless) {
        _fail(ConnectionFailure.expired, now);
        return out('auth.expired', AssistantStatus.failed);
      }
      _fail(ConnectionFailure.token, now);
      return out('auth.token', AssistantStatus.failed);
    }
    if (code is! String) {
      if (json == null && status >= 500) {
        _fail(ConnectionFailure.server, now);
        return out('serverError', AssistantStatus.failed);
      }
      if (check && (status == 400 || status == 404)) {
        return out('act.unsupported', AssistantStatus.noAction);
      }
      if (status == 403 && json?[d.needField] == 'login') {
        _fail(ConnectionFailure.expired, now);
        return out('auth.expired', AssistantStatus.failed);
      }
      if (status == 403 && json?[d.needField] == 'role') {
        return out('auth.role', AssistantStatus.noAction);
      }
      if (status == 429) return out('busy', AssistantStatus.noAction);
      return out('act.failed', AssistantStatus.failed, <String, String>{
        'error': error.isEmpty ? 'ошибка $status' : error,
      });
    }
    String field(String name) => _clean(json?[name]);
    switch (code) {
      case 'off':
        return out('act.serverOff', AssistantStatus.noAction);
      case 'login':
        _fail(ConnectionFailure.expired, now);
        return out('auth.expired', AssistantStatus.failed);
      case 'role':
        return out('auth.role', AssistantStatus.noAction);
      case 'no_right' || 'rights_unknown':
        return out('act.denied', AssistantStatus.noAction, <String, String>{
          'right': switch (json?['right']) {
            final String right when right == 'post' || right == 'moves' =>
              rightTitle(right),
            final Object? other => _clean(other, fallback: 'это действие'),
          },
        });
      case 'not_found':
        return out('act.notFound', AssistantStatus.noAction, <String, String>{
          'no': field('no'),
        });
      case 'not_in_cell':
        final from = field('from');
        return out('act.notInCell', AssistantStatus.noAction, <String, String>{
          'place': from.isEmpty ? 'на складе' : 'в $from',
        });
      case 'draft':
        return out('act.draft', AssistantStatus.noAction, <String, String>{
          'no': field('no'),
        });
      case 'locked':
        return json?['own'] == true
            ? out('act.lockedOwn', AssistantStatus.noAction, <String, String>{
                'no': field('no'),
              })
            : out('act.locked', AssistantStatus.noAction, <String, String>{
                'no': field('no'),
                'name': _clean(json?['name'], fallback: field('by')),
              });
      case 'short':
        return out('act.short', AssistantStatus.noAction, <String, String>{
          'from': field('from'),
          'have': '${_int(json?['have']) ?? 0}',
        });
      case 'no_cell':
        return out('act.noCell', AssistantStatus.noAction, <String, String>{
          'to': field('to'),
        });
      case 'cell_group':
        return out('act.cellGroup', AssistantStatus.noAction, <String, String>{
          'to': field('to'),
        });
      case 'same_cell':
        return out('act.sameCell', AssistantStatus.noAction);
      case 'only_there':
        return out('act.onlyThere', AssistantStatus.noAction, <String, String>{
          'to': field('to'),
        });
      case 'qty_limit':
        return out('act.qtyLimit', AssistantStatus.noAction, <String, String>{
          'max': '${_int(json?['max']) ?? 9999}',
          'from': field('from'),
          'have': '${_int(json?['have']) ?? 0}',
        });
      case 'clock_order':
        return out('act.clock', AssistantStatus.noAction);
      case 'expired':
        return out('act.expired', AssistantStatus.noAction);
      case 'busy':
        return out('busy', AssistantStatus.noAction);
    }
    return out('act.failed', AssistantStatus.failed, <String, String>{
      'error': error.isEmpty ? code : error,
    });
  }

  // ---------------------------------------------------------- значения

  static Map<Object?, Object?> _map(Object? value) =>
      value is Map ? value : const <Object?, Object?>{};

  static List<String> _strings(Object? value) => <String>[
        if (value is List)
          for (final item in value)
            if (item is String) item,
      ];

  static String _string(Object? value, {String fallback = ''}) =>
      value is String ? value : fallback;

  static int? _int(Object? value) => value is int
      ? value
      : value is double && value == value.roundToDouble()
          ? value.toInt()
          : null;

  /// Строка сервера для ответа и карточки: без управляющих знаков, в одну
  /// строку; фигурные скобки значения не раскрываются (подстановка
  /// вставляет значение как есть).
  static String _clean(Object? value, {String fallback = '', int max = 60}) {
    final text = value is String
        ? ActionCard.cardText(value, max: max)
        : value is num
            ? '$value'
            : '';
    return text.isEmpty ? fallback : text;
  }

  static String _marks(Object? set) {
    final list = set is List ? set : const <Object?>[];
    final names = <String>[
      if (list.contains('sv')) 'SV',
      if (list.contains('odin_c')) '1С',
    ];
    return names.isEmpty ? 'отметку' : names.join(' и ');
  }

  static String _stage(Object? stage) => switch (stage) {
        'done' => 'проведён',
        'half' => 'проведён частично',
        _ => 'не проведён',
      };

  static String _capital(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

  /// `2026-11-05` → «05.11».
  static String _day(Object? value) {
    if (value is! String) return '';
    final m = RegExp(r'^\d{4}-(\d{2})-(\d{2})').firstMatch(value);
    return m == null ? '' : '${m[2]}.${m[1]}';
  }
}
