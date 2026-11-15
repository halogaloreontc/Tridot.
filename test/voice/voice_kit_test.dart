import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/settings/app_settings.dart'
    show VoiceEngineChoice;
import 'package:local_assistant/core/voice/voice_model.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import '../support/fake_voice.dart';

const String _folder = 'test-model-1';

List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(ArchiveFile.string(key, value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _goodModel() => _zip(<String, String>{
      '$_folder/am/final.mdl': 'модель',
      '$_folder/conf/model.conf': '--sample-frequency=16000',
      '$_folder/README': 'тест',
    });

VoiceModelSpec _spec(List<int> bytes, {String? sha}) => VoiceModelSpec(
      url: 'https://example.invalid/model.zip',
      sha256: sha ?? crypto.sha256.convert(bytes).toString(),
      bytes: bytes.length,
      folderName: _folder,
    );

void main() {
  late Directory temp;
  late String dir;
  late FakeVoiceRecognizer recognizer;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('voice_kit_test');
    dir = p.join(temp.path, 'assistant', 'voice');
    recognizer = FakeVoiceRecognizer();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  VoiceKit kit(FakeFileDownloader downloader, VoiceModelSpec spec) => VoiceKit(
        recognizer: recognizer,
        downloader: downloader,
        spec: spec,
        dir: dir,
      );

  List<String> leftovers() => Directory(dir).existsSync()
      ? (Directory(dir).listSync().map((e) => p.basename(e.path)).toList()
        ..sort())
      : <String>[];

  test('скачивание, проверка и распаковка: модель установлена', () async {
    final bytes = _goodModel();
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    final phases = <VoiceKitPhase>[];
    voice.addListener(() {
      if (phases.isEmpty || phases.last != voice.phase) phases.add(voice.phase);
    });
    await voice.refresh();
    expect(voice.phase, VoiceKitPhase.notInstalled);
    await voice.install();
    expect(voice.phase, VoiceKitPhase.installed);
    expect(phases, <VoiceKitPhase>[
      VoiceKitPhase.notInstalled,
      VoiceKitPhase.downloading,
      VoiceKitPhase.verifying,
      VoiceKitPhase.installing,
      VoiceKitPhase.installed,
    ]);
    expect(voice.received, bytes.length);
    expect(
      File(p.join(dir, _folder, 'installed.json')).existsSync(),
      isTrue,
    );
    expect(File(p.join(dir, _folder, 'am', 'final.mdl')).existsSync(), isTrue);
    // Архив и временные папки удалены, осталась только модель.
    expect(leftovers(), <String>[_folder]);
    expect(voice.installedBytes, greaterThan(0));
    expect(voice.hasPartial, isFalse);
  });

  test('контрольная сумма не совпала: ошибка, архив удалён', () async {
    final bytes = _goodModel();
    final voice = kit(
      FakeFileDownloader(bytes),
      _spec(bytes, sha: 'ab' * 32),
    );
    await voice.install();
    expect(voice.phase, VoiceKitPhase.error);
    expect(voice.error, VoiceKitError.checksum);
    expect(voice.error!.message, contains('контрольная сумма'));
    expect(leftovers(), isEmpty);
    expect(voice.hasPartial, isFalse);
  });

  test('отмена сохраняет скачанное, следующая загрузка продолжает', () async {
    final bytes = _goodModel();
    final spec = _spec(bytes);
    // Первый кусок проходит сразу, следующие ждут — затем отмена.
    final downloader = FakeFileDownloader(bytes, steps: 4)
      ..gate = Completer<void>()
      ..gateFrom = 1;
    final voice = kit(downloader, spec);
    final first = voice.install();
    await pumpUntil(() => voice.received > 0);
    voice.cancel();
    await first;
    expect(voice.phase, VoiceKitPhase.notInstalled);
    expect(voice.hasPartial, isTrue);
    final partial = File(p.join(dir, '$_folder.zip.part'));
    expect(partial.existsSync(), isTrue);
    final kept = partial.lengthSync();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(bytes.length));

    // После «перезапуска» состояние видно с диска.
    final again = kit(FakeFileDownloader(bytes), spec);
    await again.refresh();
    expect(again.phase, VoiceKitPhase.notInstalled);
    expect(again.hasPartial, isTrue);
    await again.install();
    expect(again.phase, VoiceKitPhase.installed);
    expect(
      (again.downloader as FakeFileDownloader).lastOffset,
      kept,
    );
  });

  test('обрыв связи: ошибка сети, скачанное остаётся', () async {
    final bytes = _goodModel();
    final spec = _spec(bytes);
    final voice = kit(FakeFileDownloader(bytes)..dropAfter = 1, spec);
    await voice.install();
    expect(voice.phase, VoiceKitPhase.error);
    expect(voice.error, VoiceKitError.network);
    expect(voice.error!.message, contains('с места остановки'));
    expect(voice.hasPartial, isTrue);
    (voice.downloader as FakeFileDownloader).dropAfter = null;
    await voice.install();
    expect(voice.phase, VoiceKitPhase.installed);
  });

  test('сервер отдаёт больше: ошибка, недокачанное удалено', () async {
    final bytes = _goodModel();
    final voice = kit(
      FakeFileDownloader(bytes)..failWith = DownloadError.tooLarge,
      _spec(bytes),
    );
    await voice.install();
    expect(voice.error, VoiceKitError.tooLarge);
    expect(leftovers(), isEmpty);
  });

  test('в архиве нет нужного файла: ни папки модели, ни отметки', () async {
    final bytes = _zip(<String, String>{
      '$_folder/am/final.mdl': 'модель',
    });
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await voice.install();
    expect(voice.phase, VoiceKitPhase.error);
    expect(voice.error, VoiceKitError.extract);
    expect(leftovers(), isEmpty);
  });

  test('нет места при распаковке: «storage», проверенный архив сохранён',
      () async {
    final bytes = _goodModel();
    final spec = _spec(bytes);
    final downloader = FakeFileDownloader(bytes);
    var full = true;
    final voice = VoiceKit(
      recognizer: recognizer,
      downloader: downloader,
      spec: spec,
      dir: dir,
      extractor: (zip, dest, {required limits, stripRoot}) {
        if (full) {
          throw const FileSystemException(
            'No space left on device',
            '',
            OSError('No space left on device', 28),
          );
        }
        return extractZipSafely(
          zip,
          dest,
          limits: limits,
          stripRoot: stripRoot,
        );
      },
    );
    await voice.install();
    expect(voice.phase, VoiceKitPhase.error);
    expect(voice.error, VoiceKitError.storage);
    expect(voice.error!.message, contains('свободное место'));
    expect(voice.hasPartial, isTrue);
    expect(File(p.join(dir, '$_folder.zip')).existsSync(), isTrue);
    expect(downloader.calls, 1);

    // Место освободили: «Повторить» не скачивает архив заново.
    full = false;
    await voice.install();
    expect(voice.phase, VoiceKitPhase.installed);
    expect(downloader.lastOffset, bytes.length);
    expect(leftovers(), <String>[_folder]);
  });

  test('ошибка диска при загрузке: «storage», скачанное остаётся', () async {
    final bytes = _goodModel();
    final voice = kit(
      FakeFileDownloader(bytes)..failWith = DownloadError.storage,
      _spec(bytes),
    );
    await voice.install();
    expect(voice.phase, VoiceKitPhase.error);
    expect(voice.error, VoiceKitError.storage);
  });

  test('опасный путь в архиве: распаковка отклонена', () async {
    final bytes = _zip(<String, String>{
      '$_folder/am/final.mdl': 'модель',
      '$_folder/conf/model.conf': 'x',
      '$_folder/../evil.txt': 'x',
    });
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await voice.install();
    expect(voice.error, VoiceKitError.extract);
    expect(leftovers(), isEmpty);
    expect(File(p.join(dir, 'evil.txt')).existsSync(), isFalse);
  });

  test('«Удалить модель» освобождает место и выгружает модель', () async {
    final bytes = _goodModel();
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await voice.install();
    await voice.ensureLoaded();
    await voice.delete();
    expect(voice.phase, VoiceKitPhase.notInstalled);
    expect(voice.installedBytes, 0);
    expect(recognizer.unloadCalls, 1);
    expect(leftovers(), isEmpty);
    // Снова загрузить модель можно только после установки.
    await expectLater(
      voice.ensureLoaded(),
      throwsA(isA<VoiceEngineException>()),
    );
  });

  test('после перезапуска модель видна установленной', () async {
    final bytes = _goodModel();
    final spec = _spec(bytes);
    await kit(FakeFileDownloader(bytes), spec).install();
    final again = kit(FakeFileDownloader(bytes), spec);
    await again.refresh();
    expect(again.phase, VoiceKitPhase.installed);
    expect(again.installedBytes, greaterThan(0));
  });

  test('отметка от другой версии модели не считается установкой', () async {
    final bytes = _goodModel();
    final spec = _spec(bytes);
    await kit(FakeFileDownloader(bytes), spec).install();
    final other = kit(FakeFileDownloader(bytes), _spec(bytes, sha: 'cd' * 32));
    await other.refresh();
    expect(other.phase, VoiceKitPhase.notInstalled);
  });

  test('модель загружается в распознаватель один раз', () async {
    final bytes = _goodModel();
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await expectLater(
      voice.ensureLoaded(),
      throwsA(isA<VoiceEngineException>()),
    );
    await voice.install();
    await Future.wait(<Future<void>>[
      voice.ensureLoaded(),
      voice.ensureLoaded(),
    ]);
    await voice.ensureLoaded();
    expect(recognizer.loadCalls, 1);
    expect(recognizer.loadedPath, p.join(dir, _folder));
  });

  test('ошибка загрузки модели — VoiceEngineException', () async {
    final bytes = _goodModel();
    recognizer.loadError = StateError('сбой');
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await voice.install();
    await expectLater(
      voice.ensureLoaded(),
      throwsA(
        isA<VoiceEngineException>().having(
          (e) => e.code,
          'code',
          VoiceErrorCode.modelLoad,
        ),
      ),
    );
  });

  test('старые временные папки удаляются при установке', () async {
    final bytes = _goodModel();
    await Directory(p.join(dir, 'tmp-1', 'am')).create(recursive: true);
    final voice = kit(FakeFileDownloader(bytes), _spec(bytes));
    await voice.install();
    expect(leftovers(), <String>[_folder]);
  });

  test('повторный install во время установки — та же установка', () async {
    final bytes = _goodModel();
    final downloader = FakeFileDownloader(bytes);
    final voice = kit(downloader, _spec(bytes));
    await Future.wait(<Future<void>>[voice.install(), voice.install()]);
    expect(downloader.calls, 1);
    expect(voice.phase, VoiceKitPhase.installed);
  });

  group('распознавание телефона', () {
    VoiceKit deviceKit(FakeDeviceRecognizer device) {
      final bytes = _goodModel();
      return VoiceKit(
        recognizer: recognizer,
        device: device,
        downloader: FakeFileDownloader(bytes),
        spec: _spec(bytes),
        dir: dir,
      );
    }

    test('«авто» и русский установлен — телефон, без модели', () async {
      final device = FakeDeviceRecognizer();
      final voice = deviceKit(device);
      await voice.refreshDevice();
      expect(voice.deviceStatus, DeviceVoiceStatus.ready);
      expect(voice.engine, VoiceEngine.device);
      expect(voice.isInstalled, isFalse);
      expect(voice.isReady, isTrue);
      expect(identical(voice.active, device), isTrue);
      await voice.ensureLoaded();
      expect(recognizer.loadCalls, 0);
    });

    test('Android 12: «unknown» тоже пробуем', () async {
      final voice = deviceKit(
        FakeDeviceRecognizer(status: DeviceVoiceStatus.unknown),
      );
      await voice.refreshDevice();
      expect(voice.engine, VoiceEngine.device);
      expect(voice.isReady, isTrue);
    });

    for (final status in <DeviceVoiceStatus>[
      DeviceVoiceStatus.unavailable,
      DeviceVoiceStatus.unsupported,
      DeviceVoiceStatus.notInstalled,
    ]) {
      test('«авто» и ${status.name} — Vosk', () async {
        final voice = deviceKit(FakeDeviceRecognizer(status: status));
        await voice.refreshDevice();
        expect(voice.engine, VoiceEngine.vosk);
        expect(identical(voice.active, recognizer), isTrue);
        expect(voice.isReady, isFalse);
      });
    }

    test('выбран Vosk — Vosk, даже если телефон готов', () async {
      final voice = deviceKit(FakeDeviceRecognizer())
        ..choice = VoiceEngineChoice.vosk;
      await voice.refreshDevice();
      expect(voice.engine, VoiceEngine.vosk);
    });

    test(
        'выбран телефон, язык не скачан: без модели — телефон, с моделью '
        '— Vosk', () async {
      final voice = deviceKit(
        FakeDeviceRecognizer(status: DeviceVoiceStatus.notInstalled),
      )..choice = VoiceEngineChoice.device;
      await voice.refreshDevice();
      expect(voice.engine, VoiceEngine.device);
      expect(voice.isReady, isFalse);
      await voice.install();
      expect(voice.isInstalled, isTrue);
      expect(voice.engine, VoiceEngine.vosk);
      expect(voice.isReady, isTrue);
    });

    test('ошибки 12 и 13 понижают статус', () async {
      final voice = deviceKit(FakeDeviceRecognizer());
      await voice.refreshDevice();
      voice.reportDeviceError(VoiceErrorCode.languageUnavailable);
      expect(voice.deviceStatus, DeviceVoiceStatus.notInstalled);
      voice.reportDeviceError(VoiceErrorCode.languageUnsupported);
      expect(voice.deviceStatus, DeviceVoiceStatus.unsupported);
      expect(voice.engine, VoiceEngine.vosk);
      voice.reportDeviceError(VoiceErrorCode.engine);
      expect(voice.deviceStatus, DeviceVoiceStatus.unsupported);
    });

    test('загрузка языка: проценты, затем готово', () async {
      final device = FakeDeviceRecognizer(
        status: DeviceVoiceStatus.notInstalled,
      )..downloadScript = const <DeviceLanguageDownload>[
          DeviceDownloadProgress(10),
          DeviceDownloadProgress(40),
          DeviceDownloadSuccess(),
        ];
      final voice = deviceKit(device);
      await voice.refreshDevice();
      final percents = <int?>[];
      voice.addListener(() => percents.add(voice.deviceDownloadPercent));
      final outcome = await voice.downloadDeviceLanguage();
      expect(outcome, isA<DeviceDownloadSuccess>());
      expect(percents, containsAllInOrder(<int?>[10, 40]));
      expect(voice.deviceStatus, DeviceVoiceStatus.ready);
      expect(voice.deviceDownloadPercent, isNull);
      expect(voice.isDeviceDownloading, isFalse);
      expect(voice.engine, VoiceEngine.device);
    });

    test('загрузка отложена системой — pending', () async {
      final device = FakeDeviceRecognizer(
        status: DeviceVoiceStatus.notInstalled,
      )..downloadScript = const <DeviceLanguageDownload>[
          DeviceDownloadScheduled(),
        ];
      final voice = deviceKit(device);
      await voice.refreshDevice();
      final outcome = await voice.downloadDeviceLanguage();
      expect(outcome, isA<DeviceDownloadScheduled>());
      expect(voice.deviceStatus, DeviceVoiceStatus.pending);
    });

    test('голосовой ввод есть, даже если Vosk не поддерживается', () async {
      recognizer.support = VoiceSupport.unsupported;
      final voice = deviceKit(FakeDeviceRecognizer());
      expect(voice.support, VoiceSupport.unsupported);
      await voice.refreshDevice();
      expect(voice.support, VoiceSupport.supported);
    });

    test('«Удалить модель» по-прежнему выгружает Vosk', () async {
      final voice = deviceKit(FakeDeviceRecognizer())
        ..choice = VoiceEngineChoice.vosk;
      await voice.install();
      await voice.ensureLoaded();
      await voice.delete();
      expect(recognizer.unloadCalls, 1);
      expect(voice.isInstalled, isFalse);
    });
  });
}

/// Ждёт условия, отдавая управление циклу событий.
Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 2000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}
