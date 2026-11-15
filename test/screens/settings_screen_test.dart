import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/app/widgets/extensions_section.dart';
import 'package:local_assistant/app/widgets/grouped.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/app_info.dart';
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
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import '../support/fake_voice.dart';

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
    expect(find.text('Время у каждого сообщения'), findsOneWidget);
    expect(
      find.text(
        '${AppInfo.name} · приложение с помощниками, локально, без интернета и '
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
    // Время у каждого сообщения по умолчанию выключено (ADR-027).
    expect(stamps.value, isFalse);
  });

  testWidgets('switches report updated settings', (tester) async {
    final changes = <AppSettings>[];
    await tester.pumpWidget(host(onChanged: changes.add));
    await tester.tap(find.text('Уменьшить анимацию'));
    await tester.tap(find.text('Время у каждого сообщения'));
    await tester.pump();
    expect(changes, hasLength(2));
    expect(changes[0].reduceMotion, isTrue);
    expect(changes[0].showTimestamps, isFalse);
    expect(changes[1].reduceMotion, isFalse);
    expect(changes[1].showTimestamps, isTrue);
  });

  testWidgets('clear chat is disabled without messages', (tester) async {
    await tester.pumpWidget(host(messageCount: 0));
    // Строка-действие цветом ошибки в группе «Сессии» (ADR-027).
    final row = tester.widget<GroupedRow>(find.byKey(clearKey));
    expect(row.onTap, isNull);
    expect(row.destructive, isTrue);
  });

  testWidgets('clear chat is enabled from the first message', (tester) async {
    // Приветствия-сообщения нет: одно сообщение — уже история.
    await tester.pumpWidget(host(messageCount: 1));
    final row = tester.widget<GroupedRow>(find.byKey(clearKey));
    expect(row.onTap, isNotNull);
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
        find.textContaining('Настройте ${AppInfo.name} под себя'),
        findsOneWidget,
      );
      expect(find.textContaining('Соберите помощника'), findsNothing);
      expect(find.text('Калькулятор'), findsOneWidget);
      expect(find.text('Задачи'), findsOneWidget);
      expect(find.text('Мои шутки'), findsOneWidget);
      // Версия и автор — только у пака не из поставки; «встроено» не
      // пишется, обязательное — тихой подписью (ADR-027).
      expect(find.text('v1.2.0 · Я'), findsNothing);
      expect(find.textContaining('встроено'), findsNothing);
      expect(find.text('Всегда включено'), findsOneWidget);
      final tasks = tester.widget<SwitchListTile>(tile('tasks'));
      expect(tasks.value, isTrue);
      expect(tasks.onChanged, isNull);
      // Название обязательного — не «выключенным» серым.
      final title = tester.widget<Text>(
        find.descendant(of: tile('tasks'), matching: find.text('Задачи')),
      );
      expect(title.style?.color, AppPalette.dark.textStrong);
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
      await tester.ensureVisible(tile('calc'));
      await tester.pumpAndSettle();
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

  // Помощники — во вкладке «Мой Связной → Помощники» (ADR-027, поправка):
  // раздел проверяется сам по себе, а рядом — «Расширения», чтобы выключить
  // пак ответов.
  group('Помощники', () {
    Widget personasHost(
      List<AppSettings> changes, {
      ExtensionRegistry? extensions,
    }) {
      var settings = const AppSettings();
      return MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              void onChanged(AppSettings value) {
                changes.add(value);
                extensions?.apply(
                  ExtensionChoice(
                    disabled: value.disabledExtensions,
                    enabled: value.enabledExtensions,
                  ),
                );
                setState(() => settings = value);
              }

              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    PersonasSection(
                      settings: settings,
                      onChanged: onChanged,
                      registry: extensions,
                    ),
                    if (extensions != null)
                      ExtensionsSection(
                        registry: extensions,
                        settings: settings,
                        onChanged: onChanged,
                      ),
                  ],
                ),
              );
            },
          ),
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

    testWidgets('в «Настройках» помощников нет', (tester) async {
      await tester.pumpWidget(host());
      expect(
        find.byKey(const ValueKey<String>('personas-section')),
        findsNothing,
      );
      expect(find.text('Роли'), findsNothing);
      // Строки-перехода нет, пока экран не знает, куда вести.
      expect(
        find.byKey(const ValueKey<String>('settings-assistants')),
        findsNothing,
      );
    });

    testWidgets('по умолчанию: трио, примеры стилей', (tester) async {
      await tester.pumpWidget(personasHost(<AppSettings>[]));
      expect(find.text('Помощники'), findsOneWidget);
      ChoiceChip chip(String key) => tester.widget<ChoiceChip>(
            find.descendant(
              of: find.byKey(ValueKey<String>(key)),
              matching: find.byType(ChoiceChip),
            ),
          );
      expect(chip('assistant-mode-trio').selected, isTrue);
      expect(chip('assistant-mode-duo').selected, isFalse);
      expect(
        find.byKey(const ValueKey<String>('duo-helper-rio')),
        findsNothing,
      );
      expect(chip('style-sado-neutral').selected, isTrue);
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
      expect(
        find.byKey(const ValueKey<String>('duo-helper-rio')),
        findsNothing,
      );
      await tap(tester, 'assistant-mode-duo');
      expect(changes.last.personas.teamMode, TeamMode.duo);
      await tap(tester, 'duo-helper-noda');
      expect(changes.last.personas.duoHelper, 'noda');
      await tap(tester, 'assistant-mode-solo');
      expect(changes.last.personas.teamMode, TeamMode.solo);
      expect(
        find.byKey(const ValueKey<String>('duo-helper-rio')),
        findsNothing,
      );
      await tap(tester, 'assistant-mode-trio');
      expect(changes.last.personas.teamMode, TeamMode.trio);
      await tap(tester, 'jokes-normal');
      expect(changes.last.personas.jokes, JokeFrequency.normal);
      await tap(tester, 'jokes-off');
      expect(changes.last.personas.jokes, JokeFrequency.off);
      // Остальное не тронуто.
      expect(changes.last.showTimestamps, isFalse);
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
      'с переходом к «Помощникам», «Данными» и «Сессиями»', (tester) async {
    var storage = 0;
    var assistants = 0;
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
            onOpenAssistants: () => assistants++,
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
    final link = find.byKey(const ValueKey<String>('settings-assistants'));
    expect(find.text('Помощники и роли'), findsOneWidget);
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    expect(assistants, 1);
    final row = find.byKey(const ValueKey<String>('settings-storage'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    expect(storage, 1);
  });

  group('Голосовой ввод', () {
    late Directory temp;
    late String dir;
    late List<int> bytes;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('settings_voice_test');
      dir = p.join(temp.path, 'assistant', 'voice');
      bytes = List<int>.generate(3000, (int i) => i % 199);
    });

    tearDown(() => temp.deleteSync(recursive: true));

    /// Экран с голосовым вводом, который сам хранит изменённые настройки.
    Future<(VoiceKit, FakeFileDownloader, List<AppSettings>)> pumpVoice(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
      bool installed = false,
      String? sha,
      VoiceSupport support = VoiceSupport.supported,
    }) async {
      final spec = fakeVoiceSpec(bytes, sha: sha);
      if (installed) installFakeModelSync(dir, spec);
      final downloader = FakeFileDownloader(bytes);
      final voice = fakeVoiceKit(
        recognizer: FakeVoiceRecognizer(support: support),
        downloader: downloader,
        spec: spec,
        dir: dir,
      );
      addTearDown(voice.dispose);
      await tester.runAsync(voice.refresh);
      final changes = <AppSettings>[];
      var current = settings;
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsScreen(
                settings: current,
                onChanged: (value) {
                  changes.add(value);
                  setState(() => current = value);
                },
                onClearChat: () {},
                messageCount: 1,
                voice: voice,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return (voice, downloader, changes);
    }

    Future<void> tapVisible(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(key));
      await tester.pump();
    }

    /// Переключатель «Голосовой ввод» без модели: предложение с размером и
    /// источником, затем «Скачать».
    Future<void> enableVoice(WidgetTester tester) async {
      await tapVisible(tester, const Key('setting-voice'));
      await tester.pumpAndSettle();
      expect(find.text('Включить голосовой ввод?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('с сайта example.invalid'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pump();
    }

    SwitchListTile switchTile(WidgetTester tester, String key) =>
        tester.widget<SwitchListTile>(find.byKey(Key(key)));

    testWidgets('без движка — только пояснение', (tester) async {
      await tester.pumpWidget(host());
      expect(find.byKey(const Key('voice-unsupported')), findsOneWidget);
      expect(find.byKey(const Key('setting-voice')), findsNothing);

      await pumpVoice(tester, support: VoiceSupport.unsupported);
      expect(
        find.text(
          'На этой платформе пока недоступен\u00A0— сейчас только Android',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('setting-voice')), findsNothing);
    });

    testWidgets('выключен: «Отправлять сразу» недоступно, удалять нечего',
        (tester) async {
      await pumpVoice(tester);
      expect(switchTile(tester, 'setting-voice').value, isFalse);
      expect(switchTile(tester, 'setting-voice-send-now').onChanged, isNull);
      expect(find.byKey(const Key('voice-delete')), findsNothing);
    });

    testWidgets(
        'переключатель без модели сначала спрашивает: «Не сейчас» — '
        'ничего не скачивается', (tester) async {
      final (voice, downloader, changes) = await pumpVoice(tester);
      expect(find.textContaining('с сайта example.invalid'), findsOneWidget);
      await tapVisible(tester, const Key('setting-voice'));
      await tester.pumpAndSettle();
      expect(find.text('Включить голосовой ввод?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-offer-later')));
      await tester.pumpAndSettle();
      expect(downloader.calls, 0);
      expect(changes, isEmpty);
      expect(switchTile(tester, 'setting-voice').value, isFalse);
      expect(voice.phase, VoiceKitPhase.notInstalled);
    });

    testWidgets('полоса загрузки видна: заливка и дорожка разного цвета',
        (tester) async {
      final (voice, downloader, _) = await pumpVoice(tester);
      downloader
        ..gate = Completer<void>()
        ..gateFrom = 1;
      await enableVoice(tester);
      await pumpUntilVoice(tester, () => voice.received > 0);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('voice-progress-bar')),
      );
      expect(bar.color, isNotNull);
      expect(bar.backgroundColor, isNotNull);
      expect(bar.color, isNot(bar.backgroundColor));
      expect(bar.minHeight, greaterThanOrEqualTo(4));
      await tapVisible(tester, const Key('voice-cancel'));
      await pumpUntilVoice(
        tester,
        () => voice.phase == VoiceKitPhase.notInstalled,
      );
    });

    testWidgets('включение скачивает модель: ход, проверка, готово',
        (tester) async {
      final (voice, downloader, changes) = await pumpVoice(tester);
      final gate = Completer<void>();
      downloader
        ..gate = gate
        ..gateFrom = 1;
      await enableVoice(tester);
      expect(changes.last.voiceInput, isTrue);
      await pumpUntilVoice(tester, () => voice.received > 0);
      expect(find.byKey(const Key('voice-progress-bar')), findsOneWidget);
      expect(find.textContaining('из 0 МБ'), findsOneWidget);
      expect(find.byKey(const Key('voice-cancel')), findsOneWidget);
      // Пока модели нет, «Отправлять сразу» недоступно.
      expect(switchTile(tester, 'setting-voice-send-now').onChanged, isNull);

      gate.complete();
      await pumpUntilVoice(tester, () => voice.isInstalled);
      expect(find.byKey(const Key('voice-progress-bar')), findsNothing);
      expect(
        switchTile(tester, 'setting-voice-send-now').onChanged,
        isNotNull,
      );
      await tapVisible(tester, const Key('setting-voice-send-now'));
      expect(changes.last.voiceSendImmediately, isTrue);
      expect(find.byKey(const Key('voice-delete')), findsOneWidget);
    });

    testWidgets('«Отмена» в настройках: выключено, скачанное осталось',
        (tester) async {
      final (voice, downloader, changes) = await pumpVoice(tester);
      downloader
        ..gate = Completer<void>()
        ..gateFrom = 1;
      await enableVoice(tester);
      await pumpUntilVoice(tester, () => voice.received > 0);
      await tapVisible(tester, const Key('voice-cancel'));
      await pumpUntilVoice(
        tester,
        () => voice.phase == VoiceKitPhase.notInstalled,
      );
      expect(changes.last.voiceInput, isFalse);
      expect(voice.hasPartial, isTrue);
      expect(find.byKey(const Key('voice-delete')), findsOneWidget);
      expect(find.text('Удалить недокачанную модель'), findsOneWidget);
    });

    testWidgets('сумма не совпала — ошибка и «Повторить»', (tester) async {
      final (voice, downloader, _) = await pumpVoice(
        tester,
        settings: const AppSettings(voiceInput: true),
        sha: 'f' * 64,
      );
      expect(find.byKey(const Key('voice-download')), findsOneWidget);
      await tapVisible(tester, const Key('voice-download'));
      await pumpUntilVoice(tester, () => voice.phase == VoiceKitPhase.error);
      expect(
        find.text(
          'Файл повреждён: контрольная сумма не совпала',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, const Key('voice-retry'));
      await pumpUntilVoice(tester, () => downloader.calls == 2);
      await pumpUntilVoice(tester, () => voice.phase == VoiceKitPhase.error);
    });

    testWidgets('«Удалить модель» спрашивает и освобождает место',
        (tester) async {
      final (voice, _, changes) = await pumpVoice(
        tester,
        settings: const AppSettings(
          voiceInput: true,
          voiceSendImmediately: true,
        ),
        installed: true,
      );
      expect(voice.isInstalled, isTrue);
      expect(find.textContaining('Удалить модель ('), findsOneWidget);
      // Модель уже скачана: подпись не обещает скачать её снова.
      expect(find.textContaining('Модель скачана'), findsOneWidget);
      expect(find.textContaining('скачается один раз'), findsNothing);

      await tapVisible(tester, const Key('voice-delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-delete-cancel')));
      await tester.pumpAndSettle();
      expect(voice.isInstalled, isTrue);
      expect(changes, isEmpty);

      await tapVisible(tester, const Key('voice-delete'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить модель распознавания?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-delete-confirm')));
      await tester.pump();
      await pumpUntilVoice(
        tester,
        () => voice.phase == VoiceKitPhase.notInstalled,
      );
      expect(changes.last.voiceInput, isFalse);
      expect(changes.last.voiceSendImmediately, isFalse);
      expect(Directory(p.join(dir, 'test-model')).existsSync(), isFalse);
      expect(find.byKey(const Key('voice-delete')), findsNothing);
    });

    testWidgets('без переполнения на 320x640 при масштабе 2', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (voice, downloader, _) = await pumpVoice(tester);
      downloader
        ..gate = Completer<void>()
        ..gateFrom = 1;
      await enableVoice(tester);
      await pumpUntilVoice(tester, () => voice.received > 0);
      await tester.ensureVisible(find.byKey(const Key('voice-cancel')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tapVisible(tester, const Key('voice-cancel'));
      await pumpUntilVoice(
        tester,
        () => voice.phase == VoiceKitPhase.notInstalled,
      );
      await tester.ensureVisible(find.byKey(const Key('voice-delete')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });
}
