import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/intent/intent_kit.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/intent/intent_memory.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:path/path.dart' as p;

import '../support/fake_voice.dart';
import 'intent_kit_fakes.dart';

void main() {
  late Directory temp;
  late String root;
  late FakeIntentHost host;
  late FakeReleaseTransport transport;
  late FakeFileDownloader downloader;
  late IntentKit kit;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('intent_kit_test');
    root = p.join(temp.path, 'assistant', 'intent');
    host = FakeIntentHost();
    transport = FakeReleaseTransport();
    downloader = FakeFileDownloader(const <int>[]);
    kit = fakeIntentKit(
      host: host,
      transport: transport,
      downloader: downloader,
      root: root,
    );
  });

  tearDown(() async {
    kit.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  List<String> entries() => Directory(root).existsSync()
      ? (Directory(root).listSync().map((e) => p.basename(e.path)).toList()
        ..sort())
      : <String>[];

  /// Выпуск [version] с архивами уровней; загрузчик отдаёт архив [serve].
  List<int> publish(
    String version, {
    String serve = 'light',
    String? sha,
    String? corrupt,
    String? manifestTier,
  }) {
    final zips = <String, List<int>>{
      'light': fakePackZip(
        version: version,
        corrupt: serve == 'light' ? corrupt : null,
        manifestTier: serve == 'light' ? manifestTier : null,
      ),
      'accurate': fakePackZip(
        tier: 'accurate',
        version: version,
        corrupt: serve == 'accurate' ? corrupt : null,
      ),
    };
    transport.latest(fakeLatestJson(version, zips, sha: sha));
    downloader.bytes = zips[serve]!;
    return zips[serve]!;
  }

  test('скачивание: latest.json, архив, проверка, указатель, модель', () async {
    publish('1.0.0');
    await kit.refresh();
    expect(kit.installed, isNull);
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    expect(host.loads, isEmpty, reason: 'модели ещё нет');
    final phases = <IntentKitPhase>[];
    kit.addListener(() {
      if (phases.isEmpty || phases.last != kit.phase) phases.add(kit.phase);
    });
    await kit.install(IntentTier.light);
    expect(kit.phase, IntentKitPhase.idle);
    expect(phases, <IntentKitPhase>[
      IntentKitPhase.checking,
      IntentKitPhase.downloading,
      IntentKitPhase.verifying,
      IntentKitPhase.installing,
      IntentKitPhase.idle,
    ]);
    expect(kit.installed?.tier, IntentTier.light);
    expect(kit.installed?.version, '1.0.0');
    expect(entries(), <String>['active.json', 'light-1.0.0']);
    final pointer = jsonDecode(
      File(p.join(root, 'active.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(pointer['dir'], 'light-1.0.0');
    expect(host.loads, <String>[p.join(root, 'light-1.0.0')]);
    expect(kit.running, isTrue);
    // Адрес архива — из latest.json, через переадресацию GitHub.
    expect(transport.requests.first, IntentRelease.latestUrl);

    // После перезапуска — то же по диску.
    final again = fakeIntentKit(
      host: FakeIntentHost(),
      transport: transport,
      downloader: downloader,
      root: root,
    );
    addTearDown(again.dispose);
    await again.refresh();
    expect(again.installed?.tier, IntentTier.light);
    expect(again.installed?.version, '1.0.0');
  });

  test('sha256 архива не совпала — ошибка, ничего не установлено', () async {
    publish('1.0.0', sha: 'a' * 64);
    await kit.install(IntentTier.light);
    expect(kit.phase, IntentKitPhase.error);
    expect(kit.error, IntentKitError.checksum);
    expect(kit.installed, isNull);
    expect(kit.hasPartial, isFalse);
    expect(entries(), isEmpty);
    expect(host.loads, isEmpty);
  });

  test('файл пакета не совпал с манифестом — архив отвергнут', () async {
    publish('1.0.0', corrupt: 'model.int8.onnx');
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.extract);
    expect(kit.installed, isNull);
    expect(entries(), isEmpty);
  });

  test('в архиве другой уровень — архив отвергнут', () async {
    publish('1.0.0', manifestTier: 'accurate');
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.extract);
    expect(kit.installed, isNull);
  });

  test('чужой адрес в latest.json не скачивается', () async {
    transport.latest(
      jsonEncode(<String, Object?>{
        'format': IntentRelease.format,
        'version': '1.0.0',
        'tiers': <String, Object?>{
          'light': <String, Object?>{
            'url': 'https://example.com/tridot-intent-light-1.0.0.zip',
            'size': 10,
            'sha256': 'a' * 64,
          },
        },
      }),
    );
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.release);
    expect(downloader.calls, 0);
  });

  test('нет сети при чтении latest.json — «проверьте интернет»', () async {
    transport.offline = true;
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.network);
    expect(downloader.calls, 0);
  });

  test('выпуска нет (404) — «недоступна»', () async {
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.release);
  });

  test('обрыв — продолжение с места остановки', () async {
    final bytes = publish('1.0.0');
    downloader.dropAfter = 2;
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.network);
    expect(kit.hasPartial, isTrue);
    downloader.dropAfter = null;
    await kit.install(IntentTier.light);
    expect(downloader.lastOffset, greaterThan(0));
    expect(downloader.lastOffset, lessThan(bytes.length));
    expect(kit.installed?.version, '1.0.0');
  });

  test('отмена: скачанное сохраняется, ошибки нет', () async {
    publish('1.0.0');
    final gate = Completer<void>();
    downloader
      ..gate = gate
      ..gateFrom = 1;
    final install = kit.install(IntentTier.light);
    while (kit.received == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    kit.cancel();
    await install;
    expect(kit.phase, IntentKitPhase.idle);
    expect(kit.hasPartial, isTrue);
    expect(kit.installed, isNull);
  });

  test('смена уровня: новая модель загружена, прежняя удалена', () async {
    publish('1.0.0');
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    await kit.install(IntentTier.light);
    expect(host.loads, <String>[p.join(root, 'light-1.0.0')]);

    publish('1.0.0', serve: 'accurate');
    await kit.apply(const AppSettings(intentTier: IntentTier.accurate));
    // Пока «Точная» не скачана, работает «Лёгкая».
    expect(host.loads, hasLength(1));
    expect(kit.running, isTrue);
    await kit.install(IntentTier.accurate);
    expect(kit.installed?.tier, IntentTier.accurate);
    expect(host.loads.last, p.join(root, 'accurate-1.0.0'));
    expect(entries(), <String>['accurate-1.0.0', 'active.json']);

    await kit.apply(const AppSettings());
    expect(host.unloads, 1);
    expect(kit.running, isFalse);
    expect(entries(), contains('accurate-1.0.0'), reason: 'файлы остаются');
    await kit.apply(const AppSettings(intentTier: IntentTier.accurate));
    expect(host.loads.last, p.join(root, 'accurate-1.0.0'));
    expect(kit.running, isTrue);
  });

  test('обновление: проверка по кнопке, новая версия, старая удалена',
      () async {
    publish('1.0.0');
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    await kit.install(IntentTier.light);
    final requests = transport.requests.length;

    await kit.checkUpdate();
    expect(transport.requests.length, greaterThan(requests));
    expect(kit.updateAvailable, isFalse);
    expect(kit.checked, isTrue);

    final next = publish('1.1.0');
    await kit.checkUpdate();
    expect(kit.updateAvailable, isTrue);
    expect(kit.bytesOf(IntentTier.light), next.length);
    await kit.install(IntentTier.light);
    expect(kit.installed?.version, '1.1.0');
    expect(kit.updateAvailable, isFalse);
    expect(host.loads.last, p.join(root, 'light-1.1.0'));
    expect(entries(), <String>['active.json', 'light-1.1.0']);
  });

  test('сеть — только по действию: refresh и apply ничего не скачивают',
      () async {
    publish('1.0.0');
    await kit.refresh();
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    expect(transport.requests, isEmpty);
    expect(downloader.calls, 0);
  });

  test('модель не запустилась — признак для настроек', () async {
    publish('1.0.0');
    host.loadResult = false;
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    await kit.install(IntentTier.light);
    expect(kit.installed, isNotNull);
    expect(kit.loadFailed, isTrue);
    expect(kit.running, isFalse);
  });

  test('«Удалить модель»: выгружена, файлов нет, память цела', () async {
    publish('1.0.0');
    await kit.apply(const AppSettings(intentTier: IntentTier.light));
    await kit.install(IntentTier.light);
    await kit.memory.note('синтетическая фраза', UnclearKind.unknown);
    await kit.delete();
    expect(host.unloads, 1);
    expect(kit.installed, isNull);
    expect(entries(), isEmpty);
    expect(kit.memory.unclear, hasLength(1));
  });

  test('переключатели настроек — в память', () async {
    await kit.apply(
      const AppSettings(intentLearning: false, intentLogging: false),
    );
    expect(kit.memory.learning, isFalse);
    expect(kit.memory.logging, isFalse);
    await kit.memory.note('синтетическая фраза', UnclearKind.unknown);
    expect(kit.memory.unclear, isEmpty);
    await kit.apply(const AppSettings());
    expect(kit.memory.learning, isTrue);
    expect(kit.memory.logging, isTrue);
  });

  test('«Забыть выученное» и журнал', () async {
    await kit.memory.remember('синтетическая фраза', 'tasks:task.create');
    await kit.memory.reject('другая фраза', <String>['calc:calc.evaluate']);
    expect(kit.memory.learnedCount, 2);
    var notified = 0;
    kit.addListener(() => notified++);
    await kit.forgetLearned();
    expect(kit.memory.learnedCount, 0);
    expect(notified, greaterThan(0));

    await kit.memory.note('первая', UnclearKind.unknown);
    await kit.memory.note('вторая', UnclearKind.rejected);
    final first = kit.memory.unclear.last;
    await kit.removeUnclear(first);
    expect(kit.memory.unclear.map((e) => e.text), <String>['вторая']);
    await kit.clearUnclear();
    expect(kit.memory.unclear, isEmpty);
  });

  test('папка разработки загружается при любом уровне', () async {
    host.devPack = '/dev/pack';
    await kit.apply(const AppSettings());
    expect(host.loads, <String>['/dev/pack']);
    expect(kit.running, isTrue);
  });

  test('больше ожидаемого — архив удалён', () async {
    publish('1.0.0');
    downloader.failWith = DownloadError.tooLarge;
    await kit.install(IntentTier.light);
    expect(kit.error, IntentKitError.tooLarge);
    expect(kit.hasPartial, isFalse);
  });
}
