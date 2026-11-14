// Шрифты и подсветка команды (ADR-021): Inter — весь текст, JetBrains Mono —
// только пароли и распознанные части команды, Cormorant Unicase — «Tridot»
// и названия проектов.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/app_name_text.dart';
import 'package:local_assistant/app/widgets/command_highlight.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../support/home_nav.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1300, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: _clock,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      const CalculatorConnector(),
      PasswordsConnector(
        vault: null,
        canCopySecrets: false,
        vaultExisted: () => false,
      ),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: InMemorySettingsStore(),
        chatStore: InMemoryChatStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Все части текста [span] с их итоговым стилем (стиль родителя
/// наследуется).
List<(String, TextStyle)> _flatten(InlineSpan span, [TextStyle? parent]) {
  final out = <(String, TextStyle)>[];
  void walk(InlineSpan node, TextStyle inherited) {
    if (node is! TextSpan) return;
    final style = inherited.merge(node.style);
    if (node.text != null && node.text!.isNotEmpty) {
      out.add((node.text!, style));
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(span, parent ?? const TextStyle());
  return out;
}

/// Части с моноширинным шрифтом — одной строкой через «|».
/// Распознанные части через «|». Пробелы внутри части — шрифтом текста
/// (не моноширинным), но часть они не разрывают.
String _mono(InlineSpan span) {
  final groups = <String>[];
  var current = '';
  var gap = '';
  for (final (text, style) in _flatten(span)) {
    if (style.fontFamily == AppFonts.mono) {
      current += gap + text;
      gap = '';
    } else if (text.trim().isEmpty &&
        current.isNotEmpty &&
        (style.debugLabel ?? '').contains(commandGapLabel)) {
      gap += text;
    } else {
      if (current.isNotEmpty) groups.add(current);
      current = '';
      gap = '';
    }
  }
  if (current.isNotEmpty) groups.add(current);
  return groups.join('|');
}

CommandInputController _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('assistant-input')))
    .controller! as CommandInputController;

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void main() {
  group('стили', () {
    test('уведомления (SnackBar) — Inter, а не системный шрифт', () {
      final theme = AssistantTheme.dark();
      expect(
        theme.snackBarTheme.contentTextStyle?.fontFamily,
        AppFonts.text,
      );
    });

    test('метаданные — Inter с табличными цифрами', () {
      expect(metaTextStyle.fontFamily, AppFonts.text);
      expect(
        metaTextStyle.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    test('моноширинный — JetBrains Mono, название — Cormorant Unicase 600', () {
      expect(monoTextStyle.fontFamily, 'JetBrains Mono');
      expect(displayTextStyle.fontFamily, 'Cormorant Unicase');
      expect(displayTextStyle.fontWeight, FontWeight.w600);
      expect(projectNameStyle().fontFamily, 'Cormorant Unicase');
    });

    test('шрифт названия подключён в pubspec, лицензия — в main.dart', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: Cormorant Unicase'));
      expect(pubspec, contains('assets/fonts/CormorantUnicase-SemiBold.ttf'));
      expect(pubspec, contains('assets/fonts/CormorantUnicase-OFL.txt'));
      expect(
        File('assets/fonts/CormorantUnicase-SemiBold.ttf').existsSync(),
        isTrue,
      );
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains("'assets/fonts/CormorantUnicase-OFL.txt'"));
      expect(main, contains("<String>['Cormorant Unicase']"));
    });

    test('JetBrains Mono — только пароли, подсветка и тема', () {
      const allowed = <String>{
        'lib/app/assistant_theme.dart',
        'lib/app/widgets/command_highlight.dart',
      };
      final offenders = <String>[];
      for (final entity in Directory('lib/app').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (allowed.contains(path) || path.contains('/passwords/')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('monoTextStyle') ||
            text.contains('AppFonts.mono') ||
            text.contains('JetBrains Mono')) {
          offenders.add(path);
        }
      }
      expect(offenders, isEmpty);
      expect(
        File('lib/app/passwords/secret_widgets.dart').readAsStringSync(),
        contains('monoTextStyle'),
      );
    });

    test('appNameSpan: только слово «Tridot» шрифтом названия', () {
      final parts = _flatten(
        appNameSpan(AppInfo.hubName, const TextStyle(fontSize: 18)),
      );
      expect(parts.map(((String, TextStyle) p) => p.$1).join(), 'Мой Tridot');
      final name = parts.singleWhere(
        ((String, TextStyle) p) => p.$2.fontFamily == AppFonts.display,
      );
      expect(name.$1, AppInfo.name);
      expect(name.$2.fontSize, closeTo(18 * displayScale, 0.01));
    });
  });

  group('highlightedCommand', () {
    test('распознанное — моноширинным, остальное — как было', () {
      const text = 'Добавь задачу хлеб завтра';
      final span = highlightedCommand(
        text,
        const <CommandSpan>[
          CommandSpan(0, 13, CommandSpanKind.verb),
          CommandSpan(19, 25, CommandSpanKind.due),
        ],
        const TextStyle(fontSize: 16, color: AssistantColors.textStrong),
      );
      expect(span.toPlainText(), text);
      expect(_mono(span), 'Добавь задачу|завтра');
      final parts = _flatten(span);
      expect(parts.first.$2.color, AssistantColors.commandVerb);
      expect(parts.first.$2.fontSize, closeTo(16 * commandMonoScale, 0.01));
      expect(parts[1].$2.fontFamily, isNot(AppFonts.mono));
      expect(parts.last.$2.color, AssistantColors.commandValue);
    });

    test('пробелы в подсветке и рядом — шрифтом текста, не двойные', () {
      const text = 'перенеси задачу на пятницу';
      final span = highlightedCommand(
        text,
        const <CommandSpan>[
          CommandSpan(0, 16, CommandSpanKind.verb),
          CommandSpan(16, 26, CommandSpanKind.due),
        ],
        const TextStyle(fontSize: 16),
      );
      expect(span.toPlainText(), text);
      for (final (part, style) in _flatten(span)) {
        if (part.trim().isEmpty) {
          expect(style.fontFamily, isNot(AppFonts.mono), reason: '«$part»');
        } else {
          expect(style.fontFamily, AppFonts.mono, reason: part);
        }
      }
    });

    test('набираемое слово подчёркнуто и внутри подсветки', () {
      const text = 'Добавь задачу';
      final span = highlightedCommand(
        text,
        const <CommandSpan>[CommandSpan(0, 13, CommandSpanKind.verb)],
        const TextStyle(),
        composing: const TextRange(start: 7, end: 13),
      );
      final parts = _flatten(span);
      expect(parts.map(((String, TextStyle) p) => p.$1), <String>[
        'Добавь',
        ' ',
        'задачу',
      ]);
      expect(parts.last.$2.decoration, TextDecoration.underline);
      expect(parts.last.$2.fontFamily, AppFonts.mono);
      expect(parts.first.$2.decoration, isNot(TextDecoration.underline));
    });
  });

  group('CommandInputController', () {
    testWidgets('разбор — после паузы, а не на каждую букву', (tester) async {
      var calls = 0;
      final controller = CommandInputController(
        highlighter: (String text) {
          calls++;
          return <CommandSpan>[
            if (text.startsWith('Добавь'))
              const CommandSpan(0, 6, CommandSpanKind.verb),
          ];
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(child: TextField(controller: controller)),
        ),
      );
      for (final text in <String>['Д', 'До', 'Доб', 'Добавь']) {
        controller.text = text;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(calls, 0);
      expect(controller.spans, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 1);
      expect(controller.spans, hasLength(1));
      // Дописали в конец — прежняя подсветка остаётся до нового разбора.
      controller.text = 'Добавь х';
      expect(controller.spans, hasLength(1));
      // Стёрли начало — подсветки нет сразу.
      controller.text = 'бавь х';
      expect(controller.spans, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 2);
      controller.clear();
      expect(controller.spans, isEmpty);
    });
  });

  group('главный экран', () {
    testWidgets('«Tridot» в панели — шрифтом названия', (tester) async {
      await _pump(tester);
      final name = tester.widget<Text>(find.byKey(const Key('app-name')));
      expect(name.data, AppInfo.name);
      expect(name.style?.fontFamily, AppFonts.display);
      final version = tester.widget<Text>(find.byKey(const Key('app-version')));
      expect(version.style?.fontFamily, AppFonts.text);
    });

    testWidgets('название проекта в панели — шрифтом названия', (tester) async {
      await _pump(tester);
      await tapInDrawer(tester, const Key('project-new'));
      await tester.enterText(
        find.byKey(const Key('project-name-field')),
        'Ремонт',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('project-save')));
      await tester.pumpAndSettle();
      final styles = tester
          .widgetList<Text>(find.text('Ремонт'))
          .map((Text t) => t.style?.fontFamily)
          .toSet();
      expect(styles, contains(AppFonts.display));
      expect(styles, isNot(contains(AppFonts.mono)));
    });

    testWidgets('поле ввода подсвечивает команду по ходу набора',
        (tester) async {
      await _pump(tester);
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'Добавь задачу купить хлеб на завтра',
      );
      await tester.pump(const Duration(milliseconds: 300));
      final input = _input(tester);
      expect(
        input.spans.map((CommandSpan s) => s.kind),
        <CommandSpanKind>[
          CommandSpanKind.verb,
          CommandSpanKind.title,
          CommandSpanKind.due,
        ],
      );
      final span = input.buildTextSpan(
        context: tester.element(find.byKey(const Key('assistant-input'))),
        style: const TextStyle(fontSize: 16),
        withComposing: false,
      );
      expect(_mono(span), 'Добавь задачу|купить хлеб|на завтра');
    });

    testWidgets('фраза с паролем в поле ввода не подсвечивается',
        (tester) async {
      await _pump(tester);
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'Добавь задачу пароль: Kx9!mq2zQ',
      );
      await tester.pump(const Duration(milliseconds: 300));
      final input = _input(tester);
      expect(input.spans, isEmpty);
      final span = input.buildTextSpan(
        context: tester.element(find.byKey(const Key('assistant-input'))),
        style: const TextStyle(fontSize: 16),
        withComposing: false,
      );
      expect(_mono(span), isEmpty);
    });

    testWidgets('отправленная команда в ленте подсвечена, ответ — нет',
        (tester) async {
      await _pump(tester);
      await _say(tester, 'Добавь задачу купить хлеб на завтра #дом');
      final rich = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((SelectableText t) => t.textSpan != null)
          .toList();
      expect(rich, hasLength(1));
      expect(
        _mono(rich.single.textSpan!),
        'Добавь задачу|купить хлеб|на завтра|#дом',
      );
      // Время под сообщениями и подписи — не моноширинным.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.style?.fontFamily, isNot(AppFonts.mono));
      }
    });

    testWidgets('калькулятор: в ленте подсвечен пример', (tester) async {
      await _pump(tester);
      await _say(tester, 'сколько будет 2+2*2');
      final rich = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((SelectableText t) => t.textSpan != null)
          .single;
      expect(_mono(rich.textSpan!), '2+2*2');
    });

    testWidgets('фраза о паролях в ленте не подсвечена', (tester) async {
      await _pump(tester);
      await _say(tester, 'покажи пароль от почты');
      final rich = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((SelectableText t) => t.textSpan != null);
      expect(rich, isEmpty);
    });
  });
}
