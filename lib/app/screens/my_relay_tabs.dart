import 'package:flutter/material.dart';

import '../../core/extensions/extension_registry.dart';
import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../../core/replies/reply_library.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../shell/today_panel.dart';
import '../widgets/activity_grid.dart';
import '../widgets/personas_section.dart';
import '../widgets/task_tile.dart';

/// Сколько дел показывает «Сейчас и дальше» сверх сегодняшних и
/// просроченных: те видны все (на телефоне это единственное место, где
/// виден весь список «Сегодня»).
const int nextLimit = 5;

/// Ширина, с которой сетка «Сводки» показывает год, а не 16 недель.
const double wideGridWidth = 1000;

/// «Сейчас и дальше»: активные задачи со сроком, просроченные первыми,
/// затем по сроку.
List<Task> nextTasks(Iterable<Task> tasks, DateTime now) {
  final list = tasks
      .where((Task t) => t.isActive && t.deletedAt == null && t.dueAt != null)
      .toList()
    ..sort((Task a, Task b) {
      final aOver = isOverdue(a, now);
      final bOver = isOverdue(b, now);
      if (aOver != bOver) return aOver ? -1 : 1;
      final byDue = a.dueAt!.compareTo(b.dueAt!);
      return byDue != 0 ? byDue : a.id.compareTo(b.id);
    });
  return list;
}

Widget _page({required Key key, required List<Widget> children}) =>
    SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );

const TextStyle _heading = TextStyle(
  fontSize: 15,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: AssistantColors.textStrong,
);

BoxDecoration get _card => BoxDecoration(
      color: AssistantColors.raised,
      border: Border.all(color: AssistantColors.borderSoft),
      borderRadius: BorderRadius.circular(16),
    );

// ---------------------------------------------------------------- Сводка

/// «Сводка»: сетка активности (16 недель на телефоне, 52 на компьютере)
/// и «Сейчас и дальше». Без советов и погоды: только то, что есть на
/// устройстве.
final class RelaySummary extends StatelessWidget {
  const RelaySummary({
    super.key,
    required this.activity,
    required this.tasks,
    required this.now,
    required this.pending,
    required this.onOpenTask,
    required this.onAllTasks,
    this.approximate = false,
  });

  final Map<DateTime, int> activity;

  /// Все задачи; в «Сейчас и дальше» попадают активные со сроком.
  final List<Task> tasks;
  final DateTime now;

  /// Ждущие отметки карточки (как в «Сегодня»).
  final List<TodayPending> pending;
  final ValueChanged<Task> onOpenTask;
  final VoidCallback onAllTasks;
  final bool approximate;

  /// Строки «Сейчас и дальше»: все просроченные и сегодняшние (как в
  /// колонке «Сегодня» на компьютере), затем ближайшие по сроку — не
  /// больше [nextLimit].
  static List<Task> rows(List<Task> tasks, DateTime now) {
    final active = <Task>[
      for (final task in tasks)
        if (task.isActive && task.deletedAt == null) task,
    ];
    final today = todayTasks(active, now);
    final seen = <String>{for (final task in today) task.id};
    return <Task>[
      ...today,
      ...nextTasks(active, now)
          .where((Task t) => !seen.contains(t.id))
          .take(nextLimit),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final next = rows(tasks, now);
    final today = todayTasks(
      <Task>[
        for (final task in tasks)
          if (task.isActive && task.deletedAt == null) task,
      ],
      now,
    );
    final overdue = today.where((Task t) => isOverdue(t, now)).length;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Компьютер (окно от 1000) — год мелкими клетками, как в
        // D-Desk-Summary; телефон — 16 недель.
        final desk = MediaQuery.sizeOf(context).width >= wideGridWidth;
        final weeks = desk ? 52 : 16;
        return _page(
          key: const Key('my-relay-summary'),
          children: <Widget>[
            ActivityGrid(
              counts: activity,
              now: now,
              weeks: weeks,
              approximate: approximate,
              cell: desk ? 12 : 14,
              gap: desk ? 3 : 4,
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Semantics(
                        header: true,
                        child: const Text('Сейчас и дальше', style: _heading),
                      ),
                      // Счётчик дня — тот же, что был у кнопки «Сегодня».
                      Text(
                        'сегодня: ${todaySummary(today.length, overdue)}',
                        key: const Key('summary-today'),
                        style: technicalTextStyle.copyWith(
                          color: overdue > 0 ? AssistantColors.danger : null,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('summary-all-tasks'),
                  onPressed: onAllTasks,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    foregroundColor: AssistantColors.muted,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          'Все задачи',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                ),
              ],
            ),
            if (next.isEmpty && pending.isEmpty)
              const EmptyState(
                key: Key('summary-next-empty'),
                icon: Icons.event_available_outlined,
                title: 'Ближайших дел нет',
                hint: 'Задачи со сроком и ждущие отметки появятся здесь',
              )
            else
              DecoratedBox(
                key: const Key('summary-next'),
                decoration: _card,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: <Widget>[
                      for (final (i, task) in next.indexed)
                        _NextRow(
                          key: Key('next-task-${task.id}'),
                          first: i == 0,
                          overdue: isOverdue(task, now),
                          title: task.title,
                          subtitle: todayDueLabel(task, now),
                          onTap: () => onOpenTask(task),
                        ),
                      for (final (i, item) in pending.indexed)
                        _NextRow(
                          key: Key('next-pending-${item.id}'),
                          first: next.isEmpty && i == 0,
                          mark: Personas.noda,
                          title: item.title,
                          subtitle: item.subtitle,
                          onTap: item.onTap,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

final class _NextRow extends StatelessWidget {
  const _NextRow({
    super.key,
    required this.first,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.overdue = false,
    this.mark,
  });

  final bool first;
  final bool overdue;
  final Persona? mark;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Widget lead = mark != null
        ? PersonaMark(persona: mark!, size: 20)
        : Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: overdue ? AssistantColors.danger : null,
              border: overdue
                  ? null
                  : Border.all(color: AssistantColors.icon, width: 1.5),
            ),
          );
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        decoration: BoxDecoration(
          border: first
              ? null
              : const Border(top: BorderSide(color: AssistantColors.divider)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            SizedBox(width: 20, child: Center(child: lead)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: AssistantColors.textStrong,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: technicalTextStyle.copyWith(
                      color: overdue ? AssistantColors.danger : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ Активность

/// «Активность»: год по дням (на телефоне — с прокруткой) и выполненные
/// задачи с «Вернуть».
final class RelayActivity extends StatefulWidget {
  const RelayActivity({
    super.key,
    required this.activity,
    required this.completed,
    required this.now,
    required this.onReopen,
    this.approximate = false,
  });

  final Map<DateTime, int> activity;

  /// Выполненные задачи, новые первыми.
  final List<Task> completed;
  final DateTime now;
  final ValueChanged<Task> onReopen;
  final bool approximate;

  static const pageSize = 20;

  @override
  State<RelayActivity> createState() => _RelayActivityState();
}

final class _RelayActivityState extends State<RelayActivity> {
  int _visible = RelayActivity.pageSize;

  @override
  Widget build(BuildContext context) {
    final completed = widget.completed;
    final shown = completed.take(_visible).toList();
    final hidden = completed.length - shown.length;
    return _page(
      key: const Key('my-relay-activity'),
      children: <Widget>[
        ActivityGrid(
          counts: widget.activity,
          now: widget.now,
          weeks: 52,
          title: 'За год',
          cell: 12,
          gap: 3,
          approximate: widget.approximate,
        ),
        SectionLabel('Выполненные · ${completed.length}'),
        if (completed.isEmpty)
          const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'Выполненных задач пока нет',
            hint: 'Завершённые задачи появятся здесь',
          )
        else ...<Widget>[
          for (final task in shown)
            TaskTile(
              key: ValueKey<String>('activity-done-${task.id}'),
              task: task,
              now: widget.now,
              onToggleDone: () => widget.onReopen(task),
            ),
          if (hidden > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('activity-more'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(40, 44),
                  foregroundColor: AssistantColors.text,
                ),
                onPressed: () =>
                    setState(() => _visible += RelayActivity.pageSize),
                child: Text('Показать ещё · $hidden'),
              ),
            ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------- Помощники

/// Подзаголовок карточки помощника: «главный помощник», «второй
/// помощник», «отвечает на всё», «выключен в соло».
String personaRole(Persona persona, PersonaSettings personas) {
  final female = persona.gender == ReplyGender.female;
  if (personas.mode == AssistantMode.duo) {
    return personas.main.id == persona.id
        ? (female ? 'главная помощница' : 'главный помощник')
        : 'пишет первым';
  }
  return personas.solo.id == persona.id
      ? 'отвечает на всё'
      : (female ? 'выключена · режим «Соло»' : 'выключен · режим «Соло»');
}

/// «Помощники» (D-Desk-Assistants): карточки Лиорио и Ноды с их
/// настройками (стиль, обращение, роли, включён ли второй), полные
/// настройки ниже и приглушённая строка о журнале. Журнал не строим.
final class RelayAssistants extends StatefulWidget {
  const RelayAssistants({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.registry,
    required this.onOpenRoles,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final ExtensionRegistry registry;

  /// «Ведёт: Кладовщик» → роли во вкладке «Настройки».
  final VoidCallback onOpenRoles;

  @override
  State<RelayAssistants> createState() => _RelayAssistantsState();
}

final class _RelayAssistantsState extends State<RelayAssistants> {
  final GlobalKey _details = GlobalKey();

  PersonaSettings get _personas => widget.settings.personas;

  void _set(PersonaSettings personas) =>
      widget.onChanged(widget.settings.copyWith(personas: personas));

  /// Включить или выключить [persona]: в дуэте выключение второго — соло
  /// основного; в соло включение другого — дуэт, основной остаётся
  /// отвечающим.
  void _setActive(Persona persona, bool active) {
    final p = _personas;
    if (active) {
      _set(p.copyWith(mode: AssistantMode.duo, mainPersona: p.responder.id));
    } else {
      final other = Personas.all.firstWhere((Persona x) => x.id != persona.id);
      _set(p.copyWith(mode: AssistantMode.solo, soloPersona: other.id));
    }
  }

  bool _isActive(Persona persona) =>
      _personas.mode == AssistantMode.duo || _personas.solo.id == persona.id;

  void _edit() {
    final target = _details.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 240),
    );
  }

  @override
  Widget build(BuildContext context) {
    final personas = _personas;
    final library = widget.registry.replyLibrary;
    return _page(
      key: const Key('my-relay-assistants'),
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final cards = <Widget>[
              for (final persona in Personas.all)
                _PersonaCard(
                  persona: persona,
                  personas: personas,
                  library: library,
                  roles: <String>[
                    for (final role in widget.registry.activeRoles)
                      if (personas.mode == AssistantMode.duo
                          ? widget.registry.ownerOf(role.id, personas).id ==
                              persona.id
                          : personas.solo.id == persona.id)
                        role.title,
                  ],
                  active: _isActive(persona),
                  // Основной (в соло — отвечающий) всегда включён.
                  canToggle: persona.id != personas.responder.id,
                  onActive: (bool v) => _setActive(persona, v),
                  onEdit: _edit,
                  onOpenRoles: widget.onOpenRoles,
                ),
            ];
            if (constraints.maxWidth >= 640) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: cards[0]),
                    const SizedBox(width: 12),
                    Expanded(child: cards[1]),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                cards[0],
                const SizedBox(height: 12),
                cards[1],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Журнал помощников — в планах',
          key: Key('assistants-journal-planned'),
          style: technicalTextStyle,
        ),
        KeyedSubtree(
          key: _details,
          child: PersonasSection(
            settings: widget.settings,
            onChanged: widget.onChanged,
            registry: widget.registry,
          ),
        ),
      ],
    );
  }
}

final class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.persona,
    required this.personas,
    required this.library,
    required this.roles,
    required this.active,
    required this.canToggle,
    required this.onActive,
    required this.onEdit,
    required this.onOpenRoles,
  });

  final Persona persona;
  final PersonaSettings personas;
  final ReplyLibrary library;
  final List<String> roles;
  final bool active;
  final bool canToggle;
  final ValueChanged<bool> onActive;
  final VoidCallback onEdit;
  final VoidCallback onOpenRoles;

  @override
  Widget build(BuildContext context) {
    final styleId = personas.styleOf(persona);
    final style = library.style(styleId)?.title ?? 'нейтральный';
    final female = persona.gender == ReplyGender.female;
    final address =
        personas.address == ReplyAddress.informal ? 'на ты' : 'на вы';
    // Крупный шрифт: «Изменить» уходит под имя, иначе строка не влезает.
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final edit = TextButton(
      key: Key('persona-edit-${persona.id}'),
      onPressed: onEdit,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: AssistantColors.text,
      ),
      child: const Text('Изменить'),
    );
    return Container(
      key: Key('persona-card-${persona.id}'),
      decoration: _card,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              PersonaMark(persona: persona, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: Text(persona.russianName, style: _heading),
                    ),
                    Text(
                      personaRole(persona, personas),
                      key: Key('persona-role-${persona.id}'),
                      style: technicalTextStyle,
                    ),
                  ],
                ),
              ),
              if (!large) edit,
            ],
          ),
          if (large)
            Align(alignment: AlignmentDirectional.centerStart, child: edit),
          if (canToggle)
            MergeSemantics(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      female ? 'Активна' : 'Активен',
                      style: const TextStyle(color: AssistantColors.text),
                    ),
                  ),
                  Switch(
                    key: Key('persona-active-${persona.id}'),
                    value: active,
                    onChanged: onActive,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          _Fact(label: 'Стиль', value: style),
          _Fact(label: 'Обращение', value: address),
          if (roles.isNotEmpty)
            // Кнопка для диктора: «Ведёт: Личное. Роли — в «Настройках»».
            Semantics(
              button: true,
              label: 'Ведёт: ${roles.join(', ')}',
              hint: 'Открыть роли в настройках',
              onTap: onOpenRoles,
              excludeSemantics: true,
              child: InkWell(
                key: Key('persona-roles-${persona.id}'),
                onTap: onOpenRoles,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: _Fact(
                    label: 'Ведёт',
                    value: roles.join(', '),
                    trailing: const Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: AssistantColors.icon,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Text(label, style: technicalTextStyle),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(color: AssistantColors.textStrong),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
