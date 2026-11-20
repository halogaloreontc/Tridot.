import 'dart:async';

import 'package:flutter/material.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../app/screens/planning_screen.dart';
import '../app/screens/project_screen.dart';
import '../app/screens/projects_screen.dart';
import '../app/shell/project_dialogs.dart';
import '../app/shell/relay_drawer.dart';
import '../app/shell/session_hold_menu.dart';
import '../app/shell/today_panel.dart';
import '../app/widgets/grouped.dart';
import '../app/widgets/task_tile.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_search.dart';
import '../core/formatting/due_format.dart';
import '../core/models/action_card.dart';
import '../core/models/task.dart';
import '../core/personas/persona.dart';
import 'widget_session.dart';

// Меню и экраны веб-помощника — те же виджеты, что в приложении (ADR-038):
// RelayDrawer (сессии по дням, проекты, «Мой Связной»), ProjectScreen,
// ProjectsScreen, PlanningScreen, TodayPanel. Здесь только данные из
// WidgetSession и действия меню.

/// Помощник в вебе один — Связной.
const List<Persona> widgetCast = <Persona>[Personas.sado];

/// Активные задачи.
List<Task> activeTasks(WidgetSession session) => <Task>[
      for (final task in session.taskList)
        if (task.isActive) task,
    ];

/// Меню приложения: колонкой слева ([wide]) или выдвижное.
Widget widgetDrawer(
  BuildContext context,
  WidgetSession session, {
  required bool wide,
  required int sessionsShown,
  required VoidCallback onShowMore,
  VoidCallback? onCollapse,
  VoidCallback? onPicked,
}) {
  final book = session.book!;
  final now = DateTime.now();
  final active = activeTasks(session);
  final groups = book.groups(now, limit: sessionsShown);
  void picked(void Function() action) {
    action();
    onPicked?.call();
  }

  SessionGroupEntry group(String id, String label, List<ChatThread> list) =>
      SessionGroupEntry(
        id: id,
        label: label,
        entries: <SessionEntry>[
          for (final thread in list)
            if (sessionEntry(session, thread, now, id)
                case final SessionEntry e)
              e,
        ],
      );
  final planning = upcomingCount(active, now);
  final projects = book.projects();
  return RelayDrawer(
    wide: wide,
    onCollapse: onCollapse,
    assistants: widgetCast,
    activeSection: switch (session.view) {
      WidgetView.tasks => 'tasks',
      WidgetView.projects => 'projects',
      WidgetView.planning => 'planning',
      _ => null,
    },
    projects: <ProjectEntry>[
      for (final project in projects)
        ProjectEntry(
          id: project.id,
          name: project.name,
          sessions: book.projectSessionCount(project.id),
          active: session.view == WidgetView.project &&
              session.projectId == project.id,
        ),
    ],
    onOpenProject: (String id) =>
        picked(() => session.show(WidgetView.project, project: id)),
    onNewProject: () => unawaited(
      createProject(context, session).then((_) => onPicked?.call()),
    ),
    groups: <SessionGroupEntry>[
      group('pinned', 'Закреплённые', groups.pinned),
      group('today', 'Сегодня', groups.today),
      group('yesterday', 'Вчера', groups.yesterday),
      group('week', 'На неделе', groups.week),
      group('earlier', 'Ранее', groups.earlier),
    ],
    hiddenSessions: groups.hidden,
    onShowMoreSessions: onShowMore,
    counts: SectionCounts(
      tasks: active.length,
      overdue: active.where((Task t) => isOverdue(t, now)).length,
      projects: projects.isEmpty ? null : projects.length,
      planning: planning == 0 ? null : planning,
    ),
    extensions: <ExtensionEntry>[
      ExtensionEntry(
        id: 'warehouse',
        title: 'Склад',
        icon: Icons.inventory_2_outlined,
        status: 'на связи',
        statusColor: context.colors.success,
        dot: true,
        onTap: () => picked(session.openWarehouse),
      ),
    ],
    onOpenMyRelay: () => picked(() => session.show(WidgetView.today)),
    onTasks: () => picked(() => session.show(WidgetView.tasks)),
    onProjects: () => picked(() => session.show(WidgetView.projects)),
    onPlanning: () => picked(() => session.show(WidgetView.planning)),
    onOpenSession: (String id) => picked(() => openEntry(session, id)),
    onNewSession: () => picked(() => unawaited(session.newChat())),
    onSessionAction: (String id, SessionAction action) =>
        unawaited(sessionAction(context, session, id, action)),
    search: (String query) => book.search(
      query,
      titles: <String, String>{
        for (final task in session.taskList) task.id: task.title,
      },
    ),
    onOpenHit: (ChatSearchHit hit) =>
        picked(() => openEntry(session, hit.chatId)),
    timeLabel: (DateTime at) => sessionTimeLabel(at, DateTime.now()),
  );
}

/// Строка разговора в меню и на экране проекта — как в приложении.
SessionEntry? sessionEntry(
  WidgetSession session,
  ChatThread thread,
  DateTime now,
  String group, {
  bool showProject = true,
}) {
  final book = session.book!;
  final active = session.view == WidgetView.chat && book.currentId == thread.id;
  final time = sessionRowTimeLabel(thread.lastActivityAt, now, group);
  final canAct = thread.messageCount > 0;
  final projectName = showProject ? book.project(thread.projectId)?.name : null;
  switch (thread.kind) {
    case ChatKind.main:
    case ChatKind.session:
      return SessionEntry(
        id: thread.id,
        title: ChatBook.titleOf(thread),
        time: time,
        itemKey: Key('chat-${thread.id}'),
        dotKey: Key('chat-unread-${thread.id}'),
        active: active,
        unread: thread.unread,
        persona: Personas.sado,
        pinned: thread.pinned,
        canAct: canAct,
        canRename: canAct,
        canMove: canAct,
        projectName: projectName,
      );
    case ChatKind.task:
      final task =
          session.taskList.where((Task t) => t.id == thread.taskId).firstOrNull;
      if (task == null) return null;
      return SessionEntry(
        id: thread.id,
        title: task.title,
        time: time,
        itemKey: Key('chat-${task.id}'),
        dotKey: Key('chat-unread-${task.id}'),
        active: active,
        unread: thread.unread,
        muted: task.status == TaskStatus.done,
        persona: Personas.sado,
        pinned: thread.pinned,
        canAct: canAct,
        projectName: projectName,
      );
  }
}

/// Открыть строку меню: чат задачи — через задачу, остальное — разговор.
void openEntry(WidgetSession session, String chatId) {
  final thread = session.book?.thread(chatId);
  final taskId = thread?.taskId;
  if (thread != null && thread.kind == ChatKind.task && taskId != null) {
    unawaited(session.openTask(taskId));
  } else {
    unawaited(session.openChat(chatId));
  }
}

/// Меню сессии: переименовать, закрепить, в проект, удалить — те же окна,
/// что в приложении.
Future<void> sessionAction(
  BuildContext context,
  WidgetSession session,
  String chatId,
  SessionAction action,
) async {
  final book = session.book;
  final thread = book?.thread(chatId);
  if (book == null || thread == null) return;
  final task = thread.kind == ChatKind.task
      ? session.taskList.where((Task t) => t.id == thread.taskId).firstOrNull
      : null;
  final title = task?.title ?? ChatBook.titleOf(thread);
  switch (action) {
    case SessionAction.rename:
      final name = await showRenameSessionDialog(context, current: title);
      if (name != null) session.renameChat(chatId, name);
    case SessionAction.pin:
      session.pinChat(chatId, pinned: !thread.pinned);
    case SessionAction.move:
      final choice = await showMoveToProjectSheet(
        context,
        projects: book.projects(),
        currentProjectId: thread.projectId,
      );
      if (choice == null || !context.mounted) return;
      switch (choice) {
        case MoveToProject(:final projectId):
          session.moveChat(chatId, projectId);
        case MoveOutOfProject():
          session.moveChat(chatId, null);
        case MoveToNewProject():
          final created = await createProject(context, session, open: false);
          if (created != null) session.moveChat(chatId, created);
      }
    case SessionAction.delete:
      final ok = await showDeleteSessionDialog(
        context,
        title: title,
        task: thread.kind == ChatKind.task,
      );
      if (ok) await session.deleteChat(chatId);
  }
}

/// «Новый проект»: окно приложения с названием и описанием; [open] —
/// сразу его экран. Возвращает id проекта.
Future<String?> createProject(
  BuildContext context,
  WidgetSession session, {
  bool open = true,
  String? name,
  String? tag,
}) async {
  final draft = await showProjectDialog(context, name: name ?? '');
  if (draft == null) return null;
  final project = session.createProject(draft.name, tag: tag);
  if (project == null) return null;
  if (draft.description != null) {
    session.describeProject(project.id, project.name, draft.description);
  }
  if (open) session.show(WidgetView.project, project: project.id);
  return project.id;
}

/// Меню «⋯» на экране проекта.
Future<void> projectAction(
  BuildContext context,
  WidgetSession session,
  String projectId,
  ProjectAction action,
) async {
  final book = session.book;
  final project = book?.project(projectId);
  if (book == null || project == null) return;
  switch (action) {
    case ProjectAction.rename:
      final name = await showRenameSessionDialog(
        context,
        current: project.name,
        title: 'Переименовать проект',
      );
      if (name != null) session.renameProject(projectId, name);
    case ProjectAction.describe:
      final draft = await showProjectDialog(
        context,
        title: 'Проект',
        action: 'Сохранить',
        name: project.name,
        description: project.description,
      );
      if (draft != null) {
        session.describeProject(projectId, draft.name, draft.description);
      }
    case ProjectAction.tag:
      final linked = <String>{
        for (final p in book.projects())
          if (p.taskTag case final String tag) tag,
      };
      final free = <String>{
        for (final task in activeTasks(session))
          if (task.project case final String tag)
            if (!linked.contains(tag)) tag,
      }.toList()
        ..sort();
      final result = await showProjectTagDialog(
        context,
        current: project.taskTag,
        suggestions: free.take(8).toList(),
      );
      if (result == null || !context.mounted) return;
      if (!session.tagProject(projectId, result.tag)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Метка #${result.tag} уже у другого проекта')),
        );
      }
    case ProjectAction.pin:
      session.pinProject(projectId, pinned: !project.pinned);
    case ProjectAction.delete:
      final choice = await showDeleteProjectDialog(
        context,
        name: project.name,
        sessions: book.projectSessionCount(projectId),
      );
      if (choice == null) return;
      await session.deleteProject(
        projectId,
        deleteSessions: choice == ProjectDeleteChoice.deleteSessions,
      );
  }
}

/// Срок задачи — выбор дня.
Future<void> pickDue(
  BuildContext context,
  WidgetSession session,
  Task task,
) async {
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

/// Отметить задачу выполненной или вернуть в работу.
void toggleDone(WidgetSession session, Task task) => unawaited(
      task.status == TaskStatus.done
          ? session.reopenTask(task.id)
          : session.completeTask(task.id),
    );

/// Экран раздела (не разговор): «Сегодня», задачи, проекты, проект,
/// планирование.
Widget widgetScreen(BuildContext context, WidgetSession session) {
  final book = session.book!;
  final now = DateTime.now();
  final active = activeTasks(session);
  void open(Task task) => unawaited(session.openTask(task.id));
  void toggle(Task task) => toggleDone(session, task);
  switch (session.view) {
    case WidgetView.chat:
      return const SizedBox.shrink();
    case WidgetView.today:
      return todayPanel(context, session);
    case WidgetView.tasks:
      return WidgetTasksScreen(session: session, now: now);
    case WidgetView.planning:
      return PlanningScreen(
        tasks: active,
        now: now,
        selectedId: null,
        onOpenTask: open,
        onToggleDone: toggle,
      );
    case WidgetView.projects:
      return ProjectsScreen(
        tasks: active,
        now: now,
        selectedId: null,
        onOpenTask: open,
        onToggleDone: toggle,
        folders: <ProjectFolderCard>[
          for (final project in book.projects())
            ProjectFolderCard(
              id: project.id,
              name: project.name,
              description: project.description,
              taskTag: project.taskTag,
              sessions: book.projectSessionCount(project.id),
            ),
        ],
        onOpenFolder: (String id) =>
            session.show(WidgetView.project, project: id),
        onNewFolder: () => unawaited(createProject(context, session)),
        onMakeFolder: (String tag) =>
            unawaited(createProject(context, session, name: tag, tag: tag)),
      );
    case WidgetView.project:
      final project = book.project(session.projectId);
      if (project == null) {
        return ProjectsScreen(
          tasks: active,
          now: now,
          selectedId: null,
          onOpenTask: open,
          onToggleDone: toggle,
        );
      }
      final tag = project.taskTag;
      return ProjectScreen(
        project: project,
        now: now,
        sessions: <SessionEntry>[
          for (final thread in book.sessionsOf(project.id))
            if (sessionEntry(
              session,
              thread,
              now,
              'pinned',
              showProject: false,
            )
                case final SessionEntry e)
              e,
        ],
        tasks: tag == null
            ? const <Task>[]
            : <Task>[
                for (final task in active)
                  if (task.tags.contains(tag)) task,
              ],
        onOpenTask: open,
        onToggleDone: toggle,
        onNewSession: () => unawaited(session.newChat(projectId: project.id)),
        onOpenSession: (String id) => openEntry(session, id),
        onSessionAction: (String id, SessionAction action) =>
            unawaited(sessionAction(context, session, id, action)),
        onAction: (ProjectAction action) =>
            unawaited(projectAction(context, session, project.id, action)),
      );
  }
}

/// «Сегодня» приложения: дела на сегодня и просроченные, ждущие
/// подтверждения карточки склада, разделы; [onClose] — свернуть колонку.
Widget todayPanel(
  BuildContext context,
  WidgetSession session, {
  VoidCallback? onClose,
}) {
  final now = DateTime.now();
  final active = activeTasks(session);
  final book = session.book!;
  return TodayPanel(
    now: now,
    tasks: todayTasks(active, now),
    onOpenTask: (Task task) => unawaited(session.openTask(task.id)),
    onToggleDone: (Task task) => toggleDone(session, task),
    onAllTasks: () => session.show(WidgetView.tasks),
    onClose: onClose,
    emptyHint: active.isEmpty
        ? 'Задач нет. Скажите: «напомни завтра проверить акт 12-26».'
        : null,
    pending: <TodayPending>[
      for (final pending in book.pendingCards(now))
        TodayPending(
          id: pending.message.card!.id,
          title: switch (pending.message.card!.kind) {
            ActionKind.post => 'Отметка прихода ждёт подтверждения',
            ActionKind.move => 'Перемещение ждёт подтверждения',
          },
          subtitle: 'Связной · склад',
          lead: Personas.sado,
          onTap: () => openEntry(session, pending.chatId),
        ),
    ],
    sections: <TodaySection>[
      TodaySection(
        id: 'projects',
        label: 'Проекты',
        onTap: () => session.show(WidgetView.projects),
      ),
      TodaySection(
        id: 'planning',
        label: 'Планирование',
        onTap: () => session.show(WidgetView.planning),
      ),
      TodaySection(
        id: 'warehouse',
        label: 'Склад',
        semantics: 'Склад, на связи',
        dot: context.colors.success,
        onTap: session.openWarehouse,
      ),
    ],
  );
}

/// «Задачи»: группы задач — как списки приложения ([TaskTile],
/// [InsetGroup]); срок — кнопкой календаря.
final class WidgetTasksScreen extends StatelessWidget {
  const WidgetTasksScreen({
    super.key,
    required this.session,
    required this.now,
  });

  final WidgetSession session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tasks = session.taskList;
    final tomorrow =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final late = <Task>[];
    final todays = <Task>[];
    final later = <Task>[];
    final open = <Task>[];
    final done = <Task>[];
    for (final task in tasks) {
      final due = task.dueAt?.toLocal();
      if (!task.isActive) {
        done.add(task);
      } else if (isOverdue(task, now)) {
        late.add(task);
      } else if (due != null && due.isBefore(tomorrow)) {
        todays.add(task);
      } else if (due != null) {
        later.add(task);
      } else {
        open.add(task);
      }
    }
    Widget row(Task task) => Row(
          children: <Widget>[
            Expanded(
              child: TaskTile(
                task: task,
                now: now,
                onTap: () => unawaited(session.openTask(task.id)),
                onToggleDone: () => toggleDone(session, task),
              ),
            ),
            if (task.isActive)
              IconButton(
                key: ValueKey<String>('task-due-${task.id}'),
                tooltip: 'Срок',
                onPressed: () => unawaited(pickDue(context, session, task)),
                icon: Icon(
                  Icons.event_outlined,
                  size: 20,
                  color: context.colors.icon,
                ),
              ),
          ],
        );
    final groups = <(String, List<Task>, bool)>[
      ('Просрочено', late, true),
      ('Сегодня', todays, false),
      ('Дальше', later, false),
      ('Без срока', open, false),
      ('Готово', done.take(10).toList(), false),
    ];
    return ListView(
      key: const Key('tasks-screen'),
      padding: const EdgeInsets.only(top: AppSpace.m, bottom: AppSpace.xl),
      children: <Widget>[
        const LargeTitle('Задачи'),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.pageH),
            child: Text(
              'Задач нет. Скажите: «добавь задачу проверить акт 12-26» или '
              '«напомни завтра позвонить поставщику».',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge!
                  .copyWith(color: context.colors.muted),
            ),
          ),
        for (final (label, list, danger) in groups)
          if (list.isNotEmpty)
            InsetGroup(
              header: label,
              headerDanger: danger,
              children: <Widget>[for (final task in list) row(task)],
            ),
      ],
    );
  }
}
