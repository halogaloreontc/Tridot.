import 'dart:ui' show CheckedState, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/bulk_checklist_card.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../support/home_nav.dart';

/// Карточка массовой команды в чате: галочки, счётчик, применение, отмена,
/// узкий экран с крупным шрифтом и широкий экран.
final _clock = FixedClock(DateTime(2026, 11, 4, 12)); // среда

final class _Harness {
  _Harness(this.tasks, this.assistant, this.ids, this.settings);

  final TaskService tasks;
  final AssistantController assistant;
  final List<String> ids;
  final InMemorySettingsStore settings;

  Future<Task> task(String id) async =>
      (await tasks.listAll()).firstWhere((Task t) => t.id == id);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(1300, 900),
  int extra = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final ids = <String>[
    (await tasks.create(
      title: 'Купить хлеб',
      dueAt: DateTime(2026, 11, 3),
      duePrecision: DuePrecision.date,
    ))
        .id,
    (await tasks.create(
      title: 'Сдать отчёт за квартал по всем филиалам компании',
      dueAt: DateTime(2026, 11, 4, 18),
    ))
        .id,
    (await tasks.create(title: 'Придумать подарок')).id,
    for (var i = 0; i < extra; i++) (await tasks.create(title: 'Дело $i')).id,
  ];
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
    ],
    clock: _clock,
  );
  final settings = InMemorySettingsStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(tasks, assistant, ids, settings);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _apply() => find.byKey(const Key('bulk-apply'));

String _applyLabel(WidgetTester tester) =>
    (tester.widget<FilledButton>(_apply()).child! as Text).data!;

/// Прокручивает список карточки и чат так, чтобы [finder] был виден
/// целиком: на узком экране с крупным шрифтом окно чата ниже карточки.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  Future<void> scroll(Finder viewport, {required bool reverse}) async {
    if (viewport.evaluate().isEmpty) return;
    final scrollable =
        find.descendant(of: viewport, matching: find.byType(Scrollable)).first;
    var area = tester.getRect(viewport);
    // Верх ленты закрыт хроникой команд поверх неё: цель — ниже хроники.
    final pill = find.byKey(const Key('history-rail-pill'));
    if (reverse && pill.evaluate().isNotEmpty) {
      final under = tester.getRect(pill).bottom;
      if (under > area.top) {
        area = Rect.fromLTRB(area.left, under, area.right, area.bottom);
      }
    }
    final target = tester.getRect(finder);
    double delta = 0;
    if (target.top < area.top) delta = target.top - area.top - 8;
    if (target.bottom > area.bottom) delta = target.bottom - area.bottom + 8;
    if (delta == 0) return;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(
      (position.pixels + (reverse ? -delta : delta))
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    await tester.pump();
  }

  final inner =
      find.ancestor(of: finder, matching: find.byKey(const Key('bulk-list')));
  await scroll(inner, reverse: false);
  await scroll(find.byKey(const Key('chat-list')), reverse: true);
}

/// Верх видимой части ленты: под хроникой команд, если она есть.
double _visibleTop(WidgetTester tester, Rect chat) {
  final pill = find.byKey(const Key('history-rail-pill'));
  if (pill.evaluate().isEmpty) return chat.top;
  return tester.getRect(pill).bottom.clamp(chat.top, chat.bottom);
}

/// Точка для жеста по ленте: середина окна чата, но не на прокручиваемом
/// списке карточки (жест на нём листает список) и не на хронике сверху.
Offset _dragPoint(WidgetTester tester, Rect chat) {
  final list = find.byKey(const Key('bulk-list'));
  final top = _visibleTop(tester, chat);
  final free = Rect.fromLTRB(chat.left, top, chat.right, chat.bottom);
  if (list.evaluate().isEmpty) return free.center;
  final busy = tester.getRect(list);
  if (!busy.contains(free.center)) return free.center;
  final below = Rect.fromLTRB(free.left, busy.bottom, free.right, free.bottom);
  final above = Rect.fromLTRB(free.left, free.top, free.right, busy.top);
  if (below.height >= above.height && below.height > 8) return below.center;
  if (above.height > 8) return above.center;
  return free.center;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('галочки меняют счётчик, «Перенести (N)» применяет отмеченные',
      (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');

    expect(find.byType(BulkChecklistCard), findsOneWidget);
    expect(find.text('→ сб, 7 ноября'), findsOneWidget);
    expect(_applyLabel(tester), 'Перенести (3)');
    expect(find.text('отмечено 3 из 3'), findsOneWidget);

    await _tap(tester, find.byKey(ValueKey<String>('bulk-item-${h.ids[0]}')));
    expect(_applyLabel(tester), 'Перенести (2)');
    expect(find.text('отмечено 2 из 3'), findsOneWidget);
    // Галочка — не сообщение: вопрос ждёт ответа.
    expect(h.assistant.pendingChecklist, isNotNull);

    await _tap(tester, _apply());
    expect(find.text('Перенесено 2 из 3'), findsOneWidget);
    expect(_apply(), findsNothing);
    expect((await h.task(h.ids[0])).dueAt, DateTime(2026, 11, 3));
    expect((await h.task(h.ids[1])).dueAt, DateTime(2026, 11, 7));
    expect((await h.task(h.ids[2])).dueAt, DateTime(2026, 11, 7));
    // Итог — только для чтения.
    final tile = tester.widget<CheckboxListTile>(
      find.byKey(ValueKey<String>('bulk-item-${h.ids[0]}')),
    );
    expect(tile.onChanged, isNull);

    await _tap(tester, find.byKey(const Key('bulk-undo')));
    expect(find.text('Отменено — всё вернулось как было'), findsOneWidget);
    expect(find.byKey(const Key('bulk-undo')), findsNothing);
    expect((await h.task(h.ids[1])).dueAt, DateTime(2026, 11, 4, 18));
    expect((await h.task(h.ids[2])).dueAt, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('«Снять все» выключает кнопку, «Выбрать все» возвращает',
      (tester) async {
    await _pump(tester);
    await _say(tester, 'закрой всё');
    expect(_applyLabel(tester), 'Отметить (3)');
    expect(find.text('Отметить выполненными'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('bulk-select-all')));
    expect(_applyLabel(tester), 'Отметить (0)');
    expect(tester.widget<FilledButton>(_apply()).onPressed, isNull);
    expect(find.text('Выбрать все'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('bulk-select-all')));
    expect(_applyLabel(tester), 'Отметить (3)');

    await _tap(tester, find.byKey(const Key('bulk-cancel')));
    expect(find.text('Ничего не изменено'), findsOneWidget);
  });

  testWidgets(
      '«кроме …» в чате переносит карточку под новый вопрос, «да» '
      'применяет', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');
    await _say(tester, 'кроме хлеба');

    expect(find.byType(BulkChecklistCard), findsOneWidget);
    expect(_applyLabel(tester), 'Перенести (2)');
    expect(find.textContaining('Снял отметку: «Купить хлеб»'), findsOneWidget);

    await _say(tester, 'да');
    expect(find.text('Перенесено 2 из 3'), findsOneWidget);
    expect(
      find.textContaining('Перенёс на 7 ноября 2 задачи из 3'),
      findsOneWidget,
    );
    expect((await h.task(h.ids[0])).dueAt, DateTime(2026, 11, 3));

    await _say(tester, 'отмени');
    expect(find.text('Отменено — всё вернулось как было'), findsOneWidget);
  });

  testWidgets(
      'постороннее сообщение — вопрос устарел, карточка только читается',
      (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');
    await _say(tester, 'покажи задачи');

    expect(find.text('Вопрос устарел — повторите команду'), findsOneWidget);
    expect(_apply(), findsNothing);
    await _say(tester, 'да');
    expect((await h.task(h.ids[2])).dueAt, isNull);
  });

  testWidgets('смена настроек помощников не сбрасывает список', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');
    await _tap(tester, find.byKey(ValueKey<String>('bulk-item-${h.ids[0]}')));

    // Через «Мой Связной → Помощники»: режим, обращение и эмодзи.
    await openMyRelay(tester, 'assistants');
    for (final key in <String>[
      'assistant-mode-solo',
      'address-ty',
      'setting-emoji',
    ]) {
      final control = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      await tester.tap(control);
      await tester.pumpAndSettle();
    }
    expect(h.assistant.personas.mode, AssistantMode.solo);
    await backToSession(tester);
    expect(_applyLabel(tester), 'Перенести (2)');
    expect(h.assistant.pendingChecklist, isNotNull);
    await _tap(tester, _apply());
    expect(find.text('Перенесено 2 из 3'), findsOneWidget);
  });

  testWidgets('очистка чата снимает вопрос', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');
    final checklist = h.assistant.pendingChecklist!;
    await openSettings(tester);
    final clear = find.byKey(const ValueKey<String>('clear-chat'));
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('clear-chat-confirm')));
    await tester.pumpAndSettle();
    expect(h.assistant.pendingChecklist, isNull);
    expect(checklist.state, BulkChecklistState.expired);
  });

  for (final (name, size) in <(String, Size)>[
    ('320 px', const Size(320, 640)),
    ('телефон', const Size(390, 844)),
    ('настольный', const Size(1600, 1000)),
  ]) {
    testWidgets('$name при крупном шрифте: без переполнения, кнопки нажимаются',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = await _pump(tester, size: size, extra: 40);
      await _say(tester, 'перенеси всё на выходные');
      expect(tester.takeException(), isNull);
      expect(find.byType(BulkChecklistCard), findsOneWidget);
      expect(_applyLabel(tester), 'Перенести (43)');
      // Длинный список прокручивается внутри карточки, но занимает не
      // больше половины окна чата; в тесном окне — целиком, вместе с чатом.
      final list = tester.getSize(find.byKey(const Key('bulk-list')));
      final viewport = tester.getSize(find.byKey(const Key('chat-list')));
      final limit = BulkChecklistCard.listHeightFor(viewport.height);
      if (limit == null) {
        expect(list.height, greaterThan(viewport.height));
      } else {
        expect(list.height, lessThanOrEqualTo(viewport.height / 2));
        expect(list.height, lessThanOrEqualTo(BulkChecklistCard.listMaxHeight));
      }
      final card = tester.getRect(find.byType(BulkChecklistCard));
      expect(card.width, lessThanOrEqualTo(size.width));
      expect(tester.getSize(_apply()).height, greaterThanOrEqualTo(40));

      await _tap(tester, find.byKey(const Key('bulk-select-all')));
      // Длинное название на узком экране — строка выше окна чата:
      // нажимаем саму галочку.
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(ValueKey<String>('bulk-item-${h.ids[1]}')),
          matching: find.byType(Checkbox),
        ),
      );
      expect(_applyLabel(tester), 'Перенести (1)');
      await _tap(tester, _apply());
      expect(find.text('Перенесено 1 из 43'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in <(String, Size)>[
    ('320 px', const Size(320, 640)),
    ('телефон', const Size(390, 844)),
  ]) {
    testWidgets('$name, крупный шрифт: кнопки карточки докручиваются жестом',
        (tester) async {
      // Регрессия: список карточки по высоте экрана занимал всё окно чата,
      // и жест прокручивал только список — кнопки под ним были недосягаемы.
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, size: size, extra: 40);
      await _say(tester, 'перенеси всё на выходные');
      final chat = tester.getRect(find.byKey(const Key('chat-list')));
      // Сначала вверх, к началу карточки, потом жестами в середине окна
      // чата — вниз, пока кнопка не покажется целиком.
      for (var i = 0; i < 80; i++) {
        final card = tester.getRect(find.byType(BulkChecklistCard));
        if (card.top >= chat.top) break;
        await tester.dragFrom(_dragPoint(tester, chat), const Offset(0, 300));
        await tester.pumpAndSettle();
      }
      var visible = false;
      for (var i = 0; i < 120 && !visible; i++) {
        final apply =
            _apply().evaluate().isEmpty ? null : tester.getRect(_apply());
        visible = apply != null &&
            apply.top >= _visibleTop(tester, chat) &&
            apply.bottom <= chat.bottom;
        if (visible) break;
        await tester.dragFrom(_dragPoint(tester, chat), const Offset(0, -100));
        await tester.pumpAndSettle();
      }
      expect(visible, isTrue, reason: 'кнопка «Перенести» недосягаема');
      await tester.tap(_apply());
      await tester.pumpAndSettle();
      expect(find.text('Перенесено 43 из 43'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Tab обходит карточку подряд, не уходя в панель задач',
      (tester) async {
    // Регрессия: без своей группы обхода фокус чередовал строки карточки
    // с задачами и переключателями правой панели.
    final h = await _pump(tester, size: const Size(1440, 900), extra: 3);
    await _say(tester, 'перенеси всё на выходные');
    final order = <String>[];
    for (var i = 0; i < 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus == null) continue;
      final card = find.byType(BulkChecklistCard);
      final inCard = find
          .descendant(
            of: card,
            matching: find.byElementPredicate(
              (Element e) => identical(e, focus),
            ),
          )
          .evaluate()
          .isNotEmpty;
      String? key;
      focus.visitAncestorElements((Element e) {
        final k = e.widget.key;
        if (k is ValueKey<String> && k.value.startsWith('bulk-item-')) {
          key = k.value;
          return false;
        }
        if (k == const Key('bulk-select-all') ||
            k == const Key('bulk-apply') ||
            k == const Key('bulk-cancel')) {
          key = (k! as ValueKey<String>).value;
          return false;
        }
        return true;
      });
      order.add(inCard ? key ?? 'card' : 'outside');
    }
    final first = order.indexOf('bulk-select-all');
    expect(first, greaterThanOrEqualTo(0), reason: '$order');
    final ids = h.ids;
    final expected = <String>[
      'bulk-select-all',
      for (final id in ids) 'bulk-item-$id',
      'bulk-apply',
      'bulk-cancel',
    ];
    final run = <String>[
      for (final key in order.skip(first).take(expected.length * 2))
        if (key != 'card') key,
    ].take(expected.length).toList();
    expect(run, expected, reason: '$order');
  });

  testWidgets('строки списка доступны: подпись и отметка', (tester) async {
    final handle = tester.ensureSemantics();
    final h = await _pump(tester);
    await _say(tester, 'перенеси всё на выходные');
    final node = tester.getSemantics(
      find.byKey(ValueKey<String>('bulk-item-${h.ids[0]}')),
    );
    expect(node.label, contains('Купить хлеб'));
    expect(node.label, contains('вчера'));
    expect(
      node.getSemanticsData().flagsCollection.isChecked,
      CheckedState.isTrue,
    );
    expect(
      tester
          .getSemantics(_apply())
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    handle.dispose();
  });
}
