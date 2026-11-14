/// Навык-расширение «Конвертер» (docs/PLANS.md, «Конвертер»; ADR-024,
/// шаг 2): картинки png/jpeg/webp/bmp/gif → png/jpeg на Dart везде, звук
/// и видео → mp3, mp4, webm, кадр — через скачиваемый ffmpeg только на
/// Windows и Linux. Выключен по умолчанию, ведёт его Лиорио. Фраза
/// открывает в чате карточку-форму ([ExtensionCard]): файл → во что →
/// «Запустить».
library;

import '../../connectors/connector.dart';
import '../../jobs/extension_card.dart';
import '../ytdl/ytdl_formats.dart';
import 'convert_targets.dart';

export 'convert_targets.dart';
export 'image_convert.dart';

/// Что конвертер знает об устройстве: платформа и готов ли ffmpeg. Только
/// для текста ответа — варианты карточки считает [ExtensionForms].
abstract interface class ConverterEnvironment {
  JobPlatform get platform;

  /// ffmpeg скачан и установлен.
  bool get ffmpegReady;
}

final class ConverterConnector implements Connector, FormConnector {
  ConverterConnector({this.environment});

  static const String id = ExtensionForms.converter;

  static const String convertCommand = 'converter.convert';

  /// Глагол и объект: явная команда.
  static const double confidence = 0.9;

  /// `null` — ответ без оглядки на ffmpeg (корпус, тесты).
  final ConverterEnvironment? environment;

  int _counter = 0;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Конвертер',
        description: 'Картинки png, jpeg, webp, bmp, gif → png или jpeg. '
            'Звук и видео → mp3, mp4, webm или кадр — с ffmpeg на Windows и '
            'Linux. Исходный файл не меняется.',
        examples: <String>[
          'сконвертируй в mp3',
          'конвертируй фото в png',
          'сконвертируй файл',
        ],
        kind: ExtensionKind.skill,
        defaultEnabled: false,
        offHint: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (!ConverterPhrases.matches(utterance)) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: convertCommand,
      confidence: confidence,
      payload: (
        ConverterPhrases.targetOf(utterance),
        ConverterPhrases.kindOf(utterance),
      ),
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final (target, kind) = switch (match.payload) {
      (final String? target, final MediaKind? kind) => (target, kind),
      _ => (null, null),
    };
    return _form(target, kind, session, prefill: true);
  }

  @override
  AssistantResponse openForm(String? action, AssistantSession session) =>
      _form(action, null, session, prefill: false);

  AssistantResponse _form(
    String? target,
    MediaKind? wanted,
    AssistantSession session, {
    required bool prefill,
  }) {
    final now = session.clock.now();
    final card = ExtensionCard(
      id: 'j${now.microsecondsSinceEpoch}_${_counter++}',
      extensionId: id,
      updatedAt: now,
    );
    final file = prefill ? _prefill(session, wanted) : null;
    if (file != null) card.setValue('file', <JobFile>[file]);
    // Цель из фразы — если она подходит файлу (или файла ещё нет).
    if (target != null &&
        (file == null ||
            ConvertTargets.targetsFor(file.name).contains(target))) {
      card.setValue('target', target);
    } else if (file != null) {
      final targets = ConvertTargets.targetsFor(file.name);
      if (targets.length == 1) card.setValue('target', targets.single);
    }
    var key = 'converter.form';
    if (file != null && ConvertTargets.kindOf(file.name) == MediaKind.unknown) {
      key = 'converter.unsupported';
    } else if (environment case final ConverterEnvironment env) {
      final chosen = card.choice('target');
      final needsTool = file != null
          ? chosen != null && ConvertTargets.needsFfmpegFor(file.name, chosen)
          : target != null && ConvertTargets.needsFfmpeg(target);
      if (needsTool &&
          ExtensionForms.ffmpegReason(
                env.platform,
                <String>{if (env.ffmpegReady) ConvertTargets.ffmpeg},
              ) !=
              null) {
        key = ExtensionForms.ffmpegPlatform(env.platform)
            ? 'converter.noTool'
            : 'converter.imagesOnly';
      }
    }
    return session.reply(
      key,
      intent: convertCommand,
      status: AssistantStatus.completed,
      job: card,
    );
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

  /// Цель после «в»: «в mp3», «в jpg».
  static String? _targetIn(List<String> rest) {
    for (var i = 0; i + 1 < rest.length; i++) {
      if (rest[i] != 'в' && rest[i] != 'во') continue;
      final target = ConvertTargets.fromWord(rest[i + 1]);
      if (target != null) return target;
    }
    return null;
  }

  /// Фраза — команда конвертера.
  static bool matches(Utterance utterance) {
    final split = _split(utterance);
    if (split == null) return false;
    final (verb, rest) = split;
    final target = _targetIn(rest);
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
    return false;
  }

  /// Цель из фразы («в mp3») или `null`.
  static String? targetOf(Utterance utterance) {
    final split = _split(utterance);
    return split == null ? null : _targetIn(split.$2);
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
