import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/intent/intent_kit.dart';
import 'package:local_assistant/app/intent/intent_section.dart';
import 'package:local_assistant/app/intent/unclear_export_screen.dart';
import 'package:local_assistant/app/intent/unclear_phrases_screen.dart';
import 'package:local_assistant/app/intent/unclear_share.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/intent/intent_memory.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:path/path.dart' as p;

import '../support/fake_voice.dart';
import 'intent_kit_fakes.dart';

final DateTime _now = DateTime(2026, 11, 20, 12);

/// Раздел с подделками: настройки меняются как в приложении.
final class _Rig {
  _Rig(this.kit, this.host, this.transport, this.downloader, this.root);

  final IntentKit kit;
  final FakeIntentHost host;
  final FakeReleaseTransport transport;
  final FakeFileDownloader downloader;
  final String root;
  AppSettings settings = const AppSettings();
  final List<AppSettings> changes = <AppSettings>[];

  /// Выпуск [version]: архивы обоих уровней, отдаётся [serve].
  List<int> publish(String version, {String serve = 'light', String? sha}) {
    final zips = <String, List<int>>{
      'light': fakePackZip(version: version),
      'accurate': fakePackZip(tier: 'accurate', version: version),
    };
    transport.latest(fakeLatestJson(version, zips, sha: sha));
    downloader.bytes = zips[serve]!;
    return zips[serve]!;
  }
}

Future<_Rig> _rig(WidgetTester tester) async {
  final temp = Directory.systemTemp.createTempSync('intent_section_test');
  addTearDown(() => temp.deleteSync(recursive: true));
  final root = p.join(temp.path, 'assistant', 'intent');
  final host = FakeIntentHost(
    memory: IntentMemory(
      store: InMemoryIntentMemoryStore(),
      clock: FixedClock(_now),
    ),
  );
  final transport = FakeReleaseTransport();
  final downloader = FakeFileDownloader(const <int>[]);
  final kit = fakeIntentKit(
    host: host,
    transport: transport,
    downloader: downloader,
    root: root,
  );
  addTearDown(kit.dispose);
  return _Rig(kit, host, transport, downloader, root);
}

Future<void> _pumpSection(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.light(),
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => Scaffold(
          body: SingleChildScrollView(
            child: IntentSettingsSection(
              settings: rig.settings,
              intent: rig.kit,
              onChanged: (AppSettings next) {
                rig.changes.add(next);
                setState(() => rig.settings = next);
                unawaited(rig.kit.apply(next));
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Установить уровень до показа. Ожидание — кадрами: цепочки будущих
/// созданы в поддельной зоне теста.
Future<void> _install(WidgetTester tester, _Rig rig, IntentTier tier) async {
  rig.settings = rig.settings.copyWith(intentTier: tier);
  unawaited(
    rig.kit.apply(rig.settings).then((_) => rig.kit.install(tier)),
  );
  await _until(
    tester,
    () => rig.kit.installed?.tier == tier && rig.kit.running,
  );
}

/// Ждать [done]: каждый шаг установки — настоящий ввод-вывод, его
/// продолжение — в кадре поддельной зоны.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 4000 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: 'состояние модели понимания не наступило');
}

String _subtitle(WidgetTester tester, IntentTier tier) {
  final texts = tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(Key('intent-tier-${tier.id}')),
      matching: find.byType(Text),
    ),
  );
  return texts.map((Text t) => t.data ?? t.textSpan?.toPlainText()).join('|');
}

void main() {
  testWidgets('не скачана: уровни, объяснение, удаления нет', (tester) async {
    final rig = await _rig(tester);
    await _pumpSection(tester, rig);
    expect(find.text('Понимание фраз'), findsOneWidget);
    expect(find.text('Выключено'), findsOneWidget);
    expect(_subtitle(tester, IntentTier.light), contains('~32 МБ, быстрее'));
    expect(
      _subtitle(tester, IntentTier.accurate),
      contains('~131 МБ, понимает больше'),
    );
    expect(find.textContaining('Ничего не отправляется'), findsOneWidget);
    expect(find.byKey(const Key('intent-delete')), findsNothing);
    expect(find.byKey(const Key('intent-check')), findsNothing);
    expect(rig.transport.requests, isEmpty, reason: 'без нажатия — без сети');
  });

  testWidgets('«Лёгкая»: подтверждение, загрузка с ходом, затем работает',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0');
    final gate = Completer<void>();
    rig.downloader
      ..gate = gate
      ..gateFrom = 1;
    await _pumpSection(tester, rig);

    await tester.tap(find.byKey(const Key('intent-tier-light')));
    await tester.pumpAndSettle();
    expect(find.text('Скачать модель «Лёгкая»?'), findsOneWidget);
    expect(find.textContaining('Wi‑Fi'), findsNothing);
    await tester.tap(find.byKey(const Key('intent-download-confirm')));
    await tester.pump();
    expect(rig.settings.intentTier, IntentTier.light);

    await _until(
      tester,
      () => rig.kit.phase == IntentKitPhase.downloading && rig.kit.received > 0,
    );
    await tester.pump();
    expect(find.byKey(const Key('intent-progress-bar')), findsOneWidget);
    expect(find.textContaining('«Лёгкая» скачивается'), findsOneWidget);
    expect(find.byKey(const Key('intent-cancel')), findsOneWidget);
    expect(_subtitle(tester, IntentTier.light), contains('скачивается'));

    gate.complete();
    await _until(tester, () => rig.kit.running);
    await tester.pump();
    expect(find.byKey(const Key('intent-progress-bar')), findsNothing);
    expect(_subtitle(tester, IntentTier.light), contains('работает'));
    expect(find.byKey(const Key('intent-delete')), findsOneWidget);
    expect(find.byKey(const Key('intent-check')), findsOneWidget);
  });

  testWidgets('«Точная» — совет про Wi‑Fi; «Отмена» возвращает прежний уровень',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0', serve: 'accurate');
    final gate = Completer<void>();
    rig.downloader
      ..gate = gate
      ..gateFrom = 1;
    await _pumpSection(tester, rig);
    await tester.tap(find.byKey(const Key('intent-tier-accurate')));
    await tester.pumpAndSettle();
    expect(find.textContaining('лучше скачивать по Wi‑Fi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('intent-download-confirm')));
    await tester.pump();
    await _until(tester, () => rig.kit.received > 0);
    await tester.pump();
    await tester.tap(find.byKey(const Key('intent-cancel')));
    await _until(tester, () => !rig.kit.isBusy);
    await tester.pump();
    expect(rig.settings.intentTier, IntentTier.off);
    expect(
      find.byKey(const Key('intent-delete')),
      findsOneWidget,
      reason: 'недокачанное можно удалить',
    );
  });

  testWidgets('ошибка суммы — текст ошибки и «Повторить»', (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0', sha: 'a' * 64);
    await _pumpSection(tester, rig);
    await tester.tap(find.byKey(const Key('intent-tier-light')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('intent-download-confirm')));
    await tester.pump();
    await _until(tester, () => rig.kit.phase == IntentKitPhase.error);
    await tester.pump();
    expect(
      find.text('Файл повреждён: контрольная сумма не совпала'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('intent-retry')), findsOneWidget);
    expect(rig.host.loads, isEmpty);

    rig.publish('1.0.0');
    await tester.tap(find.byKey(const Key('intent-retry')));
    await _until(tester, () => rig.kit.running);
    await tester.pump();
    expect(find.byKey(const Key('intent-error')), findsNothing);
  });

  testWidgets('установлена: смена уровня перезагружает модель', (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0');
    await _install(tester, rig, IntentTier.light);
    await _pumpSection(tester, rig);
    expect(_subtitle(tester, IntentTier.light), contains('работает'));

    await tester.tap(find.byKey(const Key('intent-tier-off')));
    await _until(tester, () => !rig.kit.running);
    await tester.pump();
    expect(rig.host.unloads, 1);
    expect(_subtitle(tester, IntentTier.light), contains('скачана'));

    await tester.tap(find.byKey(const Key('intent-tier-light')));
    await _until(tester, () => rig.kit.running);
    await tester.pump();
    expect(
      find.text('Скачать модель «Лёгкая»?'),
      findsNothing,
      reason: 'скачанную не скачиваем',
    );
    expect(rig.host.loads, hasLength(2));

    rig.publish('1.0.0', serve: 'accurate');
    await tester.tap(find.byKey(const Key('intent-tier-accurate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('intent-download-confirm')));
    await tester.pump();
    await _until(
      tester,
      () => rig.kit.installed?.tier == IntentTier.accurate && !rig.kit.isBusy,
    );
    await tester.pump();
    expect(rig.host.loads.last, endsWith('accurate-1.0.0'));
    expect(_subtitle(tester, IntentTier.accurate), contains('работает'));
    expect(_subtitle(tester, IntentTier.light), isNot(contains('скачана')));
  });

  testWidgets('обновление: «Проверить» → «Доступна новая версия — N МБ»',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0');
    await _install(tester, rig, IntentTier.light);
    await _pumpSection(tester, rig);
    final next = rig.publish('1.1.0');
    await tester.tap(find.byKey(const Key('intent-check')));
    await _until(tester, () => rig.kit.updateAvailable);
    await tester.pump();
    final mb = (next.length / 1e6).round();
    expect(
      find.text('Доступна новая версия модели понимания — $mb МБ'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('intent-update')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('intent-download-confirm')));
    await tester.pump();
    await _until(
      tester,
      () => rig.kit.installed?.version == '1.1.0' && !rig.kit.isBusy,
    );
    await tester.pump();
    expect(find.byKey(const Key('intent-update')), findsNothing);
    expect(rig.host.loads.last, endsWith('light-1.1.0'));
  });

  testWidgets('удалить модель: подтверждение, уровень выключен',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish('1.0.0');
    await _install(tester, rig, IntentTier.light);
    await _pumpSection(tester, rig);
    await tester.tap(find.byKey(const Key('intent-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('intent-delete-confirm')));
    await _until(tester, () => rig.kit.installed == null);
    await tester.pump();
    expect(rig.settings.intentTier, IntentTier.off);
    expect(find.byKey(const Key('intent-delete')), findsNothing);
  });

  testWidgets('переключатели учёбы и журнала меняют настройки и память',
      (tester) async {
    final rig = await _rig(tester);
    await _pumpSection(tester, rig);
    await tester.tap(find.byKey(const Key('setting-intent-learning')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('setting-intent-logging')));
    await tester.tap(find.byKey(const Key('setting-intent-logging')));
    await _until(tester, () => !rig.kit.memory.logging);
    expect(rig.settings.intentLearning, isFalse);
    expect(rig.settings.intentLogging, isFalse);
    expect(rig.kit.memory.learning, isFalse);
  });

  testWidgets('«Забыть выученное»: число в подтверждении, затем пусто',
      (tester) async {
    final rig = await _rig(tester);
    unawaited(() async {
      await rig.kit.memory.remember('синтетика один', 'tasks:task.create');
      await rig.kit.memory.remember('синтетика два', 'tasks:task.list');
      await rig.kit.memory
          .reject('синтетика три', <String>['calc:calc.evaluate']);
    }());
    await _until(tester, () => rig.kit.memory.learnedCount == 3);
    await _pumpSection(tester, rig);
    await tester.ensureVisible(find.byKey(const Key('intent-forget')));
    await tester.tap(find.byKey(const Key('intent-forget')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Связной забудет 3 ответа «Да» и «Нет» на догадки. Модель и '
        'непонятые фразы останутся.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('intent-forget-confirm')));
    await _until(tester, () => rig.kit.memory.learnedCount == 0);
    await tester.pumpAndSettle();
    expect(find.text('Пока ничего не выучено'), findsOneWidget);
  });

  group('непонятые фразы', () {
    Future<_Rig> withPhrases(WidgetTester tester) async {
      final rig = await _rig(tester);
      final memory = rig.kit.memory;
      unawaited(() async {
        await memory.note('первая синтетическая', UnclearKind.unknown);
        await memory.note(
          'вторая синтетическая',
          UnclearKind.accepted,
          label: 'tasks:task.create',
        );
        await memory.note(
          'третья синтетическая',
          UnclearKind.rejected,
          label: 'calc:calc.evaluate',
        );
      }());
      await _until(tester, () => memory.unclear.length == 3);
      return rig;
    }

    Future<void> open(WidgetTester tester, _Rig rig, _FakeSharer sharer) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.light(),
          home: UnclearPhrasesScreen(
            intent: rig.kit,
            sharer: sharer,
            now: () => _now,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('список: новые первыми, статус и день; удалить одну',
        (tester) async {
      final rig = await withPhrases(tester);
      await open(tester, rig, _FakeSharer());
      expect(find.text('третья синтетическая'), findsOneWidget);
      final third = tester.getTopLeft(find.text('третья синтетическая'));
      final first = tester.getTopLeft(find.text('первая синтетическая'));
      expect(third.dy, lessThan(first.dy));
      expect(find.text('Не понял · 20 нояб.'), findsOneWidget);
      expect(find.text('Догадка отвергнута · 20 нояб.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('unclear-remove-0')));
      await _until(tester, () => rig.kit.memory.unclear.length == 2);
      await tester.pump();
      expect(find.text('третья синтетическая'), findsNothing);
    });

    testWidgets('«Очистить всё» — после подтверждения', (tester) async {
      final rig = await withPhrases(tester);
      await open(tester, rig, _FakeSharer());
      await tester.tap(find.byKey(const Key('unclear-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unclear-clear-confirm')));
      await _until(tester, () => rig.kit.memory.unclear.isEmpty);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unclear-empty')), findsOneWidget);
    });

    testWidgets('просмотр выгрузки: убранная строка не уходит в файл',
        (tester) async {
      final rig = await withPhrases(tester);
      final sharer = _FakeSharer();
      await open(tester, rig, sharer);
      await tester.tap(find.byKey(const Key('unclear-share')));
      await tester.pumpAndSettle();
      expect(find.byType(UnclearExportScreen), findsOneWidget);
      expect(find.text('Файл: 3 строки'), findsOneWidget);
      expect(
        find.textContaining('"text":"вторая синтетическая"'),
        findsOneWidget,
      );
      expect(sharer.shared, isEmpty, reason: 'само ничего не отправляется');

      await tester.tap(find.byKey(const Key('export-remove-1')));
      await tester.pump();
      expect(find.text('Файл: 2 строки'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-share')));
      await tester.pump();
      expect(sharer.names.single, 'tridot-unclear-2026-11-20.jsonl');
      final text = sharer.shared.single;
      expect(text, contains('третья синтетическая'));
      expect(text, contains('первая синтетическая'));
      expect(text, isNot(contains('вторая синтетическая')));
      expect(text.trim().split('\n'), hasLength(2));
      // Журнал на устройстве не меняется.
      expect(rig.kit.memory.unclear, hasLength(3));
    });
  });

  testWidgets('предложение «Лёгкой» — один раз, после первого «не понял»',
      (tester) async {
    final rig = await _rig(tester);
    final store = InMemorySettingsStore();
    final clock = FixedClock(_now);
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
      ],
      clock: clock,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.light(),
        home: HomePage(
          assistant: assistant,
          tasks: tasks,
          clock: clock,
          settingsStore: store,
          intent: rig.kit,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> say(String text) async {
      await tester.enterText(find.byKey(const Key('assistant-input')), text);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    await say('фывапролджэ');
    expect(find.text('Понимать больше фраз?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('intent-offer-later')));
    await tester.pumpAndSettle();
    expect((await store.load()).intentOffered, isTrue);
    expect((await store.load()).intentTier, IntentTier.off);

    await say('ячсмитьбю');
    expect(find.text('Понимать больше фраз?'), findsNothing);
    expect(rig.transport.requests, isEmpty);
  });
}

final class _FakeSharer implements UnclearSharer {
  final List<String> shared = <String>[];
  final List<String> names = <String>[];

  @override
  String get actionTitle => 'Поделиться';

  @override
  Future<UnclearShareOutcome> share({
    required String fileName,
    required String text,
  }) async {
    names.add(fileName);
    shared.add(text);
    return UnclearShareOutcome.done;
  }
}
