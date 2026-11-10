import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_matcher.dart';

import 'fixtures.dart';

Map<String, Object?> _json([String path = currentManifestPath]) =>
    jsonDecode(manifestSource(path)) as Map<String, Object?>;

List<String> _errors(void Function(Map<String, Object?> json) patch) {
  final json = _json();
  patch(json);
  return ManifestDescription.check(
    json,
    appId: 'halowarekeep',
    manifestUri: Uri.parse('https://warehouse.example/assistant.json'),
  );
}

Map<String, Object?> _command(Map<String, Object?> json, String id) =>
    (json['commands']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> c) => c['id'] == id);

void main() {
  group('описания склада', () {
    test('текущее: принято, версии, входа по ссылке и выхода нет', () {
      final d = manifest();
      expect(d.appId, 'halowarekeep');
      expect(d.version, isNull);
      expect(d.qr, isNull);
      expect(d.logout, isNull);
      expect(d.commands.map((ManifestCommand c) => c.id), <String>[
        'where',
        'count',
        'price',
        'cell',
        'today',
        'yesterday',
        'week',
        'nophoto',
        'help',
      ]);
      expect(d.only, <String>[
        'ask_stock',
        'ask_cell',
        'ask_arrivals',
        'ask_nophoto',
      ]);
      expect(d.access['staff']!.needs, <String>['token', 'sid']);
      expect(d.credentials['sid']!.get!.action, 'auth_check');
      expect(d.fallback, 'where');
      expect(d.fingerprint, hasLength(16));
    });

    test('1.4.56: версия, auth.qr и auth.logout', () {
      final d = manifest(patchedManifestPath);
      expect(d.version, '1.4.56');
      expect(d.qr!.action, 'qr_take');
      expect(d.qr!.param, 'code');
      expect(d.qr!.linkParam, 'qr');
      expect(d.qr!.take['sid'], 'sid');
      expect(d.qr!.errors['410'], contains('Код устарел'));
      expect(d.logout!.action, 'sess_end');
      expect(d.logout!.needs, <String>['token', 'sid']);
      // Вход и выход — не команды: в api.only их нет.
      expect(d.only, isNot(contains('qr_take')));
      expect(d.only, isNot(contains('sess_end')));
    });

    test('в описаниях нет секретов: только подписи и имена ключей', () {
      for (final path in <String>[currentManifestPath, patchedManifestPath]) {
        final text = manifestSource(path);
        expect(RegExp(r'[0-9a-f]{32}').hasMatch(text), isFalse, reason: path);
        final auth = _json(path)['auth']! as Map<String, Object?>;
        expect(
          (auth['headers']! as Map<String, Object?>).values,
          everyElement(matches(r'^\{\$[a-z]+\}$')),
        );
      }
    });

    test('встроенная копия в assets — описание 1.4.56 (ADR-012)', () {
      expect(
        File(ConnectionSlots.warehouse.builtInAsset!).readAsStringSync(),
        manifestSource(patchedManifestPath),
      );
    });
  });

  group('проверка как askCheck', () {
    test('исправное описание — без ошибок', () {
      expect(_errors((_) {}), isEmpty);
    });

    test('чужой формат и нет команд', () {
      expect(
        _errors((j) => j['format'] = 'assistant/2'),
        contains(contains('format')),
      );
      expect(
        _errors((j) => j['commands'] = <Object?>[]),
        contains(contains('commands: нет ни одной команды')),
      );
    });

    test('действие не из api.only', () {
      expect(
        _errors(
          (j) => (_command(j, 'where')['call']!
              as Map<String, Object?>)['action'] = 'stock_write',
        ),
        contains(contains('не входит в api.only')),
      );
    });

    test('действия входа и выхода — только известные и не команды', () {
      List<String> patched(void Function(Map<String, Object?> auth) patch) {
        final json = _json(patchedManifestPath);
        patch(json['auth']! as Map<String, Object?>);
        return ManifestDescription.check(json, appId: 'halowarekeep');
      }

      Map<String, Object?> sidGet(Map<String, Object?> auth) =>
          ((auth['credentials']! as Map<String, Object?>)['sid']!
              as Map<String, Object?>)['get']! as Map<String, Object?>;

      expect(patched((_) {}), isEmpty);
      // Подменённое описание: выход и личный ключ — изменяющими действиями.
      expect(
        patched(
          (Map<String, Object?> a) =>
              (a['logout']! as Map<String, Object?>)['action'] = 'item_delete',
        ),
        contains(contains('auth.logout.action: действие «item_delete»')),
      );
      expect(
        patched((Map<String, Object?> a) {
          sidGet(a)
            ..['action'] = 'user_set_role'
            ..['body'] = <String, Object?>{
              'login': '{login}',
              'role': 'admin',
            };
        }),
        allOf(
          contains(contains('действие «user_set_role»')),
          contains(contains('body.role: только «{login}» или «{pass}»')),
        ),
      );
      // Действие из api.only — команда, а не вход (и не известное).
      expect(
        patched(
          (Map<String, Object?> a) =>
              (a['qr']! as Map<String, Object?>)['action'] = 'ask_stock',
        ),
        allOf(
          contains(contains('команда из api.only')),
          contains(contains('помощник не зовёт')),
        ),
      );
      expect(
        patched(
          (Map<String, Object?> a) => (a['credentials']!
              as Map<String, Object?>)['token'] = <String, Object?>{
            'label': 'Пароль',
            'get': <String, Object?>{'action': 'auth_check'},
          },
        ),
        contains(contains('только личный ключ (sid)')),
      );
      expect(
        patched(
          (Map<String, Object?> a) => sidGet(a)['body'] = <String, Object?>{
            'a': '{pass}',
            'b': '{pass}',
          },
        ),
        contains(contains('повторяется')),
      );
      expect(
        patched(
          (Map<String, Object?> a) => (a['logout']!
              as Map<String, Object?>)['needs'] = <String>['pass'],
        ),
        contains(contains('auth.logout.needs')),
      );
      // Текущее описание тоже проверяется: его credentials.sid.get.
      final current = _json();
      sidGet(current['auth']! as Map<String, Object?>)['action'] = 'item_set';
      expect(
        () => ManifestDescription.parse(jsonEncode(current)),
        throwsA(isA<ManifestException>()),
      );
    });

    test('поле без описания, два поля подряд, повтор id', () {
      expect(
        _errors(
          (j) =>
              (_command(j, 'where')['say']! as List<Object?>).add('где {nope}'),
        ),
        contains(contains('{nope}')),
      );
      expect(
        _errors(
          (j) => (_command(j, 'where')['say']! as List<Object?>).add('{q} {q}'),
        ),
        contains(contains('два поля подряд')),
      );
      expect(
        _errors((j) => _command(j, 'count')['id'] = 'where'),
        contains(contains('id повторяется')),
      );
    });

    test('плохой shape и слишком длинный shape', () {
      Map<String, Object?> slots(Map<String, Object?> j) =>
          (_command(j, 'cell')['slots']! as Map<String, Object?>)['cell']!
              as Map<String, Object?>;
      expect(
        _errors((j) => slots(j)['shape'] = '(('),
        contains(contains('не регулярное выражение')),
      );
      expect(
        _errors((j) => slots(j)['shape'] = 'a' * 201),
        contains(contains('длиннее 200')),
      );
    });

    test('fallback с двумя полями и без команды', () {
      expect(
        _errors((j) => j['fallback'] = 'today'),
        contains(contains('ровно одно поле')),
      );
      expect(
        _errors((j) => j['fallback'] = 'nope'),
        contains(contains('нет команды')),
      );
    });

    test('чужой адрес API, чужое приложение, метод', () {
      expect(
        _errors(
          (j) => (j['api']! as Map<String, Object?>)['url'] =
              'https://evil.example/api.php',
        ),
        contains(contains('на другом сервере')),
      );
      expect(
        _errors(
          (j) => (j['api']! as Map<String, Object?>)['url'] =
              'http://warehouse.example/api.php',
        ),
        contains(contains('на другом сервере')),
      );
      expect(
        _errors((j) => (j['app']! as Map<String, Object?>)['id'] = 'expeora'),
        contains(contains('app.id')),
      );
      expect(
        _errors((j) => (j['api']! as Map<String, Object?>)['method'] = 'PUT'),
        contains(contains('api.method')),
      );
    });

    test('файл больше 256 КБ и не JSON — исключение', () {
      expect(
        () => ManifestDescription.parse(' ' * (256 * 1024 + 1)),
        throwsA(isA<ManifestException>()),
      );
      expect(
        () => ManifestDescription.parse('<html>'),
        throwsA(
          isA<ManifestException>().having(
            (ManifestException e) => e.message,
            'message',
            'это не JSON',
          ),
        ),
      );
    });
  });

  group('разбор как askMatch', () {
    for (final path in <String>[currentManifestPath, patchedManifestPath]) {
      test('каждый пример доходит до своей команды: $path', () {
        final matcher = ManifestMatcher(manifest(path));
        for (final command in matcher.description.commands) {
          for (final example in command.examples) {
            expect(
              matcher.askMatch(example)?.command.id,
              command.id,
              reason: example,
            );
          }
        }
      });
    }

    final matcher = ManifestMatcher(manifest());

    test('длинная фраза без поля сильнее «где {q}»', () {
      expect(matcher.askMatch('где нет фото')!.command.id, 'nophoto');
      expect(matcher.askMatch('где лежит 64115')!.slots, <String, String>{
        'q': '64115',
      });
    });

    test('shape и вид поля: ячейка заглавными', () {
      final hit = matcher.askMatch('что в ячейке 215 - 1 - 1а')!;
      expect(hit.command.id, 'cell');
      expect(hit.slots['cell'], '215-1-1А');
      expect(matcher.askMatch('без места')!.slots['cell'], 'БЕЗ МЕСТА');
    });

    test('связки снимаются, иначе — команда по умолчанию', () {
      expect(matcher.askMatch('подскажи где лежит 64115')!.how, 'say');
      final fallback = matcher.askMatch('стул венский')!;
      expect(fallback.how, 'fallback');
      expect(fallback.command.id, 'where');
      expect(fallback.slots['q'], 'стул венский');
    });
  });
}
