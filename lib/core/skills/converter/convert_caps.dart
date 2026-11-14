/// Что конвертер делает на какой платформе (ADR-024, ADR-026) — одна
/// честная таблица для карточки, ответов Лиорио и выбора исполнителя:
///
/// - картинка → png/jpeg — на Dart везде;
/// - звук и видео на Windows и Linux — скачиваемым ffmpeg;
/// - на телефоне и Mac — средствами системы, когда они есть в сборке
///   ([NativeMediaCaps]: система сама сообщает, что умеет);
/// - WebM на телефоне и Mac, MOV на телефоне не делаются вовсе: в системе
///   нет нужного кодировщика — так и говорится, без молчаливой ошибки.
///
/// Без вызовов платформы внутри: всё приходит параметрами.
library;

import '../../jobs/extension_forms.dart';
import 'convert_targets.dart';

/// Кто делает задачу.
enum ConvertBackend {
  /// Картинки на Dart в изоляте.
  dart,

  /// Скачанный ffmpeg (Windows, Linux).
  ffmpeg,

  /// Средства системы (Android, macOS).
  native,
}

/// Почему цель здесь недоступна.
enum ConvertBlock {
  /// Нужен ffmpeg, а он не скачан (Windows, Linux).
  noTool,

  /// На этой платформе звук и видео пока не конвертируются.
  imagesOnly,

  /// На этой платформе этот формат не делается вовсе.
  impossible,

  /// Система делает звук и видео, но этот формат — нет: например, не
  /// загрузился встроенный кодировщик MP3 или нет кодировщика H.264.
  deviceLacks,

  /// Исходник этого формата система не открывает (WebM, MKV, AVI, OGG и
  /// Opus на Mac; AVI на телефоне — кроме MP4).
  sourceUnreadable,
}

/// Что система телефона или Mac сообщила о своих кодировщиках. Приходит
/// одним вызовом при запуске; в тестах и на других платформах — [none].
///
/// Через карточку и проверку «можно ли запускать» оно идёт в наборе
/// установленных программ ([toTools]/[fromTools]): так у полей формы одна
/// и та же подпись.
final class NativeMediaCaps {
  const NativeMediaCaps({
    this.targets = const <String>{},
    this.video1080 = true,
  });

  /// Ничего системного: звук и видео на телефоне и Mac недоступны.
  static const NativeMediaCaps none = NativeMediaCaps();

  /// Цели, которые система делает.
  final Set<String> targets;

  /// Есть кодировщик H.264 на 1080p.
  final bool video1080;

  static const String _prefix = 'native:';
  static const String _no1080 = 'native-no-1080';

  /// Записи для набора установленных программ.
  Set<String> toTools() => <String>{
        for (final target in targets) '$_prefix$target',
        if (targets.isNotEmpty && !video1080) _no1080,
      };

  /// Из набора установленных программ.
  static NativeMediaCaps fromTools(Set<String> tools) {
    final targets = <String>{
      for (final tool in tools)
        if (tool.startsWith(_prefix)) tool.substring(_prefix.length),
    };
    if (targets.isEmpty) return none;
    return NativeMediaCaps(
      targets: targets,
      video1080: !tools.contains(_no1080),
    );
  }
}

/// Итог [ConvertCaps.route]: исполнитель или причина, почему нельзя.
final class ConvertRoute {
  const ConvertRoute.run(ConvertBackend this.backend) : block = null;

  const ConvertRoute.blocked(ConvertBlock this.block) : backend = null;

  final ConvertBackend? backend;
  final ConvertBlock? block;

  bool get runnable => backend != null;
}

abstract final class ConvertCaps {
  /// Где цель [target] для исходника [source] сделать нельзя никогда.
  static bool impossible(JobPlatform platform, String target) =>
      switch (platform) {
        JobPlatform.android =>
          target == ConvertTargets.webm || target == ConvertTargets.mov,
        JobPlatform.macos => target == ConvertTargets.webm,
        _ => false,
      };

  /// Расширения исходников, которые AVFoundation на Mac не открывает.
  static const Set<String> _macUnreadable = <String>{
    'webm',
    'mkv',
    'avi',
    'ogg',
    'oga',
    'opus',
  };

  /// Исходник [name] система [platform] не откроет для [target]: на Mac —
  /// WebM, MKV, AVI, OGG, Opus; на телефоне AVI читает только путь MP4
  /// (Media3), а системный разборщик звука и кадров — нет.
  static bool unreadable(JobPlatform platform, String name, String target) {
    final ext = ConvertTargets.extensionOf(name);
    return switch (platform) {
      JobPlatform.macos => _macUnreadable.contains(ext),
      JobPlatform.android => ext == 'avi' && target != ConvertTargets.mp4,
      _ => false,
    };
  }

  /// Кто сделает [target] из [source] на [platform]; [tools] —
  /// установленные программы (`ffmpeg`) и системные кодировщики
  /// ([NativeMediaCaps.toTools]); [sourceName] — имя исходника, если он
  /// уже выбран (на Mac и телефоне не всякий контейнер открывается).
  static ConvertRoute route({
    required JobPlatform platform,
    required Set<String> tools,
    required MediaKind source,
    required String target,
    String? sourceName,
  }) {
    if (source == MediaKind.image && ConvertTargets.isImageTarget(target)) {
      return const ConvertRoute.run(ConvertBackend.dart);
    }
    if (impossible(platform, target)) {
      return const ConvertRoute.blocked(ConvertBlock.impossible);
    }
    switch (platform) {
      case JobPlatform.windows || JobPlatform.linux:
        return tools.contains(ConvertTargets.ffmpeg)
            ? const ConvertRoute.run(ConvertBackend.ffmpeg)
            : const ConvertRoute.blocked(ConvertBlock.noTool);
      case JobPlatform.android || JobPlatform.macos:
        final native = NativeMediaCaps.fromTools(tools).targets;
        if (native.isEmpty) {
          return const ConvertRoute.blocked(ConvertBlock.imagesOnly);
        }
        if (!native.contains(target)) {
          return const ConvertRoute.blocked(ConvertBlock.deviceLacks);
        }
        if (sourceName != null && unreadable(platform, sourceName, target)) {
          return const ConvertRoute.blocked(ConvertBlock.sourceUnreadable);
        }
        return const ConvertRoute.run(ConvertBackend.native);
      case JobPlatform.ios:
        return const ConvertRoute.blocked(ConvertBlock.imagesOnly);
    }
  }

  /// Текст причины под вариантом карточки; [sourceName] — имя исходника
  /// (для [ConvertBlock.sourceUnreadable]).
  static String reason(
    ConvertBlock block,
    JobPlatform platform,
    String target, {
    String? sourceName,
  }) =>
      switch (block) {
        ConvertBlock.noTool =>
          'Нужен ffmpeg: Настройки → Расширения → Конвертер → Настроить',
        ConvertBlock.imagesOnly => '${_where(platform)} — только картинки',
        ConvertBlock.impossible => impossibleReason(platform, target),
        ConvertBlock.deviceLacks => '${_where(platform)} '
            '${ConvertTargets.shortLabel(target)} не делается: '
            '${lacksWhy(target)}',
        ConvertBlock.sourceUnreadable =>
          '${_where(platform)} ${_sourceLabel(sourceName)} не открывается — '
              '${unreadableHint(platform)}',
      };

  /// «На телефоне», «На Mac», «На этом устройстве».
  static String _where(JobPlatform platform) => switch (platform) {
        JobPlatform.android => 'На телефоне',
        JobPlatform.macos => 'На Mac',
        _ => 'На этом устройстве',
      };

  /// «файл WebM» по имени исходника; без имени — «этот файл».
  static String _sourceLabel(String? name) {
    final ext = name == null ? '' : ConvertTargets.extensionOf(name);
    return ext.isEmpty ? 'этот файл' : 'файл ${ext.toUpperCase()}';
  }

  /// Что откроется вместо неоткрываемого исходника, со строчной буквы.
  static String unreadableHint(JobPlatform platform) =>
      platform == JobPlatform.macos
          ? 'подойдут mp4, mov, m4a, mp3, wav'
          : 'из AVI здесь делается только MP4';

  /// Почему система не делает [target], хотя звук и видео делает, со
  /// строчной буквы: «встроенный кодировщик MP3 не загрузился».
  static String lacksWhy(String target) => switch (target) {
        ConvertTargets.mp3 => 'встроенный кодировщик MP3 не загрузился',
        ConvertTargets.mp4 || ConvertTargets.mov => 'нет кодировщика видео '
            'H.264',
        ConvertTargets.m4a => 'нет кодировщика AAC',
        _ => 'нет нужного кодировщика',
      };

  /// Почему из исходника [name] на [platform] не делается [target] — для
  /// ответа Лиорио, со строчной буквы.
  static String unreadableWhy(JobPlatform platform, String name) =>
      '${_sourceLabel(name)} здесь не открывается — '
      '${unreadableHint(platform)}';

  /// Почему формат [target] здесь не делается вовсе — под вариантом
  /// карточки: «На телефоне WebM не делается: …».
  static String impossibleReason(JobPlatform platform, String target) {
    final where = platform == JobPlatform.macos ? 'На Mac' : 'На телефоне';
    return '$where ${ConvertTargets.shortLabel(target)} не делается: '
        '${impossibleWhy(platform, target)}';
  }

  /// Короткая причина для ответа Лиорио, со строчной буквы: «в системе
  /// нет кодировщика для WebM — подойдёт MP4».
  static String impossibleWhy(JobPlatform platform, String target) =>
      switch (target) {
        ConvertTargets.webm => 'в системе нет кодировщика для WebM — '
            'подойдёт MP4',
        ConvertTargets.mov => 'система телефона не записывает MOV — '
            'подойдёт MP4',
        _ => 'в системе нет нужного кодировщика',
      };

  /// Варианты поля «Во что» для файла [name]. Недоступные — с причиной;
  /// то, что здесь не делается вовсе, не показывается (кроме [keep] —
  /// уже выбранного, например из фразы: пусть будет видно, почему нет).
  static List<Choice> targetChoices(
    String name,
    JobPlatform platform,
    Set<String> tools, {
    String? keep,
  }) {
    final source = ConvertTargets.kindOf(name);
    return <Choice>[
      for (final target in ConvertTargets.targetsFor(name))
        if (route(
          platform: platform,
          tools: tools,
          source: source,
          target: target,
          sourceName: name,
        )
            case final ConvertRoute r
            when r.block != ConvertBlock.impossible || target == keep)
          Choice(
            target,
            ConvertTargets.label(
              target,
              same: ConvertTargets.sameFormat(name, target),
            ),
            disabledReason: r.block == null
                ? null
                : reason(r.block!, platform, target, sourceName: name),
          ),
    ];
  }

  /// Форматы, которые здесь делаются из звука и видео, для текста ответа:
  /// «MP3, M4A, WAV, MP4…»; пусто — только картинки.
  static List<String> mediaTargets(JobPlatform platform, Set<String> tools) {
    final ffmpegPlatform =
        platform == JobPlatform.windows || platform == JobPlatform.linux;
    final native = NativeMediaCaps.fromTools(tools).targets;
    return <String>[
      for (final target in ConvertTargets.all)
        if (!ConvertTargets.isImageTarget(target) &&
            !impossible(platform, target) &&
            (ffmpegPlatform ||
                ((platform == JobPlatform.android ||
                        platform == JobPlatform.macos) &&
                    native.contains(target))))
          target,
    ];
  }

  /// Названия целей [targets] для текста: «mp3, m4a, wav, mp4, кадр»
  /// (два вида кадра — одно слово).
  static String mediaNames(Iterable<String> targets) => <String>[
        for (final target in ConvertTargets.all)
          if (targets.contains(target))
            if (ConvertTargets.isFrame(target))
              if (target == ConvertTargets.frameJpeg ||
                  !targets.contains(ConvertTargets.frameJpeg))
                'кадр'
              else
                ...<String>[]
            else
              target,
      ].join(', ');
}
