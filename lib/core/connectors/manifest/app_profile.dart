import '../../commands/command_suggest.dart';
import '../../personas/persona.dart';
import '../../personas/persona_names.dart';

/// Род имени приложения: согласование «ответил / ответила / ответило /
/// ответили» и «его / её / их» (ADR-039).
enum AppGender {
  m,
  f,
  n,
  pl;

  static AppGender? parse(Object? value) => switch (value) {
        'm' => AppGender.m,
        'f' => AppGender.f,
        'n' => AppGender.n,
        'pl' => AppGender.pl,
        _ => null,
      };
}

/// Шесть падежей имени приложения: «автосервис», «автосервиса»,
/// «автосервису», «автосервис», «автосервисом», «автосервисе». Только
/// готовые строки из описания: «Tridot» имена не склоняет.
final class NameForms {
  const NameForms({
    required this.nom,
    required this.gen,
    required this.dat,
    required this.acc,
    required this.ins,
    required this.prep,
  });

  /// Несклоняемое имя: все падежи одинаковые («CRM»).
  const NameForms.same(String name)
      : nom = name,
        gen = name,
        dat = name,
        acc = name,
        ins = name,
        prep = name;

  final String nom;
  final String gen;
  final String dat;
  final String acc;
  final String ins;
  final String prep;

  static const List<String> keys = <String>[
    'nom',
    'gen',
    'dat',
    'acc',
    'ins',
    'prep',
  ];

  List<String> get all => <String>[nom, gen, dat, acc, ins, prep];
}

/// Профиль приложения из необязательных полей `app` описания
/// `assistant/1` (ADR-039): как его называть и как к нему обращаться.
/// Из него собирается слот приложения, которого нет в коде
/// (`ConnectionSlot.generic`).
///
/// Значения — недоверенные данные сервера. Поэтому в них только буквы
/// (кириллица и латиница), цифры, пробел, дефис и «»: синтаксис шаблонов
/// ответов (`{`, `|`, `}`) в них невозможен, и тексты ответов собираются из
/// них готовыми строками. Плохое необязательное поле отбрасывается с
/// предупреждением, описание целиком из-за него не отклоняется.
final class AppProfile {
  const AppProfile({
    required this.appId,
    required this.name,
    this.forms,
    this.inPhrase,
    this.gender,
    this.addressing = const <String>[],
  });

  /// `app.id` описания: `severauto`.
  final String appId;

  /// Короткое имя: «автосервис», «CRM».
  final String name;

  /// Падежи; `null` — имя несклоняемое.
  final NameForms? forms;

  /// Готовое «в автосервисе» / «на складе»: предлог зависит от слова, его
  /// не угадываем. `null` — в описании нет.
  final String? inPhrase;

  /// Род; учитывается только вместе с [forms].
  final AppGender? gender;

  /// Как к приложению обращаются: «сервис», «автосервис».
  final List<String> addressing;

  /// Имя склоняется ([forms] есть).
  bool get declinable => forms != null;

  /// Падежи для текстов: свои или несклоняемое имя.
  NameForms get cases => forms ?? NameForms.same(name);

  /// Пределы «Tridot».
  static const int maxLength = 40;
  static const int maxAddressing = 8;

  /// Допустимые знаки значения: буквы кириллицы и латиницы, цифры, пробел,
  /// дефис и «».
  static final RegExp _allowed = RegExp(r'^[A-Za-zА-Яа-яЁё0-9 «»-]+$');
  static final RegExp _letter = RegExp('[A-Za-zА-Яа-яЁё]');
  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _appId = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  /// Предлоги, с которых начинается [inPhrase].
  static const List<String> _prepositions = <String>['в', 'во', 'на'];

  /// Названия навыков «Tridot»: обращение к приложению ими не бывает.
  static const Set<String> _skillWords = <String>{
    'задачи',
    'задача',
    'беседа',
    'калькулятор',
    'пароли',
    'погода',
    'файлы',
    'будильник',
    'архиватор',
    'конвертер',
    'данные',
    'загрузчик',
    'помощник',
    'помощники',
    'tridot',
    'тридот',
  };

  /// Значение годится: непустое, не длиннее [maxLength], только
  /// допустимые знаки и хотя бы одна буква.
  static bool isSafe(String value) =>
      value.isNotEmpty &&
      value.length <= maxLength &&
      _allowed.hasMatch(value) &&
      _letter.hasMatch(value);

  /// Слово занято: обращение к навыку или подключению «Tridot», имя
  /// помощника, обычное начало фразы. [taken] — обращения уже
  /// подключённых приложений.
  static bool isReserved(String value, {Set<String> taken = const {}}) {
    final folded = Persona.fold(value.trim());
    if (folded.isEmpty) return true;
    if (_skillWords.contains(folded)) return true;
    if (PersonaNames.connectorWords.contains(folded)) return true;
    if (PersonaNames.isPhraseWord(folded)) return true;
    if (taken.map(Persona.fold).contains(folded)) return true;
    for (final persona in Personas.all) {
      if (persona.nameForms.contains(folded)) return true;
    }
    if (Personas.byNameForm(folded) != null) return true;
    // «на складе»: обращение из двух слов — по последнему слову тоже.
    final words = folded.split(' ');
    if (words.length == 2 && _prepositions.contains(words.first)) {
      return isReserved(words.last, taken: taken);
    }
    return false;
  }

  /// Пароль, PIN, код, логин и похожее: такие слова не попадают ни в
  /// обращения, ни в имя.
  static bool isPrivate(String value) => CommandSuggester.isPrivate(value);

  /// Профиль из объекта `app` описания и предупреждения о полях, которые
  /// отброшены. Профиля нет (`null`), если нет годного `app.id` или
  /// `app.name`. [taken] — обращения уже подключённых приложений.
  static ({AppProfile? profile, List<String> warnings}) parse(
    Object? app, {
    Set<String> taken = const <String>{},
  }) {
    final warnings = <String>[];
    if (app is! Map) return (profile: null, warnings: warnings);
    final id = app['id'];
    final rawName = app['name'];
    if (rawName == null) return (profile: null, warnings: warnings);
    if (id is! String || !_appId.hasMatch(id)) {
      warnings.add('app.name: без годного app.id профиля нет');
      return (profile: null, warnings: warnings);
    }
    final name = _clean(rawName);
    if (name == null) {
      warnings.add('app.name: только буквы, цифры, пробел, дефис и «», '
          'не длиннее $maxLength знаков — профиль не принят');
      return (profile: null, warnings: warnings);
    }
    if (isPrivate(name) || isReserved(name, taken: taken)) {
      warnings.add('app.name: «$name» занято или похоже на секрет — '
          'профиль не принят');
      return (profile: null, warnings: warnings);
    }

    NameForms? forms;
    final rawForms = app['forms'];
    if (rawForms != null) {
      forms = _forms(rawForms, name);
      if (forms == null) {
        warnings.add('app.forms: нужны шесть падежей (nom, gen, dat, acc, '
            'ins, prep) из допустимых знаков, nom — как app.name; имя '
            'считается несклоняемым');
      }
    }

    AppGender? gender;
    final rawGender = app['gender'];
    if (rawGender != null) {
      gender = AppGender.parse(rawGender);
      if (gender == null) warnings.add('app.gender: только m, f, n или pl');
    }

    String? inPhrase;
    final rawIn = app['in'];
    if (rawIn != null) {
      inPhrase = _inPhrase(rawIn, forms);
      if (inPhrase == null) {
        warnings.add('app.in: предлог («в», «во», «на») и имя'
            '${forms == null ? '' : ' в предложном падеже'}');
      } else if (isPrivate(inPhrase) || isReserved(inPhrase, taken: taken)) {
        warnings.add('app.in: «$inPhrase» занято или похоже на секрет');
        inPhrase = null;
      }
    }

    final addressing = <String>[];
    final rawAddressing = app['addressing'];
    if (rawAddressing != null && rawAddressing is! List) {
      warnings.add('app.addressing: нужен список слов');
    }
    if (rawAddressing is List) {
      for (final raw in rawAddressing) {
        final word = _clean(raw);
        if (word == null) {
          warnings.add('app.addressing: «$raw» — только буквы, цифры, '
              'пробел, дефис и «»');
          continue;
        }
        if (isPrivate(word)) {
          warnings.add('app.addressing: «$word» похоже на секрет');
          continue;
        }
        if (isReserved(word, taken: taken)) {
          warnings.add('app.addressing: «$word» занято навыком, помощником '
              'или другим подключением');
          continue;
        }
        final folded = Persona.fold(word);
        if (addressing.map(Persona.fold).contains(folded)) continue;
        if (addressing.length == maxAddressing) {
          warnings.add('app.addressing: слов больше $maxAddressing — '
              'лишние отброшены');
          break;
        }
        addressing.add(word);
      }
    }

    return (
      profile: AppProfile(
        appId: id,
        name: name,
        forms: forms,
        inPhrase: inPhrase,
        gender: gender,
        addressing: List<String>.unmodifiable(addressing),
      ),
      warnings: warnings,
    );
  }

  /// Значение без лишних пробелов или `null`, если оно не годится.
  static String? _clean(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim().replaceAll(_spaces, ' ');
    return isSafe(value) ? value : null;
  }

  static NameForms? _forms(Object? raw, String name) {
    if (raw is! Map) return null;
    final values = <String, String>{};
    for (final key in NameForms.keys) {
      final value = _clean(raw[key]);
      if (value == null || isPrivate(value)) return null;
      values[key] = value;
    }
    if (Persona.fold(values['nom']!) != Persona.fold(name)) return null;
    return NameForms(
      nom: name,
      gen: values['gen']!,
      dat: values['dat']!,
      acc: values['acc']!,
      ins: values['ins']!,
      prep: values['prep']!,
    );
  }

  static String? _inPhrase(Object? raw, NameForms? forms) {
    final value = _clean(raw);
    if (value == null) return null;
    final space = value.indexOf(' ');
    if (space < 0) return null;
    final preposition = value.substring(0, space).toLowerCase();
    if (!_prepositions.contains(preposition)) return null;
    final rest = value.substring(space + 1);
    if (!_letter.hasMatch(rest)) return null;
    if (forms != null && Persona.fold(rest) != Persona.fold(forms.prep)) {
      return null;
    }
    return '$preposition $rest';
  }
}
