// Конвертер картинок (ADR-024, шаг 2): png/jpeg/webp/bmp/gif → png/jpeg на
// Dart, поворот по EXIF применён, метаданные (с GPS) не переносятся, у GIF
// — первый кадр, предел 50 мегапикселей, битый файл, исходник не меняется,
// отмена убирает временный файл.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/jobs/job_placement.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';
import 'package:local_assistant/core/skills/converter/image_convert.dart';
import 'package:path/path.dart' as p;

final class _Reporter implements JobReporter {
  final List<(double?, String?)> ticks = <(double?, String?)>[];

  @override
  void progress(double? value, String? stage) => ticks.add((value, stage));
}

img.Image _picture({int width = 4, int height = 2}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // Левая половина красная, правая синяя.
      final left = x < width ~/ 2;
      image.setPixelRgb(x, y, left ? 255 : 0, 0, left ? 0 : 255);
    }
  }
  return image;
}

/// PNG-заголовок с размерами [width]×[height] без данных картинки: размер
/// читается до декодирования.
Uint8List _hugePngHeader(int width, int height) {
  final ihdr = BytesBuilder()
    ..add('IHDR'.codeUnits)
    ..add(_u32(width))
    ..add(_u32(height))
    ..add(<int>[8, 2, 0, 0, 0]);
  final body = ihdr.toBytes();
  return (BytesBuilder()
        ..add(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        ..add(_u32(13))
        ..add(body)
        ..add(_u32(getCrc32(body)))
        ..add(_u32(0))
        ..add('IEND'.codeUnits)
        ..add(_u32(getCrc32('IEND'.codeUnits))))
      .toBytes();
}

List<int> _u32(int v) =>
    <int>[(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

String _sha(File file) =>
    crypto.sha256.convert(file.readAsBytesSync()).toString();

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('image_convert'));
  tearDown(() => temp.deleteSync(recursive: true));

  final inputs = <String, Uint8List Function(img.Image)>{
    'png': (img.Image i) => img.encodePng(i),
    'jpg': (img.Image i) => img.encodeJpg(i),
    'bmp': (img.Image i) => img.encodeBmp(i),
    'gif': (img.Image i) => img.encodeGif(i),
    // `image` не пишет WebP: берём готовый файл без потерь 1×1.
  };

  for (final MapEntry(key: ext, value: encode) in inputs.entries) {
    for (final target in ConvertTargets.targetsFor('a.$ext')) {
      test('$ext → $target', () {
        final source = File(p.join(temp.path, 'кадр.$ext'))
          ..writeAsBytesSync(encode(_picture()));
        final before = _sha(source);
        final request = ConvertOps.plan(
          cardId: 'c1',
          target: target,
          source: JobSource(source.path, 'кадр.$ext'),
          outputDir: temp.path,
        );
        final reporter = _Reporter();
        final done = ConvertOps.run(request, reporter);
        final out = File(done.outputs.single);
        // Тот же формат («пережать») — рядом с «(2)»: исходник на месте.
        final same = ConvertTargets.sameFormat('a.$ext', target);
        expect(
          p.basename(out.path),
          'кадр${same ? ' (2)' : ''}.${ConvertTargets.outputExtension(target)}',
        );
        final decoded = img.decodeImage(out.readAsBytesSync())!;
        expect(decoded.width, 4);
        expect(decoded.height, 2);
        expect(
          target == ConvertTargets.png
              ? img.findDecoderForData(out.readAsBytesSync()) is img.PngDecoder
              : img.findDecoderForData(out.readAsBytesSync())
                  is img.JpegDecoder,
          isTrue,
        );
        expect(_sha(source), before, reason: 'исходник не меняется');
        expect(File(request.temp!).existsSync(), isFalse);
        expect(reporter.ticks.last.$1, 1);
      });
    }
  }

  test('webp → png', () {
    // Самый маленький WebP без потерь: 1×1, непрозрачный.
    final webp = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, //
      0x56, 0x50, 0x38, 0x4c, 0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
      0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0x00,
    ]);
    final encoded = ConvertOps.convertBytes(webp, ConvertTargets.png);
    final decoded = img.decodePng(encoded)!;
    expect(decoded.width, 1);
    expect(decoded.height, 1);
  });

  test('поворот по EXIF применён, EXIF и GPS не переносятся', () {
    final source = _picture();
    source.exif.imageIfd.orientation = 6; // повернуть на 90° по часовой
    source.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(55, 1);
    final jpeg = img.encodeJpg(source);
    expect(img.decodeJpg(jpeg)!.exif.gpsIfd.isEmpty, isFalse);
    for (final target in <String>[ConvertTargets.jpeg, ConvertTargets.png]) {
      final out = ConvertOps.convertBytes(jpeg, target);
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 2, reason: target);
      expect(decoded.height, 4, reason: target);
      expect(decoded.exif.isEmpty, isTrue, reason: target);
      // Никаких следов EXIF в байтах.
      expect(String.fromCharCodes(out).contains('Exif'), isFalse);
    }
  });

  test('анимированный GIF — первый кадр', () {
    // У очень маленьких картинок кодировщик GIF путает палитру — берём
    // 16×8.
    final first = _picture(width: 16, height: 8);
    final second = img.Image(width: 16, height: 8)
      ..clear(img.ColorRgb8(0, 255, 0));
    first.addFrame(second);
    final gif = img.encodeGif(first);
    expect(img.decodeGif(gif)!.numFrames, 2);
    final out =
        img.decodePng(ConvertOps.convertBytes(gif, ConvertTargets.png))!;
    expect(out.numFrames, 1);
    final pixel = out.getPixel(0, 0);
    expect(pixel.r, greaterThan(200));
    expect(pixel.g, lessThan(50));
  });

  test('прозрачное в JPEG — на белом', () {
    final rgba = img.Image(width: 2, height: 2, numChannels: 4)
      ..clear(img.ColorRgba8(0, 0, 0, 0));
    final out = img.decodeJpg(
      ConvertOps.convertBytes(img.encodePng(rgba), ConvertTargets.jpeg),
    )!;
    expect(out.getPixel(0, 0).r, greaterThan(240));
  });

  test('больше 50 мегапикселей — отказ до декодирования', () {
    expect(
      () => ConvertOps.convertBytes(
        _hugePngHeader(10000, 6000),
        ConvertTargets.jpeg,
      ),
      throwsA(
        isA<JobError>().having((JobError e) => e.code, 'code', JobCodes.tooBig),
      ),
    );
  });

  test('не картинка — «не поддерживается», обрезанная — «не прочитать»', () {
    expect(
      () => ConvertOps.convertBytes(
        Uint8List.fromList(List<int>.filled(64, 7)),
        ConvertTargets.png,
      ),
      throwsA(
        isA<JobError>()
            .having((JobError e) => e.code, 'code', JobCodes.unsupported),
      ),
    );
    final png = img.encodePng(_picture(width: 64, height: 64));
    final cut = Uint8List.sublistView(png, 0, png.length ~/ 2);
    expect(
      () => ConvertOps.convertBytes(cut, ConvertTargets.jpeg),
      throwsA(
        isA<JobError>().having((JobError e) => e.code, 'code', JobCodes.media),
      ),
    );
  });

  test('имя занято — «(2)»; исходника нет — missing', () {
    final source = File(p.join(temp.path, 'a.png'))
      ..writeAsBytesSync(img.encodePng(_picture()));
    File(p.join(temp.path, 'a.jpg')).writeAsStringSync('занято');
    final request = ConvertOps.plan(
      cardId: 'c',
      target: ConvertTargets.jpeg,
      source: JobSource(source.path, 'a.png'),
      outputDir: temp.path,
    );
    expect(p.basename(request.target!), 'a (2).jpg');
    expect(ConvertOps.usesDart(request), isTrue);
    source.deleteSync();
    expect(
      () => ConvertOps.run(request, _Reporter()),
      throwsA(isA<JobMissing>()),
    );
    expect(JobCodes.of(const JobError(JobCodes.media)), JobCodes.media);
  });

  test('видео и звук — не задача изолята (ffmpeg или система)', () {
    final request = ConvertOps.plan(
      cardId: 'c',
      target: ConvertTargets.framePng,
      source: const JobSource('/tmp/v.mp4', 'v.mp4'),
      outputDir: '/tmp',
    );
    expect(ConvertOps.usesDart(request), isFalse);
    expect(p.basename(request.target!), 'v.png');
    expect(
      p.basename(request.temp!),
      matches(RegExp(r'^\.v\.png\.r[0-9a-z]+\.c\.part$')),
    );
    expect(JobPlacement.isTempFor(request.temp!, 'c'), isTrue);
  });

  test('в изоляте: готово; отмена убирает временный файл', () async {
    final source = File(p.join(temp.path, 'b.bmp'))
      ..writeAsBytesSync(img.encodeBmp(_picture(width: 600, height: 400)));
    final runner = IsolateJobRunner(<String, JobWork>{
      'converter': ConvertOps.run,
    });
    final request = ConvertOps.plan(
      cardId: 'c2',
      target: ConvertTargets.png,
      source: JobSource(source.path, 'b.bmp'),
      outputDir: temp.path,
    );
    final events = await runner.start(request).toList();
    expect(events.last, isA<JobDone>());
    expect(File(p.join(temp.path, 'b.png')).existsSync(), isTrue);

    final again = ConvertOps.plan(
      cardId: 'c3',
      target: ConvertTargets.jpeg,
      source: JobSource(source.path, 'b.bmp'),
      outputDir: temp.path,
    );
    File(again.temp!).writeAsStringSync('частично');
    final stream = runner.start(again);
    runner.cancel('c3');
    final cancelled = await stream.toList();
    expect((cancelled.last as JobFailed).code, JobCodes.cancelled);
    expect(File(again.temp!).existsSync(), isFalse);
    expect(File(again.target!).existsSync(), isFalse);
  });

  group('качество и размер (ADR-026)', () {
    img.Image noisy(int width, int height) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          image.setPixelRgb(
            x,
            y,
            (x * 7 + y * 3) % 256,
            (x * y) % 256,
            y % 256,
          );
        }
      }
      return image;
    }

    test('JPEG: меньше качество — меньше файл', () {
      final bytes = img.encodePng(noisy(300, 200));
      final sizes = <int>[
        for (final q in ConvertQuality.jpegPresets)
          ConvertOps.convertBytes(bytes, ConvertTargets.jpeg, jpegQuality: q)
              .length,
      ];
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], lessThan(sizes[i - 1]), reason: '$sizes');
      }
    });

    test('уменьшение: длинная сторона — ровно предел, пропорции те же', () {
      final wide = img.decodeImage(
        ConvertOps.convertBytes(
          img.encodePng(noisy(400, 100)),
          ConvertTargets.png,
          maxSide: 200,
        ),
      )!;
      expect((wide.width, wide.height), (200, 50));
      final tall = img.decodeJpg(
        ConvertOps.convertBytes(
          img.encodePng(noisy(90, 300)),
          ConvertTargets.jpeg,
          maxSide: 150,
        ),
      )!;
      expect((tall.width, tall.height), (45, 150));
    });

    test('меньшая картинка не растягивается', () {
      final out = img.decodePng(
        ConvertOps.convertBytes(
          img.encodePng(noisy(120, 80)),
          ConvertTargets.png,
          maxSide: 1920,
        ),
      )!;
      expect((out.width, out.height), (120, 80));
    });

    test('поворот по EXIF применяется до уменьшения', () {
      final source = noisy(400, 100)..exif.imageIfd.orientation = 6;
      final out = img.decodeJpg(
        ConvertOps.convertBytes(
          img.encodeJpg(source),
          ConvertTargets.jpeg,
          maxSide: 200,
        ),
      )!;
      // Повёрнута на 90°: была 400×100, стала 100×400 → 50×200.
      expect((out.width, out.height), (50, 200));
      expect(out.exif.imageIfd.orientation, anyOf(isNull, 1));
    });

    test('задача берёт качество и размер из карточки', () {
      final source = File(p.join(temp.path, 'фото.png'))
        ..writeAsBytesSync(img.encodePng(noisy(640, 480)));
      final request = ConvertOps.plan(
        cardId: 'q1',
        target: ConvertTargets.jpeg,
        source: JobSource(source.path, 'фото.png'),
        outputDir: temp.path,
        options: const <String, String>{
          'jpeg_quality': '60',
          'image_size': '1280',
          // Не к этой цели — в задачу не попадает.
          'audio_kbps': '320',
          'video_res': '<script>',
        },
      );
      expect(request.options, <String, String>{
        'jpeg_quality': '60',
        'image_size': '1280',
      });
      final done = ConvertOps.run(request, _Reporter());
      final out = img.decodeJpg(File(done.outputs.single).readAsBytesSync())!;
      // 640 меньше 1280 — размер прежний.
      expect((out.width, out.height), (640, 480));
    });

    test('тот же формат — «(2)» рядом, исходник не тронут', () {
      final source = File(p.join(temp.path, 'кот.jpg'))
        ..writeAsBytesSync(img.encodeJpg(noisy(300, 200)));
      final before = _sha(source);
      expect(ConvertTargets.targetsFor('кот.jpg'), contains('jpeg'));
      final request = ConvertOps.plan(
        cardId: 'q2',
        target: ConvertTargets.jpeg,
        source: JobSource(source.path, 'кот.jpg'),
        outputDir: temp.path,
        options: const <String, String>{'image_size': '1280'},
      );
      expect(p.basename(request.target!), 'кот (2).jpg');
      ConvertOps.run(request, _Reporter());
      expect(_sha(source), before);
      expect(File(p.join(temp.path, 'кот (2).jpg')).existsSync(), isTrue);
    });
  });
}
