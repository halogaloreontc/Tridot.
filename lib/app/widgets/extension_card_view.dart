import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/jobs/extension_card.dart';
import '../../core/jobs/job_runner.dart';
import '../../core/skills/ytdl/ytdl_formats.dart';
import '../assistant_theme.dart';
import '../jobs/job_hub.dart';
import 'whole_word_text.dart';

/// Карточка-форма расширения под ответом Лиорио (docs/PLANS.md,
/// «Карточки-формы»): поля по схеме ядра ([ExtensionForms]) → «Запустить»
/// → ход работы и «Отмена» → «Открыть» / «Открыть папку» или ошибка с
/// «Повторить». Одна карточка для всех расширений, которые работают с
/// файлами. Имена файлов — простым текстом в одну строку.
final class ExtensionCardView extends StatelessWidget {
  const ExtensionCardView({
    super.key,
    required this.card,
    required this.platform,
    required this.progress,
    this.busy = false,
    this.canReveal = false,
    this.sessionFiles = const <JobFile>[],
    this.tools = const <String>{},
    this.enabled = true,
    this.temporary = false,
    this.onAddFiles,
    this.onAddFolder,
    this.onAddSessionFile,
    this.onRemoveFile,
    this.onChoice,
    this.onText,
    this.onRun,
    this.onCancel,
    this.onOpen,
    this.onReveal,
    this.onRetry,
    this.dropTarget,
  });

  final ExtensionCard card;
  final JobPlatform platform;

  /// Ход работы (только в памяти).
  final ValueListenable<JobTick?> progress;

  /// Интерфейс занят (готовится ответ): кнопки формы не нажимаются.
  final bool busy;

  /// «Открыть папку» есть (компьютер).
  final bool canReveal;

  /// Файлы сессии, которые можно добавить в поле.
  final List<JobFile> sessionFiles;

  /// Установленные внешние программы (`ffmpeg`): от них зависят варианты
  /// конвертера.
  final Set<String> tools;

  /// Расширение включено в настройках: выключенное не запускается.
  final bool enabled;

  /// Результат во временной папке (хранилище «Только в памяти»): после
  /// выхода его не будет.
  final bool temporary;

  final VoidCallback? onAddFiles;
  final VoidCallback? onAddFolder;
  final ValueChanged<JobFile>? onAddSessionFile;
  final ValueChanged<JobFile>? onRemoveFile;
  final void Function(String code, String value)? onChoice;

  /// Текст поля-ссылки изменился.
  final void Function(String code, String value)? onText;
  final VoidCallback? onRun;
  final VoidCallback? onCancel;
  final ValueChanged<String>? onOpen;
  final ValueChanged<String>? onReveal;
  final VoidCallback? onRetry;

  /// Обёртка для перетаскивания файлов в карточку (компьютер): только в
  /// состоянии формы.
  final Widget Function(Widget child)? dropTarget;

  static const ButtonStyle _outlined = ButtonStyle(
    minimumSize: WidgetStatePropertyAll<Size>(Size(0, 48)),
  );

  /// Подпись над полем — 15 вторичным (ADR-027).
  /// Подпись поля — 15 полужирным основным цветом: над подсказкой 15
  /// приглушённой видна иерархия «что» → «что сделать».
  static TextStyle _labelStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium!
      .copyWith(color: context.colors.text, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final fields = ExtensionForms.of(card.extensionId);
    final body = Material(
      color: context.colors.raised,
      clipBehavior: Clip.antiAlias,
      // Карточка заливкой без рамки (ADR-027): форму видно по заголовку и
      // активной основной кнопке.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(context),
            const SizedBox(height: 4),
            if (fields == null)
              Text(
                'Расширение недоступно в этой версии приложения',
                key: Key('ext-card-unavailable'),
                style: metaStyle(context),
              )
            else
              ..._body(context, fields),
          ],
        ),
      ),
    );
    final wrapped = card.state == CardState.form && dropTarget != null
        ? dropTarget!(body)
        : body;
    return Padding(
      key: ValueKey<String>('ext-card-${card.id}'),
      padding: EdgeInsets.zero,
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: wrapped,
      ),
    );
  }

  Widget _header(BuildContext context) => Row(
        children: <Widget>[
          Icon(
            switch (card.extensionId) {
              ExtensionForms.converter => Icons.swap_horiz,
              ExtensionForms.ytdl => Icons.download_outlined,
              _ => Icons.folder_zip_outlined,
            },
            size: 22,
            color: context.colors.icon,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ExtensionForms.title(card.extensionId),
              key: const Key('ext-card-title'),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium!
                  .copyWith(color: context.colors.textStrong),
            ),
          ),
        ],
      );

  List<Widget> _body(BuildContext context, List<FieldSpec> fields) =>
      switch (card.state) {
        CardState.form => _form(context, fields),
        CardState.running => _running(),
        CardState.done => _done(context),
        CardState.failed => _retry(
            JobCodes.message(card.errorCode),
            context.colors.danger,
            'ext-card-error',
          ),
        CardState.cancelled =>
          _retry('Отменено', context.colors.muted, 'ext-card-cancelled'),
        CardState.interrupted => _retry(
            'Прервано: приложение закрывали во время работы',
            context.colors.warning,
            'ext-card-interrupted',
          ),
      };

  List<Widget> _form(BuildContext context, List<FieldSpec> fields) {
    final blocker = ExtensionForms.blocker(
      card,
      platform,
      tools: tools,
      enabled: enabled,
    );
    final repeated = blocker != null && _saidAbove(fields, blocker);
    return <Widget>[
      // Между полями — воздух (ADR-027); скрытое поле места не занимает.
      for (final (i, part) in <List<Widget>>[
        for (final field in fields)
          switch (field.kind) {
            FieldKind.files || FieldKind.file => _filesField(context, field),
            FieldKind.choice => _choiceField(context, field),
            FieldKind.url => _urlField(context, field),
            FieldKind.folder => const <Widget>[],
          },
      ].where((List<Widget> p) => p.isNotEmpty).indexed) ...<Widget>[
        if (i > 0) const SizedBox(height: 12),
        ...part,
      ],
      if (blocker != null && !repeated)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            blocker,
            key: const Key('ext-card-blocker'),
            style: metaStyle(context),
          ),
        ),
      const SizedBox(height: 12),
      // Основное действие — во всю ширину, акцентом.
      FilledButton.icon(
        key: const Key('ext-card-run'),
        onPressed: blocker == null && !busy ? onRun : null,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: context.colors.bubble,
          disabledForegroundColor: context.colors.muted,
          minimumSize: const Size.fromHeight(50),
        ),
        icon: const Icon(Icons.play_arrow, size: 20),
        label: Text(ExtensionForms.runLabel(card.extensionId)),
      ),
    ];
  }

  /// Причину [blocker] уже видно выше: пустое поле файлов («Выберите
  /// файл») или пояснение под выбранным вариантом — второй раз под
  /// кнопкой она не пишется.
  bool _saidAbove(List<FieldSpec> fields, String blocker) {
    for (final field in fields) {
      switch (field.kind) {
        case FieldKind.files || FieldKind.file:
          if (card.files(field.code).isEmpty &&
              (blocker == ExtensionForms.needFile ||
                  blocker == ExtensionForms.needFiles)) {
            return true;
          }
        case FieldKind.choice:
          final value = card.choice(field.code);
          final options =
              field.options?.call(card, platform, tools) ?? const <Choice>[];
          final chosen =
              options.where((Choice c) => c.value == value).firstOrNull;
          if (chosen?.disabledReason == blocker) return true;
        case FieldKind.url || FieldKind.folder:
          break;
      }
    }
    return false;
  }

  List<Widget> _filesField(BuildContext context, FieldSpec field) {
    final files = card.files(field.code);
    final addable = <JobFile>[
      for (final file in sessionFiles)
        if (!files.contains(file)) file,
    ];
    return <Widget>[
      Text(field.label, style: _labelStyle(context)),
      const SizedBox(height: 4),
      if (files.isEmpty)
        Text(
          field.kind == FieldKind.file
              ? 'Выберите файл'
              : platform.isDesktop
                  ? 'Выберите файлы или папку'
                  : 'Выберите файлы',
          key: const Key('ext-card-files-empty'),
          style: TextStyle(fontSize: 14, color: context.colors.muted),
        ),
      for (final (i, file) in files.indexed)
        Row(
          key: ValueKey<String>('ext-card-file-$i'),
          children: <Widget>[
            Icon(
              file.folder
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
              size: 16,
              color: context.colors.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            IconButton(
              key: ValueKey<String>('ext-card-file-remove-$i'),
              tooltip: 'Убрать',
              iconSize: 18,
              onPressed: busy || onRemoveFile == null
                  ? null
                  : () => onRemoveFile!(file),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('ext-card-pick-files'),
            style: _outlined,
            onPressed: busy ? null : onAddFiles,
            icon: const Icon(Icons.attach_file, size: 18),
            label: Text(
              field.kind == FieldKind.file ? 'Выбрать файл' : 'Выбрать файлы',
            ),
          ),
          if (platform.isDesktop && field.kind == FieldKind.files)
            OutlinedButton.icon(
              key: const Key('ext-card-pick-folder'),
              style: _outlined,
              onPressed: busy ? null : onAddFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Выбрать папку'),
            ),
          if (addable.isNotEmpty && onAddSessionFile != null)
            PopupMenuButton<JobFile>(
              key: const Key('ext-card-session-files'),
              tooltip: 'Файлы этой сессии',
              enabled: !busy,
              onSelected: onAddSessionFile,
              itemBuilder: (BuildContext context) => <PopupMenuEntry<JobFile>>[
                for (final file in addable)
                  PopupMenuItem<JobFile>(
                    value: file,
                    child: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.history, size: 18),
                    SizedBox(width: 8),
                    Text('Из сессии'),
                  ],
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _choiceField(BuildContext context, FieldSpec field) {
    final options =
        field.options?.call(card, platform, tools) ?? const <Choice>[];
    final value = card.choice(field.code);
    final chosen = options.where((Choice c) => c.value == value).firstOrNull;
    // Вариантов пока нет (конвертер без файла): не пустая подпись, а
    // подсказка, что сделать сначала, — или ничего.
    if (options.isEmpty) {
      final hint = field.emptyHint;
      if (hint == null) return const <Widget>[];
      return <Widget>[
        Text(field.label, style: _labelStyle(context)),
        const SizedBox(height: 4),
        Text(
          hint,
          key: ValueKey<String>('ext-card-empty-${field.code}'),
          style: TextStyle(fontSize: 14, color: context.colors.muted),
        ),
      ];
    }
    return <Widget>[
      _ChoiceDropdown(
        key: ValueKey<String>('ext-card-select-${field.code}'),
        label: field.label,
        options: options,
        value: chosen?.value,
        onChanged: busy || onChoice == null
            ? null
            : (String value) => onChoice!(field.code, value),
      ),
      if (chosen?.disabledReason case final String reason)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            reason,
            key: const Key('ext-card-choice-reason'),
            style: TextStyle(fontSize: 13, color: context.colors.warning),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _urlField(BuildContext context, FieldSpec field) {
    final value = card.values[field.code];
    return <Widget>[
      Text(field.label, style: _labelStyle(context)),
      const SizedBox(height: 4),
      _UrlField(
        key: ValueKey<String>('ext-card-url-${card.id}'),
        initial: value is String ? value : '',
        enabled: !busy && onText != null,
        onChanged: (String text) => onText?.call(field.code, text),
      ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _running() => <Widget>[
        ValueListenableBuilder<JobTick?>(
          valueListenable: progress,
          builder: (BuildContext context, JobTick? tick, _) {
            final value = tick?.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    value == null
                        ? '${tick?.stage ?? 'Работаю'}…'
                        : '${tick?.stage ?? 'Работаю'}: '
                            '${(value * 100).clamp(0, 100).round()}%',
                    key: const Key('ext-card-stage'),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  key: const Key('ext-card-progress'),
                  value: value,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const Key('ext-card-cancel'),
            style: _outlined,
            onPressed: onCancel,
            child: const Text('Отмена'),
          ),
        ),
      ];

  List<Widget> _done(BuildContext context) {
    final outputs = card.outputs;
    final name = outputs.isEmpty ? null : p.basename(outputs.first);
    return <Widget>[
      Semantics(
        liveRegion: true,
        child: Text(
          name == null ? 'Готово' : 'Готово: $name',
          key: const Key('ext-card-done'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: context.colors.success),
        ),
      ),
      if (card.listing.isNotEmpty) ...<Widget>[
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            key: const Key('ext-card-listing'),
            shrinkWrap: true,
            children: <Widget>[
              for (final line in card.listing)
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              if (card.listingMore > 0)
                Text(
                  'и ещё ${card.listingMore}',
                  key: const Key('ext-card-listing-more'),
                  style: metaStyle(context),
                ),
            ],
          ),
        ),
      ],
      if (temporary) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          'Результат во временной папке и удалится при выходе',
          key: Key('ext-card-temporary'),
          style: TextStyle(fontSize: 13, color: context.colors.warning),
        ),
      ],
      if (!canReveal)
        for (final output in outputs) ..._folderFiles(output),
      // Готово, но путь файла не известен (загрузчик видео): папка.
      if (outputs.isEmpty && canReveal && card.outputDir != null) ...<Widget>[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('ext-card-open-dir'),
            style: _outlined,
            onPressed: onOpen == null ? null : () => onOpen!(card.outputDir!),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Открыть папку'),
          ),
        ),
      ],
      if (outputs.isNotEmpty) ...<Widget>[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (canReveal || !_isDirectory(outputs.first))
              FilledButton.icon(
                key: const Key('ext-card-open'),
                onPressed: onOpen == null ? null : () => onOpen!(outputs.first),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Открыть'),
              ),
            if (canReveal)
              OutlinedButton.icon(
                key: const Key('ext-card-reveal'),
                style: _outlined,
                onPressed:
                    onReveal == null ? null : () => onReveal!(outputs.first),
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('Открыть папку'),
              ),
          ],
        ),
      ],
    ];
  }

  static bool _isDirectory(String path) {
    try {
      return FileSystemEntity.isDirectorySync(path);
    } on Object {
      return false;
    }
  }

  /// Распакованная папка на телефоне: «Открыть папку» нет, поэтому её
  /// файлы (до 30) открываются по одному.
  List<Widget> _folderFiles(String folder) {
    if (!_isDirectory(folder)) return const <Widget>[];
    final files = <File>[];
    final queue = <Directory>[Directory(folder)];
    try {
      while (queue.isNotEmpty && files.length < 30) {
        for (final entity in queue.removeAt(0).listSync(followLinks: false)) {
          if (entity is File && files.length < 30) files.add(entity);
          if (entity is Directory) queue.add(entity);
        }
      }
    } on Object {
      // Папку не прочитать — показываем, что успели.
    }
    files.sort((File a, File b) => a.path.compareTo(b.path));
    return <Widget>[
      const SizedBox(height: 4),
      for (final (i, file) in files.indexed)
        TextButton(
          key: ValueKey<String>('ext-card-output-$i'),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            minimumSize: const Size(0, 36),
          ),
          onPressed: onOpen == null ? null : () => onOpen!(file.path),
          child: Text(
            p.relative(file.path, from: folder),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  List<Widget> _retry(String text, Color color, String key) => <Widget>[
        Semantics(
          liveRegion: true,
          child: Text(
            text,
            key: Key(key),
            style: TextStyle(fontSize: 14, color: color),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('ext-card-retry'),
            style: _outlined,
            onPressed: busy ? null : onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Повторить'),
          ),
        ),
      ];
}

/// Поле-выбор карточки — выпадающий список (ADR-026): подпись сверху,
/// список на всю ширину; длинная подпись варианта переносится по словам
/// (узкий экран, шрифт 200 %), а не обрезается посреди слова. Недоступный
/// вариант виден в списке серым с причиной второй строкой, но не
/// выбирается.
final class _ChoiceDropdown extends StatelessWidget {
  const _ChoiceDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<Choice> options;

  /// Выбранный вариант из [options] или `null`.
  final String? value;

  /// `null` — список не открывается (идёт ответ, форма занята).
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.any((Choice c) => c.value == value) ? value : null;
    return Semantics(
      container: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium!
                .copyWith(color: context.colors.muted),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            // Поле помнит начальное значение: сменилось снаружи (новый
            // файл, значение по умолчанию) — новое поле.
            key: ValueKey<String?>(selected),
            // Значение не из списка (старая карточка) — пусто, а не
            // падение DropdownButton.
            initialValue: selected,
            isExpanded: true,
            // Не плотное: у плотного кнопка высотой в одну строку, и
            // выбранная подпись в две строки (узкий экран, шрифт 200 %)
            // обрезается снизу.
            isDense: false,
            itemHeight: null,
            dropdownColor: context.colors.raised,
            borderRadius: BorderRadius.circular(12),
            icon: Icon(Icons.unfold_more, color: context.colors.icon),
            hint:
                const WholeWordText('Выберите', style: TextStyle(fontSize: 16)),
            // style заменяет стиль темы целиком (не дополняет): без
            // fontFamily выбранное значение и пункты списка ушли бы в
            // системный шрифт, а не шрифт приложения.
            style: TextStyle(
              fontFamily: AppFonts.text,
              fontSize: 16,
              color: context.colors.textStrong,
            ),
            // Поле внутри карточки — на уровень контрастнее карточки, без
            // рамки, строка не ниже 48.
            decoration: InputDecoration(
              isDense: true,
              fillColor: context.colors.fieldOnRaised,
              constraints: const BoxConstraints(minHeight: 48),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            ),
            selectedItemBuilder: (BuildContext context) => <Widget>[
              for (final option in options)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: WholeWordText(
                    option.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
            ],
            items: <DropdownMenuItem<String>>[
              for (final option in options)
                DropdownMenuItem<String>(
                  key: ValueKey<String>('ext-card-choice-${option.value}'),
                  value: option.value,
                  enabled: option.enabled,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        WholeWordText(
                          option.label,
                          style: TextStyle(
                            fontSize: 16,
                            color: option.enabled
                                ? context.colors.textStrong
                                : context.colors.muted,
                          ),
                        ),
                        if (option.disabledReason case final String reason)
                          WholeWordText(
                            reason,
                            style: TextStyle(
                              fontSize: 13,
                              color: context.colors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
            onChanged: onChanged == null
                ? null
                : (String? v) {
                    if (v != null) onChanged!(v);
                  },
          ),
        ],
      ),
    );
  }
}

/// Поле ссылки загрузчика: шрифт текста, одна строка, без автоисправлений.
final class _UrlField extends StatefulWidget {
  const _UrlField({
    super.key,
    required this.initial,
    required this.enabled,
    required this.onChanged,
  });

  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<_UrlField> createState() => _UrlFieldState();
}

final class _UrlFieldState extends State<_UrlField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(_UrlField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != _controller.text &&
        widget.initial != oldWidget.initial) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: const Key('ext-card-url'),
        controller: _controller,
        enabled: widget.enabled,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        maxLines: 1,
        maxLength: YtdlUrl.maxLength,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          isDense: true,
          fillColor: context.colors.fieldOnRaised,
          hintText: 'https://…',
          // На поле в карточке — вторичным, а не «тише» (ADR-027).
          hintStyle: TextStyle(color: context.colors.muted),
          counterText: '',
        ),
        onChanged: widget.onChanged,
      );
}
