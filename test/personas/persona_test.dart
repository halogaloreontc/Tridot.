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
      ('Rio покажи задачи', 'rio', 'покажи задачи'),
      ('Рио, перенеси её на завтра', 'rio', 'перенеси её на завтра'),
      ('  rio:покажи', 'rio', 'покажи'),
      ('Нода', 'noda', ''),
      ('Rio,', 'rio', ''),
      ('Noda!', 'noda', ''),
      ('Нода.', 'noda', ''),
      ('Noda?', 'noda', ''),
      ('Noda;2+2', 'noda', '2+2'),
      ('Рио! покажи задачи', 'rio', 'покажи задачи'),
      ('Нода… сколько будет 2+2', 'noda', 'сколько будет 2+2'),
    ]) {
      test(text, () {
        final addressing = PersonaAddressing.parse(text);
        expect(addressing, isNotNull);
        expect(addressing!.persona.id, persona);
        expect(addressing.rest, rest);
      });
    }

    for (final text in <String>[
      'Рио-де-Жанейро — купить билеты',
      'Нодаа, привет',
      'Riot покажи',
      'Купить билет в Рио',
      'Добавь задачу «Noda, позвонить»',
      '',
    ]) {
      test('не обращение: «$text»', () {
        expect(PersonaAddressing.parse(text), isNull);
      });
    }
  });

  group('настройки помощников', () {
    test('по умолчанию: дуэт, основной Rio, Rio нейтральный, Noda дружеская',
        () {
      const settings = PersonaSettings();
      expect(settings.mode, AssistantMode.duo);
      expect(settings.main, Personas.rio);
      expect(settings.notifier, Personas.noda);
      expect(settings.solo, Personas.rio);
      expect(settings.styleOf(Personas.rio), ReplyStyles.neutral);
      expect(settings.styleOf(Personas.noda), ReplyStyles.friendly);
      expect(settings.address, ReplyAddress.formal);
      expect(settings.emoji, isTrue);
      expect(settings.jokes, JokeFrequency.rare);
      expect(Personas.rio.gender, ReplyGender.male);
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
      expect(settings.personas.main, Personas.rio);
      expect(settings.personas.solo, Personas.rio);
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
        expect(settings.personas.main, Personas.rio);
      }
      expect(await tasks.readAsBytes(), before);
    });
  });
}
