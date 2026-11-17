// Таблица качества конвертера (ADR-026): допустимые значения, значения по
// умолчанию, лишнее и чужое отбрасывается, предустановки битрейта видео.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';

void main() {
  test('поля к цели: звук, видео, JPEG, размер картинки', () {
    expect(ConvertQuality.codesFor('mp3'), <String>['audio_kbps']);
    expect(ConvertQuality.codesFor('m4a'), <String>['audio_kbps']);
    expect(ConvertQuality.codesFor('wav'), isEmpty);
    expect(
      ConvertQuality.codesFor('mp4'),
      <String>['video_res', 'video_quality'],
    );
    expect(ConvertQuality.codesFor('frame-jpeg'), <String>['jpeg_quality']);
    expect(ConvertQuality.codesFor('frame-png'), isEmpty);
    expect(
      ConvertQuality.codesFor('jpeg', MediaKind.image),
      <String>['jpeg_quality', 'image_size'],
    );
    expect(ConvertQuality.codesFor('png', MediaKind.image), <String>[
      'image_size',
    ]);
    // Без файла png и jpeg — из картинки.
    expect(ConvertQuality.codesFor('png'), <String>['image_size']);
    for (final field in ConvertQuality.fields) {
      expect(RegExp(r'^[a-z_]+$').hasMatch(field.code), isTrue);
      expect(field.accepts(field.defaultValue), isTrue, reason: field.code);
    }
  });

  test('значения по умолчанию и разбор', () {
    expect(
      ConvertOptions.fromMap(const <String, Object?>{}, 'mp3'),
      ConvertOptions.defaults,
    );
    expect(ConvertOptions.defaults.audioKbps, 192);
    expect(ConvertOptions.defaults.jpegQuality, 85);
    expect(ConvertOptions.defaults.maxSide, isNull);
    final o = ConvertOptions.fromMap(
      const <String, Object?>{
        'audio_kbps': '320',
        'image_size': '1920',
        'jpeg_quality': '60',
      },
      'jpeg',
      MediaKind.image,
    );
    // audio_kbps у jpeg ничего не меняет — по умолчанию.
    expect(o.audioKbps, 192);
    expect(o.maxSide, 1920);
    expect(o.jpegQuality, 60);
  });

  test('чужое, недопустимое и не к цели — отбрасывается', () {
    expect(
      ConvertOptions.clean(
        const <String, Object?>{
          'audio_kbps': '320',
          'video_res': '720',
          'jpeg_quality': '101',
          'target': 'mp3',
          'file': <Object>[],
          'x': '1',
        },
        'mp3',
      ),
      <String, String>{'audio_kbps': '320'},
    );
    expect(
      ConvertOptions.clean(
        const <String, Object?>{
          'audio_kbps': '321',
        },
        'mp3',
      ),
      isEmpty,
    );
    expect(
      ConvertOptions.fromMap(
        const <String, Object?>{
          'video_res': '4320',
          'video_quality': 'ultra',
        },
        'mp4',
      ),
      ConvertOptions.defaults,
    );
  });

  test('предустановки: битрейт видео, звук в видео, WebM, кадр JPEG', () {
    expect(ConvertQuality.videoKbps('1080', 'high'), 8000);
    expect(ConvertQuality.videoKbps('720', 'eco'), 1800);
    expect(ConvertQuality.videoKbps('480', 'mid'), 1500);
    expect(ConvertQuality.videoKbps('src', 'mid'), 4000);
    expect(ConvertQuality.videoAudioKbps('high'), 192);
    expect(ConvertQuality.videoAudioKbps('eco'), 128);
    expect(ConvertQuality.webmCrf('mid'), 33);
    expect(ConvertQuality.longSide('720'), 1280);
    expect(ConvertQuality.longSide('480'), 854);
    expect(ConvertQuality.longSide('src'), isNull);
    expect(ConvertQuality.ffmpegJpegQ(95), 2);
    expect(ConvertQuality.ffmpegJpegQ(85), 3);
    expect(ConvertQuality.ffmpegJpegQ(75), 5);
    expect(ConvertQuality.ffmpegJpegQ(60), 8);
    // Чем выше качество, тем больше битрейт — в каждой строке.
    for (final res in <String>['src', '1080', '720', '480']) {
      expect(
        ConvertQuality.videoKbps(res, 'high'),
        greaterThan(ConvertQuality.videoKbps(res, 'mid')),
      );
      expect(
        ConvertQuality.videoKbps(res, 'mid'),
        greaterThan(ConvertQuality.videoKbps(res, 'eco')),
      );
    }
  });

  test('ближайшее значение и подписи для ответа', () {
    expect(ConvertQuality.nearest(160, ConvertQuality.kbpsPresets), 192);
    expect(ConvertQuality.nearest(300, ConvertQuality.kbpsPresets), 320);
    expect(ConvertQuality.nearest(90, ConvertQuality.jpegPresets), 95);
    expect(ConvertQuality.nearest(2000, ConvertQuality.sizePresets), 1920);
    expect(ConvertQuality.phraseLabel('audio_kbps', '320'), '320 кбит/с');
    expect(ConvertQuality.phraseLabel('video_res', '720'), '720p');
    expect(
      ConvertQuality.phraseLabel('video_quality', 'eco'),
      'экономное качество',
    );
  });
}
