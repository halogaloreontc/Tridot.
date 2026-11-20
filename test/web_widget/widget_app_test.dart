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
    // Шапка сессии приложения: «Новая сессия ▾» и кто отвечает.
    expect(find.byKey(const Key('session-title')), findsOneWidget);
    expect(find.text('Связной'), findsWidgets);
    expect(find.byKey(const Key('session-hero')), findsOneWidget);
    expect(find.textContaining('Иван Петров · Кладовщик'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('widget-input')), findsOneWidget);
    expect(find.byKey(const Key('assistant-voice')), findsNothing);
  });

  testWidgets('вопрос из поля ввода — ответ в ленте',
      (WidgetTester tester) async {
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
    // Пузырь, строка разговора слева и название в заголовке.
    expect(find.text('что умеет склад'), findsWidgets);
    expect(session.messages, hasLength(2));
    expect(find.byType(MessageRow), findsWidgets);
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
    await tester.tap(find.byKey(const Key('assistant-voice')));
    await tester.pump();
    expect(host.sent.last['op'], 'start');
    expect(find.text('Говорите…'), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey<String>('widget-input')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(host.sent.last['type'], 'close');
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

  group('разговоры, проекты, задачи (ADR-038)', () {
    Future<void> sized(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('панель 420: меню приложения по кнопке в шапке',
        (WidgetTester tester) async {
      await sized(tester, const Size(420, 800));
      await openPanel(tester);
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('widget-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('drawer-my-relay')), findsOneWidget);
      expect(find.text('Задачи'), findsOneWidget);
      expect(find.text('Проекты'), findsOneWidget);
      expect(find.byKey(const Key('new-session')), findsOneWidget);
      expect(find.text('на связи'), findsOneWidget);
      // «Мой Связной» — «Сегодня» внутри помощника, меню закрывается.
      await tester.tap(find.byKey(const Key('drawer-my-relay')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      expect(find.byKey(const Key('today-panel')), findsOneWidget);
    });

    testWidgets('телефон 390: меню выдвигается, сессия открывается из него',
        (WidgetTester tester) async {
      await sized(tester, const Size(390, 760));
      await openPanel(tester);
      await tester.runAsync(() async {
        await session.send('2+2');
        await settle();
        await session.newChat();
        await settle();
      });
      await tester.pump();
      final first = session.book!.sessions().last;
      await tester.tap(find.byKey(const ValueKey<String>('widget-menu')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key('chat-${first.id}')));
        await settle();
      });
      await tester.pumpAndSettle();
      expect(session.book!.currentId, first.id);
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      expect(find.text('2+2'), findsWidgets);
    });

    testWidgets('широкая панель: меню колонкой слева, задачи — экраном',
        (WidgetTester tester) async {
      await sized(tester, const Size(760, 800));
      await openPanel(tester);
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('widget-menu')), findsNothing);
      await tester.runAsync(() async {
        await session.send('добавь задачу проверить акт 12-26');
        await settle();
      });
      await tester.pump();
      final task = session.taskList.single;
      await tester.tap(find.text('Задачи'));
      await tester.pump();
      expect(find.byKey(const Key('tasks-screen')), findsOneWidget);
      expect(find.byKey(ValueKey<String>('task-${task.id}')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(ValueKey<String>('toggle-${task.id}')));
        await settle();
      });
      await tester.pump();
      expect(session.taskList.single.status.name, 'done');
      // Колонку можно свернуть — тогда меню кнопкой в шапке.
      await tester.tap(find.byKey(const Key('sidebar-collapse')));
      await tester.pump();
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('widget-menu')),
        findsOneWidget,
      );
    });

    testWidgets(
        'open-project: склад открывает экран проекта, «Назад» — в '
        'разговор', (WidgetTester tester) async {
      await sized(tester, const Size(420, 800));
      await openPanel(tester);
      final project = session.createProject('Брак Ромашка')!;
      await tester.runAsync(() async {
        host.emit(<String, Object?>{
          'svz': 1,
          'type': 'open-project',
          'id': project.id,
        });
        await settle();
      });
      await tester.pump();
      expect(find.byKey(const Key('project-screen')), findsOneWidget);
      expect(find.byKey(const Key('project-title')), findsOneWidget);
      expect(find.text('Брак Ромашка'), findsWidgets);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('project-new-session')));
        await settle();
      });
      await tester.pump();
      expect(session.view, WidgetView.chat);
      expect(session.book!.current.projectId, project.id);
      expect(find.byKey(const Key('hero-project')), findsOneWidget);
      session.show(WidgetView.project, project: project.id);
      await tester.pump();
      await tester.runAsync(() async {
        host.emit(<String, Object?>{'svz': 1, 'type': 'back'});
        await settle();
      });
      await tester.pump();
      expect(find.byKey(const Key('project-screen')), findsNothing);
      expect(host.types, isNot(contains('close')));
    });

    testWidgets('напоминание склада над лентой, «Отложить» убирает',
        (WidgetTester tester) async {
      await sized(tester, const Size(420, 800));
      await openPanel(tester);
      await tester.runAsync(() async {
        host.emit(<String, Object?>{
          'svz': 1,
          'type': 'signal',
          'items': <Object?>[
            <String, Object?>{
              'id': 'ship.collect:gr9:1',
              'title': 'Отгрузка ГР-00009 не собрана 26 ч',
              'actions': <Object?>[
                <String, Object?>{
                  'id': 'open',
                  'label': 'Открыть',
                  'open': '#/ship/gr9',
                },
              ],
            },
          ],
        });
        await settle();
      });
      await tester.pump();
      expect(
        find.text('Напоминание: Отгрузка ГР-00009 не собрана 26 ч'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('reminder-open')));
      await tester.pump();
      expect(host.sent.last['hash'], '#/ship/gr9');
      await tester.tap(find.byKey(const ValueKey<String>('reminder-close')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('widget-reminders')),
        findsNothing,
      );
    });

    testWidgets('склад умеет широкую панель — кнопка просит layout',
        (WidgetTester tester) async {
      await sized(tester, const Size(420, 800));
      await tester.pumpWidget(WidgetApp(session: session));
      await tester.runAsync(() async {
        session.start();
        host.emit(<String, Object?>{
          ...initMessage(device: 'desktop'),
          'layout': <String, Object?>{'can': true, 'wide': false},
        });
        await settle();
      });
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('widget-wide')));
      await tester.pump();
      expect(host.sent.last['type'], 'layout');
      expect(host.sent.last['wide'], isTrue);
    });
  });
}
