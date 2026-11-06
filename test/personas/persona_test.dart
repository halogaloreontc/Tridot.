import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';

void main() {
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

  group('настройки помощников', () {
    test(
        'по умолчанию: дуэт, основной Liorio, Liorio нейтральный, Noda дружеская',
        () {
      const settings = PersonaSettings();
      expect(settings.mode, AssistantMode.duo);
      expect(settings.main, Personas.liorio);
      expect(settings.notifier, Personas.noda);
      expect(settings.solo, Personas.liorio);
      expect(settings.styleOf(Personas.liorio), ReplyStyles.neutral);
      expect(settings.styleOf(Personas.noda), ReplyStyles.friendly);
      expect(settings.address, ReplyAddress.formal);
      expect(settings.emoji, isTrue);
      expect(settings.jokes, JokeFrequency.rare);
      expect(Personas.liorio.gender, ReplyGender.male);
      expect(Personas.noda.gender, ReplyGender.female);
    });

    test('соло: один помощник и отвечает, и пишет первым', () {
      const settings =
          PersonaSettings(mode: AssistantMode.solo, soloPersona: 'noda');
      expect(settings.responder, Personas.noda);
      expect(settings.notifier, Personas.noda);
    });

    test('сохраняются и читаются без потерь', () {
      final settings = const AppSettings().copyWith(
        personas: const PersonaSettings(
          mode: AssistantMode.solo,
          mainPersona: 'noda',
          soloPersona: 'noda',
          styles: <String, String>{'rio': 'business', 'noda': 'replies.pirate'},
          address: ReplyAddress.informal,
          emoji: false,
          jokes: JokeFrequency.off,
        ),
        noticeDay: '2026-11-06',
      );
      final json = jsonDecode(jsonEncode(settings.toJson()));
      final back = AppSettings.fromJson(json as Map<String, dynamic>);
      expect(back.personas, settings.personas);
      expect(back.noticeDay, '2026-11-06');
      expect(json['address'], 'ty');
      expect(json['assistant_mode'], 'solo');
    });

    test('битые значения — по умолчанию, по каждому полю отдельно', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'assistant_mode': 'trio',
        'main_persona': 42,
        'solo_persona': 'alice',
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
        'show_timestamps': false,
      });
      expect(settings.personas.mode, AssistantMode.duo);
      expect(settings.personas.main, Personas.liorio);
      expect(settings.personas.solo, Personas.liorio);
      expect(settings.personas.styles, <String, String>{
        'rio': 'brief',
        'noda': 'friendly',
      });
      expect(settings.personas.address, ReplyAddress.formal);
      expect(settings.personas.emoji, isTrue);
      expect(settings.personas.jokes, JokeFrequency.rare);
      expect(settings.noticeDay, isNull);
      expect(settings.showTimestamps, isFalse, reason: 'остальное читается');
      // Стиль — не словарь.
      expect(
        AppSettings.fromJson(<String, dynamic>{'persona_styles': 'friendly'})
            .personas
            .styles,
        PersonaSettings.defaultStyles,
      );
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
        const PersonaSettings(mode: AssistantMode.solo),
        const PersonaSettings(mainPersona: 'noda'),
        const PersonaSettings(mainPersona: 'noda').withStyle('rio', 'brief'),
        const PersonaSettings(
          mainPersona: 'noda',
          address: ReplyAddress.informal,
          emoji: false,
        ).withStyle('rio', 'brief'),
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

    test('файл настроек до переименования Rio в Liorio читается как был',
        () async {
      final folder = await Directory.systemTemp.createTemp('rename_');
      addTearDown(() => folder.delete(recursive: true));
      final path = '${folder.path}/settings.json';
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
        'address': 'ty',
        'emoji': false,
        'jokes': 'normal',
      };
      await File(path).writeAsString(jsonEncode(old));
      final loaded = await JsonSettingsStore(path).load();
      final personas = loaded.personas;
      expect(personas.main, Personas.liorio);
      expect(personas.main.name, 'Liorio');
      expect(personas.main.initial, 'L');
      expect(personas.solo, Personas.liorio);
      expect(personas.notifier, Personas.noda);
      expect(personas.styleOf(Personas.liorio), 'business');
      expect(personas.styleOf(Personas.noda), 'brief');
      expect(personas.address, ReplyAddress.informal);
      expect(personas.emoji, isFalse);
      expect(personas.jokes, JokeFrequency.normal);
      expect(loaded.noticeDay, '2026-11-05');
      expect(loaded.reduceMotion, isTrue);
      expect(loaded.disabledExtensions, <String>{'calc'});
      // Сохранение ничего не переименовывает: файл тот же.
      await JsonSettingsStore(path).save(loaded);
      expect(jsonDecode(await File(path).readAsString()), old);
    });

    test('испорченный файл настроек — по умолчанию, задачи не тронуты',
        () async {
      final folder = await Directory.systemTemp.createTemp('settings_');
      addTearDown(() => folder.delete(recursive: true));
      final tasks = File('${folder.path}/tasks.json');
      await tasks.writeAsString('{"tasks": []}');
      final before = await tasks.readAsBytes();
      for (final broken in <String>[
        '{не json',
        '[1, 2]',
        '{"assistant_mode": null, "main_persona": {"x": 1}}',
        '',
      ]) {
        await File('${folder.path}/settings.json').writeAsString(broken);
        final settings =
            await JsonSettingsStore('${folder.path}/settings.json').load();
        expect(settings.personas, const PersonaSettings(), reason: broken);
        expect(settings.personas.mode, AssistantMode.duo);
        expect(settings.personas.main, Personas.liorio);
      }
      expect(await tasks.readAsBytes(), before);
    });
  });
}
