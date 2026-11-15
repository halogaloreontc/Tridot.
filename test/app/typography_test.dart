// Шрифты и шкала текста (ADR-021, ADR-027): Inter — весь текст, шкала
// 17/15/13, ничего мельче 13; JetBrains Mono — только пароли и коды
// восстановления; Cormorant Unicase — «Tridot» и названия проектов. Команды
// в ленте — обычный текст, в поле ввода выделен только глагол.
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
String _mono(InlineSpan span) => <String>[
      for (final (text, style) in _flatten(span))
        if (style.fontFamily == AppFonts.mono) text,
    ].join('|');

/// Части, выделенные цветом распознанного глагола, — через «|».
String _tinted(InlineSpan span, Color tint) => <String>[
      for (final (text, style) in _flatten(span))
        if (style.color == tint) text,
    ].join('|');

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

    test(
        'метаданные — Inter 13, цвет из темы; табличные цифры только у '
        'времени и счётчиков', () {
      expect(metaTextStyle.fontFamily, AppFonts.text);
      expect(metaTextStyle.fontSize, 13);
      expect(metaTextStyle.color, isNull);
      // Табличные цифры в Inter расширяют «-» и «–»: в подписях их нет.
      expect(metaTextStyle.fontFeatures, isNull);
      for (final theme in <ThemeData>[
        AssistantTheme.dark(),
        AssistantTheme.light(),
      ]) {
        expect(theme.textTheme.bodySmall!.fontFeatures, isNull);
      }
      expect(metaNumTextStyle.fontSize, 13);
      expect(metaNumTextStyle.color, isNull);
      expect(
        metaNumTextStyle.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    for (final (name, theme) in <(String, ThemeData)>[
      ('тёмная', AssistantTheme.dark()),
      ('светлая', AssistantTheme.light()),
    ]) {
      test('шкала 17/15/13 и Inter в каждом стиле: $name', () {
        final t = theme.textTheme;
        expect(t.bodyLarge!.fontSize, 17);
        expect(t.bodyLarge!.height, closeTo(1.41, 0.001));
        expect(t.bodyMedium!.fontSize, 15);
        expect(t.bodySmall!.fontSize, 13);
        expect(t.titleMedium!.fontSize, 17);
        expect(t.titleMedium!.fontWeight, FontWeight.w600);
        expect(t.displaySmall!.fontSize, 30);
        expect(t.headlineMedium!.fontSize, 28);
        expect(t.labelLarge!.fontSize, 17);
        final p = theme.extension<AppPalette>()!;
        expect(t.bodySmall!.color, p.muted);
        expect(t.bodyLarge!.color, p.text);
        for (final style in <TextStyle?>[
          t.displayLarge,
          t.displayMedium,
          t.displaySmall,
          t.headlineLarge,
          t.headlineMedium,
          t.headlineSmall,
          t.titleLarge,
          t.titleMedium,
          t.titleSmall,
          t.bodyLarge,
          t.bodyMedium,
          t.bodySmall,
          t.labelLarge,
          t.labelMedium,
          t.labelSmall,
        ]) {
          expect(style!.fontFamily, AppFonts.text);
          expect(style.fontSize, greaterThanOrEqualTo(13));
        }
      });
    }

    test('моноширинный — JetBrains Mono, название — Cormorant Unicase 600', () {
      expect(monoTextStyle.fontFamily, 'JetBrains Mono');
      expect(displayTextStyle.fontFamily, 'Cormorant Unicase');
      expect(displayTextStyle.fontWeight, FontWeight.w600);
      expect(displayTextStyle.color, isNull);
      expect(
        projectNameStyle(color: AppPalette.light.textStrong).fontFamily,
        'Cormorant Unicase',
      );
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

    test('JetBrains Mono — только пароли и коды восстановления', () {
      const allowed = <String>{
        'lib/app/assistant_theme.dart',
        'lib/app/passwords/secret_widgets.dart',
        'lib/app/passwords/recovery_code_view.dart',
      };
      final offenders = <String>[];
      for (final entity in Directory('lib/app').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (allowed.contains(path)) continue;
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
    const p = AppPalette.dark;
    const spans = <CommandSpan>[
      CommandSpan(0, 13, CommandSpanKind.verb),
      CommandSpan(19, 25, CommandSpanKind.due),
    ];
    const text = 'Добавь задачу хлеб завтра';
    final base = TextStyle(fontSize: 17, color: p.textStrong);

    test('в ленте (plain) — обычный текст: без моно и без цвета', () {
      final span = highlightedCommand(
        text,
        spans,
        base,
        colors: p,
        mode: CommandSpanMode.plain,
      );
      expect(span.toPlainText(), text);
      for (final (_, style) in _flatten(span)) {
        expect(style.fontFamily, isNot(AppFonts.mono));
        expect(style.fontSize, 17);
        expect(style.color, p.textStrong);
      }
    });

    test('в поле ввода (subtle) — только глагол цветом и полужирным', () {
      for (final palette in <AppPalette>[AppPalette.dark, AppPalette.light]) {
        final span = highlightedCommand(
          text,
          spans,
          base.copyWith(color: palette.textStrong),
          colors: palette,
        );
        expect(span.toPlainText(), text);
        expect(_mono(span), isEmpty);
        expect(_tinted(span, palette.cmdTint), 'Добавь задачу');
        final parts = _flatten(span);
        expect(parts.first.$2.fontWeight, FontWeight.w600);
        expect(parts.first.$2.fontSize, 17);
        // Срок — как текст.
        expect(parts.last.$2.color, palette.textStrong);
      }
    });

    test('набираемое слово подчёркнуто и внутри подсветки', () {
      const typed = 'Добавь задачу';
      final span = highlightedCommand(
        typed,
        const <CommandSpan>[CommandSpan(0, 13, CommandSpanKind.verb)],
        const TextStyle(),
        colors: p,
        composing: const TextRange(start: 7, end: 13),
      );
      final parts = _flatten(span);
      expect(parts.map(((String, TextStyle) p) => p.$1), <String>[
        'Добавь ',
        'задачу',
      ]);
      expect(parts.last.$2.decoration, TextDecoration.underline);
      expect(parts.last.$2.color, p.cmdTint);
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
      // Версия — в «Настройки → О приложении», не в шапке (ADR-027).
      expect(find.byKey(const Key('app-version')), findsNothing);
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
        style: const TextStyle(fontSize: 17),
        withComposing: false,
      );
      // Без моноширинного шрифта; выделен только глагол.
      expect(_mono(span), isEmpty);
      expect(_tinted(span, AppPalette.dark.cmdTint), 'Добавь задачу');
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
        style: const TextStyle(fontSize: 17),
        withComposing: false,
      );
      expect(_mono(span), isEmpty);
      expect(_tinted(span, AppPalette.dark.cmdTint), isEmpty);
    });

    testWidgets('отправленная команда в ленте — обычный текст Inter 17',
        (tester) async {
      await _pump(tester);
      await _say(tester, 'Добавь задачу купить хлеб на завтра #дом');
      final rich = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((SelectableText t) => t.textSpan != null)
          .toList();
      expect(rich, hasLength(1));
      expect(_mono(rich.single.textSpan!), isEmpty);
      final colors = <Color?>{
        for (final (_, style) in _flatten(rich.single.textSpan!)) style.color,
      };
      expect(colors, <Color?>{AppPalette.dark.textStrong});
      for (final (_, style) in _flatten(rich.single.textSpan!)) {
        expect(style.fontSize, 17);
      }
      // Время под сообщениями и подписи — не моноширинным.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.style?.fontFamily, isNot(AppFonts.mono));
      }
    });

    testWidgets('калькулятор: числа в ленте — как обычный текст',
        (tester) async {
      await _pump(tester);
      await _say(tester, 'сколько будет 2+2*2');
      final rich = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((SelectableText t) => t.textSpan != null)
          .single;
      expect(_mono(rich.textSpan!), isEmpty);
      expect(_tinted(rich.textSpan!, AppPalette.dark.cmdTint), isEmpty);
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
