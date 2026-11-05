import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import '../widgets/task_tile.dart';

/// Экран «Проекты»: активные задачи, сгруппированные по проекту
/// (первая метка задачи). Карточка проекта раскрывается на месте и
/// показывает его задачи по срокам; одновременно открыта одна карточка.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    super.key,
    required this.tasks,
    required this.now,
    required this.selectedId,
    required this.onOpenTask,
    required this.onToggleDone,
  });

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

  String get key => name == null ? 'project-none' : 'project-$name';
  String get label => name == null ? 'Без проекта' : '#$name';
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  /// Ключ раскрытой карточки или null, если все свёрнуты.
  String? _expandedKey;

  List<_Project> _projects() {
    final named = <String, _Project>{};
    final none = _Project(null);
    for (final task in widget.tasks) {
      final project = task.project;
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

  void _toggle(String key) {
    setState(() => _expandedKey = _expandedKey == key ? null : key);
  }

  @override
  Widget build(BuildContext context) {
    final projects = _projects();
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Проекты',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: AssistantColors.textStrong),
              ),
              const SizedBox(height: 6),
              const Text(
                'Проект задаётся меткой в команде: Добавь задачу «Отчёт» '
                '#работа — или в документе задачи.',
                style: technicalTextStyle,
              ),
              const SizedBox(height: 16),
              if (projects.isEmpty)
                const EmptyState(
                  icon: Icons.folder_outlined,
                  title: 'Нет активных задач',
                  hint: 'Проекты появятся, когда у задач будут метки.',
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
  });

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
    final radius = BorderRadius.circular(10);
    return Material(
      color: expanded ? AssistantColors.raised : AssistantColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: const BorderSide(color: AssistantColors.borderSoft),
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
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
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
                              style: const TextStyle(
                                color: AssistantColors.textStrong,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              'активных: ${project.tasks.length}',
                              style: technicalTextStyle,
                            ),
                            if (overdue > 0)
                              Text(
                                'просрочено: $overdue',
                                style: technicalTextStyle.copyWith(
                                  color: AssistantColors.danger,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: AssistantColors.muted,
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
