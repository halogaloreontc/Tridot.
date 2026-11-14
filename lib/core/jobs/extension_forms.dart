/// Схемы полей карточек-форм расширений (docs/EXTENSIONS.md, «Карточка-
/// форма»). Схема строится ядром по id расширения и в историю чата не
/// пишется: будущее расширение добавляет сюда описание своей формы и
/// обработчик задачи, а карточка в чате и исполнитель остаются общими.
library;

import '../build_flags.dart';
import '../skills/converter/convert_targets.dart';
import '../skills/ytdl/ytdl_formats.dart';
import 'extension_card.dart';

/// Платформа, на которой открыта карточка: от неё зависят доступные
/// варианты (папка целиком — только на компьютере).
enum JobPlatform {
  android,
  ios,
  windows,
  linux,
  macos;

  bool get isDesktop => this == windows || this == linux || this == macos;
}

/// Вид поля.
enum FieldKind {
  /// Несколько файлов (и папок на компьютере).
  files,

  /// Один файл.
  file,

  /// Папка.
  folder,

  /// Выбор из вариантов.
  choice,

  /// Ссылка.
  url,
}

/// Вариант поля-выбора. [disabledReason] — почему он недоступен сейчас.
final class Choice {
  const Choice(this.value, this.label, {this.disabledReason});

  final String value;
  final String label;
  final String? disabledReason;

  bool get enabled => disabledReason == null;
}

/// Описание поля формы.
final class FieldSpec {
  const FieldSpec({
    required this.code,
    required this.kind,
    required this.label,
    this.required = true,
    this.options,
    this.emptyHint,
  });

  /// Ключ значения в [ExtensionCard.values].
  final String code;
  final FieldKind kind;

  /// Подпись поля.
  final String label;

  final bool required;

  /// Варианты поля-выбора при значениях [card], платформе [platform] и
  /// установленных внешних программах [tools] (`ffmpeg`).
  final List<Choice> Function(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  )? options;

  /// Подсказка вместо вариантов, пока их нет (конвертер без файла:
  /// «Сначала выберите файл»). `null` — пустое поле-выбор не показывается
  /// вовсе, даже подписью.
  final String? emptyHint;
}

/// Схемы форм расширений этой сборки.
abstract final class ExtensionForms {
  /// Id архиватора.
  static const String archiver = 'archiver';

  /// Id конвертера.
  static const String converter = 'converter';

  /// Id загрузчика видео.
  static const String ytdl = 'ytdl';

  /// Действия архиватора.
  static const String zip = 'zip';
  static const String extract = 'extract';
  static const String list = 'list';

  /// Поля формы расширения [extensionId] или `null`, если такого
  /// расширения в сборке нет (карточка только для чтения).
  static List<FieldSpec>? of(String extensionId) => switch (extensionId) {
        archiver => _archiverFields,
        converter => _converterFields,
        // В сборке для Google Play загрузчика нет: его форма и всё, что
        // за ней, выбрасываются при сборке.
        ytdl => kPlayBuild ? null : _ytdlFields,
        _ => null,
      };

  /// Название расширения в заголовке карточки.
  static String title(String extensionId) => switch (extensionId) {
        archiver => 'Архиватор',
        converter => 'Конвертер',
        ytdl => 'Загрузчик видео',
        _ => 'Расширение',
      };

  /// Подпись кнопки запуска.
  static String runLabel(String extensionId) =>
      extensionId == ytdl ? 'Скачать' : 'Запустить';

  static const List<FieldSpec> _archiverFields = <FieldSpec>[
    FieldSpec(code: 'files', kind: FieldKind.files, label: 'Файлы'),
    FieldSpec(
      code: 'action',
      kind: FieldKind.choice,
      label: 'Действие',
      options: _archiverActions,
    ),
  ];

  static List<Choice> _archiverActions(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) {
    final files = card.files();
    final oneZip = files.length == 1 && files.single.isZip;
    const needZip = 'Нужен ровно один файл .zip';
    return <Choice>[
      const Choice(zip, 'Создать архив'),
      Choice(extract, 'Распаковать', disabledReason: oneZip ? null : needZip),
      Choice(
        list,
        'Посмотреть содержимое',
        disabledReason: oneZip ? null : needZip,
      ),
    ];
  }

  static const List<FieldSpec> _converterFields = <FieldSpec>[
    FieldSpec(code: 'file', kind: FieldKind.file, label: 'Файл'),
    FieldSpec(
      code: 'target',
      kind: FieldKind.choice,
      label: 'Во что',
      options: _converterTargets,
      emptyHint: 'Сначала выберите файл',
    ),
  ];

  /// Платформы, где конвертер может запускать ffmpeg (ADR-024): только
  /// Windows и Linux. На Android запуск скачанных программ запрещён
  /// системой, на macOS — песочницей; там конвертируются только картинки.
  static bool ffmpegPlatform(JobPlatform platform) =>
      platform == JobPlatform.windows || platform == JobPlatform.linux;

  /// Почему цель, которой нужен ffmpeg, сейчас недоступна; `null` —
  /// доступна.
  static String? ffmpegReason(JobPlatform platform, Set<String> tools) {
    if (!ffmpegPlatform(platform)) {
      return 'На этой платформе недоступно: здесь конвертируются только '
          'картинки';
    }
    if (!tools.contains(ConvertTargets.ffmpeg)) {
      return 'Нужен ffmpeg: Настройки → Расширения → Конвертер → Настроить';
    }
    return null;
  }

  static List<Choice> _converterTargets(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) {
    final file = card.files('file').firstOrNull;
    if (file == null) return const <Choice>[];
    return <Choice>[
      for (final target in ConvertTargets.targetsFor(file.name))
        Choice(
          target,
          ConvertTargets.label(target),
          disabledReason: ConvertTargets.needsFfmpegFor(file.name, target)
              ? ffmpegReason(platform, tools)
              : null,
        ),
    ];
  }

  static const List<FieldSpec> _ytdlFields = <FieldSpec>[
    FieldSpec(code: 'url', kind: FieldKind.url, label: 'Ссылка'),
    FieldSpec(
      code: 'format',
      kind: FieldKind.choice,
      label: 'Что скачать',
      options: _ytdlFormats,
    ),
  ];

  /// Платформы загрузчика видео: только Windows и Linux (ADR-024).
  static bool ytdlPlatform(JobPlatform platform) =>
      platform == JobPlatform.windows || platform == JobPlatform.linux;

  static List<Choice> _ytdlFormats(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) {
    final noFfmpeg = tools.contains(YtdlFormats.ffmpeg)
        ? null
        : 'Нужен ffmpeg: Настройки → Расширения → Конвертер → Настроить';
    return <Choice>[
      for (final format in YtdlFormats.all)
        Choice(
          format,
          YtdlFormats.label(format),
          disabledReason: YtdlFormats.needsFfmpeg(format) ? noFfmpeg : null,
        ),
    ];
  }

  /// Почему у поля-выбора нет ни одного варианта.
  static String _noOptions(ExtensionCard card, FieldSpec field) {
    if (card.extensionId == converter) {
      final file = card.files('file').firstOrNull;
      if (file != null &&
          ConvertTargets.kindOf(file.name) == MediaKind.unknown) {
        return 'Этот формат пока не поддерживается';
      }
      if (file != null) return 'Для этого файла нет других форматов';
    }
    return 'Выберите: ${field.label.toLowerCase()}';
  }

  /// Причина «нет файла» и «нет файлов»: её уже говорит пустое поле
  /// файлов, под кнопкой она не повторяется.
  static const String needFile = 'Выберите файл';
  static const String needFiles = 'Добавьте файлы';

  /// Расширение выключено в настройках.
  static String offReason(String extensionId) =>
      '${title(extensionId)} выключен — включите в «Настройки → '
      'Расширения»';

  /// Почему «Запустить» сейчас неактивна; `null` — можно запускать.
  /// [tools] — установленные внешние программы (`ffmpeg`).
  /// [enabled] — расширение включено в «Настройки → Расширения»: у
  /// выключенного карточка в чате остаётся, но не запускается.
  static String? blocker(
    ExtensionCard card,
    JobPlatform platform, {
    Set<String> tools = const <String>{},
    bool enabled = true,
  }) {
    final fields = of(card.extensionId);
    if (fields == null) return 'Расширение недоступно';
    if (!enabled) return offReason(card.extensionId);
    if (card.extensionId == ytdl) {
      if (!ytdlPlatform(platform)) return 'На этой платформе недоступно';
      if (!tools.contains(YtdlFormats.tool)) {
        return 'Нужен yt-dlp: Настройки → Расширения → Загрузчик видео → '
            'Настроить';
      }
    }
    for (final field in fields) {
      switch (field.kind) {
        case FieldKind.files:
        case FieldKind.file:
          final files = card.files(field.code);
          if (field.required && files.isEmpty) {
            return field.kind == FieldKind.file ? needFile : needFiles;
          }
          if (field.kind == FieldKind.file && files.length > 1) {
            return 'Нужен один файл';
          }
          if (field.kind == FieldKind.file &&
              files.length == 1 &&
              files.single.folder) {
            return 'Нужен файл, а не папка';
          }
        case FieldKind.choice:
          final options =
              field.options?.call(card, platform, tools) ?? const <Choice>[];
          final value = card.choice(field.code);
          if (options.isEmpty && field.required) {
            return _noOptions(card, field);
          }
          if (value == null) {
            if (field.required) return 'Выберите: ${field.label.toLowerCase()}';
            continue;
          }
          final chosen =
              options.where((Choice c) => c.value == value).firstOrNull;
          if (chosen == null) return 'Выберите: ${field.label.toLowerCase()}';
          if (chosen.disabledReason case final String reason) return reason;
        case FieldKind.folder:
          final value = card.values[field.code];
          if (field.required && (value is! String || value.isEmpty)) {
            return 'Заполните: ${field.label.toLowerCase()}';
          }
        case FieldKind.url:
          final value = card.values[field.code];
          if (value is! String || value.trim().isEmpty) {
            if (field.required) return 'Вставьте ссылку';
            continue;
          }
          if (!YtdlUrl.valid(value.trim())) {
            return 'Нужна ссылка вида https://…';
          }
      }
    }
    return null;
  }
}
