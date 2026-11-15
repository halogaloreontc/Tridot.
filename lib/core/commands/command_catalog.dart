/// Каталог команд для «+» → «Шаблоны команд» и «Найти команду» (ADR-020).
///
/// Чистый Dart: ни Flutter, ни ввода-вывода. Каталог собирается из
/// включённых навыков и подключений ([ConnectorInfo]): выключили навык —
/// его команды пропали из списка, потому что помощник их всё равно не
/// выполнит. У каждой команды постоянный id (`task.new`, `calc.eval`): по
/// нему считается, как часто её выбирают ([CommandUsage]). Текст, который
/// пользователь потом допишет, не хранится и не считается.
library;

import '../build_flags.dart';
import '../chats/chat_search.dart';
import '../connectors/connector.dart';

/// Раздел списка «Найти команду». Порядок — порядок разделов в списке.
enum CommandCategory {
  tasks('Задачи'),
  planning('Планирование'),
  talk('Беседа'),
  calc('Калькулятор'),
  warehouse('Склад'),
  vault('Сейф'),
  data('Данные'),
  files('Файлы'),
  other('Другое');

  const CommandCategory(this.label);

  final String label;
}

/// Что делает выбор команды.
enum CommandKind {
  /// Вставить [CommandEntry.template] в поле ввода; `|` — место курсора.
  insert,

  /// Действие интерфейса (открыть сейф, генератор, карточку архиватора):
  /// ничего не вставляет. Какое — решает интерфейс по [CommandEntry.id].
  action,
}

/// Одна команда каталога.
final class CommandEntry {
  const CommandEntry({
    required this.id,
    required this.category,
    required this.label,
    required this.connectorId,
    this.template = '',
    this.kind = CommandKind.insert,
    this.iconName = 'bolt',
    this.sample = '',
    this.needsSelection = false,
  });

  /// Постоянный id латиницей: `task.new`. Ключ счётчика и виджета
  /// `command-entry-<id>`.
  final String id;

  final CommandCategory category;

  /// Подпись в списке: «Новая задача».
  final String label;

  /// Шаблон для поля ввода; `|` — место курсора. Пусто у действий.
  final String template;

  final CommandKind kind;

  /// Навык или подключение, которое выполнит команду: без него команды
  /// в каталоге нет.
  final String connectorId;

  /// Имя значка (`add`, `event`): ядро не знает о Flutter, значок по
  /// имени выбирает интерфейс.
  final String iconName;

  /// Пример того, что вписать на место `|`: для подсказки в списке и для
  /// теста «каждый шаблон доходит до своего навыка».
  final String sample;

  /// Команда о выбранной задаче («её»): без выбранной задачи не
  /// показывается.
  final bool needsSelection;

  /// Шаблон без `|`, как его увидит пользователь в поле.
  String get preview => template.replaceFirst('|', '…');

  /// Шаблон с [sample] на месте `|`: полная команда.
  String get filled => template.replaceFirst('|', sample);
}

/// Каталог команд включённых навыков.
final class CommandCatalog {
  const CommandCatalog._(this.entries);

  /// Каталог для включённых навыков [connectors]
  /// (AssistantController.connectors). [hasSelection] — в сессии выбрана
  /// активная задача: тогда есть и команды о ней («Перенести выбранную»).
  /// [projectTag] — метка папки проекта, в сессии которого открыт ввод
  /// (ADR-018): «Задача в проект» сразу подставит её. [passwordActions] —
  /// интерфейс умеет открывать сейф и генератор. [formActions] —
  /// интерфейс умеет открывать карточки расширений (архиватор).
  factory CommandCatalog.build({
    required Iterable<ConnectorInfo> connectors,
    bool hasSelection = false,
    String? projectTag,
    bool passwordActions = true,
    bool formActions = true,
  }) {
    // Недоступное в сборке ([ConnectorInfo.unavailable]) команд не даёт.
    final enabled = <String, ConnectorInfo>{
      for (final info in connectors)
        if (!info.unavailable) info.id: info,
    };
    final entries = <CommandEntry>[
      for (final entry in curated)
        if (enabled.containsKey(entry.connectorId))
          if (!entry.needsSelection || hasSelection)
            if (entry.kind != CommandKind.action ||
                (entry.connectorId == 'passwords'
                    ? passwordActions
                    : formActions))
              _withProject(entry, projectTag),
      // Навыки и подключения, о которых каталог ничего не знает (новые
      // расширения): их примеры — готовые команды в «Другом».
      for (final info in enabled.values)
        if (!_curatedConnectors.contains(info.id))
          for (var i = 0; i < info.examples.length && i < 6; i++)
            CommandEntry(
              id: 'ext.${info.id}.$i',
              category: CommandCategory.other,
              label: info.examples[i],
              template: info.examples[i],
              connectorId: info.id,
            ),
    ];
    // Склад без описания (ещё ни разу не подключались и нет встроенной
    // копии) — не знает ни одной команды: его раздел не показывается.
    entries.removeWhere(
      (CommandEntry e) =>
          e.category == CommandCategory.warehouse &&
          (enabled[e.connectorId]?.examples.isEmpty ?? true),
    );
    entries.sort(
      (CommandEntry a, CommandEntry b) =>
          a.category.index.compareTo(b.category.index),
    );
    return CommandCatalog._(List<CommandEntry>.unmodifiable(entries));
  }

  /// Команды в порядке разделов, внутри раздела — в порядке [curated].
  final List<CommandEntry> entries;

  CommandEntry? byId(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Разделы с командами, в порядке [CommandCategory].
  Map<CommandCategory, List<CommandEntry>> get grouped {
    final result = <CommandCategory, List<CommandEntry>>{};
    for (final entry in entries) {
      (result[entry.category] ??= <CommandEntry>[]).add(entry);
    }
    return result;
  }

  /// Команды, где [query] есть в подписи, шаблоне, примере или названии
  /// раздела; без учёта регистра и «ё». Пустой запрос — все.
  List<CommandEntry> search(String query) {
    final words = ChatSearch.fold(query)
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return entries;
    return <CommandEntry>[
      for (final entry in entries)
        if (_matches(entry, words)) entry,
    ];
  }

  static bool _matches(CommandEntry entry, List<String> words) {
    final haystack = ChatSearch.fold(
      '${entry.label} ${entry.preview} ${entry.filled} '
      '${entry.category.label}',
    );
    return words.every(haystack.contains);
  }

  /// До [count] команд для «Шаблонов команд»: самые частые по [usage],
  /// при равенстве (и без счётчиков) — в порядке [defaultTop], затем
  /// каталога. Команды выключенных навыков не попадают.
  List<CommandEntry> top(Map<String, int> usage, {int count = 4}) {
    int rank(CommandEntry e) {
      final index = defaultTop.indexOf(e.id);
      return index < 0 ? defaultTop.length + entries.indexOf(e) : index;
    }

    final sorted = List<CommandEntry>.of(entries)
      ..sort((CommandEntry a, CommandEntry b) {
        final byUse = (usage[b.id] ?? 0).compareTo(usage[a.id] ?? 0);
        return byUse != 0 ? byUse : rank(a).compareTo(rank(b));
      });
    return sorted.take(count).toList();
  }

  /// Порядок «Шаблонов команд», пока счётчиков нет.
  static const List<String> defaultTop = <String>[
    'task.new',
    'task.tomorrow10',
    'task.list',
    'calc.eval',
  ];

  /// «Задача в проект» в сессии папки с меткой: метка уже подставлена.
  static CommandEntry _withProject(CommandEntry entry, String? tag) {
    if (entry.id != 'task.project' || tag == null || tag.isEmpty) {
      return entry;
    }
    return CommandEntry(
      id: entry.id,
      category: entry.category,
      label: entry.label,
      template: 'Добавь задачу «|» #$tag',
      connectorId: entry.connectorId,
      iconName: entry.iconName,
      sample: entry.sample,
    );
  }

  static final Set<String> _curatedConnectors = <String>{
    for (final entry in curated) entry.connectorId,
  };

  /// Id всех встроенных команд: счётчик с другим id (кроме `ext.*`) при
  /// загрузке настроек отбрасывается.
  static final Set<String> knownIds = <String>{
    for (final entry in curated) entry.id,
  };

  /// Id команды, которую можно считать: встроенная или пример расширения.
  static bool isCountable(String id) =>
      knownIds.contains(id) ||
      RegExp(r'^ext\.[a-z0-9_-]{1,40}\.\d{1,2}$').hasMatch(id);

  /// Встроенные команды. Id не меняются: по ним хранятся счётчики.
  static const List<CommandEntry> curated = <CommandEntry>[
    // ---------------------------------------------------------- Задачи
    CommandEntry(
      id: 'task.new',
      category: CommandCategory.tasks,
      label: 'Новая задача',
      template: 'Добавь задачу «|»',
      connectorId: 'tasks',
      iconName: 'add',
      sample: 'Купить хлеб',
    ),
    CommandEntry(
      id: 'task.tomorrow10',
      category: CommandCategory.tasks,
      label: 'Задача на завтра в 10:00',
      template: 'Добавь задачу «|» на завтра в 10:00',
      connectorId: 'tasks',
      iconName: 'event',
      sample: 'Позвонить врачу',
    ),
    CommandEntry(
      id: 'task.project',
      category: CommandCategory.tasks,
      label: 'Задача в проект',
      template: 'Добавь задачу «|» #',
      connectorId: 'tasks',
      iconName: 'tag',
      sample: 'Смета',
    ),
    CommandEntry(
      id: 'task.remind',
      category: CommandCategory.tasks,
      label: 'Напомнить',
      template: 'Напомни |',
      connectorId: 'tasks',
      iconName: 'bell',
      sample: 'позвонить маме завтра в 18:00',
    ),
    CommandEntry(
      id: 'task.list',
      category: CommandCategory.tasks,
      label: 'Показать задачи',
      template: 'Покажи задачи',
      connectorId: 'tasks',
      iconName: 'checklist',
    ),
    CommandEntry(
      id: 'task.today',
      category: CommandCategory.tasks,
      label: 'Задачи на сегодня',
      template: 'Покажи задачи на сегодня',
      connectorId: 'tasks',
      iconName: 'today',
    ),
    CommandEntry(
      id: 'task.done',
      category: CommandCategory.tasks,
      label: 'Завершить выбранную',
      template: 'Заверши её',
      connectorId: 'tasks',
      iconName: 'check',
      needsSelection: true,
    ),
    CommandEntry(
      id: 'task.complete',
      category: CommandCategory.tasks,
      label: 'Завершить задачу',
      template: 'Заверши «|»',
      connectorId: 'tasks',
      iconName: 'check',
      sample: 'Отчёт',
    ),
    // ----------------------------------------------------- Планирование
    CommandEntry(
      id: 'plan.move',
      category: CommandCategory.planning,
      label: 'Перенести выбранную',
      template: 'Перенеси её на |',
      connectorId: 'tasks',
      iconName: 'update',
      sample: 'завтра в 15:00',
      needsSelection: true,
    ),
    CommandEntry(
      id: 'plan.moveTask',
      category: CommandCategory.planning,
      label: 'Перенести задачу',
      template: 'Перенеси «|» на завтра',
      connectorId: 'tasks',
      iconName: 'update',
      sample: 'Отчёт',
    ),
    // Будильник и таймер в «Часах» (ADR-029).
    CommandEntry(
      id: 'alarm.set',
      category: CommandCategory.planning,
      label: 'Будильник',
      template: 'Поставь будильник на |',
      connectorId: 'alarm',
      iconName: 'alarm',
      sample: '7:00',
    ),
    CommandEntry(
      id: 'alarm.timer',
      category: CommandCategory.planning,
      label: 'Таймер',
      template: 'Поставь таймер на |',
      connectorId: 'alarm',
      iconName: 'timer',
      sample: '5 минут',
    ),
    CommandEntry(
      id: 'plan.overdue',
      category: CommandCategory.planning,
      label: 'Просроченные — на завтра',
      template: 'Перенеси все просроченные на завтра',
      connectorId: 'tasks',
      iconName: 'history',
    ),
    CommandEntry(
      id: 'plan.week',
      category: CommandCategory.planning,
      label: 'Задачи на неделю',
      template: 'Покажи задачи на неделю',
      connectorId: 'tasks',
      iconName: 'event',
    ),
    // ----------------------------------------------------------- Беседа
    CommandEntry(
      id: 'talk.skills',
      category: CommandCategory.talk,
      label: 'Что ты умеешь',
      template: 'Что ты умеешь?',
      connectorId: 'talk',
      iconName: 'help',
    ),
    CommandEntry(
      id: 'talk.joke',
      category: CommandCategory.talk,
      label: 'Рассказать шутку',
      template: 'Расскажи шутку',
      connectorId: 'talk',
      iconName: 'mood',
    ),
    CommandEntry(
      id: 'talk.brief',
      category: CommandCategory.talk,
      label: 'Отвечать короче',
      template: 'Говори короче',
      connectorId: 'talk',
      iconName: 'chat',
    ),
    // ------------------------------------------------------- Калькулятор
    CommandEntry(
      id: 'calc.eval',
      category: CommandCategory.calc,
      label: 'Посчитать',
      template: 'Сколько будет |',
      connectorId: 'calc',
      iconName: 'calc',
      sample: '2+2*2',
    ),
    CommandEntry(
      id: 'calc.percent',
      category: CommandCategory.calc,
      label: 'Процент от числа',
      template: '15% от |',
      connectorId: 'calc',
      iconName: 'percent',
      sample: '2400',
    ),
    CommandEntry(
      id: 'calc.root',
      category: CommandCategory.calc,
      label: 'Корень',
      template: 'Корень из |',
      connectorId: 'calc',
      iconName: 'calc',
      sample: '144',
    ),
    // ------------------------------------------------------------ Склад
    CommandEntry(
      id: 'wh.where',
      category: CommandCategory.warehouse,
      label: 'Где лежит…',
      template: 'Где лежит |',
      connectorId: 'warehouse',
      iconName: 'search',
      sample: 'ABC-123',
    ),
    CommandEntry(
      id: 'wh.today',
      category: CommandCategory.warehouse,
      label: 'Что пришло сегодня',
      template: 'Что пришло сегодня',
      connectorId: 'warehouse',
      iconName: 'inbox',
    ),
    CommandEntry(
      id: 'wh.nophoto',
      category: CommandCategory.warehouse,
      label: 'Приходы без фото',
      template: 'Без фото',
      connectorId: 'warehouse',
      iconName: 'photo',
    ),
    // ------------------------------------------------------------- Сейф
    CommandEntry(
      id: 'pw.open',
      category: CommandCategory.vault,
      label: 'Пароли',
      kind: CommandKind.action,
      connectorId: 'passwords',
      iconName: 'key',
    ),
    CommandEntry(
      id: 'pw.generate',
      category: CommandCategory.vault,
      label: 'Сгенерировать пароль',
      kind: CommandKind.action,
      connectorId: 'passwords',
      iconName: 'password',
    ),
    CommandEntry(
      id: 'pw.add',
      category: CommandCategory.vault,
      label: 'Добавить запись',
      kind: CommandKind.action,
      connectorId: 'passwords',
      iconName: 'shield',
    ),
    CommandEntry(
      id: 'pw.forgot',
      category: CommandCategory.vault,
      label: 'Подсказка к паролю',
      template: 'Забыл пароль от |',
      connectorId: 'passwords',
      iconName: 'key',
      sample: 'почты',
    ),
    CommandEntry(
      id: 'pw.check',
      category: CommandCategory.vault,
      label: 'Проверить пароли',
      template: 'Проверь мои пароли',
      connectorId: 'passwords',
      iconName: 'shield',
    ),
    CommandEntry(
      id: 'pw.lock',
      category: CommandCategory.vault,
      label: 'Запереть сейф',
      template: 'Запри пароли',
      connectorId: 'passwords',
      iconName: 'lock',
    ),
    // ------------------------------------------------------------ Файлы
    // Карточки архиватора (docs/PLANS.md, «Карточки-формы»): форма
    // открывается сразу, без фразы.
    CommandEntry(
      id: 'ext.archiver.zip',
      category: CommandCategory.files,
      label: 'Сжать в ZIP',
      kind: CommandKind.action,
      connectorId: 'archiver',
      iconName: 'zip',
    ),
    CommandEntry(
      id: 'ext.archiver.extract',
      category: CommandCategory.files,
      label: 'Распаковать ZIP',
      kind: CommandKind.action,
      connectorId: 'archiver',
      iconName: 'unzip',
    ),
    CommandEntry(
      id: 'ext.archiver.list',
      category: CommandCategory.files,
      label: 'Что внутри ZIP',
      kind: CommandKind.action,
      connectorId: 'archiver',
      iconName: 'list',
    ),
    // Карточка конвертера: файл → формат → «Запустить».
    CommandEntry(
      id: 'ext.converter',
      category: CommandCategory.files,
      label: 'Сконвертировать файл',
      kind: CommandKind.action,
      connectorId: 'converter',
      iconName: 'convert',
    ),
    // Карточка загрузчика видео: ссылка → что скачать → «Скачать». Есть
    // только там, где загрузчик зарегистрирован (Windows, Linux, не
    // сборка для Google Play).
    if (!kPlayBuild)
      CommandEntry(
        id: 'ext.ytdl',
        category: CommandCategory.files,
        label: 'Скачать видео по ссылке',
        kind: CommandKind.action,
        connectorId: 'ytdl',
        iconName: 'download',
      ),
    // ----------------------------------------------------------- Данные
    CommandEntry(
      id: 'data.backup',
      category: CommandCategory.data,
      label: 'Резервная копия',
      template: 'Сделай резервную копию всех данных',
      connectorId: 'data',
      iconName: 'backup',
    ),
    CommandEntry(
      id: 'data.restore',
      category: CommandCategory.data,
      label: 'Восстановить из копии',
      template: 'Восстанови все данные из копии',
      connectorId: 'data',
      iconName: 'restore',
    ),
    CommandEntry(
      id: 'data.open',
      category: CommandCategory.data,
      label: 'Данные приложения',
      template: 'Открой данные приложения',
      connectorId: 'data',
      iconName: 'storage',
    ),
  ];
}

/// Счётчики выбора команд ([AppSettings.commandUsage]): id → сколько раз
/// выбрали из «+» или «Найти команду». Только id и число: ни текста
/// команды, ни времени.
abstract final class CommandUsage {
  /// Больше записей не храним: остаются самые частые.
  static const int maxEntries = 50;

  /// Потолок одного счётчика: дальше порядок всё равно не меняется.
  static const int maxCount = 1 << 20;

  /// Счётчики с [id] на один больше. Неизвестный id не считается.
  static Map<String, int> bump(Map<String, int> usage, String id) {
    if (!CommandCatalog.isCountable(id)) return usage;
    final next = <String, int>{...usage};
    final count = (next[id] ?? 0) + 1;
    next[id] = count > maxCount ? maxCount : count;
    return trim(next);
  }

  /// Чтение из `settings.json`: не объект — пусто; неизвестные id и не
  /// положительные числа отбрасываются; не больше [maxEntries].
  static Map<String, int> fromJson(Object? value) {
    if (value is! Map) return const <String, int>{};
    return trim(<String, int>{
      for (final MapEntry(:key, :value) in value.entries)
        if (key is String &&
            CommandCatalog.isCountable(key) &&
            value is int &&
            value > 0)
          key: value > maxCount ? maxCount : value,
    });
  }

  /// Не больше [maxEntries] самых частых.
  static Map<String, int> trim(Map<String, int> usage) {
    if (usage.length <= maxEntries) return usage;
    final sorted = usage.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        },
      );
    return <String, int>{
      for (final entry in sorted.take(maxEntries)) entry.key: entry.value,
    };
  }
}
