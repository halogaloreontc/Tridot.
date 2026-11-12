import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

Widget host({
  AppSettings settings = const AppSettings(),
  ValueChanged<AppSettings>? onChanged,
  VoidCallback? onClearChat,
  int messageCount = 5,
  ExtensionRegistry? extensions,
}) {
  return MaterialApp(
    theme: AssistantTheme.dark(),
    home: Scaffold(
      body: SettingsScreen(
        settings: settings,
        onChanged: onChanged ?? (_) {},
        onClearChat: onClearChat ?? () {},
        messageCount: messageCount,
        extensions: extensions,
      ),
    ),
  );
}

String userPack(String id, {String title = 'Мои шутки'}) => '''
{"format":"assistant-pack/1","id":"$id","type":"jokes","title":"$title",
 "author":"Я","language":"ru","version":"1.2.0","description":"Свои шутки",
 "entries":[{"id":"j1","text":"Шутка","tags":["кофе"]}]}''';

Future<ExtensionRegistry> registry() async {
  final clock = FixedClock(DateTime(2026, 11, 5, 12));
  final packs = PackStore.memory(builtIn: <String>[userPack('jokes.basic')]);
  await packs.load();
  return ExtensionRegistry(
    connectors: <Connector>[
      TasksConnector(
        taskService: TaskService(
          repository: InMemoryTaskRepository(),
          clock: clock,
        ),
        parser: ScenarioParser(clock: clock),
      ),
      const CalculatorConnector(),
    ],
    packs: packs,
  );
}

/// Экран с реестром, который сам хранит изменённые настройки.
Widget stateful(ExtensionRegistry extensions, List<AppSettings> changes) {
  var settings = const AppSettings();
  return StatefulBuilder(
    builder: (context, setState) => host(
      settings: settings,
      extensions: extensions,
      onChanged: (value) {
        changes.add(value);
        extensions.apply(
          ExtensionChoice(
            disabled: value.disabledExtensions,
            enabled: value.enabledExtensions,
          ),
        );
        setState(() => settings = value);
      },
    ),
  );
}

Finder tile(String id) => find.byKey(ValueKey<String>('extension-$id'));

const clearKey = ValueKey<String>('clear-chat');

void main() {
  testWidgets('shows sections and switch values', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Уменьшить анимацию'), findsOneWidget);
    expect(find.text('Кубик и переходы без движения'), findsOneWidget);
    expect(find.text('Время под сообщениями'), findsOneWidget);
    expect(
      find.text(
        'Связной · приложение с помощниками, локально, без интернета и '
        'языковой модели',
      ),
      findsOneWidget,
    );
    final reduce = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('setting-reduce-motion')),
    );
    final stamps = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('setting-timestamps')),
    );
    expect(reduce.value, isFalse);
    expect(stamps.value, isTrue);
  });

  testWidgets('switches report updated settings', (tester) async {
    final changes = <AppSettings>[];
    await tester.pumpWidget(host(onChanged: changes.add));
    await tester.tap(find.text('Уменьшить анимацию'));
    await tester.tap(find.text('Время под сообщениями'));
    await tester.pump();
    expect(changes, hasLength(2));
    expect(changes[0].reduceMotion, isTrue);
    expect(changes[0].showTimestamps, isTrue);
    expect(changes[1].reduceMotion, isFalse);
    expect(changes[1].showTimestamps, isFalse);
  });

  testWidgets('clear chat is disabled without messages', (tester) async {
    await tester.pumpWidget(host(messageCount: 0));
    final button = tester.widget<ButtonStyleButton>(find.byKey(clearKey));
    expect(button.onPressed, isNull);
  });

  testWidgets('clear chat is enabled from the first message', (tester) async {
    // Приветствия-сообщения нет: одно сообщение — уже история.
    await tester.pumpWidget(host(messageCount: 1));
    final button = tester.widget<ButtonStyleButton>(find.byKey(clearKey));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('clear chat asks for confirmation; cancel keeps history',
      (tester) async {
    var cleared = 0;
    await tester.pumpWidget(host(onClearChat: () => cleared++));
    // Раздел «Помощники» выше: кнопка может оказаться ниже экрана.
    await tester.ensureVisible(find.byKey(clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cleared, 0);

    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cleared, 1);
  });

  testWidgets('licenses button opens the license page', (tester) async {
    await tester.pumpWidget(host());
    await tester.ensureVisible(find.byKey(const ValueKey<String>('licenses')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('no overflow at 320x640 with textScaler 2.0', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1600 wide', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(messageCount: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('Расширения', () {
    testWidgets('без реестра раздела нет', (tester) async {
      await tester.pumpWidget(host());
      expect(find.text('Расширения'), findsNothing);
    });

    testWidgets('группы, строки, бейджи, обязательные задачи', (tester) async {
      final extensions = await tester.runAsync(registry);
      await tester.pumpWidget(host(extensions: extensions));
      for (final title in <String>['Расширения', 'Навыки', 'Подключения']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Паки'), findsOneWidget);
      expect(find.text('Подключений пока нет'), findsOneWidget);
      // Расширения ставятся в приложение, а не в помощника (ADR-009).
      expect(
        find.textContaining('Настройте Связной под себя'),
        findsOneWidget,
      );
      expect(find.textContaining('Соберите помощника'), findsNothing);
      expect(find.text('Калькулятор'), findsOneWidget);
      expect(find.text('Задачи'), findsOneWidget);
      expect(find.text('Мои шутки'), findsOneWidget);
      expect(find.text('v1.2.0 · Я'), findsOneWidget);
      expect(find.text('встроено'), findsNWidgets(3));
      expect(find.text('всегда включено'), findsOneWidget);
      final tasks = tester.widget<SwitchListTile>(tile('tasks'));
      expect(tasks.value, isTrue);
      expect(tasks.onChanged, isNull);
      final calc = tester.widget<SwitchListTile>(tile('calc'));
      expect(calc.value, isTrue);
      expect(calc.onChanged, isNotNull);
      expect(
        find.byKey(const ValueKey<String>('extension-remove-jokes.basic')),
        findsNothing,
        reason: 'встроенный пак не удаляется',
      );
    });

    testWidgets('переключатель сообщает выбор в настройках', (tester) async {
      final extensions = (await tester.runAsync(registry))!;
      final changes = <AppSettings>[];
      await tester.pumpWidget(stateful(extensions, changes));
      await tester.ensureVisible(tile('calc'));
      await tester.tap(tile('calc'));
      await tester.pumpAndSettle();
      expect(changes.last.disabledExtensions, <String>{'calc'});
      expect(extensions.isEnabled('calc'), isFalse);
      expect(tester.widget<SwitchListTile>(tile('calc')).value, isFalse);
      await tester.ensureVisible(tile('jokes.basic'));
      await tester.tap(tile('jokes.basic'));
      await tester.pumpAndSettle();
      expect(changes.last.disabledExtensions, <String>{'calc', 'jokes.basic'});
      await tester.tap(tile('calc'));
      await tester.pumpAndSettle();
      expect(changes.last.disabledExtensions, <String>{'jokes.basic'});
    });

    testWidgets('добавить пак: ошибки, успех, замена, удаление',
        (tester) async {
      final extensions = (await tester.runAsync(registry))!;
      await tester.pumpWidget(stateful(extensions, <AppSettings>[]));
      Future<void> openDialog() async {
        await tester.ensureVisible(find.byKey(const ValueKey('pack-add')));
        await tester.tap(find.byKey(const ValueKey('pack-add')));
        await tester.pumpAndSettle();
      }

      Future<void> submit(String json) async {
        await tester.enterText(find.byKey(const ValueKey('pack-json')), json);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('pack-import')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
      }

      await openDialog();
      await submit('{"format":"assistant-pack/2"}');
      expect(find.byKey(const ValueKey('pack-errors')), findsOneWidget);
      expect(
        find.textContaining('Версия формата «assistant-pack/2»'),
        findsOneWidget,
      );
      await submit(userPack('jokes.basic'));
      expect(find.textContaining('встроен в приложение'), findsOneWidget);

      await submit(userPack('my.jokes', title: 'Свои'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Пак «Свои» добавлен.'), findsOneWidget);
      expect(tile('my.jokes'), findsOneWidget);

      // Повторный импорт того же id — с подтверждением замены.
      await openDialog();
      await submit(userPack('my.jokes', title: 'Свои 2'));
      expect(find.text('Заменить пак?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pack-replace-confirm')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Свои 2'), findsOneWidget);

      final remove = find.byKey(
        const ValueKey<String>('extension-remove-my.jokes'),
      );
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-remove-cancel')));
      await tester.pumpAndSettle();
      expect(tile('my.jokes'), findsOneWidget);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-remove-confirm')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(extensions.info('my.jokes'), isNull);
      expect(tile('my.jokes'), findsNothing);
    });

    testWidgets('без переполнения на 320x640 при масштабе 2', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final extensions = (await tester.runAsync(registry))!;
      await tester.pumpWidget(stateful(extensions, <AppSettings>[]));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('pack-add')));
      await tester.tap(find.byKey(const ValueKey('pack-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pack-json')), '{');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pack-import')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pack-errors')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('удаление пака с длинным названием на 320x640 при масштабе 2',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final extensions = (await tester.runAsync(registry))!;
      final title = 'Очень длинное название пакета шуток для проверки '
          'экрана настроек на узком телефоне с крупным шрифтом';
      expect(title.length, lessThanOrEqualTo(100));
      await tester.runAsync(
        () => extensions.importPack(userPack('my.pack', title: title)),
      );
      await tester.pumpWidget(stateful(extensions, <AppSettings>[]));
      await tester.pumpAndSettle();
      final remove =
          find.byKey(const ValueKey<String>('extension-remove-my.pack'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final key in <String>['pack-remove-cancel', 'pack-remove-confirm']) {
        final button = find.byKey(ValueKey<String>(key));
        final rect = tester.getRect(button);
        expect(
          const Rect.fromLTWH(0, 0, 320, 640).contains(rect.center),
          isTrue,
          reason: '$key: $rect',
        );
      }
      await tester.tap(find.byKey(const ValueKey('pack-remove-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tile('my.pack'), findsOneWidget);
    });

    testWidgets('сбой записи пака — ошибка в диалоге, кнопка снова доступна',
        (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pack_ui'),
      ))!;
      addTearDown(() => temp.deleteSync(recursive: true));
      final blocker = File('${temp.path}/file')..writeAsStringSync('');
      final extensions = ExtensionRegistry(
        connectors: const <Connector>[CalculatorConnector()],
        packs: PackStore(userDirectory: '${blocker.path}/packs'),
      );
      await tester.pumpWidget(stateful(extensions, <AppSettings>[]));
      await tester.ensureVisible(find.byKey(const ValueKey('pack-add')));
      await tester.tap(find.byKey(const ValueKey('pack-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pack-json')),
        userPack('my.pack'),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pack-import')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      for (var i = 0; i < 5; i++) {
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pack-errors')), findsOneWidget);
      expect(find.textContaining('Не удалось сохранить пак'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('pack-import')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('удалённый выключенный пак добавляется снова включённым',
        (tester) async {
      final extensions = (await tester.runAsync(registry))!;
      final changes = <AppSettings>[];
      await tester.runAsync(() => extensions.importPack(userPack('my.pack')));
      await tester.pumpWidget(stateful(extensions, changes));
      await tester.ensureVisible(tile('my.pack'));
      await tester.tap(tile('my.pack'));
      await tester.pumpAndSettle();
      expect(changes.last.disabledExtensions, contains('my.pack'));

      final remove =
          find.byKey(const ValueKey<String>('extension-remove-my.pack'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pack-remove-confirm')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(tile('my.pack'), findsNothing);
      expect(changes.last.disabledExtensions, isNot(contains('my.pack')));

      await tester.runAsync(() => extensions.importPack(userPack('my.pack')));
      await tester.pumpAndSettle();
      expect(extensions.isEnabled('my.pack'), isTrue);
      expect(tester.widget<SwitchListTile>(tile('my.pack')).value, isTrue);
    });
  });

  group('Помощники', () {
    Widget personasHost(
      List<AppSettings> changes, {
      ExtensionRegistry? extensions,
    }) {
      var settings = const AppSettings();
      return StatefulBuilder(
        builder: (context, setState) => host(
          settings: settings,
          extensions: extensions,
          onChanged: (value) {
            changes.add(value);
            extensions?.apply(
              ExtensionChoice(
                disabled: value.disabledExtensions,
                enabled: value.enabledExtensions,
              ),
            );
            setState(() => settings = value);
          },
        ),
      );
    }

    Future<void> tap(WidgetTester tester, String key) async {
      final target = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    String preview(WidgetTester tester, String persona) => tester
        .widget<Text>(find.byKey(ValueKey<String>('style-preview-$persona')))
        .data!;

    testWidgets('по умолчанию: дуэт, основной Liorio, примеры стилей',
        (tester) async {
      await tester.pumpWidget(host());
      expect(find.text('Помощники'), findsOneWidget);
      ChoiceChip chip(String key) => tester.widget<ChoiceChip>(
            find.descendant(
              of: find.byKey(ValueKey<String>(key)),
              matching: find.byType(ChoiceChip),
            ),
          );
      expect(chip('assistant-mode-duo').selected, isTrue);
      expect(chip('main-persona-rio').selected, isTrue);
      expect(chip('style-rio-neutral').selected, isTrue);
      expect(chip('style-noda-friendly').selected, isTrue);
      expect(chip('address-vy').selected, isTrue);
      expect(
        preview(tester, 'rio'),
        'Создал задачу «Купить хлеб» на завтра в 10:00.',
      );
      expect(preview(tester, 'noda'), contains('«Купить хлеб»'));
      expect(preview(tester, 'noda'), contains('завтра в 10:00'));
    });

    testWidgets('переключатели сообщают настройки, пример меняется сразу',
        (tester) async {
      final changes = <AppSettings>[];
      await tester.pumpWidget(personasHost(changes));
      await tap(tester, 'style-rio-business');
      expect(changes.last.personas.styleOf(Personas.liorio), 'business');
      expect(
        preview(tester, 'rio'),
        'Задача «Купить хлеб» создана, срок — завтра в 10:00.',
      );
      await tap(tester, 'style-noda-neutral');
      await tap(tester, 'address-ty');
      expect(changes.last.personas.address, ReplyAddress.informal);
      expect(
        preview(tester, 'noda'),
        'Создала задачу «Купить хлеб» на завтра в 10:00.',
      );
      await tap(tester, 'style-noda-friendly');
      await tap(tester, 'setting-emoji');
      expect(changes.last.personas.emoji, isFalse);
      expect(
        ReplyTemplate.pictographs.hasMatch(preview(tester, 'noda')),
        isFalse,
      );
      await tap(tester, 'main-persona-noda');
      expect(changes.last.personas.mainPersona, 'noda');
      await tap(tester, 'assistant-mode-solo');
      expect(changes.last.personas.mode, AssistantMode.solo);
      expect(
        find.byKey(const ValueKey<String>('solo-persona-rio')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('main-persona-rio')),
        findsNothing,
      );
      await tap(tester, 'solo-persona-noda');
      expect(changes.last.personas.soloPersona, 'noda');
      await tap(tester, 'jokes-normal');
      expect(changes.last.personas.jokes, JokeFrequency.normal);
      await tap(tester, 'jokes-off');
      expect(changes.last.personas.jokes, JokeFrequency.off);
      // Остальное не тронуто.
      expect(changes.last.showTimestamps, isTrue);
      expect(changes.last.disabledExtensions, isEmpty);
    });

    testWidgets('стиль из пака ответов — ещё одна кнопка', (tester) async {
      final extensions = await tester.runAsync(() async {
        final packs = PackStore.memory(
          builtIn: <String>[
            '{"format":"assistant-pack/1","id":"replies.sea","type":"replies",'
                '"title":"Морской","author":"Я","language":"ru",'
                '"version":"1.0.0","entries":{"task.created.withDue":'
                '"Полный вперёд: «{title}», {due}!"}}',
          ],
        );
        await packs.load();
        return ExtensionRegistry(connectors: <Connector>[], packs: packs);
      });
      final changes = <AppSettings>[];
      await tester.pumpWidget(personasHost(changes, extensions: extensions));
      await tap(tester, 'style-rio-replies.sea');
      expect(
        preview(tester, 'rio'),
        'Полный вперёд: «Купить хлеб», завтра в 10:00!',
      );
      // Пак выключили — стиль сохранён, но говорит нейтрально.
      await tap(tester, 'extension-replies.sea');
      expect(changes.last.personas.styleOf(Personas.liorio), 'replies.sea');
      expect(
        find.byKey(const ValueKey<String>('style-missing-rio')),
        findsOneWidget,
      );
      expect(
        preview(tester, 'rio'),
        'Создал задачу «Купить хлеб» на завтра в 10:00.',
      );
    });
  });

  testWidgets(
      'вкладка «Мой Связной → Настройки»: без заголовка и помощников, '
      'с «Данными» и «Сессиями»', (tester) async {
    var storage = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) {},
            onClearChat: () {},
            messageCount: 5,
            showTitle: false,
            includePersonas: false,
            onOpenStorage: () => storage++,
          ),
        ),
      ),
    );
    expect(find.text('Настройки'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('main-persona-noda')),
      findsNothing,
    );
    expect(find.text('Сессии'), findsOneWidget);
    expect(find.text('Очистить историю сессий'), findsOneWidget);
    final row = find.byKey(const ValueKey<String>('settings-storage'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    expect(storage, 1);
  });
}
