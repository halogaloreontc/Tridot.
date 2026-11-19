/// Навык «Файлы сессии» (ADR-028): «удали этот файл» после готовой
/// карточки конвертера — удалить результат с подтверждением. Работает
/// только с файлами текущей сессии ([AssistantSession.recentFiles]);
/// исходники пользователя не трогает. Ведёт Лиорио, как сами
/// расширения-авторы файлов.
library;

import '../../connectors/connector.dart';

/// Вид файла из просьбы: «удали последний архив», «удали видео».
enum FileKind {
  archive(<String>{'zip', '7z', 'tar', 'gz', 'tgz', 'rar', 'bz2', 'xz'}),
  video(<String>{'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp'}),
  audio(<String>{'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac', 'wma'}),
  image(<String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'heic',
    'heif',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'avif',
  }),
  document(<String>{
    'pdf',
    'doc',
    'docx',
    'odt',
    'rtf',
    'txt',
    'md',
    'xls',
    'xlsx',
    'csv',
    'ppt',
    'pptx',
  });

  const FileKind(this.extensions);

  final Set<String> extensions;

  bool matches(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    return extensions.contains(name.substring(dot + 1).toLowerCase());
  }
}

/// Какие файлы сессии имеются в виду: результат карточки или исходник.
enum FileOrigin { any, output, source }

/// Просьба удалить файл сессии.
final class FileDeleteRequest {
  const FileDeleteRequest({
    this.name,
    this.pointed = false,
    this.kind,
    this.origin = FileOrigin.any,
  });

  /// Имя из кавычек: «удали файл «отчёт.pdf»».
  final String? name;

  /// Файл указан: «этот», «последний», «его», «только что сделанный».
  /// Без указания и при нескольких файлах — вопрос «Какой файл удалить?».
  final bool pointed;

  /// Вид файла: «архив», «видео», «фото». `null` — любой.
  final FileKind? kind;

  /// «Результат» — файл карточки, «исходник», «оригинал» — вложение.
  final FileOrigin origin;
}

/// Фразы удаления файла.
abstract final class FilesPhrases {
  static const Set<String> _verbs = <String>{
    'удали',
    'удалите',
    'удалить',
    'сотри',
    'сотрите',
    'стереть',
    'убери',
    'уберите',
    'убрать',
    'выкинь',
    'выкиньте',
    'выброси',
    'выбрось',
    'выбросите',
    'снеси',
  };

  /// Что удаляют: файл и его виды. Значение — вид файла, `null` — любой.
  static const Map<String, FileKind?> _objects = <String, FileKind?>{
    'файл': null,
    'файлы': null,
    'файлик': null,
    'файла': null,
    'результат': null,
    'результаты': null,
    'исходник': null,
    'исходники': null,
    'оригинал': null,
    'оригиналы': null,
    'картинку': FileKind.image,
    'картинки': FileKind.image,
    'изображение': FileKind.image,
    'фото': FileKind.image,
    'фотку': FileKind.image,
    'фотографию': FileKind.image,
    'скриншот': FileKind.image,
    'скрин': FileKind.image,
    'видео': FileKind.video,
    'видеофайл': FileKind.video,
    'ролик': FileKind.video,
    'аудио': FileKind.audio,
    'аудиофайл': FileKind.audio,
    'музыку': FileKind.audio,
    'песню': FileKind.audio,
    'трек': FileKind.audio,
    'архив': FileKind.archive,
    'архивы': FileKind.archive,
    'документ': FileKind.document,
  };

  static const Set<String> _outputWords = <String>{'результат', 'результаты'};

  static const Set<String> _sourceWords = <String>{
    'исходник',
    'исходники',
    'оригинал',
    'оригиналы',
  };

  /// Слово [word] называет файл: «файл», «архив», «видео».
  static bool isObject(String word) => _objects.containsKey(word);

  /// Указатели на файл: «этот», «последний», «только что сделанный».
  static const Set<String> _pointers = <String>{
    'этот',
    'эту',
    'это',
    'этого',
    'эти',
    'последний',
    'последнюю',
    'последнее',
    'последние',
    'новый',
    'новую',
    'готовый',
    'готовую',
    'полученный',
    'полученную',
    'полученное',
    'получившийся',
    'получившуюся',
    'получившееся',
    'конвертированный',
    'конвертированную',
    'сконвертированный',
    'сконвертированную',
    'готовое',
  };

  /// Местоимения вместо файла: «удали его». Только сразу после карточки
  /// расширения — иначе «её» скорее задача.
  static const Set<String> _pronouns = <String>{'его', 'ее', 'это', 'их'};

  static const Set<String> _filler = <String>{
    'мне',
    'пожалуйста',
    'плиз',
    'пж',
    'ка',
    'только',
    'что',
    'из',
    'сессии',
    'файлов',
    'с',
    'устройства',
    'телефона',
    'а',
    'и',
    'ну',
    'давай',
    'теперь',
    'можешь',
    'можете',
    'тогда',
    'сделанный',
    'сделанную',
    'сделанное',
    'сделанные',
    'созданный',
    'созданную',
    'созданное',
    'созданные',
    'скачанный',
    'скачанную',
    'скачанное',
    'скачанные',
    'загруженный',
    'загруженную',
    'загруженное',
    'загруженные',
    // «Удали все файлы»: по одному, с вопросом «Какой файл удалить?».
    'все',
  };

  /// Навыки, после карточки которых «его» — их результат.
  static const Set<String> fileSkills = <String>{
    'converter',
    'archiver',
    'ytdl',
    FilesConnector.id,
  };

  /// Слова других предметов удаления: «удали запись почта из паролей»,
  /// «удали задачу», «удали сессию».
  static const List<String> _otherStems = <String>[
    'парол',
    'запис',
    'задач',
    'напоминани',
    'заметк',
    'сесси',
    'чат',
    'истори',
    'проект',
    'будильник',
    'таймер',
    'сейф',
    'копи',
    'модел',
  ];

  /// Просьба удалить файл в [utterance] или `null`.
  static FileDeleteRequest? parse(Utterance utterance) {
    final tokens = utterance.tokens;
    if (tokens.isEmpty || utterance.isQuestion) return null;
    final verbAt = tokens.indexWhere(
      (UtteranceToken t) => _verbs.contains(t.text),
    );
    if (verbAt < 0) return null;
    // «Сотри «отчёт.pdf»» — с кавычками: имя файла.
    final quoted = utterance.quotedTitles;
    var object = false;
    var pointed = false;
    var pronoun = false;
    FileKind? kind;
    var origin = FileOrigin.any;
    // До глагола — вступление или сам файл: «а теперь удали этот файл»,
    // «этот файл удали».
    for (var i = 0; i < tokens.length; i++) {
      if (i == verbAt) continue;
      final word = tokens[i].text;
      if (_otherStems.any(word.startsWith) &&
          !(word == 'сессии' || word == 'сессия')) {
        return null;
      }
      if (_objects.containsKey(word)) {
        object = true;
        kind ??= _objects[word];
        if (_outputWords.contains(word)) origin = FileOrigin.output;
        if (_sourceWords.contains(word)) origin = FileOrigin.source;
        continue;
      }
      if (i < verbAt) {
        if (_pointers.contains(word)) {
          pointed = true;
          continue;
        }
        if (_filler.contains(word)) continue;
        return null;
      }
      if (_pointers.contains(word)) {
        pointed = true;
        continue;
      }
      if (_pronouns.contains(word)) {
        pronoun = true;
        continue;
      }
      if (_filler.contains(word)) continue;
      // Любое другое слово — другой предмет: «удали файл отчёт из задачи».
      return null;
    }
    if (quoted.length == 1) {
      return FileDeleteRequest(name: quoted.single.text, pointed: true);
    }
    if (quoted.isNotEmpty) return null;
    if (object) {
      return FileDeleteRequest(
        pointed: pointed || pronoun,
        kind: kind,
        origin: origin,
      );
    }
    if (pronoun && fileSkills.contains(utterance.recentConnectorId)) {
      return const FileDeleteRequest(pointed: true);
    }
    return null;
  }
}

/// «Удали этот файл»: вопрос «Удалить «…»?» и удаление по «Удалить».
final class FilesConnector implements Connector, ConnectorHealth {
  FilesConnector();

  static const String id = 'files';

  static const String deleteCommand = 'files.delete';

  /// Явная просьба с «файл»: выше бесед и угадываний задач.
  static const double confidence = 0.85;

  /// «Удали его» сразу после карточки — по контексту.
  static const double pronounConfidence = 0.8;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Файлы сессии',
        description: 'Удаляет результат карточки или вложение из «Файлов '
            'сессии» по просьбе «удали этот файл» — только после '
            'подтверждения. Исходные файлы не трогает.',
        examples: <String>['удали этот файл'],
        access: ConnectorAccess.readWrite,
        kind: ExtensionKind.skill,
        required: true,
      );

  /// Навык локальный: проверять нечего, файлы сессии всегда под рукой.
  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  @override
  ConnectorMatch? match(Utterance utterance) {
    final request = FilesPhrases.parse(utterance);
    if (request == null) return null;
    final byWord = utterance.tokens.any(
      (UtteranceToken t) => FilesPhrases.isObject(t.text),
    );
    return ConnectorMatch(
      connectorId: id,
      commandId: deleteCommand,
      confidence:
          byWord || request.name != null ? confidence : pronounConfidence,
      payload: request,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) return _answer(payload, session);
    final request = payload! as FileDeleteRequest;
    final files = _wanted(session.recentFiles, request);
    if (files.isEmpty) {
      return session.reply(
        session.recentFiles.isEmpty
            ? 'files.delete.none'
            : 'files.delete.noneOfKind',
        intent: deleteCommand,
        status: AssistantStatus.noAction,
      );
    }
    final name = request.name;
    final SessionFileRef file;
    if (name != null) {
      final wanted = name.toLowerCase();
      final found = files
          .where((SessionFileRef f) => f.name.toLowerCase() == wanted)
          .toList();
      if (found.isEmpty) return _which(files, session);
      file = found.first;
    } else if (files.length == 1 || request.pointed) {
      file = files.first;
    } else {
      return _which(files, session);
    }
    return _confirm(file, session);
  }

  /// Файлы сессии под просьбу: нужного вида («архив» — zip, 7z…) и
  /// происхождения. «Результат» предпочитает файлы карточек, но если их нет,
  /// подходит любой; «исходник» — только вложения.
  static List<SessionFileRef> _wanted(
    List<SessionFileRef> files,
    FileDeleteRequest request,
  ) {
    final kind = request.kind;
    var result = kind == null
        ? files
        : files.where((SessionFileRef f) => kind.matches(f.name)).toList();
    switch (request.origin) {
      case FileOrigin.any:
        break;
      case FileOrigin.output:
        final outputs = result.where((SessionFileRef f) => f.output).toList();
        if (outputs.isNotEmpty) result = outputs;
      case FileOrigin.source:
        result = result.where((SessionFileRef f) => !f.output).toList();
    }
    return result;
  }

  /// «Какой файл удалить: «a.jpg», «b.mp3» или «c.zip»?».
  AssistantResponse _which(
    List<SessionFileRef> files,
    AssistantSession session,
  ) {
    final shown = files.take(3).toList();
    if (shown.length < 2) return _confirm(shown.single, session);
    final clarification = Clarification(
      questionId: 'files.delete.which',
      options: <ClarifyOption>[
        for (final file in shown)
          ClarifyOption(
            label: file.name,
            text: 'удали файл «${file.name}»',
            connectorId: id,
          ),
      ],
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: deleteCommand,
        payload: clarification,
      ),
    );
    return session.reply(
      clarification.questionId,
      values: <String, String>{'options': clarification.optionsText},
      intent: deleteCommand,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  /// «Удалить «…» из файлов сессии?» с кнопками «Удалить» и «Отмена».
  AssistantResponse _confirm(SessionFileRef file, AssistantSession session) {
    final downloads = file.output && file.extensionId == 'ytdl';
    final questionId = !file.output
        ? 'files.delete.confirm.attachment'
        : downloads
            ? 'files.delete.confirm.downloads'
            : 'files.delete.confirm';
    final clarification = Clarification(
      questionId: questionId,
      options: const <ClarifyOption>[
        ClarifyOption(
          label: 'Удалить',
          text: 'Удалить',
          answers: <String>{'удали', 'удалить', 'удаляй', 'стирай', 'сотри'},
          connectorId: id,
          answer: true,
        ),
        ClarifyOption(
          label: 'Отмена',
          text: 'Отмена',
          answers: <String>{'отмени', 'отменить', 'оставь', 'оставить'},
          connectorId: id,
          answer: false,
        ),
      ],
      context: file,
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: deleteCommand,
        itemId: file.id,
        payload: clarification,
      ),
    );
    return session.reply(
      questionId,
      values: <String, String>{
        'name': file.name,
        if (downloads) 'folder': 'Загрузки',
      },
      intent: deleteCommand,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  Future<AssistantResponse> _answer(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) async {
    final clarification = answer.pending.payload;
    final file = clarification is Clarification ? clarification.context : null;
    if (file is! SessionFileRef || !answer.confirmed) {
      return session.reply(
        'files.delete.cancelled',
        intent: deleteCommand,
        status: AssistantStatus.noAction,
      );
    }
    final remover = session.fileRemover;
    if (remover == null) {
      return session.reply(
        'files.delete.unavailable',
        intent: deleteCommand,
        status: AssistantStatus.noAction,
      );
    }
    final removed = await remover.remove(file);
    return session.reply(
      removed ? 'files.delete.done' : 'files.delete.failed',
      values: <String, String>{'name': file.name},
      intent: deleteCommand,
      status: removed ? AssistantStatus.completed : AssistantStatus.failed,
    );
  }
}
