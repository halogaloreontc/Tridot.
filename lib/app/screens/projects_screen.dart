import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/formatting/plural.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/grouped.dart';
import '../widgets/task_tile.dart';
import '../widgets/whole_word_text.dart';

/// Проект-папка на экране «Проекты» (ADR-018).
final class ProjectFolderCard {
  const ProjectFolderCard({
    required this.id,
    required this.name,
    required this.sessions,
    this.description,
    this.taskTag,
  });

  final String id;
  final String name;
  final String? description;

  /// Сколько в папке сессий.
  final int sessions;

  /// Связанная метка задач без «#»; `null` — нет.
  final String? taskTag;
}

/// Экран «Проекты» (ADR-018), два блока:
///
/// - «Папки» — проекты-папки с сессиями ([folders]): нажатие открывает
///   проект ([onOpenFolder]), «Новый проект» — [onNewFolder];
/// - «Метки задач» — активные задачи, сгруппированные по первой метке, как
///   раньше. Метки, уже связанные с папкой, здесь не повторяются (их задачи
///   — на экране папки). Карточка метки раскрывается на месте и показывает
///   задачи по срокам и «Сделать папкой» ([onMakeFolder]); одновременно
///   открыта одна карточка.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    super.key,
    required this.tasks,
    required this.now,
    required this.selectedId,
    required this.onOpenTask,
    required this.onToggleDone,
    this.folders = const <ProjectFolderCard>[],
    this.onOpenFolder,
    this.onNewFolder,
    this.onMakeFolder,
  });

  /// Проекты-папки по порядку.
  final List<ProjectFolderCard> folders;
  final ValueChanged<String>? onOpenFolder;
  final VoidCallback? onNewFolder;

  /// «Сделать папкой» у метки: папка с её именем, связанная с ней.
  final ValueChanged<String>? onMakeFolder;

  /// Только активные задачи.
  final List<Task> tasks;
  final DateTime now;

  /// Задача, с которой сейчас работает помощник.
  final String? selectedId;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

/// Проект для группировки: [name] == null — задачи без проекта.
final class _Project {
  _Project(this.name);

  final String? name;
  final List<Task> tasks = <Task>[];

  String get key => name == null ? 'tag-none' : 'tag-$name';
  String get label => name == null ? 'Без проекта' : '#$name';
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  /// Ключ раскрытой карточки или null, если все свёрнуты.
  String? _expandedKey;

  List<_Project> _projects() {
    final named = <String, _Project>{};
    final none = _Project(null);
    final linked = <String>{
      for (final folder in widget.folders)
        if (folder.taskTag case final String tag) tag,
    };
    for (final task in widget.tasks) {
      final project = task.project;
      if (project != null && linked.contains(project)) continue;
      if (project == null) {
        none.tasks.add(task);
      } else {
        named.putIfAbsent(project, () => _Project(project)).tasks.add(task);
      }
    }
    final names = named.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return <_Project>[
      for (final name in names) named[name]!,
      if (none.tasks.isNotEmpty) none,
    ];
  }

  List<Widget> _buildFolders() {
    final open = widget.onOpenFolder;
    return <Widget>[
      // Перенос, а не сжатие: на узком экране с крупным шрифтом «Новый
      // проект» уходит на свою строку, «Папки» не рвётся (ADR-021).
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          const SectionLabel('Папки'),
          if (widget.onNewFolder != null)
            TextButton.icon(
              key: const Key('projects-new'),
              onPressed: widget.onNewFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Новый проект'),
            ),
        ],
      ),
      if (widget.folders.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            'Папок пока нет. В папке живут сессии одного дела, а новую '
            'сессию можно начать прямо в ней.',
            key: Key('projects-no-folders'),
            // Пустое состояние — 15, как вторичный текст (ADR-027).
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
            for (final folder in widget.folders)
              _FolderCard(
                folder: folder,
                onTap: open == null ? null : () => open(folder.id),
              ),
          ],
        ),
    ];
  }

  void _toggle(String key) {
    setState(() => _expandedKey = _expandedKey == key ? null : key);
  }

  @override
  Widget build(BuildContext context) {
    final projects = _projects();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Semantics(
                  header: true,
                  child: Text(
                    'Проекты',
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall
                        ?.copyWith(color: context.colors.textStrong),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: WholeWordText(
                  'Проект — папка для сессий: из неё сразу начинают новую '
                  'сессию. Метку задачи задают в команде: Добавь задачу '
                  '«Отчёт» #работа — или в документе задачи.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium!
                      .copyWith(color: context.colors.muted),
                ),
              ),
              const SizedBox(height: 16),
              ..._buildFolders(),
              const SizedBox(height: 16),
              const SectionLabel('Метки задач'),
              if (projects.isEmpty)
                const EmptyState(
                  icon: Icons.sell_outlined,
                  title: 'Нет активных задач',
                  hint: 'Метки появятся, когда у задач будут метки.',
                )
              else
                for (final project in projects)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ProjectCard(
                      project: project,
                      now: widget.now,
                      expanded: _expandedKey == project.key,
                      selectedId: widget.selectedId,
                      onToggleExpanded: () => _toggle(project.key),
                      onOpenTask: widget.onOpenTask,
                      onToggleDone: widget.onToggleDone,
                      onMakeFolder:
                          project.name == null || widget.onMakeFolder == null
                              ? null
                              : () => widget.onMakeFolder!(project.name!),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.now,
    required this.expanded,
    required this.selectedId,
    required this.onToggleExpanded,
    required this.onOpenTask,
    required this.onToggleDone,
    this.onMakeFolder,
  });

  final VoidCallback? onMakeFolder;
  final _Project project;
  final DateTime now;
  final bool expanded;
  final String? selectedId;
  final VoidCallback onToggleExpanded;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;

  @override
  Widget build(BuildContext context) {
    final overdue = project.tasks.where((t) => isOverdue(t, now)).length;
    // Метка — панелью листа без рамки (ADR-027).
    return Material(
      color: context.colors.workspace,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.group),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              key: ValueKey<String>(project.key),
              onTap: onToggleExpanded,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSize.rowMin),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            Text(
                              project.label,
                              style: TextStyle(
                                color: context.colors.textStrong,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'активных: ${project.tasks.length}',
                              style: metaStyle(context),
                            ),
                            if (overdue > 0)
                              Text(
                                'просрочено: $overdue',
                                style: metaStyle(context).copyWith(
                                  color: context.colors.danger,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: context.colors.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expanded) ...<Widget>[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (onMakeFolder != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: Key('make-folder-${project.name}'),
                        onPressed: onMakeFolder,
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 18,
                        ),
                        label: const Text('Сделать папкой'),
                      ),
                    ),
                  for (final (group, tasks)
                      in groupTasks(project.tasks, now)) ...<Widget>[
                    SectionLabel(
                      '${group.title} · ${tasks.length}',
                      danger: group == TaskGroup.overdue,
                    ),
                    for (final task in tasks)
                      TaskTile(
                        task: task,
                        now: now,
                        selected: task.id == selectedId,
                        showProject: false,
                        onTap: () => onOpenTask(task),
                        onToggleDone: () => onToggleDone(task),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Карточка проекта-папки: значок, название, число сессий, метка и
/// описание.
final class _FolderCard extends StatelessWidget {
  const _FolderCard({required this.folder, required this.onTap});

  final ProjectFolderCard folder;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sessions = '${folder.sessions} '
        '${ruPlural(folder.sessions, 'сессия', 'сессии', 'сессий')}';
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: true,
        label: 'Проект «${folder.name}», $sessions',
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          key: Key('folder-${folder.id}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: <Widget>[
                  IconTile(
                    icon: Icons.folder_outlined,
                    color: context.colors.tileAmber,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          folder.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: projectNameStyle(
                            fontSize: 18,
                            color: context.colors.textStrong,
                          ),
                        ),
                        Wrap(
                          spacing: 12,
                          children: <Widget>[
                            Text(sessions, style: metaStyle(context)),
                            if (folder.taskTag != null)
                              Text(
                                '#${folder.taskTag}',
                                style: metaStyle(context),
                              ),
                          ],
                        ),
                        if (folder.description != null)
                          Text(
                            folder.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: context.colors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: context.colors.faint,
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
