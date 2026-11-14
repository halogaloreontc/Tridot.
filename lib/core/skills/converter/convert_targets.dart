/// Во что конвертер умеет превращать файл (docs/PLANS.md, «Конвертер»;
/// ADR-024, шаг 2). Тип файла — по расширению имени: картинки
/// конвертируются на Dart (пакет `image`), звук и видео — внешней
/// программой ffmpeg, которая скачивается отдельно и есть не на всех
/// платформах.
library;

/// Тип исходного файла.
enum MediaKind {
  /// png, jpeg, webp, bmp, gif.
  image,

  /// wav, flac, ogg, m4a, mp3, opus, aac.
  audio,

  /// mp4, webm, mkv, mov, avi.
  video,

  /// Всё остальное (в том числе HEIC): «пока не поддерживается».
  unknown,
}

/// Цели конвертера: значение поля `target` карточки.
abstract final class ConvertTargets {
  static const String png = 'png';
  static const String jpeg = 'jpeg';
  static const String mp3 = 'mp3';
  static const String mp4 = 'mp4';
  static const String webm = 'webm';

  /// Кадр из видео (на первой секунде).
  static const String frameJpeg = 'frame-jpeg';
  static const String framePng = 'frame-png';

  /// Все цели в порядке показа.
  static const List<String> all = <String>[
    png,
    jpeg,
    mp3,
    mp4,
    webm,
    frameJpeg,
    framePng,
  ];

  /// Id внешней программы, которая нужна звуку и видео.
  static const String ffmpeg = 'ffmpeg';

  static const Set<String> _image = <String>{
    'png',
    'jpg',
    'jpeg',
    'jpe',
    'webp',
    'bmp',
    'gif',
  };

  static const Set<String> _audio = <String>{
    'wav',
    'flac',
    'ogg',
    'oga',
    'm4a',
    'mp3',
    'opus',
    'aac',
  };

  static const Set<String> _video = <String>{
    'mp4',
    'm4v',
    'webm',
    'mkv',
    'mov',
    'avi',
  };

  /// Расширение имени строчными без точки; нет — пустая строка.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    final ext = name.substring(dot + 1).toLowerCase();
    return ext.contains('/') || ext.contains('\\') ? '' : ext;
  }

  /// Тип файла по имени.
  static MediaKind kindOf(String name) {
    final ext = extensionOf(name);
    if (_image.contains(ext)) return MediaKind.image;
    if (_audio.contains(ext)) return MediaKind.audio;
    if (_video.contains(ext)) return MediaKind.video;
    return MediaKind.unknown;
  }

  /// Цели для файла [name] — без его собственного формата («jpg» не
  /// предлагается для .jpg).
  static List<String> targetsFor(String name) {
    final ext = extensionOf(name);
    return switch (kindOf(name)) {
      MediaKind.image => <String>[
          if (ext != 'png') png,
          if (!const <String>{'jpg', 'jpeg', 'jpe'}.contains(ext)) jpeg,
        ],
      MediaKind.audio => <String>[if (ext != 'mp3') mp3],
      MediaKind.video => <String>[
          mp3,
          if (ext != 'mp4' && ext != 'm4v') mp4,
          if (ext != 'webm') webm,
          frameJpeg,
          framePng,
        ],
      MediaKind.unknown => const <String>[],
    };
  }

  /// Цель делается программой ffmpeg (иначе — на Dart).
  static bool needsFfmpeg(String target) => target != png && target != jpeg;

  /// Цель для картинки или кадра: делается ли она для файла [name] без
  /// ffmpeg. Кадр из видео — всегда ffmpeg.
  static bool needsFfmpegFor(String name, String target) =>
      kindOf(name) != MediaKind.image || needsFfmpeg(target);

  /// Подпись цели в карточке.
  static String label(String target) => switch (target) {
        png => 'PNG',
        jpeg => 'JPEG',
        mp3 => 'MP3 (звук)',
        mp4 => 'MP4',
        webm => 'WebM',
        frameJpeg => 'Кадр в JPEG',
        framePng => 'Кадр в PNG',
        _ => target,
      };

  /// Расширение файла результата.
  static String outputExtension(String target) => switch (target) {
        png || framePng => 'png',
        jpeg || frameJpeg => 'jpg',
        mp3 => 'mp3',
        mp4 => 'mp4',
        webm => 'webm',
        _ => 'bin',
      };

  /// Цель по слову из фразы («mp3», «джипег», «пнг») или `null`.
  static String? fromWord(String word) => switch (word) {
        'mp3' || 'мп3' => mp3,
        'png' || 'пнг' => png,
        'jpg' || 'jpeg' || 'джпг' || 'джипег' || 'жпег' || 'джпег' => jpeg,
        'mp4' || 'мп4' => mp4,
        'webm' => webm,
        _ => null,
      };
}
