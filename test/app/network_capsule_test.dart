import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/network_status.dart';
import 'package:local_assistant/app/widgets/network_capsule.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/connectors/watched_transport.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Ответ или обрыв — по сценарию.
final class _Script implements HttpTransport {
  Object? fail;
  int status = 200;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    final error = fail;
    if (error != null) throw error;
    return HttpResponseData(statusCode: status);
  }
}

final _request = HttpRequestData(
  method: 'GET',
  uri: Uri.parse('https://warehouse.example/api.php?action=ask_me'),
);

Finder _capsule() => find.byKey(const Key('network-capsule'));

Future<void> _pumpCapsule(
  WidgetTester tester,
  NetworkStatus status, {
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: NetworkCapsule(status: status),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('NetworkStatus', () {
    test('нет сети → сеть есть на 2 с → скрыта', () {
      fakeAsync((FakeAsync async) {
        final status = NetworkStatus();
        var changes = 0;
        status.addListener(() => changes++);
        expect(status.visible, isFalse);
        status.restored(sent: 3);
        expect(status.visible, isFalse, reason: 'сеть и так была');
        status
          ..lost()
          ..lost();
        expect(status.offline, isTrue);
        expect(changes, 1, reason: 'повтор без перерисовки');
        status.restored(sent: 3);
        expect(status.offline, isFalse);
        expect(status.sent, 3);
        async.elapse(const Duration(milliseconds: 1999));
        expect(status.visible, isTrue);
        async.elapse(const Duration(milliseconds: 2));
        expect(status.visible, isFalse);
        expect(status.sent, isNull);
        status.dispose();
      });
    });

    test('связь снова пропала за 2 с — снова «Нет сети», без таймера', () {
      fakeAsync((FakeAsync async) {
        final status = NetworkStatus()
          ..lost()
          ..restored();
        expect(status.sent, 0);
        status.lost();
        async.elapse(const Duration(seconds: 3));
        expect(status.offline, isTrue);
        expect(status.visible, isTrue);
        status.dispose();
      });
    });
  });

  group('WatchedTransport', () {
    test(
        'ответ — связь есть, обрыв и статус 0 — нет, тайм-аут — ни то ни '
        'другое', () async {
      final inner = _Script();
      var up = 0;
      var down = 0;
      final watched = WatchedTransport(
        inner,
        onReachable: () => up++,
        onUnreachable: () => down++,
      );
      inner.status = 503;
      expect((await watched.send(_request)).statusCode, 503);
      expect((up, down), (1, 0));
      inner.status = 0;
      await watched.send(_request);
      expect((up, down), (1, 1));
      inner.fail = StateError('Failed to fetch');
      await expectLater(watched.send(_request), throwsStateError);
      expect((up, down), (1, 2));
      inner.fail = TimeoutException('медленно');
      await expectLater(
        watched.send(_request),
        throwsA(isA<TimeoutException>()),
      );
      expect((up, down), (1, 2));
    });
  });

  group('NetworkCapsule', () {
    testWidgets('скрыта, пока сеть есть; без сети — полная фраза',
        (WidgetTester tester) async {
      final status = NetworkStatus();
      addTearDown(status.dispose);
      await _pumpCapsule(tester, status);
      expect(_capsule(), findsNothing);
      status.lost();
      await tester.pumpAndSettle();
      expect(_capsule(), findsOneWidget);
      expect(find.text(NetworkCapsule.offlineText), findsOneWidget);
      // Плашка без рамки, янтарная точка — tileAmber светлой темы.
      final dot = tester
          .widgetList<Container>(
            find.descendant(of: _capsule(), matching: find.byType(Container)),
          )
          .map((Container c) => c.decoration)
          .whereType<BoxDecoration>()
          .single;
      expect(dot.color, AppPalette.light.tileAmber);
      expect(dot.shape, BoxShape.circle);
    });

    testWidgets('узко — короткая фраза; связь вернулась — «Сеть есть»',
        (WidgetTester tester) async {
      final status = NetworkStatus();
      addTearDown(status.dispose);
      await _pumpCapsule(tester, status, width: 390);
      status.lost();
      await tester.pumpAndSettle();
      expect(find.text(NetworkCapsule.offlineShort), findsOneWidget);
      expect(find.text(NetworkCapsule.offlineText), findsNothing);
      status.restored(sent: 2);
      await tester.pumpAndSettle();
      expect(find.text('Сеть есть · отправлено 2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(_capsule(), findsNothing);
    });

    testWidgets('появляется плавно: высота растёт, а не скачет',
        (WidgetTester tester) async {
      final status = NetworkStatus();
      addTearDown(status.dispose);
      await _pumpCapsule(tester, status);
      final box = find.byType(NetworkCapsule);
      expect(tester.getSize(box).height, 0);
      status.lost();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getSize(box).height;
      await tester.pumpAndSettle();
      final full = tester.getSize(box).height;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(full));
    });
  });

  testWidgets('приложение: капсула над полем ввода, только без сети',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 4, 12));
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final network = NetworkStatus();
    addTearDown(network.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: AssistantController(
            connectors: <Connector>[
              TasksConnector(
                taskService: tasks,
                parser: ScenarioParser(clock: clock),
              ),
            ],
            clock: clock,
          ),
          tasks: tasks,
          clock: clock,
          network: network,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_capsule(), findsNothing);
    final input = find.byKey(const Key('assistant-input'));
    final bottom = tester.getBottomLeft(input).dy;

    network.lost();
    await tester.pumpAndSettle();
    expect(_capsule(), findsOneWidget);
    expect(find.text(NetworkCapsule.offlineShort), findsOneWidget);
    expect(
      tester.getBottomLeft(_capsule()).dy,
      lessThanOrEqualTo(tester.getTopLeft(input).dy),
    );
    expect(tester.getBottomLeft(input).dy, closeTo(bottom, 0.1));

    // В приложении очереди нет — просто «Сеть есть».
    network.restored();
    await tester.pumpAndSettle();
    expect(find.text('Сеть есть'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_capsule(), findsNothing);
  });
}
