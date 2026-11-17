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

  /// Сжатие нового архива: обычное, сильное, без сжатия.
  static const String levelNormal = 'normal';
  static const String levelStrong = 'strong';
  static const String levelStore = 'store';

  /// Уровень deflate для сжатия [level]: 6, 9 или 0 (без сжатия).
  static int zipLevel(String? level) => switch (level) {
        levelStrong => 9,
        levelStore => 0,
        _ => 6,
      };

  static const List<FieldSpec> _archiverFields = <FieldSpec>[
    FieldSpec(code: 'files', kind: FieldKind.files, label: 'Файлы'),
    FieldSpec(
      code: 'action',
      kind: FieldKind.choice,
      label: 'Действие',
      options: _archiverActions,
    ),
    FieldSpec(
      code: 'level',
      kind: FieldKind.choice,
      label: 'Сжатие',
      required: false,
      options: _archiverLevels,
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

  static const List<Choice> _levels = <Choice>[
    Choice(levelNormal, 'Обычное'),
    Choice(levelStrong, 'Сильное — дольше, файл меньше'),
    Choice(levelStore, 'Без сжатия — быстрее'),
  ];

  /// Сжатие — только у «Создать архив».
  static List<Choice> _archiverLevels(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) =>
      (card.choice('action') ?? zip) == zip ? _levels : const <Choice>[];

  static final List<FieldSpec> _converterFields = <FieldSpec>[
    const FieldSpec(code: 'file', kind: FieldKind.file, label: 'Файл'),
    const FieldSpec(
      code: 'target',
      kind: FieldKind.choice,
      label: 'Во что',
      options: _converterTargets,
      emptyHint: 'Сначала выберите файл',
    ),
    for (final quality in ConvertQuality.fields)
      FieldSpec(
        code: quality.code,
        kind: FieldKind.choice,
        label: quality.label,
        required: false,
        options:
            (ExtensionCard card, JobPlatform platform, Set<String> tools) =>
                _qualityOptions(quality, card, platform, tools),
      ),
  ];

  static List<Choice> _converterTargets(
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) {
    final file = card.files('file').firstOrNull;
    if (file == null) return const <Choice>[];
    return ConvertCaps.targetChoices(
      file.name,
      platform,
      tools,
      keep: card.choice('target'),
    );
  }

  /// Тип исходника карточки конвертера; файла нет — `null`.
  static MediaKind? _sourceKind(ExtensionCard card) {
    final file = card.files('file').firstOrNull;
    return file == null ? null : ConvertTargets.kindOf(file.name);
  }

  /// Варианты поля качества: только когда оно что-то меняет у выбранной
  /// цели и цель здесь вообще делается (у WebM на телефоне — нет; пока
  /// не скачан ffmpeg — показываются: его можно скачать). 1080p — только
  /// если система умеет его кодировать.
  static List<Choice> _qualityOptions(
    QualityField quality,
    ExtensionCard card,
    JobPlatform platform,
    Set<String> tools,
  ) {
    final target = card.choice('target');
    final file = card.files('file').firstOrNull;
    if (target == null ||
        !ConvertQuality.codesFor(target, _sourceKind(card))
            .contains(quality.code)) {
      return const <Choice>[];
    }
    if (file != null) {
      final block = ConvertCaps.route(
        platform: platform,
        tools: tools,
        source: ConvertTargets.kindOf(file.name),
        target: target,
        sourceName: file.name,
      ).block;
      if (block != null && block != ConvertBlock.noTool) {
        return const <Choice>[];
      }
    }
    final native = NativeMediaCaps.fromTools(tools);
    return <Choice>[
      for (final (value, label) in quality.values)
        Choice(
          value,
          label,
          disabledReason: quality.code == ConvertQuality.videoRes &&
                  value == '1080' &&
                  native.targets.contains(target) &&
                  !native.video1080
              ? 'Телефон не умеет кодировать 1080p'
              : null,
        ),
    ];
  }

  /// Поля, чей последний выбор запоминается (`AppSettings.formDefaults`).
  static bool rememberable(String extensionId, String code) =>
      (extensionId == converter && ConvertQuality.field(code) != null) ||
      (extensionId == archiver && code == 'level');

  /// Значение [value] годится для запоминаемого поля [code].
  static bool validDefault(String extensionId, String code, String value) {
    if (!rememberable(extensionId, code)) return false;
    if (extensionId == archiver) {
      return _levels.any((Choice c) => c.value == value);
    }
    return ConvertQuality.field(code)!.accepts(value);
  }

  /// Значение по умолчанию поля [code], если его не выбирали.
  static String? builtInDefault(String extensionId, String code) =>
      extensionId == archiver && code == 'level'
          ? levelNormal
          : extensionId == converter
              ? ConvertQuality.field(code)?.defaultValue
              : null;

  /// Необязательные поля-выборы карточки: лишние (не к этой цели или
  /// действию) убираются, пустые заполняются — значением из фразы, иначе
  /// последним выбором [remembered] (`<расширение>.<поле>`), иначе
  /// значением по умолчанию. Конвертер с единственной целью получает её
  /// сам. `true` — что-то поменялось.
  static bool resolve(
    ExtensionCard card,
    JobPlatform platform, {
    Set<String> tools = const <String>{},
    Map<String, String> remembered = const <String, String>{},
  }) {
    final fields = of(card.extensionId);
    if (fields == null || card.state != CardState.form) return false;
    var changed = false;
    if (card.extensionId == converter && card.choice('target') == null) {
      final targets = _converterTargets(card, platform, tools);
      if (targets.length == 1) {
        card.setValue('target', targets.single.value);
        changed = true;
      }
    }
    // Цели ещё нет: значения из фразы («320») ждут её; убирается только
    // то, что не подойдёт ни одной цели этого файла.
    if (card.extensionId == converter && card.choice('target') == null) {
      final file = card.files('file').firstOrNull;
      if (file == null) return changed;
      final kind = ConvertTargets.kindOf(file.name);
      final useful = <String>{
        for (final target in ConvertTargets.targetsFor(file.name))
          ...ConvertQuality.codesFor(target, kind),
      };
      for (final quality in ConvertQuality.fields) {
        if (!useful.contains(quality.code) &&
            card.values.containsKey(quality.code)) {
          card.setValue(quality.code, null);
          changed = true;
        }
      }
      return changed;
    }
    for (final field in fields) {
      if (field.kind != FieldKind.choice || field.required) continue;
      final options =
          field.options?.call(card, platform, tools) ?? const <Choice>[];
      final value = card.choice(field.code);
      if (options.isEmpty) {
        if (card.values.containsKey(field.code)) {
          card.setValue(field.code, null);
          changed = true;
        }
        continue;
      }
      bool ok(String? v) =>
          v != null && options.any((Choice c) => c.value == v && c.enabled);
      if (ok(value)) continue;
      final saved = remembered['${card.extensionId}.${field.code}'];
      final fallback = builtInDefault(card.extensionId, field.code);
      final next = ok(saved)
          ? saved
          : ok(fallback)
              ? fallback
              : options.where((Choice c) => c.enabled).firstOrNull?.value;
      if (next != value) {
        card.setValue(field.code, next);
        changed = true;
      }
    }
    return changed;
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
          if (chosen == null) {
            // Необязательное поле с прежним значением, которое к этой цели
            // не относится (`audio_kbps` у png), запуск не держит.
            if (!field.required) continue;
            return 'Выберите: ${field.label.toLowerCase()}';
          }
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
