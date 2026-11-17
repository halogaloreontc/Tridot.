// Главный помощник по умолчанию — «Связной» или «Связная» (ADR-017).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/personas/persona_names.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

const PersonaSettings _female = PersonaSettings(
  genders: <String, ReplyGender>{'sado': ReplyGender.female},
);

void main() {
  setUp(PersonaCast.resetForTest);
  tearDown(PersonaCast.resetForTest);

  group('имя по умолчанию', () {
    test('до выбора рода и в мужском роде — «Связной», в женском — «Связная»',
        () {
      expect(const PersonaSettings().nameOf('sado'), 'Связной');
      expect(
        const PersonaSettings(
          genders: <String, ReplyGender>{'sado': ReplyGender.male},
        ).nameOf('sado'),
        'Связной',
      );
      expect(_female.nameOf('sado'), 'Связная');
      expect(_female.cast.responder.russianName, 'Связная');
      expect(_female.cast.responder.gender, ReplyGender.female);
    });

    test('буква «С», фиолетовый цвет и id `sado` не меняются', () {
      for (final settings in <PersonaSettings>[
        const PersonaSettings(),
        _female,
      ]) {
        final sado = settings.cast.responder;
        expect(sado.id, 'sado');
        expect(sado.initial, 'С');
        expect(sado.accentColor, Personas.sado.accentColor);
      }
    });

    test('обращение — оба слова при любом роде; падежи — не обращение', () {
      for (final settings in <PersonaSettings>[
        const PersonaSettings(),
        _female,
      ]) {
        final names = settings.cast.responder.addressNames;
        expect(names, containsAll(<String>['связной', 'связная']));
        expect(names, isNot(contains('связного')));
        expect(
          settings.cast.responder.nameForms,
          containsAll(<String>['связного', 'связному', 'связным', 'связную']),
        );
      }
      PersonaCast.configure(_female);
      expect(PersonaAddressing.parse('Связной, 2+2')?.persona.id, 'sado');
      expect(PersonaAddressing.parse('связная: 2+2')?.persona.id, 'sado');
      // Косвенный падеж и слово, которое начинается с имени, — не
      // обращение.
      expect(PersonaAddressing.parse('Связного, привет'), isNull);
      expect(PersonaAddressing.parse('Связнойка, привет'), isNull);
      expect(PersonaAddressing.parse('Садовник, привет'), isNull);
      // Прежнее имя больше не обращение.
      expect(PersonaAddressing.parse('Садо, привет'), isNull);
    });

    test('isDefaultName и defaultNameFor', () {
      expect(Personas.sado.isDefaultName('СВЯЗНАЯ'), isTrue);
      expect(Personas.sado.isDefaultName(' связной '), isTrue);
      expect(Personas.sado.isDefaultName('Садо'), isFalse);
      expect(Personas.noda.isDefaultName('нода'), isTrue);
      expect(Personas.noda.defaultNameFor(ReplyGender.male), 'Нода');
      expect(Personas.sado.defaultNameFor(ReplyGender.female), 'Связная');
    });
  });

  group('переименование', () {
    test('встроенное имя другого рода ключа не создаёт и род не меняет', () {
      final male = const PersonaSettings().withName('sado', 'Связная');
      expect(male.names, isEmpty);
      expect(male.nameOf('sado'), 'Связной');
      final female = _female.withName('sado', 'связной');
      expect(female.names, isEmpty);
      expect(female.nameOf('sado'), 'Связная');
    });

    test('своё имя от рода не зависит; встроенное снова следует за родом', () {
      final renamed = const PersonaSettings().withName('sado', 'Мира');
      expect(renamed.nameOf('sado'), 'Мира');
      expect(
        renamed.withGender('sado', ReplyGender.female).nameOf('sado'),
        'Мира',
      );
      final back = renamed
          .withGender('sado', ReplyGender.female)
          .withName('sado', 'Связной');
      expect(back.names, isEmpty);
      expect(back.nameOf('sado'), 'Связная');
      // Своё имя «Садо» теперь можно.
      expect(
        PersonaNames.validate('Садо', 'sado', const PersonaSettings().cast),
        isNull,
      );
      expect(
        const PersonaSettings().withName('sado', 'Садо').nameOf('sado'),
        'Садо',
      );
    });

    test('другой помощник не возьмёт имя главного ни в каком падеже', () {
      final cast = _female.cast;
      for (final name in <String>['Связной', 'Связная', 'Связного']) {
        expect(
          PersonaNames.validate(name, 'noda', cast),
          contains('уже у помощника Связная'),
          reason: name,
        );
      }
    });
  });

  group('settings.json', () {
    test('без имён — имя по роду; своё имя остаётся', () {
      expect(
        PersonaSettings.fromJson(const <String, Object?>{}).nameOf('sado'),
        'Связной',
      );
      final female = PersonaSettings.fromJson(const <String, Object?>{
        'persona_genders': <String, String>{'sado': 'f'},
      });
      expect(female.nameOf('sado'), 'Связная');
      final custom = PersonaSettings.fromJson(const <String, Object?>{
        'persona_names': <String, String>{'sado': 'Мира'},
      });
      expect(custom.nameOf('sado'), 'Мира');
      expect(
        custom.toJson()['persona_names'],
        <String, String>{'sado': 'Мира'},
      );
    });

    test('«Связной», записанное как своё, снова следует за родом', () {
      final settings = PersonaSettings.fromJson(const <String, Object?>{
        'persona_names': <String, String>{'sado': 'СВЯЗНОЙ'},
        'persona_genders': <String, String>{'sado': 'f'},
      });
      expect(settings.names, isEmpty);
      expect(settings.nameOf('sado'), 'Связная');
      expect(settings.toJson()['persona_names'], isEmpty);
    });

    test('коллизия: Нода с именем «Связная» — снова «Нода»', () {
      final settings = PersonaSettings.fromJson(const <String, Object?>{
        'persona_names': <String, String>{'noda': 'Связная', 'rio': 'Садо'},
      });
      expect(settings.nameOf('noda'), 'Нода');
      expect(settings.nameOf('sado'), 'Связной');
      // Прежнее имя главного у другого помощника — просто имя.
      expect(settings.nameOf('rio'), 'Садо');
    });
  });

  group('падежи имени', () {
    test('прилагательное и существительные', () {
      expect(
        nameCaseForms('Связной', ReplyGender.male),
        <String>['связного', 'связному', 'связным', 'связном'],
      );
      expect(
        nameCaseForms('Связная', ReplyGender.female),
        containsAll(<String>['связной', 'связную']),
      );
      expect(nameCaseForms('Аглая', ReplyGender.female), contains('аглаей'));
      expect(nameCaseForms('Аглая', ReplyGender.female), contains('аглаю'));
      expect(
        nameCaseForms('Дмитрий', ReplyGender.male),
        <String>['дмитрия', 'дмитрию', 'дмитрием', 'дмитрии'],
      );
      expect(
        nameCaseForms('Света', ReplyGender.female),
        containsAll(<String>['свету', 'светой', 'светы']),
      );
      expect(nameCaseForms('Гоша', ReplyGender.male), contains('гоши'));
      expect(nameCaseForms('Тим', ReplyGender.male), contains('тимом'));
      expect(nameCaseForms('Нинель', ReplyGender.female), contains('нинелью'));
      expect(nameCaseForms('Игорь', ReplyGender.male), contains('игорем'));
      expect(nameCaseForms('Кэт', ReplyGender.female), isEmpty);
      expect(nameCaseForms('Садо', ReplyGender.male), isEmpty);
      expect(nameCaseForms('Max', ReplyGender.male), isEmpty);
      // Прежняя функция ADR-016 — творительный падеж.
      expect(instrumentalForms('Мира'), <String>['мирой', 'мирей']);
    });

    test('«сделай Свету основной» и «дуэт со Светой» — Нода по имени', () {
      final settings = const PersonaSettings().withName('noda', 'Света');
      PersonaCast.configure(settings);
      final main = TalkPhrases.recognize('сделай Свету основной');
      expect(main?.setting, TalkSettingKind.main);
      expect(main?.persona, 'noda');
      final duo = TalkPhrases.recognize('включи дуэт со Светой');
      expect(duo?.setting, TalkSettingKind.modeDuo);
      expect(duo?.persona, 'noda');
    });

    test('«дуэт со Связным», «сделай Связного основным»', () {
      final duo = TalkPhrases.recognize('включи дуэт со Связным');
      expect(duo?.setting, TalkSettingKind.modeDuo);
      expect(duo?.persona, 'sado');
      final main = TalkPhrases.recognize('сделай Связного основным');
      expect(main?.setting, TalkSettingKind.main);
      expect(main?.persona, 'sado');
      // «Со» без имени — обычное слово: «со смайликами».
      expect(
        TalkPhrases.recognize('можно со смайликами')?.setting,
        TalkSettingKind.emojiOn,
      );
    });
  });

  group('контроллер', () {
    final clock = FixedClock(DateTime(2026, 11, 13, 12));

    (AssistantController, TaskService) assistant(PersonaSettings personas) {
      final tasks = TaskService(
        repository: InMemoryTaskRepository(),
        clock: clock,
      );
      return (
        AssistantController(
          connectors: <Connector>[
            TasksConnector(
              taskService: tasks,
              parser: ScenarioParser(clock: clock),
            ),
            TalkConnector(taskService: tasks),
          ],
          clock: clock,
          personas: personas,
        ),
        tasks,
      );
    }

    for (final (settings, address) in <(PersonaSettings, String)>[
      (const PersonaSettings(), 'Связной'),
      (_female, 'Связная'),
      (_female, 'Связной'),
    ]) {
      test('«$address, добавь задачу хлеб» — задача «Хлеб» от главного',
          () async {
        PersonaCast.configure(settings);
        final (controller, tasks) = assistant(settings);
        final response =
            await controller.handle('$address, добавь задачу хлеб');
        expect(response.personaId, 'sado');
        expect((await tasks.listActive()).single.title, 'Хлеб');
      });
    }

    test('«включи дуэт со Связным» помощника не выбирает', () async {
      const settings = PersonaSettings();
      final (controller, _) = assistant(settings);
      final response = await controller.handle('включи дуэт со Связным');
      expect(response.personaId, 'sado');
      final change = response.settingsChange;
      expect(change, isNotNull);
      final next = change!.apply(settings);
      expect(next.teamMode, TeamMode.duo);
      expect(next.duoHelper, 'rio', reason: 'прежний помощник дуэта');
      expect(response.message, contains('Связной'));
    });

    test('«кто ты» в женском роде — «Я Связная, главная помощница»', () async {
      PersonaCast.configure(_female);
      final (controller, _) = assistant(_female);
      final response = await controller.handle('кто ты');
      expect(response.message, startsWith('Я Связная, главная помощница'));
    });
  });

  group('«Помощники»', () {
    Future<void> pump(WidgetTester tester, AppSettings settings) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PersonasSection(settings: settings, onChanged: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String hint(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey<String>('assistant-mode-hint')))
        .data!;

    testWidgets('подсказка режима — имя только в именительном', (tester) async {
      await pump(
        tester,
        const AppSettings(
          personas: PersonaSettings(
            teamMode: TeamMode.duo,
            genders: <String, ReplyGender>{'sado': ReplyGender.female},
          ),
        ),
      );
      expect(hint(tester), startsWith('Связная и один помощник на выбор'));
      expect(hint(tester), isNot(contains('к Связн')));

      await pump(
        tester,
        const AppSettings(
          personas: PersonaSettings(
            teamMode: TeamMode.solo,
            genders: <String, ReplyGender>{'sado': ReplyGender.female},
          ),
        ),
      );
      expect(hint(tester), startsWith('Связная делает всё сама.'));
    });

    testWidgets('поле имени: «Связной» при «она» остаётся «Связная»',
        (tester) async {
      await pump(tester, const AppSettings(personas: _female));
      final field = find.byKey(const ValueKey<String>('persona-name-sado'));
      expect(tester.widget<TextField>(field).controller!.text, 'Связная');
      await tester.ensureVisible(field);
      await tester.enterText(field, 'Связной');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'Связная');
      expect(tester.widget<TextField>(field).decoration?.errorText, isNull);
    });
  });
}
