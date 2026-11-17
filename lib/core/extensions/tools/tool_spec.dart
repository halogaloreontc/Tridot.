/// Внешние программы расширений, которые скачиваются по кнопке (ADR-024):
/// ffmpeg для конвертера и yt-dlp для загрузчика видео. Узкое исключение из ADR-005 —
/// только Windows и Linux, только по явному действию пользователя после
/// предупреждения о размере. Источник закреплён в коде: адрес, размер и
/// SHA-256 из официального списка сумм релиза; переадресация — только на
/// хосты из [ToolSpec.redirectHosts].
library;

import 'dart:ffi' show Abi;

import '../../build_flags.dart';

/// Во что упакована программа.
enum ToolArchive {
  /// Сама программа, без архива (yt-dlp).
  none,

  /// `.zip` (Windows).
  zip,

  /// `.tar.xz` (Linux).
  tarXz,
}

/// Одна сборка программы для одной платформы.
final class ToolSpec {
  const ToolSpec({
    required this.id,
    required this.title,
    required this.abi,
    required this.version,
    required this.url,
    required this.sha256,
    required this.bytes,
    required this.archive,
    required this.entry,
    required this.binaryName,
    required this.binaryBytes,
    required this.license,
    required this.sourceUrl,
    this.redirectHosts = githubAssets,
  });

  /// `ffmpeg` или `ytdlp`.
  final String id;

  /// Название для человека.
  final String title;

  /// Платформа и процессор сборки.
  final Abi abi;

  /// Версия (и имя папки установки).
  final String version;

  /// Откуда скачивать: только https.
  final String url;

  /// SHA-256 архива строчными. Пустая строка — сумму не удалось получить
  /// из официального источника: такая сборка «недоступна», кнопки
  /// «Скачать» нет и [ToolSpec.available] — `false`.
  final String sha256;

  /// Размер архива в байтах.
  final int bytes;

  final ToolArchive archive;

  /// Путь программы внутри архива (через `/`); у [ToolArchive.none] —
  /// пустая строка.
  final String entry;

  /// Имя файла программы после установки.
  final String binaryName;

  /// Сколько места займёт установленная программа (примерно).
  final int binaryBytes;

  /// Лицензия сборки.
  final String license;

  /// Где исходники и скрипты сборки.
  final String sourceUrl;

  /// Хосты, на которые разрешена переадресация (точные имена).
  final Set<String> redirectHosts;

  /// Хосты файлов релизов GitHub.
  static const Set<String> githubAssets = <String>{
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };

  Uri get uri => Uri.parse(url);

  /// Сборку можно скачать: адрес https и сумма из официального источника.
  bool get available =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      bytes > 0;
}

/// Закреплённые сборки.
abstract final class ToolSpecs {
  /// ffmpeg: сборки BtbN (github.com/BtbN/FFmpeg-Builds, теперь
  /// github.com/FFmpeg-Builds/FFmpeg-Builds), вариант LGPL с libmp3lame,
  /// FFmpeg n9.0.2, месячный тег `autobuild-2026-10-31-12-59` (месячные
  /// теги хранятся около двух лет — константы обновляются выпусками
  /// приложения). Суммы — из официального `checksums.sha256` этого тега,
  /// скачанного 2026-11-14 и сверенного со скачанными архивами. Подписей
  /// GPG у BtbN нет: проверка только по закреплённой сумме (ADR-024).
  static const String ffmpegTag = 'autobuild-2026-10-31-12-59';
  static const String ffmpegBuild = 'ffmpeg-n9.0.2-39-g7adfbe40dc';
  static const String _ffmpegBase =
      'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/'
      '$ffmpegTag/';
  static const String _ffmpegSource =
      'https://github.com/FFmpeg-Builds/FFmpeg-Builds';
  static const String _lgpl = 'LGPL-3.0 (FFmpeg с --enable-version3, '
      'libmp3lame — LGPL)';

  static const List<ToolSpec> ffmpeg = <ToolSpec>[
    ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.windowsX64,
      version: ffmpegBuild,
      url: '$_ffmpegBase$ffmpegBuild-win64-lgpl-9.0.zip',
      sha256:
          '9d37c564e0d01c18cde184a079fa6ef04d7d2783ada41da81d04165cc8f1a650',
      bytes: 168715328,
      archive: ToolArchive.zip,
      entry: '$ffmpegBuild-win64-lgpl-9.0/bin/ffmpeg.exe',
      binaryName: 'ffmpeg.exe',
      binaryBytes: 132190720,
      license: _lgpl,
      sourceUrl: _ffmpegSource,
    ),
    ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.windowsArm64,
      version: ffmpegBuild,
      url: '$_ffmpegBase$ffmpegBuild-winarm64-lgpl-9.0.zip',
      sha256:
          'd1981518b99a1c05d6b864200b1ac9459b09e2ee174feffe84b6e6bb0bfa79e2',
      bytes: 117554579,
      archive: ToolArchive.zip,
      entry: '$ffmpegBuild-winarm64-lgpl-9.0/bin/ffmpeg.exe',
      binaryName: 'ffmpeg.exe',
      binaryBytes: 80793088,
      license: _lgpl,
      sourceUrl: _ffmpegSource,
    ),
    ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.linuxX64,
      version: ffmpegBuild,
      url: '$_ffmpegBase$ffmpegBuild-linux64-lgpl-9.0.tar.xz',
      sha256:
          '6046d6731b26f58887e953561551d254a6eec9fbca4100dfeab56e19af8328d5',
      bytes: 136027168,
      archive: ToolArchive.tarXz,
      entry: '$ffmpegBuild-linux64-lgpl-9.0/bin/ffmpeg',
      binaryName: 'ffmpeg',
      binaryBytes: 140488520,
      license: _lgpl,
      sourceUrl: _ffmpegSource,
    ),
    ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.linuxArm64,
      version: ffmpegBuild,
      url: '$_ffmpegBase$ffmpegBuild-linuxarm64-lgpl-9.0.tar.xz',
      sha256:
          '3d1f66827a73ce5a446312bc4924234dc1515726d3743e2df35c0177e1f82128',
      bytes: 116688828,
      archive: ToolArchive.tarXz,
      entry: '$ffmpegBuild-linuxarm64-lgpl-9.0/bin/ffmpeg',
      binaryName: 'ffmpeg',
      binaryBytes: 117224424,
      license: _lgpl,
      sourceUrl: _ffmpegSource,
    ),
  ];

  /// yt-dlp: одиночные исполняемые файлы релиза `2026.10.26`
  /// (github.com/yt-dlp/yt-dlp). Суммы — из официального `SHA2-256SUMS`
  /// этого релиза, скачанного 2026-11-14; подпись `SHA2-256SUMS.sig`
  /// проверена GPG ключом AC0C BBE6 848D 6A87 3464 AF4E 57CF 6593 3B5A 7581
  /// (yt-dlp signing key) в момент закрепления — в приложении подпись не
  /// проверяется, только закреплённая сумма (ADR-024). Размеры — по
  /// ответу сервера релизов. Обновление — только новой версией
  /// приложения: `yt-dlp -U` обошёл бы закреплённую сумму.
  static const String ytdlpVersion = '2026.10.26';
  static const String _ytdlpBase =
      'https://github.com/yt-dlp/yt-dlp/releases/download/$ytdlpVersion/';
  static const String _ytdlpSource = 'https://github.com/yt-dlp/yt-dlp';
  static const String _ytdlpLicense = 'исходники — Unlicense; одиночный '
      'исполняемый файл — GPLv3+ (совместное произведение с Python и '
      'библиотеками)';

  static const List<ToolSpec> ytdlp = <ToolSpec>[
    ToolSpec(
      id: 'ytdlp',
      title: 'yt-dlp',
      abi: Abi.windowsX64,
      version: ytdlpVersion,
      url: '${_ytdlpBase}yt-dlp.exe',
      sha256:
          'f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d',
      bytes: 23575744,
      archive: ToolArchive.none,
      entry: '',
      binaryName: 'yt-dlp.exe',
      binaryBytes: 23575744,
      license: _ytdlpLicense,
      sourceUrl: _ytdlpSource,
    ),
    ToolSpec(
      id: 'ytdlp',
      title: 'yt-dlp',
      abi: Abi.windowsArm64,
      version: ytdlpVersion,
      url: '${_ytdlpBase}yt-dlp_arm64.exe',
      sha256:
          '0066dbac3c124028e2dcae2a197fccee33cd91f456313d24f7af89fd54590e98',
      bytes: 22809590,
      archive: ToolArchive.none,
      entry: '',
      binaryName: 'yt-dlp.exe',
      binaryBytes: 22809590,
      license: _ytdlpLicense,
      sourceUrl: _ytdlpSource,
    ),
    ToolSpec(
      id: 'ytdlp',
      title: 'yt-dlp',
      abi: Abi.linuxX64,
      version: ytdlpVersion,
      url: '${_ytdlpBase}yt-dlp_linux',
      sha256:
          '767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795',
      bytes: 41166968,
      archive: ToolArchive.none,
      entry: '',
      binaryName: 'yt-dlp',
      binaryBytes: 41166968,
      license: _ytdlpLicense,
      sourceUrl: _ytdlpSource,
    ),
    ToolSpec(
      id: 'ytdlp',
      title: 'yt-dlp',
      abi: Abi.linuxArm64,
      version: ytdlpVersion,
      url: '${_ytdlpBase}yt-dlp_linux_aarch64',
      sha256:
          'e87e9533e89fe5889abaa21f5114dfe7756d6aa6219b83551add04d48b18e483',
      bytes: 40789792,
      archive: ToolArchive.none,
      entry: '',
      binaryName: 'yt-dlp',
      binaryBytes: 40789792,
      license: _ytdlpLicense,
      sourceUrl: _ytdlpSource,
    ),
  ];

  /// yt-dlp для macOS (универсальный `yt-dlp_macos`, сумма из того же
  /// подписанного `SHA2-256SUMS`) — на будущее: в [all] не входит, пока
  /// владелец не решит судьбу macOS (песочница, карантин; ADR-024).
  static const ToolSpec ytdlpMacos = ToolSpec(
    id: 'ytdlp',
    title: 'yt-dlp',
    abi: Abi.macosArm64,
    version: ytdlpVersion,
    url: '${_ytdlpBase}yt-dlp_macos',
    sha256: '0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa',
    bytes: 37466304,
    archive: ToolArchive.none,
    entry: '',
    binaryName: 'yt-dlp',
    binaryBytes: 37466304,
    license: _ytdlpLicense,
    sourceUrl: _ytdlpSource,
  );

  /// Все закреплённые сборки.
  /// В сборке для Google Play yt-dlp нет (ADR-024): ссылки и суммы
  /// выбрасываются при сборке.
  static const List<ToolSpec> all = <ToolSpec>[
    ...ffmpeg,
    if (!kPlayBuild) ...ytdlp,
  ];

  /// Сборка программы [id] для платформы [abi] или `null` (Android,
  /// macOS, iOS — запускать скачанные программы нельзя, ADR-024).
  static ToolSpec? forAbi(String id, Abi abi) {
    for (final spec in all) {
      if (spec.id == id && spec.abi == abi) return spec;
    }
    return null;
  }

  /// Сборка для этого устройства.
  static ToolSpec? forCurrentPlatform(String id) => forAbi(id, Abi.current());
}
