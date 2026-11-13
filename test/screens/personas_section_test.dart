// Раздел «Помощники»: имена, род, обязанности и подсказка об обращении
// (ADR-016).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

void main() {
  setUp(PersonaCast.resetForTest);
  tearDown(PersonaCast.resetForTest);

  Future<List<AppSettings>> pump(
    WidgetTester tester, {
    AppSettings initial = const AppSettings(),
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <AppSettings>[];
    var settings = initial;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) =>
                  SingleChildScrollView(
                child: PersonasSection(
                  settings: settings,
                  onChanged: (AppSettings value) => setState(() {
                    changes.add(value);
                    settings = value;
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  Finder key(String value) => find.byKey(ValueKey<String>(value));

  Future<void> tap(WidgetTester tester, String value) async {
    await tester.ensureVisible(key(value));
    await tester.pumpAndSettle();
    await tester.tap(key(value));
    await tester.pumpAndSettle();
  }

  Future<void> rename(WidgetTester tester, String id, String name) async {
    final field = key('persona-name-$id');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  String? errorOf(WidgetTester tester, String id) =>
      tester.widget<TextField>(key('persona-name-$id')).decoration?.errorText;

  bool selected(WidgetTester tester, String value) => tester
      .widget<ChoiceChip>(
        find.descendant(of: key(value), matching: find.byType(ChoiceChip)),
      )
      .selected;

  testWidgets('поле имени у каждого из трёх', (tester) async {
    await pump(tester);
    for (final (id, name) in <(String, String)>[
      ('sado', 'Садо'),
      ('rio', 'Лиорио'),
      ('noda', 'Нода'),
    ]) {
      expect(
        tester.widget<TextField>(key('persona-name-$id')).controller!.text,
        name,
      );
      expect(key('persona-gender-$id'), findsOneWidget);
    }
  });

  testWidgets('новое имя сохраняется и попадает в подсказку обращения',
      (tester) async {
    final changes = await pump(tester);
    expect(
      tester.widget<Text>(key('assistant-mode-hint')).data,
      contains('«Лиорио, …»'),
    );
    await rename(tester, 'rio', 'Мира');
    expect(errorOf(tester, 'rio'), isNull);
    expect(changes.last.personas.nameOf('rio'), 'Мира');
    expect(
      tester.widget<Text>(key('assistant-mode-hint')).data,
      contains('«Мира, …»'),
    );
    // Чипы дуэта и обязанностей — тоже с новым именем.
    expect(
      find.descendant(
        of: key('duty-extensions-rio'),
        matching: find.text('Мира'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('«склад» — отказ с понятной причиной, имя не сохраняется',
      (tester) async {
    final changes = await pump(tester);
    await rename(tester, 'noda', 'Склад');
    expect(errorOf(tester, 'noda'), contains('занято обращением'));
    expect(errorOf(tester, 'noda'), contains('«склад, …»'));
    expect(changes, isEmpty);
  });

  testWidgets('имя другого помощника — отказ', (tester) async {
    final changes = await pump(tester);
    await rename(tester, 'sado', 'нода');
    expect(errorOf(tester, 'sado'), contains('уже у помощника Нода'));
    expect(changes, isEmpty);
    // Ошибка видна сразу при наборе, до «Готово».
    final field = key('persona-name-rio');
    await tester.ensureVisible(field);
    await tester.enterText(field, 'Пароли');
    await tester.pump();
    expect(errorOf(tester, 'rio'), isNotNull);
    expect(changes, isEmpty);
  });

  testWidgets('род: Садо до выбора без отметки, выбор сохраняется',
      (tester) async {
    final changes = await pump(tester);
    expect(selected(tester, 'persona-gender-sado-male'), isFalse);
    expect(selected(tester, 'persona-gender-sado-female'), isFalse);
    expect(selected(tester, 'persona-gender-noda-female'), isTrue);
    // Пример склоняется в мужском роде — об этом сказано прямо.
    expect(key('style-preview-note-sado'), findsOneWidget);
    expect(key('style-preview-note-rio'), findsNothing);
    await tap(tester, 'persona-gender-sado-female');
    expect(key('style-preview-note-sado'), findsNothing);
    expect(
      tester.widget<Text>(key('style-preview-sado')).data,
      contains('Создала'),
    );
    expect(changes.last.personas.sadoGenderChosen, isTrue);
    expect(changes.last.personas.genderOf('sado'), ReplyGender.female);
    expect(selected(tester, 'persona-gender-sado-female'), isTrue);
    await tap(tester, 'persona-gender-rio-female');
    expect(changes.last.personas.genderOf('rio'), ReplyGender.female);
  });

  testWidgets('обязанности переназначаются, выключенного заменяет Садо',
      (tester) async {
    final changes = await pump(tester);
    expect(selected(tester, 'duty-extensions-rio'), isTrue);
    expect(selected(tester, 'duty-notifications-noda'), isTrue);
    expect(key('duty-extensions-fallback'), findsNothing);

    await tap(tester, 'duty-notifications-rio');
    expect(changes.last.personas.dutyNotifications, 'rio');
    expect(changes.last.personas.notifier.id, 'rio');

    // Дуэт с Нодой: Лиорио выключен — обе обязанности сейчас у Садо.
    await tap(tester, 'assistant-mode-duo');
    await tap(tester, 'duo-helper-noda');
    expect(
      tester.widget<Text>(key('duty-extensions-fallback')).data,
      'Сейчас делает Садо: Лиорио выключен режимом.',
    );
    expect(key('duty-notifications-fallback'), findsOneWidget);
    expect(changes.last.personas.extensionsLead.id, 'sado');

    await tap(tester, 'duty-notifications-noda');
    expect(key('duty-notifications-fallback'), findsNothing);
    expect(changes.last.personas.notifier.id, 'noda');
  });

  testWidgets('360 px и шрифт ×2 — без переполнений', (tester) async {
    await pump(tester, size: const Size(360, 720), textScale: 2);
    expect(tester.takeException(), isNull);
    await tap(tester, 'assistant-mode-duo');
    expect(tester.takeException(), isNull);
  });
}
