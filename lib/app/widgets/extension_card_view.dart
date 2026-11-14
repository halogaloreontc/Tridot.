import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/jobs/extension_card.dart';
import '../../core/jobs/job_runner.dart';
import '../../core/skills/ytdl/ytdl_formats.dart';
import '../assistant_theme.dart';
import '../jobs/job_hub.dart';

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
    minimumSize: WidgetStatePropertyAll<Size>(Size(0, 40)),
  );

  @override
  Widget build(BuildContext context) {
    final fields = ExtensionForms.of(card.extensionId);
    final body = Material(
      color: AssistantColors.raised,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: card.state == CardState.form
              ? AssistantColors.border
              : AssistantColors.borderSoft,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(),
            const SizedBox(height: 6),
            if (fields == null)
              const Text(
                'Расширение недоступно в этой версии приложения',
                key: Key('ext-card-unavailable'),
                style: metaTextStyle,
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
      padding: const EdgeInsets.only(top: 8),
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: wrapped,
      ),
    );
  }

  Widget _header() => Row(
        children: <Widget>[
          Icon(
            switch (card.extensionId) {
              ExtensionForms.converter => Icons.swap_horiz,
              ExtensionForms.ytdl => Icons.download_outlined,
              _ => Icons.folder_zip_outlined,
            },
            size: 18,
            color: AssistantColors.textStrong,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ExtensionForms.title(card.extensionId),
              key: const Key('ext-card-title'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AssistantColors.textStrong,
              ),
            ),
          ),
        ],
      );

  List<Widget> _body(BuildContext context, List<FieldSpec> fields) =>
      switch (card.state) {
        CardState.form => _form(fields),
        CardState.running => _running(),
        CardState.done => _done(),
        CardState.failed => _retry(
            JobCodes.message(card.errorCode),
            AssistantColors.danger,
            'ext-card-error',
          ),
        CardState.cancelled =>
          _retry('Отменено', AssistantColors.muted, 'ext-card-cancelled'),
        CardState.interrupted => _retry(
            'Прервано: приложение закрывали во время работы',
            AssistantColors.warning,
            'ext-card-interrupted',
          ),
      };

  List<Widget> _form(List<FieldSpec> fields) {
    final blocker = ExtensionForms.blocker(
      card,
      platform,
      tools: tools,
      enabled: enabled,
    );
    final repeated = blocker != null && _saidAbove(fields, blocker);
    return <Widget>[
      for (final field in fields)
        ...switch (field.kind) {
          FieldKind.files || FieldKind.file => _filesField(field),
          FieldKind.choice => _choiceField(field),
          FieldKind.url => _urlField(field),
          FieldKind.folder => const <Widget>[],
        },
      if (blocker != null && !repeated)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            blocker,
            key: const Key('ext-card-blocker'),
            style: metaTextStyle,
          ),
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          key: const Key('ext-card-run'),
          onPressed: blocker == null && !busy ? onRun : null,
          style: FilledButton.styleFrom(
            backgroundColor: AssistantColors.textStrong,
            foregroundColor: AssistantColors.workspace,
            disabledBackgroundColor: AssistantColors.bubble,
            disabledForegroundColor: AssistantColors.muted,
            minimumSize: const Size(0, 40),
          ),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(ExtensionForms.runLabel(card.extensionId)),
        ),
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

  List<Widget> _filesField(FieldSpec field) {
    final files = card.files(field.code);
    final addable = <JobFile>[
      for (final file in sessionFiles)
        if (!files.contains(file)) file,
    ];
    return <Widget>[
      Text(field.label, style: metaTextStyle),
      const SizedBox(height: 4),
      if (files.isEmpty)
        Text(
          field.kind == FieldKind.file
              ? 'Выберите файл'
              : platform.isDesktop
                  ? 'Выберите файлы или папку'
                  : 'Выберите файлы',
          key: const Key('ext-card-files-empty'),
          style: const TextStyle(fontSize: 13, color: AssistantColors.muted),
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
              color: AssistantColors.muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
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
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.history, size: 18),
                    SizedBox(width: 6),
                    Text('Из сессии'),
                  ],
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
    ];
  }

  List<Widget> _choiceField(FieldSpec field) {
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
        Text(field.label, style: metaTextStyle),
        const SizedBox(height: 4),
        Text(
          hint,
          key: ValueKey<String>('ext-card-empty-${field.code}'),
          style: const TextStyle(fontSize: 13, color: AssistantColors.muted),
        ),
      ];
    }
    return <Widget>[
      Text(field.label, style: metaTextStyle),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final option in options)
            ChoiceChip(
              key: ValueKey<String>('ext-card-choice-${option.value}'),
              // Узкий экран и крупный шрифт: подпись переносится, а не
              // обрезается («Видео: лучшее до 1080p» и «…до 720p» иначе
              // не различить).
              label: Text(
                option.label,
                softWrap: true,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              selected: option.value == value,
              onSelected: busy || onChoice == null
                  ? null
                  : (_) => onChoice!(field.code, option.value),
            ),
        ],
      ),
      if (chosen?.disabledReason case final String reason)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            reason,
            key: const Key('ext-card-choice-reason'),
            style:
                const TextStyle(fontSize: 12, color: AssistantColors.warning),
          ),
        ),
    ];
  }

  List<Widget> _urlField(FieldSpec field) {
    final value = card.values[field.code];
    return <Widget>[
      Text(field.label, style: metaTextStyle),
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
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 6),
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

  List<Widget> _done() {
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
          style: const TextStyle(fontSize: 13, color: AssistantColors.success),
        ),
      ),
      if (card.listing.isNotEmpty) ...<Widget>[
        const SizedBox(height: 6),
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
                  style: const TextStyle(fontSize: 13),
                ),
              if (card.listingMore > 0)
                Text(
                  'и ещё ${card.listingMore}',
                  key: const Key('ext-card-listing-more'),
                  style: metaTextStyle,
                ),
            ],
          ),
        ),
      ],
      if (temporary) ...<Widget>[
        const SizedBox(height: 4),
        const Text(
          'Результат во временной папке и удалится при выходе',
          key: Key('ext-card-temporary'),
          style: TextStyle(fontSize: 12, color: AssistantColors.warning),
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
                  backgroundColor: AssistantColors.textStrong,
                  foregroundColor: AssistantColors.workspace,
                  minimumSize: const Size(0, 40),
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
      const SizedBox(height: 6),
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
            style: TextStyle(fontSize: 13, color: color),
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

/// Поле ссылки загрузчика: Inter, одна строка, без автоисправлений.
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
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'https://…',
          counterText: '',
          border: OutlineInputBorder(),
        ),
        onChanged: widget.onChanged,
      );
}
