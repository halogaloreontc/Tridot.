import 'package:flutter/material.dart';

import '../../core/chats/attachments.dart';
import '../assistant_theme.dart';

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
