/// Навык-расширение «Конвертер» (docs/PLANS.md, «Конвертер»; ADR-024,
/// шаг 2; ADR-026): картинки png/jpeg/webp/bmp/gif → png/jpeg на Dart
/// везде (с качеством JPEG и уменьшением), звук и видео → mp3, m4a, wav,
/// mp4, mov, webm или кадр — с битрейтом, размером и качеством; через
/// скачиваемый ffmpeg на Windows и Linux, средствами системы на телефоне и
/// Mac, где они есть ([ConvertCaps]). Выключен по умолчанию, ведёт его
/// Лиорио. Фраза открывает в чате карточку-форму ([ExtensionCard]): файл →
/// во что → качество → «Запустить»; «в mp3 320» заполняет и качество.
library;

import '../../connectors/connector.dart';
import '../../jobs/extension_card.dart';
import '../ytdl/ytdl_formats.dart';
import 'convert_targets.dart';

export 'convert_targets.dart';
export 'image_convert.dart';

/// Что конвертер знает об устройстве: платформа, готов ли ffmpeg и что
/// умеет система. Только для текста ответа — варианты карточки считает
/// [ExtensionForms].
abstract interface class ConverterEnvironment {
  JobPlatform get platform;

  /// ffmpeg скачан и установлен.
  bool get ffmpegReady;

  /// Что умеют кодировщики системы (телефон, Mac).
  NativeMediaCaps get native;
}

/// Что поняли из фразы: цель, тип исходника, качество и формат, который
/// конвертер не делает («в flac»).
typedef ConvertRequest = ({
  String? target,
  MediaKind? kind,
  Map<String, String> options,
  String? unoffered,
});

final class ConverterConnector
    implements Connector, FormConnector, IntentTarget {
  ConverterConnector({this.environment});

  static const String id = ExtensionForms.converter;

  static const String convertCommand = 'converter.convert';

  /// Глагол и объект: явная команда.
  static const double confidence = 0.9;

  /// `null` — ответ без оглядки на платформу (корпус, тесты).
  final ConverterEnvironment? environment;

  int _counter = 0;

  @override
  ConnectorInfo get info => ConnectorInfo(
        id: id,
        title: 'Конвертер',
        description: _description(environment?.platform),
        examples: const <String>[
          'сконвертируй в mp3',
          'конвертируй фото в png',
          'сконвертируй видео в mp3 320',
          'сконвертируй файл',
        ],
        kind: ExtensionKind.skill,
        defaultEnabled: false,
        offHint: true,
      );

  static String _description(JobPlatform? platform) {
    const images = 'Картинки png, jpeg, webp, bmp, gif → png или jpeg, с '
        'качеством и уменьшением.';
    const keep = ' Исходный файл не меняется.';
    return switch (platform) {
      JobPlatform.windows || JobPlatform.linux => '$images Звук и видео → '
          'mp3, m4a, wav, mp4, mov, webm или кадр — с битрейтом, размером и '
          'качеством, через ffmpeg.$keep',
      JobPlatform.android ||
      JobPlatform.macos =>
        '$images Звук и видео — средствами системы, где они есть.$keep',
      JobPlatform.ios => '$images$keep',
      null => '$images Звук и видео → mp3, m4a, wav, mp4 или кадр — с '
          'битрейтом, размером и качеством.$keep',
    };
  }

  /// Как выполнить команду по подсказке запасного слоя (ADR-045).
  static const Map<String, IntentRecipe> intentRecipes = <String, IntentRecipe>{
    'converter.convert': IntentRecipe(
      carriers: <String>['сконвертируй'],
      ask: 'сконвертируй файл',
      example: 'сконвертируй видео в mp3',
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
    if (!ConverterPhrases.matches(utterance)) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: convertCommand,
      confidence: confidence,
      payload: ConverterPhrases.requestOf(utterance),
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final request = switch (match.payload) {
      final ConvertRequest r => r,
      _ => (
          target: null,
          kind: null,
          options: const <String, String>{},
          unoffered: null,
        ),
    };
    return _form(request, session, prefill: true);
  }

  @override
  AssistantResponse openForm(String? action, AssistantSession session) => _form(
        (
          target: action,
          kind: null,
          options: const <String, String>{},
          unoffered: null,
        ),
        session,
        prefill: false,
      );

  AssistantResponse _form(
    ConvertRequest request,
    AssistantSession session, {
    required bool prefill,
  }) {
    final now = session.clock.now();
    final card = ExtensionCard(
      id: 'j${now.microsecondsSinceEpoch}_${_counter++}',
      extensionId: id,
      updatedAt: now,
    );
    final file = prefill ? _prefill(session, request.kind) : null;
    if (file != null) card.setValue('file', <JobFile>[file]);
    var target = ConverterPhrases.forSource(
      request.target,
      file == null ? null : ConvertTargets.kindOf(file.name),
    );
    // «Сожми фото до 1920» без формата: тот же формат, видео — в mp4.
    if (target == null && file != null && request.options.isNotEmpty) {
      target = _sameOrDefault(file.name);
    }
    // Файла ещё нет, но качество сказано: «уменьши видео до 720p» — в
    // mp4, «сожми фото до 1920» — в jpeg; формат в карточке можно сменить.
    if (target == null && file == null && request.options.isNotEmpty) {
      target = switch (request.kind) {
        MediaKind.video => ConvertTargets.mp4,
        MediaKind.image => ConvertTargets.jpeg,
        _ => null,
      };
    }
    // Цель из фразы — если она подходит файлу (или файла ещё нет).
    if (target != null &&
        (file == null ||
            ConvertTargets.targetsFor(file.name).contains(target))) {
      card.setValue('target', target);
    }
    // Качество из фразы — то, что относится к цели (или цели ещё нет).
    final chosen = card.choice('target');
    final source = file == null ? null : ConvertTargets.kindOf(file.name);
    final codes =
        chosen == null ? null : ConvertQuality.codesFor(chosen, source).toSet();
    final applied = <String, String>{
      for (final MapEntry(:key, :value) in request.options.entries)
        if (codes == null || codes.contains(key)) key: value,
    };
    for (final MapEntry(:key, :value) in applied.entries) {
      card.setValue(key, value);
    }
    final env = environment;
    final platform = env?.platform;
    final tools = <String>{
      if (env?.ffmpegReady ?? false) ConvertTargets.ffmpeg,
      ...?env?.native.toTools(),
    };
    if (platform != null) {
      ExtensionForms.resolve(card, platform, tools: tools);
      // Подставленные значения по умолчанию — не из фразы: в карточке они
      // остаются, а в ответе называется только сказанное.
    } else if (file != null && chosen == null) {
      final targets = ConvertTargets.targetsFor(file.name);
      if (targets.length == 1) card.setValue('target', targets.single);
    }
    var key = 'converter.form';
    var values = <String, String>{};
    final picked = card.choice('target');
    if (request.unoffered case final String format) {
      key = 'converter.unavailable.format';
      values = <String, String>{
        'format': format,
        'formats': _formats(platform, tools),
      };
    } else if (file != null &&
        ConvertTargets.kindOf(file.name) == MediaKind.unknown) {
      key = 'converter.unsupported';
      values = <String, String>{'formats': _formats(platform, tools)};
    } else if (_mediaAsked(file, picked ?? (file == null ? target : null))
        case final String asked when platform != null) {
      final route = ConvertCaps.route(
        platform: platform,
        tools: tools,
        source: source ?? _sourceFor(asked),
        target: asked,
        sourceName: file?.name,
      );
      switch (route.block) {
        case ConvertBlock.impossible:
          key = 'converter.unavailable.target';
          values = <String, String>{
            'format': ConvertTargets.shortLabel(asked),
            'reason': ConvertCaps.impossibleWhy(platform, asked),
          };
        case ConvertBlock.deviceLacks:
          key = 'converter.unavailable.target';
          values = <String, String>{
            'format': ConvertTargets.shortLabel(asked),
            'reason': ConvertCaps.lacksWhy(asked),
          };
        case ConvertBlock.sourceUnreadable:
          key = 'converter.unreadable';
          values = <String, String>{
            'format': ConvertTargets.extensionOf(file!.name).toUpperCase(),
            'hint': ConvertCaps.unreadableHint(platform),
          };
        case ConvertBlock.noTool:
          key = 'converter.noTool';
        case ConvertBlock.imagesOnly:
          key = 'converter.imagesOnly';
        case null:
          break;
      }
    }
    // Файл и формат уже выбраны — просить «выберите» незачем.
    if (key == 'converter.form' &&
        (applied.isNotEmpty || (file != null && picked != null))) {
      key = 'converter.form.quality';
      values = <String, String>{
        'quality': <String>[
          if (picked != null) ConvertTargets.shortLabel(picked),
          for (final field in ConvertQuality.fields)
            if (applied[field.code] case final String value)
              ConvertQuality.phraseLabel(field.code, value),
        ].join(', '),
      };
    }
    return session.reply(
      key,
      values: values,
      intent: convertCommand,
      status: AssistantStatus.completed,
      job: card,
    );
  }

  /// Цель [target], если ей нужен не Dart (звук, видео, кадр); иначе
  /// `null`.
  static String? _mediaAsked(JobFile? file, String? target) {
    if (target == null) return null;
    final dart = file != null
        ? ConvertTargets.dartFor(file.name, target)
        : ConvertTargets.isImageTarget(target);
    return dart ? null : target;
  }

  /// Цель «того же формата» для фразы без формата: jpg → JPEG, png → PNG,
  /// mp3 → MP3, видео → MP4.
  static String? _sameOrDefault(String name) {
    final targets = ConvertTargets.targetsFor(name);
    for (final target in targets) {
      if (ConvertTargets.sameFormat(name, target)) return target;
    }
    return switch (ConvertTargets.kindOf(name)) {
      MediaKind.image => ConvertTargets.jpeg,
      MediaKind.video => ConvertTargets.mp4,
      _ => null,
    };
  }

  /// Исходник, из которого обычно делают [target] (файла ещё нет).
  static MediaKind _sourceFor(String target) =>
      ConvertTargets.videoTargets.contains(target) ||
              ConvertTargets.isFrame(target)
          ? MediaKind.video
          : MediaKind.audio;

  /// Что здесь делается, для текста ответа: «картинки — в png или jpeg;
  /// звук и видео — в mp3, m4a, wav».
  static String _formats(JobPlatform? platform, Set<String> tools) {
    const images = 'картинки png, jpeg, webp, bmp, gif — в png или jpeg';
    final media = platform == null
        ? const <String>[
            ConvertTargets.mp3,
            ConvertTargets.m4a,
            ConvertTargets.wav,
            ConvertTargets.mp4,
            ConvertTargets.frameJpeg,
          ]
        : ConvertCaps.mediaTargets(platform, tools);
    if (media.isEmpty) return '$images; звук и видео здесь недоступны';
    return '$images; звук и видео — в ${ConvertCaps.mediaNames(media)}';
  }

  /// Файл для карточки: последний подходящий из сообщения, иначе из
  /// недавних сообщений сессии. [wanted] — тип из фразы («фото»,
  /// «видео»): тогда только такого типа.
  static JobFile? _prefill(AssistantSession session, MediaKind? wanted) {
    for (final files in <List<JobFile>>[
      session.attachments,
      session.recentAttachments,
    ]) {
      for (final file in files.reversed) {
        if (file.folder) continue;
        final kind = ConvertTargets.kindOf(file.name);
        if (wanted != null ? kind == wanted : kind != MediaKind.unknown) {
          return file;
        }
      }
    }
    // В сообщении один файл неизвестного типа — честно скажем, что его
    // формат пока не поддерживается.
    if (wanted == null && session.attachments.length == 1) {
      final only = session.attachments.single;
      if (!only.folder) return only;
    }
    return null;
  }
}

/// Фразы конвертера: повелительное наклонение и объект — «сконвертируй в
/// mp3», «конвертируй фото в png», «сконвертируй файл». «Переведи» и
/// «перегони» — только с форматом («переведи видео в mp3»): «переведи 100
/// долларов в рубли», «переведи файл на английский» — не его фразы.
/// Инфинитив («сконвертировать видео»), задачи и напоминания — тоже.
abstract final class ConverterPhrases {
  static const Set<String> _fillers = <String>{
    'пожалуйста',
    'давай',
    'теперь',
    'а',
    'и',
    'ну',
    'еще',
  };

  /// Глаголы, которым хватает объекта («сконвертируй файл»).
  static const Set<String> _convertVerbs = <String>{
    'сконвертируй',
    'сконвертируйте',
    'конвертируй',
    'конвертируйте',
    'переконвертируй',
    'переконвертируйте',
    'конвертни',
    'преобразуй',
    'преобразуйте',
  };

  /// Глаголы, которым нужен формат («переведи видео в mp3»).
  static const Set<String> _formatVerbs = <String>{
    'переведи',
    'переведите',
    'перегони',
    'перегоните',
    'сохрани',
    'сохраните',
  };

  /// Слова «формат», которые сами по себе — цель без названия.
  static bool _isFormatWord(String w) => w.startsWith('формат');

  /// Тип файла по слову («фото» — картинка) или `null`; «файл» — любой.
  static MediaKind? _kindWord(String w) {
    if (w.startsWith('фото') ||
        w.startsWith('фотк') ||
        w.startsWith('картинк') ||
        w.startsWith('изображени') ||
        w.startsWith('скриншот') ||
        w == 'гифку' ||
        w == 'гифка') {
      return MediaKind.image;
    }
    if (w.startsWith('видео') ||
        w.startsWith('ролик') ||
        w.startsWith('клип') ||
        w.startsWith('фильм')) {
      return MediaKind.video;
    }
    if (w.startsWith('аудио') ||
        w.startsWith('звук') ||
        w.startsWith('песн') ||
        w.startsWith('трек') ||
        w.startsWith('музык')) {
      return MediaKind.audio;
    }
    return null;
  }

  static bool _isFile(String w) => w.startsWith('файл');

  /// Слова после глагола и без вводных; `null` — фраза не команда.
  static (String, List<String>)? _split(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty || words.length > 12) return null;
    // Фраза со ссылкой — не файл конвертеру («сохрани видео https://… в
    // mp3» — загрузчик видео).
    if (YtdlUrl.find(utterance.original) != null) return null;
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
    return (words[start], words.sublist(start + 1));
  }

  /// Глаголы «уменьшить»: только с типом файла и качеством («сожми фото
  /// до 1920», «уменьши видео до 720p»). «Сожми файлы» — архиватор.
  static const Set<String> _shrinkVerbs = <String>{
    'уменьши',
    'уменьшите',
    'сожми',
    'сожмите',
    'пережми',
    'пережмите',
  };

  /// «Сделай из видео mp3»: нужен «из» с объектом и формат.
  static const Set<String> _makeVerbs = <String>{'сделай', 'сделайте'};

  /// Формат во фразе «сделай из видео mp3» — первое слово-формат после
  /// «из <объект>».
  static String? _madeTarget(List<String> rest, {bool unoffered = false}) {
    final from = rest.indexOf('из');
    if (from < 0 || from + 1 >= rest.length) return null;
    final what = rest[from + 1];
    if (!_isFile(what) && _kindWord(what) == null) return null;
    for (final w in rest.skip(from + 2)) {
      final target = unoffered
          ? ConvertTargets.unofferedWord(_madeWord(w))
          : ConvertTargets.fromWord(w);
      if (target != null) return target;
    }
    return null;
  }

  /// «Гифку», «гифка» после «сделай из видео» — формат GIF, а не тип
  /// исходного файла.
  static String _madeWord(String w) => w.startsWith('гифк') ? 'гиф' : w;

  /// Индекс слова после «в»/«во», которое — формат; иначе -1.
  static int _targetAt(List<String> rest, {bool unoffered = false}) {
    for (var i = 0; i + 1 < rest.length; i++) {
      // «Сохрани картинку как png» — то же, что «в png».
      if (rest[i] != 'в' && rest[i] != 'во' && rest[i] != 'как') continue;
      // «в формат mp3», «в формате mp3»: формат — следующее слово.
      final at =
          _isFormatWord(rest[i + 1]) && i + 2 < rest.length ? i + 2 : i + 1;
      final word = rest[at];
      if (ConvertTargets.fromWord(word) != null) return at;
      if (unoffered && ConvertTargets.unofferedWord(word) != null) {
        return at;
      }
    }
    return -1;
  }

  /// Цель после «в»: «в mp3», «в jpg».
  static String? _targetIn(List<String> rest) {
    final at = _targetAt(rest);
    return at < 0 ? null : ConvertTargets.fromWord(rest[at]);
  }

  /// Формат, который конвертер не делает, после «в»: «в flac».
  static String? _unofferedIn(List<String> rest) {
    if (_targetAt(rest) >= 0) return null;
    final at = _targetAt(rest, unoffered: true);
    return at < 0 ? null : ConvertTargets.unofferedWord(rest[at]);
  }

  /// Фраза — команда конвертера.
  static bool matches(Utterance utterance) {
    final split = _split(utterance);
    if (split == null) return false;
    final (verb, rest) = split;
    final target = _targetIn(rest) ?? _unofferedIn(rest);
    if (_convertVerbs.contains(verb)) {
      return target != null ||
          rest.any(
            (String w) =>
                _isFile(w) || _kindWord(w) != null || _isFormatWord(w),
          );
    }
    if (_formatVerbs.contains(verb)) {
      // «Сохрани фото в png», «перегони видео в mp4»: нужен формат и
      // объект — «сохрани в mp3» без объекта тоже понятно.
      if (target == null) return false;
      if (verb.startsWith('сохран')) {
        return rest.any((String w) => _isFile(w) || _kindWord(w) != null);
      }
      return true;
    }
    if (_makeVerbs.contains(verb)) {
      return _madeTarget(rest) != null ||
          _madeTarget(rest, unoffered: true) != null;
    }
    if (_shrinkVerbs.contains(verb)) {
      final kind = rest.map(_kindWord).nonNulls.firstOrNull;
      if (kind != MediaKind.image && kind != MediaKind.video) return false;
      return optionsOf(rest, _targetIn(rest), kind: kind).isNotEmpty;
    }
    return false;
  }

  /// Цель из фразы («в mp3») или `null`.
  static String? targetOf(Utterance utterance) => requestOf(utterance).target;

  /// Всё, что поняли из фразы, для карточки.
  static ConvertRequest requestOf(Utterance utterance) {
    final split = _split(utterance);
    if (split == null) {
      return (
        target: null,
        kind: null,
        options: const <String, String>{},
        unoffered: null,
      );
    }
    final (verb, rest) = split;
    var target = _makeVerbs.contains(verb) && _targetIn(rest) == null
        ? _madeTarget(rest)
        : _targetIn(rest);
    final kind = kindOf(utterance);
    target = forSource(target, kind);
    return (
      target: target,
      kind: kind,
      options: optionsOf(rest, target, kind: kind),
      unoffered: _unofferedIn(rest) ??
          (target == null && _makeVerbs.contains(verb)
              ? _madeTarget(rest, unoffered: true)
              : null),
    );
  }

  /// «Видео в jpg» — это кадр: картинка из видео делается кадром
  /// (`frame-jpeg`, `frame-png`); остальное — как есть.
  static String? forSource(String? target, MediaKind? source) =>
      source != MediaKind.video
          ? target
          : switch (target) {
              ConvertTargets.jpeg => ConvertTargets.frameJpeg,
              ConvertTargets.png => ConvertTargets.framePng,
              _ => target,
            };

  /// Числа рядом с этими словами — не качество: «320 рублей», «на 5
  /// минут», «10 штук».
  static bool _notQuality(String w) =>
      w.startsWith('рубл') ||
      w.startsWith('руб') ||
      w.startsWith('доллар') ||
      w.startsWith('евро') ||
      w.startsWith('минут') ||
      w.startsWith('секунд') ||
      w.startsWith('час') ||
      w.startsWith('штук') ||
      w.startsWith('процент') ||
      w.startsWith('градус') ||
      w.startsWith('раз');

  static bool _kbpsWord(String w) =>
      w == 'кбит' ||
      w == 'кб' ||
      w == 'kbps' ||
      w == 'kbit' ||
      w == 'k' ||
      w == 'к' ||
      w == 'кбитс' ||
      w == 'кбпс';

  static bool _pxWord(String w) =>
      w == 'px' || w == 'пикс' || w.startsWith('пиксел') || w == 'пкс';

  /// Качество из слов фразы после глагола ([rest]): битрейт («320»,
  /// «320 кбит/с», «320k»), размер видео («720p», «full hd»), качество JPEG
  /// («качество 85»), размер картинки («до 1920», «1920px»), слова
  /// («лучшее качество», «экономно»). [target] — цель из фразы, [kind] —
  /// тип исходника. Только допустимые значения ([ConvertQuality]).
  static Map<String, String> optionsOf(
    List<String> rest,
    String? target, {
    MediaKind? kind,
  }) {
    final out = <String, String>{};
    final audioTarget =
        target == ConvertTargets.mp3 || target == ConvertTargets.m4a;
    final videoTarget = ConvertTargets.videoTargets.contains(target) ||
        (target == null && kind == MediaKind.video);
    final imageTarget = target == ConvertTargets.jpeg ||
        target == ConvertTargets.png ||
        (target == null && kind == MediaKind.image);
    final jpegTarget = target == ConvertTargets.jpeg ||
        target == ConvertTargets.frameJpeg ||
        (target == null && kind == MediaKind.image);
    final at = _targetAt(rest);
    for (var i = 0; i < rest.length; i++) {
      if (i == at) continue;
      final w = rest[i];
      final next = i + 1 < rest.length ? rest[i + 1] : '';
      final prev = i > 0 ? rest[i - 1] : '';
      if (_notQuality(next)) continue;
      // Разрешение видео: 1080p, 720р, «full hd», «hd».
      final res = RegExp(r'^(1080|720|480)(p|р)$').firstMatch(w);
      if (res != null && (videoTarget || target == null)) {
        out[ConvertQuality.videoRes] = res.group(1)!;
        continue;
      }
      if ((w == 'full' || w == 'фулл') && (next == 'hd' || next == 'хд')) {
        if (videoTarget) out[ConvertQuality.videoRes] = '1080';
        i++;
        continue;
      }
      if ((w == 'hd' || w == 'хд') && prev != 'full' && prev != 'фулл') {
        if (videoTarget) out[ConvertQuality.videoRes] = '720';
        continue;
      }
      // Число со склеенной единицей: 320k, 320кбит, 1920px.
      final glued =
          RegExp(r'^(\d{2,4})(k|к|kbps|кбит|кб|px|пикс|пкс)$').firstMatch(w);
      final number = glued != null
          ? int.parse(glued.group(1)!)
          : RegExp(r'^\d{2,4}$').hasMatch(w)
              ? int.parse(w)
              : null;
      if (number == null) continue;
      final unit = glued?.group(2) ?? next;
      final kbps = glued != null
          ? const <String>{'k', 'к', 'kbps', 'кбит', 'кб'}.contains(unit)
          : _kbpsWord(unit);
      final px = glued != null
          ? const <String>{'px', 'пикс', 'пкс'}.contains(unit)
          : _pxWord(unit);
      final quality = prev.startsWith('качеств') ||
          prev == 'jpg' ||
          prev == 'jpeg' ||
          prev == 'джпг';
      if (audioTarget && (kbps || (!px && !quality && number >= 96))) {
        if (number >= 64 && number <= 320) {
          out[ConvertQuality.audioKbps] =
              '${ConvertQuality.nearest(number, ConvertQuality.kbpsPresets)}';
        }
        continue;
      }
      if (videoTarget &&
          const <int>[1080, 720, 480].contains(number) &&
          !px &&
          !kbps) {
        out[ConvertQuality.videoRes] = '$number';
        continue;
      }
      if (jpegTarget && quality && number <= 100) {
        out[ConvertQuality.jpegQuality] =
            '${ConvertQuality.nearest(number, ConvertQuality.jpegPresets)}';
        continue;
      }
      if (imageTarget &&
          (px || prev == 'до') &&
          number >= 640 &&
          number <= 8000) {
        out[ConvertQuality.imageSize] =
            '${ConvertQuality.nearest(number, ConvertQuality.sizePresets)}';
      }
    }
    // Слова о качестве: «в лучшем качестве», «экономно», «поменьше».
    final best = rest.any(
      (String w) =>
          w.startsWith('лучш') ||
          w.startsWith('максимальн') ||
          w.startsWith('наилучш') ||
          (w.startsWith('высок') &&
              rest.any((String x) => x.startsWith('качеств'))),
    );
    final small = rest.any(
      (String w) =>
          w.startsWith('эконом') ||
          w.startsWith('сжат') ||
          w == 'поменьше' ||
          w.startsWith('компактн'),
    );
    if (best != small) {
      if (audioTarget) {
        out.putIfAbsent(ConvertQuality.audioKbps, () => best ? '320' : '128');
      }
      if (videoTarget) {
        out.putIfAbsent(
          ConvertQuality.videoQuality,
          () => best ? ConvertQuality.high : ConvertQuality.eco,
        );
      }
      if (jpegTarget) {
        out.putIfAbsent(ConvertQuality.jpegQuality, () => best ? '95' : '60');
      }
    }
    return out;
  }

  /// Тип файла из фразы («фото», «видео») или `null`.
  static MediaKind? kindOf(Utterance utterance) {
    final split = _split(utterance);
    if (split == null) return null;
    final (_, rest) = split;
    // «Звук из видео в mp3» — исходник видео.
    for (final w in rest) {
      if (w == 'из') {
        final i = rest.indexOf(w);
        if (i + 1 < rest.length) {
          final kind = _kindWord(rest[i + 1]);
          if (kind != null) return kind;
        }
      }
    }
    for (final w in rest) {
      final kind = _kindWord(w);
      if (kind != null) return kind;
    }
    return null;
  }
}
