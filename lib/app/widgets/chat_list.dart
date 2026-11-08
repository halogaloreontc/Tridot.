import 'package:flutter/material.dart';

import '../assistant_theme.dart';

/// Чат задачи в боковом меню.
final class ChatListEntry {
  const ChatListEntry({
    required this.taskId,
    required this.title,
    this.done = false,
    this.unread = false,
    this.active = false,
  });

  final String taskId;

  /// Текущее название задачи.
  final String title;

  /// Задача выполнена: пункт приглушён.
  final bool done;
  final bool unread;
  final bool active;
}

/// Блок «Чаты» в боковом меню: «Главный» и последние чаты задач по
/// активности. В свёрнутом меню (узкая полоса значков) — те же чаты
/// значками: название — в подсказке, новое сообщение — точкой.
final class ChatList extends StatelessWidget {
  const ChatList({
    super.key,
    required this.expanded,
    required this.mainActive,
    required this.mainUnread,
    required this.entries,
    required this.onOpenMain,
    required this.onOpenTask,
  });

  final bool expanded;
  final bool mainActive;
  final bool mainUnread;
  final List<ChatListEntry> entries;
  final VoidCallback onOpenMain;
  final ValueChanged<String> onOpenTask;

  @override
  Widget build(BuildContext context) {
    final main = _ChatItem(
      itemKey: const Key('chat-main'),
      dotKey: const Key('chat-unread-main'),
      icon: Icons.forum_outlined,
      title: 'Главный',
      expanded: expanded,
      active: mainActive,
      unread: mainUnread,
      onTap: onOpenMain,
    );
    final items = <Widget>[
      for (final entry in entries)
        _ChatItem(
          itemKey: Key('chat-${entry.taskId}'),
          dotKey: Key('chat-unread-${entry.taskId}'),
          icon: entry.done
              ? Icons.check_circle_outline
              : Icons.chat_bubble_outline,
          title: entry.title,
          expanded: expanded,
          active: entry.active,
          unread: entry.unread,
          muted: entry.done,
          onTap: () => onOpenTask(entry.taskId),
        ),
    ];
    if (!expanded) {
      return Column(
        key: const Key('chats-menu'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          main,
          ...items,
          if (items.isNotEmpty) const Divider(indent: 12, endIndent: 12),
        ],
      );
    }
    return Column(
      key: const Key('chats-menu'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Text(
            'Чаты',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: technicalTextStyle,
          ),
        ),
        main,
        ...items,
        const SizedBox(height: 4),
        const Divider(indent: 12, endIndent: 12),
      ],
    );
  }
}

final class _ChatItem extends StatelessWidget {
  const _ChatItem({
    required this.itemKey,
    required this.dotKey,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.active,
    required this.unread,
    required this.onTap,
    this.muted = false,
  });

  final Key itemKey;
  final Key dotKey;
  final IconData icon;
  final String title;
  final bool expanded;
  final bool active;
  final bool unread;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AssistantColors.textStrong
        : muted
            ? AssistantColors.muted
            : AssistantColors.text;
    final dot = unread
        ? Container(
            key: dotKey,
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AssistantColors.textStrong,
              shape: BoxShape.circle,
            ),
          )
        : null;
    final iconWidget = Icon(icon, size: 18, color: color);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 8, vertical: 2),
      child: Tooltip(
        message: unread ? '$title — новое сообщение' : title,
        child: Semantics(
          button: true,
          selected: active,
          label: unread ? 'Чат «$title», новое сообщение' : 'Чат «$title»',
          excludeSemantics: true,
          child: InkWell(
            key: itemKey,
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
              decoration: BoxDecoration(
                color: active ? AssistantColors.raised : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: expanded
                  ? Row(
                      children: <Widget>[
                        iconWidget,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: color),
                          ),
                        ),
                        if (dot != null) ...<Widget>[
                          const SizedBox(width: 8),
                          dot,
                        ],
                      ],
                    )
                  : Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          iconWidget,
                          if (dot != null)
                            Positioned(right: -4, top: -2, child: dot),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
