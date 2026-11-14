/// Качество и размер результата конвертера (ADR-026): одна таблица на всё
/// — поля формы, фразы («в mp3 320»), аргументы ffmpeg, кодировщик
/// картинок на Dart и (позже) системные кодировщики телефона и Mac берут
/// варианты и значения по умолчанию отсюда.
library;

import 'convert_targets.dart';

/// Поле качества: код в [ExtensionCard.values], подпись, варианты и
/// значение по умолчанию.
final class QualityField {
  const QualityField({
    required this.code,
    required this.label,
    required this.values,
    required this.defaultValue,
  });

  /// Код поля (`^[a-z_]+$`).
  final String code;

  /// Подпись над списком.
  final String label;

  /// Значение → подпись в списке, в порядке показа.
  final List<(String, String)> values;

  final String defaultValue;

  bool accepts(String? value) =>
      value != null && values.any(((String, String) v) => v.$1 == value);
}

/// Таблица полей качества и предустановок.
abstract final class ConvertQuality {
  /// Битрейт звука mp3 и m4a, кбит/с.
  static const String audioKbps = 'audio_kbps';

  /// Размер видео: `src` — как в исходнике, иначе высота кадра.
  static const String videoRes = 'video_res';

  /// Качество видео: `high`, `mid`, `eco`.
  static const String videoQuality = 'video_quality';

  /// Качество JPEG (и кадра в JPEG).
  static const String jpegQuality = 'jpeg_quality';

  /// Размер картинки по длинной стороне: `orig` — как есть.
  static const String imageSize = 'image_size';

  static const String src = 'src';
  static const String high = 'high';
  static const String mid = 'mid';
  static const String eco = 'eco';
  static const String orig = 'orig';

  static const QualityField audio = QualityField(
    code: audioKbps,
    label: 'Качество звука',
    values: <(String, String)>[
      ('128', '128 кбит/с — меньше файл'),
      ('192', '192 кбит/с — обычно'),
      ('256', '256 кбит/с'),
      ('320', '320 кбит/с — наилучшее'),
    ],
    defaultValue: '192',
  );

  static const QualityField resolution = QualityField(
    code: videoRes,
    label: 'Размер видео',
    values: <(String, String)>[
      (src, 'Как в исходнике'),
      ('1080', '1080p (Full HD)'),
      ('720', '720p (HD)'),
      ('480', '480p'),
    ],
    defaultValue: src,
  );

  static const QualityField video = QualityField(
    code: videoQuality,
    label: 'Качество видео',
    values: <(String, String)>[
      (high, 'Высокое'),
      (mid, 'Среднее'),
      (eco, 'Экономное — меньше файл'),
    ],
    defaultValue: mid,
  );

  static const QualityField jpeg = QualityField(
    code: jpegQuality,
    label: 'Качество JPEG',
    values: <(String, String)>[
      ('95', '95 — наилучшее'),
      ('85', '85 — обычно'),
      ('75', '75'),
      ('60', '60 — меньше файл'),
    ],
    defaultValue: '85',
  );

  static const QualityField size = QualityField(
    code: imageSize,
    label: 'Размер картинки',
    values: <(String, String)>[
      (orig, 'Оригинал'),
      ('2560', 'До 2560 px по длинной стороне'),
      ('1920', 'До 1920 px по длинной стороне'),
      ('1280', 'До 1280 px по длинной стороне'),
    ],
    defaultValue: orig,
  );

  /// Все поля в порядке показа в карточке.
  static const List<QualityField> fields = <QualityField>[
    audio,
    resolution,
    video,
    jpeg,
    size,
  ];

  /// Поле по коду или `null`.
  static QualityField? field(String code) =>
      fields.where((QualityField f) => f.code == code).firstOrNull;

  /// Коды полей, которые что-то меняют у цели [target]. [source] — тип
  /// исходника; `null` — файла ещё нет (png и jpeg тогда — из картинки).
  static List<String> codesFor(String target, [MediaKind? source]) => <String>[
        if (target == ConvertTargets.mp3 || target == ConvertTargets.m4a)
          audioKbps,
        if (ConvertTargets.videoTargets.contains(target)) ...<String>[
          videoRes,
          videoQuality,
        ],
        if (target == ConvertTargets.jpeg || target == ConvertTargets.frameJpeg)
          jpegQuality,
        if (ConvertTargets.isImageTarget(target) &&
            (source == null || source == MediaKind.image))
          imageSize,
      ];

  /// Битрейты, которые понимает фраза.
  static const List<int> kbpsPresets = <int>[128, 192, 256, 320];

  /// Качества JPEG, которые понимает фраза.
  static const List<int> jpegPresets = <int>[95, 85, 75, 60];

  /// Размеры картинки, которые понимает фраза.
  static const List<int> sizePresets = <int>[2560, 1920, 1280];

  /// Ближайшее к [value] из [presets] (при равенстве — большее).
  static int nearest(int value, List<int> presets) {
    var best = presets.first;
    for (final p in presets) {
      final d = (p - value).abs();
      final bd = (best - value).abs();
      if (d < bd || (d == bd && p > best)) best = p;
    }
    return best;
  }

  /// Битрейт видео, кбит/с, по размеру и качеству (H.264 в mp4 и mov).
  static int videoKbps(String res, String quality) {
    const table = <String, List<int>>{
      '1080': <int>[8000, 5000, 3000],
      '720': <int>[5000, 3000, 1800],
      '480': <int>[2500, 1500, 900],
      src: <int>[8000, 4000, 2000],
    };
    final row = table[res] ?? table[src]!;
    return row[_qualityIndex(quality)];
  }

  /// Битрейт звука AAC внутри видео, кбит/с.
  static int videoAudioKbps(String quality) =>
      const <int>[192, 160, 128][_qualityIndex(quality)];

  /// CRF для WebM (VP9): меньше — лучше.
  static int webmCrf(String quality) =>
      const <int>[28, 33, 38][_qualityIndex(quality)];

  /// Длинная сторона кадра по размеру видео; `null` — как в исходнике.
  static int? longSide(String res) => switch (res) {
        '1080' => 1920,
        '720' => 1280,
        '480' => 854,
        _ => null,
      };

  /// `-q:v` ffmpeg для кадра в JPEG (2 — наилучшее, 31 — наихудшее).
  static int ffmpegJpegQ(int quality) => switch (quality) {
        >= 95 => 2,
        >= 85 => 3,
        >= 75 => 5,
        _ => 8,
      };

  static int _qualityIndex(String quality) => switch (quality) {
        high => 0,
        eco => 2,
        _ => 1,
      };

  /// Короткая подпись выбранного значения для ответа: «320 кбит/с»,
  /// «720p», «экономное качество».
  static String phraseLabel(String code, String value) => switch (code) {
        audioKbps => '$value кбит/с',
        videoRes => value == src ? 'как в исходнике' : '${value}p',
        videoQuality => switch (value) {
            high => 'высокое качество',
            eco => 'экономное качество',
            _ => 'среднее качество',
          },
        jpegQuality => 'качество $value',
        imageSize => value == orig ? 'исходный размер' : 'до $value px',
        _ => value,
      };
}

/// Выбранное качество для одной задачи: только допустимые значения и
/// только поля, которые что-то меняют у цели. Неизвестное и лишнее
/// отбрасывается, пустое — значение по умолчанию.
final class ConvertOptions {
  const ConvertOptions({
    this.audioKbps = 192,
    this.videoRes = ConvertQuality.src,
    this.videoQuality = ConvertQuality.mid,
    this.jpegQuality = 85,
    this.maxSide,
  });

  /// Значения по умолчанию.
  static const ConvertOptions defaults = ConvertOptions();

  final int audioKbps;
  final String videoRes;
  final String videoQuality;
  final int jpegQuality;

  /// Длинная сторона картинки; `null` — оригинал.
  final int? maxSide;

  /// Из значений карточки или задачи [values] для цели [target].
  factory ConvertOptions.fromMap(
    Map<String, Object?> values,
    String target, [
    MediaKind? source,
  ]) {
    final codes = ConvertQuality.codesFor(target, source);
    String pick(QualityField field) {
      final value = values[field.code];
      return codes.contains(field.code) &&
              value is String &&
              field.accepts(value)
          ? value
          : field.defaultValue;
    }

    final size = pick(ConvertQuality.size);
    return ConvertOptions(
      audioKbps: int.parse(pick(ConvertQuality.audio)),
      videoRes: pick(ConvertQuality.resolution),
      videoQuality: pick(ConvertQuality.video),
      jpegQuality: int.parse(pick(ConvertQuality.jpeg)),
      maxSide: size == ConvertQuality.orig ? null : int.parse(size),
    );
  }

  /// Только допустимые значения нужных цели [target] полей из [values]:
  /// это уходит в задачу ([JobRequest.options]).
  static Map<String, String> clean(
    Map<String, Object?> values,
    String target, [
    MediaKind? source,
  ]) =>
      <String, String>{
        for (final code in ConvertQuality.codesFor(target, source))
          if (values[code] case final String value
              when ConvertQuality.field(code)!.accepts(value))
            code: value,
      };

  @override
  bool operator ==(Object other) =>
      other is ConvertOptions &&
      other.audioKbps == audioKbps &&
      other.videoRes == videoRes &&
      other.videoQuality == videoQuality &&
      other.jpegQuality == jpegQuality &&
      other.maxSide == maxSide;

  @override
  int get hashCode =>
      Object.hash(audioKbps, videoRes, videoQuality, jpegQuality, maxSide);

  @override
  String toString() => 'ConvertOptions($audioKbps, $videoRes, $videoQuality, '
      '$jpegQuality, $maxSide)';
}
