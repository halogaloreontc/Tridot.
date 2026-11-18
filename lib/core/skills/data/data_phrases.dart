import '../../connectors/utterance.dart';
import '../../personas/persona_address.dart';
import '../passwords/passwords_phrases.dart';

/// Что просят сделать с данными.
enum DataAction {
  /// Резервная копия: «сделай бэкап».
  backup,

  /// Восстановление из копии: «восстанови из копии».
  restore,

  /// Открыть, посмотреть: «открой хранилище».
  open,

  /// Запереть: «закрой хранилище».
  lock,

  /// Нет доступа, не открывается: «хранилище не открывается».
  access,

  /// Перенос на другое устройство: «перенести хранилище на новый ноутбук».
  move,
}

/// Разобранная просьба о данных ([DataPhrases.parse]).
final class DataRequest {
  const DataRequest({
    required this.action,
    required this.everything,
    this.command = false,
  });

  final DataAction action;

  /// Вся фраза — команда с голым «хранилище» в объекте: «закрой
  /// хранилище», «восстановить хранилище из копии». Это не название
  /// задачи («закрой задачу X»), а просьба о сейфе или данных — у неё
  /// маркер, а не догадка по форме.
  final bool command;

  /// Названы все данные приложения («всех данных», «данные приложения»):
  /// спрашивать нечего. `false` — объекта нет или он двусмысленный
  /// («хранилище»): это может быть и сейф с паролями.
  final bool everything;

  /// Та же просьба о сейфе с паролями: каноническая команда
  /// ([DataPhrases.passwordsCommands]), а не фраза пользователя — в ней
  /// нет ничего, кроме шаблона.
  String get passwordsText => DataPhrases.passwordsCommands[action]!;

  /// Та же просьба обо всех данных: каноническая команда.
  String get dataText => DataPhrases.dataCommands[action]!;

  /// Команда коннектора «Данные» для этой просьбы: `data.backup`. Нет
  /// доступа и перенос для всех данных — то же, что открыть их.
  String get dataCommand => switch (action) {
        DataAction.access || DataAction.move => 'data.open',
        _ => 'data.${action.name}',
      };
}

/// Фразы о данных приложения без опоры на пароли (решение владельца 3 и 5,
/// docs/PLANS.md). Чистые функции без ввода-вывода.
///
/// Два вида фраз:
///
/// * **Двусмысленные** — копия или восстановление без объекта («сделай
///   бэкап», «восстанови из копии», «нужна копия») и любое действие с
///   голым «хранилище» («открой хранилище», «сделай копию хранилища»): в
///   приложении есть и сейф с паролями, и общие данные. Коннектор «Данные»
///   переспрашивает «Копию чего: паролей или всех данных?» или берёт ответ
///   из контекста сессии.
/// * **Явные** — с объектом «все данные», «данные приложения», «задачи и
///   чаты»: «сделай резервную копию всех данных».
///
/// Фразы со словом «пароль», «сейф» или «хранилище паролей» — не здесь:
/// это навык «Пароли». Копия чего-то названного («сделай копию договора»)
/// — тоже не здесь.
abstract final class DataPhrases {
  /// Канонические команды сейфа по действию: их разбирает навык «Пароли».
  static const Map<DataAction, String> passwordsCommands = <DataAction, String>{
    DataAction.backup: 'сделай резервную копию сейфа',
    DataAction.restore: 'восстанови сейф из копии',
    DataAction.open: 'открой сейф',
    DataAction.lock: 'запри сейф',
    DataAction.access: 'сейф не открывается',
    DataAction.move: 'как перенести сейф на новый телефон',
  };

  /// Канонические команды «Данных» по действию: их разбирает [parse] как
  /// явные.
  static const Map<DataAction, String> dataCommands = <DataAction, String>{
    DataAction.backup: 'сделай резервную копию всех данных',
    DataAction.restore: 'восстанови все данные из копии',
    DataAction.open: 'открой данные приложения',
    DataAction.lock: 'запри данные приложения',
    DataAction.access: 'открой данные приложения',
    DataAction.move: 'открой данные приложения',
  };

  /// Просьба о данных в [utterance] или `null`.
  static DataRequest? parse(Utterance utterance) {
    final text = _prepare(utterance.normalized);
    if (text.isEmpty) return null;
    // Пароли, сейф и хранилище паролей — навык «Пароли».
    if (PasswordPhrases.mentions(utterance) ||
        _passwordsObject.hasMatch(text)) {
      return null;
    }
    if (_storage.hasMatch(text) &&
        !_foreignStorage.hasMatch(text) &&
        !_task.hasMatch(text)) {
      final action = _storageAction(text);
      if (action == null) return null;
      return DataRequest(
        action: action,
        everything: false,
        command: _storageCommand.hasMatch(text),
      );
    }
    if (_everything.hasMatch(text)) {
      final action = _looseAction(text);
      if (action == null) return null;
      return DataRequest(
        action: action,
        everything: true,
      );
    }
    final DataAction action;
    if (_restore.hasMatch(text)) {
      action = DataAction.restore;
    } else if (_backup.hasMatch(text) || _backupReversed.hasMatch(text)) {
      action = DataAction.backup;
    } else {
      return null;
    }
    return DataRequest(
      action: action,
      everything: false,
    );
  }

  /// Текст для правил: без обращения к помощнику, без вежливых слов по
  /// краям, кавычек и знаков в конце.
  static String _prepare(String text) {
    var value = PersonaAddressing.withoutAddress(text);
    value = _clean(value);
    for (var i = 0; i < 2; i++) {
      value = _clean(value.replaceAll(_politeEdge, ''));
    }
    return value;
  }

  static String _clean(String text) => text
      .replaceAll(RegExp(r'[«»"“”„]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s,.!?;:—–-]+|[\s,.!?;:—–…]+$'), '')
      .trim();

  static final RegExp _politeEdge = RegExp(
    r'^(?:пожалуйста|плиз|пж)(?:[\s,]+|$)|'
    r'[\s,]+(?:пожалуйста|плиз|пж|pls|please)$',
  );

  /// Сейф и хранилище паролей — объект навыка «Пароли».
  static final RegExp _passwordsObject = RegExp(
    r'(?<![а-я])сейф|хранилищ[а-я]*\s+(?:паролей|с\s+паролями)',
  );

  /// Названа задача: «закрой задачу хранилище» — о задаче, не о данных.
  static final RegExp _task = RegExp(r'(?<![а-я])задач[а-я]*');

  /// Голое «хранилище» в любой форме.
  static final RegExp _storage = RegExp(r'(?<![а-я])хранилищ[а-я]*');

  /// Хранилище чего-то другого: облачное, для велосипеда, ключ от
  /// хранилища — помещение, а не данные.
  static final RegExp _foreignStorage = RegExp(
    r'(?<![а-я])(?:облачн|сетев|внешн|файлов|домашн|холодн|нов)[а-я]*'
    r'\s+хранилищ|'
    r'хранилищ[а-я]*\s+(?:для|под)\s|'
    r'(?<![а-я])(?:ключ|замк|замок|двер|ворот|охран)[а-я]*\s+(?:от\s+|в\s+)?'
    r'хранилищ',
  );

  /// Все данные приложения.
  static final RegExp _everything = RegExp(
    r'(?<![а-я])(?:вс[еёя]|всех|всего)\s+(?:мои\s+|моих\s+)?данн[а-я]*|'
    r'данн[а-я]*\s+приложени[а-я]*|'
    r'(?<![а-я])задач[а-я]*\s+и\s+(?:сесси|чат)[а-я]*',
  );

  /// Нет доступа: «не открывается», «не могу зайти», «доступ пропал».
  static final RegExp _accessWords = RegExp(
    r'(?<![а-я])не\s+(?:открыва|откро|могу|получается|вхожу|захожу|пуска)|'
    r'(?<![а-я])(?:доступ|заблокирован|пропал|сломал|поврежд)[а-я]*',
  );

  static final RegExp _restoreWord = RegExp(
    r'(?<![а-я])(?:восстан[ао]в|верн(?:и|уть|ите)(?![а-я])|откат)',
  );

  static final RegExp _lockWord = RegExp(
    r'(?<![а-я])(?:запри|запереть|закрой|закрыть|закройте|заприте|'
    r'заблокируй|заблокировать|блокируй)(?![а-я])',
  );

  static final RegExp _backupWord = RegExp(
    r'(?<![а-я])(?:бэкап|бекап|backup|резервн[а-я]*\s+коп|'
    r'коп(?:ию|ия|ии|ировать|ируй|ирую|ирование)(?![а-я]))',
  );

  /// «Из копии», «из последнего бэкапа», «из резервной копии».
  static final RegExp _fromCopy = RegExp(
    r'(?<![а-я])из\s+(?:[а-я]+\s+)?'
    r'(?:бэкап|бекап|backup|резервн[а-я]*\s+коп|коп(?:ии|ий)(?![а-я]))',
  );

  static final RegExp _device = RegExp(
    r'(?<![а-я])(?:телефон|смартфон|мобил|ноутбук|ноут|компьютер|комп|'
    r'планшет|айфон|устройств)[а-я]*',
  );

  static final RegExp _moveWord = RegExp(r'(?<![а-я])перен[её]?с[а-я]*');

  static final RegExp _openWord = RegExp(
    r'(?<![а-я])(?:открой|открыть|откройте|покажи|показать|зайди|зайти|'
    r'войти|разблокируй|разблокировать)(?![а-я])',
  );

  /// Действие с голым «хранилище»; без глагола — только само слово
  /// («хранилище», «мое хранилище»).
  static DataAction? _storageAction(String text) {
    // Телефон или ноутбук рядом — потеря или смена устройства.
    if (_device.hasMatch(text)) return DataAction.move;
    if (_accessWords.hasMatch(text)) return DataAction.access;
    final action = _looseAction(text);
    if (action != null) return action;
    if (_moveWord.hasMatch(text)) return DataAction.move;
    if (_bareStorage.hasMatch(text)) return DataAction.open;
    return null;
  }

  /// Команда целиком: глагол в начале, «хранилище» — его объект (через
  /// одно-два слова, но не «задачу»: «закрой задачу хранилище» — задача),
  /// дальше — только «из копии», «на новый телефон» или запятая. «Закрой
  /// хранилище на складе», «открой хранилище в 10 утра» — помещение или
  /// дело, а не команда: остаётся догадкой.
  static final RegExp _storageCommand = RegExp(
    r'^(?:запри|закрой|заблокируй|открой|разблокируй|восстанови|сделай|'
    r'создай|сохрани|запереть|закрыть|заблокировать|открыть|'
    r'разблокировать|восстановить|сделать|создать|сохранить)'
    r'\s+(?:(?!задач|напомина)[а-я]+\s+){0,2}?'
    r'хранилищ[а-я]*(?=$|\s*,|'
    r'\s+из\s+(?:резервн[а-я]*\s+|последн[а-я]*\s+|вчерашн[а-я]*\s+)?'
    r'(?:коп|бэкап|бекап)|'
    r'\s+на\s+(?:нов[а-я]*\s+|друг[а-я]*\s+)?(?:телефон|смартфон|ноутбук|'
    r'ноут|компьютер|комп|планшет|айфон|устройств))',
  );

  static final RegExp _bareStorage = RegExp(
    r'^(?:(?:мое|моё|мой|мои)\s+)?хранилищ[а-я]*$',
  );

  /// Действие по глаголу или существительному, без требований к форме.
  /// «Из копии» — направление восстановления, какой бы ни был глагол:
  /// «вытащи все данные из копии», «загрузи данные из бэкапа» — не новая
  /// копия поверх старой.
  static DataAction? _looseAction(String text) {
    if (_restoreWord.hasMatch(text)) return DataAction.restore;
    if (_lockWord.hasMatch(text)) return DataAction.lock;
    if (_fromCopy.hasMatch(text)) return DataAction.restore;
    if (_backupWord.hasMatch(text)) return DataAction.backup;
    if (_openWord.hasMatch(text)) return DataAction.open;
    return null;
  }

  /// Начало просьбы: «как», «можно», «помоги» перед глаголом.
  static const String _lead =
      r'^(?:(?:как|можно|хочу|надо|нужно|помоги|давай)\s+)?';

  /// Копия без объекта: существительное копии.
  static const String _copyNoun =
      r'(?:бэкап|бекап|backup|резервн[а-я]*\s+коп(?:ию|ия)|коп(?:ию|ия))';

  /// Что может идти после копии и не делает её копией чего-то другого:
  /// слова срочности и вежливости, а после запятой или «чтобы», «а то» —
  /// только страх потерять данные («а то всё пропадёт», «чтобы ничего не
  /// потерялось»). «Нужна копия, паспорта и снилса», «сделай копию чтобы
  /// отправить начальнику» — копия бумаги, не данных приложения.
  static const String _tail =
      r'(?:(?:\s*,\s*|\s+)(?:всего|данных|на\s+всякий\s+случай|сейчас|'
      r'срочно|быстро|еще|ещё|мне|пожалуйста|плиз|'
      r'(?:а\s+то|чтобы|чтоб|вдруг|если|на\s+случай(?:\s+если)?)'
      r'(?:\s+[а-яё]+){0,4}?\s+(?:пропа|потер|удал|слет|сотр|слом|исчез|'
      r'грохн|накрыл)[а-яё]*(?:\s+[а-яё]+){0,3}))*$';

  /// «Сделай бэкап», «нужна копия», «как сделать копию, чтобы не
  /// пропало». «Сделай копию договора» — копия чего-то названного, не
  /// здесь.
  static final RegExp _backup = RegExp(
    '$_lead(?:сделай|сделайте|создай|создайте|сохрани|сохраните|сделать|'
    r'создать|сохранить|сними|снять|нужн[аоы]|нужен)\s+(?:мне\s+)?'
    '$_copyNoun$_tail',
  );

  /// «Бэкап сделай», «копию сохрани».
  static final RegExp _backupReversed = RegExp(
    '^$_copyNoun\\s+(?:сделай|создай|сохрани|нужн[аоы]|нужен)$_tail',
  );

  /// «Восстанови из копии», «восстановление из бэкапа», «верни всё из
  /// вчерашнего бэкапа», «как восстановить через резервную копию».
  static final RegExp _restore = RegExp(
    '$_lead(?:восстанов[а-я]*|верни|вернуть|верните|откати[а-я]*)'
    r'(?:\s+(?:вс[её]|данные|данных|мои\s+данные|информацию))?'
    r'\s+(?:из|через|с|по)\s+(?:[а-я]+\s+)?'
    r'(?:бэкап[а-я]*|бекап[а-я]*|backup|резервн[а-я]*\s+коп[а-я]*|коп[а-я]*)'
    '$_tail',
  );
}
