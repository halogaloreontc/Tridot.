import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../replies/reply_library.dart';
import 'pack.dart';

/// Установленный пак и откуда он.
final class InstalledPack {
  const InstalledPack(this.pack, {required this.builtIn, this.path});

  final Pack pack;

  /// Встроен в приложение (assets/packs): не удаляется.
  final bool builtIn;

  /// Файл пользовательского пака на диске. Имя файла может не совпадать с
  /// id (файл переименовали или положили вручную): удалять нужно именно
  /// его. `null` — встроенный пак или магазин в памяти.
  final String? path;
}

/// Файл пака не сохранился или не удалился: сообщение по-русски.
final class PackStoreException implements Exception {
  const PackStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Итог импорта пака.
final class PackImportResult {
  const PackImportResult._({
    this.pack,
    this.errors = const <String>[],
    this.needsReplaceConfirmation = false,
  });

  /// Принятый и сохранённый пак.
  final Pack? pack;

  /// Ошибки проверки по-русски.
  final List<String> errors;

  /// Пользовательский пак с таким id уже есть: нужно подтверждение замены
  /// (повторный импорт с `replace: true`). Ничего не сохранено.
  final bool needsReplaceConfirmation;

  bool get ok => pack != null;
}

/// Паки: встроенные (assets/packs/*.json) и пользовательские
/// (`<документы>/assistant/packs/<id>.json`).
///
/// Паки — только данные (ADR-005): магазин их проверяет [PackFormat] и
/// ничего из них не выполняет. Записи файлов идут строго по очереди, как
/// в JsonTaskRepository.
final class PackStore {
  PackStore({
    Future<List<String>> Function()? loadBuiltIn,
    this.userDirectory,
    Set<String> reservedIds = const <String>{},
  })  : _loadBuiltIn = loadBuiltIn ?? (() async => const <String>[]),
        _reservedIds = reservedIds;

  /// Только в памяти: для тестов и предпросмотра.
  factory PackStore.memory({
    List<String> builtIn = const <String>[],
    Set<String> reservedIds = const <String>{},
  }) =>
      PackStore(loadBuiltIn: () async => builtIn, reservedIds: reservedIds);

  final Future<List<String>> Function() _loadBuiltIn;

  /// Каталог пользовательских паков; `null` — только в памяти.
  final String? userDirectory;

  Set<String> _reservedIds;

  final Map<String, InstalledPack> _packs = <String, InstalledPack>{};

  /// Ошибки загрузки: битый встроенный или пользовательский файл не мешает
  /// остальным.
  final List<String> loadErrors = <String>[];

  Future<void> _queue = Future<void>.value();

  /// Id навыков и подключений: пак с таким id спутал бы настройки.
  set reservedIds(Set<String> ids) => _reservedIds = Set<String>.of(ids);

  /// Записи каталога ответов, против которых проверяются паки ответов:
  /// встроенные и записи подключённых коннекторов.
  ReplySchema? replySchema;

  /// Все паки: сначала встроенные, затем пользовательские, по названию.
  List<InstalledPack> get packs {
    final list = _packs.values.toList()
      ..sort((a, b) {
        if (a.builtIn != b.builtIn) return a.builtIn ? -1 : 1;
        return a.pack.title.compareTo(b.pack.title);
      });
    return List<InstalledPack>.unmodifiable(list);
  }

  InstalledPack? operator [](String id) => _packs[id];

  /// Загружает встроенные паки и пользовательские файлы. Сбой одной части
  /// (встроенных, каталога, отдельного файла) попадает в [loadErrors] и не
  /// мешает остальным; исключений наружу нет.
  Future<void> load() => _enqueue(_load);

  Future<void> _load() async {
    _packs.clear();
    loadErrors.clear();
    List<String> builtIn = const <String>[];
    try {
      builtIn = await _loadBuiltIn();
    } on Object catch (error) {
      loadErrors.add('Встроенные паки не загрузились: $error');
    }
    for (final source in builtIn) {
      final result = PackFormat.parse(source, replySchema: replySchema);
      final pack = result.pack;
      if (pack == null) {
        loadErrors.add('Встроенный пак отклонён: ${result.errors.join(' ')}');
        continue;
      }
      _packs[pack.id] = InstalledPack(pack, builtIn: true);
    }
    final directory = userDirectory;
    if (directory == null) return;
    final List<File> files;
    try {
      final folder = Directory(directory);
      if (!await folder.exists()) return;
      files = await folder
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on Object catch (error) {
      loadErrors.add('Папка паков не читается: $error');
      return;
    }
    for (final file in files) {
      final name = p.basename(file.path);
      try {
        final result = PackFormat.parse(
          await file.readAsString(),
          replySchema: replySchema,
        );
        final pack = result.pack;
        final existing = pack == null ? null : _packs[pack.id];
        if (pack == null) {
          loadErrors.add('$name: ${result.errors.join(' ')}');
        } else if (existing?.builtIn ?? false) {
          loadErrors.add('$name: id «${pack.id}» занят встроенным паком.');
        } else if (_reservedIds.contains(pack.id)) {
          loadErrors.add('$name: id «${pack.id}» занят навыком.');
        } else if (existing != null) {
          // Два файла с одним id: берём тот, что назван по id.
          loadErrors.add(
            '$name: пак «${pack.id}» уже загружен из '
            '${p.basename(existing.path ?? '')}.',
          );
          if (name == '${pack.id}.json') {
            _packs[pack.id] =
                InstalledPack(pack, builtIn: false, path: file.path);
          }
        } else {
          _packs[pack.id] =
              InstalledPack(pack, builtIn: false, path: file.path);
        }
      } on Object catch (error) {
        loadErrors.add('$name: не читается ($error).');
      }
    }
  }

  /// Принимает пак, вставленный текстом. Пак с id встроенного или навыка
  /// отклоняется; пользовательский с тем же id заменяется только при
  /// [replace].
  ///
  /// Проверка «такой id уже есть» и запись идут одной операцией в общей
  /// очереди: два одновременных импорта одного нового id не проходят оба
  /// без подтверждения, а удаление во время импорта применяется после
  /// него. Ошибка записи на диск — в [PackImportResult.errors], пак не
  /// принимается.
  Future<PackImportResult> importFromString(
    String source, {
    bool replace = false,
  }) {
    final result = PackFormat.parse(source, replySchema: replySchema);
    final pack = result.pack;
    if (pack == null) {
      return Future<PackImportResult>.value(
        PackImportResult._(errors: result.errors),
      );
    }
    return _enqueue(() => _import(pack, replace: replace));
  }

  Future<PackImportResult> _import(Pack pack, {required bool replace}) async {
    final existing = _packs[pack.id];
    if (existing != null && existing.builtIn) {
      return PackImportResult._(
        errors: <String>[
          'Пак «${pack.id}» встроен в приложение: выберите другой id.',
        ],
      );
    }
    if (_reservedIds.contains(pack.id)) {
      return PackImportResult._(
        errors: <String>[
          'Id «${pack.id}» занят навыком или подключением: выберите другой.',
        ],
      );
    }
    if (existing != null && !replace) {
      return const PackImportResult._(needsReplaceConfirmation: true);
    }
    final encoded = pack.encode();
    // Сохранённый файл тоже должен пройти проверку при следующем запуске.
    if (utf8.encode(encoded).length > PackFormat.maxBytes) {
      return const PackImportResult._(
        errors: <String>['Файл пака больше 1 МБ.'],
      );
    }
    final String? path;
    try {
      path = await _writeFile(pack.id, encoded);
      final old = existing?.path;
      if (old != null && old != path) await _deleteFile(old);
    } on Object catch (error) {
      return PackImportResult._(
        errors: <String>['Не удалось сохранить пак: ${_reason(error)}.'],
      );
    }
    _packs[pack.id] = InstalledPack(pack, builtIn: false, path: path);
    return PackImportResult._(pack: pack);
  }

  /// Удаляет пользовательский пак. Встроенные не удаляются (`false`).
  /// Если файл не удалился, пак остаётся и летит [PackStoreException].
  Future<bool> remove(String id) => _enqueue(() async {
        final existing = _packs[id];
        if (existing == null || existing.builtIn) return false;
        try {
          final path =
              existing.path ?? (userDirectory == null ? null : _path(id));
          if (path != null) await _deleteFile(path);
        } on Object catch (error) {
          throw PackStoreException(
            'Не удалось удалить пак: ${_reason(error)}.',
          );
        }
        _packs.remove(id);
        return true;
      });

  /// Записи паков с фильтрами: вид, все метки [tags], помощник. [packIds] —
  /// только эти паки (включённые в настройках); `null` — все.
  List<PackEntry> entries({
    String? type,
    Set<String> tags = const <String>{},
    PackPersona persona = PackPersona.any,
    Set<String>? packIds,
  }) {
    final wanted = tags.map(PackFormat.normalizeTag).toSet();
    return <PackEntry>[
      for (final installed in packs)
        if ((type == null || installed.pack.type == type) &&
            (packIds == null || packIds.contains(installed.pack.id)))
          for (final entry in installed.pack.entries)
            if (entry.persona.suits(persona) &&
                wanted.every(entry.tags.contains))
              entry,
    ];
  }

  /// Операции с паками строго по очереди. Ошибка одной не блокирует
  /// следующие.
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  static String _reason(Object error) => switch (error) {
        FileSystemException(:final message, :final osError) =>
          osError == null ? message : '$message (${osError.message})',
        _ => '$error',
      };

  String _path(String id) => p.join(userDirectory!, '$id.json');

  /// Пишет файл пака атомарно (через временный) и возвращает путь;
  /// `null` — магазин в памяти.
  Future<String?> _writeFile(String id, String encoded) async {
    if (userDirectory == null) return null;
    final file = File(_path(id));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(file.path);
    return file.path;
  }

  Future<void> _deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
