import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/gen/gen_release.dart';

/// Загрузчик частей модели: байты по адресу, с продолжением, обрывом и
/// воротами для проверки хода.
final class PartsDownloader implements FileDownloader {
  final Map<Uri, List<int>> files = <Uri, List<int>>{};

  /// Оборвать загрузку после стольких записанных кусков (за всё время).
  int? dropAfter;
  int calls = 0;
  int chunks = 0;
  final List<int> offsets = <int>[];
  Completer<void>? gate;

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    calls++;
    final bytes = files[uri];
    if (bytes == null) throw const DownloadException(DownloadError.network);
    var offset = await partFile.exists() ? await partFile.length() : 0;
    offsets.add(offset);
    yield DownloadProgress(offset, expectedBytes);
    while (offset < bytes.length) {
      if (gate case final g?) {
        await Future.any(<Future<void>>[g.future, cancel.whenCancelled]);
      }
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      if (dropAfter case final n? when chunks >= n) {
        throw const DownloadException(DownloadError.network);
      }
      final end = (offset + 500).clamp(0, bytes.length);
      await partFile.writeAsBytes(
        bytes.sublist(offset, end),
        mode: FileMode.append,
        flush: true,
      );
      chunks++;
      offset = end;
      yield DownloadProgress(offset, expectedBytes);
    }
  }
}

String sha(List<int> b) => crypto.sha256.convert(b).toString();

/// Выпуск [version] частями по [partBytes]; кладёт части в [downloader].
/// [badPart] — номер части с неверной суммой.
String publishGen(
  PartsDownloader downloader,
  String version,
  List<int> bytes, {
  int partBytes = 1500,
  int? minRam,
  int? badPart,
  String? wholeSha,
}) {
  final parts = <Map<String, Object?>>[];
  for (var i = 0, n = 1; i < bytes.length; i += partBytes, n++) {
    final chunk = bytes.sublist(i, (i + partBytes).clamp(0, bytes.length));
    final url = GenRelease.latestUrl.resolve(
      'tridot-gen-$version.gguf.${n.toString().padLeft(3, '0')}',
    );
    downloader.files[url] = chunk;
    parts.add(<String, Object?>{
      'url': '$url',
      'size': chunk.length,
      'sha256': n == badPart ? 'a' * 64 : sha(chunk),
    });
  }
  return jsonEncode(<String, Object?>{
    'format': GenRelease.format,
    'version': version,
    'model': <String, Object?>{
      'size': bytes.length,
      'sha256': wholeSha ?? sha(bytes),
      'parts': parts,
      'title': 'Qwen3-4B-Instruct-2507',
      if (minRam != null) 'min_ram_mb': minRam,
    },
  });
}
