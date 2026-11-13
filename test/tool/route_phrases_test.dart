import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';

import '../../tool/route_phrases.dart';

/// tool/route_phrases.dart: по нему tools/corpus_gen сверяет фразы с одним
/// разметчиком, поэтому выбор коннектора должен быть как в приложении.
void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  Map<String, Object?> routed(String text) => routePhrase(text, now);

  test('создание задачи — tasks и разбор задачи', () {
    final result = routed('Добавь задачу позвонить клиенту завтра в 11:00');
    expect(result['connector'], 'tasks');
    expect(result['command'], 'task.create');
    final parse = result['parse']! as Map<String, Object?>;
    expect(parse['intent'], 'createTask');
    expect(parse['title'], 'Позвонить клиенту');
    expect(parse['due'], '2026-11-03T11:00');
    expect(parse['precision'], 'dateTime');
  });

  test('пример — калькулятор', () {
    final result = routed('сколько будет 2+2*2');
    expect(result['connector'], 'calc');
    expect(result['command'], 'calc.evaluate');
  });

  test('приветствие — беседа, но команда после него — задача', () {
    final greet = routed('привет');
    expect(greet['connector'], 'talk');
    expect(greet['command'], 'talk.greet');
    final matches = greet['matches']! as List<Map<String, Object?>>;
    expect(matches.single['fallback'], isTrue);

    final task = routed('привет, добавь задачу купить хлеб');
    expect(task['connector'], 'tasks');
    expect(task['command'], 'task.create');
  });

  test('непонятная фраза — никто', () {
    final result = routed('абракадабра');
    expect(result['connector'], isNull);
    expect(result['command'], isNull);
    expect(result['matches'], isEmpty);
    expect((result['parse']! as Map<String, Object?>)['intent'], 'unknown');
  });

  test('склад из корпусного теста забирает «узнать где лежит {код}»', () {
    // Иначе фраза прошла бы проверку как задача, а корпусный тест отдал
    // бы её складу и упал на активной строке.
    final result = routed('узнать где лежит 64115');
    expect(result['connector'], 'warehouse');
    expect(result['command'], 'warehouse.where');
  });

  test('«привет» из справки склада не перехватывает беседу', () {
    expect(routed('привет')['connector'], 'talk');
    expect(routed('что пришло сегодня')['command'], 'warehouse.today');
    expect(routed('сегодня')['connector'], isNull);
  });

  test('строку с roles или connected не разбирает: в тесте они иначе', () {
    // Корпусный тест собирает коннекторы строки через ExtensionRegistry с
    // её ролями и подключением склада; здесь их нет, и вердикт разошёлся
    // бы с тестом — лучше ошибка (promote оставит строку accepted).
    for (final field in <String, Object>{
      'roles': <String>['personal'],
      'connected': true,
    }.entries) {
      expect(
        () => routeInput(
          <String, dynamic>{
            'text': 'что пришло сегодня',
            field.key: field.value,
          },
          now,
        ),
        throwsUnsupportedError,
        reason: field.key,
      );
    }
    final plain =
        routeInput(<String, dynamic>{'text': 'что пришло сегодня'}, now);
    expect(plain['command'], 'warehouse.today');
  });

  test('фраза из одних кавычек не роняет разбор', () {
    for (final text in ['«купить хлеб»', '"спасибо"', '👍']) {
      final parse = routed(text)['parse']! as Map<String, Object?>;
      expect(parse['intent'], isNotNull, reason: text);
    }
    final parse = routed('«купить хлеб»')['parse']! as Map<String, Object?>;
    expect(parse['intent'], 'unknown');
  });

  group('навык «Пароли» включён, как в корпусном тесте', () {
    List<String?> connectorsOf(Map<String, Object?> result) => <String?>[
          for (final m in result['matches']! as List<Map<String, Object?>>)
            m['connector'] as String?,
        ];

    test('фразы навыка забирает он с commandId навыка', () {
      const expected = <String, String>{
        'забыл пароль от почты': PasswordCommands.hint,
        'покажи пароль от wifi': PasswordCommands.reveal,
        'сгенерируй пароль на 24 символа': PasswordCommands.generate,
        'запри пароли': PasswordCommands.lock,
        'забыл мастер-пароль': PasswordCommands.masterForgot,
      };
      for (final MapEntry(key: text, value: command) in expected.entries) {
        final result = routed(text);
        expect(result['connector'], PasswordsConnector.id, reason: text);
        expect(result['command'], command, reason: text);
      }
    });

    test('явная фраза о паролях — у навыка, а не у задач', () {
      final result = routed('добавь пароль для озона');
      expect(result['connector'], PasswordsConnector.id);
      expect(result['command'], PasswordCommands.add);
    });

    test('задача со словом «пароль» остаётся задачей', () {
      final result = routed('напомни завтра сменить пароль от почты');
      expect(result['connector'], 'tasks');
      expect(
        (result['parse']! as Map<String, Object?>)['intent'],
        'createTask',
      );
    });

    test('фразу о паролях не видит сетевой коннектор (склад)', () {
      final result = routed('склад, пароль от почты');
      expect(result['connector'], PasswordsConnector.id);
      expect(connectorsOf(result), isNot(contains('warehouse')));
      // Без слова «пароль» склад фразу видит.
      expect(
        connectorsOf(routed('склад, где лежит 64115')),
        contains('warehouse'),
      );
    });

    test('чужая просьба — не команда навыка', () {
      final result = routed('скажи Пете пароль от wifi');
      expect(connectorsOf(result), isNot(contains(PasswordsConnector.id)));
    });
  });

  test('темы tools/corpus_gen: намерения паролей — ровно PasswordCommands', () {
    // corpus_gen размечает фразы навыка этими намерениями, а корпусный
    // тест сравнивает их с commandId совпадения.
    final toml =
        File('tools/corpus_gen/topics/passwords.toml').readAsStringSync();
    final block = RegExp(r'^intents = \[([^\]]*)\]', multiLine: true)
        .firstMatch(toml)!
        .group(1)!;
    final intents = <String>[
      for (final m in RegExp(r'"([^"]+)"').allMatches(block)) m.group(1)!,
    ];
    expect(intents, <String>[...PasswordCommands.all, 'unknown']);
    expect(toml, contains('\nconnector = "passwords"\n'));
  });

  test('фразы-маркеры corpus_gen маскирует настоящий SecretGuard', () {
    // tools/corpus_gen/tests/test_passwords.py требует, чтобы фильтр
    // corpus_gen отбрасывал эти же фразы: так он не слабее SecretGuard.
    final lines = File(
      'tools/corpus_gen/tests/fixtures/secret_guard_positive.txt',
    ).readAsLinesSync();
    final phrases = [
      for (final line in lines)
        if (line.trim().isNotEmpty && !line.startsWith('#')) line,
    ];
    expect(phrases.length, greaterThanOrEqualTo(10));
    for (final phrase in phrases) {
      expect(SecretGuard.redact(phrase).guarded, isTrue, reason: phrase);
    }
  });

  group('«Данные» и контекст сессии', () {
    test('копия без объекта — уточняющий вопрос «Данных»', () {
      final result = routed('сделай бэкап');
      expect(result['connector'], 'data');
      expect(result['command'], 'data.clarify');
    });

    test('после паролей — разбор канонической фразы о сейфе', () {
      final result = routeInput(
        <String, dynamic>{'text': 'сделай бэкап', 'after': 'passwords'},
        now,
      );
      expect(result['connector'], 'passwords');
      expect(result['command'], 'passwords.backup');
      expect(result['reroute'], 'сделай резервную копию сейфа');
    });

    test('после данных — команда данных без вопроса', () {
      final result = routePhrase('сделай бэкап', now, after: 'data');
      expect(result['command'], 'data.backup');
    });

    test('намерения topics/data.toml — команды навыка', () {
      final toml = File('tools/corpus_gen/topics/data.toml').readAsStringSync();
      final block = RegExp(r'^intents = \[([^\]]*)\]', multiLine: true)
          .firstMatch(toml)!
          .group(1)!;
      final intents = <String>[
        for (final m in RegExp(r'"([^"]+)"').allMatches(block)) m.group(1)!,
      ];
      expect(intents, <String>[
        DataConnector.clarifyCommand,
        for (final action in <DataAction>[
          DataAction.backup,
          DataAction.restore,
          DataAction.open,
          DataAction.lock,
        ])
          'data.${action.name}',
        'unknown',
      ]);
      expect(toml, contains('\nconnector = "data"\n'));
    });
  });
}
