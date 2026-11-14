import '../downloads/safe_zip.dart';

/// Модель распознавания речи, которую скачивают по требованию (ADR-023).
///
/// В приложение модель не встроена: она скачивается один раз, когда
/// включают голосовой ввод. До распаковки архив проверяется по размеру и
/// SHA-256, закреплённым здесь, в коде.
final class VoiceModelSpec {
  const VoiceModelSpec({
    required this.url,
    required this.sha256,
    required this.bytes,
    required this.folderName,
    this.requiredFiles = const <String>['am/final.mdl', 'conf/model.conf'],
    this.limits = const ZipLimits(
      maxEntries: 64,
      maxTotalBytes: 128 * 1024 * 1024,
      maxEntryBytes: 64 * 1024 * 1024,
    ),
  });

  /// Официальный адрес архива (https).
  final String url;

  /// SHA-256 архива: 64 строчных шестнадцатеричных знака.
  final String sha256;

  /// Размер архива в байтах.
  final int bytes;

  /// Папка внутри архива; под тем же именем модель лежит на устройстве.
  final String folderName;

  /// Файлы, без которых модель не считается установленной (пути внутри
  /// [folderName]).
  final List<String> requiredFiles;

  /// Пределы распаковки архива.
  final ZipLimits limits;

  Uri get uri => Uri.parse(url);

  /// Малая русская модель Vosk 0.22 (Apache-2.0), ~45 МБ в архиве и ~87 МБ
  /// после распаковки.
  ///
  /// SHA-256 вычислен по архиву, md5 которого совпал с официальным
  /// model-list.json (`d1759dc83eb8fd87850129afbd9f4b7b`); размер совпал с
  /// `Content-Length` сервера. Подписи у моделей Vosk нет — только эта
  /// закреплённая сумма. Новая версия модели — новые значения здесь и
  /// новое имя папки.
  static const VoiceModelSpec ruSmall = VoiceModelSpec(
    url: 'https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip',
    sha256: '961d5ff98a17f4aa6de69864d0aa71fa5bac682301d2b5d17a3f24c5c99a46d4',
    bytes: 46236750,
    folderName: 'vosk-model-small-ru-0.22',
  );
}
