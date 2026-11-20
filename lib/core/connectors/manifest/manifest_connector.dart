import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../extensions/role.dart';
import '../../models/action_card.dart';
import '../../models/warehouse_card.dart';
import '../connector.dart';
import '../http_transport.dart';
import '../number_words.dart';
import '../secret_store.dart';
import '../social_prefix.dart';
import '../verb_forms.dart';
import 'connection.dart';
import 'manifest_format.dart';
import 'manifest_matcher.dart';
import 'manifest_query.dart';
import 'manifest_text.dart';
import 'manifest_view.dart';

part 'manifest_actions.dart';

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

  /// `say`, `fallback`, `help` (своя фраза справки «Tridot»), `ask`
  /// — начало фразы с полем без самого поля («где лежит»): спросить, что
  /// искать, или `total` — вопрос обо всём складе («сколько позиций на
  /// складе»): склад этого не считает, ответ — без запроса.
  final String how;

  /// Фраза начиналась с обращения к приложению: «на складе …».
  final bool aliased;
}

/// Коннектор к любому приложению с описанием `assistant/1` (ADR-011):
/// склад halowarekeep, потом expeora. Фразы, запрос и ответ — из
/// описания; голос, защиты маршрутизации и тексты ошибок — «Tridot».
///
/// Команды — только чтение: действия из `api.only`, других обычный путь
/// не зовёт. Действия с записью (перемещение, отметка проведения,
/// ADR-013) — только из встроенной копии описания ([builtIn]), только при
/// «Разрешить действия» для логина входа и только по кнопке
/// «Подтвердить» на карточке (`manifest_actions.dart`).
/// Секреты (пароль приложения, личный ключ) — только в [SecretStore];
/// в ответах, логах и настройках их нет.
final class ManifestConnector
    implements
        Connector,
        ConnectorHealth,
        RoleHints,
        RoleActions,
        ConfirmationFollowUp {
  ManifestConnector({
    required this.slot,
    required HttpTransport transport,
    required SecretStore secrets,
    ManifestDescription? description,
    ConnectionRecord? record,
    ManifestDescription? builtIn,
    Random? random,
  })  : _transport = transport,
        _secrets = secrets,
        _random = random ?? Random.secure(),
        record = record ?? ConnectionRecord(appId: slot.fileKey) {
    if (description != null) load(description);
    this.builtIn = builtIn;
  }

  final ConnectionSlot slot;
  final HttpTransport _transport;
  final SecretStore _secrets;

  ManifestDescription? _description;
  ManifestMatcher? _matcher;

  /// Источник одноразовых ключей записи (`rid`).
  final Random _random;

  ManifestDescription? _builtIn;
  List<_ActRule> _actRules = const <_ActRule>[];

  /// Встроенная копия описания: только из неё — действия с записью
  /// (ADR-013), что бы ни было в работе для чтения.
  ManifestDescription? get builtIn => _builtIn;

  set builtIn(ManifestDescription? value) {
    _builtIn = value != null && value.builtIn ? value : null;
    _actRules = _Actions.compile(_builtIn);
  }

  /// Логин, для которого роль разрешила действия; `null` — не разрешены.
  String? _actionsLogin;

  @override
  void applyRoleActions(String? login) {
    _actionsLogin = login;
  }

  /// Сколько ждать перед проверкой `act_settle`, если ответ на запись не
  /// пришёл.
  Duration settleDelay = const Duration(seconds: 3);

  /// Сколько ждать ответа на запись.
  static const Duration writeTimeout = Duration(seconds: 30);

  /// Сколько ждать сохранения карточки перед записью
  /// ([ActionCard.onSending]); дольше — запись уходит без него.
  static const Duration persistLimit = Duration(seconds: 2);

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
        // Запись — только пока разрешены действия для этого входа.
        access: actionsActive
            ? ConnectorAccess.readWrite
            : ConnectorAccess.readOnly,
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

  /// Слова задач и чата «Tridot»: «сколько у меня задач» — не товар.
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
  static const Set<String> _notGoods = <String>{
    'смысл',
    'толк',
    'толку',
    'лет',
    'годиков',
  };

  /// Часы телефона: «сколько осталось на таймере» — не склад.
  static const List<String> _deviceStems = <String>[
    'таймер',
    'будильник',
    'секундомер',
  ];

  /// Надобность: «сколько стульев нужно для гостей», «сколько надо краски».
  static const Set<String> _needWords = <String>{
    'нужно',
    'надо',
    'нужен',
    'нужна',
    'нужны',
    'понадобится',
    'понадобятся',
    'потребуется',
    'потребуются',
    'хватит',
  };

  /// «Сколько можно …», «сколько нельзя …» — риторика, а не остаток.
  static const Set<String> _modalWords = <String>{'можно', 'нельзя'};

  /// Меры погоды и тела: «сколько градусов за окном», «сколько калорий в
  /// яблоке» — не позиции склада.
  static const List<String> _measureStems = <String>[
    'градус',
    'калори',
    'килокалори',
  ];

  /// Слова между числами примера: «48 на 25», «12 и 7», «3 с половиной на 2».
  static const Set<String> _arithmeticWords = <String>{
    'на',
    'и',
    'с',
    'половиной',
    'х',
    'x',
    'по',
    'это',
  };

  /// В поле только числа (не меньше двух, ни одного кода артикула) и слова
  /// действия между ними: «48 на 25» — пример, а не товар.
  ///
  /// Числа словами — тоже числа ([NumberWords]): «сто сорок четыре
  /// поделённое на шестнадцать» — пример, «куб семёрки» — тоже.
  static bool _arithmetic(List<String> words) {
    final joined = words.join(' ');
    final spelled = NumberWords.find(joined);
    var numbers = spelled.length;
    var position = 0;
    for (final word in words) {
      final start = position;
      position += word.length + 1;
      if (spelled.any(
        (NumberWordMatch m) => start >= m.start && start < m.end,
      )) {
        continue;
      }
      if (RegExp(r'^\d{1,4}(?:[.,]\d+)?$').hasMatch(word) ||
          NumberWords.nouns.containsKey(word)) {
        numbers++;
      } else if (!_arithmeticWords.contains(word) &&
          !_calcWords.contains(word)) {
        return false;
      }
    }
    // «Куб семёрки», «квадрат пяти» — одно число со словом действия.
    final operated = words.any(_calcWords.contains);
    return numbers >= 2 || (numbers == 1 && operated);
  }

  /// Единица после «в»: «сколько сантиметров в дюйме», «сколько секунд
  /// в сутках» — перевод единиц, а не товар.
  static const Set<String> _unitsIn = <String>{
    'дюйме',
    'футе',
    'миле',
    'ярде',
    'метре',
    'сантиметре',
    'километре',
    'литре',
    'галлоне',
    'килограмме',
    'кило',
    'грамме',
    'фунте',
    'унции',
    'тонне',
    'часе',
    'минуте',
    'сутках',
    'неделе',
    'месяце',
    'году',
    'веке',
  };

  static const List<String> _currencyStems = <String>[
    'доллар',
    'евро',
    'рубл',
    'бакс',
    'биткоин',
    'юан',
    'курс',
  ];

  static const Set<String> _calcWords = <String>{
    'будет',
    'умножить',
    'умножь',
    'умноженное',
    'помноженное',
    'разделить',
    'раздели',
    'подели',
    'поделить',
    'деленное',
    'разделенное',
    'поделенное',
    'прибавить',
    'отнять',
    'вычесть',
    'куб',
    'квадрат',
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
    // Вопрос о состоянии: «склад работает?», «склад, ты жив?».
    'работает',
    'работаешь',
    'работают',
    'доступен',
    'жив',
    'живой',
    'онлайн',
    'подключен',
    'ты',
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
    // Инфинитив — дело, а не товар: «склад: 64115 переместить в 215-1-2-1».
    if (words.any(VerbForms.isInfinitive)) return true;
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
    final text = askText(SocialPrefix.rest(utterance) ?? utterance.original);
    if (text.isEmpty || text.length > maxLength) return null;
    // Действия с записью — только по встроенной копии; раньше команд.
    final action = matchAction(text, utterance);
    if (action != null) return action;
    final matcher = _matcher;
    if (matcher == null) return null;
    final lead = _withoutLead(text);
    // «покажи мне, где лежит …»: запятая после связок мешает их снять.
    final plain = text.replaceAll(RegExp(r'\s*,\s*'), ' ');
    final priced = ManifestQuery.priceForm(lead ?? text);
    final arrivals = ManifestQuery.arrivalsForm(lead ?? text);
    // «Скока стоят …», «чо не проведено ещё», «приходы без фоток покажь».
    final spoken = ManifestQuery.colloquial(lead ?? text);
    final spokenPrice = spoken == null ? null : ManifestQuery.priceForm(spoken);
    final remain = ManifestQuery.remainForm(lead ?? text);
    final candidates = <String>{
      if (remain != null) remain,
      if (priced != null) priced,
      if (arrivals != null) arrivals,
      text,
      if (lead != null) lead,
      plain,
      if (spokenPrice != null) spokenPrice,
      if (spoken != null) spoken,
    };
    // «Где лежит» без артикула (кнопка «Где лежит…» и сразу «Отправить»):
    // иначе правило «где {q}» искало бы на складе слово «лежит». Смотрим
    // во всех вариантах текста раньше обычных правил: «подскажи, где
    // лежит» правило «{q} где лежит» приняло бы за поиск «подскажи».
    for (final candidate in candidates) {
      final asked = _asked(matcher, candidate, aliased: false);
      if (asked != null) return asked.match;
      final rest = _withoutAlias(candidate) ?? _withoutTrailingAlias(candidate);
      if (rest != null) {
        final aliased = _asked(matcher, rest, aliased: true);
        if (aliased != null) return aliased.match;
      }
    }
    for (final candidate in candidates) {
      final found = _matchText(matcher, utterance, candidate, aliased: false);
      if (found != null) return found.match;
      final rest = _withoutAlias(candidate) ?? _withoutTrailingAlias(candidate);
      if (rest != null) {
        final aliased = _matchText(matcher, utterance, rest, aliased: true);
        if (aliased != null) return aliased.match;
      }
    }
    // Та же просьба словами описания: «есть ли на складе 64115», «наличие
    // 64115», «поищи 64115», «в какой ячейке лежит 64115».
    for (final candidate in candidates) {
      for (final (:text, :availability) in ManifestQuery.paraphrases(
        candidate,
      )) {
        if (availability && !_stockTalk(utterance, text)) continue;
        final found = _matchText(matcher, utterance, text, aliased: false);
        final match = found?.match;
        if (match == null) continue;
        // Наличие — догадка по обычным словам «есть ли»: уступает явной
        // команде другого навыка («есть ли у меня задачи на завтра»).
        if (!availability || match.confidence <= 0.75) return match;
        return ConnectorMatch(
          connectorId: match.connectorId,
          commandId: match.commandId,
          confidence: 0.75,
          payload: match.payload,
        );
      }
    }
    return null;
  }

  /// Вопрос «есть ли X» — о складе: назван склад или артикул, склад только
  /// что отвечал или подключён для роли «Кладовщик», и в вопросе нет слов
  /// других навыков («есть ли резервная копия», «есть ли смысл ждать»).
  /// В чате задачи и в ответ на вопрос помощника — нет.
  bool _stockTalk(Utterance utterance, String text) {
    if (utterance.chatTaskId != null || utterance.awaitingAnswer) return false;
    final words = text.split(_wordSplit);
    if (words.any((String w) => _foreignStems.any(w.startsWith))) return false;
    return utterance.codes.isNotEmpty ||
        words.any((String w) => _aliasWords.any(w.startsWith)) ||
        utterance.recentConnectorId == slot.id ||
        _hint('bareWords');
  }

  /// Слова обращений слота без предлогов: у склада — «складе» и «склад»
  /// (по началу слова — «склада», «складу»), у автосервиса —
  /// «автосервисе», «автосервис».
  late final List<String> _aliasWords = <String>{
    for (final alias in slot.aliases)
      for (final word in askText(alias).split(_wordSplit))
        if (word.isNotEmpty && !_prepositions.contains(word)) word,
  }.toList();

  static const Set<String> _prepositions = <String>{'в', 'во', 'на', 'у'};

  /// Слова других навыков и обычной речи в вопросе о наличии.
  static const List<String> _foreignStems = <String>[
    'задач',
    'напомин',
    'копи',
    'бэкап',
    'бекап',
    'резервн',
    'парол',
    'будильник',
    'таймер',
    'погод',
    'файл',
    'смысл',
    'толк',
    'врем',
    'дела',
    'планы',
    'вопрос',
  ];

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

  /// «приходы без фото за неделю, склад» → «приходы без фото».
  String? _withoutTrailingAlias(String text) {
    for (final alias in slot.aliases.map(askText)) {
      final match = RegExp('^(.+?)\\s*[,—–-]\\s*${RegExp.escape(alias)}\$')
          .firstMatch(text);
      if (match != null) return match.group(1);
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
      for (final raw in matcher.hits(pass)) {
        final hit = _cleaned(raw);
        final query = _textSlot(hit);
        if (query != null && query.isEmpty && raw.rule!.literalWords > 0) {
          // «сколько на складе»: искать нечего — спросить, что искать.
          return _found(
            hit.command.id,
            const <String, String>{},
            'ask',
            0.9,
            aliased: aliased,
          );
        }
        if (query != null &&
            _countsStock(hit.command) &&
            ManifestQuery.isWholeStock(query)) {
          // «сколько позиций на складе»: обо всём складе, а не поиск
          // товара «позиций» — честный ответ без запроса к складу.
          return _found(
            hit.command.id,
            const <String, String>{},
            'total',
            0.9,
            aliased: aliased,
          );
        }
        final verdict = _judge(hit, utterance, pass, aliased: aliased);
        if (verdict == null) continue;
        if (verdict < 0) {
          // «склад, 120734 срочно к завтрашнему дню где?»: срок и
          // срочность при одном артикуле — не часть запроса.
          final code = _codeOf(hit, utterance);
          if (code != null) {
            return _found(
              hit.command.id,
              code,
              hit.how,
              hit.rule!.literalWords == 1 ? 0.75 : 0.9,
              aliased: aliased,
            );
          }
          return const _Found(null);
        }
        return _found(
          hit.command.id,
          hit.slots,
          hit.how,
          verdict,
          aliased: aliased,
        );
      }
    }
    final relaxed = _relaxed(matcher, utterance, bare.isNotEmpty ? bare : text);
    if (relaxed != null) {
      final (raw, pass) = relaxed;
      final hit = _cleaned(raw);
      final verdict = _judge(hit, utterance, pass, aliased: aliased);
      if (verdict != null && verdict > 0) {
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
    // «есть в наличии 64115» — вопрос о наличии: его разберёт пересказ
    // («остаток 64115»), а не «где лежит» по голому артикулу.
    final raw = bare.isNotEmpty ? bare : text;
    final value = _availability.hasMatch(raw) ? raw : ManifestQuery.clean(raw);
    if (value.isEmpty) return null;
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

  static final RegExp _blank = RegExp(r'\s+');

  static final RegExp _availability = RegExp(r'наличи|(?:^|\s)есть(?:\s|$)');

  /// Совпадение с текстовыми полями без служебных слов по краям
  /// ([ManifestQuery.clean]): «по 64115» → «64115».
  static ManifestHit _cleaned(ManifestHit hit) {
    var changed = false;
    final slots = <String, String>{};
    for (final MapEntry(:key, :value) in hit.slots.entries) {
      final type = hit.command.slots[key]?.type;
      final clean =
          type == 'cell' || type == 'int' ? value : ManifestQuery.clean(value);
      if (clean != value) changed = true;
      slots[key] = clean;
    }
    if (!changed) return hit;
    return ManifestHit(
      command: hit.command,
      slots: slots,
      how: hit.how,
      rule: hit.rule,
    );
  }

  /// Значение единственного текстового поля совпадения или `null`.
  static String? _textSlot(ManifestHit hit) {
    if (hit.slots.length != 1) return null;
    final MapEntry(:key, :value) = hit.slots.entries.single;
    final type = hit.command.slots[key]?.type;
    return type == 'cell' || type == 'int' ? null : value;
  }

  /// Команда считает остаток: среди её фраз есть «сколько {поле}».
  static bool _countsStock(ManifestCommand command) => command.say.any(
        (String phrase) => _countPhrase.hasMatch(askText(phrase)),
      );

  static final RegExp _countPhrase = RegExp(r'^сколько\s+\{');

  /// Период у команды без полей: «приходы без фото за сегодня»,
  /// «приходы за день без фото». «За день», «за сутки» — это сегодня.
  static final RegExp _period = RegExp(
    r'(?:^|\s)(?:за\s+)?(?:сегодня|вчера|день|сутки|неделю|7\s+дней)(?=\s|$)',
  );

  /// Связка «есть»: «без фото приходы есть за день?».
  static final RegExp _linkWord = RegExp(r'(?:^|\s)есть(?=\s|$)');

  /// Место в конце запроса: «венских стульев сколько на 215-3».
  static final RegExp _placeTail = RegExp(r'^(.+?)\s+(?:на|в)\s+(\S+)$');

  /// Вопрос о ячейке после неё: «ячейка 215-1-1-1 что в ней», «на 215-3
  /// что стоит», «215а, что там?», «в ячейке без места что лежит».
  static final RegExp _cellQuestion = RegExp(
    r'^(?:(?:в|на)\s+(?:ячейке|стеллаже|складе)\s+|(?:ячейка|стеллаж)\s+|'
    r'(?:в|на)\s+)?(.+?)\s*,?\s+что(?:\s+(?:лежит|стоит|есть|там|хранится))?'
    r'(?:\s+(?:в|на)\s+(?:ней|нем))?$',
  );

  /// Совпадение с правилом описания после того, как фраза приведена к
  /// его словам (порядок и уточнения — не часть запроса):
  ///
  /// - период у команды без полей: «приходы без фото за сегодня» →
  ///   «приходы без фото» (у такой команды периода нет — его называет её
  ///   ответ), «что пришло за день» → «что пришло за сегодня»;
  /// - слова команды без полей в другом порядке: «без фото приходы есть»;
  /// - артикул впереди: «120734 остатки» → «остатки 120734»;
  /// - место в конце: «венских стульев сколько на 215-3» → без «на 215-3»
  ///   (ответ и так разбит по ячейкам);
  /// - вопрос после ячейки: «на 215-3 что стоит» → «215-3», «215а что в
  ///   ячейке без места» → «что в ячейке без места».
  ///
  /// Значение — совпадение и текст, по которому оно найдено.
  (ManifestHit, String)? _relaxed(
    ManifestMatcher matcher,
    Utterance utterance,
    String text,
  ) {
    ManifestHit? first(String pass, bool Function(ManifestHit) keep) {
      if (pass.isEmpty) return null;
      for (final hit in matcher.hits(pass)) {
        if (keep(hit)) return hit;
      }
      return null;
    }

    bool slotless(ManifestHit hit) =>
        hit.rule != null && hit.rule!.names.isEmpty;
    bool slotted(ManifestHit hit) =>
        hit.rule != null && hit.rule!.names.isNotEmpty;

    // Период: «за день» → «за сегодня»; без периода — только команды без
    // своего периода («приходы без фото»): «за неделю что пришло» — не
    // «что пришло» (сегодня).
    final today = text
        .replaceAll(RegExp(r'за\s+(?:день|сутки)(?=\s|$)'), 'за сегодня')
        .replaceAll(_linkWord, ' ')
        .replaceAll(_blank, ' ')
        .trim();
    final plain = text
        .replaceAll(_period, ' ')
        .replaceAll(_linkWord, ' ')
        .replaceAll(_blank, ' ')
        .trim();
    bool timeless(ManifestHit hit) => slotless(hit) && !_hasPeriod(hit.command);
    if (today != text) {
      final hit = first(today, slotless);
      if (hit != null) return (hit, today);
    }
    if (plain != text && plain != today) {
      final hit = first(plain, timeless);
      if (hit != null) return (hit, plain);
    }
    // Те же слова в другом порядке — только у фраз из двух слов и больше.
    for (final (pass, periods) in <(String, bool)>[
      (today, true),
      (plain, false),
    ]) {
      final words = pass.split(' ').toSet();
      if (words.length < 2) continue;
      for (final rule in matcher.rules) {
        if (rule.names.isNotEmpty || rule.literalWords < 2) continue;
        if (!periods && _hasPeriod(rule.command)) continue;
        final phrase = rule.phrase.split(' ').toSet();
        if (phrase.length == words.length && phrase.containsAll(words)) {
          return (
            ManifestHit(
              command: rule.command,
              slots: const <String, String>{},
              how: 'say',
              rule: rule,
            ),
            rule.phrase,
          );
        }
      }
    }
    // Артикул впереди.
    final lead = RegExp(r'^(\d{5,6})[\s,]+(.+)$').firstMatch(text);
    if (lead != null) {
      final pass = '${lead.group(2)} ${lead.group(1)}';
      final hit = first(pass, slotted);
      if (hit != null) return (hit, pass);
    }
    // Место в конце: «на 215-3».
    final place = _placeTail.firstMatch(text);
    if (place != null && _isCell(matcher, place.group(2)!)) {
      final pass = place.group(1)!;
      final hit = first(pass, slotted) ??
          (lead == null ? null : _relaxedCode(matcher, pass));
      if (hit != null) return (hit, pass);
    }
    // Вопрос после ячейки.
    final question = _cellQuestion.firstMatch(text);
    if (question != null && _isCell(matcher, question.group(1)!)) {
      final pass = question.group(1)!;
      final hit = first(pass, (ManifestHit h) => _cellRule(h));
      if (hit != null) return (hit, pass);
    }
    // Ячейка впереди и дальше целый вопрос: «215а что в ячейке без места».
    final space = text.indexOf(' ');
    if (space > 0 && _isCell(matcher, text.substring(0, space))) {
      final pass = text.substring(space + 1).replaceFirst(RegExp(r'^,\s*'), '');
      final hit = first(pass, slotted);
      if (hit != null) return (hit, pass);
    }
    return null;
  }

  /// У команды свой период: среди её фраз есть «сегодня», «вчера», «за
  /// неделю».
  static bool _hasPeriod(ManifestCommand command) =>
      command.say.any((String phrase) => _period.hasMatch(askText(phrase)));

  /// «120734 остатки на 215а»: артикул впереди и место в конце сразу.
  ManifestHit? _relaxedCode(ManifestMatcher matcher, String text) {
    final lead = RegExp(r'^(\d{5,6})[\s,]+(.+)$').firstMatch(text);
    if (lead == null) return null;
    for (final hit in matcher.hits('${lead.group(2)} ${lead.group(1)}')) {
      if (hit.rule != null && hit.rule!.names.isNotEmpty) return hit;
    }
    return null;
  }

  /// [value] — код ячейки по `shape` какого-нибудь поля-ячейки.
  static bool _isCell(ManifestMatcher matcher, String value) {
    for (final command in matcher.description.commands) {
      for (final def in command.slots.values) {
        if (def.type == 'cell' &&
            def.shape != null &&
            matcher.slotValue(def, value).isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  /// Правило — голое поле-ячейка: «{cell}».
  static bool _cellRule(ManifestHit hit) {
    final rule = hit.rule;
    if (rule == null || rule.names.length != 1) return false;
    return hit.command.slots[rule.names.first]?.type == 'cell';
  }

  /// Текстовые поля совпадения, если в каждом — один артикул, а остальное
  /// — срок и срочность: «120734 срочно к завтрашнему дню» → «120734».
  /// Иначе `null`.
  Map<String, String>? _codeOf(ManifestHit hit, Utterance utterance) {
    final rule = hit.rule;
    if (rule == null || rule.names.isEmpty) return null;
    // Обращение («склад, …») тоже не часть запроса.
    final aliases = slot.aliases.map(askText).toSet();
    final dueWords = <String>{
      for (final token in utterance.tokens)
        if (Utterance.isCovered(token, utterance.due.spans))
          askText(token.text),
    };
    final out = <String, String>{};
    for (final name in rule.names) {
      final value = hit.slots[name] ?? '';
      final def = hit.command.slots[name];
      if (def?.type == 'cell' || def?.type == 'int') {
        out[name] = value;
        continue;
      }
      final words = askText(value)
          .split(_wordSplit)
          .where(
            (String w) =>
                w.isNotEmpty &&
                !dueWords.contains(w) &&
                !_urgency.contains(w) &&
                !aliases.contains(w),
          )
          .toList();
      if (words.length != 1 || !_code.hasMatch(words.single)) return null;
      out[name] = words.single;
    }
    return out;
  }

  /// Срочность рядом с артикулом: «120734 срочно где».
  static const Set<String> _urgency = <String>{
    'срочно',
    'быстро',
    'сейчас',
    'пожалуйста',
  };

  /// Совпадение «спросить, что искать» для [text] или `null`.
  _Found? _asked(
    ManifestMatcher matcher,
    String text, {
    required bool aliased,
  }) {
    final bare = matcher.strip(text);
    for (final pass in <String>{text, if (bare.isNotEmpty) bare}) {
      final command = _unfinished(matcher, pass, aliased: aliased);
      if (command != null) {
        return _found(
          command.id,
          const <String, String>{},
          'ask',
          0.9,
          aliased: aliased,
        );
      }
    }
    return null;
  }

  /// Команда, чью фразу с полем начали и не договорили: [text] — слова
  /// фразы без поля («где лежит» из «где лежит {q}»). Одно слово («где»,
  /// «найди») слишком общее — только после обращения «склад, …». Фраза,
  /// которая целиком есть в описании («сколько пришло»), — не начало.
  static ManifestCommand? _unfinished(
    ManifestMatcher matcher,
    String text, {
    required bool aliased,
  }) {
    ManifestCommand? found;
    for (final rule in matcher.rules) {
      if (rule.command.help) continue;
      if (rule.names.isEmpty) {
        if (rule.phrase == text) return null;
        continue;
      }
      if (found != null || rule.literalWords < (aliased ? 1 : 2)) continue;
      final literal =
          rule.phrase.replaceAll(askSlotPattern, ' ').replaceAll(_blank, ' ');
      if (literal.trim() == text) found = rule.command;
    }
    return found;
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
          aliased: aliased,
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
        // Роль «Кладовщик» и подключённый склад: «сегодня» — приходы. Но
        // не в чате задачи («сегодня» там — новый срок задачи) и не в
        // ответ на вопрос помощника («На когда перенести задачу?»): там
        // слово — ответ, а не вопрос складу.
        return rule.literalWords == 1 &&
                command.call != null &&
                utterance.chatTaskId == null &&
                !utterance.awaitingAnswer &&
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
    // «сколько осталось до отпуска», «сколько стоит доллар», «сколько
    // смысл ждать» — не товар.
    if (words.first == 'до' ||
        words.any(
          (String w) =>
              _notGoods.contains(w) ||
              _currencyStems.any(w.startsWith) ||
              _deviceStems.any(w.startsWith),
        )) {
      return false;
    }
    // «Сколько стульев нужно для гостей» — расчёт, а не остаток; «сколько
    // сантиметров в дюйме» — перевод единиц.
    if (words.any(_needWords.contains)) return false;
    // «48 на 25 скока» — пример: одни числа и слова действия между ними.
    if (_arithmetic(words)) return false;
    // «Сколько можно повторять», «сколько ещё терпеть» — глагол, а не
    // товар; «скока там градусов за окном» — мера, а не позиция склада.
    if (words.any(
      (String w) =>
          _modalWords.contains(w) ||
          VerbForms.isInfinitive(w) ||
          _measureStems.any(w.startsWith),
    )) {
      return false;
    }
    for (var i = 0; i + 1 < words.length; i++) {
      if ((words[i] == 'в' || words[i] == 'во') &&
          _unitsIn.contains(words[i + 1])) {
        return false;
      }
    }
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
    final intent = match.commandId;
    switch (match.payload) {
      case final ActRequest request:
        return startAction(request, session, intent);
      case final ActFollow follow:
        return followAction(follow, session, intent);
      case final ActionCardSettle settle:
        return settleCard(settle.card, session, intent);
      case ConfirmationAnswer(pending: PendingConfirmation(:final payload))
          when payload is ActionCard:
        return answerCard(
          match.payload! as ConfirmationAnswer,
          payload,
          session,
          intent,
        );
      case ConfirmationAnswer(pending: PendingConfirmation(:final payload))
          when payload is ActDraft:
        return answerDraft(
          match.payload! as ConfirmationAnswer,
          payload,
          session,
          intent,
        );
    }
    final payload = match.payload! as ManifestPayload;
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
    if (payload.how == 'total') {
      return say('total', AssistantStatus.noAction, <String, String>{
        'example': command.examples.firstOrNull ?? slot.totalExample,
      });
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
    final keys = await readConnectionKeys(_secrets, slot, record);
    if (call == null || base == null || keys == null) {
      return _notConnected(session, intent);
    }
    if (payload.how == 'ask') {
      final field = command.slots.values.firstOrNull;
      return say('ask', AssistantStatus.needsClarification, <String, String>{
        'label': field == null || field.label.isEmpty
            ? slot.queryLabel
            : field.label,
        'example': command.examples.firstOrNull ?? '',
      });
    }
    final needs =
        description.access[command.access]?.needs ?? const <String>['token'];
    // Пароля склада нет только у ключа помощника без пароля (tokenless):
    // склад пускает его действия по одному личному ключу — он идёт всегда.
    final credentials = <String, String>{
      if (keys['token'] case final String token) 'token': token,
      if (record.tokenless) 'sid': keys['sid']!,
    };
    for (final name in needs) {
      if (name == 'token' || credentials.containsKey(name)) continue;
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
        if (record.tokenless) {
          // Без пароля склада 401 — ключ помощника не принят: войти заново.
          _fail(ConnectionFailure.expired, now);
          return say('auth.expired', AssistantStatus.failed);
        }
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
        // Склад 1.4.61+: у роли нет права (`perm`), помощник выключен
        // администратором (`off`).
        if (need == 'perm') return say('auth.perm', AssistantStatus.noAction);
        if (need == 'off') return say('auth.off', AssistantStatus.noAction);
        // Ключ помощника на действие приложения (склад 1.4.62).
        if (need == 'scope') return say('auth.scope', AssistantStatus.noAction);
      case 429:
        return say('busy', AssistantStatus.noAction);
    }
    if (unknownAction(status, json, description)) {
      // Склад этой команды не знает (старше или другой ветки): у команды
      // со своей записью каталога — она («цены пока не называю»), иначе —
      // «склад этого пока не умеет».
      final own = slot.commandReplies[command.id];
      if (own != null) return say(own, AssistantStatus.completed);
      return say('unsupported', AssistantStatus.noAction, <String, String>{
        'what': _lowerFirst(command.title),
      });
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

  /// Сервер ответил «не знаю такого действия»: 400 без кода отказа с
  /// текстом «Неизвестное действие» (склад halowarekeep и DepotDesk).
  static bool unknownAction(
    int status,
    Map<String, Object?>? json,
    ManifestDescription d,
  ) {
    if (status != 400 && status != 404) return false;
    if (json == null) return status == 404;
    if (json[d.codeField] != null) return false;
    final error = json[d.errorField];
    return error is String &&
        RegExp('неизвестн[а-яё]* действ', caseSensitive: false).hasMatch(error);
  }

  /// Подключение включила роль, а входа ещё нет: подсказать путь через
  /// карточку роли (ADR-012), а не «не понял».
  AssistantResponse _notConnected(AssistantSession session, String intent) {
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
    return session.reply(
      '${slot.id}.notConnected',
      intent: intent,
      status: AssistantStatus.noAction,
    );
  }

  // ------------------------------------------------- уточнение ответа

  @override
  ConnectorMatch? matchFollowUp(
    Utterance utterance,
    PendingConfirmation pending,
  ) {
    final payload = pending.payload;
    if (payload is! ActDraft) return null;
    return followUpAction(utterance, payload);
  }

  @override
  ConnectorMatch? matchLeadingAnswer(
    Utterance utterance,
    PendingConfirmation pending,
    ConfirmationReply reply,
  ) =>
      null;

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
    final card = cardOf(command, view);
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
      warehouse: card,
    );
  }

  /// Карточка ответа (ADR-031): те же строки, что в тексте, но данными —
  /// ячейка, количество, класс; вложенные — до [WarehouseCard.maxNested].
  WarehouseCard? cardOf(ManifestCommand command, ManifestView view) {
    if (view.rows.isEmpty) return null;
    WarehouseRow row(ManifestRow r, {bool nested = false}) => WarehouseRow(
          title: WarehouseCard.clean(r.title),
          text: WarehouseCard.clean(r.text),
          note: WarehouseCard.clean(r.note),
          badge: WarehouseCard.clean(r.badge),
          linkKind: WarehouseCard.kind(r.link?.kind),
          linkId: WarehouseCard.clean(r.link?.id),
          rows: nested
              ? const <WarehouseRow>[]
              : <WarehouseRow>[
                  for (final child
                      in r.rows.where((ManifestRow c) => !c.rest).take(
                            WarehouseCard.maxNested,
                          ))
                    row(child, nested: true),
                ],
        );
    final top = view.rows.where((ManifestRow r) => !r.rest).toList();
    return WarehouseCard(
      connector: slot.id,
      command: command.id,
      title: WarehouseCard.clean(command.title),
      say: WarehouseCard.clean(view.say),
      rows: <WarehouseRow>[
        for (final r in top.take(WarehouseCard.maxRows)) row(r),
      ],
      hidden: top.length > WarehouseCard.maxRows
          ? top.length - WarehouseCard.maxRows
          : 0,
      more: view.more.isNotEmpty,
    );
  }

  /// «где лежит товар — «где лежит 64115»; …».
  String _helpList() => <String>[
        for (final command
            in _description?.commands ?? const <ManifestCommand>[])
          if (!command.help && command.examples.isNotEmpty)
            '${_lowerFirst(command.title)} — «${command.examples.first}»',
        // Действия — только когда они разрешены для этого входа.
        if (actionsActive)
          for (final action in builtIn?.actions ?? const <ManifestAction>[])
            if (action.examples.isNotEmpty)
              '${_lowerFirst(action.title)} — «${action.examples.first}»',
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

  /// Личный ключ не принят сервером: «ключ устарел» (вход по ссылке
  /// заново).
  void markExpired(DateTime now) => _fail(ConnectionFailure.expired, now);

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
    final keys = await readConnectionKeys(_secrets, slot, record);
    if (keys == null || !record.connected) {
      // Роль включена, а входа ещё нет (или из склада вышли) — задуманное
      // состояние, а не сбой (ADR-012).
      return const HealthReport(
        HealthStatus.notConnected,
        detail: 'не подключён',
      );
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
