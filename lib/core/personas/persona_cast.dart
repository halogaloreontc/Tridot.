import 'persona.dart';

/// Режим команды помощников («Мой Tridot» → «Помощники», ADR-016).
enum TeamMode {
  /// Связной делает всё сам.
  solo,

  /// Связной и один помощник на выбор ([PersonaSettings.duoHelper]); зона
  /// второго возвращается к главному.
  duo,

  /// Все трое.
  trio,
}

/// Обязанность помощника.
enum PersonaDuty {
  /// Беседа, задачи, планы, расчёты. Всегда у главного.
  main,

  /// Расширения: склад, пароли, будущие конвертер, архиватор, загрузчик и
  /// подключения. По умолчанию у Лиорио.
  extensions,

  /// Оповещения: напоминания, просрочки, сигналы склада, итоги фоновых
  /// задач, утренняя сводка. По умолчанию у Ноды.
  notifications,
}

/// Состав помощников по настройкам: имена и род из настроек, кто активен в
/// текущем режиме и кто что ведёт.
///
/// Обращение по имени («Нода, …») берёт имена из текущего состава
/// ([current]): интерфейс ставит его при смене настроек ([configure]), а
/// разборщики обращений пересобирают образцы, когда меняется [version].
final class PersonaCast {
  PersonaCast._(this.members, this.mode, this._duoHelper, this._duties);

  /// Состав по [settings].
  factory PersonaCast.of(PersonaSettings settings) => PersonaCast._(
        List<Persona>.unmodifiable(<Persona>[
          for (final persona in Personas.all)
            persona.renamed(
              settings.nameOf(persona.id),
              settings.genderOf(persona.id),
            ),
        ]),
        settings.teamMode,
        settings.duoHelper,
        <PersonaDuty, String>{
          for (final duty in PersonaDuty.values)
            duty: settings.dutyOwnerId(duty),
        },
      );

  /// Все трое — Связной, Лиорио, Нода — с текущими именами и родом, вне
  /// зависимости от режима.
  final List<Persona> members;

  final TeamMode mode;
  final String _duoHelper;
  final Map<PersonaDuty, String> _duties;

  /// Помощник по id с текущим именем; неизвестный id — `null`.
  Persona? find(String? id) =>
      members.where((Persona p) => p.id == id).firstOrNull;

  /// Помощник по id; неизвестный id — главный.
  Persona byId(String? id) => find(id) ?? responder;

  /// Главный: Связной. Отвечает, если к помощнику не обратились.
  Persona get responder => members.first;

  /// Активные в текущем режиме: в Соло — Связной, в Дуэте — Связной и выбранный
  /// помощник, в Трио — все трое.
  List<Persona> get active => <Persona>[
        for (final persona in members)
          if (isActive(persona.id)) persona,
      ];

  /// Помощник [id] работает в текущем режиме.
  bool isActive(String id) => switch (mode) {
        _ when id == Personas.sado.id => true,
        TeamMode.solo => false,
        TeamMode.duo => id == _duoHelper,
        TeamMode.trio => find(id) != null,
      };

  /// Кто ведёт обязанность [duty]: назначенный, если он активен, иначе
  /// Связной.
  Persona ownerOf(PersonaDuty duty) {
    final id = _duties[duty];
    return id != null && isActive(id) ? byId(id) : responder;
  }

  /// Кто пишет первым: ведущий оповещений.
  Persona get notifier => ownerOf(PersonaDuty.notifications);

  /// Кто ведёт расширения.
  Persona get extensionsLead => ownerOf(PersonaDuty.extensions);

  /// Помощник по имени для обращения ([Persona.addressNames]) без учёта
  /// регистра: «Лио», «Noda». Не имя — `null`.
  Persona? byAddressName(String word) {
    final lower = Persona.fold(word);
    return members
        .where((Persona p) => p.addressNames.contains(lower))
        .firstOrNull;
  }

  /// Помощник по любой форме имени ([Persona.nameForms]) без учёта
  /// регистра: «Ноду», «Лиорио». Не имя — `null`.
  Persona? byNameForm(String word) {
    final lower = Persona.fold(word);
    return members
        .where((Persona p) => p.nameForms.contains(lower))
        .firstOrNull;
  }

  /// Все формы имён: от них зависят образцы разбора обращений.
  String get _namesKey => <String>[
        for (final persona in members) ...persona.nameForms,
      ].join('|');

  static PersonaCast _current = PersonaCast.of(const PersonaSettings());
  static int _version = 0;

  /// Текущий состав: по нему разбираются обращения по имени.
  static PersonaCast get current => _current;

  /// Растёт, когда меняются имена: разборщики обращений
  /// ([PersonaAddressing], беседа, вступления) пересобирают образцы.
  static int get version => _version;

  /// Ставит текущий состав по [settings].
  static void configure(PersonaSettings settings) {
    final next = PersonaCast.of(settings);
    if (next._namesKey != _current._namesKey) _version++;
    _current = next;
  }

  /// Для тестов: встроенный состав.
  static void resetForTest() => configure(const PersonaSettings());
}
