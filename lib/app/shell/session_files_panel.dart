import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/chats/attachments.dart';
import '../../core/chats/session_files.dart';
import '../../core/formatting/due_format.dart';
import '../../core/jobs/extension_card.dart';
import '../assistant_theme.dart';
import '../attachments/attachment_views.dart';
import '../files/file_opener.dart';
import '../layout.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';

/// Что панель знает о файле результата на диске.
typedef SessionFileStat = ({bool exists, bool folder, int? size});

/// Узнать о файле результата: в тестах — подделка.
typedef SessionFileStatter = SessionFileStat Function(String path);

SessionFileStat _statOnDisk(String path) {
  try {
    final stat = FileStat.statSync(path);
    return switch (stat.type) {
      FileSystemEntityType.notFound => (
          exists: false,
          folder: false,
          size: null
        ),
      FileSystemEntityType.directory => (
          exists: true,
          folder: true,
          size: null
        ),
      _ => (exists: true, folder: false, size: stat.size),
    };
  } on Object {
    return (exists: false, folder: false, size: null);
  }
}

/// Действие из меню файла.
enum _FileAction { open, show, reveal, info, delete }

/// Правая панель сессии «Файлы сессии» (ADR-028): что сделали расширения
/// («Артефакты») и что прикрепили («Вложения»). На телефоне — выдвижная
/// панель справа, на компьютере — колонка справа от ленты.
///
/// Нажатие открывает файл в другой программе; «⋯» и долгое нажатие —
/// меню: «Открыть», «Показать в сообщении», «Показать в папке»
/// (компьютер), «Сведения» (вложение). Удалить файл отсюда нельзя: он
/// живёт, пока живо его сообщение.
final class SessionFilesPanel extends StatefulWidget {
  const SessionFilesPanel({
    super.key,
    required this.outputs,
    required this.attachments,
    required this.store,
    required this.opener,
    required this.onShowInMessage,
    required this.onClose,
    required this.now,
    this.onMessage,
    this.onDelete,
    this.stat,
    this.closeTooltip = 'Закрыть',
  });

  /// «Удалить» в меню файла: спросить и удалить (ADR-028). `null` — пункта
  /// нет.
  final ValueChanged<SessionFile>? onDelete;

  /// Результаты расширений, новые первыми ([SessionFiles.of]).
  final List<SessionFile> outputs;

  /// Вложения, новые первыми.
  final List<SessionFile> attachments;

  final AttachmentStore store;
  final FileOpener opener;

  /// «Показать в сообщении»: закрыть панель и перейти к сообщению.
  final ValueChanged<String> onShowInMessage;

  /// Закрыть выдвижную панель или свернуть колонку.
  final VoidCallback onClose;
  final String closeTooltip;

  final DateTime now;

  /// Короткое сообщение пользователю («Не удалось открыть файл»).
  final ValueChanged<String>? onMessage;

  /// Как узнать о файле результата; по умолчанию — с диска.
  final SessionFileStatter? stat;

  @override
  State<SessionFilesPanel> createState() => _SessionFilesPanelState();
}

final class _SessionFilesPanelState extends State<SessionFilesPanel> {
  /// Сведения о результатах: путь и время карточки → что на диске. Файлов
  /// в сессии — десятки, а не тысячи: синхронный stat один раз на файл
  /// дешевле мерцания размера.
  final Map<String, SessionFileStat> _stats = <String, SessionFileStat>{};

  SessionFileStat _statOf(SessionFile file) {
    final path = file.absolute!;
    final key = '$path|${file.at.microsecondsSinceEpoch}';
    return _stats[key] ??= (widget.stat ?? _statOnDisk)(path);
  }

  /// Файл могли удалить вне приложения, пока колонка открыта (на
  /// компьютере она живёт долго): новый список — новое сообщение, смена
  /// сессии — проверяет диск заново.
  @override
  void didUpdateWidget(SessionFilesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.outputs, widget.outputs) ||
        oldWidget.stat != widget.stat) {
      _stats.clear();
    }
  }

  ({bool missing, bool folder, int? size}) _info(SessionFile file) {
    if (file.attachment case final ChatAttachment a) {
      return (missing: !widget.store.exists(a), folder: false, size: a.size);
    }
    final stat = _statOf(file);
    return (missing: !stat.exists, folder: stat.folder, size: stat.size);
  }

  String _when(DateTime at) {
    final now = widget.now;
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return today ? formatTime(at) : formatDay(at, now);
  }

  String _subtitle(
    SessionFile file,
    ({bool missing, bool folder, int? size}) i,
  ) {
    if (i.missing) return 'Файла больше нет';
    final what = file.isOutput
        ? ExtensionForms.title(file.extensionId ?? '')
        : file.kind.label;
    // Число и единица («70 Б», «1 ноября») не расходятся по строкам.
    // Переносы между частями расставляет [metaLines]: «·» не висит ни в
    // конце строки, ни в начале.
    return <String>[
      what,
      if (i.folder) 'папка',
      if (!i.folder && i.size != null)
        ChatAttachment.sizeLabel(i.size!).replaceAll(' ', '\u00A0'),
      _when(file.at).replaceAll(' ', '\u00A0'),
    ].join('\u00A0· ');
  }

  void _say(String text) => widget.onMessage?.call(text);

  Future<void> _open(SessionFile file) async {
    // Перед открытием — свежий взгляд на диск: удалённый файл ведёт к
    // его сообщению, а не к «Не удалось открыть файл».
    if (file.absolute != null) {
      final path = file.absolute!;
      _stats['$path|${file.at.microsecondsSinceEpoch}'] =
          (widget.stat ?? _statOnDisk)(path);
    }
    final info = _info(file);
    if (info.missing && mounted) setState(() {});
    if (info.missing) {
      widget.onShowInMessage(file.messageId);
      return;
    }
    final attachment = file.attachment;
    if (attachment != null) {
      final path = widget.store.pathOf(attachment);
      if (path == null) {
        // Хранилище «Только в памяти»: файла на диске нет — сведения.
        await showAttachmentInfo(context, attachment, widget.store);
        return;
      }
      if (!await widget.opener.open(path, name: attachment.name)) {
        _say('Не удалось открыть файл');
      }
      return;
    }
    if (info.folder && !widget.opener.canReveal) {
      // Папку на телефоне открыть нечем: её карточка — в сообщении.
      widget.onShowInMessage(file.messageId);
      return;
    }
    if (!await widget.opener.open(file.absolute!)) {
      _say('Не удалось открыть файл');
    }
  }

  Future<void> _reveal(SessionFile file) async {
    final path = file.absolute ??
        (file.attachment == null
            ? null
            : widget.store.pathOf(file.attachment!));
    if (path == null || !await widget.opener.reveal(path)) {
      _say('Не удалось открыть папку');
    }
  }

  void _act(SessionFile file, _FileAction action) {
    switch (action) {
      case _FileAction.open:
        unawaited(_open(file));
      case _FileAction.show:
        widget.onShowInMessage(file.messageId);
      case _FileAction.reveal:
        unawaited(_reveal(file));
      case _FileAction.info:
        unawaited(
          showAttachmentInfo(context, file.attachment!, widget.store),
        );
      case _FileAction.delete:
        widget.onDelete?.call(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final empty = widget.outputs.isEmpty && widget.attachments.isEmpty;
    return Material(
      key: const Key('session-files-panel'),
      color: colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.l,
              AppSpace.xs,
              AppSpace.xxs,
              AppSpace.xs,
            ),
            child: Row(
              // «×» — сверху справа, даже если заголовок в две строки.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  // Заголовок панели не растёт без конца: при крупном
                  // шрифте он не съедает пятую часть её высоты.
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.3,
                    // Одна строка — по центру «×» (цель 48, строка 25).
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        header: true,
                        child: WholeWordText(
                          'Файлы сессии',
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.33,
                            fontWeight: FontWeight.w600,
                            color: colors.textStrong,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('session-files-close'),
                  tooltip: widget.closeTooltip,
                  onPressed: widget.onClose,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(AppSize.minTap, AppSize.minTap),
                  ),
                  icon: Icon(Icons.close, color: colors.icon),
                ),
              ],
            ),
          ),
          Expanded(
            child: empty
                ? const _EmptyFiles()
                : ListView(
                    key: const Key('session-files-list'),
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    children: <Widget>[
                      if (widget.outputs.isNotEmpty)
                        InsetGroup(
                          header: 'Артефакты',
                          footer:
                              'Файлы, которые сделали расширения в этой сессии.',
                          children: <Widget>[
                            for (final file in widget.outputs) _row(file),
                          ],
                        ),
                      if (widget.attachments.isNotEmpty)
                        InsetGroup(
                          header: 'Вложения',
                          footer: 'Файлы хранятся на устройстве и никуда '
                              'не отправляются.',
                          children: <Widget>[
                            for (final file in widget.attachments) _row(file),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(SessionFile file) {
    final info = _info(file);
    return _FileRow(
      key: Key('session-file-${file.id}'),
      file: file,
      subtitle: _subtitle(file, info),
      missing: info.missing,
      folder: info.folder,
      actions: <_FileAction>[
        if (!info.missing) _FileAction.open,
        _FileAction.show,
        if (widget.opener.canReveal && !info.missing) _FileAction.reveal,
        if (file.attachment != null) _FileAction.info,
        if (widget.onDelete != null && !info.folder) _FileAction.delete,
      ],
      onTap: () => unawaited(_open(file)),
      onAction: (_FileAction action) => _act(file, action),
    );
  }
}

/// Строка файла: плитка вида, имя (до трёх строк), подпись; «⋯» — меню.
final class _FileRow extends StatefulWidget {
  const _FileRow({
    super.key,
    required this.file,
    required this.subtitle,
    required this.missing,
    required this.folder,
    required this.actions,
    required this.onTap,
    required this.onAction,
  });

  final SessionFile file;
  final String subtitle;
  final bool missing;
  final bool folder;
  final List<_FileAction> actions;
  final VoidCallback onTap;
  final ValueChanged<_FileAction> onAction;

  @override
  State<_FileRow> createState() => _FileRowState();
}

final class _FileRowState extends State<_FileRow> {
  /// Меню «⋯»: его же открывает долгое нажатие по строке.
  final GlobalKey<PopupMenuButtonState<_FileAction>> _menu =
      GlobalKey<PopupMenuButtonState<_FileAction>>();

  static String _label(_FileAction action) => switch (action) {
        _FileAction.open => 'Открыть',
        _FileAction.show => 'Показать в сообщении',
        _FileAction.reveal => 'Показать в папке',
        _FileAction.info => 'Сведения',
        _FileAction.delete => 'Удалить',
      };

  static IconData _icon(_FileAction action) => switch (action) {
        _FileAction.open => Icons.open_in_new,
        _FileAction.show => Icons.chat_bubble_outline,
        _FileAction.reveal => Icons.folder_outlined,
        _FileAction.info => Icons.info_outline,
        _FileAction.delete => Icons.delete_outline,
      };

  (IconData, Color) _tile(BuildContext context) {
    final colors = context.colors;
    final (:file, :missing, :folder) =
        (file: widget.file, missing: widget.missing, folder: widget.folder);
    if (missing) return (Icons.broken_image_outlined, colors.tileGray);
    if (folder) return (Icons.folder_outlined, colors.tileBlue);
    if (file.archive) return (Icons.inventory_2_outlined, colors.tileGray);
    return switch (file.kind) {
      AttachmentKind.image => (attachmentIcon(file.kind), colors.tileGreen),
      AttachmentKind.video => (attachmentIcon(file.kind), colors.tileViolet),
      AttachmentKind.audio => (attachmentIcon(file.kind), colors.tileAmber),
      AttachmentKind.document => (attachmentIcon(file.kind), colors.tileBlue),
      AttachmentKind.other => (attachmentIcon(file.kind), colors.tileGray),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final (:file, :missing, :subtitle) =
        (file: widget.file, missing: widget.missing, subtitle: widget.subtitle);
    final (icon, tile) = _tile(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            button: true,
            label: '${file.name}, $subtitle',
            hint: missing ? 'Показать в сообщении' : 'Открыть',
            excludeSemantics: true,
            onTap: widget.onTap,
            onLongPress: () => _menu.currentState?.showButtonMenu(),
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: () => _menu.currentState?.showButtonMenu(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSize.rowMin),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.rowH,
                    AppSpace.rowV,
                    0,
                    AppSpace.rowV,
                  ),
                  child: Row(
                    children: <Widget>[
                      IconTile(icon: icon, color: tile),
                      const SizedBox(width: AppSpace.s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            // Имя файла — до трёх строк по словам: не
                            // входит — чуть мельче, совсем длинное — «…».
                            WholeWordText(
                              file.name,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyLarge!.copyWith(
                                color:
                                    missing ? colors.muted : colors.textStrong,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: LayoutBuilder(
                                builder: (
                                  BuildContext context,
                                  BoxConstraints constraints,
                                ) {
                                  final style = text.bodyMedium!.copyWith(
                                    color:
                                        missing ? colors.warning : colors.muted,
                                  );
                                  return WholeWordText(
                                    metaLines(
                                      subtitle,
                                      DefaultTextStyle.of(context)
                                          .style
                                          .merge(style),
                                      MediaQuery.textScalerOf(context),
                                      constraints.maxWidth,
                                    ),
                                    style: style,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        PopupMenuButton<_FileAction>(
          key: _menu,
          tooltip: 'Действия: ${file.name}',
          onSelected: widget.onAction,
          style: IconButton.styleFrom(
            minimumSize: const Size(AppSize.minTap, AppSize.minTap),
          ),
          icon: Icon(
            Icons.more_horiz,
            key: Key('session-file-more-${file.id}'),
            color: colors.icon,
          ),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<_FileAction>>[
            for (final action in widget.actions)
              PopupMenuItem<_FileAction>(
                key: Key('session-file-${action.name}'),
                value: action,
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(_label(action))),
                    const SizedBox(width: AppSpace.s),
                    Icon(_icon(action), size: 20, color: colors.icon),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(width: AppSpace.xxs),
      ],
    );
  }
}

/// Пусто: ни вложений, ни результатов.
final class _EmptyFiles extends StatelessWidget {
  const _EmptyFiles();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return ListView(
      key: const Key('session-files-empty'),
      padding: const EdgeInsets.all(AppSpace.xl),
      children: <Widget>[
        const SizedBox(height: AppSpace.xxl),
        Icon(Icons.folder_open_outlined, size: 40, color: colors.faint),
        const SizedBox(height: AppSpace.s),
        WholeWordText(
          'Здесь пока пусто',
          textAlign: TextAlign.center,
          style: text.bodyLarge!.copyWith(
            fontWeight: FontWeight.w600,
            color: colors.textStrong,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        WholeWordText(
          'Сюда попадут файлы, которые вы прикрепите, и то, что сделают '
          'расширения: конвертер, архиватор и загрузчик видео.',
          textAlign: TextAlign.center,
          style: text.bodyMedium!.copyWith(color: colors.muted),
        ),
      ],
    );
  }
}

/// Подпись из частей через « · » ([subtitle]) по строкам ширины
/// [maxWidth]: части не рвутся, строки делятся только между ними, и «·»
/// там не пишется — строка не кончается и не начинается голой точкой
/// («Архиватор / 2 КБ · 12:00», а не «Архиватор · / 2 КБ»). Входит
/// целиком — та же строка.
String metaLines(
  String subtitle,
  TextStyle style,
  TextScaler scaler,
  double maxWidth,
) {
  const separator = '\u00A0· ';
  final parts = subtitle.split(separator);
  if (parts.length < 2 || !maxWidth.isFinite) return subtitle;
  double width(String line) {
    final painter = TextPainter(
      text: TextSpan(text: line, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  if (width(subtitle) <= maxWidth) return subtitle;
  final lines = <String>[];
  var line = parts.first;
  for (final part in parts.skip(1)) {
    final joined = '$line$separator$part';
    if (width(joined) <= maxWidth) {
      line = joined;
    } else {
      lines.add(line);
      line = part;
    }
  }
  lines.add(line);
  return lines.join('\n');
}
