/// Договор веб-помощника со страницей склада (ADR-032): сообщения
/// `postMessage` между фреймом помощника и складом на том же адресе.
///
/// Здесь только данные и разбор — без `package:web`: разбор проверяется
/// тестами на VM. Отправку и проверку отправителя (`origin` и окно
/// родителя) делает `browser_host.dart`.
///
/// В каждом сообщении поле `svz: 1`. Чужие и битые сообщения
/// отбрасываются молча: страница может получать сообщения и от других
/// своих частей.
library;

import '../core/models/warehouse_card.dart';

/// Версия договора склад ↔ помощник: склад сверяет её с `minApi` выпуска
/// (`ASSIST_WEB_API` на сервере). 2 — напоминания (`signal`), открыть
/// разговор (`open-chat`), «изменилось» (`changed`); выпуск по-прежнему с
/// `minApi: 1` — открывается и на складе с договором 1.
const int widgetApi = 2;

/// Что умеет помощник сверх договора 1 — в `hello.caps`. `layout` —
/// помощник просит у склада широкую панель на компьютере ([WidgetMessages.layout]);
/// `open-project` — склад открывает проект сразу на его экране (ADR-038).
const List<String> widgetCaps = <String>[
  'signal',
  'open-chat',
  'open-project',
  'changed',
  'layout',
];

/// Отметка сообщения договора.
const String widgetMarker = 'svz';

/// Голос на этом устройстве — как его описала страница склада (модуль
/// `WhVoice` оболочки Android).
final class VoiceCaps {
  const VoiceCaps({this.available = false, this.reason = 'web'});

  factory VoiceCaps.fromJson(Object? json) {
    if (json is! Map) return const VoiceCaps();
    final reason = json['reason'];
    return VoiceCaps(
      available: json['available'] == true,
      reason: reason is String && reasons.contains(reason) ? reason : 'web',
    );
  }

  /// `ok` — распознавание на устройстве есть; `sdk` — Android ниже 12;
  /// `no-ondevice` — на устройстве распознавателя нет; `no-lang` — нет
  /// русского, его можно скачать; `web` — браузер или компьютер.
  static const Set<String> reasons = <String>{
    'ok',
    'sdk',
    'no-ondevice',
    'no-lang',
    'web',
  };

  final bool available;
  final String reason;

  /// Кнопка микрофона видна: распознавание есть, или оболочка Android
  /// может хотя бы подсказать (старый Android, нет русского).
  bool get showButton => available || reason != 'web';

  /// Android ниже 12 или без распознавания на устройстве: только подсказка
  /// про микрофон клавиатуры.
  bool get keyboardHint =>
      !available && (reason == 'sdk' || reason == 'no-ondevice');

  /// Нет русского для распознавания на устройстве: предложить скачать.
  bool get needsLanguage => !available && reason == 'no-lang';
}

/// Сообщение страницы склада помощнику.
sealed class HostEvent {
  const HostEvent();

  /// Разбор `event.data`; `null` — не наше или битое.
  static HostEvent? parse(Object? data) {
    if (data is! Map || data[widgetMarker] != 1) return null;
    final type = data['type'];
    String text(String key, [int max = 200]) {
      final value = data[key];
      if (value is! String) return '';
      final clean = value.replaceAll(_controls, ' ').trim();
      return clean.length > max ? clean.substring(0, max) : clean;
    }

    switch (type) {
      case 'init':
        final base = text('base', 2048);
        final sid = text('sid');
        if (base.isEmpty) return null;
        return HostInit(
          base: base,
          sid: sid,
          login: text('login', 64),
          name: text('name', 60),
          roleLabel: text('roleLabel', 60),
          theme: switch (data['theme']) {
            'light' => 'light',
            'dark' => 'dark',
            _ => '',
          },
          phone: data['device'] == 'phone',
          voice: VoiceCaps.fromJson(data['voice']),
          canWide: switch (data['layout']) {
            {'can': true} => true,
            _ => false,
          },
          wide: switch (data['layout']) {
            {'wide': true} => true,
            _ => false,
          },
        );
      case 'key':
        final sid = text('sid');
        return HostKey(sid: sid, error: sid.isEmpty ? text('error') : '');
      case 'theme':
        final theme = data['theme'];
        if (theme != 'light' && theme != 'dark') return null;
        return HostTheme(theme! as String);
      case 'back':
        return const HostBack();
      case 'logout':
        return const HostLogout();
      case 'visible':
        return HostVisible(data['on'] == true);
      case 'signal':
        final items = data['items'];
        if (items is! List) return null;
        return HostSignal(
          reason: text('reason', 20),
          focus: text('focus', 120),
          items: <WidgetSignal>[
            for (final item in items.take(5))
              if (WidgetSignal.fromJson(item) case final WidgetSignal s) s,
          ],
        );
      case 'open-chat':
        final id = text('id', 80);
        if (!RegExp(r'^[a-z0-9][a-z0-9:_\-.]{2,79}$').hasMatch(id)) return null;
        return HostOpenChat(id);
      case 'open-project':
        final id = text('id', 80);
        if (!RegExp(r'^[a-z0-9][a-z0-9:_\-.]{2,79}$').hasMatch(id)) return null;
        return HostOpenProject(id);
      case 'voice-ev':
        final id = data['id'];
        final ev = data['ev'];
        if (id is! int || ev is! String || !HostVoiceEvent.kinds.contains(ev)) {
          return null;
        }
        return HostVoiceEvent(
          id: id,
          kind: ev,
          text: text('text', 1000),
          code: text('code', 40),
        );
    }
    return null;
  }

  static final RegExp _controls = RegExp(
    '[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]',
  );
}

/// Вход сотрудника: адрес склада, ключ помощника (`assist_web_key`), кто
/// вошёл, тема и голос.
final class HostInit extends HostEvent {
  const HostInit({
    required this.base,
    required this.sid,
    this.login = '',
    this.name = '',
    this.roleLabel = '',
    this.theme = '',
    this.phone = false,
    this.voice = const VoiceCaps(),
    this.canWide = false,
    this.wide = false,
  });

  /// Адрес склада, где лежат `assistant.json` и `api.php`.
  final String base;

  /// Ключ помощника; пусто — страница ключа не получила.
  final String sid;
  final String login;
  final String name;
  final String roleLabel;

  /// `light`, `dark` или пусто — как у системы.
  final String theme;

  /// Телефон: панель во весь экран.
  final bool phone;
  final VoiceCaps voice;

  /// Склад умеет расширять панель на компьютере (`layout: {can: true}`).
  final bool canWide;

  /// Панель сейчас широкая (`layout: {wide: true}`).
  final bool wide;
}

/// Напоминания склада (договор 2): до 5 штук, [focus] — какое показать
/// первым; `reason` — `open`, `bell`, `badge`.
final class HostSignal extends HostEvent {
  const HostSignal({this.reason = '', this.focus = '', this.items = const []});
  final String reason;
  final String focus;
  final List<WidgetSignal> items;
}

/// Открыть разговор [id] из личного хранилища склада.
final class HostOpenChat extends HostEvent {
  const HostOpenChat(this.id);
  final String id;
}

/// Открыть проект [id] из личного хранилища склада: экран проекта с его
/// разговорами и задачами.
final class HostOpenProject extends HostEvent {
  const HostOpenProject(this.id);
  final String id;
}

/// Действие напоминания: ровно одно из [ask], [open], [ack], [my], [call],
/// [date] (README склада, «Объект напоминания»).
final class SignalAction {
  const SignalAction({
    required this.id,
    required this.label,
    this.ask,
    this.open,
    this.ack,
    this.my,
    this.call,
    this.dateLabel,
    this.confirmBy = 'button',
  });

  final String id;
  final String label;

  /// Вопрос помощнику — как будто его написали.
  final String? ask;

  /// Адрес на странице склада (`#/act/…`).
  final String? open;

  /// `my_signal_ack` с этим `op` (`snooze`, `dismiss`).
  final String? ack;

  /// Вызов `my_*`: `{action, body}`.
  final Map<String, Object?>? my;

  /// Расчёт действия склада (`*_check`) → карточка.
  final Map<String, Object?>? call;

  /// Выбор даты: подпись; дата подставляется в `{date}` тела [my].
  final String? dateLabel;
  final String confirmBy;

  static SignalAction? fromJson(Object? json) {
    if (json is! Map) return null;
    String? str(Object? v, [int max = 200]) {
      if (v is! String) return null;
      final t = v.replaceAll(HostEvent._controls, ' ').trim();
      if (t.isEmpty) return null;
      return t.length > max ? t.substring(0, max) : t;
    }

    final id = str(json['id'], 40);
    final label = str(json['label'], 60);
    if (id == null || label == null) return null;
    final ack = json['ack'];
    final my = json['my'];
    final call = json['call'];
    final date = json['date'];
    final open = str(json['open'], 256);
    return SignalAction(
      id: id,
      label: label,
      ask: str(json['ask'], 300),
      open: open == null ? null : WidgetMessages.safeHash(open),
      ack: ack is Map && ack['op'] is String ? ack['op']! as String : null,
      my: my is Map && my['action'] is String && my['body'] is Map
          ? Map<String, Object?>.from(my)
          : null,
      call: call is Map && call['action'] is String
          ? Map<String, Object?>.from(call)
          : null,
      dateLabel: date is Map ? str(date['label'], 60) ?? 'Дата' : null,
      confirmBy: json['confirmBy'] == 'word' ? 'word' : 'button',
    );
  }
}

/// Напоминание склада — один вид для колокольчика, помощника и Связного.
final class WidgetSignal {
  const WidgetSignal({
    required this.id,
    required this.title,
    this.text = '',
    this.level = 'info',
    this.open = '',
    this.seen = false,
    this.actions = const <SignalAction>[],
  });

  final String id;
  final String title;
  final String text;
  final String level;
  final String open;
  final bool seen;
  final List<SignalAction> actions;

  static WidgetSignal? fromJson(Object? json) {
    if (json is! Map) return null;
    String clean(Object? v, int max) {
      if (v is! String) return '';
      final t = v.replaceAll(HostEvent._controls, ' ').trim();
      return t.length > max ? t.substring(0, max) : t;
    }

    final id = clean(json['id'], 120);
    final title = clean(json['title'], 200);
    if (id.isEmpty || title.isEmpty) return null;
    final state = json['state'];
    final actions = json['actions'];
    return WidgetSignal(
      id: id,
      title: title,
      text: clean(json['text'], 600),
      level: json['level'] == 'warn' ? 'warn' : 'info',
      open: WidgetMessages.safeHash(clean(json['open'], 256)),
      seen: state is Map && state['seen'] == true,
      actions: <SignalAction>[
        if (actions is List)
          for (final a in actions.take(8))
            if (SignalAction.fromJson(a) case final SignalAction x) x,
      ],
    );
  }
}

/// Новый ключ помощника после [WidgetMessages.needKey] — или почему его нет.
final class HostKey extends HostEvent {
  const HostKey({this.sid = '', this.error = ''});
  final String sid;
  final String error;
}

/// Сотрудник переключил тему склада, пока помощник загружен: `light` или
/// `dark`. Вход и разговор не трогаются.
final class HostTheme extends HostEvent {
  const HostTheme(this.theme);
  final String theme;
}

/// «Назад» на телефоне: отменить распознавание, иначе закрыть.
final class HostBack extends HostEvent {
  const HostBack();
}

/// Сотрудник вышел из склада: ключ уже погашен вместе со входом.
final class HostLogout extends HostEvent {
  const HostLogout();
}

/// Панель открыта или закрыта.
final class HostVisible extends HostEvent {
  const HostVisible(this.on);
  final bool on;
}

/// Событие распознавания речи от модуля оболочки.
final class HostVoiceEvent extends HostEvent {
  const HostVoiceEvent({
    required this.id,
    required this.kind,
    this.text = '',
    this.code = '',
  });

  static const Set<String> kinds = <String>{
    'state',
    'partial',
    'final',
    'error',
  };

  /// Номер запуска распознавания ([WidgetMessages.voice]): события
  /// прежнего запуска не путаются с новым.
  final int id;

  /// `state` (в [text]: `listening`, `speech`, `end`), `partial`, `final`,
  /// `error` (в [code]: `no-speech`, `no-match`, `busy`, `perm`,
  /// `perm-denied`, `lang`, `lang-unavailable`).
  final String kind;
  final String text;
  final String code;
}

/// Сообщения помощника странице склада.
abstract final class WidgetMessages {
  static Map<String, Object?> _m(String type, [Map<String, Object?>? rest]) =>
      <String, Object?>{widgetMarker: 1, 'type': type, ...?rest};

  /// Помощник загрузился и ждёт `init`.
  static Map<String, Object?> hello(String version) =>
      _m('hello', <String, Object?>{
        'version': version,
        'api': widgetApi,
        'caps': widgetCaps,
      });

  /// Что-то изменилось: `data` — склад, `sig` — напоминания, `my` — личные
  /// записи. Склад перечитывает своё.
  static Map<String, Object?> changed(List<String> what) => _m(
        'changed',
        <String, Object?>{
          'what': <String>[
            for (final w in what)
              if (w == 'data' || w == 'sig' || w == 'my') w,
          ],
        },
      );

  /// Широкая панель на компьютере ([HostInit.canWide]): список разговоров
  /// слева, разговор справа.
  static Map<String, Object?> layout({required bool wide}) =>
      _m('layout', <String, Object?>{'wide': wide});

  /// Ключ устарел или отозван (403 `need: login`, 401 без пароля склада):
  /// странице — получить новый `assist_web_key`.
  static Map<String, Object?> needKey() => _m('need-key');

  /// Закрыть панель.
  static Map<String, Object?> close() => _m('close');

  /// Перейти на странице склада: `#/entry/…`; пусто — главная склада.
  static Map<String, Object?> open(String hash) =>
      _m('open', <String, Object?>{'hash': safeHash(hash)});

  /// На складе установлена другая версия помощника, а помощник ничем не
  /// занят: странице — перезагрузить фрейм.
  static Map<String, Object?> updateReady(String version) =>
      _m('update-ready', <String, Object?>{'version': version});

  /// Распознавание речи: `start`, `stop`, `cancel`, `download`.
  static Map<String, Object?> voice(String op, int id) {
    if (!voiceOps.contains(op)) throw ArgumentError.value(op, 'op');
    return _m('voice', <String, Object?>{'op': op, 'id': id, 'lang': 'ru-RU'});
  }

  static const Set<String> voiceOps = <String>{
    'start',
    'stop',
    'cancel',
    'download',
  };

  /// Позиция или приход из карточки ответа: `#/sku/<артикул>`,
  /// `#/entry/<id>` (склад: `onOpenHash`). Id — %-кодом всё, кроме букв,
  /// цифр и `._-`: кириллица, `/` и скобки в артикуле не ломают адрес,
  /// склад раскодирует (`decodeURIComponent`). Другое — пусто (главная).
  static String linkHash(String kind, String id) =>
      WarehouseCard.openKinds.contains(kind) && id.isNotEmpty
          ? safeHash('#/$kind/${_encodeId(id)}')
          : '';

  static String _encodeId(String id) =>
      Uri.encodeComponent(id).replaceAllMapped(
        RegExp(r"[!*'()~]"),
        (Match m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
      );

  /// Только `#/…` из букв, цифр и `/._-=&?%`: страница склада переходит
  /// внутри себя, а не по чужому адресу. `%` — закодированный id
  /// ([linkHash]): склад раскодирует его сам.
  static String safeHash(String hash) =>
      RegExp(r'^#/[A-Za-z0-9/._=&?%-]{0,200}$').hasMatch(hash) ? hash : '';
}
