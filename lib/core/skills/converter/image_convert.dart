/// Работа конвертера (ADR-024, шаг 2): картинки png/jpeg/webp/bmp/gif →
/// png/jpeg на чистом Dart (пакет `image`) в отдельном изоляте
/// ([IsolateJobRunner]); звук и видео — ffmpeg ([FfmpegJobRunner]).
/// Исходник не меняется: результат пишется во временный файл рядом и
/// переименовывается в конце.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../jobs/extension_card.dart';
import '../../jobs/job_placement.dart';
import '../../jobs/job_runner.dart';
import 'convert_targets.dart';

abstract final class ConvertOps {
  /// Самая большая картинка: 50 мегапикселей (память телефона).
  static const int maxPixels = 50 * 1000 * 1000;

  /// Самый большой файл картинки, который читается целиком.
  static const int maxImageBytes = 200 * 1024 * 1024;

  /// Качество JPEG.
  static const int jpegQuality = 90;

  /// Задача по карточке: имя результата и временный путь. Результат —
  /// `<имя>.<расширение цели>` в [outputDir] («(2)», «(3)» при
  /// совпадении) или [explicitTarget] (окно сохранения на macOS).
  static JobRequest plan({
    required String cardId,
    required String target,
    required JobSource source,
    required String outputDir,
    String? explicitTarget,
  }) {
    final ext = ConvertTargets.outputExtension(target);
    final base = JobPlacement.safeName(
      p.basenameWithoutExtension(source.name),
      fallback: 'Файл',
    );
    final out =
        explicitTarget ?? JobPlacement.uniquePath(outputDir, '$base.$ext');
    return JobRequest(
      cardId: cardId,
      extensionId: ExtensionForms.converter,
      action: target,
      sources: <JobSource>[source],
      outputDir: p.dirname(out),
      target: out,
      // Id карточки в имени: две задачи с одним именем результата не
      // пишут в один временный файл.
      temp: JobPlacement.tempFile(out, cardId),
    );
  }

  /// Задача делается ffmpeg (а не на Dart).
  static bool usesFfmpeg(JobRequest request) =>
      request.extensionId == ExtensionForms.converter &&
      ConvertTargets.needsFfmpegFor(
        request.sources.single.name,
        request.action,
      );

  /// Картинка → png или jpeg; работа в изоляте.
  static JobDone run(JobRequest request, JobReporter reporter) {
    final source = request.sources.single;
    final target = request.target!;
    final part = request.temp!;
    final file = File(source.path);
    if (!file.existsSync()) throw const JobMissing();
    if (usesFfmpeg(request)) throw const JobError(JobCodes.noTool);
    reporter.progress(0.05, 'Чтение');
    if (file.lengthSync() > maxImageBytes) {
      throw const JobError(JobCodes.tooBig);
    }
    final bytes = file.readAsBytesSync();
    final encoded = convertBytes(bytes, request.action, reporter: reporter);
    reporter.progress(0.9, 'Запись');
    try {
      File(part).writeAsBytesSync(encoded, flush: true);
      // Имя могли занять, пока шла работа: чужой файл не заменяется.
      final result = JobPlacement.commitFile(part, target);
      reporter.progress(1, 'Запись');
      return JobDone(outputs: <String>[result], outputDir: p.dirname(result));
    } on Object {
      IsolateJobRunner.removeQuietly(part);
      rethrow;
    }
  }

  /// Байты картинки → байты png или jpeg ([target]). Поворот по EXIF
  /// применяется, метаданные (EXIF с GPS, текстовые поля) не переносятся;
  /// у GIF и других анимаций — первый кадр; прозрачное в JPEG — на белом.
  static Uint8List convertBytes(
    Uint8List bytes,
    String target, {
    JobReporter? reporter,
  }) {
    if (target != ConvertTargets.png && target != ConvertTargets.jpeg) {
      throw const JobError(JobCodes.unsupported);
    }
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) throw const JobError(JobCodes.unsupported);
    final img.DecodeInfo? info;
    try {
      info = decoder.startDecode(bytes);
    } on Object {
      throw const JobError(JobCodes.media);
    }
    if (info == null) throw const JobError(JobCodes.media);
    if (info.width <= 0 || info.height <= 0) {
      throw const JobError(JobCodes.media);
    }
    if (info.width * info.height > maxPixels) {
      throw const JobError(JobCodes.tooBig);
    }
    reporter?.progress(0.2, 'Преобразование');
    img.Image? decoded;
    try {
      decoded = decoder.decode(bytes, frame: 0);
    } on Object {
      decoded = null;
    }
    if (decoded == null) throw const JobError(JobCodes.media);
    if (decoded.width * decoded.height > maxPixels) {
      throw const JobError(JobCodes.tooBig);
    }
    var image = img.bakeOrientation(decoded);
    // Метаданные не переносятся: в EXIF бывают координаты съёмки.
    image
      ..exif = img.ExifData()
      ..textData = null
      ..frames = <img.Image>[image];
    reporter?.progress(0.6, 'Преобразование');
    if (target == ConvertTargets.png) return img.encodePng(image);
    if (image.hasPalette) image = image.convert(numChannels: 4);
    if (image.numChannels == 4 || image.numChannels == 2) {
      final background = img.Image(
        width: image.width,
        height: image.height,
      )..clear(img.ColorRgb8(255, 255, 255));
      image = img.compositeImage(background, image);
    }
    return img.encodeJpg(image, quality: jpegQuality);
  }
}
