// Закреплённые сборки ffmpeg (ADR-024, шаг 2) и yt-dlp (шаг 3): только
// https, сумма — 64 шестнадцатеричных знака, переадресация — только на
// хосты файлов релизов GitHub; на Android, macOS и iOS сборки нет; сборка
// без суммы не скачивается никогда.
import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';

final class _NoDownloads implements FileDownloader {
  int calls = 0;

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    file, {
    required int expectedBytes,
    required CancelToken cancel,
  }) {
    calls++;
    return const Stream<DownloadProgress>.empty();
  }
}

void main() {
  test('каждая сборка: https, хост, сумма, программа внутри архива', () {
    expect(ToolSpecs.all, isNotEmpty);
    for (final spec in ToolSpecs.ffmpeg) {
      expect(spec.uri.scheme, 'https', reason: spec.url);
      expect(spec.uri.host, 'github.com', reason: spec.url);
      expect(spec.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: spec.url);
      expect(spec.available, isTrue);
      expect(spec.bytes, greaterThan(50 * 1024 * 1024));
      expect(spec.entry.endsWith('/bin/${spec.binaryName}'), isTrue);
      expect(spec.url, contains(ToolSpecs.ffmpegTag));
      expect(spec.url, contains('-lgpl-'), reason: 'только LGPL-сборка');
      expect(spec.redirectHosts, <String>{
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      });
      expect(
        spec.redirectHosts.every((String h) => !h.contains('*')),
        isTrue,
      );
    }
  });

  test('yt-dlp: официальный релиз, программа без архива', () {
    expect(ToolSpecs.ytdlp, hasLength(4));
    for (final spec in <ToolSpec>[...ToolSpecs.ytdlp, ToolSpecs.ytdlpMacos]) {
      expect(spec.id, 'ytdlp');
      expect(spec.uri.scheme, 'https', reason: spec.url);
      expect(spec.uri.host, 'github.com', reason: spec.url);
      expect(
        spec.uri.path,
        startsWith('/yt-dlp/yt-dlp/releases/download/'
            '${ToolSpecs.ytdlpVersion}/'),
      );
      expect(spec.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: spec.url);
      expect(spec.available, isTrue);
      expect(spec.archive, ToolArchive.none);
      expect(spec.entry, isEmpty);
      expect(spec.binaryBytes, spec.bytes);
      expect(spec.bytes, greaterThan(10 * 1024 * 1024));
      expect(spec.redirectHosts, ToolSpec.githubAssets);
    }
    // Сумма из подписанного SHA2-256SUMS релиза 2026.10.26.
    expect(
      ToolSpecs.forAbi('ytdlp', Abi.linuxX64)!.sha256,
      '767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795',
    );
    expect(ToolSpecs.forAbi('ytdlp', Abi.windowsX64)!.binaryName, 'yt-dlp.exe');
    // macOS — только на будущее: в набор сборок не входит.
    expect(ToolSpecs.all, isNot(contains(ToolSpecs.ytdlpMacos)));
    for (final abi in <Abi>[
      Abi.androidArm64,
      Abi.macosArm64,
      Abi.macosX64,
      Abi.iosArm64,
    ]) {
      expect(ToolSpecs.forAbi('ytdlp', abi), isNull, reason: '$abi');
    }
  });

  test('Windows и Linux — есть; Android, macOS, iOS — нет', () {
    for (final abi in <Abi>[
      Abi.windowsX64,
      Abi.windowsArm64,
      Abi.linuxX64,
      Abi.linuxArm64,
    ]) {
      expect(ToolSpecs.forAbi('ffmpeg', abi), isNotNull, reason: '$abi');
    }
    for (final abi in <Abi>[
      Abi.androidArm64,
      Abi.androidX64,
      Abi.macosArm64,
      Abi.macosX64,
      Abi.iosArm64,
    ]) {
      expect(ToolSpecs.forAbi('ffmpeg', abi), isNull, reason: '$abi');
    }
  });

  test('сборка без суммы недоступна: установка не начинается', () async {
    final real = ToolSpecs.ffmpeg.first;
    final stub = ToolSpec(
      id: real.id,
      title: real.title,
      abi: real.abi,
      version: real.version,
      url: real.url,
      // ЗАГЛУШКА: сумма не получена из официального источника.
      sha256: '',
      bytes: real.bytes,
      archive: real.archive,
      entry: real.entry,
      binaryName: real.binaryName,
      binaryBytes: real.binaryBytes,
      license: real.license,
      sourceUrl: real.sourceUrl,
    );
    expect(stub.available, isFalse);
    final downloads = _NoDownloads();
    final kit = ToolKit(spec: stub, downloader: downloads, dir: '/nonexistent');
    await expectLater(kit.install(), throwsStateError);
    expect(downloads.calls, 0);
  });
}
