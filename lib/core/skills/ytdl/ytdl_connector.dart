/// Навык-расширение «Загрузчик видео» (docs/PLANS.md, «Загрузчик видео по
/// ссылке»; ADR-024, шаг 3): ссылка → видео с качеством или только звук →
/// «Скачать». Скачивает программа yt-dlp, которую пользователь скачивает
/// по кнопке; только Windows и Linux и не в сборке для Google Play
/// ([ytdlSupported]). Выключен по умолчанию, ведёт его Лиорио.
///
/// Ссылка уходит только в yt-dlp: навык кладёт её в поле карточки и
/// больше никуда — ни в текст ответа, ни в код ошибки, ни в журналы.
library;

import '../../connectors/connector.dart';
import '../../jobs/extension_card.dart';
import 'ytdl_formats.dart';

export 'ytdl_formats.dart';

final class YtdlConnector implements Connector, FormConnector, IntentTarget {
  YtdlConnector();

  static const String id = ExtensionForms.ytdl;

  static const String downloadCommand = 'ytdl.download';

  /// Глагол и объект или ссылка: явная команда.
  static const double confidence = 0.9;

  int _counter = 0;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Загрузчик видео',
        description: 'Видео или звук по ссылке — через программу yt-dlp, '
            'которая скачивается по кнопке. Скачивайте только своё или то, '
            'на что есть права.',
        examples: <String>[
          'скачай видео по ссылке',
          'скачай звук из видео',
        ],
        kind: ExtensionKind.skill,
        // Ссылку надо скачать из интернета: фразы о паролях навык не
        // видит никогда (раздел 5.9).
        requiresNetwork: true,
        defaultEnabled: false,
        offHint: true,
      );

  /// Как выполнить команду по подсказке запасного слоя (ADR-041).
  static const Map<String, IntentRecipe> intentRecipes = <String, IntentRecipe>{
    'ytdl.download': IntentRecipe(
      carriers: <String>['скачай видео'],
      ask: 'скачай видео',
      example: 'скачай видео по ссылке',
    ),
  };

  @override
  ConnectorMatch? matchAs(
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  ) =>
      matchByRecipe(this, intentRecipes, commandId, utterance, analyze);

  @override
  String? intentExample(String commandId) =>
      intentRecipes[commandId]?.example ?? intentRecipes[commandId]?.ask;

  @override
  ConnectorMatch? match(Utterance utterance) {
    final format = YtdlPhrases.formatOf(utterance);
    if (format == null) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: downloadCommand,
      confidence: confidence,
      // Ссылка — только в данных совпадения, до карточки: в тексте ответа
      // и в журналах её нет.
      payload: (format, YtdlUrl.find(utterance.original)),
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final (format, url) = switch (match.payload) {
      (final String format, final String? url) => (format, url),
      _ => (YtdlPhrases.unspecified, null),
    };
    return _form(url, format, session);
  }

  @override
  AssistantResponse openForm(String? action, AssistantSession session) =>
      _form(null, null, session);

  AssistantResponse _form(
    String? url,
    String? format,
    AssistantSession session,
  ) {
    final now = session.clock.now();
    final card = ExtensionCard(
      id: 'j${now.microsecondsSinceEpoch}_${_counter++}',
      extensionId: id,
      updatedAt: now,
    );
    if (url != null) card.setValue('url', url);
    card.setValue(
      'format',
      format == null || format == YtdlPhrases.unspecified
          ? YtdlFormats.fallback
          : format,
    );
    // Ответ без ссылки: адрес — только в поле карточки.
    return session.reply(
      url == null ? 'ytdl.form' : 'ytdl.form.url',
      intent: downloadCommand,
      status: AssistantStatus.completed,
      job: card,
    );
  }
}

/// Фразы загрузчика: повелительное наклонение и объект («скачай видео»,
/// «скачай звук из видео …») или ссылка («скачай https://…»). «Загрузи» и
/// «сохрани» — только со ссылкой («сохрани видео в mp3» — конвертер,
/// «загрузи видео на ютуб» — не скачивание). Голая ссылка без глагола,
/// инфинитив («скачать музыку»), задачи и напоминания — не его.
abstract final class YtdlPhrases {
  /// Формат не назван: подставится вариант по умолчанию.
  static const String unspecified = '';

  static const Set<String> _fillers = <String>{
    'пожалуйста',
    'давай',
    'теперь',
    'а',
    'и',
    'ну',
    'еще',
    'мне',
    'плиз',
  };

  /// Глаголы, которым хватает объекта.
  static const Set<String> _downloadVerbs = <String>{
    'скачай',
    'скачайте',
    'выкачай',
    'стяни',
  };

  /// Глаголы, которым нужна ссылка.
  static const Set<String> _linkVerbs = <String>{
    'загрузи',
    'загрузите',
    'сохрани',
    'сохраните',
  };

  static bool _isVideo(String w) =>
      w.startsWith('видео') ||
      w.startsWith('видос') ||
      w.startsWith('ролик') ||
      w.startsWith('клип');

  static bool _isAudio(String w) =>
      w.startsWith('звук') ||
      w.startsWith('аудио') ||
      w == 'mp3' ||
      w.startsWith('музык') ||
      w.startsWith('песн') ||
      w.startsWith('трек');

  /// Слова фразы без ссылок: строчными, «ё» → «е».
  static List<String> wordsOf(String text) => <String>[
        for (final match in RegExp('[a-zа-я0-9]+').allMatches(
          YtdlUrl.strip(text).toLowerCase().replaceAll('ё', 'е'),
        ))
          match.group(0)!,
      ];

  /// Формат из фразы ([YtdlFormats], [unspecified]) или `null` — фраза
  /// не команда загрузчику.
  static String? formatOf(Utterance utterance) {
    final original = utterance.original;
    final words = wordsOf(original);
    if (words.isEmpty || words.length > 14) return null;
    if (words.any(
      (String w) =>
          w.startsWith('задач') ||
          w.startsWith('напомн') ||
          w.startsWith('напомин'),
    )) {
      return null;
    }
    var start = 0;
    while (start < words.length - 1 && _fillers.contains(words[start])) {
      start++;
    }
    final verb = words[start];
    final rest = words.sublist(start + 1);
    final hasUrl = YtdlUrl.find(original) != null;
    final video = rest.any(_isVideo);
    final audio = rest.any(_isAudio);
    if (_downloadVerbs.contains(verb)) {
      // «Скачай музыку» без ссылки — не про ролик по ссылке.
      final musicOnly = !video &&
          !rest.any(
            (String w) =>
                w.startsWith('звук') || w.startsWith('аудио') || w == 'mp3',
          );
      if (!hasUrl && (!video && !audio || musicOnly)) return null;
    } else if (_linkVerbs.contains(verb)) {
      if (!hasUrl) return null;
      // «Загрузи видео на ютуб» — выложить, а не скачать.
      if (verb.startsWith('загруз') && rest.contains('на')) return null;
    } else {
      return null;
    }
    if (audio) return YtdlFormats.audio;
    for (final w in rest) {
      final quality = switch (w) {
        '1080' || '1080p' => YtdlFormats.video1080,
        '720' || '720p' => YtdlFormats.video720,
        '480' || '480p' => YtdlFormats.video480,
        _ => null,
      };
      if (quality != null) return quality;
    }
    return unspecified;
  }
}
