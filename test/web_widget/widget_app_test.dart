import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/widgets/message_row.dart';
import 'package:local_assistant/web_widget/widget_app.dart';
import 'package:local_assistant/web_widget/widget_session.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';

import 'fakes.dart';

void main() {
  late FakeWarehouse server;
  late FakeHost host;
  late WidgetSession session;

  setUp(() {
    server = FakeWarehouse();
    host = FakeHost();
    session = WidgetSession(
      host: host,
      transport: server,
      storage: MemoryStorage(),
      builtInManifest: builtInSource(),
      version: '1.0.0',
      updateEvery: const Duration(hours: 1),
    );
  });

  tearDown(() => session.dispose());

  Future<void> openPanel(
    WidgetTester tester, {
    Map<String, Object?> voice = const <String, Object?>{
      'available': false,
      'reason': 'web',
    },
  }) async {
    await tester.pumpWidget(WidgetApp(session: session));
    await tester.runAsync(() async {
      session.start();
      host.emit(initMessage(voice: voice));
      await settle();
    });
    await tester.pump();
  }

  testWidgets('ждёт склад, потом чат «Связной» с именем сотрудника',
      (WidgetTester tester) async {
    await tester.pumpWidget(WidgetApp(session: session));
    expect(find.text('Подключаюсь к складу…'), findsOneWidget);
    await openPanel(tester);
    expect(find.text('Связной'), findsOneWidget);
    expect(find.text('Иван Петров · Кладовщик'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('widget-input')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('widget-mic')), findsNothing);
  });

  testWidgets(
      'пустой чат — как новая сессия: «Что сделать?» и примеры '
      'кнопками, нажатие спрашивает', (WidgetTester tester) async {
    await openPanel(tester);
    expect(find.text('Что сделать?'), findsOneWidget);
    expect(find.text('Склад'), findsOneWidget);
    final example = find.byKey(
      const ValueKey<String>('widget-example-где лежит 64115'),
    );
    expect(example, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(example);
      await settle();
    });
    await tester.pump();
    expect(session.messages.first.text, 'где лежит 64115');
    expect(find.text('Что сделать?'), findsNothing);
    expect(example, findsNothing);
  });

  testWidgets(
      'лента как в приложении: метка времени группы и имя над '
      'ответом', (WidgetTester tester) async {
    await openPanel(tester);
    await tester.runAsync(() async {
      await session.send('посчитай 12 * 7');
      await settle();
    });
    await tester.pump();
    expect(find.byType(GroupTime), findsOneWidget);
    expect(find.byType(MessageRow), findsNWidgets(2));
    expect(find.textContaining('84'), findsWidgets);
    // Имя Связного — в шапке и над ответом.
    expect(find.text('Связной'), findsNWidgets(2));
  });

  testWidgets('вопрос из поля ввода — ответ в ленте',
      (WidgetTester tester) async {
    // Ответ «что умеет склад» длинный: вопрос над ним должен поместиться в
    // окно вместе с кнопкой «Копировать» под ответом.
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openPanel(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('widget-input')),
      'что умеет склад',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('widget-send')));
      await settle();
    });
    await tester.pump();
    expect(find.text('что умеет склад'), findsOneWidget);
    expect(session.messages, hasLength(2));
  });

  testWidgets('после Enter курсор остаётся в поле — следующий вопрос сразу',
      (WidgetTester tester) async {
    await openPanel(tester);
    final input = find.byKey(const ValueKey<String>('widget-input'));
    await tester.tap(input);
    await tester.enterText(input, 'что умеет склад');
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await settle();
    });
    await tester.pump();
    expect(session.messages, hasLength(2));
    final field = tester.widget<TextField>(input);
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('Escape закрывает панель сразу после открытия, без щелчка',
      (WidgetTester tester) async {
    await tester.pumpWidget(WidgetApp(session: session));
    await tester.runAsync(() async {
      session.start();
      host.emit(initMessage(device: 'desktop'));
      await settle();
    });
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(host.sent.last['type'], 'close');
  });

  testWidgets('в оболочке Android 12+ есть микрофон',
      (WidgetTester tester) async {
    await openPanel(
      tester,
      voice: const <String, Object?>{'available': true, 'reason': 'ok'},
    );
    await tester.tap(find.byKey(const ValueKey<String>('widget-mic')));
    await tester.pump();
    expect(host.sent.last['op'], 'start');
    expect(find.text('Слушаю…'), findsOneWidget);
  });

  testWidgets('«Закрыть» — сообщение странице', (WidgetTester tester) async {
    await openPanel(tester);
    await tester.tap(find.byKey(const ValueKey<String>('widget-close')));
    expect(host.sent.last['type'], 'close');
  });

  testWidgets('Escape на компьютере закрывает панель',
      (WidgetTester tester) async {
    await tester.pumpWidget(WidgetApp(session: session));
    await tester.runAsync(() async {
      session.start();
      host.emit(initMessage(device: 'desktop'));
      await settle();
    });
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(host.sent.last['type'], 'close');
  });

  testWidgets('Enter в пустом поле не уводит фокус — Escape закрывает',
      (WidgetTester tester) async {
    await tester.pumpWidget(WidgetApp(session: session));
    await tester.runAsync(() async {
      session.start();
      host.emit(initMessage(device: 'desktop'));
      await settle();
    });
    await tester.pump();
    final input = find.byKey(const ValueKey<String>('widget-input'));
    await tester.tap(input);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(host.sent.last['type'], 'close');
  });

  testWidgets(
      'без распознавания речи долгое нажатие на поле не включает '
      'голос', (WidgetTester tester) async {
    await openPanel(
      tester,
      voice: const <String, Object?>{'available': false, 'reason': 'no-lang'},
    );
    final sent = host.sent.length;
    await tester.longPress(find.byKey(const ValueKey<String>('widget-input')));
    await tester.pump();
    expect(host.sent.skip(sent).where((m) => m['type'] == 'voice'), isEmpty);
  });

  testWidgets('Shift+Enter не выводит текст за 500 знаков',
      (WidgetTester tester) async {
    await openPanel(tester);
    final input = find.byKey(const ValueKey<String>('widget-input'));
    await tester.tap(input);
    await tester.enterText(input, 'а' * 500);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, hasLength(500));
  });

  testWidgets('смена темы склада доходит без нового входа',
      (WidgetTester tester) async {
    await openPanel(tester);
    final chat = find.byType(WidgetChat);
    expect(Theme.of(tester.element(chat)).brightness, Brightness.light);
    final sent = host.sent.length;
    await tester.runAsync(() async {
      host.emit(<String, Object?>{'svz': 1, 'type': 'theme', 'theme': 'dark'});
      await settle();
    });
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(chat)).brightness, Brightness.dark);
    expect(host.sent.length, sent, reason: 'ни ключа, ни hello заново');
    expect(session.messages, isEmpty);
  });

  testWidgets('открыт не из склада — подсказка', (WidgetTester tester) async {
    final alone = WidgetSession(
      host: FakeHost(embedded: false),
      transport: server,
      storage: MemoryStorage(),
      builtInManifest: null,
      version: 'dev',
    );
    await tester.pumpWidget(WidgetApp(session: alone));
    alone.start();
    await tester.pump();
    expect(find.textContaining('шапке склада'), findsOneWidget);
    alone.dispose();
  });
}
