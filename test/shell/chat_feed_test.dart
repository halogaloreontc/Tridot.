// Лента чата «как в Заметках» (ADR-027, шаг S2), в тёмной и светлой теме:
// ответ — абзацами без полосы и рамки, имя помощника не повторяется
// подряд, пузырь — заливкой без рамки и «хвоста», время — меткой над
// группой, история команд — в «⋯» шапки, поле ввода — капсулой.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/layout.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/app/widgets/status_cube.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../support/home_nav.dart';

final _clock = FixedClock(DateTime(2026, 11, 14, 12));

/// Обе темы: тёмная и светлая с их палитрами.
final _themes = <(String, ThemeData Function(), AppPalette)>[
  ('тёмная', AssistantTheme.dark, AppPalette.dark),
  ('светлая', AssistantTheme.light, AppPalette.light),
];

Future<void> _pump(
  WidgetTester tester,
  ThemeData Function() theme, {
  SettingsStore? settings,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      CalculatorConnector(),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settings ?? InMemorySettingsStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _inFeed(Finder finder) =>
    find.descendant(of: find.byKey(const Key('chat-list')), matching: finder);

/// Оформление ближайшего к тексту [text] контейнера с декорацией.
BoxDecoration? _decorationOf(WidgetTester tester, String text) {
  for (final element in _inFeed(find.text(text)).evaluate()) {
    BoxDecoration? found;
    element.visitAncestorElements((Element a) {
      final w = a.widget;
      if (w is Container && w.decoration is BoxDecoration) {
        found = w.decoration! as BoxDecoration;
        return false;
      }
      if (w is DecoratedBox && w.decoration is BoxDecoration) {
        found = w.decoration as BoxDecoration;
        return false;
      }
      return a.widget is! ListView;
    });
    return found;
  }
  return null;
}

void main() {
  for (final (name, theme, palette) in _themes) {
    group(name, () {
      testWidgets('ответ — без полосы и рамки, пузырь — заливкой r18',
          (tester) async {
        await _pump(tester, theme);
        await _say(tester, '2+2');
        // Ответ: ни Border, ни левого отступа — просто абзац.
        final reply = _decorationOf(tester, '2 + 2 = 4');
        expect(reply?.border, isNull);
        final replyText = tester.getRect(_inFeed(find.text('2 + 2 = 4')));
        final composer =
            tester.getRect(find.byKey(const Key('assistant-composer')));
        expect(replyText.left, moreOrLessEquals(composer.left, epsilon: 1));
        // Пузырь — заливкой bubble, без рамки и без «хвоста».
        final bubble = _decorationOf(tester, '2+2')!;
        expect(bubble.color, palette.bubble);
        expect(bubble.border, isNull);
        expect(
          bubble.borderRadius,
          BorderRadius.circular(AppRadius.bubble),
        );
        // Пузырь — не шире 78 % колонки.
        final bubbleRect = tester.getRect(
          find
              .ancestor(
                of: _inFeed(find.text('2+2')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          bubbleRect.width,
          lessThanOrEqualTo(composer.width * AppSize.maxBubbleFactor + 1),
        );
        // Кубика в ленте нет.
        expect(_inFeed(find.byType(StatusCube)), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('имя помощника — один раз над подряд идущими ответами',
          (tester) async {
        await _pump(tester, theme);
        await _say(tester, '2+2');
        await _say(tester, '3+3');
        await _say(tester, 'Нода, 4+4');
        // Связной ответил дважды подряд — имя одно; Нода — своё.
        expect(
          _inFeed(find.byKey(const ValueKey<String>('author-name-sado'))),
          findsOneWidget,
        );
        expect(
          _inFeed(find.byKey(const ValueKey<String>('author-name-noda'))),
          findsOneWidget,
        );
        // Каждый ответ всё равно помечен автором.
        expect(
          _inFeed(find.byKey(const ValueKey<String>('message-author-sado'))),
          findsNWidgets(2),
        );
        // Точка и имя — цветом помощника для этой темы.
        final row = find.byKey(const ValueKey<String>('author-name-noda'));
        final text = tester.widget<Text>(
          find.descendant(of: row, matching: find.byType(Text)),
        );
        expect(text.style!.color, palette.noda);
        expect(
          find.descendant(of: row, matching: find.byType(PersonaDot)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.byType(PersonaMark)),
          findsNothing,
        );
      });

      testWidgets('линия под шапкой — только когда лента заехала под неё',
          (tester) async {
        Color? line() => tester
            .widget<Divider>(find.byKey(const Key('header-divider')))
            .color;
        await _pump(tester, theme);
        // Пустая сессия: шапка не отделена линией.
        expect(line(), const Color(0x00000000));
        for (var i = 0; i < 12; i++) {
          await _say(tester, '$i+$i');
        }
        // Лента длиннее экрана и прижата к низу: верх ушёл под шапку.
        expect(line(), isNot(const Color(0x00000000)));
      });

      testWidgets('«Диалог / Документ» — цель нажатия не меньше 48',
          (tester) async {
        await _pump(tester, theme);
        for (final id in <String>['mode-dialogue', 'mode-document']) {
          final size = tester.getSize(find.byKey(Key(id)));
          expect(size.height, greaterThanOrEqualTo(AppSize.minTap), reason: id);
          expect(size.width, greaterThanOrEqualTo(AppSize.minTap), reason: id);
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });

      testWidgets('время — меткой над группой; у сообщений — по настройке',
          (tester) async {
        await _pump(tester, theme);
        await _say(tester, '2+2');
        expect(_inFeed(find.text('Сегодня, 12:00')), findsOneWidget);
        expect(_inFeed(find.text('12:00')), findsNothing);
        // Разделителя дня с линиями нет.
        expect(_inFeed(find.byType(Divider)), findsNothing);

        await tester.pumpWidget(const SizedBox());
        final store = InMemorySettingsStore();
        await store.save(const AppSettings(showTimestamps: true));
        await _pump(tester, theme, settings: store);
        await _say(tester, '2+2');
        expect(_inFeed(find.text('12:00')), findsNWidgets(2));
      });

      testWidgets('«⋯ → История команд»: шторка, выбранная команда — рамкой',
          (tester) async {
        await _pump(tester, theme);
        expect(find.byKey(const Key('session-more')), findsNothing);
        await _say(tester, '2+2');
        await _say(tester, '3+3');
        expect(find.byKey(const Key('history-rail')), findsNothing);
        await openCommandHistory(tester);
        expect(find.byKey(const Key('history-sheet')), findsOneWidget);
        // Новые — сверху.
        final first = tester.getRect(find.byKey(const Key('history-item-1')));
        final second = tester.getRect(find.byKey(const Key('history-item-0')));
        expect(first.top, lessThan(second.top));
        expect(first.height, greaterThanOrEqualTo(52));
        await tester.tap(find.byKey(const Key('history-item-0')));
        await tester.pumpAndSettle();
        final bubble = _decorationOf(tester, '2+2')!;
        expect(bubble.border, isNotNull);
        expect((bubble.border! as Border).top.color, palette.accent);
        // Ответы по-прежнему без рамки.
        expect(_decorationOf(tester, '2 + 2 = 4')?.border, isNull);
      });

      testWidgets('поле ввода — капсула без рамки, отправка акцентом',
          (tester) async {
        await _pump(tester, theme);
        expect(find.text('Сообщение'), findsOneWidget);
        final composer = find.byKey(const Key('assistant-composer'));
        final borders = tester
            .widgetList<Container>(
              find.descendant(of: composer, matching: find.byType(Container)),
            )
            .where(
              (Container c) =>
                  c.decoration is BoxDecoration &&
                  (c.decoration! as BoxDecoration).border != null,
            );
        expect(borders, isEmpty);
        await tester.enterText(find.byKey(const Key('assistant-input')), 'x');
        await tester.pump();
        final send = tester.widget<IconButton>(
          find.byKey(const Key('assistant-send')),
        );
        expect(
          send.style!.backgroundColor!.resolve(<WidgetState>{}),
          palette.accent,
        );
        final size = tester.getSize(find.byKey(const Key('assistant-send')));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      });
    });
  }

  testWidgets('шапка: точка помощника вместо знака, кубик — пока работает',
      (tester) async {
    await _pump(tester, AssistantTheme.dark);
    await _say(tester, '2+2');
    final persona = find.byKey(const Key('session-persona'));
    expect(
      find.descendant(of: persona, matching: find.byType(PersonaDot)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: persona, matching: find.byType(PersonaMark)),
      findsNothing,
    );
    expect(find.byType(StatusCube), findsNothing);
    await tester.enterText(find.byKey(const Key('assistant-input')), '3+3');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: persona, matching: find.byType(StatusCube)),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(StatusCube), findsNothing);
  });

  test('«Время у каждого сообщения»: по умолчанию выключено', () {
    expect(const AppSettings().showTimestamps, isFalse);
    // Старый файл писал `show_timestamps: true` всегда — это не выбор.
    expect(
      AppSettings.fromJson(<String, dynamic>{'show_timestamps': true})
          .showTimestamps,
      isFalse,
    );
    // Явный выбор — в `message_times`, он уважается.
    final on = AppSettings.fromJson(
      const AppSettings(showTimestamps: true).toJson(),
    );
    expect(on.showTimestamps, isTrue);
    expect(
      AppSettings.fromJson(<String, dynamic>{'message_times': 'да'})
          .showTimestamps,
      isFalse,
    );
    // Прежние версии после отката читают то же значение.
    expect(
      const AppSettings(showTimestamps: true).toJson()['show_timestamps'],
      isTrue,
    );
  });
}
