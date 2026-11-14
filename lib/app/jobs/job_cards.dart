import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/chats/attachments.dart';
import '../../core/downloads/safe_zip.dart';
import '../../core/jobs/extension_card.dart';
import '../../core/jobs/job_placement.dart';
import '../../core/jobs/job_runner.dart';
import '../../core/skills/archiver/zip_ops.dart';
import '../../core/skills/converter/convert_targets.dart';
import '../../core/skills/converter/image_convert.dart';
import '../files/file_opener.dart';
import '../widgets/extension_card_view.dart';
import 'job_hub.dart';
import 'job_picker.dart';

/// Карточки расширений в чате: виджет по карточке сообщения, выбор файлов,
/// запуск задачи и что делать с результатом. Держит экран чата коротким:
/// [JobHub] — состояние задач, этот класс — их связь с файлами сессии.
final class JobCards {
  JobCards({
    required this.hub,
    required this.platform,
    required this.picker,
    required this.opener,
    required this.attachments,
    required this.tempRoot,
    this.tools,
    this.downloadsDir,
    this.isEnabled,
    this.onFinished,
    this.onMessage,
  });

  final JobHub hub;
  final JobPlatform platform;
  final JobFilePicker picker;
  final FileOpener opener;

  /// Хранилище вложений открытой книги чатов.
  final AttachmentStore Function() attachments;

  /// Временная папка приложения (`null` — ещё не известна).
  final Future<String> Function() tempRoot;

  /// Установленные внешние программы (`ffmpeg`); `null` — никаких.
  final Set<String> Function()? tools;

  Set<String> get _tools => tools?.call() ?? const <String>{};

  /// Папка загрузок загрузчика видео (`<Загрузки>/Tridot`); `null` —
  /// загрузчика нет.
  final Future<String?> Function()? downloadsDir;

  /// Расширение включено в «Настройки → Расширения»; `null` — все.
  /// Карточка выключенного остаётся в чате, но не запускается.
  final bool Function(String extensionId)? isEnabled;

  bool _enabled(ExtensionCard card) =>
      isEnabled?.call(card.extensionId) ?? true;

  /// Почему карточку сейчас нельзя запустить; `null` — можно.
  String? _blocker(ExtensionCard card) => ExtensionForms.blocker(
        card,
        platform,
        tools: _tools,
        enabled: _enabled(card),
      );

  /// Результат лежит во временной папке задач (хранилище «Только в
  /// памяти»): при следующем запуске она удаляется.
  static bool isTemporary(ExtensionCard card) => <String>[
        ...card.outputs,
        if (card.outputDir case final String dir) dir,
      ].any((String path) => p.split(path).contains(tempFolder));

  /// Поле файлов карточки: `files` у архиватора, `file` у конвертера.
  static FieldSpec? fileField(ExtensionCard card) => ExtensionForms.of(
        card.extensionId,
      )
          ?.where(
            (FieldSpec f) =>
                f.kind == FieldKind.files || f.kind == FieldKind.file,
          )
          .firstOrNull;

  /// Задача закончилась.
  final void Function(String chatId, ExtensionCard card)? onFinished;

  /// Короткое сообщение пользователю («Не удалось открыть файл»).
  final void Function(String text)? onMessage;

  /// Имя временной папки задач: `<временная папка>/tridot-jobs`; при
  /// запуске приложения удаляется целиком.
  static const String tempFolder = 'tridot-jobs';

  /// Карточка сообщения.
  Widget build(
    String chatId,
    ExtensionCard card, {
    required bool busy,
    required List<JobFile> sessionFiles,
    Widget Function(Widget child, void Function(List<JobFile>) onDrop)?
        dropTarget,
  }) {
    if (card.state == CardState.interrupted && card.cleanup.isNotEmpty) {
      hub.sweepInterrupted(chatId, card);
    }
    final field = fileField(card);
    final code = field?.code ?? 'files';
    void add(List<JobFile> files) {
      if (files.isEmpty || card.state != CardState.form) return;
      if (field?.kind == FieldKind.file) {
        // Один файл: новый заменяет прежний, папка не подходит.
        final file = files.where((JobFile f) => !f.folder).lastOrNull;
        if (file == null) return;
        card.setValue(code, <JobFile>[file]);
        // Прежняя цель могла не подойти новому файлу — выбрать заново.
        if (card.extensionId == ExtensionForms.converter) {
          final targets = ConvertTargets.targetsFor(file.name);
          final target = card.choice('target');
          if (target != null && !targets.contains(target)) {
            card.setValue('target', null);
          }
          if (card.choice('target') == null && targets.length == 1) {
            card.setValue('target', targets.single);
          }
        }
        hub.edited(chatId, card);
        return;
      }
      final current = card.files(code);
      card.setValue(code, <JobFile>[
        ...current,
        for (final file in files)
          if (!current.contains(file)) file,
      ]);
      hub.edited(chatId, card);
    }

    return ExtensionCardView(
      card: card,
      platform: platform,
      progress: hub.progressOf(card.id),
      busy: busy,
      canReveal: opener.canReveal,
      sessionFiles: sessionFiles,
      tools: _tools,
      enabled: _enabled(card),
      temporary: card.state == CardState.done && isTemporary(card),
      onAddFiles: () => unawaited(picker.files().then(add)),
      onAddFolder: () => unawaited(
        picker.folder().then(
              (JobFile? folder) => add(<JobFile>[if (folder != null) folder]),
            ),
      ),
      onAddSessionFile: (JobFile file) => add(<JobFile>[file]),
      onRemoveFile: (JobFile file) {
        card.setValue(code, card.files(code)..remove(file));
        hub.edited(chatId, card);
      },
      onChoice: (String code, String value) {
        card.setValue(code, value);
        hub.edited(chatId, card);
      },
      onText: (String code, String value) {
        if (card.state != CardState.form) return;
        final text = value.trim();
        final before = _blocker(card);
        card.setValue(code, text.isEmpty ? null : text);
        // Экран перестраивается, только когда меняется, можно ли
        // запускать (и подсказка под кнопкой); иначе чат сохраняется
        // чуть позже, а не на каждую букву.
        if (_blocker(card) != before) {
          hub.edited(chatId, card);
        } else {
          hub.editedLater(chatId, card);
        }
      },
      onRun: () => unawaited(run(chatId, card)),
      onCancel: () => hub.cancel(card.id),
      onRetry: () => hub.retry(chatId, card),
      onOpen: (String path) => unawaited(_open(path)),
      onReveal: (String path) => unawaited(_reveal(path)),
      dropTarget:
          dropTarget == null ? null : (Widget child) => dropTarget(child, add),
    );
  }

  Future<void> _open(String path) async {
    if (!await opener.open(path)) onMessage?.call('Не удалось открыть файл');
  }

  Future<void> _reveal(String path) async {
    if (!await opener.reveal(path)) {
      onMessage?.call('Не удалось открыть папку');
    }
  }

  /// «Запустить»: исходники, место результата и задача в изоляте.
  Future<void> run(String chatId, ExtensionCard card) async {
    if (hub.isRunning(card.id) || card.state != CardState.form) return;
    if (_blocker(card) != null) return;
    if (card.extensionId == ExtensionForms.ytdl) {
      await _runYtdl(chatId, card);
      return;
    }
    final temp = p.join(await tempRoot(), tempFolder, card.id);
    final store = attachments();
    final files = card.files(fileField(card)?.code ?? 'files');
    final sources = <JobSource>[];
    for (final file in files) {
      if (!file.attachment) {
        sources.add(JobSource(file.path, file.name, folder: file.folder));
        continue;
      }
      final path = store.pathOfRelative(file.path);
      if (path != null) {
        sources.add(JobSource(path, file.name));
        continue;
      }
      // Хранилище в памяти: копия во временной папке задачи.
      final bytes = store.bytesOfRelative(file.path);
      if (bytes == null) {
        _fail(chatId, card, JobCodes.missing);
        return;
      }
      // Имя вложения — только как имя файла: `../` и разделители не
      // выведут копию из временной папки задачи.
      final inbox = p.join(temp, 'in', '${sources.length}');
      final copy = p.join(inbox, JobPlacement.fileName(file.name));
      if (!p.isWithin(inbox, copy)) {
        _fail(chatId, card, JobCodes.missing);
        return;
      }
      try {
        await Directory(p.dirname(copy)).create(recursive: true);
        await File(copy).writeAsBytes(bytes);
      } on Object {
        _fail(chatId, card, JobCodes.disk);
        return;
      }
      sources.add(JobSource(copy, file.name));
    }
    var outputDir = JobPlacement.outputDir(
      files: files,
      platform: platform,
      sessionOut: store.outputDir(chatId, card.id),
      tempOut: p.join(temp, 'out'),
    );
    final fromDisk = files.every((JobFile f) => !f.attachment);
    if (card.extensionId == ExtensionForms.converter) {
      final request = await _convertRequest(
        card,
        sources.single,
        outputDir,
        macSave: platform == JobPlatform.macos && fromDisk,
      );
      if (request == null) return;
      try {
        await Directory(request.outputDir).create(recursive: true);
      } on Object {
        _fail(chatId, card, JobCodes.disk);
        return;
      }
      _start(chatId, card, request, files);
      return;
    }
    final action = card.choice('action') ?? ExtensionForms.zip;
    String? target;
    if (platform == JobPlatform.macos && fromDisk && action != 'list') {
      // Песочница macOS: писать рядом с исходником можно только туда, что
      // выбрал пользователь.
      if (action == ExtensionForms.zip) {
        final name = files.length == 1
            ? '${JobPlacement.safeName(files.single.folder ? files.single.name : p.basenameWithoutExtension(files.single.name))}.zip'
            : 'Архив.zip';
        target = await picker.saveFile(name, outputDir);
        if (target == null) return;
      } else {
        final chosen = await picker.chooseFolder(outputDir);
        if (chosen == null) return;
        outputDir = chosen;
      }
    }
    try {
      await Directory(outputDir).create(recursive: true);
    } on Object {
      _fail(chatId, card, JobCodes.disk);
      return;
    }
    final mobile =
        platform == JobPlatform.android || platform == JobPlatform.ios;
    final request = ZipOps.plan(
      cardId: card.id,
      action: action,
      sources: sources,
      outputDir: outputDir,
      limits: mobile ? ZipLimits.mobile : ZipLimits.desktop,
      explicitTarget: target,
    );
    _start(chatId, card, request, files);
  }

  /// Загрузка по ссылке: в папку загрузок, промежуточные файлы — в
  /// скрытой временной папке рядом (её убирает отмена и перезапуск).
  /// Ссылка идёт только в задачу.
  Future<void> _runYtdl(String chatId, ExtensionCard card) async {
    final url = card.values['url'];
    final format = card.choice('format');
    if (url is! String || format == null) return;
    String? dir;
    try {
      dir = await downloadsDir?.call();
    } on Object {
      dir = null;
    }
    if (dir == null) {
      _fail(chatId, card, JobCodes.disk);
      return;
    }
    final request = JobRequest(
      cardId: card.id,
      extensionId: ExtensionForms.ytdl,
      action: format,
      sources: const <JobSource>[],
      outputDir: dir,
      temp: JobPlacement.downloadTemp(dir, card.id),
      url: url.trim(),
    );
    _start(chatId, card, request, const <JobFile>[]);
  }

  void _start(
    String chatId,
    ExtensionCard card,
    JobRequest request,
    List<JobFile> files,
  ) {
    hub.start(
      chatId,
      card,
      request,
      onFinished: (ExtensionCard done) {
        // Копии от выбора файлов нужны «Повторить» после ошибки или
        // отмены; после успеха — нет. Оставшиеся уберёт уборка при
        // запуске.
        if (done.state == CardState.done) _dropPickerCopies(files);
        onFinished?.call(chatId, done);
      },
    );
  }

  /// Задача конвертера; на macOS место результата выбирает пользователь
  /// (песочница), отказался — `null`.
  Future<JobRequest?> _convertRequest(
    ExtensionCard card,
    JobSource source,
    String outputDir, {
    required bool macSave,
  }) async {
    final target = card.choice('target')!;
    String? explicit;
    if (macSave) {
      final name = '${JobPlacement.safeName(
        p.basenameWithoutExtension(source.name),
        fallback: 'Файл',
      )}.${ConvertTargets.outputExtension(target)}';
      explicit = await picker.saveFile(name, outputDir);
      if (explicit == null) return null;
    }
    return ConvertOps.plan(
      cardId: card.id,
      target: target,
      source: source,
      outputDir: outputDir,
      explicitTarget: explicit,
    );
  }

  void _fail(String chatId, ExtensionCard card, String code) {
    card
      ..state = CardState.failed
      ..errorCode = code;
    hub.edited(chatId, card);
  }

  /// Копии, которые выбор файлов на Android кладёт во временную папку
  /// приложения, после задачи не нужны.
  void _dropPickerCopies(List<JobFile> files) {
    if (platform != JobPlatform.android) return;
    unawaited(() async {
      final root = p.canonicalize(await tempRoot());
      for (final file in files) {
        if (file.attachment || file.folder) continue;
        final path = p.canonicalize(file.path);
        if (!p.isWithin(root, path)) continue;
        if (p.isWithin(p.join(root, tempFolder), path)) continue;
        IsolateJobRunner.removeQuietly(path);
      }
    }());
  }
}
