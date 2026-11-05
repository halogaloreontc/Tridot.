import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/extensions/pack.dart';
import 'package:local_assistant/core/extensions/pack_store.dart';
import 'package:path/path.dart' as p;

String pack(
  String id, {
  String type = 'jokes',
  String title = 'Пак',
  List<Map<String, Object?>>? entries,
}) =>
    jsonEncode(<String, Object?>{
      'format': 'assistant-pack/1',
      'id': id,
      'type': type,
      'title': title,
      'author': 'Автор',
      'language': 'ru',
      'version': '1.0.0',
      'entries': entries ??
          <Map<String, Object?>>[
            <String, Object?>{'id': 'e1', 'text': 'Текст $id'},
          ],
    });

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('packs_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('встроенные загружаются, битые не мешают остальным', () async {
    final store = PackStore.memory(
      builtIn: <String>[pack('jokes.basic'), '{битый', pack('puns.a')],
    );
    await store.load();
    expect(
      store.packs.map((i) => i.pack.id),
      <String>['jokes.basic', 'puns.a'],
    );
    expect(store.packs.every((i) => i.builtIn), isTrue);
    expect(store.loadErrors, hasLength(1));
  });

  test('импорт, замена с подтверждением, удаление, сохранение в файлы',
      () async {
    final dir = p.join(temp.path, 'packs');
    final store = PackStore(
      loadBuiltIn: () async => <String>[pack('jokes.basic')],
      userDirectory: dir,
    );
    await store.load();

    var result = await store.importFromString(pack('my.jokes', title: 'Мои'));
    expect(result.ok, isTrue);
    expect(File(p.join(dir, 'my.jokes.json')).existsSync(), isTrue);

    result = await store.importFromString(pack('my.jokes', title: 'Новые'));
    expect(result.ok, isFalse);
    expect(result.needsReplaceConfirmation, isTrue);
    expect(store['my.jokes']!.pack.title, 'Мои');

    result = await store.importFromString(
      pack('my.jokes', title: 'Новые'),
      replace: true,
    );
    expect(result.ok, isTrue);
    expect(store['my.jokes']!.pack.title, 'Новые');

    // Новый экземпляр читает файлы с диска.
    final reopened = PackStore(
      loadBuiltIn: () async => <String>[pack('jokes.basic')],
      userDirectory: dir,
    );
    await reopened.load();
    expect(reopened['my.jokes']!.pack.title, 'Новые');
    expect(reopened['my.jokes']!.builtIn, isFalse);

    expect(await reopened.remove('jokes.basic'), isFalse, reason: 'встроен');
    expect(await reopened.remove('my.jokes'), isTrue);
    expect(File(p.join(dir, 'my.jokes.json')).existsSync(), isFalse);
    expect(reopened['my.jokes'], isNull);
  });

  test('id встроенного пака и навыка заняты', () async {
    final store = PackStore.memory(
      builtIn: <String>[pack('jokes.basic')],
      reservedIds: <String>{'calc'},
    );
    await store.load();
    var result = await store.importFromString(pack('jokes.basic'));
    expect(result.errors.single, contains('встроен в приложение'));
    result = await store.importFromString(pack('calc'));
    expect(result.errors.single, contains('занят навыком'));
    result = await store.importFromString('{"format":"x"}');
    expect(result.errors, isNotEmpty);
  });

  test('битый пользовательский файл пропускается', () async {
    final dir = Directory(p.join(temp.path, 'packs'))..createSync();
    File(p.join(dir.path, 'bad.json')).writeAsStringSync('{');
    File(p.join(dir.path, 'good.json')).writeAsStringSync(pack('good.one'));
    File(p.join(dir.path, 'clash.json')).writeAsStringSync(pack('jokes.basic'));
    final store = PackStore(
      loadBuiltIn: () async => <String>[pack('jokes.basic')],
      userDirectory: dir.path,
    );
    await store.load();
    expect(store['good.one'], isNotNull);
    expect(store['jokes.basic']!.builtIn, isTrue);
    expect(store.loadErrors, hasLength(2));
  });

  test('параллельные импорты не теряют файлы', () async {
    final dir = p.join(temp.path, 'packs');
    final store = PackStore(userDirectory: dir);
    await store.load();
    await Future.wait(<Future<Object?>>[
      for (var i = 0; i < 10; i++) store.importFromString(pack('pack.$i')),
    ]);
    final reopened = PackStore(userDirectory: dir);
    await reopened.load();
    expect(reopened.packs, hasLength(10));
    expect(
      Directory(dir).listSync().where((e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('записи по виду, меткам, помощнику и включённым пакам', () async {
    final store = PackStore.memory(
      builtIn: <String>[
        pack(
          'jokes.a',
          entries: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'a1',
              'text': 'про задачи',
              'tags': <String>['задачи', 'понедельник'],
            },
            <String, Object?>{
              'id': 'a2',
              'text': 'для Rio',
              'tags': <String>['кофе'],
              'persona': 'rio',
            },
          ],
        ),
        pack(
          'puns.b',
          type: 'puns',
          entries: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'b1',
              'text': 'каламбур',
              'tags': <String>['Задачи'],
              'persona': 'noda',
            },
          ],
        ),
      ],
    );
    await store.load();
    List<String> ids(List<PackEntry> entries) =>
        entries.map((e) => e.id).toList();
    expect(ids(store.entries()), <String>['a1', 'a2', 'b1']);
    expect(ids(store.entries(type: 'jokes')), <String>['a1', 'a2']);
    expect(ids(store.entries(tags: <String>{'задачи'})), <String>['a1', 'b1']);
    expect(
      ids(store.entries(tags: <String>{'Задачи', 'понедельник'})),
      <String>['a1'],
    );
    expect(ids(store.entries(persona: PackPersona.rio)), <String>['a1', 'a2']);
    expect(ids(store.entries(persona: PackPersona.noda)), <String>['a1', 'b1']);
    expect(ids(store.entries(packIds: <String>{'puns.b'})), <String>['b1']);
    expect(store.entries(type: 'phrases'), isEmpty);
  });

  group('находки ревью', () {
    test('большой пак под 1 МБ сохраняется компактно и переживает перезапуск',
        () async {
      final dir = p.join(temp.path, 'packs');
      final entries = <Map<String, Object?>>[
        for (var i = 0; i < PackFormat.maxEntries; i++)
          <String, Object?>{
            'id': 'e$i',
            'text': 'Шутка номер $i ${'x' * 110}',
            'tags': <String>['задачи'],
            'persona': 'any',
          },
      ];
      final source = pack('big.pack', entries: entries);
      final size = utf8.encode(source).length;
      expect(size, greaterThan(PackFormat.maxBytes * 0.9));
      expect(size, lessThanOrEqualTo(PackFormat.maxBytes));
      final store = PackStore(userDirectory: dir);
      final result = await store.importFromString(source);
      expect(result.ok, isTrue, reason: result.errors.join());
      final saved = File(p.join(dir, 'big.pack.json')).lengthSync();
      expect(saved, lessThanOrEqualTo(size));
      final reopened = PackStore(userDirectory: dir);
      await reopened.load();
      expect(reopened.loadErrors, isEmpty);
      expect(reopened['big.pack']!.pack.entries, hasLength(5000));
    });

    test('ошибка записи — ошибка в результате, а не исключение', () async {
      final blocker = File(p.join(temp.path, 'file'))..writeAsStringSync('');
      final store = PackStore(userDirectory: p.join(blocker.path, 'packs'));
      await store.load();
      final result = await store.importFromString(pack('my.pack'));
      expect(result.ok, isFalse);
      expect(result.errors.single, startsWith('Не удалось сохранить пак'));
      expect(store['my.pack'], isNull);
      // Очередь не сломана: следующая операция выполняется.
      expect(await store.remove('my.pack'), isFalse);
    });

    test('файл, названный не по id, удаляется и не возвращается', () async {
      final dir = Directory(p.join(temp.path, 'packs'))..createSync();
      File(p.join(dir.path, 'other.json'))
          .writeAsStringSync(pack('renamed', title: 'Старое'));
      final store = PackStore(userDirectory: dir.path);
      await store.load();
      expect(store['renamed']!.path, p.join(dir.path, 'other.json'));
      expect(await store.remove('renamed'), isTrue);
      expect(dir.listSync(), isEmpty);
      final reopened = PackStore(userDirectory: dir.path);
      await reopened.load();
      expect(reopened['renamed'], isNull);
    });

    test('замена пака из чужого файла не оставляет дубля', () async {
      final dir = Directory(p.join(temp.path, 'packs'))..createSync();
      File(p.join(dir.path, 'other.json'))
          .writeAsStringSync(pack('renamed', title: 'Старое'));
      final store = PackStore(userDirectory: dir.path);
      await store.load();
      final result = await store.importFromString(
        pack('renamed', title: 'Новое'),
        replace: true,
      );
      expect(result.ok, isTrue);
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        <String>['renamed.json'],
      );
    });

    test(
        'одновременные импорты одного id: подтверждение у всех, кроме '
        'первого', () async {
      final dir = p.join(temp.path, 'packs');
      final store = PackStore(userDirectory: dir);
      await store.load();
      final results = await Future.wait(<Future<PackImportResult>>[
        for (var i = 0; i < 20; i++)
          store.importFromString(pack('same', title: 'v$i')),
      ]);
      expect(results.where((r) => r.ok), hasLength(1));
      expect(results.where((r) => r.needsReplaceConfirmation), hasLength(19));
      expect(store['same']!.pack.title, 'v0');
      final reopened = PackStore(userDirectory: dir);
      await reopened.load();
      expect(reopened['same']!.pack.title, 'v0');
    });

    test('удаление во время импорта применяется после него', () async {
      final dir = p.join(temp.path, 'packs');
      final store = PackStore(userDirectory: dir);
      await store.load();
      final imported = store.importFromString(pack('race'));
      final removed = store.remove('race');
      expect((await imported).ok, isTrue);
      expect(await removed, isTrue);
      expect(store['race'], isNull);
      expect(File(p.join(dir, 'race.json')).existsSync(), isFalse);
    });

    test('сбой встроенных не мешает пользовательским', () async {
      final dir = Directory(p.join(temp.path, 'packs'))..createSync();
      File(p.join(dir.path, 'good.json')).writeAsStringSync(pack('good.one'));
      final store = PackStore(
        loadBuiltIn: () async => throw StateError('нет манифеста'),
        userDirectory: dir.path,
      );
      await store.load();
      expect(store['good.one'], isNotNull);
      expect(store.loadErrors.single, contains('Встроенные паки'));
    });

    test('каталог паков — файл: загрузка без исключения', () async {
      final blocker = File(p.join(temp.path, 'packs'))..writeAsStringSync('');
      final store = PackStore(
        loadBuiltIn: () async => <String>[pack('jokes.basic')],
        userDirectory: blocker.path,
      );
      await store.load();
      expect(store['jokes.basic'], isNotNull);
    });
  });
}
