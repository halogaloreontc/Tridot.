import 'dart:async';

import 'package:flutter/material.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_projects.dart';
import '../core/models/task.dart';
import 'widget_session.dart';

/// Левая колонка (широкая панель) или выдвижное меню (узкая панель,
/// телефон): задачи, проекты, разговоры — как меню сессий Tridot, но
/// компактно, для склада.
final class WidgetSide extends StatelessWidget {
  const WidgetSide({super.key, required this.session, this.onPicked});

  final WidgetSession session;

  /// Выбрали разговор — в узкой панели меню закрывается.
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final book = session.book;
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    if (book == null) return const SizedBox.shrink();
    final groups = book.groups(DateTime.now());
    final projects = book.projects();
    bool loose(ChatThread t) => t.projectId == null;
    final tasks = session.taskList;
    Widget title(String label, {Widget? action}) => Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.m,
            AppSpace.m,
            AppSpace.xxs,
            AppSpace.xxs,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: text.labelMedium?.copyWith(color: colors.muted),
                ),
              ),
              if (action != null) action,
            ],
          ),
        );
    final days = <(String, List<ChatThread>)>[
      ('Закреплённые', groups.pinned),
      ('Сегодня', groups.today.where(loose).toList()),
      ('Вчера', groups.yesterday.where(loose).toList()),
      ('Неделя', groups.week.where(loose).toList()),
      ('Раньше', groups.earlier.where(loose).toList()),
    ];
    return ColoredBox(
      color: colors.raised,
      child: ListView(
        key: const ValueKey<String>('widget-side'),
        padding: const EdgeInsets.only(bottom: AppSpace.l),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.s,
              AppSpace.s,
              AppSpace.s,
              0,
            ),
            child: FilledButton.tonalIcon(
              key: const ValueKey<String>('side-new'),
              onPressed: session.busy
                  ? null
                  : () {
                      unawaited(session.newChat());
                      onPicked?.call();
                    },
              icon: const Icon(Icons.add_comment_outlined, size: 18),
              label: const Text('Новый разговор'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.m,
              AppSpace.xs,
              AppSpace.m,
              0,
            ),
            child: Text(
              session.synced
                  ? 'Хранится на складе — видно с любого устройства.'
                  : 'Хранится только в этом браузере: склад пока не '
                      'хранит записи помощника.',
              key: const ValueKey<String>('side-sync'),
              style: text.bodySmall?.copyWith(color: colors.muted),
            ),
          ),
          title(
            'Задачи',
            action: tasks.isEmpty
                ? null
                : Text(
                    '${tasks.where((Task t) => t.status != TaskStatus.done).length}',
                    style: text.labelSmall?.copyWith(color: colors.muted),
                  ),
          ),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
              child: Text(
                'Скажите: «напомни завтра проверить акт 12-26».',
                style: text.bodySmall?.copyWith(color: colors.muted),
              ),
            ),
          for (final task in tasks.take(12))
            _TaskRow(session: session, task: task, onPicked: onPicked),
          title(
            'Проекты',
            action: IconButton(
              key: const ValueKey<String>('side-project-new'),
              tooltip: 'Новый проект',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.create_new_folder_outlined,
                size: 18,
                color: colors.icon,
              ),
              onPressed: () => unawaited(_newProject(context)),
            ),
          ),
          for (final project in projects)
            _ProjectTile(
              session: session,
              project: project,
              onPicked: onPicked,
            ),
          for (final (label, list) in days)
            if (list.isNotEmpty) ...<Widget>[
              title(label),
              for (final thread in list)
                ChatRow(session: session, thread: thread, onPicked: onPicked),
            ],
        ],
      ),
    );
  }

  Future<void> _newProject(BuildContext context) async {
    final name = await askText(
      context,
      title: 'Новый проект',
      hint: 'Название: «Брак Ромашка»',
    );
    if (name == null) return;
    session.createProject(name);
  }
}

/// Строка разговора: открыть по нажатию, меню — переименовать,
/// закрепить, в проект, удалить.
final class ChatRow extends StatelessWidget {
  const ChatRow({
    super.key,
    required this.session,
    required this.thread,
    this.onPicked,
    this.indent = 0,
  });

  final WidgetSession session;
  final ChatThread thread;
  final VoidCallback? onPicked;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final book = session.book!;
    final current = thread.id == book.currentId;
    final taskTitle = thread.kind == ChatKind.task
        ? session.taskList
            .where((Task t) => t.id == thread.taskId)
            .firstOrNull
            ?.title
        : null;
    final name = ChatBook.titleOf(thread, taskTitle: taskTitle);
    return Material(
      color: current ? colors.workspace : Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('chat-${thread.id}'),
        onTap: () {
          unawaited(session.openChat(thread.id));
          onPicked?.call();
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpace.m + indent, 2, 0, 2),
          child: Row(
            children: <Widget>[
              if (thread.pinned)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpace.xxs),
                  child: Icon(Icons.push_pin, size: 14, color: colors.muted),
                ),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: current ? colors.textStrong : colors.text,
                    fontWeight: thread.unread ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (thread.messageCount > 0)
                PopupMenuButton<String>(
                  key: ValueKey<String>('chat-menu-${thread.id}'),
                  tooltip: 'Действия',
                  icon: Icon(Icons.more_horiz, size: 18, color: colors.icon),
                  onSelected: (String v) => unawaited(_act(context, v)),
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    if (thread.isSession)
                      const PopupMenuItem<String>(
                        value: 'rename',
                        child: Text('Переименовать'),
                      ),
                    PopupMenuItem<String>(
                      value: 'pin',
                      child: Text(thread.pinned ? 'Открепить' : 'Закрепить'),
                    ),
                    if (thread.isSession)
                      const PopupMenuItem<String>(
                        value: 'move',
                        child: Text('В проект…'),
                      ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Удалить'),
                    ),
                  ],
                ),
              if (thread.messageCount == 0) const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    switch (action) {
      case 'rename':
        final name = await askText(
          context,
          title: 'Переименовать',
          initial: ChatBook.titleOf(thread),
        );
        if (name != null) session.renameChat(thread.id, name);
      case 'pin':
        session.pinChat(thread.id, pinned: !thread.pinned);
      case 'move':
        if (!context.mounted) return;
        final target = await pickProject(context, session, thread.projectId);
        if (target != null) {
          session.moveChat(thread.id, target.isEmpty ? null : target);
        }
      case 'delete':
        if (!context.mounted) return;
        final ok = await confirm(
          context,
          'Удалить разговор?',
          thread.kind == ChatKind.task
              ? 'Сама задача останется.'
              : 'Его не будет ни здесь, ни на складе.',
        );
        if (ok) await session.deleteChat(thread.id);
    }
  }
}

final class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.session,
    required this.project,
    this.onPicked,
  });

  final WidgetSession session;
  final ChatProject project;
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final sessions = session.book!.sessionsOf(project.id);
    return ExpansionTile(
      key: ValueKey<String>('project-${project.id}'),
      dense: true,
      tilePadding: const EdgeInsets.only(left: AppSpace.m, right: 0),
      childrenPadding: EdgeInsets.zero,
      leading: Icon(
        project.pinnedAt != null ? Icons.folder_special : Icons.folder_outlined,
        size: 18,
        color: colors.icon,
      ),
      title: Text(
        project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: colors.text),
      ),
      subtitle: project.taskTag == null
          ? null
          : Text('#${project.taskTag}', style: text.bodySmall),
      trailing: PopupMenuButton<String>(
        key: ValueKey<String>('project-menu-${project.id}'),
        tooltip: 'Действия',
        icon: Icon(Icons.more_horiz, size: 18, color: colors.icon),
        onSelected: (String v) => unawaited(_act(context, v)),
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(
            value: 'new',
            child: Text('Новый разговор в проекте'),
          ),
          const PopupMenuItem<String>(
            value: 'rename',
            child: Text('Переименовать'),
          ),
          PopupMenuItem<String>(
            value: 'pin',
            child: Text(project.pinnedAt != null ? 'Открепить' : 'Закрепить'),
          ),
          const PopupMenuItem<String>(
            value: 'delete',
            child: Text('Удалить проект'),
          ),
        ],
      ),
      children: <Widget>[
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl,
              0,
              AppSpace.m,
              AppSpace.xs,
            ),
            child: Text('Разговоров пока нет', style: text.bodySmall),
          ),
        for (final thread in sessions)
          ChatRow(
            session: session,
            thread: thread,
            onPicked: onPicked,
            indent: AppSpace.m,
          ),
      ],
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    switch (action) {
      case 'new':
        await session.newChat(projectId: project.id);
        onPicked?.call();
      case 'rename':
        final name = await askText(
          context,
          title: 'Переименовать проект',
          initial: project.name,
        );
        if (name != null) session.renameProject(project.id, name);
      case 'pin':
        session.pinProject(project.id, pinned: project.pinnedAt == null);
      case 'delete':
        final ok = await confirm(
          context,
          'Удалить проект «${project.name}»?',
          'Разговоры и задачи останутся — без проекта.',
        );
        if (ok) await session.deleteProject(project.id);
    }
  }
}

final class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.session, required this.task, this.onPicked});

  final WidgetSession session;
  final Task task;
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final done = task.status == TaskStatus.done;
    final late = session.overdue(task);
    final due = task.dueAt;
    return InkWell(
      key: ValueKey<String>('task-${task.id}'),
      onTap: () {
        unawaited(session.openTask(task.id));
        onPicked?.call();
      },
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpace.xxs),
        child: Row(
          children: <Widget>[
            Checkbox(
              key: ValueKey<String>('task-done-${task.id}'),
              value: done,
              visualDensity: VisualDensity.compact,
              onChanged: (bool? v) => unawaited(
                v ?? false
                    ? session.completeTask(task.id)
                    : session.reopenTask(task.id),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: done ? colors.muted : colors.text,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (due != null)
                    Text(
                      dueLabel(task),
                      style: text.bodySmall?.copyWith(
                        color: late ? colors.danger : colors.muted,
                      ),
                    ),
                ],
              ),
            ),
            if (!done)
              IconButton(
                key: ValueKey<String>('task-due-${task.id}'),
                tooltip: 'Срок',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.event_outlined, size: 18, color: colors.icon),
                onPressed: () => unawaited(_pickDue(context)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDue(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: task.dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: 'Срок задачи',
    );
    if (picked != null) await session.setDue(task.id, picked);
  }
}

/// «18.11», «18.11 15:00».
String dueLabel(Task task) {
  final d = task.dueAt?.toLocal();
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${two(d.day)}.${two(d.month)}';
  return task.duePrecision == DuePrecision.dateTime
      ? '$day ${two(d.hour)}:${two(d.minute)}'
      : day;
}

/// Строка текста в окне; `null` — отмена.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const ValueKey<String>('ask-text'),
        controller: controller,
        autofocus: true,
        maxLength: ChatThread.customTitleLimit,
        decoration: InputDecoration(hintText: hint, counterText: ''),
        onSubmitted: (String v) => Navigator.of(context).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey<String>('ask-ok'),
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Готово'),
        ),
      ],
    ),
  ).then((String? v) => v == null || v.trim().isEmpty ? null : v.trim());
}

Future<bool> confirm(BuildContext context, String title, String body) =>
    showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirm-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Да'),
          ),
        ],
      ),
    ).then((bool? v) => v ?? false);

/// Куда перенести разговор: id проекта, `''` — «Без проекта», `null` —
/// отмена.
Future<String?> pickProject(
  BuildContext context,
  WidgetSession session,
  String? current,
) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('В проект'),
        children: <Widget>[
          for (final p in session.book?.projects() ?? const <ChatProject>[])
            SimpleDialogOption(
              key: ValueKey<String>('pick-${p.id}'),
              onPressed: () => Navigator.of(context).pop(p.id),
              child: Text(p.id == current ? '${p.name} ✓' : p.name),
            ),
          if (current != null)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('Без проекта'),
            ),
          SimpleDialogOption(
            key: const ValueKey<String>('pick-new'),
            onPressed: () async {
              final name = await askText(context, title: 'Новый проект');
              if (!context.mounted) return;
              final project = name == null ? null : session.createProject(name);
              Navigator.of(context).pop(project?.id);
            },
            child: const Text('Новый проект…'),
          ),
        ],
      ),
    );
