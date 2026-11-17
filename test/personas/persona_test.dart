import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/personas/persona_names.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';

void main() {
  setUp(PersonaCast.resetForTest);
  tearDown(PersonaCast.resetForTest);

  group('обращение по имени', () {
    for (final (text, persona, rest) in <(String, String, String)>[
      ('Noda, покажи задачи', 'noda', 'покажи задачи'),
      ('нода, покажи задачи', 'noda', 'покажи задачи'),
      ('НОДА: добавь задачу купить хлеб', 'noda', 'добавь задачу купить хлеб'),
      ('Нода — сколько будет 2+2', 'noda', 'сколько будет 2+2'),
      ('Noda - покажи задачи', 'noda', 'покажи задачи'),
      ('Liorio покажи задачи', 'rio', 'покажи задачи'),
      ('Лиорио, перенеси её на завтра', 'rio', 'перенеси её на завтра'),
      ('  liorio:покажи', 'rio', 'покажи'),
      ('Нода', 'noda', ''),
      ('Liorio,', 'rio', ''),
      ('Noda!', 'noda', ''),
      ('Нода.', 'noda', ''),
      ('Noda?', 'noda', ''),
      ('Noda;2+2', 'noda', '2+2'),
      ('Лиорио! покажи задачи', 'rio', 'покажи задачи'),
      ('Нода… сколько будет 2+2', 'noda', 'сколько будет 2+2'),
      // Краткое имя Liorio и другие имена Noda.
      ('Лио, покажи задачи', 'rio', 'покажи задачи'),
      ('лио: 2+2', 'rio', '2+2'),
      ('LIO — покажи задачи', 'rio', 'покажи задачи'),
      ('Lio покажи задачи', 'rio', 'покажи задачи'),
      ('Лио!', 'rio', ''),
      ('Лио', 'rio', ''),
      ('лиорио - сколько будет 2+2', 'rio', 'сколько будет 2+2'),
      ('Нодочка, покажи задачи', 'noda', 'покажи задачи'),
      ('нодочка: 2+2', 'noda', '2+2'),
      ('Нодь, покажи задачи', 'noda', 'покажи задачи'),
      ('НОДЬ! 2+2', 'noda', '2+2'),
      ('нодь покажи задачи', 'noda', 'покажи задачи'),
      ('Нодь?', 'noda', ''),
      // Связной — главный: к нему тоже можно обратиться.
      ('Связной, привет', 'sado', 'привет'),
      ('связной: добавь задачу хлеб', 'sado', 'добавь задачу хлеб'),
      ('Svyaznoy — 2+2', 'sado', '2+2'),
      // Встроенное имя другого рода — тоже обращение (ADR-017).
      ('Связная, покажи задачи', 'sado', 'покажи задачи'),
      ('СВЯЗНАЯ! 2+2', 'sado', '2+2'),
    ]) {
      test(text, () {
        final addressing = PersonaAddressing.parse(text);
        expect(addressing, isNotNull);
        expect(addressing!.persona.id, persona);
        expect(addressing.rest, rest);
      });
    }

    for (final text in <String>[
      // Прежнее имя и город — просто текст.
      'Рио-де-Жанейро — купить билеты',
      'Рио де Жанейро красивый город',
      'Рио  де Жанейро',
      'Рио, покажи задачи',
      'Rio, покажи задачи',
      'rio:покажи',
      // Слова, которые только начинаются с имени.
      'Лион — красивый город',
      'Лиона, привет',
      'лиорион, привет',
      'Лио-Лио',
      'Lion, покажи',
      'Нодаа, привет',
      'Нодальный анализ',
      'нодьа, привет',
      'Нодочкин, привет',
      'Riot покажи',
      'Садовник, привет',
      'Садовое кольцо',
      // Имя в середине фразы и косвенный падеж.
      'Купить билет в Лиорио',
      'Ноду покажи',
      'Добавь задачу «Noda, позвонить»',
      '',
    ]) {
      test('не обращение: «$text»', () {
        expect(PersonaAddressing.parse(text), isNull);
      });
    }
  });

  group('сообщение без обращения', () {
    for (final (text, rest) in <(String, String)>[
      ('Лиорио, запри пароли', 'запри пароли'),
      ('лиорио какой логин от вк', 'какой логин от вк'),
      ('выкинь запись, Лиорио', 'выкинь запись'),
      (
        'новый пароль от сбера, Лиорио, записать его куда?',
        'новый пароль от сбера, записать его куда?',
      ),
      ('Нода, привет, Лио, пока', 'привет, пока'),
      // Не обращение: часть слова, имя без запятых в середине, одно имя.
      ('Лион — красивый город', 'Лион — красивый город'),
      ('пусть отвечает Лио', 'пусть отвечает Лио'),
      ('Лиорио', 'Лиорио'),
    ]) {
      test(text, () {
        expect(PersonaAddressing.withoutAddress(text), rest);
      });
    }
  });

  group('обращение в конце', () {
    for (final (text, persona, rest) in <(String, String, String)>[
      ('да, Лиорио', 'rio', 'да'),
      ('спасибо, Нода!', 'noda', 'спасибо'),
      ('нет — Noda', 'noda', 'нет'),
      ('да - лиорио.', 'rio', 'да'),
      ('да, Лио', 'rio', 'да'),
      ('спасибо, lio!', 'rio', 'спасибо'),
      ('нет — Liorio', 'rio', 'нет'),
      ('спасибо, Нодочка', 'noda', 'спасибо'),
      ('да, нодь!', 'noda', 'да'),
    ]) {
      test(text, () {
        final addressing = PersonaAddressing.parseTrailing(text);
        expect(addressing, isNotNull);
        expect(addressing!.persona.id, persona);
        expect(addressing.rest, rest);
      });
    }

    for (final text in <String>[
      'съездить в Лиорио',
      'съездить в Лион',
      'Лиорио',
      'Лио',
      ', Нода',
      'да, Лиорио?',
      'да, Нодаа',
      'да, Лион',
      'да, Нодальный',
      'да, Рио',
      'да, Rio',
      'да, Рио-де-Жанейро',
      'спасибо Лио',
    ]) {
      test('не обращение: «$text»', () {
        expect(PersonaAddressing.parseTrailing(text), isNull);
      });
    }
  });

  group('переименование', () {
    test('новое имя — обращение, прежнее — просто текст', () {
      PersonaCast.configure(
        const PersonaSettings(names: <String, String>{'noda': 'Мира'}),
      );
      final addressing = PersonaAddressing.parse('Мира, покажи задачи');
      expect(addressing!.persona.id, 'noda');
      expect(addressing.persona.russianName, 'Мира');
      expect(addressing.persona.initial, 'М');
      expect(addressing.rest, 'покажи задачи');
      expect(PersonaAddressing.parse('Нода, покажи задачи'), isNull);
      expect(PersonaAddressing.parse('Нодочка, покажи задачи'), isNull);
      expect(
        PersonaAddressing.parseTrailing('спасибо, Мира')!.persona.id,
        'noda',
      );
      expect(
        PersonaAddressing.withoutAddress('Мира, привет, Лио, пока'),
        'привет, пока',
      );
      // Лиорио не переименован: его формы на месте.
      expect(PersonaAddressing.parse('Лио, 2+2')!.persona.id, 'rio');
    });

    test('«ё» и «е» в имени — одна буква', () {
      PersonaCast.configure(
        const PersonaSettings(names: <String, String>{'noda': 'Алёна'}),
      );
      for (final text in <String>[
        'Алёна, привет',
        'Алена, привет',
        'АЛЕНА, привет',
      ]) {
        final addressing = PersonaAddressing.parse(text);
        expect(addressing?.persona.id, 'noda', reason: text);
        expect(addressing!.rest, 'привет');
      }
      expect(
        PersonaAddressing.parseTrailing('спасибо, Алена')!.persona.id,
        'noda',
      );
      expect(Personas.byAddressName('Алена')!.id, 'noda');
      expect(Personas.byNameForm('алёна')!.id, 'noda');
    });

    test('обращение снимается перед разбором команды', () {
      expect(
        PersonaAddressing.commandText('Связной, добавь задачу хлеб'),
        'добавь задачу хлеб',
      );
      expect(PersonaAddressing.commandText('Связной'), 'Связной');
      expect(
        PersonaAddressing.commandText('добавь задачу хлеб'),
        'добавь задачу хлеб',
      );
    });

    test('имя с другим регистром', () {
      PersonaCast.configure(
        const PersonaSettings(names: <String, String>{'rio': 'лиорио'}),
      );
      // То же имя в другом регистре — прежний помощник со всеми формами.
      expect(PersonaAddressing.parse('Лио, 2+2')!.persona.id, 'rio');
    });

    test('версия растёт только при смене имён', () {
      final before = PersonaCast.version;
      PersonaCast.configure(const PersonaSettings(teamMode: TeamMode.solo));
      expect(PersonaCast.version, before);
      PersonaCast.configure(
        const PersonaSettings(names: <String, String>{'rio': 'Тим'}),
      );
      expect(PersonaCast.version, before + 1);
      expect(Personas.byAddressName('тим')!.id, 'rio');
      expect(Personas.byNameForm('ноду')!.id, 'noda');
      PersonaCast.resetForTest();
      expect(PersonaCast.version, before + 2);
      expect(Personas.byAddressName('тим'), isNull);
    });
  });

  group('состав и обязанности', () {
    test('по умолчанию: Трио, обязанности у Лиорио и Ноды', () {
      const settings = PersonaSettings();
      final cast = settings.cast;
      expect(settings.teamMode, TeamMode.trio);
      expect(cast.members.map((Persona p) => p.id), <String>[
        'sado',
        'rio',
        'noda',
      ]);
      expect(cast.active.map((Persona p) => p.id), <String>[
        'sado',
        'rio',
        'noda',
      ]);
      expect(settings.responder.id, 'sado');
      expect(settings.extensionsLead.id, 'rio');
      expect(settings.notifier.id, 'noda');
      expect(cast.ownerOf(PersonaDuty.main).id, 'sado');
      expect(
        cast.members.map((Persona p) => p.initial),
        <String>['С', 'Л', 'Н'],
      );
      expect(settings.styleOf(Personas.sado), ReplyStyles.neutral);
      expect(settings.styleOf(Personas.liorio), ReplyStyles.neutral);
      expect(settings.styleOf(Personas.noda), ReplyStyles.friendly);
      expect(settings.address, ReplyAddress.formal);
      expect(settings.emoji, isTrue);
      expect(settings.jokes, JokeFrequency.rare);
      expect(settings.genderOf('rio'), ReplyGender.male);
      expect(settings.genderOf('noda'), ReplyGender.female);
      expect(settings.sadoGenderChosen, isFalse);
      expect(
        settings.genderOf('sado'),
        ReplyGender.male,
        reason: 'до выбора каталог склоняет в мужском роде',
      );
    });

    // Режим × помощник дуэта × кто назначен → кто ведёт расширения и
    // оповещения.
    for (final (mode, helper, ext, notes, active, wantExt, wantNotes)
        in <(TeamMode, String, String, String, List<String>, String, String)>[
      (
        TeamMode.trio,
        'rio',
        'rio',
        'noda',
        ['sado', 'rio', 'noda'],
        'rio',
        'noda'
      ),
      (
        TeamMode.trio,
        'noda',
        'noda',
        'rio',
        ['sado', 'rio', 'noda'],
        'noda',
        'rio'
      ),
      (
        TeamMode.trio,
        'rio',
        'noda',
        'noda',
        ['sado', 'rio', 'noda'],
        'noda',
        'noda'
      ),
      (TeamMode.duo, 'rio', 'rio', 'noda', ['sado', 'rio'], 'rio', 'sado'),
      (TeamMode.duo, 'noda', 'rio', 'noda', ['sado', 'noda'], 'sado', 'noda'),
      (TeamMode.duo, 'noda', 'noda', 'noda', ['sado', 'noda'], 'noda', 'noda'),
      (TeamMode.duo, 'rio', 'rio', 'rio', ['sado', 'rio'], 'rio', 'rio'),
      (TeamMode.solo, 'rio', 'rio', 'noda', ['sado'], 'sado', 'sado'),
      (TeamMode.solo, 'noda', 'noda', 'rio', ['sado'], 'sado', 'sado'),
    ]) {
      test('${mode.name}, дуэт с $helper, расширения $ext, оповещения $notes',
          () {
        final settings = PersonaSettings(
          teamMode: mode,
          duoHelper: helper,
          dutyExtensions: ext,
          dutyNotifications: notes,
        );
        final cast = settings.cast;
        expect(cast.active.map((Persona p) => p.id), active);
        expect(cast.ownerOf(PersonaDuty.extensions).id, wantExt);
        expect(cast.ownerOf(PersonaDuty.notifications).id, wantNotes);
        expect(cast.ownerOf(PersonaDuty.main).id, 'sado');
        expect(settings.extensionsLead.id, wantExt);
        expect(settings.notifier.id, wantNotes);
        expect(settings.responder.id, 'sado');
      });
    }

    test('имя и род из настроек; встроенные формы — только у прежнего имени',
        () {
      const settings = PersonaSettings(
        names: <String, String>{'noda': 'Мира', 'sado': 'Ника'},
        genders: <String, ReplyGender>{
          'noda': ReplyGender.male,
          'sado': ReplyGender.female,
        },
      );
      final cast = settings.cast;
      final noda = cast.byId('noda');
      expect(noda.russianName, 'Мира');
      expect(noda.gender, ReplyGender.male);
      expect(noda.addressNames, <String>['мира']);
      // У нового имени — косвенные падежи для просьб беседы («дуэт с
      // Мирой», «сделай Миру основной»), обращением они не считаются.
      expect(
        noda.inflectedForms,
        <String>['миру', 'мире', 'миры', 'мирой', 'мирей'],
      );
      expect(cast.byId('rio').nicknames, <String>['lio', 'лио']);
      expect(settings.voiceOf(Personas.noda).gender, ReplyGender.male);
      expect(settings.voiceOf(Personas.sado).gender, ReplyGender.female);
      expect(settings.sadoGenderChosen, isTrue);
      expect(cast.byId('sado').initial, 'Н');
      expect(settings.nameOf('rio'), 'Лиорио');
      expect(
        settings.withName('noda', 'Нода').names,
        <String, String>{'sado': 'Ника'},
        reason: 'встроенное имя снимает переименование',
      );
    });

    test('изменение: режим, помощник дуэта, имена, род, обязанности, стиль',
        () {
      const change = PersonaSettingsChange(
        teamMode: TeamMode.duo,
        duoHelper: 'noda',
        names: <String, String>{'rio': 'Тим'},
        genders: <String, ReplyGender>{'sado': ReplyGender.female},
        duties: <PersonaDuty, String>{
          PersonaDuty.extensions: 'noda',
          PersonaDuty.main: 'rio',
        },
        stylePersona: 'sado',
        style: ReplyStyles.brief,
      );
      final next = change.apply(const PersonaSettings());
      expect(next.teamMode, TeamMode.duo);
      expect(next.duoHelper, 'noda');
      expect(next.nameOf('rio'), 'Тим');
      expect(next.genderOf('sado'), ReplyGender.female);
      expect(next.dutyExtensions, 'noda');
      expect(next.dutyNotifications, 'noda');
      expect(
        next.cast.ownerOf(PersonaDuty.main).id,
        'sado',
        reason: 'главного не переназначить',
      );
      expect(next.styleOf(Personas.sado), ReplyStyles.brief);
      expect(change.isNoOpFor(next), isTrue);
      expect(
        const PersonaSettingsChange(teamMode: TeamMode.trio)
            .isNoOpFor(const PersonaSettings()),
        isTrue,
      );
    });
  });

  group('настройки помощников', () {
    test('сохраняются и читаются без потерь', () {
      final settings = const AppSettings().copyWith(
        personas: const PersonaSettings(
          teamMode: TeamMode.duo,
          duoHelper: 'noda',
          names: <String, String>{'noda': 'Мира', 'sado': 'Ника'},
          genders: <String, ReplyGender>{
            'sado': ReplyGender.female,
            'rio': ReplyGender.female,
          },
          dutyExtensions: 'noda',
          dutyNotifications: 'rio',
          styles: <String, String>{
            'sado': 'brief',
            'rio': 'business',
            'noda': 'replies.pirate',
          },
          address: ReplyAddress.informal,
          emoji: false,
          jokes: JokeFrequency.off,
        ),
        noticeDay: '2026-11-06',
        firstSeenDay: '2026-10-15',
      );
      final json = jsonDecode(jsonEncode(settings.toJson()));
      final back = AppSettings.fromJson(json as Map<String, dynamic>);
      expect(back.personas, settings.personas);
      expect(back.noticeDay, '2026-11-06');
      expect(back.firstSeenDay, '2026-10-15');
      expect(json['first_seen_day'], '2026-10-15');
      expect(json['address'], 'ty');
      expect(json['team_mode'], 'duo');
      expect(json['duo_helper'], 'noda');
      // Пишутся только переименованные.
      expect(json['persona_names'], <String, Object?>{
        'sado': 'Ника',
        'noda': 'Мира',
      });
      expect(json['persona_genders'], <String, Object?>{
        'sado': 'f',
        'rio': 'f',
        'noda': 'f',
      });
      expect(json['duty_extensions'], 'noda');
      expect(json['duty_notifications'], 'rio');
    });

    test('род Связной не выбран — ключа sado нет, после чтения тоже', () {
      final json = const PersonaSettings().toJson();
      expect(json['persona_genders'], <String, String>{
        'rio': 'm',
        'noda': 'f',
      });
      final back = PersonaSettings.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(back.sadoGenderChosen, isFalse);
      expect(back, const PersonaSettings());
    });

    test('для отката пишутся и прежние ключи', () {
      for (final (mode, legacy) in <(TeamMode, String)>[
        (TeamMode.solo, 'solo'),
        (TeamMode.duo, 'duo'),
        (TeamMode.trio, 'duo'),
      ]) {
        final json = PersonaSettings(teamMode: mode).toJson();
        expect(json['assistant_mode'], legacy, reason: mode.name);
        expect(json['main_persona'], 'rio');
        expect(json['solo_persona'], 'rio');
        expect(
          (json['persona_styles']! as Map<String, String>).keys,
          containsAll(<String>['rio', 'noda']),
        );
      }
    });

    test('прежний отвечающий из файла пишется обратно как был', () {
      // Пользователь прежней версии: соло с Нодой в деловом стиле. Новая
      // версия читает и сохраняет файл, не трогая помощников, — откат
      // должен вернуть ему Ноду, а не Лиорио.
      final legacy = PersonaSettings.fromJson(<String, Object?>{
        'assistant_mode': 'solo',
        'main_persona': 'noda',
        'solo_persona': 'noda',
        'persona_styles': <String, Object?>{'noda': 'business'},
      });
      expect(legacy.teamMode, TeamMode.solo);
      final json = jsonDecode(jsonEncode(legacy.toJson())) as Map;
      expect(json['solo_persona'], 'noda');
      expect(json['main_persona'], 'noda');
      expect((json['persona_styles'] as Map)['noda'], 'business');
      // И после второго круга, и после любой правки настроек.
      final again = PersonaSettings.fromJson(json.cast<String, Object?>())
          .withStyle('sado', 'brief')
          .copyWith(teamMode: TeamMode.trio)
          .toJson();
      expect(again['solo_persona'], 'noda');
      expect(again['main_persona'], 'noda');
    });

    for (final (label, steps) in <(String, List<(String, String)>)>[
      // Лиорио → «Вега», затем Связной → «Лиорио»: экран принимает (имя
      // Лиорио свободно), файл должен прочитаться так же.
      (
        'Связной берёт прежнее имя Лиорио',
        <(String, String)>[
          ('rio', 'Вега'),
          ('sado', 'Лиорио'),
        ]
      ),
      // Обмен через третье имя: Связной → «Мира», Нода → «Связной», Связной →
      // «Нода».
      (
        'Связной и Нода меняются именами',
        <(String, String)>[
          ('sado', 'Мира'),
          ('noda', 'Связной'),
          ('sado', 'Нода'),
        ]
      ),
      (
        'Нода берёт прежнее имя Связной',
        <(String, String)>[
          ('sado', 'Ника'),
          ('noda', 'Связной'),
        ]
      ),
    ]) {
      test('принятые экраном имена читаются из файла без потерь: $label', () {
        var settings = const PersonaSettings();
        for (final (id, name) in steps) {
          expect(
            PersonaNames.validate(name, id, settings.cast),
            isNull,
            reason: 'экран принимает «$name» для $id',
          );
          settings = settings.withName(id, name);
        }
        final json = jsonDecode(jsonEncode(settings.toJson()));
        final back = PersonaSettings.fromJson(json as Map<String, Object?>);
        for (final persona in Personas.all) {
          expect(
            back.nameOf(persona.id),
            settings.nameOf(persona.id),
            reason: persona.id,
          );
        }
        expect(back, settings);
      });
    }

    test('имя в другом регистре — не переименование', () {
      final settings = const PersonaSettings().withName('noda', 'нода');
      expect(settings.names, isEmpty);
      expect(settings.toJson()['persona_names'], isEmpty);
    });

    test('битые значения — по умолчанию, по каждому полю отдельно', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'team_mode': 'quartet',
        'duo_helper': 'sado',
        'persona_names': <String, Object?>{
          'sado': 'склад',
          'rio': 42,
          'noda': '  Мира  ',
          'alice': 'Алиса',
        },
        'persona_genders': <String, Object?>{
          'sado': 'x',
          'rio': 'f',
          'noda': 7,
        },
        'duty_extensions': 'sado',
        'duty_notifications': <String>[],
        'persona_styles': <String, Object?>{
          'rio': 'brief',
          'noda': 7,
          'alice': 'friendly',
          'x': <String>[],
        },
        'address': 'они',
        'emoji': 'нет',
        'jokes': 'always',
        'notice_day': 'вчера',
        'first_seen_day': 'давно',
        'show_timestamps': false,
      });
      final personas = settings.personas;
      expect(personas.teamMode, TeamMode.trio);
      expect(personas.duoHelper, 'rio');
      expect(personas.names, <String, String>{'noda': 'Мира'});
      expect(
        personas.genders,
        <String, ReplyGender>{'rio': ReplyGender.female},
      );
      expect(personas.sadoGenderChosen, isFalse);
      expect(personas.dutyExtensions, 'rio');
      expect(personas.dutyNotifications, 'noda');
      expect(personas.styles, <String, String>{
        'sado': 'neutral',
        'rio': 'brief',
        'noda': 'friendly',
      });
      expect(personas.address, ReplyAddress.formal);
      expect(personas.emoji, isTrue);
      expect(personas.jokes, JokeFrequency.rare);
      expect(settings.noticeDay, isNull);
      expect(settings.firstSeenDay, isNull);
      expect(settings.showTimestamps, isFalse, reason: 'остальное читается');
      // Стиль — не словарь.
      expect(
        AppSettings.fromJson(<String, dynamic>{'persona_styles': 'friendly'})
            .personas
            .styles,
        PersonaSettings.defaultStyles,
      );
    });

    test('имя из файла, занятое другим помощником, — встроенное', () {
      final personas = PersonaSettings.fromJson(<String, Object?>{
        'team_mode': 'trio',
        'persona_names': <String, Object?>{
          'sado': 'Нода',
          'rio': 'Тим',
          'noda': 'тим',
        },
      });
      expect(personas.nameOf('sado'), 'Связной');
      expect(personas.nameOf('rio'), 'Тим');
      expect(personas.nameOf('noda'), 'Нода');
    });

    test('смена настроек и перезапуск: файлы настроек и задач целы', () async {
      final folder = await Directory.systemTemp.createTemp('restart_');
      addTearDown(() => folder.delete(recursive: true));
      final clock = FixedClock(DateTime(2026, 11, 4, 12));
      final tasksPath = '${folder.path}/tasks.json';
      final settingsPath = '${folder.path}/settings.json';
      final tasks = TaskService(
        repository: JsonTaskRepository(tasksPath),
        clock: clock,
      );
      await tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
      final tasksBefore = await File(tasksPath).readAsString();
      var settings = const AppSettings(
        disabledExtensions: <String>{'calc'},
      );
      final store = JsonSettingsStore(settingsPath);
      for (final personas in <PersonaSettings>[
        const PersonaSettings(teamMode: TeamMode.solo),
        const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda'),
        const PersonaSettings(teamMode: TeamMode.duo).withStyle('rio', 'brief'),
        const PersonaSettings(
          address: ReplyAddress.informal,
          emoji: false,
        )
            .withStyle('rio', 'brief')
            .withName('noda', 'Мира')
            .withGender('sado', ReplyGender.female)
            .withDuty(PersonaDuty.notifications, 'rio'),
      ]) {
        settings = settings.copyWith(personas: personas);
        await store.save(settings);
      }

      // «Перезапуск»: новые хранилища над теми же файлами.
      final loaded = await JsonSettingsStore(settingsPath).load();
      expect(loaded.personas, settings.personas);
      expect(loaded.disabledExtensions, <String>{'calc'});
      final reloaded = TaskService(
        repository: JsonTaskRepository(tasksPath),
        clock: clock,
      );
      expect(
        (await reloaded.listActive()).map((t) => t.title),
        <String>['Отчёт'],
      );
      expect(await File(tasksPath).readAsString(), tasksBefore);
    });

    group('переход с прежних настроек', () {
      // Так писала прежняя версия: id `rio` остался прежним (ADR-008).
      const old = <String, Object?>{
        'reduce_motion': true,
        'show_timestamps': false,
        'disabled_extensions': <String>['calc'],
        'enabled_extensions': <String>[],
        'notice_day': '2026-11-05',
        'assistant_mode': 'duo',
        'main_persona': 'rio',
        'solo_persona': 'rio',
        'persona_styles': <String, String>{
          'noda': 'brief',
          'rio': 'business',
        },
        'role_owners': <String, String>{'storekeeper': 'noda'},
        'address': 'ty',
        'emoji': false,
        'jokes': 'normal',
      };

      test('дуэт Лиорио + Нода — Трио; Связной говорит, как основной',
          () async {
        final folder = await Directory.systemTemp.createTemp('migrate_');
        addTearDown(() => folder.delete(recursive: true));
        final path = '${folder.path}/settings.json';
        await File(path).writeAsString(jsonEncode(old));
        final loaded = await JsonSettingsStore(path).load();
        final personas = loaded.personas;
        expect(personas.teamMode, TeamMode.trio);
        expect(personas.responder.id, 'sado');
        expect(personas.sadoGenderChosen, isFalse);
        expect(personas.styleOf(Personas.sado), 'business');
        expect(personas.styleOf(Personas.liorio), 'business');
        expect(personas.styleOf(Personas.noda), 'brief');
        // Прежний выбор «Кладовщика ведёт Нода» в обязанности не идёт:
        // расширения у Лиорио.
        expect(personas.extensionsLead.id, 'rio');
        expect(personas.notifier.id, 'noda');
        expect(
          loaded.roleOwners,
          <String, String>{'storekeeper': 'noda'},
          reason: 'карта ролей остаётся в файле',
        );
        expect(personas.address, ReplyAddress.informal);
        expect(personas.emoji, isFalse);
        expect(personas.jokes, JokeFrequency.normal);
        expect(loaded.noticeDay, '2026-11-05');
        expect(loaded.reduceMotion, isTrue);
        expect(loaded.disabledExtensions, <String>{'calc'});

        // Сохранение: прежние ключи на месте и с прежними значениями,
        // добавились новые.
        await JsonSettingsStore(path).save(loaded);
        final saved =
            jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
        for (final key in <String>[
          'assistant_mode',
          'main_persona',
          'solo_persona',
          'role_owners',
          'address',
          'emoji',
          'jokes',
          'notice_day',
        ]) {
          expect(saved[key], old[key], reason: key);
        }
        expect(saved['persona_styles'], <String, Object?>{
          'noda': 'brief',
          'rio': 'business',
          'sado': 'business',
        });
        expect(saved['team_mode'], 'trio');
        // Второе чтение — то же самое, перехода больше нет.
        expect((await JsonSettingsStore(path).load()).personas, personas);
      });

      test('ключа режима нет — Трио', () {
        final personas = PersonaSettings.fromJson(<String, Object?>{
          'persona_styles': <String, String>{'rio': 'brief'},
        });
        expect(personas.teamMode, TeamMode.trio);
        expect(personas.styleOf(Personas.sado), 'brief');
      });

      test('основной была Нода — Связной говорит её стилем', () {
        final personas = PersonaSettings.fromJson(<String, Object?>{
          'assistant_mode': 'duo',
          'main_persona': 'noda',
        });
        expect(personas.teamMode, TeamMode.trio);
        expect(personas.styleOf(Personas.sado), ReplyStyles.friendly);
      });

      test('соло — Соло, всё делает Связной стилем прежнего отвечающего', () {
        final personas = PersonaSettings.fromJson(<String, Object?>{
          'assistant_mode': 'solo',
          'main_persona': 'rio',
          'solo_persona': 'noda',
          'persona_styles': <String, String>{'noda': 'business'},
        });
        expect(personas.teamMode, TeamMode.solo);
        expect(personas.cast.active.map((Persona p) => p.id), <String>['sado']);
        expect(personas.notifier.id, 'sado');
        expect(personas.extensionsLead.id, 'sado');
        expect(personas.styleOf(Personas.sado), 'business');
        expect(personas.styleOf(Personas.noda), 'business');
      });

      test('битый прежний файл — нейтральный Связной, Трио', () {
        final personas = PersonaSettings.fromJson(<String, Object?>{
          'assistant_mode': 7,
          'main_persona': <String, Object?>{'x': 1},
          'persona_styles': 'friendly',
        });
        expect(personas, const PersonaSettings());
      });

      test('новый файл (team_mode есть) не переходит заново', () {
        final personas = PersonaSettings.fromJson(<String, Object?>{
          'team_mode': 'solo',
          'assistant_mode': 'duo',
          'main_persona': 'noda',
        });
        expect(personas.teamMode, TeamMode.solo);
        expect(personas.styleOf(Personas.sado), ReplyStyles.neutral);
      });
    });

    test('испорченный файл и новая установка — по умолчанию, задачи не тронуты',
        () async {
      final folder = await Directory.systemTemp.createTemp('settings_');
      addTearDown(() => folder.delete(recursive: true));
      final tasks = File('${folder.path}/tasks.json');
      await tasks.writeAsString('{"tasks": []}');
      final before = await tasks.readAsBytes();
      for (final broken in <String?>[
        '{не json',
        '[1, 2]',
        '{"assistant_mode": null, "main_persona": {"x": 1}}',
        '',
        null,
      ]) {
        final file = File('${folder.path}/settings.json');
        if (broken == null) {
          if (file.existsSync()) await file.delete();
        } else {
          await file.writeAsString(broken);
        }
        final settings =
            await JsonSettingsStore('${folder.path}/settings.json').load();
        expect(settings.personas, const PersonaSettings(), reason: broken);
        expect(settings.personas.teamMode, TeamMode.trio);
        expect(settings.personas.sadoGenderChosen, isFalse);
      }
      expect(await tasks.readAsBytes(), before);
    });
  });
}
