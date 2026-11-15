import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chats/chat_projects.dart';
import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import '../shell/relay_drawer.dart';
import '../shell/session_hold_menu.dart';
import '../widgets/grouped.dart';
import '../widgets/task_tile.dart';

/// Действие с самим проектом из меню «⋯» на его экране.
enum ProjectAction {
  /// «Переименовать».
  rename,

  /// «Описание».
  describe,

  /// «Метка задач»: связать с меткой или снять связь.
  tag,

  /// «Закрепить» / «Открепить».
  pin,

  /// «Удалить проект».
  delete,
}

/// Экран проекта-папки (ADR-018): название, описание, «Новая сессия в
/// проекте», сессии проекта (закреплённые сверху; нажатие открывает,
/// долгое нажатие — то же меню, что в панели) и, если проект связан с
/// меткой, задачи с этой меткой. Меню «⋯» — действия с проектом.
///
/// Своего состояния нет: всё приходит параметрами и колбэками.
final class ProjectScreen extends StatelessWidget {
  const ProjectScreen({
    super.key,
    required this.project,
    required this.sessions,
    required this.tasks,
    required this.now,
    required this.onNewSession,
    required this.onOpenSession,
    required this.onAction,
    this.onSessionAction,
    this.selectedTaskId,
    this.onOpenTask,
    this.onToggleDone,
    this.reduceMotion = false,
  });

  final ChatProject project;

  /// Строки сессий проекта по порядку.
  final List<SessionEntry> sessions;

  /// Активные задачи с меткой проекта ([ChatProject.taskTag]).
  final List<Task> tasks;
  final DateTime now;
  final VoidCallback onNewSession;
  final ValueChanged<String> onOpenSession;
  final ValueChanged<ProjectAction> onAction;
  final void Function(String id, SessionAction action)? onSessionAction;
  final String? selectedTaskId;
  final ValueChanged<Task>? onOpenTask;
  final ValueChanged<Task>? onToggleDone;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final tag = project.taskTag;
    return ListView(
      key: const Key('project-screen'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      children: <Widget>[
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: EdgeInsets.only(top: 2, right: 10),
                      child: IconTile(
                        icon: Icons.folder_outlined,
                        color: context.colors.tileAmber,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        project.name,
                        key: const Key('project-title'),
                        style: projectNameStyle(
                          fontSize: 26,
                          color: context.colors.textStrong,
                        ),
                      ),
                    ),
                    _ProjectMenu(pinned: project.pinned, onAction: onAction),
                  ],
                ),
                if (project.description != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    project.description!,
                    key: const Key('project-description'),
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge!
                        .copyWith(color: context.colors.muted),
                  ),
                ],
                if (tag != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'Метка задач: #$tag — новая задача из сессий проекта '
                    'получает её, если в команде нет своей.',
                    key: const Key('project-tag'),
                    style: metaStyle(context),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('project-new-session'),
                    onPressed: onNewSession,
                    icon: const Icon(Icons.add),
                    label: const Text('Новая сессия в проекте'),
                  ),
                ),
                const SizedBox(height: 16),
                SectionLabel('Сессии · ${sessions.length}'),
                if (sessions.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Text(
                      'В проекте пока нет сессий. Начните новую или '
                      'перенесите готовую: долгое нажатие на сессию → '
                      '«В проект…».',
                      key: Key('project-empty'),
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium!
                          .copyWith(color: context.colors.muted),
                    ),
                  )
                else
                  InsetGroup(
                    margin: EdgeInsets.zero,
                    children: <Widget>[
                      for (final entry in sessions)
                        _ProjectSessionRow(
                          entry: entry,
                          reduceMotion: reduceMotion,
                          onTap: () => onOpenSession(entry.id),
                          onAction: onSessionAction == null
                              ? null
                              : (SessionAction action) =>
                                  onSessionAction!(entry.id, action),
                        ),
                    ],
                  ),
                if (tag != null) ...<Widget>[
                  const SizedBox(height: 16),
                  SectionLabel('Задачи #$tag · ${tasks.length}'),
                  if (tasks.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: Text(
                        'Активных задач с этой меткой нет.',
                        style: metaStyle(context),
                      ),
                    )
                  else
                    for (final (group, list) in groupTasks(tasks, now))
                      InsetGroup(
                        header: '${group.title} · ${list.length}',
                        headerDanger: group == TaskGroup.overdue,
                        margin: const EdgeInsets.only(top: 12),
                        children: <Widget>[
                          for (final task in list)
                            TaskTile(
                              task: task,
                              now: now,
                              selected: task.id == selectedTaskId,
                              showProject: false,
                              onTap: () => onOpenTask?.call(task),
                              onToggleDone: () => onToggleDone?.call(task),
                            ),
                        ],
                      ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _ProjectMenu extends StatelessWidget {
  const _ProjectMenu({required this.pinned, required this.onAction});

  final bool pinned;
  final ValueChanged<ProjectAction> onAction;

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<ProjectAction> item(
      ProjectAction action,
      String key,
      IconData icon,
      String label, {
      bool danger = false,
    }) =>
        PopupMenuItem<ProjectAction>(
          key: Key('project-menu-$key'),
          value: action,
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 20,
                color: danger ? context.colors.danger : context.colors.icon,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: danger ? context.colors.danger : null,
                  ),
                ),
              ),
            ],
          ),
        );
    return PopupMenuButton<ProjectAction>(
      key: const Key('project-menu'),
      tooltip: 'Действия с проектом',
      icon: Icon(Icons.more_horiz, color: context.colors.accent),
      onSelected: onAction,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<ProjectAction>>[
        item(
          ProjectAction.rename,
          'rename',
          Icons.edit_outlined,
          'Переименовать',
        ),
        item(
          ProjectAction.describe,
          'describe',
          Icons.notes_outlined,
          'Описание',
        ),
        item(ProjectAction.tag, 'tag', Icons.sell_outlined, 'Метка задач'),
        item(
          ProjectAction.pin,
          'pin',
          pinned ? Icons.push_pin : Icons.push_pin_outlined,
          pinned ? 'Открепить' : 'Закрепить',
        ),
        const PopupMenuDivider(),
        item(
          ProjectAction.delete,
          'delete',
          Icons.delete_outline,
          'Удалить проект',
          danger: true,
        ),
      ],
    );
  }
}

/// Строка сессии на экране проекта: как в панели, долгое нажатие и правая
/// кнопка — меню сессии.
final class _ProjectSessionRow extends StatefulWidget {
  const _ProjectSessionRow({
    required this.entry,
    required this.reduceMotion,
    required this.onTap,
    required this.onAction,
  });

  final SessionEntry entry;
  final bool reduceMotion;
  final VoidCallback onTap;
  final ValueChanged<SessionAction>? onAction;

  @override
  State<_ProjectSessionRow> createState() => _ProjectSessionRowState();
}

final class _ProjectSessionRowState extends State<_ProjectSessionRow> {
  bool _held = false;

  bool get _acts => widget.entry.canAct && widget.onAction != null;

  Future<void> _openMenu() async {
    final onAction = widget.onAction;
    if (!_acts || onAction == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _held = true);
    final action = await showSessionHoldMenu(
      context,
      rowRect: rect,
      title: widget.entry.title,
      pinned: widget.entry.pinned,
      canRename: widget.entry.canRename,
      canMove: widget.entry.canMove,
      reduceMotion: widget.reduceMotion,
      liftedRow: SessionRowBody(entry: widget.entry, wide: false),
    );
    if (!mounted) return;
    setState(() => _held = false);
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Semantics(
      button: true,
      selected: entry.active,
      label: <String>[
        'Сессия «${entry.title}»',
        if (entry.pinned) 'закреплена',
        if (entry.preview != null) entry.preview!,
      ].join(', '),
      onTap: widget.onTap,
      onLongPress: _acts ? _openMenu : null,
      excludeSemantics: true,
      child: InkWell(
        key: Key('project-session-${entry.id}'),
        onTap: widget.onTap,
        onLongPress: _acts ? _openMenu : null,
        onSecondaryTap: _acts ? _openMenu : null,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          opacity: _held ? 0 : 1,
          child: SessionRowBody(entry: entry, wide: false),
        ),
      ),
    );
  }
}
