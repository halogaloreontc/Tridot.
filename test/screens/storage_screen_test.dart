import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/storage_screen.dart';
import 'package:local_assistant/app/widgets/task_tile.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/storage/storage_info.dart';

final class FakeStorageInfo implements StorageInfo {
  FakeStorageInfo({
    this.label = 'JSON на этом устройстве',
    this.location = '/data/tasks.json',
    this.size = 12698,
    this.canBackup = true,
    this.backupError,
  });

  @override
  final String label;

  @override
  final String? location;

  @override
  String? get chatsLocation => null;

  final int? size;

  @override
  final bool canBackup;

  final Object? backupError;
  Completer<String>? pending;
  int backupCalls = 0;

  @override
  Future<int?> sizeBytes() async => size;

  @override
  Future<String> backup() {
    backupCalls++;
    final error = backupError;
    if (error != null) return Future<String>.error(error);
    final completer = Completer<String>();
    pending = completer;
    return completer.future;
  }
}

final now = DateTime(2026, 11, 5, 12);

Task doneTask(int i) => Task(
      id: 't$i',
      title: 'Задача $i',
      status: TaskStatus.done,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 4),
      completedAt: DateTime(2026, 11, 4),
      dueAt: DateTime(2026, 11, 4, 18),
      tags: const <String>['дом'],
    );

Widget host(
  StorageInfo info, {
  List<Task> completed = const <Task>[],
  int activeCount = 3,
  Future<void> Function(Task)? onReopen,
}) {
  return MaterialApp(
    theme: AssistantTheme.dark(),
    home: Scaffold(
      body: StorageScreen(
        info: info,
        activeCount: activeCount,
        completed: completed,
        now: now,
        onReopen: onReopen ?? (_) async {},
      ),
    ),
  );
}

void main() {
  test('formatBytes uses Б/КБ/МБ and a decimal comma', () {
    expect(formatBytes(0), '0 Б');
    expect(formatBytes(-5), '0 Б');
    expect(formatBytes(1023), '1023 Б');
    expect(formatBytes(1024), '1,0 КБ');
    expect(formatBytes(12698), '12,4 КБ');
    expect(formatBytes(1024 * 1024 - 1), '1,0 МБ');
    expect(formatBytes(1024 * 1024), '1,0 МБ');
    expect(formatBytes(5 * 1024 * 1024 + 300 * 1024), '5,3 МБ');
  });

  testWidgets('shows label, location, size and counts', (tester) async {
    await tester.pumpWidget(
      host(FakeStorageInfo(), completed: <Task>[doneTask(1)]),
    );
    await tester.pumpAndSettle();
    // Экран зовётся «Данные»: «Хранилище» оставлено за «Хранилищем
    // контекста» (docs/PLANS.md).
    expect(find.text('Данные'), findsOneWidget);
    expect(find.textContaining('Хранилищ'), findsNothing);
    expect(find.text('JSON на этом устройстве'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('/data/tasks.json'), findsOneWidget);
    expect(find.text('12,4 КБ'), findsOneWidget);
    expect(find.text('активных: 3 · выполненных: 1'), findsOneWidget);
  });

  testWidgets('memory storage: no file, dash size, backup disabled, empty',
      (tester) async {
    await tester.pumpWidget(host(const MemoryStorageInfo()));
    await tester.pumpAndSettle();
    expect(find.text('только в памяти'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey<String>('storage-backup')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text('Данные только в памяти — копия недоступна'),
      findsOneWidget,
    );
    expect(find.textContaining('Хранилищ'), findsNothing);
    expect(find.byType(EmptyState), findsOneWidget);
  });

  test('memory storage: backup error names the data, not «Хранилище»',
      () async {
    await expectLater(
      const MemoryStorageInfo().backup(),
      throwsA(
        isA<UnsupportedError>()
            .having((e) => e.message, 'message', 'Данные только в памяти'),
      ),
    );
  });

  testWidgets('backup success shows progress, then the path', (tester) async {
    final info = FakeStorageInfo();
    await tester.pumpWidget(host(info));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('storage-backup')));
    await tester.pump();
    expect(info.backupCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    info.pending!.complete('/data/tasks.backup-1.json');
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.text('Копия сохранена: /data/tasks.backup-1.json'),
      findsOneWidget,
    );
  });

  testWidgets('backup failure shows the error', (tester) async {
    final info = FakeStorageInfo(
      backupError: StateError('Задач ещё нет — копировать нечего'),
    );
    await tester.pumpWidget(host(info));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('storage-backup')));
    await tester.pumpAndSettle();
    expect(
      find.text('Не удалось: Задач ещё нет — копировать нечего'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('reopen calls back and confirms', (tester) async {
    final reopened = <Task>[];
    await tester.pumpWidget(
      host(
        FakeStorageInfo(),
        completed: <Task>[doneTask(1)],
        onReopen: (task) async => reopened.add(task),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('toggle-t1')));
    await tester.pumpAndSettle();
    expect(reopened.single.id, 't1');
    expect(find.text('«Задача 1» снова в работе'), findsOneWidget);
  });

  testWidgets('shows 20 completed tasks, then more', (tester) async {
    final tasks = List<Task>.generate(45, doneTask);
    await tester.pumpWidget(host(FakeStorageInfo(), completed: tasks));
    await tester.pumpAndSettle();
    final tiles = find.byType(TaskTile, skipOffstage: false);
    final more = find.byKey(const ValueKey<String>('archive-more'));
    expect(tiles, findsNWidgets(20));
    expect(find.text('Показать ещё · 25', skipOffstage: false), findsOneWidget);
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(tiles, findsNWidgets(40));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(tiles, findsNWidgets(45));
    expect(find.byKey(const ValueKey<String>('archive-more')), findsNothing);
  });

  testWidgets('no overflow at 320x640 with textScaler 2.0', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      host(
        FakeStorageInfo(
          location: '/storage/emulated/0/Android/data/very/long/path/'
              'tasks.json',
        ),
        completed: List<Task>.generate(25, doneTask),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final backup = find.byKey(const ValueKey<String>('storage-backup'));
    await tester.ensureVisible(backup);
    await tester.pumpAndSettle();
    await tester.tap(backup);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1600 wide', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const MemoryStorageInfo()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
