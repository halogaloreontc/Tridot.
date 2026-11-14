/// Во что конвертер умеет превращать файл (docs/PLANS.md, «Конвертер»;
/// ADR-024, шаг 2; ADR-026). Тип файла — по расширению имени: картинки
/// конвертируются на Dart (пакет `image`) везде, звук и видео — внешней
/// программой ffmpeg на Windows и Linux или средствами системы на
/// телефоне и Mac ([ConvertCaps]). Что где делается — честно, по таблице
/// [ConvertCaps.route].
library;

export 'convert_caps.dart';
export 'convert_quality.dart';

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

  /// Звук AAC в контейнере MPEG-4.
  static const String m4a = 'm4a';

  /// Звук без сжатия (PCM 16 бит).
  static const String wav = 'wav';
  static const String mp4 = 'mp4';
  static const String mov = 'mov';
  static const String webm = 'webm';

  /// Кадр из видео (на первой секунде).
  static const String frameJpeg = 'frame-jpeg';
  static const String framePng = 'frame-png';

  /// Все цели в порядке показа.
  static const List<String> all = <String>[
    png,
    jpeg,
    mp3,
    m4a,
    wav,
    mp4,
    mov,
    webm,
    frameJpeg,
    framePng,
  ];

  /// Цели со звуком без видео.
  static const Set<String> audioTargets = <String>{mp3, m4a, wav};

  /// Цели с видео.
  static const Set<String> videoTargets = <String>{mp4, mov, webm};

  /// Id внешней программы, которая нужна звуку и видео на компьютере.
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

  /// Расширения, у которых своя цель: «jpg» → `jpeg`, «m4v» → `mp4`.
  static String? _ownTarget(String ext) => switch (ext) {
        'png' => png,
        'jpg' || 'jpeg' || 'jpe' => jpeg,
        'mp3' => mp3,
        'm4a' || 'aac' => m4a,
        'wav' => wav,
        'mp4' || 'm4v' => mp4,
        'mov' => mov,
        'webm' => webm,
        _ => null,
      };

  /// Цели, которые можно сделать из файла того же формата: у них есть
  /// настройки качества или размера («JPEG (пережать)», «MP3 (пережать)»).
  static const Set<String> _reencodable = <String>{png, jpeg, mp3, m4a, mp4};

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

  /// Цель — тот же формат, что у файла [name] («пережать»).
  static bool sameFormat(String name, String target) =>
      _ownTarget(extensionOf(name)) == target;

  /// Цели для файла [name] без оглядки на платформу ([ConvertCaps]
  /// решает, что из них здесь делается). Свой формат — только если у
  /// него есть настройки («JPEG (пережать)»): wav в wav не предлагается.
  static List<String> targetsFor(String name) {
    final own = _ownTarget(extensionOf(name));
    bool offer(String target) => target != own || _reencodable.contains(target);
    final List<String> candidates = switch (kindOf(name)) {
      MediaKind.image => const <String>[png, jpeg],
      MediaKind.audio => const <String>[mp3, m4a, wav],
      MediaKind.video => const <String>[
          mp3,
          m4a,
          wav,
          mp4,
          mov,
          webm,
          frameJpeg,
          framePng,
        ],
      MediaKind.unknown => const <String>[],
    };
    return <String>[
      for (final target in candidates)
        if (offer(target)) target,
    ];
  }

  /// Цель делается на Dart (картинка в картинку); иначе нужен ffmpeg или
  /// система.
  static bool isImageTarget(String target) => target == png || target == jpeg;

  /// Цель для файла [name] делается на Dart: картинка → png/jpeg.
  static bool dartFor(String name, String target) =>
      kindOf(name) == MediaKind.image && isImageTarget(target);

  /// Цель — кадр из видео.
  static bool isFrame(String target) =>
      target == frameJpeg || target == framePng;

  /// Подпись цели в карточке; [same] — файл того же формата.
  static String label(String target, {bool same = false}) => switch (target) {
        png => same ? 'PNG (уменьшить)' : 'PNG',
        jpeg => same ? 'JPEG (пережать)' : 'JPEG',
        mp3 => same ? 'MP3 (пережать)' : 'MP3 (звук)',
        m4a => same ? 'M4A (пережать)' : 'M4A (звук AAC)',
        wav => 'WAV (звук без сжатия)',
        mp4 => same ? 'MP4 (пережать)' : 'MP4 (видео H.264)',
        mov => 'MOV (видео)',
        webm => 'WebM',
        frameJpeg => 'Кадр в JPEG',
        framePng => 'Кадр в PNG',
        _ => target,
      };

  /// Название формата для текста ответа: «MP3», «кадр JPEG».
  static String shortLabel(String target) => switch (target) {
        png => 'PNG',
        jpeg => 'JPEG',
        mp3 => 'MP3',
        m4a => 'M4A',
        wav => 'WAV',
        mp4 => 'MP4',
        mov => 'MOV',
        webm => 'WebM',
        frameJpeg => 'кадр JPEG',
        framePng => 'кадр PNG',
        _ => target,
      };

  /// Расширение файла результата.
  static String outputExtension(String target) => switch (target) {
        png || framePng => 'png',
        jpeg || frameJpeg => 'jpg',
        mp3 => 'mp3',
        m4a => 'm4a',
        wav => 'wav',
        mp4 => 'mp4',
        mov => 'mov',
        webm => 'webm',
        _ => 'bin',
      };

  /// Цель по слову из фразы («mp3», «джипег», «пнг») или `null`.
  static String? fromWord(String word) => switch (word) {
        'mp3' || 'мп3' => mp3,
        'png' || 'пнг' => png,
        'jpg' || 'jpeg' || 'джпг' || 'джипег' || 'жпег' || 'джпег' => jpeg,
        'mp4' || 'мп4' => mp4,
        'm4a' || 'aac' || 'м4а' => m4a,
        'wav' || 'вав' => wav,
        'mov' || 'мов' => mov,
        'webm' => webm,
        _ => null,
      };

  /// Формат, который конвертер не делает нигде, по слову из фразы:
  /// «в flac» — честный ответ, а не молчание. Иначе `null`.
  static String? unofferedWord(String word) => switch (word) {
        'flac' || 'флак' => 'FLAC',
        'ogg' || 'огг' => 'OGG',
        'opus' || 'опус' => 'Opus',
        'webp' => 'WebP',
        'heic' => 'HEIC',
        'avi' => 'AVI',
        'mkv' => 'MKV',
        'gif' || 'гиф' => 'GIF',
        _ => null,
      };
}
