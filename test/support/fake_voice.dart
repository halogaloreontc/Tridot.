import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/voice/voice_model.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

/// Распознаватель для тестов: события подаются руками через [emit].
final class FakeVoiceRecognizer implements VoiceRecognizer {
  FakeVoiceRecognizer({
    this.support = VoiceSupport.supported,
    this.permission = VoicePermission.granted,
  });

  @override
  VoiceSupport support;

  VoicePermission permission;

  /// Ошибка [load], если задана.
  Object? loadError;

  /// Что вернёт [stop] в [VoiceFinal].
  String finalText = '';

  /// Если задан — [load] ждёт его (долгая загрузка модели на телефоне).
  Completer<void>? loadGate;

  /// Если задан — [ensurePermission] ждёт его (системный диалог).
  Completer<void>? permissionGate;

  int permissionCalls = 0;
  int loadCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int unloadCalls = 0;
  int disposeCalls = 0;
  String? loadedPath;

  StreamController<VoiceEvent>? _events;

  bool get isListening => _events != null;

  @override
  Future<VoicePermission> ensurePermission() async {
    permissionCalls++;
    final gate = permissionGate;
    if (gate != null) await gate.future;
    return permission;
  }

  @override
  Future<void> load(String modelDir) async {
    // Как настоящий: уже загруженную модель не загружает снова.
    if (loadedPath == modelDir) return;
    loadCalls++;
    final gate = loadGate;
    if (gate != null) await gate.future;
    final error = loadError;
    if (error != null) throw error;
    loadedPath = modelDir;
  }

  @override
  Stream<VoiceEvent> start() {
    startCalls++;
    // Как настоящий: новое начало закрывает прежний поток.
    final previous = _events;
    if (previous != null) unawaited(previous.close());
    final controller = StreamController<VoiceEvent>();
    _events = controller;
    return controller.stream;
  }

  /// Подаёт событие в текущий поток [start].
  void emit(VoiceEvent event) => _events?.add(event);

  @override
  Future<void> stop() async {
    stopCalls++;
    final controller = _events;
    _events = null;
    if (controller == null) return;
    controller.add(VoiceFinal(finalText));
    await controller.close();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final controller = _events;
    _events = null;
    await controller?.close();
  }

  @override
  Future<void> unload() async {
    unloadCalls++;
    loadedPath = null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await cancel();
  }
}

/// Загрузчик для тестов: пишет [bytes] в `.part` по [steps] кусков; между
/// кусками ждёт [gate], если он задан. Учитывает уже скачанное (продолжение)
/// и отмену.
final class FakeFileDownloader implements FileDownloader {
  FakeFileDownloader(this.bytes, {this.steps = 4});

  List<int> bytes;
  final int steps;

  /// Ошибка вместо загрузки, если задана.
  DownloadError? failWith;

  /// После скольких кусков упасть с [DownloadError.network] (обрыв).
  int? dropAfter;

  /// Ход загрузки, который сообщается до первого куска (например, «12 из
  /// 44 МБ» для экрана), — без записи в файл.
  List<DownloadProgress> preamble = const <DownloadProgress>[];

  /// С какого куска (по счёту в этом вызове) действует [gate]: 1 — первый
  /// кусок пишется сразу, следующие ждут.
  int gateFrom = 0;

  /// Если задан — каждый кусок ждёт его завершения.
  Completer<void>? gate;

  int calls = 0;

  /// Сколько байт уже было в `.part` при последнем вызове.
  int lastOffset = 0;

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    calls++;
    final error = failWith;
    if (error != null) throw DownloadException(error);
    await partFile.parent.create(recursive: true);
    var offset = await partFile.exists() ? await partFile.length() : 0;
    lastOffset = offset;
    yield DownloadProgress(offset, expectedBytes);
    for (final step in preamble) {
      yield step;
    }
    final chunk = (bytes.length / steps).ceil();
    var written = 0;
    while (offset < bytes.length) {
      final pending = written >= gateFrom ? gate : null;
      // Отмена будит ожидание, как закрытие запроса у настоящего.
      if (pending != null) {
        await Future.any(<Future<void>>[pending.future, cancel.whenCancelled]);
      }
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      final end = (offset + chunk).clamp(0, bytes.length);
      await partFile.writeAsBytes(
        bytes.sublist(offset, end),
        mode: FileMode.append,
        flush: true,
      );
      offset = end;
      written++;
      yield DownloadProgress(offset, expectedBytes);
      if (dropAfter != null && written >= dropAfter! && offset < bytes.length) {
        throw const DownloadException(DownloadError.network);
      }
    }
  }
}

/// Модель для тестов экранов: архив — просто [bytes], сумма — от них (или
/// заведомо неверная [sha]).
VoiceModelSpec fakeVoiceSpec(List<int> bytes, {String? sha}) => VoiceModelSpec(
      url: 'https://example.invalid/test-model.zip',
      sha256: sha ?? crypto.sha256.convert(bytes).toString(),
      bytes: bytes.length,
      folderName: 'test-model',
    );

/// [VoiceKit] для тестов экранов: сумма считается без изоляты, а
/// «распаковка» просто создаёт обязательные файлы модели.
VoiceKit fakeVoiceKit({
  required FakeVoiceRecognizer recognizer,
  required FakeFileDownloader downloader,
  required VoiceModelSpec spec,
  required String dir,
}) =>
    VoiceKit(
      recognizer: recognizer,
      downloader: downloader,
      spec: spec,
      dir: dir,
      hasher: (File file) async =>
          crypto.sha256.convert(await file.readAsBytes()).toString(),
      extractor: (
        File zip,
        Directory dest, {
        required ZipLimits limits,
        String? stripRoot,
      }) async {
        for (final name in spec.requiredFiles) {
          final file = File(p.join(dest.path, name));
          await file.parent.create(recursive: true);
          await file.writeAsString('тест');
        }
      },
    );

/// Кладёт установленную модель на диск синхронно (до pumpWidget).
void installFakeModelSync(String dir, VoiceModelSpec spec) {
  final model = p.join(dir, spec.folderName);
  for (final name in spec.requiredFiles) {
    File(p.join(model, name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('тест');
  }
  File(p.join(model, 'installed.json')).writeAsStringSync(
    '{"version":"${spec.folderName}","sha256":"${spec.sha256}"}',
  );
}

/// Ждёт [done], давая настоящему вводу-выводу (файлы [VoiceKit]) идти между
/// кадрами тестового времени.
Future<void> pumpUntilVoice(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    // Время кадра идёт: листы и диалоги успевают выехать.
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: 'состояние голосового ввода не наступило');
}
