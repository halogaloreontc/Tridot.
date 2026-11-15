import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/chats/attachments.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/app_dialog.dart';

/// Значок вида вложения (ADR-019).
IconData attachmentIcon(AttachmentKind kind) => switch (kind) {
      AttachmentKind.image => Icons.image_outlined,
      AttachmentKind.video => Icons.movie_outlined,
      AttachmentKind.audio => Icons.audiotrack_outlined,
      AttachmentKind.document => Icons.description_outlined,
      AttachmentKind.other => Icons.insert_drive_file_outlined,
    };

/// Чип файла: значок, имя и размер; [onRemove] — крестик (файл ещё не
/// отправлен), [missing] — копии больше нет.
final class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.name,
    required this.kind,
    required this.size,
    this.onTap,
    this.onRemove,
    this.missing = false,
  });

  final String name;
  final AttachmentKind kind;
  final int size;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final detail = missing ? 'файл не найден' : ChatAttachment.sizeLabel(size);
    return Semantics(
      label: '${kind.label}: $name, $detail',
      button: onTap != null,
      excludeSemantics: onRemove == null,
      child: Material(
        color: context.colors.raised,
        // Заливкой без рамки (ADR-027).
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, minHeight: 40),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 4, onRemove == null ? 12 : 0, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    missing
                        ? Icons.broken_image_outlined
                        : attachmentIcon(kind),
                    size: 18,
                    color: context.colors.icon,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: context.colors.textStrong,
                          ),
                        ),
                        Text(
                          detail,
                          style: metaStyle(context).copyWith(
                            color: missing
                                ? context.colors.warning
                                : context.colors.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onRemove != null)
                    IconButton(
                      tooltip: 'Убрать файл',
                      onPressed: onRemove,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Вложения сообщения: картинки — превью, остальное — чипы. Нажатие
/// открывает сведения о файле (никуда его не отправляет).
final class MessageAttachments extends StatelessWidget {
  const MessageAttachments({
    super.key,
    required this.attachments,
    required this.store,
    this.alignEnd = false,
  });

  final List<ChatAttachment> attachments;
  final AttachmentStore store;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.xs,
      runSpacing: AppSpace.xs,
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      children: <Widget>[
        for (final attachment in attachments)
          _AttachmentView(
            key: ValueKey<String>('attachment-${attachment.id}'),
            attachment: attachment,
            store: store,
          ),
      ],
    );
  }
}

final class _AttachmentView extends StatelessWidget {
  const _AttachmentView({
    super.key,
    required this.attachment,
    required this.store,
  });

  final ChatAttachment attachment;
  final AttachmentStore store;

  @override
  Widget build(BuildContext context) {
    final exists = store.exists(attachment);
    void open() => showAttachmentInfo(context, attachment, store);
    if (exists && attachment.kind == AttachmentKind.image) {
      final preview = _preview();
      if (preview != null) {
        return Semantics(
          label: 'Фото: ${attachment.name}',
          button: true,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: open,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 240, maxHeight: 240),
                child: preview,
              ),
            ),
          ),
        );
      }
    }
    return AttachmentChip(
      name: attachment.name,
      kind: attachment.kind,
      size: attachment.size,
      missing: !exists,
      onTap: open,
    );
  }

  Widget? _preview() {
    Widget fallback(BuildContext context, Object error, StackTrace? stack) =>
        AttachmentChip(
          name: attachment.name,
          kind: attachment.kind,
          size: attachment.size,
        );
    // cacheWidth: большая фотография не раскрывается в память целиком.
    final path = store.pathOf(attachment);
    if (path != null) {
      return Image.file(
        File(path),
        key: ValueKey<String>('attachment-preview-${attachment.id}'),
        cacheWidth: 480,
        fit: BoxFit.cover,
        errorBuilder: fallback,
      );
    }
    final bytes = store.bytesOf(attachment);
    if (bytes != null) {
      return Image.memory(
        bytes,
        key: ValueKey<String>('attachment-preview-${attachment.id}'),
        cacheWidth: 480,
        fit: BoxFit.cover,
        errorBuilder: fallback,
      );
    }
    return null;
  }
}

/// Сведения о вложении: имя, вид, размер и где лежит копия.
Future<void> showAttachmentInfo(
  BuildContext context,
  ChatAttachment attachment,
  AttachmentStore store,
) {
  final exists = store.exists(attachment);
  final path = store.pathOf(attachment);
  // Своя ручка ([SheetHandle]) вместо ручки темы с полем 48; при крупном
  // шрифте сведения листаются, а не вылезают за край.
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
    ),
    builder: (BuildContext context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('attachment-info'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SheetHandle(),
            // Значок — у первой строки имени, а не посреди двух строк.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(
                    top: math.max(
                      0,
                      (MediaQuery.textScalerOf(context).scale(16) * 1.3 - 20) /
                          2,
                    ),
                  ),
                  child: Icon(attachmentIcon(attachment.kind), size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    attachment.name,
                    style: TextStyle(
                      fontSize: 16,
                      color: context.colors.textStrong,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${attachment.kind.label} · '
              '${ChatAttachment.sizeLabel(attachment.size)}',
              style: metaStyle(context),
            ),
            const SizedBox(height: 12),
            Text(
              exists
                  ? 'Файл сохранён в этой сессии и никуда не отправлялся. '
                      'Сжать или распаковать — скажите «сожми в zip» или '
                      '«распакуй архив» (расширение «Архиватор»), сменить '
                      'формат — «сконвертируй файл» (расширение «Конвертер»).'
                  : 'Файла больше нет на устройстве.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            if (exists && path != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(path, style: metaStyle(context)),
            ],
          ],
        ),
      ),
    ),
  );
}
