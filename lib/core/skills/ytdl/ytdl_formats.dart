/// Что умеет скачивать загрузчик видео (ADR-024, шаг 3): варианты поля
/// «Что скачать» и проверка ссылки. Без ввода-вывода: этим пользуются и
/// схема карточки ([ExtensionForms]), и навык, и задача.
library;

/// Варианты «Что скачать».
abstract final class YtdlFormats {
  /// Id программы yt-dlp в наборе установленных программ карточки.
  static const String tool = 'ytdlp';

  /// Id ffmpeg (тот же, что у конвертера).
  static const String ffmpeg = 'ffmpeg';

  static const String video1080 = 'video1080';
  static const String video720 = 'video720';
  static const String video480 = 'video480';
  static const String audio = 'audio';

  static const List<String> all = <String>[
    video1080,
    video720,
    video480,
    audio,
  ];

  /// Вариант по умолчанию, если во фразе ничего не сказано.
  static const String fallback = video720;

  static String label(String format) => switch (format) {
        video1080 => 'Видео: лучшее до 1080p',
        video720 => 'Видео: лучшее до 720p',
        video480 => 'Видео: лучшее до 480p',
        audio => 'Только звук (mp3)',
        _ => format,
      };

  /// Высота кадра для видео или `null` (звук).
  static int? heightOf(String format) => switch (format) {
        video1080 => 1080,
        video720 => 720,
        video480 => 480,
        _ => null,
      };

  /// Варианту нужен ffmpeg: только звук (перекодирование в mp3).
  static bool needsFfmpeg(String format) => format == audio;
}

/// Ссылка для загрузчика: только http и https, с именем сайта.
abstract final class YtdlUrl {
  /// Самая длинная ссылка, которую принимает карточка.
  static const int maxLength = 2048;

  static final RegExp _pattern = RegExp(
    r'https?://[^\s<>"«»]+',
    caseSensitive: false,
  );

  /// Знаки, которые в конце ссылки скорее относятся к фразе.
  static final RegExp _trailing = RegExp(r'[.,;:!?)\]}»”]+$');

  /// Первая ссылка в тексте [text] или `null`.
  static String? find(String text) {
    for (final match in _pattern.allMatches(text)) {
      final candidate = match.group(0)!.replaceFirst(_trailing, '');
      if (valid(candidate)) return candidate;
    }
    return null;
  }

  /// Текст без ссылок (для разбора слов фразы).
  static String strip(String text) => text.replaceAll(_pattern, ' ');

  /// Ссылка годится для yt-dlp: http(s), есть сайт, без пробелов и
  /// управляющих знаков, не длиннее [maxLength]. Ссылка не может
  /// начинаться с `-`: она и так идёт после `--`, но пусть будет дважды.
  static bool valid(String url) {
    if (url.isEmpty || url.length > maxLength) return false;
    if (RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'https' || scheme == 'http') &&
        uri.host.isNotEmpty &&
        !uri.host.startsWith('-');
  }
}
