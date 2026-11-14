// Экран новой сессии: знак Связной, строки ведущего оповещений, строка о
// ролях помощников голосом Связной и карточка выбора рода Связной (ADR-016).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/session_hero.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_library.dart';

void main() {
  Future<void> pump(WidgetTester tester, SessionHero hero) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AssistantTheme.dark(), home: Scaffold(body: hero)),
    );
  }

  Persona markOf(WidgetTester tester, String key) => tester
      .widget<PersonaMark>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(PersonaMark),
        ),
      )
      .persona;

  /// Строка роли голосом Связной из встроенного каталога.
  String Function(String, Persona) line(PersonaSettings personas) =>
      (String roles, Persona owner) => ReplyLibrary.builtIn.render(
            Reply('session.handoff.note', <String, String>{
              'roles': roles,
              'name': owner.russianName,
            }),
            personas.voiceOf(personas.responder),
          );

  for (final (title, settings) in <(String, PersonaSettings)>[
    ('Соло', const PersonaSettings(teamMode: TeamMode.solo)),
    ('Дуэт с Лиорио', const PersonaSettings(teamMode: TeamMode.duo)),
    (
      'Дуэт с Нодой',
      const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda'),
    ),
    ('Трио', const PersonaSettings()),
  ]) {
    testWidgets(
        '$title: крупный знак — Связной, просрочки — от ведущего '
        'оповещений', (tester) async {
      final cast = settings.cast;
      await pump(
        tester,
        SessionHero(
          persona: cast.responder,
          notifier: cast.notifier,
          overdue: 2,
          onOverdue: () {},
          onTraining: () {},
        ),
      );
      final big = tester.widget<PersonaMark>(
        find.descendant(
          of: find.byKey(const Key('session-hero')),
          matching: find.byWidgetPredicate(
            (Widget w) => w is PersonaMark && w.size == 48,
          ),
        ),
      );
      expect(big.persona.id, 'sado');
      final expected = switch (settings.teamMode) {
        TeamMode.trio => 'noda',
        TeamMode.duo when settings.duoHelper == 'noda' => 'noda',
        _ => 'sado',
      };
      expect(markOf(tester, 'session-hero-overdue').id, expected);
      expect(markOf(tester, 'session-hero-training').id, expected);
      expect(find.text('Просрочены 2 задачи'), findsOneWidget);
    });
  }

  test('строка о ролях — из каталога, голосом Связной, без ролей Связной', () {
    final cast = const PersonaSettings().cast;
    final roles = <(String, Persona)>[
      ('Личное', cast.responder),
      ('Кладовщик', cast.byId('rio')),
    ];
    // Строка без рода: она видна рядом с карточкой «Связной — он или она?»,
    // пока род не выбран, и не меняется после выбора.
    for (final personas in <PersonaSettings>[
      const PersonaSettings(),
      const PersonaSettings(
        genders: <String, ReplyGender>{'sado': ReplyGender.male},
      ),
      const PersonaSettings(
        genders: <String, ReplyGender>{'sado': ReplyGender.female},
      ),
    ]) {
      expect(
        SessionHero.noteFor(roles, cast.responder, line: line(personas)),
        '«Кладовщик» ведёт Лиорио — такие фразы передам',
      );
    }
    // Все роли у Связной — строки нет.
    expect(
      SessionHero.noteFor(
        <(String, Persona)>[('Личное', cast.responder)],
        cast.responder,
        line: line(const PersonaSettings()),
      ),
      isNull,
    );
    // Переименованный помощник — под новым именем.
    final renamed = const PersonaSettings(
      names: <String, String>{'rio': 'Мира'},
    );
    expect(
      SessionHero.noteFor(
        <(String, Persona)>[('Кладовщик', renamed.cast.byId('rio'))],
        renamed.cast.responder,
        line: line(renamed),
      ),
      '«Кладовщик» ведёт Мира — такие фразы передам',
    );
  });

  testWidgets('карточка «Связной или Связная?» видна, пока род не выбран',
      (tester) async {
    final chosen = <ReplyGender>[];
    final cast = const PersonaSettings().cast;
    await pump(
      tester,
      SessionHero(persona: cast.responder, onSadoGender: chosen.add),
    );
    expect(find.byKey(const Key('sado-gender-choice')), findsOneWidget);
    expect(find.text('Связной или Связная?'), findsOneWidget);
    expect(find.text('Связной (он)'), findsOneWidget);
    expect(find.text('Связная (она)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('sado-gender-female')));
    expect(chosen, <ReplyGender>[ReplyGender.female]);

    await pump(tester, SessionHero(persona: cast.responder));
    expect(find.byKey(const Key('sado-gender-choice')), findsNothing);
  });

  testWidgets('своё имя главного: «Мира — он или она?», чипы «Он» и «Она»',
      (tester) async {
    final cast = const PersonaSettings(
      names: <String, String>{'sado': 'Мира'},
    ).cast;
    await pump(
      tester,
      SessionHero(persona: cast.responder, onSadoGender: (_) {}),
    );
    expect(find.text('Мира — он или она?'), findsOneWidget);
    expect(find.text('Он'), findsOneWidget);
    expect(find.text('Она'), findsOneWidget);
    expect(find.textContaining('Связн'), findsNothing);
  });

  testWidgets('карточка выбора рода на 320 px и шрифте ×2 без переполнений',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cast = const PersonaSettings().cast;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SessionHero(
              persona: cast.responder,
              overdue: 3,
              note: '«Кладовщик» ведёт Лиорио — такие фразы передам',
              onSadoGender: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
