// Канарейка — главный тест хранилища паролей (ADR-014, раздел 11,
// группа 13; каркас этапа 1). Хранилище во временной папке с паролем,
// заметкой, логином и подсказкой-канарейками; сообщения идут через
// настоящие SecretGuard → AssistantController → ChatBook → JsonChatStore.
// Пароля, заметки и мастер-пароля нет (UTF-8, UTF-16LE/BE, другая
// раскладка, base64, hex) ни в одном файле папки, ни в истории, ни в
// ответах, ни в выводе print/debugPrint/FlutterError, ни в запросах сети,
// ни в toString моделей и ошибок. Этап 3: импорт CSV и резервная копия
// `.relaybak` (выгрузка, «новое устройство», слияние, «Заменить всё»).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/passwords_files.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/login_link.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/passwords/csv_import.dart';
import 'package:local_assistant/core/passwords/import_rules.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/passwords/vault_backup.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';
import 'package:path/path.dart' as p;

import '../connectors/example_warehouse_connector.dart';
import '../connectors/fakes.dart';
import 'vault_test_support.dart';

/// Навык с секретами, у которого `run` падает с канарейкой в тексте.
final class _LeakyConnector implements Connector {
  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'leaky',
        title: 'Протекающий',
        description: 'Падает с паролем в исключении.',
        kind: ExtensionKind.skill,
        sensitive: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) =>
      utterance.original.contains('сломайся')
          ? const ConnectorMatch(
              connectorId: 'leaky',
              commandId: 'leaky.break',
              confidence: 0.95,
            )
          : null;

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      throw FormatException('сбой', Canary.password);
}

void main() {
  late SodiumVaultCrypto crypto;
  late Directory root;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('no_leak_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Все канарейки, которых не должно быть нигде в открытом виде.
  const forbidden = <String>[
    Canary.master,
    Canary.password,
    Canary.note,
    'CANARY-pw2-Lm5',
    'CANARY-master2-Pz8',
    'CANARY-Vq8#mT2!zK9pL-wR4',
  ];

  /// Логин и подсказка тоже не лежат открыто в файлах (они в индексе).
  const indexOnly = <String>[Canary.login, Canary.hint];

  void expectClean(String where, String text, {bool withIndex = false}) {
    for (final canary in <String>[...forbidden, if (withIndex) ...indexOnly]) {
      for (final form in Canary.textForms(canary)) {
        expect(text, isNot(contains(form)), reason: '$where: $canary');
      }
    }
  }

  Future<void> expectFilesClean() async {
    var files = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      files++;
      final bytes = await entity.readAsBytes();
      for (final canary in <String>[...forbidden, ...indexOnly]) {
        for (final form in Canary.encodings(canary)) {
          expect(
            containsBytes(bytes, form),
            isFalse,
            reason: '${p.relative(entity.path, from: root.path)}: $canary',
          );
        }
      }
    }
    expect(files, greaterThan(3));
  }

  test('сценарии этапа 1: ни одной канарейки нигде', () async {
    final logs = <String>[];
    final errors = <String>[];
    final previousDebugPrint = debugPrint;
    final previousOnError = FlutterError.onError;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
    FlutterError.onError =
        (FlutterErrorDetails details) => errors.add(details.toString());
    addTearDown(() {
      debugPrint = previousDebugPrint;
      FlutterError.onError = previousOnError;
    });

    await runZoned(
      () async {
        final documents = p.join(root.path, 'documents', 'assistant');
        final support = p.join(root.path, 'support', 'assistant');
        final clock = TestClock(DateTime(2026, 11, 10, 12));
        final vault = testVault(
          FileVaultStore(p.join(support, 'vault')),
          crypto,
          clock: clock,
        );
        final facade = VaultFacade(vault);
        await vault.load();
        await vault.create(secret(Canary.master), params: fastKdf);
        final id = await vault.addEntry(
          service: 'Почта',
          login: Canary.login,
          hint: Canary.hint,
          password: secret(Canary.password),
          note: secret(Canary.note),
          important: true,
        );
        final second = await vault.addEntry(
          service: 'Форум',
          password: secret('CANARY-pw2-Lm5'),
        );
        // Показ (как VaultRevealService): прочитать и сразу затереть.
        final shown = await vault.readSecret(id);
        expectClean('VaultSecret.toString', '$shown');
        expectClean('SecretBytes.toString', '${shown.password}');
        shown.wipe();
        await vault.updatePassword(second, secret('CANARY-pw2-Lm5'));
        expect(await vault.verifyMaster(secret('CANARY-wrong')), isFalse);
        expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
        vault.lock();
        await vault.unlock(secret(Canary.master));
        await vault.changeMaster(
          current: secret(Canary.master),
          next: secret('CANARY-master2-Pz8'),
          params: fastKdf,
        );
        await vault.reencryptAll(secret('CANARY-master2-Pz8'));

        // Чат: настоящие маршрутизатор, история и файлы.
        final transport = FakeHttpTransport(
          (HttpRequestData request) =>
              const HttpResponseData(statusCode: 200, body: '{}'),
        );
        final tasks = TaskService(
          repository: JsonTaskRepository(p.join(documents, 'tasks.json')),
          clock: clock,
        );
        final assistant = AssistantController(
          connectors: <Connector>[
            TasksConnector(
              taskService: tasks,
              parser: ScenarioParser(clock: clock),
            ),
            ExampleWarehouseConnector(
              transport: transport,
              secrets: InMemorySecretStore(<String, String>{
                ExampleWarehouseConnector.tokenKey: 'токен',
              }),
              baseUri: Uri.parse('https://warehouse.example/api/'),
            ),
            _LeakyConnector(),
          ],
          clock: clock,
          knownSecret: facade.knownSecret,
        );
        final store = JsonChatStore(p.join(documents, 'chats'));
        final book = ChatBook(store: store, clock: clock);
        await book.load();
        final commands = <String>[];
        final responses = <AssistantResponse>[];

        // Как HomePage._send: SecretGuard до истории, команд и маршрутизатора.
        Future<void> send(String text) async {
          final guard = SecretGuard.redact(
            LoginLinks.redact(text),
            known: assistant.knownSecret,
          );
          final shownText = guard.text;
          final working = assistant.working(
            guard.guarded ? shownText : text,
            secretRedacted: guard.guarded,
          );
          responses.add(working);
          book.append(
            ChatThread.mainId,
            ChatMessage(
              id: book.newMessageId(),
              author: ChatAuthor.user,
              text: shownText,
              timestamp: clock.now(),
            ),
          );
          commands.add(shownText);
          final response = await assistant.handle(
            guard.guarded ? shownText : text,
            secretRedacted: guard.guarded,
          );
          responses.add(response);
          book.append(
            ChatThread.mainId,
            ChatMessage(
              id: book.newMessageId(),
              author: ChatAuthor.persona,
              text: response.message,
              timestamp: clock.now(),
              status: response.status,
              secureCard: const SecureCardRequest(kind: SecureCardKind.hint),
            ),
          );
        }

        await send('пароль от почты: ${Canary.password}');
        await send('логин ivan пароль ${Canary.password}');
        await send('мой пароль "${Canary.note}"');
        // Без слова «пароль»: узнан по отпечатку открытого хранилища.
        await send('добавь задачу ${Canary.password}');
        await send('${Canary.password} где лежит 64115');
        // Исключение внутри навыка с канарейкой в тексте.
        await send('сломайся');
        await send('добавь задачу купить хлеб');
        // Выключенный навык: хранилище заперто, отпечатков нет, но
        // правило с разделителем работает.
        vault.setEnabled(false);
        expect(facade.knownSecret(Canary.password), isFalse);
        await send('пароль от почты: ${Canary.password}');
        await send('пин-код: ${Canary.password}');

        await book.flush();
        await JsonSettingsStore(p.join(documents, 'settings.json'))
            .save(const AppSettings());
        await File(p.join(support, 'secrets.json')).writeAsString('{}');

        expect(assistant.outboundLeaks, 0);
        expect((await tasks.listAll()).map((Task t) => t.title), <String>[
          'Купить хлеб',
        ]);
        expect(
          responses.map((AssistantResponse r) => r.replyId),
          containsAll(<String>['secret.redacted', 'router.failed.quiet']),
        );
        for (final response in responses) {
          expectClean('ответ', response.message);
          expectClean('факты', response.values.values.join('|'));
        }
        for (final command in commands) {
          expectClean('команда', command);
        }
        final pending = assistant.session.pendingConfirmation;
        expectClean('ожидание', '${pending?.payload}');
        for (final message in book.thread(ChatThread.mainId)!.messages) {
          final json = message.toJson();
          expect(json.containsKey('secure_card'), isFalse);
          expect(json.toString(), isNot(contains('secureCard')));
          expectClean('ChatMessage.toJson', '$json');
        }
        for (final request in transport.requests) {
          expectClean('запрос', '${request.uri} ${request.body}');
        }
        // toString моделей и ошибок — без данных.
        for (final value in <Object>[
          vault,
          facade,
          ...vault.entries,
          ...facade.find('Почта'),
          facade.summary(),
          VaultError.corrupt,
          VaultRateLimited(DateTime.utc(2026)),
          VaultAttempts.decode(null),
          SecretBytes.fromText(Canary.password),
          FileVaultStore('x'),
        ]) {
          expectClean('toString ${value.runtimeType}', '$value');
        }
        await expectFilesClean();
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
            logs.add(line),
      ),
    );
    for (final line in <String>[...logs, ...errors]) {
      expectClean('вывод', line, withIndex: true);
    }
  });

  test('импорт CSV и копия .relaybak: ни одной канарейки нигде', () async {
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
    addTearDown(() => debugPrint = previousDebugPrint);
    // CSV — файл человека открытым текстом; лежит вне папки приложения и
    // удаляется после импорта (как кнопка «Удалить CSV-файл»).
    final outside = await Directory.systemTemp.createTemp('no_leak_csv_');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });

    await runZoned(
      () async {
        final documents = p.join(root.path, 'documents', 'assistant');
        final support = p.join(root.path, 'support', 'assistant');
        final clock = TestClock(DateTime(2026, 11, 10, 12));
        final vault = testVault(
          FileVaultStore(p.join(support, 'vault')),
          crypto,
          clock: clock,
        );
        final kit = PasswordsKit(
          vault: vault,
          platform: PasswordsPlatform.linux,
          kdfForTesting: fastKdf,
          wordlists: testWordlists(),
          clipboard: ClipboardGuard(
            platform: PasswordsPlatform.linux,
            cipher: crypto,
            write: (String text) async {},
            read: () async => null,
          ),
        );
        addTearDown(kit.dispose);
        await vault.load();
        await kit.create(Canary.master);
        await vault.addEntry(
          service: 'Почта',
          login: Canary.login,
          hint: Canary.hint,
          password: secret('CANARY-pw2-Lm5'),
        );

        // CSV: пароль, заметка, логин — канарейки.
        final csv = File(p.join(outside.path, 'passwords.csv'));
        await csv.writeAsString(
          'name,url,username,password,note\n'
          'Почта,https://mail.example,${Canary.login},${Canary.password},'
          '${Canary.note}\n'
          'Битая,javascript:alert(1),x\u202E,${Canary.password}x,\n'
          'Без пароля,https://none.example,${Canary.login},,${Canary.note}\n',
        );
        final raw = await csv.readAsBytes();
        final plan = kit.analyzeCsv(raw) as CsvPlan;
        final items = <ImportItem>[for (final r in plan.records) r.item];
        final matches = kit.matchImport(items);
        final result = await kit.applyImport(
          <ImportDecision>[
            for (var i = 0; i < items.length; i++)
              ImportDecision(items[i], matches[i], matches[i].defaultChoice),
          ],
          fromBackup: false,
        );
        expect(result.added, 1);
        final models = <Object>[
          plan,
          ...plan.records,
          ...items,
          ...matches,
          result,
          CsvReader.parse(raw),
          const CsvException(CsvFailure.malformed),
          const CsvColumns(password: 3),
          PickedFile(path: csv.path, bytes: raw),
          const BackupProblem('x'),
          ImportDecision(items.first, matches.first, ImportChoice.keepBoth),
        ];
        for (final error in plan.errors) {
          expectClean('ошибка CSV', error, withIndex: true);
        }
        plan.wipe();
        raw.fillRange(0, raw.length, 0);
        await csv.delete();

        // Копия: мастер-паролем и отдельным паролем; в папке приложения.
        final backup = await kit.exportBackup(Canary.master);
        final separate = await kit.exportBackup(
          Canary.master,
          separate: 'CANARY-Vq8#mT2!zK9pL-wR4',
        );
        await kit.recordBackup(separate: false);
        await File(p.join(root.path, VaultBackup.fileName(clock.now())))
            .writeAsBytes(backup);
        await File(p.join(root.path, 'separate.relaybak'))
            .writeAsBytes(separate);

        // «Новое устройство»: создать из копии.
        final device = testVault(
          FileVaultStore(p.join(root.path, 'device', 'vault')),
          crypto,
          clock: clock,
        );
        await device.load();
        final opened = await device.readBackup(
          separate,
          secret('CANARY-Vq8#mT2!zK9pL-wR4'),
        );
        models.add(opened);
        await device.createFromBackup(
          opened,
          secret('CANARY-Vq8#mT2!zK9pL-wR4'),
          params: fastKdf,
        );
        opened.wipe();
        models.addAll(device.entries);

        // Слияние в исходное хранилище и «Заменить всё» (архив).
        final again = await kit.openBackup(backup, Canary.master);
        final merge = kit.matchImport(again.items, byId: true);
        await kit.applyImport(
          <ImportDecision>[
            for (var i = 0; i < again.items.length; i++)
              ImportDecision(again.items[i], merge[i], ImportChoice.replace),
          ],
          fromBackup: true,
        );
        expect(await kit.replaceAll(again, Canary.master), isTrue);
        again.wipe();
        expect(await vault.store.archived(), hasLength(1));

        // Чат: фразы импорта, копии и восстановления — через навык.
        final facade = VaultFacade(vault);
        final assistant = AssistantController(
          extensions: ExtensionRegistry(
            connectors: <Connector>[PasswordsConnector(vault: facade)],
            choice: const ExtensionChoice(
              enabled: <String>{PasswordsConnector.id},
            ),
          ),
          clock: clock,
          knownSecret: facade.knownSecret,
        );
        final store = JsonChatStore(p.join(documents, 'chats'));
        final book = ChatBook(store: store, clock: clock);
        await book.load();
        for (final text in <String>[
          'импорт паролей из браузера',
          'сделай резервную копию паролей',
          'восстанови пароли из копии',
          'потерял телефон',
        ]) {
          final response = await assistant.handle(text);
          expect(response.secureCard, isNotNull, reason: text);
          expectClean('ответ', response.message, withIndex: true);
          expectClean('факты', response.values.values.join('|'));
          book.append(
            ChatThread.mainId,
            ChatMessage(
              id: book.newMessageId(),
              author: ChatAuthor.persona,
              text: response.message,
              timestamp: clock.now(),
              secureCard: response.secureCard,
            ),
          );
        }
        await book.flush();
        await JsonSettingsStore(p.join(documents, 'settings.json')).save(
          AppSettings(
            passwordsSeenRev: kit.seenRev,
            passwordsVaultExisted: true,
          ),
        );
        for (final message in book.thread(ChatThread.mainId)!.messages) {
          expectClean(
            'ChatMessage.toJson',
            '${message.toJson()}',
            withIndex: true,
          );
        }
        for (final model in models) {
          expectClean(
            'toString ${model.runtimeType}',
            '$model',
            withIndex: true,
          );
        }
        vault.lock();
        device.lock();
        // Ни в хранилищах, ни в .prev, архиве, копиях, настройках и чатах.
        await expectFilesClean();
        final names = await root
            .list(recursive: true)
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList();
        expect(names, contains(VaultBackup.fileName(clock.now())));
        expect(
          names.where((String n) => n.startsWith('replaced-')),
          hasLength(1),
        );
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
            logs.add(line),
      ),
    );
    for (final line in logs) {
      expectClean('вывод', line, withIndex: true);
    }
  });

  test('после «перезапуска» карточки нет — только текст', () async {
    final store = JsonChatStore(p.join(root.path, 'chats'));
    final clock = TestClock(DateTime(2026, 11, 10, 12));
    final book = ChatBook(store: store, clock: clock);
    await book.load();
    final message = ChatMessage(
      id: book.newMessageId(),
      author: ChatAuthor.persona,
      text: 'Подсказка к «Почта» — в карточке ниже.',
      timestamp: clock.now(),
      secureCard: const SecureCardRequest(
        kind: SecureCardKind.hint,
        entryIds: <String>['00112233445566778899aabbccddeeff'],
      ),
    );
    book.append(ChatThread.mainId, message);
    await book.flush();
    expect(message.copyAs('m_copy').secureCard, isNull);
    expect(message.withLink(null).secureCard, isNotNull);
    expect(ChatMessage.fromJson(message.toJson())!.secureCard, isNull);
    final again = ChatBook(store: JsonChatStore(p.join(root.path, 'chats')));
    await again.load();
    final restored = again.thread(ChatThread.mainId)!.messages.single;
    expect(restored.text, message.text);
    expect(restored.secureCard, isNull);
    for (final file in Directory(p.join(root.path, 'chats')).listSync()) {
      final text = File(file.path).readAsStringSync();
      expect(text, isNot(contains('00112233445566778899aabbccddeeff')));
    }
  });

  testWidgets('поле ввода: пароль не попадает в ленту и в сохранённый чат',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 10, 12));
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
    final chats = InMemoryChatStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: assistant,
          tasks: tasks,
          clock: clock,
          settingsStore: InMemorySettingsStore(),
          chatStore: chats,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'добавь задачу пароль от почты: ${Canary.password}',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining(Canary.password), findsNothing);
    expect(find.textContaining(SecretGuard.mask), findsWidgets);
    expect(await tasks.listAll(), isEmpty);
    for (final thread in await chats.loadIndex()) {
      for (final message in await chats.loadMessages(thread.id)) {
        expect('${message.toJson()}', isNot(contains(Canary.password)));
      }
    }
    // «Предыдущая команда» в поле ввода — тоже без пароля.
    await tester.tap(find.byKey(const Key('assistant-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.textContaining(Canary.password), findsNothing);
  });
}
