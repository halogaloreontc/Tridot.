// ToolKit (ADR-024, шаг 2): установка ffmpeg по кнопке — загрузка,
// SHA-256 архива, распаковка одной программы, права на запуск,
// installed.json; отмена оставляет скачанное; удаление; программа
// подменена после установки — удаляется и не запускается.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';
import 'package:path/path.dart' as p;

final List<int> _archive = utf8.encode('архив ffmpeg');

ToolSpec _spec({String? sha}) => ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.linuxX64,
      version: 'v1',
      url: 'https://github.com/x/y/releases/download/t/ffmpeg-linux64.tar.xz',
      sha256: sha ?? crypto.sha256.convert(_archive).toString(),
      bytes: _archive.length,
      archive: ToolArchive.tarXz,
      entry: 'ff/bin/ffmpeg',
      binaryName: 'ffmpeg',
      binaryBytes: 10,
      license: 'LGPL',
      sourceUrl: 'https://github.com/x/y',
    );

final class _Downloader implements FileDownloader {
  int calls = 0;
  Completer<void>? gate;

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    calls++;
    await partFile.parent.create(recursive: true);
    partFile.writeAsBytesSync(_archive.sublist(0, 4));
    yield DownloadProgress(4, expectedBytes);
    if (gate case final Completer<void> wait) {
      await Future.any(<Future<void>>[wait.future, cancel.whenCancelled]);
    }
    if (cancel.isCancelled) {
      throw const DownloadException(DownloadError.cancelled);
    }
    partFile.writeAsBytesSync(_archive);
    yield DownloadProgress(expectedBytes, expectedBytes);
  }
}

void main() {
  late Directory temp;
  late _Downloader downloader;
  late List<String> chmods;
  late List<(String, String)> extracted;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tool_kit');
    downloader = _Downloader();
    chmods = <String>[];
    extracted = <(String, String)>[];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  ToolKit kit({ToolSpec? spec}) => ToolKit(
        spec: spec ?? _spec(),
        downloader: downloader,
        dir: p.join(temp.path, 'tools', 'ffmpeg'),
        extractor: (ToolSpec s, String archive, String dest, String tar) async {
          extracted.add((archive, tar));
          final file = File(p.join(dest, s.entry));
          await file.parent.create(recursive: true);
          await file.writeAsString('программа');
        },
        chmod: (String path) async => chmods.add(path),
      );

  test('установка: сумма, одна программа, права, installed.json', () async {
    final tool = kit();
    await tool.refresh();
    expect(tool.phase, ToolPhase.notInstalled);
    await tool.install();
    expect(tool.phase, ToolPhase.installed);
    expect(File(tool.binaryPath).readAsStringSync(), 'программа');
    expect(chmods, <String>[tool.binaryPath]);
    expect(p.basename(extracted.single.$1), 'ffmpeg-linux64.tar.xz');
    final marker = jsonDecode(
      File(p.join(tool.dir, 'v1', 'installed.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(marker['binary_sha256'], hasLength(64));
    // Архив и временные папки убраны.
    expect(
      Directory(tool.dir).listSync().map((e) => p.basename(e.path)),
      <String>['v1'],
    );
    expect(await tool.verifiedPath(), tool.binaryPath);
    // После перезапуска приложения — снова установлен.
    final again = kit();
    await again.refresh();
    expect(again.isInstalled, isTrue);
    expect(await again.verifiedPath(), again.binaryPath);
  });

  test('сумма архива не совпала — архив удалён, программы нет', () async {
    final tool = kit(spec: _spec(sha: 'a' * 64));
    await tool.install();
    expect(tool.phase, ToolPhase.error);
    expect(tool.error, ToolError.checksum);
    expect(File(tool.binaryPath).existsSync(), isFalse);
    expect(tool.hasPartial, isFalse);
    expect(extracted, isEmpty);
  });

  test('отмена — скачанное остаётся, следующая загрузка продолжит', () async {
    final tool = kit();
    downloader.gate = Completer<void>();
    final installing = tool.install();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(tool.phase, ToolPhase.downloading);
    tool.cancel();
    await installing;
    expect(tool.phase, ToolPhase.notInstalled);
    expect(tool.hasPartial, isTrue);
    downloader.gate = null;
    await tool.install();
    expect(tool.isInstalled, isTrue);
  });

  test('программу подменили после установки — удаляется, путь null', () async {
    final tool = kit();
    await tool.install();
    final restarted = kit();
    await restarted.refresh();
    File(restarted.binaryPath).writeAsStringSync('подменённая');
    expect(await restarted.verifiedPath(), isNull);
    expect(File(restarted.binaryPath).existsSync(), isFalse);
    expect(restarted.isInstalled, isFalse);
  });

  test('удаление — программы и архива нет', () async {
    final tool = kit();
    await tool.install();
    await tool.delete();
    expect(tool.phase, ToolPhase.notInstalled);
    expect(File(tool.binaryPath).existsSync(), isFalse);
    expect(await tool.verifiedPath(), isNull);
  });

  test('распаковка не удалась — ошибка, установка не засчитана', () async {
    final tool = ToolKit(
      spec: _spec(),
      downloader: downloader,
      dir: p.join(temp.path, 'tools', 'ffmpeg'),
      extractor: (ToolSpec s, String a, String d, String t) async =>
          throw ArgumentError('плохой архив'),
      chmod: (String path) async {},
    );
    await tool.install();
    expect(tool.error, ToolError.extract);
    expect(File(tool.binaryPath).existsSync(), isFalse);
  });

  group('программа без архива (yt-dlp)', () {
    ToolSpec ytdlp(String version) => ToolSpec(
          id: 'ytdlp',
          title: 'yt-dlp',
          abi: Abi.linuxX64,
          version: version,
          url: 'https://github.com/yt-dlp/yt-dlp/releases/download/'
              '$version/yt-dlp_linux',
          sha256: crypto.sha256.convert(_archive).toString(),
          bytes: _archive.length,
          archive: ToolArchive.none,
          entry: '',
          binaryName: 'yt-dlp',
          binaryBytes: _archive.length,
          license: 'Unlicense / GPLv3+',
          sourceUrl: 'https://github.com/yt-dlp/yt-dlp',
        );

    ToolKit ytKit(String version) => ToolKit(
          spec: ytdlp(version),
          downloader: downloader,
          dir: p.join(temp.path, 'tools', 'ytdlp'),
          extractor: (ToolSpec s, String a, String d, String t) async =>
              fail('распаковывать нечего'),
          chmod: (String path) async => chmods.add(path),
        );

    test('проверенный файл становится программой', () async {
      final tool = ytKit('2026.10.26');
      await tool.install();
      expect(tool.phase, ToolPhase.installed);
      expect(File(tool.binaryPath).readAsBytesSync(), _archive);
      expect(p.basename(tool.binaryPath), 'yt-dlp');
      expect(chmods, <String>[tool.binaryPath]);
      expect(
        Directory(tool.dir).listSync().map((e) => p.basename(e.path)),
        <String>['2026.10.26'],
      );
      expect(await tool.verifiedPath(), tool.binaryPath);
      expect(tool.olderVersion, isNull);
    });

    test('прежняя версия: «устарела», не запускается, обновление её убирает',
        () async {
      await ytKit('2025.01.01').install();
      final tool = ytKit('2026.10.26');
      await tool.refresh();
      expect(tool.isInstalled, isFalse);
      expect(tool.olderVersion, '2025.01.01');
      expect(await tool.verifiedPath(), isNull);
      await tool.install();
      expect(tool.isInstalled, isTrue);
      expect(tool.olderVersion, isNull);
      expect(
        Directory(tool.dir).listSync().map((e) => p.basename(e.path)),
        <String>['2026.10.26'],
      );
    });

    test('сумма не совпала — программы нет', () async {
      final spec = ytdlp('2026.10.26');
      final tool = ToolKit(
        spec: ToolSpec(
          id: spec.id,
          title: spec.title,
          abi: spec.abi,
          version: spec.version,
          url: spec.url,
          sha256: 'b' * 64,
          bytes: spec.bytes,
          archive: spec.archive,
          entry: spec.entry,
          binaryName: spec.binaryName,
          binaryBytes: spec.binaryBytes,
          license: spec.license,
          sourceUrl: spec.sourceUrl,
        ),
        downloader: downloader,
        dir: p.join(temp.path, 'tools', 'ytdlp'),
        chmod: (String path) async => chmods.add(path),
      );
      await tool.install();
      expect(tool.error, ToolError.checksum);
      expect(File(tool.binaryPath).existsSync(), isFalse);
      expect(chmods, isEmpty);
    });

    test('подменили и программу, и installed.json — не запускается', () async {
      final tool = ytKit('2026.10.26');
      await tool.install();
      // Чужой файл и его сумма в installed.json: сверка с суммой,
      // закреплённой в приложении, его не пропустит.
      final evil = utf8.encode('чужая программа');
      File(tool.binaryPath).writeAsBytesSync(evil);
      final marker = File(
        p.join(tool.dir, '2026.10.26', 'installed.json'),
      );
      final json = jsonDecode(marker.readAsStringSync()) as Map;
      json['binary_sha256'] = crypto.sha256.convert(evil).toString();
      marker.writeAsStringSync(jsonEncode(json));
      final fresh = ytKit('2026.10.26');
      await fresh.refresh();
      expect(await fresh.verifiedPath(), isNull);
      expect(File(fresh.binaryPath).existsSync(), isFalse);
    });
  });
}
