// Канарейка для навыка «Пароли» (ADR-014, этап 2, раздел 11 группа 13):
// все сценарии навыка через настоящие SecretGuard → AssistantController →
// ChatBook → JsonChatStore, хранилище на диске. Пароля, заметки и
// мастер-пароля нет ни в файлах, ни в истории, ни в ответах, ни в
// ожиданиях; подсказки нет в истории, пока выключен hints_in_history.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/login_link.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';
import 'package:path/path.dart' as p;

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;
  late Directory root;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('skill_no_leak_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  const forbidden = <String>[
    Canary.master,
    Canary.password,
    Canary.note,
    'CANARY-pw2-Lm5',
  ];

  void expectClean(String where, String text, {bool hint = true}) {
    for (final canary in <String>[...forbidden, if (hint) Canary.hint]) {
      for (final form in Canary.textForms(canary)) {
        expect(text, isNot(contains(form)), reason: '$where: $canary');
      }
    }
    // Логин в ответах — только в маске.
    expect(text, isNot(contains(Canary.login)), reason: '$where: логин');
  }

  test('сценарии навыка: ни одной канарейки нигде', () async {
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
    addTearDown(() => debugPrint = previousDebugPrint);

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
        );
        await vault.addEntry(
          service: 'Форум',
          password: secret('CANARY-pw2-Lm5'),
        );
        final tasks = TaskService(
          repository: JsonTaskRepository(p.join(documents, 'tasks.json')),
          clock: clock,
        );
        final registry = ExtensionRegistry(
          connectors: <Connector>[
            TasksConnector(
              taskService: tasks,
              parser: ScenarioParser(clock: clock),
            ),
            PasswordsConnector(vault: facade),
          ],
          choice: const ExtensionChoice(
            enabled: <String>{PasswordsConnector.id},
          ),
        );
        vault.followExtension(registry, PasswordsConnector.id);
        final assistant = AssistantController(
          extensions: registry,
          clock: clock,
          knownSecret: facade.knownSecret,
        );
        final book = ChatBook(
          store: JsonChatStore(p.join(documents, 'chats')),
          clock: clock,
        );
        await book.load();
        final responses = <AssistantResponse>[];
        final payloads = <String>[];

        void record(AssistantResponse response) {
          responses.add(response);
          payloads.add('${assistant.session.pendingConfirmation?.payload}');
          book.append(
            ChatThread.mainId,
            ChatMessage(
              id: book.newMessageId(),
              author: ChatAuthor.persona,
              text: response.message,
              timestamp: clock.now(),
              status: response.status,
              secureCard: response.secureCard,
            ),
          );
        }

        Future<void> send(String text) async {
          final guard = SecretGuard.redact(
            LoginLinks.redact(text),
            known: assistant.knownSecret,
          );
          book.append(
            ChatThread.mainId,
            ChatMessage(
              id: book.newMessageId(),
              author: ChatAuthor.user,
              text: guard.text,
              timestamp: clock.now(),
            ),
          );
          record(
            await assistant.handle(
              guard.guarded ? guard.text : text,
              secretRedacted: guard.guarded,
            ),
          );
        }

        Future<void> press(String action, {String? entryId}) async {
          final card = responses.last.secureCard!;
          record(
            (await assistant.secureCardAction(
              card,
              action,
              entryId: entryId,
            ))!,
          );
        }

        await send('забыл пароль от почты');
        await press(SecureCardCommand.revealed, entryId: id);
        await send('какой у меня логин от почты');
        await send('покажи пароль от почты');
        await send('да');
        await send('скопируй пароль от почты');
        await send('да');
        await press(SecureCardCommand.copied, entryId: id);
        await send('какие пароли сохранены');
        await send('запомни пароль от озона');
        await send('смени пароль от почты');
        await send('пароль от почты ${Canary.password}');
        await send('забыл пароль от форума');
        await send('удали пароль от форума');
        await send('да');
        await send('нет');
        await send('забыл мастер-пароль');
        await send('потерял телефон');
        await send('запри пароли');
        await send('забыл пароль от почты');
        await vault.unlock(secret(Canary.master));
        await press(SecureCardCommand.resume);
        registry.apply(registry.choiceWith(PasswordsConnector.id, false));
        await send('покажи пароль от почты');
        await send('пароль от почты: ${Canary.password}');
        await book.flush();
        await JsonSettingsStore(p.join(documents, 'settings.json')).save(
          AppSettings(
            enabledExtensions: const <String>{PasswordsConnector.id},
            passwordsSeenRev: vault.rev ?? 1,
            passwordsVaultExisted: true,
          ),
        );

        expect(assistant.outboundLeaks, 0);
        expect(await tasks.listAll(), isEmpty);
        expect(
          responses.map((AssistantResponse r) => r.replyId),
          containsAll(<String>[
            'passwords.hint.card',
            'passwords.revealed',
            'passwords.login.card',
            'passwords.reveal.card',
            'passwords.copy.done',
            'passwords.list.count',
            'passwords.add.editor',
            'passwords.change.editor',
            'secret.redacted',
            'passwords.delete.button',
            'passwords.noRecovery',
            'passwords.lostDevice',
            'passwords.lock.done',
            'passwords.locked',
            'passwords.off',
            'secret.redacted.off',
          ]),
        );
        for (final response in responses) {
          expectClean('ответ ${response.replyId}', response.message);
          expectClean('факты', response.values.values.join('|'));
          expectClean('карточка', '${response.secureCard?.options}');
        }
        for (final payload in payloads) {
          expectClean('ожидание', payload);
        }
        for (final message in book.thread(ChatThread.mainId)!.messages) {
          expectClean('ChatMessage.toJson', '${message.toJson()}');
        }
        // Файлы: история, задачи, настройки, хранилище.
        await for (final entity in root.list(recursive: true)) {
          if (entity is! File) continue;
          final bytes = await entity.readAsBytes();
          for (final canary in <String>[
            ...forbidden,
            Canary.hint,
            Canary.login,
          ]) {
            for (final form in Canary.encodings(canary)) {
              expect(
                containsBytes(bytes, form),
                isFalse,
                reason: '${p.relative(entity.path, from: root.path)}: '
                    '$canary',
              );
            }
          }
        }
        final settingsText =
            File(p.join(documents, 'settings.json')).readAsStringSync();
        expect(settingsText, contains('"passwords.seen_rev"'));
        expect(settingsText, contains('"passwords.vault_existed": true'));
        expect(settingsText, isNot(contains('Почта')));
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
            logs.add(line),
      ),
    );
    for (final line in logs) {
      expectClean('вывод', line);
    }
  });

  test('флаг «подсказки в истории» — подсказка в тексте, пароля нет', () async {
    final vault = testVault(InMemoryVaultStore(), crypto);
    final facade = VaultFacade(vault);
    await vault.create(secret(Canary.master), params: fastKdf);
    await vault.addEntry(
      service: 'Почта',
      hint: Canary.hint,
      password: secret(Canary.password),
    );
    await vault.setPrefs(
      const <String, Object?>{'hints_in_history': true},
      master: secret(Canary.master),
    );
    final assistant = AssistantController(
      extensions: ExtensionRegistry(
        connectors: <Connector>[PasswordsConnector(vault: facade)],
        choice: const ExtensionChoice(enabled: <String>{'passwords'}),
      ),
      knownSecret: facade.knownSecret,
    );
    final response = await assistant.handle('забыл пароль от почты');
    expect(response.message, contains(Canary.hint));
    expectClean('ответ', response.message, hint: false);
    expect(
      (await assistant.handle('пароль от почты?')).message,
      isNot(contains(Canary.password)),
    );
    vault.lock();
  });

  test('модели навыка: toString без данных', () {
    expect(
      '${const PasswordCommand(cmd: 'passwords.hint', confidence: 1, query: 'почта')}',
      'PasswordCommand(passwords.hint)',
    );
    expect(
      '${const SecureCardCommand(SecureCardRequest(kind: SecureCardKind.hint), 'choose', entryId: '00')}',
      'SecureCardCommand(choose)',
    );
    expect('${PasswordsConnector()}', 'PasswordsConnector');
  });
}
