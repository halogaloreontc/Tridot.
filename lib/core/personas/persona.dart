import 'package:characters/characters.dart';

import '../replies/reply_library.dart';
import 'persona_cast.dart';
import 'persona_names.dart';
import 'persona_palette.dart';

export 'persona_cast.dart';

/// Помощник: Садо, Лиорио или Нода (docs/PLANS.md, «Tridot: Садо, Лиорио
/// и Нода»; ADR-016).
///
/// Данные и коннекторы у них общие; различаются имя, род, цвет, стиль
/// общения и обязанности. Имя и род можно поменять в настройках: тогда
/// [PersonaCast] строит помощника с новым именем ([renamed]).
final class Persona {
  const Persona({
    required this.id,
    required this.name,
    required this.russianName,
    this.nicknames = const <String>[],
    this.inflectedForms = const <String>[],
    required this.gender,
    required this.accentColor,
    required this.accentBackground,
    required this.description,
  });

  /// Постоянный id латиницей: `sado`, `rio`, `noda`. Хранится в
  /// настройках, в истории чата и в паках. У Лиорио id остался `rio` от
  /// прежнего имени: старые настройки и история читаются как есть
  /// (ADR-008). При переименовании id не меняется.
  final String id;

  /// Имя латиницей: «Liorio». У переименованного помощника — новое имя.
  final String name;

  /// Имя в интерфейсе и в ответах: «Лиорио» или имя из настроек.
  final String russianName;

  /// Другие имена для обращения, в нижнем регистре: краткое «лио»,
  /// ласковое «нодочка», разговорное «нодь». Только у встроенного имени.
  final List<String> nicknames;

  /// Косвенные падежи имени, в нижнем регистре: «ноду», «ноде». Только
  /// для беседы («сделай Ноду основной»), обращением не считаются.
  /// «Лиорио» и «Садо» не склоняются; у нового имени форм нет.
  final List<String> inflectedForms;

  /// Имена, по которым обращаются в начале и в конце сообщения, в нижнем
  /// регистре и с «е» вместо «ё» ([fold]): латиницей, кириллицей и
  /// [nicknames], без повторов.
  List<String> get addressNames => <String>{
        fold(name),
        fold(russianName),
        ...nicknames.map(fold),
      }.toList();

  /// Слово для сравнения имён: нижний регистр, «ё» → «е». «Алёна» и
  /// «Алена» — одно имя: «е» вместо «ё» пишут постоянно.
  static String fold(String word) => word.toLowerCase().replaceAll('ё', 'е');

  /// Все формы имени в нижнем регистре: [addressNames] и
  /// [inflectedForms].
  List<String> get nameForms =>
      <String>[...addressNames, ...inflectedForms.map(fold)];

  /// Род, в котором помощник говорит о себе: «добавил» или «добавила».
  final ReplyGender gender;

  /// Цвет метки у ответов, ARGB. Ядро без Flutter: цвет — число.
  final int accentColor;

  /// Фон знака помощника (буква на нём — [accentColor]), ARGB.
  final int accentBackground;

  /// Одна строка для настроек.
  final String description;

  /// Буква на метке у ответа: первая буква текущего имени, «С», «Л», «Н».
  String get initial => russianName.characters.first.toUpperCase();

  /// То же, что [initial]: знак помощника в оболочке.
  String get russianInitial => initial;

  /// Помощники равны, если у них тот же id, те же имена и род: встроенный
  /// и непереименованный из состава ([PersonaCast]) — один и тот же.
  @override
  bool operator ==(Object other) =>
      other is Persona &&
      other.id == id &&
      other.name == name &&
      other.russianName == russianName &&
      other.gender == gender;

  @override
  int get hashCode => Object.hash(id, name, russianName, gender);

  /// Тот же помощник с именем [newName] и родом [newGender]. Встроенные
  /// краткие имена и падежи остаются, только пока имя прежнее (без учёта
  /// регистра и «ё»): у нового имени одно обращение — именительный падеж,
  /// а в просьбах беседы понимается ещё творительный («дуэт с Мирой»,
  /// [instrumentalForms]).
  Persona renamed(String newName, ReplyGender newGender) {
    final same = fold(newName) == fold(russianName);
    return Persona(
      id: id,
      name: same ? name : newName,
      russianName: same ? russianName : newName,
      nicknames: same ? nicknames : const <String>[],
      inflectedForms: same ? inflectedForms : instrumentalForms(newName),
      gender: newGender,
      accentColor: accentColor,
      accentBackground: accentBackground,
      description: description,
    );
  }
}

/// Творительный падеж нового имени для просьб беседы («включи дуэт с
/// Мирой»), в нижнем регистре и с «е» вместо «ё»: «Мира» — «мирой»,
/// «мирей»; «Тим» — «тимом», «тимем»; «Гоша» — «гошей», «гошой»; «Ая» —
/// «аей». Несклоняемые («Садо», «Лиорио») и не кириллица — без форм.
/// Только для образцов просьб: обращением эти формы не считаются.
List<String> instrumentalForms(String name) {
  final word = Persona.fold(name.trim());
  if (word.length < 2 || !RegExp(r'^[а-я-]+$').hasMatch(word)) {
    return const <String>[];
  }
  final stem = word.substring(0, word.length - 1);
  final last = word[word.length - 1];
  return switch (last) {
    'а' => <String>['$stemой', '$stemей'],
    'я' => <String>['$stemей'],
    'й' => <String>['$stemем'],
    'ь' => <String>['$stemем', '$stemью'],
    'о' || 'е' || 'и' || 'у' || 'ю' || 'э' || 'ы' => const <String>[],
    _ => <String>['$wordом', '$wordем'],
  };
}

/// Встроенные помощники — значения по умолчанию. Текущие имена и род —
/// в [PersonaCast] ([PersonaSettings.cast]).
abstract final class Personas {
  /// Садо — главный: беседа, задачи, планы, расчёты. Встречает в новой
  /// сессии. Род выбирает пользователь; пока не выбран, каталог склоняет в
  /// мужском роде (ADR-016).
  static const Persona sado = Persona(
    id: 'sado',
    name: 'Sado',
    russianName: 'Садо',
    gender: ReplyGender.male,
    accentColor: PersonaPalette.sado,
    accentBackground: PersonaPalette.sadoBg,
    description: 'Главный: беседа, задачи, планы и расчёты.',
  );

  /// Лиорио — расширения. Id `rio` — от прежнего имени «Rio», менять его
  /// нельзя: он в настройках и истории пользователя (ADR-008).
  static const Persona liorio = Persona(
    id: 'rio',
    name: 'Liorio',
    russianName: 'Лиорио',
    nicknames: <String>['lio', 'лио'],
    gender: ReplyGender.male,
    accentColor: PersonaPalette.liorio,
    accentBackground: PersonaPalette.liorioBg,
    description: 'Расширения: склад, пароли и подключения.',
  );

  /// Нода — оповещения.
  static const Persona noda = Persona(
    id: 'noda',
    name: 'Noda',
    russianName: 'Нода',
    nicknames: <String>['нодочка', 'нодь'],
    inflectedForms: <String>['ноды', 'ноде', 'ноду', 'нодой', 'нодочку'],
    gender: ReplyGender.female,
    accentColor: PersonaPalette.noda,
    accentBackground: PersonaPalette.nodaBg,
    description: 'Оповещения: напоминания, просрочки и сигналы.',
  );

  static const List<Persona> all = <Persona>[sado, liorio, noda];

  /// Помощники, которым можно поручить обязанность (расширения,
  /// оповещения): все, кроме главного.
  static const List<String> helperIds = <String>['rio', 'noda'];

  /// Встроенный помощник по id; неизвестный id — `null`. Текущее имя и
  /// род — у [PersonaCast.find].
  static Persona? byId(String? id) =>
      all.where((Persona p) => p.id == id).firstOrNull;

  /// Помощник по имени для обращения ([Persona.addressNames]) без учёта
  /// регистра, по текущему составу ([PersonaCast.current]): «Лио», «Noda».
  /// Не имя — `null`.
  static Persona? byAddressName(String word) =>
      PersonaCast.current.byAddressName(word);

  /// Помощник по любой форме имени ([Persona.nameForms]) без учёта
  /// регистра, по текущему составу: «Ноду», «Лиорио». Не имя — `null`.
  static Persona? byNameForm(String word) =>
      PersonaCast.current.byNameForm(word);
}

/// Как часто беседа добавляет лёгкий каламбур к приветствию и
/// благодарности. На ответы задач и других навыков не влияет.
enum JokeFrequency {
  off,
  rare,
  normal;

  /// На ступень реже: «шути меньше».
  JokeFrequency get less => switch (this) {
        normal => rare,
        _ => off,
      };

  /// На ступень чаще: «шути больше».
  JokeFrequency get more => switch (this) {
        off => rare,
        _ => normal,
      };
}

/// Настройки помощников. Хранятся в `settings.json` (AppSettings) и
/// ничего, кроме того, кто и как говорит, не меняют.
final class PersonaSettings {
  const PersonaSettings({
    this.teamMode = TeamMode.trio,
    this.duoHelper = 'rio',
    this.names = const <String, String>{},
    this.genders = const <String, ReplyGender>{},
    this.dutyExtensions = 'rio',
    this.dutyNotifications = 'noda',
    this.styles = defaultStyles,
    this.address = ReplyAddress.formal,
    this.emoji = true,
    this.jokes = JokeFrequency.rare,
    this.legacyMainPersona,
    this.legacySoloPersona,
  });

  /// По умолчанию Садо и Лиорио говорят нейтрально, Нода — дружески.
  static const Map<String, String> defaultStyles = <String, String>{
    'sado': ReplyStyles.neutral,
    'rio': ReplyStyles.neutral,
    'noda': ReplyStyles.friendly,
  };

  /// Соло, Дуэт или Трио.
  final TeamMode teamMode;

  /// Помощник Садо в Дуэте: `rio` или `noda`.
  final String duoHelper;

  /// Имена из настроек: id → имя. Нет ключа — встроенное имя.
  final Map<String, String> names;

  /// Род из настроек: id → род. Нет ключа — встроенный род; у Садо это
  /// значит «род не выбран» ([sadoGenderChosen]).
  final Map<String, ReplyGender> genders;

  /// Кто ведёт расширения: `rio` или `noda`.
  final String dutyExtensions;

  /// Кто ведёт оповещения: `rio` или `noda`.
  final String dutyNotifications;

  /// Стиль каждого помощника: id → id стиля (встроенного или пака
  /// ответов).
  final Map<String, String> styles;

  /// «Вы» или «ты» — общее для всех.
  final ReplyAddress address;

  /// Эмодзи разрешены; пользуется ли ими стиль — решает стиль.
  final bool emoji;

  final JokeFrequency jokes;

  /// Прежние ключи `main_persona` и `solo_persona` как они были в файле:
  /// пишутся обратно без изменений, чтобы откат на прошлую версию вернул
  /// пользователю его отвечающего (ADR-016). Новая версия их не читает;
  /// `null` — ключа не было, пишется `rio`.
  final String? legacyMainPersona;
  final String? legacySoloPersona;

  /// Состав по этим настройкам: имена, род, кто активен и кто что ведёт.
  PersonaCast get cast => PersonaCast.of(this);

  /// Текущее имя помощника [id] (встроенное, если не меняли).
  String nameOf(String id) => names[id] ?? Personas.byId(id)?.russianName ?? id;

  /// Текущий род помощника [id]. У Садо до выбора — мужской: так
  /// склоняет каталог (ADR-016); интерфейс до выбора говорит без рода.
  ReplyGender genderOf(String id) =>
      genders[id] ?? Personas.byId(id)?.gender ?? ReplyGender.male;

  /// Пользователь уже выбрал род Садо (карточка первого запуска).
  bool get sadoGenderChosen => genders.containsKey(Personas.sado.id);

  /// Кто ведёт обязанность [duty] по настройкам, без учёта режима.
  String dutyOwnerId(PersonaDuty duty) => switch (duty) {
        PersonaDuty.main => Personas.sado.id,
        PersonaDuty.extensions => dutyExtensions,
        PersonaDuty.notifications => dutyNotifications,
      };

  /// Главный — всегда Садо. Отвечает, если к помощнику не обратились.
  Persona get responder => cast.responder;

  /// Кто пишет первым: ведущий оповещений, если он активен, иначе Садо.
  Persona get notifier => cast.notifier;

  /// Кто ведёт расширения: назначенный, если он активен, иначе Садо.
  Persona get extensionsLead => cast.extensionsLead;

  String styleOf(Persona persona) =>
      styles[persona.id] ?? defaultStyles[persona.id] ?? ReplyStyles.neutral;

  /// Голос [persona]: стиль, род из настроек, обращение, эмодзи.
  ReplyVoice voiceOf(Persona persona) => ReplyVoice(
        style: styleOf(persona),
        gender: genderOf(persona.id),
        address: address,
        emoji: emoji,
      );

  PersonaSettings copyWith({
    TeamMode? teamMode,
    String? duoHelper,
    Map<String, String>? names,
    Map<String, ReplyGender>? genders,
    String? dutyExtensions,
    String? dutyNotifications,
    Map<String, String>? styles,
    ReplyAddress? address,
    bool? emoji,
    JokeFrequency? jokes,
  }) =>
      PersonaSettings(
        teamMode: teamMode ?? this.teamMode,
        duoHelper: duoHelper ?? this.duoHelper,
        names: names ?? this.names,
        genders: genders ?? this.genders,
        dutyExtensions: dutyExtensions ?? this.dutyExtensions,
        dutyNotifications: dutyNotifications ?? this.dutyNotifications,
        styles: styles ?? this.styles,
        address: address ?? this.address,
        emoji: emoji ?? this.emoji,
        jokes: jokes ?? this.jokes,
        legacyMainPersona: legacyMainPersona,
        legacySoloPersona: legacySoloPersona,
      );

  /// Стиль одного помощника.
  PersonaSettings withStyle(String personaId, String style) =>
      copyWith(styles: <String, String>{...styles, personaId: style});

  /// Имя одного помощника. Встроенное имя снимает переименование.
  PersonaSettings withName(String personaId, String name) {
    final next = <String, String>{...names}..remove(personaId);
    final builtin = Personas.byId(personaId)?.russianName;
    // «нода» вместо «Нода» — то же имя ([Persona.renamed]).
    if (builtin == null || Persona.fold(name) != Persona.fold(builtin)) {
      next[personaId] = name;
    }
    return copyWith(names: next);
  }

  /// Род одного помощника.
  PersonaSettings withGender(String personaId, ReplyGender gender) =>
      copyWith(genders: <String, ReplyGender>{...genders, personaId: gender});

  /// Обязанность [duty] ведёт [personaId] (`rio` или `noda`). Главного
  /// не переназначить: он всегда Садо.
  PersonaSettings withDuty(PersonaDuty duty, String personaId) =>
      switch (duty) {
        PersonaDuty.main => this,
        PersonaDuty.extensions => copyWith(dutyExtensions: personaId),
        PersonaDuty.notifications => copyWith(dutyNotifications: personaId),
      };

  static String _genderKey(ReplyGender gender) =>
      gender == ReplyGender.female ? 'f' : 'm';

  static ReplyGender? _gender(Object? value) => switch (value) {
        'm' => ReplyGender.male,
        'f' => ReplyGender.female,
        _ => null,
      };

  /// Поля для `settings.json`. Пишутся и прежние ключи (`assistant_mode`,
  /// `main_persona`, `solo_persona`): прошлая версия приложения прочитает
  /// файл после отката (ADR-016).
  Map<String, Object?> toJson() => <String, Object?>{
        'team_mode': teamMode.name,
        'duo_helper': duoHelper,
        // Только переименованные: встроенное имя в файле читалось бы как
        // переименование, если встроенное когда-нибудь поменяется.
        'persona_names': <String, String>{
          for (final persona in Personas.all)
            if (names[persona.id] case final String name) persona.id: name,
        },
        'persona_genders': <String, String>{
          for (final persona in Personas.all)
            if (persona.id != Personas.sado.id || sadoGenderChosen)
              persona.id: _genderKey(genderOf(persona.id)),
        },
        'duty_extensions': dutyExtensions,
        'duty_notifications': dutyNotifications,
        'persona_styles': <String, String>{
          for (final key in styles.keys.toList()..sort()) key: styles[key]!,
        },
        'assistant_mode': teamMode == TeamMode.solo ? 'solo' : 'duo',
        'main_persona': legacyMainPersona ?? Personas.liorio.id,
        'solo_persona': legacySoloPersona ?? Personas.liorio.id,
        'address': address == ReplyAddress.formal ? 'vy' : 'ty',
        'emoji': emoji,
        'jokes': jokes.name,
      };

  /// Неизвестные и битые значения — по умолчанию, как у остальных
  /// настроек: испорченный файл не мешает запуску.
  ///
  /// Файл прежней версии (нет `team_mode`): дуэт Лиорио + Нода или ключа
  /// нет — Трио; соло — Соло, всё делает Садо. Садо получает стиль
  /// прежнего отвечающего. `role_owners` в обязанности не переносится
  /// (ADR-016).
  factory PersonaSettings.fromJson(Map<String, Object?> json) {
    String? legacy(Object? value) =>
        value is String && value.length <= 32 ? value : null;
    bool helper(Object? value) =>
        value is String && Personas.helperIds.contains(value);
    String? validStyle(Object? value) =>
        value is String && ReplyFormat.stylePattern.hasMatch(value)
            ? value
            : null;

    final styles = <String, String>{...defaultStyles};
    final rawStyles = json['persona_styles'];
    if (rawStyles is Map) {
      for (final MapEntry(:key, :value) in rawStyles.entries) {
        final style = validStyle(value);
        if (key is String && Personas.byId(key) != null && style != null) {
          styles[key] = style;
        }
      }
    }

    final TeamMode teamMode;
    if (json.containsKey('team_mode')) {
      teamMode = TeamMode.values
              .where((TeamMode m) => m.name == json['team_mode'])
              .firstOrNull ??
          TeamMode.trio;
    } else {
      // Переход с прежних настроек: Садо говорит, как прежний отвечающий.
      final solo = json['assistant_mode'] == 'solo';
      teamMode = solo ? TeamMode.solo : TeamMode.trio;
      // Прежний отвечающий: неизвестный id читался как Лиорио.
      final raw = json[solo ? 'solo_persona' : 'main_persona'];
      final previous = raw is String && Personas.helperIds.contains(raw)
          ? raw
          : Personas.liorio.id;
      styles[Personas.sado.id] = styles[previous] ?? ReplyStyles.neutral;
    }

    final genders = <String, ReplyGender>{};
    final rawGenders = json['persona_genders'];
    if (rawGenders is Map) {
      for (final persona in Personas.all) {
        final gender = _gender(rawGenders[persona.id]);
        if (gender != null) genders[persona.id] = gender;
      }
    }

    // Имена. Каждое проверяется против состава из всех остальных
    // имён файла (а не встроенных): так файл читается в том же виде, в
    // каком его принял экран, даже после обмена именами через третье
    // («Садо» → «Мира», «Нода» → «Садо», «Садо» → «Нода»). Неверное
    // (пустое, «склад», имя другого помощника) отбрасывается — помощник
    // со встроенным именем; проверка повторяется, пока что-то
    // отбрасывается: встроенное имя могло совпасть с чужим.
    final names = <String, String>{};
    final rawNames = json['persona_names'];
    if (rawNames is Map) {
      for (final persona in Personas.all) {
        final raw = rawNames[persona.id];
        if (raw is! String) continue;
        final name = raw.trim();
        if (Persona.fold(name) == Persona.fold(persona.russianName)) continue;
        // Само по себе неверное («склад», пусто, пробелы) — сразу мимо:
        // остальные помощники здесь с именами, которые ни с чем не
        // совпадут.
        final alone = PersonaSettings(
          names: <String, String>{
            for (final other in Personas.all)
              other.id: other.id == persona.id ? name : 'Ъ',
          },
        ).cast;
        if (PersonaNames.validate(name, persona.id, alone) != null) continue;
        names[persona.id] = name;
      }
      // Остались совпадения с чужими именами.
      while (true) {
        final cast = PersonaSettings(names: names).cast;
        // Отбрасывается по одному, с конца (Нода, Лиорио, Садо): из двух
        // одинаковых имён остаётся первое.
        final invalid = <String>[
          for (final persona in Personas.all)
            if (names[persona.id] case final String name)
              if (PersonaNames.validate(name, persona.id, cast) != null)
                persona.id,
        ];
        if (invalid.isEmpty) break;
        names.remove(invalid.last);
      }
    }

    final address = json['address'];
    final emoji = json['emoji'];
    final jokes = JokeFrequency.values
        .where((JokeFrequency j) => j.name == json['jokes'])
        .firstOrNull;
    return PersonaSettings(
      teamMode: teamMode,
      duoHelper: helper(json['duo_helper'])
          ? json['duo_helper']! as String
          : Personas.liorio.id,
      names: Map<String, String>.unmodifiable(names),
      genders: Map<String, ReplyGender>.unmodifiable(genders),
      dutyExtensions: helper(json['duty_extensions'])
          ? json['duty_extensions']! as String
          : Personas.liorio.id,
      dutyNotifications: helper(json['duty_notifications'])
          ? json['duty_notifications']! as String
          : Personas.noda.id,
      styles: Map<String, String>.unmodifiable(styles),
      address: address == 'ty' ? ReplyAddress.informal : ReplyAddress.formal,
      emoji: emoji is! bool || emoji,
      jokes: jokes ?? JokeFrequency.rare,
      legacyMainPersona: legacy(json['main_persona']),
      legacySoloPersona: legacy(json['solo_persona']),
    );
  }

  static bool _sameMap<K, V>(Map<K, V> a, Map<K, V> b) =>
      a.length == b.length &&
      a.entries.every((MapEntry<K, V> e) => b[e.key] == e.value);

  @override
  bool operator ==(Object other) =>
      other is PersonaSettings &&
      other.teamMode == teamMode &&
      other.duoHelper == duoHelper &&
      other.dutyExtensions == dutyExtensions &&
      other.dutyNotifications == dutyNotifications &&
      other.address == address &&
      other.emoji == emoji &&
      other.jokes == jokes &&
      Personas.all.every(
        (Persona p) =>
            other.nameOf(p.id) == nameOf(p.id) &&
            other.genderOf(p.id) == genderOf(p.id),
      ) &&
      other.sadoGenderChosen == sadoGenderChosen &&
      _sameMap(other.styles, styles);

  @override
  int get hashCode => Object.hash(
        teamMode,
        duoHelper,
        dutyExtensions,
        dutyNotifications,
        address,
        emoji,
        jokes,
        Object.hashAll(
          Personas.all.map((Persona p) => '${nameOf(p.id)}:${genderOf(p.id)}'),
        ),
        sadoGenderChosen,
        Object.hashAllUnordered(
          styles.entries
              .map((MapEntry<String, String> e) => '${e.key}=${e.value}'),
        ),
      );
}

/// Просьба изменить настройки помощников из разговора или с экрана:
/// «говори короче», «давай на ты», «включи трио» (навык «Беседа»).
///
/// Это изменение, а не готовые настройки: интерфейс применяет его к своим
/// текущим настройкам тем же путём, что и экран настроек, поэтому
/// перемены, сделанные во время ответа, не теряются.
final class PersonaSettingsChange {
  const PersonaSettingsChange({
    this.stylePersona,
    this.style,
    this.address,
    this.emoji,
    this.jokes,
    this.teamMode,
    this.duoHelper,
    this.names,
    this.genders,
    this.duties,
  }) : assert(
          (stylePersona == null) == (style == null),
          'Стиль меняется у конкретного помощника',
        );

  /// Чей стиль меняется: id из [Personas].
  final String? stylePersona;

  /// Новый стиль помощника [stylePersona].
  final String? style;

  final ReplyAddress? address;
  final bool? emoji;
  final JokeFrequency? jokes;

  /// Новый режим: Соло, Дуэт, Трио.
  final TeamMode? teamMode;

  /// Новый помощник Садо в Дуэте.
  final String? duoHelper;

  /// Новые имена: id → имя. Остальные как были.
  final Map<String, String>? names;

  /// Новый род: id → род. Остальные как были.
  final Map<String, ReplyGender>? genders;

  /// Кто ведёт обязанности: обязанность → id. Остальные как были.
  final Map<PersonaDuty, String>? duties;

  /// [settings] с этим изменением; остальное как было.
  PersonaSettings apply(PersonaSettings settings) {
    var result = settings.copyWith(
      address: address,
      emoji: emoji,
      jokes: jokes,
      teamMode: teamMode,
      duoHelper: duoHelper,
    );
    for (final MapEntry(:key, :value)
        in (names ?? const <String, String>{}).entries) {
      result = result.withName(key, value);
    }
    for (final MapEntry(:key, :value)
        in (genders ?? const <String, ReplyGender>{}).entries) {
      result = result.withGender(key, value);
    }
    for (final MapEntry(:key, :value)
        in (duties ?? const <PersonaDuty, String>{}).entries) {
      result = result.withDuty(key, value);
    }
    final persona = stylePersona;
    final newStyle = style;
    if (persona != null && newStyle != null) {
      result = result.withStyle(persona, newStyle);
    }
    return result;
  }

  /// Ничего не меняет в [settings]: «и так на ты».
  bool isNoOpFor(PersonaSettings settings) => apply(settings) == settings;
}
