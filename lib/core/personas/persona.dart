import '../replies/reply_library.dart';

/// Личность помощника: Rio или Noda (docs/PLANS.md, «Rio и Noda»).
///
/// Данные и коннекторы у них общие; различаются имя, род, цвет и стиль
/// общения.
final class Persona {
  const Persona({
    required this.id,
    required this.name,
    required this.russianName,
    required this.gender,
    required this.accentColor,
    required this.description,
  });

  /// Постоянный id латиницей: `rio`, `noda`. Хранится в настройках и в
  /// истории чата.
  final String id;

  /// Имя в интерфейсе: «Rio».
  final String name;

  /// Имя кириллицей: «Рио». По нему тоже можно обратиться.
  final String russianName;

  /// Род, в котором помощник говорит о себе: «добавил» или «добавила».
  final ReplyGender gender;

  /// Цвет метки у ответов, ARGB. Ядро без Flutter: цвет — число.
  final int accentColor;

  /// Одна строка для настроек.
  final String description;

  /// Буква на метке у ответа.
  String get initial => name.substring(0, 1);
}

/// Встроенные личности.
abstract final class Personas {
  static const Persona rio = Persona(
    id: 'rio',
    name: 'Rio',
    russianName: 'Рио',
    gender: ReplyGender.male,
    accentColor: 0xFF8FB3D9,
    description: 'Спокойный и собранный, говорит о себе в мужском роде.',
  );

  static const Persona noda = Persona(
    id: 'noda',
    name: 'Noda',
    russianName: 'Нода',
    gender: ReplyGender.female,
    accentColor: 0xFFD9A3C4,
    description: 'Живая и внимательная, говорит о себе в женском роде.',
  );

  static const List<Persona> all = <Persona>[rio, noda];

  /// Личность по id; неизвестный id — `null`.
  static Persona? byId(String? id) =>
      all.where((Persona p) => p.id == id).firstOrNull;

  /// Вторая личность пары.
  static Persona other(Persona persona) => persona.id == rio.id ? noda : rio;
}

/// Как помощники делят работу.
enum AssistantMode {
  /// Основной отвечает на всё по умолчанию, второй пишет первым:
  /// напоминания и уведомления. Написать можно любому.
  duo,

  /// Один помощник на всё.
  solo,
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
/// ничего, кроме того, как говорит помощник, не меняют.
final class PersonaSettings {
  const PersonaSettings({
    this.mode = AssistantMode.duo,
    this.mainPersona = 'rio',
    this.soloPersona = 'rio',
    this.styles = defaultStyles,
    this.address = ReplyAddress.formal,
    this.emoji = true,
    this.jokes = JokeFrequency.rare,
  });

  /// По умолчанию Rio говорит нейтрально, Noda — дружески.
  static const Map<String, String> defaultStyles = <String, String>{
    'rio': ReplyStyles.neutral,
    'noda': ReplyStyles.friendly,
  };

  final AssistantMode mode;

  /// Основной помощник в дуэте: id из [Personas].
  final String mainPersona;

  /// Кто отвечает в соло.
  final String soloPersona;

  /// Стиль каждого помощника: id личности → id стиля (встроенного или
  /// пака ответов).
  final Map<String, String> styles;

  /// «Вы» или «ты» — общее для обоих.
  final ReplyAddress address;

  /// Эмодзи разрешены; пользуется ли ими стиль — решает стиль.
  final bool emoji;

  final JokeFrequency jokes;

  /// Основной в дуэте (неизвестный id — Rio).
  Persona get main => Personas.byId(mainPersona) ?? Personas.rio;

  /// Отвечающий в соло (неизвестный id — Rio).
  Persona get solo => Personas.byId(soloPersona) ?? Personas.rio;

  /// Кто отвечает, если к помощнику не обратились по имени.
  Persona get responder => mode == AssistantMode.duo ? main : solo;

  /// Кто пишет первым: второй в дуэте, единственный в соло.
  Persona get notifier =>
      mode == AssistantMode.duo ? Personas.other(main) : solo;

  String styleOf(Persona persona) =>
      styles[persona.id] ?? defaultStyles[persona.id] ?? ReplyStyles.neutral;

  /// Голос [persona]: стиль, род, обращение, эмодзи.
  ReplyVoice voiceOf(Persona persona) => ReplyVoice(
        style: styleOf(persona),
        gender: persona.gender,
        address: address,
        emoji: emoji,
      );

  PersonaSettings copyWith({
    AssistantMode? mode,
    String? mainPersona,
    String? soloPersona,
    Map<String, String>? styles,
    ReplyAddress? address,
    bool? emoji,
    JokeFrequency? jokes,
  }) =>
      PersonaSettings(
        mode: mode ?? this.mode,
        mainPersona: mainPersona ?? this.mainPersona,
        soloPersona: soloPersona ?? this.soloPersona,
        styles: styles ?? this.styles,
        address: address ?? this.address,
        emoji: emoji ?? this.emoji,
        jokes: jokes ?? this.jokes,
      );

  /// Стиль одного помощника.
  PersonaSettings withStyle(String personaId, String style) =>
      copyWith(styles: <String, String>{...styles, personaId: style});

  /// Поля для `settings.json`.
  Map<String, Object?> toJson() => <String, Object?>{
        'assistant_mode': mode.name,
        'main_persona': mainPersona,
        'solo_persona': soloPersona,
        'persona_styles': <String, String>{
          for (final key in styles.keys.toList()..sort()) key: styles[key]!,
        },
        'address': address == ReplyAddress.formal ? 'vy' : 'ty',
        'emoji': emoji,
        'jokes': jokes.name,
      };

  /// Неизвестные и битые значения — по умолчанию, как у остальных
  /// настроек: испорченный файл не мешает запуску.
  factory PersonaSettings.fromJson(Map<String, Object?> json) {
    final mode = AssistantMode.values
        .where((AssistantMode m) => m.name == json['assistant_mode'])
        .firstOrNull;
    String persona(Object? value) =>
        value is String && Personas.byId(value) != null ? value : 'rio';
    final styles = <String, String>{...defaultStyles};
    final rawStyles = json['persona_styles'];
    if (rawStyles is Map) {
      for (final MapEntry(:key, :value) in rawStyles.entries) {
        if (key is String &&
            Personas.byId(key) != null &&
            value is String &&
            ReplyFormat.stylePattern.hasMatch(value)) {
          styles[key] = value;
        }
      }
    }
    final address = json['address'];
    final emoji = json['emoji'];
    final jokes = JokeFrequency.values
        .where((JokeFrequency j) => j.name == json['jokes'])
        .firstOrNull;
    return PersonaSettings(
      mode: mode ?? AssistantMode.duo,
      mainPersona: persona(json['main_persona']),
      soloPersona: persona(json['solo_persona']),
      styles: Map<String, String>.unmodifiable(styles),
      address: address == 'ty' ? ReplyAddress.informal : ReplyAddress.formal,
      emoji: emoji is! bool || emoji,
      jokes: jokes ?? JokeFrequency.rare,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PersonaSettings &&
      other.mode == mode &&
      other.mainPersona == mainPersona &&
      other.soloPersona == soloPersona &&
      other.address == address &&
      other.emoji == emoji &&
      other.jokes == jokes &&
      other.styles.length == styles.length &&
      styles.entries.every(
        (MapEntry<String, String> e) => other.styles[e.key] == e.value,
      );

  @override
  int get hashCode => Object.hash(
        mode,
        mainPersona,
        soloPersona,
        address,
        emoji,
        jokes,
        Object.hashAllUnordered(
          styles.entries
              .map((MapEntry<String, String> e) => '${e.key}=${e.value}'),
        ),
      );
}

/// Просьба изменить настройки помощников из разговора: «говори короче»,
/// «давай на ты», «Noda, будь основной» (навык «Беседа»).
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
    this.mainPersona,
    this.soloPersona,
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

  /// Новый основной в дуэте.
  final String? mainPersona;

  /// Новый отвечающий в соло.
  final String? soloPersona;

  /// [settings] с этим изменением; остальное как было.
  PersonaSettings apply(PersonaSettings settings) {
    var result = settings.copyWith(
      address: address,
      emoji: emoji,
      jokes: jokes,
      mainPersona: mainPersona,
      soloPersona: soloPersona,
    );
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
