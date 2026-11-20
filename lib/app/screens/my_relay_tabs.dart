import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../../core/replies/reply_library.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../shell/today_panel.dart';
import '../widgets/activity_grid.dart';
import '../widgets/connections_host.dart';
import '../widgets/connections_section.dart';
import '../widgets/grouped.dart';
import '../widgets/personas_section.dart';
import '../widgets/roles_section.dart';
import '../widgets/task_tile.dart';
import '../widgets/whole_word_text.dart';

/// Сколько дел показывает «Сейчас и дальше» сверх сегодняшних и
/// просроченных: те видны все (на телефоне это единственное место, где
/// виден весь список «Сегодня»).
const int nextLimit = 5;

/// Ширина окна, с которой сетка «Сводки» показывает год мелкими клетками.
const double wideGridWidth = 1000;

/// Сколько недель сетки ([ActivityGrid]: подписи дней 22 + 6, клетка
/// [cell], зазор [gap]) входит в [width] — ширину внутри её панели —
/// целиком: от 12 до 52.
int fitWeeks(double width, {required double cell, required double gap}) =>
    ((width - 28 + gap) / (cell + gap)).floor().clamp(12, 52);

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

TextStyle _heading(BuildContext context) => TextStyle(
      fontSize: 16,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: context.colors.textStrong,
    );

/// Панель «Мой Связной» — заливкой листа на фоне экрана, без рамки
/// (ADR-027).
BoxDecoration _card(BuildContext context) => BoxDecoration(
      color: context.colors.workspace,
      borderRadius: BorderRadius.circular(12),
    );

// ---------------------------------------------------------------- Сводка

/// «Сводка» — всё о том, что было и что впереди, на одной вкладке:
/// сетка активности (год на компьютере, на телефоне — сколько недель
/// входит в ширину), «Сейчас и дальше» и выполненные задачи с «Вернуть». Отдельной
/// вкладки «Активность» нет: сетка была и там, и здесь. Без советов и
/// погоды: только то, что есть на устройстве.
final class RelaySummary extends StatefulWidget {
  const RelaySummary({
    super.key,
    required this.activity,
    required this.tasks,
    required this.now,
    required this.pending,
    required this.onOpenTask,
    required this.onAllTasks,
    this.completed = const <Task>[],
    this.onReopen,
    this.approximate = false,
    this.notifier,
  });

  final Map<DateTime, int> activity;

  /// Знак у ждущих отметки карточек — ведущий оповещений; `null` — по
  /// текущему составу ([PersonaCast.current]).
  final Persona? notifier;

  /// Все задачи; в «Сейчас и дальше» попадают активные со сроком.
  final List<Task> tasks;
  final DateTime now;

  /// Ждущие отметки карточки (как в «Сегодня»).
  final List<TodayPending> pending;
  final ValueChanged<Task> onOpenTask;
  final VoidCallback onAllTasks;
  final bool approximate;

  /// Выполненные задачи, новые первыми.
  final List<Task> completed;

  /// «Вернуть» выполненную задачу в работу; `null` — без отметки.
  final ValueChanged<Task>? onReopen;

  /// Сколько выполненных показать сразу и добавлять «Показать ещё».
  static const pageSize = 20;

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
  State<RelaySummary> createState() => _RelaySummaryState();
}

final class _RelaySummaryState extends State<RelaySummary> {
  int _visible = RelaySummary.pageSize;

  @override
  Widget build(BuildContext context) {
    final tasks = widget.tasks;
    final now = widget.now;
    final pending = widget.pending;
    final next = RelaySummary.rows(tasks, now);
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
        // D-Desk-Summary. Уже — столько недель, сколько входит в ширину
        // целиком (на телефоне 390 — 16): сетка не прокручивается вбок, и
        // свайп вправо по «Сводке» всегда открывает меню.
        final desk = MediaQuery.sizeOf(context).width >= wideGridWidth;
        final weeks = desk
            ? 52
            : fitWeeks(
                // Поля страницы и панели сетки — по 16 с каждой стороны.
                math.min(constraints.maxWidth, 960 + 32) - 64,
                cell: 14,
                gap: 4,
              );
        return _page(
          key: const Key('my-relay-summary'),
          children: <Widget>[
            ActivityGrid(
              counts: widget.activity,
              now: now,
              weeks: weeks,
              title: weeks == 52 ? 'Активность за год' : 'Активность',
              approximate: widget.approximate,
              cell: desk ? 12 : 14,
              gap: desk ? 3 : 4,
            ),
            const SizedBox(height: 12),
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
                        child:
                            Text('Сейчас и дальше', style: _heading(context)),
                      ),
                      // Счётчик дня — тот же, что был у кнопки «Сегодня».
                      Text(
                        'сегодня: ${todaySummary(today.length, overdue)}',
                        key: const Key('summary-today'),
                        style: metaStyle(context).copyWith(
                          color: overdue > 0 ? context.colors.danger : null,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('summary-all-tasks'),
                  onPressed: widget.onAllTasks,
                  // Перенеслась под заголовок (узкий экран, крупный шрифт)
                  // — текст начинается ровно под ним: слева отступ 4, как у
                  // заголовка, справа — обычный.
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.only(left: 4, right: 8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          'Все задачи',
                          style: TextStyle(fontSize: 14),
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
                decoration: _card(context),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 12),
                  child: Column(
                    children: <Widget>[
                      for (final (i, task) in next.indexed)
                        _NextRow(
                          key: Key('next-task-${task.id}'),
                          first: i == 0,
                          overdue: isOverdue(task, now),
                          title: task.title,
                          subtitle: todayDueLabel(task, now),
                          onTap: () => widget.onOpenTask(task),
                        ),
                      for (final (i, item) in pending.indexed)
                        _NextRow(
                          key: Key('next-pending-${item.id}'),
                          first: next.isEmpty && i == 0,
                          mark: widget.notifier ?? PersonaCast.current.notifier,
                          title: item.title,
                          subtitle: item.subtitle,
                          onTap: item.onTap,
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            ..._done(context),
          ],
        );
      },
    );
  }

  /// «Выполненные · N»: новые первыми, по [RelaySummary.pageSize] за раз,
  /// отметка возвращает задачу в работу.
  List<Widget> _done(BuildContext context) {
    final completed = widget.completed;
    if (completed.isEmpty) {
      return <Widget>[
        const SectionLabel('Выполненные · 0'),
        const EmptyState(
          key: Key('summary-done-empty'),
          icon: Icons.inventory_2_outlined,
          title: 'Выполненных задач пока нет',
          hint: 'Завершённые задачи появятся здесь',
        ),
      ];
    }
    final shown = completed.take(_visible).toList();
    final hidden = completed.length - shown.length;
    final reopen = widget.onReopen;
    return <Widget>[
      InsetGroup(
        key: const Key('summary-done'),
        header: 'Выполненные · ${completed.length}',
        margin: EdgeInsets.zero,
        children: <Widget>[
          for (final task in shown)
            TaskTile(
              key: ValueKey<String>('activity-done-${task.id}'),
              task: task,
              now: widget.now,
              onToggleDone: reopen == null ? null : () => reopen(task),
            ),
          if (hidden > 0)
            GroupedRow(
              key: const Key('activity-more'),
              accent: true,
              title: 'Показать ещё · $hidden',
              onTap: () => setState(() => _visible += RelaySummary.pageSize),
            ),
        ],
      ),
    ];
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
              color: overdue ? context.colors.danger : null,
              border: overdue
                  ? null
                  : Border.all(color: context.colors.icon, width: 1.5),
            ),
          );
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: AppSize.rowMin),
        decoration: BoxDecoration(
          border: first
              ? null
              : Border(top: BorderSide(color: context.colors.divider)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            SizedBox(width: 20, child: Center(child: lead)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                          color: context.colors.textStrong,
                        ),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: overdue
                              ? context.colors.danger
                              : context.colors.muted,
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

// ------------------------------------------------------------- Помощники

/// Подзаголовок карточки помощника: «главный помощник», «ведёт
/// расширения», «ведёт оповещения», «выключен · режим «Соло»». Пока род
/// главного не выбран, о нём — без рода.
String personaRole(Persona persona, PersonaSettings personas) {
  final cast = personas.cast;
  final female = personas.genderOf(persona.id) == ReplyGender.female;
  if (!cast.isActive(persona.id)) {
    final mode = personas.teamMode == TeamMode.solo ? 'Соло' : 'Дуэт';
    return '${female ? 'выключена' : 'выключен'} · режим «$mode»';
  }
  if (persona.id == cast.responder.id) {
    if (!personas.sadoGenderChosen) return 'главное: беседа, задачи, планы';
    return female ? 'главная помощница' : 'главный помощник';
  }
  final extensions = cast.extensionsLead.id == persona.id;
  final notifications = cast.notifier.id == persona.id;
  return switch ((extensions, notifications)) {
    (true, true) => 'ведёт расширения и оповещения',
    (true, false) => 'ведёт расширения',
    (false, true) => 'ведёт оповещения',
    (false, false) => 'без обязанностей',
  };
}

/// «Помощники» (D-Desk-Assistants): карточки Связного, Лиорио и Ноды
/// (стиль, обращение, роли, включён ли помощник), под ними все настройки
/// помощников — режим, обязанности, стили, обращение — и роли, которые
/// они ведут. В «Настройках» помощников больше нет: всё о них — здесь.
/// Журнал не строим — о нём приглушённая строка в конце вкладки.
final class RelayAssistants extends StatefulWidget {
  const RelayAssistants({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.registry,
    this.connections = const <ConnectionService>[],
    this.onOpenRoles,
    this.connectionsHost,
  });

  /// Каталог подключений (ADR-043): раздел «Подключения» под «Ролями»;
  /// `null` — раздела нет.
  final ConnectionsHost? connectionsHost;

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final ExtensionRegistry registry;

  /// Подключения ролей: статус и «Подключить склад» в «Ролях».
  final List<ConnectionService> connections;

  /// «Ведёт: Кладовщик» → роли; `null` — прокрутка к «Ролям» ниже на этой
  /// же вкладке.
  final VoidCallback? onOpenRoles;

  /// С этой ширины карточки стоят в ряд, уже — столбцом.
  static const double rowWidth = 900;

  @override
  State<RelayAssistants> createState() => _RelayAssistantsState();
}

final class _RelayAssistantsState extends State<RelayAssistants> {
  final GlobalKey _details = GlobalKey();
  final GlobalKey _roles = GlobalKey();

  /// Чьи имя, род и стиль раскрыты под «Режимом» («Изменить» на
  /// карточке); `null` — ничьи: вкладка короче, стиль и обращение и так
  /// видны на карточках.
  String? _editing;

  PersonaSettings get _personas => widget.settings.personas;

  void _set(PersonaSettings personas) =>
      widget.onChanged(widget.settings.copyWith(personas: personas));

  /// Включить или выключить помощника [persona]: оба помощника главного
  /// включены — Трио, один — Дуэт с ним, ни одного — Соло.
  void _setActive(Persona persona, bool active) {
    final p = _personas;
    final on = <String>{
      for (final id in Personas.helperIds)
        if (p.cast.isActive(id)) id,
    };
    active ? on.add(persona.id) : on.remove(persona.id);
    _set(
      switch (on.length) {
        0 => p.copyWith(teamMode: TeamMode.solo),
        1 => p.copyWith(teamMode: TeamMode.duo, duoHelper: on.single),
        _ => p.copyWith(teamMode: TeamMode.trio),
      },
    );
  }

  void _edit(Persona persona) {
    setState(() => _editing = persona.id);
    // Раскрытый блок — после перестройки: тогда к нему и прокрутка.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal(_details);
    });
  }

  void _openRoles() {
    if (widget.onOpenRoles case final VoidCallback open) return open();
    _reveal(_roles);
  }

  void _reveal(GlobalKey key) {
    final target = key.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 240),
    );
  }

  @override
  Widget build(BuildContext context) {
    final personas = _personas;
    final cast = personas.cast;
    final library = widget.registry.replyLibrary;
    return _page(
      key: const Key('my-relay-assistants'),
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final cards = <Widget>[
              for (final persona in cast.members)
                _PersonaCard(
                  persona: persona,
                  personas: personas,
                  library: library,
                  roles: <String>[
                    for (final role in widget.registry.activeRoles)
                      if (widget.registry.ownerOf(role.id, personas).id ==
                          persona.id)
                        role.title,
                  ],
                  active: cast.isActive(persona.id),
                  // Связной всегда включён; помощников включает режим.
                  canToggle: persona.id != cast.responder.id,
                  onActive: (bool v) => _setActive(persona, v),
                  onEdit: () => _edit(persona),
                  onOpenRoles: _openRoles,
                ),
            ];
            if (constraints.maxWidth >= RelayAssistants.rowWidth) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final (i, card) in cards.indexed) ...<Widget>[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: card),
                    ],
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (i, card) in cards.indexed) ...<Widget>[
                  if (i > 0) const SizedBox(height: 12),
                  card,
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        KeyedSubtree(
          key: _details,
          // Страница уже даёт поля 16: группы — без своих боковых.
          child: InsetGroupScope(
            side: 0,
            child: PersonasSection(
              settings: widget.settings,
              onChanged: widget.onChanged,
              registry: widget.registry,
              // Вкладка и так «Помощники»: заголовок не повторяется.
              showHeader: false,
              editing: _editing,
              onEditing: (String? id) => setState(() => _editing = id),
            ),
          ),
        ),
        // Роли ведут помощники (ADR-016): их выбор — рядом с обязанностями.
        if (widget.registry.roles.isNotEmpty)
          KeyedSubtree(
            key: _roles,
            child: InsetGroupScope(
              side: 0,
              child: RolesSection(
                registry: widget.registry,
                settings: widget.settings,
                onChanged: widget.onChanged,
                connections: widget.connections,
              ),
            ),
          ),
        // Подключения к приложениям (ADR-043) — рядом с ролями: склад
        // подключается и в роли «Кладовщик», остальные — только здесь.
        if (widget.connectionsHost case final ConnectionsHost host)
          InsetGroupScope(side: 0, child: ConnectionsSection(host: host)),
        // В самом конце, а не между карточками и их настройками: строка о
        // будущем не разрывает вкладку.
        // Отступ — как у подписей групп над ней (AppSpace.rowH): одна
        // левая линия у «Роли» и у этой строки.
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.rowH),
          child: WholeWordText(
            'Журнал помощников — в планах',
            key: const Key('assistants-journal-planned'),
            style: metaStyle(context),
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
    final large = MediaQuery.textScalerOf(context).scale(1) >= 1.3;
    final edit = TextButton(
      key: Key('persona-edit-${persona.id}'),
      onPressed: onEdit,
      style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
      child: const Text('Изменить'),
    );
    return Container(
      key: Key('persona-card-${persona.id}'),
      decoration: _card(context),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
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
                      child:
                          Text(persona.russianName, style: _heading(context)),
                    ),
                    Text(
                      personaRole(persona, personas),
                      key: Key('persona-role-${persona.id}'),
                      style: metaStyle(context),
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
                      style: TextStyle(color: context.colors.text),
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
          const SizedBox(height: 4),
          _Fact(label: 'Стиль', value: style),
          _Fact(label: 'Обращение', value: address),
          if (roles.isNotEmpty)
            // Кнопка для диктора: «Ведёт: Личное», переход к «Ролям».
            Semantics(
              button: true,
              label: 'Ведёт: ${roles.join(', ')}',
              hint: 'Перейти к ролям',
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
                    trailing: Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: context.colors.icon,
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
          // Слово, которое не влезает в свою долю строки («Обращение» на
          // 320 px с крупным шрифтом), чуть уменьшается, а не рвётся
          // (ADR-021). WholeWordText, а не LayoutBuilder: карточки стоят и
          // в IntrinsicHeight.
          Expanded(
            flex: 2,
            child: WholeWordText(label, style: metaStyle(context)),
          ),
          Expanded(
            flex: 3,
            child: WholeWordText(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(color: context.colors.textStrong),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
