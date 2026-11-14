import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';

/// Выбранный файл: путь и байты. Байты затирает тот, кто их разбирает.
final class PickedFile {
  const PickedFile({required this.path, required this.bytes});

  final String path;
  final Uint8List bytes;

  String get name => p.basename(path);

  @override
  String toString() => 'PickedFile(${bytes.length} B)';
}

/// Файл больше допустимого — не читаем вовсе.
final class FileTooLarge implements Exception {
  const FileTooLarge();

  @override
  String toString() => 'FileTooLarge';
}

/// Открыть и сохранить файлы навыка «Пароли»: CSV из браузера и копию
/// `.relaybak`. Без нового нативного пакета (ADR-014: `file_selector` /
/// `share_plus` — вместе с нативной частью этапа 4): свой выбор файла на
/// чистом Dart поверх `dart:io`. Тесты подменяют реализацию.
abstract interface class PasswordFiles {
  /// Выбрать и прочитать файл с одним из [extensions] (без точки) не
  /// больше [maxBytes]. `null` — отменили. Больше — [FileTooLarge].
  Future<PickedFile?> open(
    BuildContext context, {
    required String title,
    required List<String> extensions,
    required int maxBytes,
  });

  /// Сохранить [bytes] под именем [fileName] в выбранную папку. Путь или
  /// `null` (отменили). Файл записывается целиком и сбрасывается на диск.
  Future<String?> save(
    BuildContext context, {
    required String title,
    required String fileName,
    required Uint8List bytes,
  });

  /// Прочитать сохранённое (проверка копии после записи).
  Future<Uint8List?> read(String path);

  /// Удалить файл (CSV после импорта, неудачную копию).
  Future<bool> delete(String path);

  /// Можно ли удалить файл из приложения (на Android — только
  /// инструкция).
  bool get canDelete;

  /// Где лежат файлы, если выбрать их негде (подсказка человеку).
  String get placeNote;
}

/// Реализация на `dart:io`: простой выбор файла и папки внутри
/// приложения. Адреса и файлы сами ничего не открывают.
final class IoPasswordFiles implements PasswordFiles {
  const IoPasswordFiles();

  @override
  bool get canDelete => !Platform.isAndroid;

  @override
  String get placeNote => Platform.isAndroid
      ? 'На Android положите файл в папку приложения (Android/data/…/files) '
          'через компьютер или файловый менеджер.'
      : 'Обычно файл лежит в «Загрузках».';

  Future<String> _start() async {
    Directory? dir;
    try {
      dir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getDownloadsDirectory();
    } on Object {
      dir = null;
    }
    dir ??= await getApplicationDocumentsDirectory();
    return dir.path;
  }

  @override
  Future<PickedFile?> open(
    BuildContext context, {
    required String title,
    required List<String> extensions,
    required int maxBytes,
  }) async {
    final start = await _start();
    if (!context.mounted) return null;
    final path = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => FileBrowserDialog(
        title: title,
        start: start,
        extensions: extensions,
      ),
    );
    if (path == null) return null;
    final file = File(path);
    if (await file.length() > maxBytes) throw const FileTooLarge();
    return PickedFile(path: path, bytes: await file.readAsBytes());
  }

  @override
  Future<String?> save(
    BuildContext context, {
    required String title,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final start = await _start();
    if (!context.mounted) return null;
    final folder = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => FileBrowserDialog(
        title: title,
        start: start,
        extensions: const <String>[],
        pickFolder: true,
        fileName: fileName,
      ),
    );
    if (folder == null) return null;
    var path = p.join(folder, fileName);
    for (var n = 2; await File(path).exists(); n++) {
      final ext = p.extension(fileName);
      path = p.join(folder, '${p.basenameWithoutExtension(fileName)}-$n$ext');
    }
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<bool> delete(String path) async {
    try {
      await File(path).delete();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  String toString() => 'IoPasswordFiles';
}

/// Выбор файла или папки на `dart:io`: папки, файлы с нужным
/// расширением, «вверх», путь вручную.
class FileBrowserDialog extends StatefulWidget {
  const FileBrowserDialog({
    super.key,
    required this.title,
    required this.start,
    required this.extensions,
    this.pickFolder = false,
    this.fileName,
  });

  final String title;
  final String start;
  final List<String> extensions;
  final bool pickFolder;
  final String? fileName;

  @override
  State<FileBrowserDialog> createState() => _FileBrowserDialogState();
}

class _FileBrowserDialogState extends State<FileBrowserDialog> {
  late String _dir = widget.start;
  List<FileSystemEntity> _items = const <FileSystemEntity>[];
  bool _failed = false;
  final TextEditingController _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_list(_dir));
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _list(String dir) async {
    List<FileSystemEntity> items;
    var failed = false;
    try {
      items = await Directory(dir)
          .list(followLinks: false)
          .where(
            (FileSystemEntity e) =>
                !p.basename(e.path).startsWith('.') &&
                (e is Directory ||
                    (!widget.pickFolder &&
                        e is File &&
                        widget.extensions.any(
                          (String ext) =>
                              e.path.toLowerCase().endsWith('.$ext'),
                        ))),
          )
          .toList();
      items.sort((FileSystemEntity a, FileSystemEntity b) {
        if ((a is Directory) != (b is Directory)) {
          return a is Directory ? -1 : 1;
        }
        return p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase(),
            );
      });
    } on Object {
      items = const <FileSystemEntity>[];
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _dir = dir;
      _items = items;
      _failed = failed;
      _path.text = dir;
    });
  }

  @override
  Widget build(BuildContext context) {
    final parent = p.dirname(_dir);
    return AlertDialog(
      backgroundColor: AssistantColors.raised,
      title: WholeWordText(widget.title),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('file-browser-path'),
              controller: _path,
              decoration: const InputDecoration(labelText: 'Папка'),
              onSubmitted: (String value) => unawaited(_list(value.trim())),
            ),
            if (widget.fileName != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Имя файла: ${widget.fileName}',
                  style: const TextStyle(color: AssistantColors.muted),
                ),
              ),
            const SizedBox(height: 8),
            if (parent != _dir)
              ListTile(
                dense: true,
                leading: const Icon(Icons.arrow_upward, size: 18),
                title: const WholeWordText('Вверх'),
                onTap: () => unawaited(_list(parent)),
              ),
            if (_failed)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Эту папку не открыть.',
                  style: TextStyle(color: AssistantColors.danger),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _items.length,
                itemBuilder: (BuildContext context, int i) {
                  final item = _items[i];
                  final folder = item is Directory;
                  return ListTile(
                    key: ValueKey<String>(
                      'file-browser-${p.basename(item.path)}',
                    ),
                    dense: true,
                    leading: Icon(
                      folder
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                      size: 18,
                    ),
                    title: Text(p.basename(item.path)),
                    onTap: () => folder
                        ? unawaited(_list(item.path))
                        : Navigator.of(context).pop(item.path),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        if (widget.pickFolder)
          FilledButton(
            key: const ValueKey<String>('file-browser-here'),
            onPressed: _failed ? null : () => Navigator.of(context).pop(_dir),
            child: const Text('Сохранить сюда'),
          ),
      ],
    );
  }
}
