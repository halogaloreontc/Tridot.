import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../core/chats/chat_search.dart';
import '../../core/formatting/plural.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/grouped.dart';
import '../widgets/personas_section.dart';
import '../widgets/whole_word_text.dart';
import 'session_hold_menu.dart';

export 'session_hold_menu.dart' show SessionAction;

/// Строка сессии (или чата задачи) в меню.
final class SessionEntry {
  const SessionEntry({
    required this.id,
    required this.title,
    required this.time,
    required this.itemKey,
    required this.dotKey,
    this.active = false,
    this.unread = false,
    this.muted = false,
    this.persona,
    this.pinned = false,
    this.canAct = false,
    this.canRename = false,
    this.canMove = false,
    this.projectName,
  });

  final String id;
  final String title;

  /// «12:40», «вт», «4 нояб».
  final String time;
  final Key itemKey;
  final Key dotKey;

  /// Открыта сейчас.
  final bool active;

  /// Пришло сообщение, пока сессия была закрыта.
  final bool unread;

  /// Приглушённая (выполненная задача).
  final bool muted;

  /// Кто ответил последним: его знак слева; `null` — ещё никто.
  final Persona? persona;

  /// Закреплена.
  final bool pinned;

  /// Есть действия: «Закрепить», «Удалить» (у пустой новой сессии нет).
  final bool canAct;

  /// Можно переименовать (сессия; у чата задачи название — задачи).
  final bool canRename;

  /// Можно перенести в проект-папку («В проект…», ADR-018).
  final bool canMove;

  /// Проект-папка, в которой лежит сессия: значок папки перед временем,
  /// название — в подсказке и для экранного диктора; `null` — вне
  /// проектов.
  final String? projectName;
}

/// Проект-папка в панели под «Проектами» (ADR-018).
final class ProjectEntry {
  const ProjectEntry({
    required this.id,
    required this.name,
    required this.sessions,
    this.active = false,
  });

  final String id;
  final String name;

  /// Сколько в нём сессий.
  final int sessions;

  /// Его экран открыт.
  final bool active;
}

/// Группа строк в меню: «Закреплённые», «Сегодня», «Вчера», «На неделе»,
/// «Ранее».
final class SessionGroupEntry {
  const SessionGroupEntry({
    required this.id,
    required this.label,
    required this.entries,
  });

  /// `pinned`, `today`, `yesterday`, `week`, `earlier`.
  final String id;
  final String label;
  final List<SessionEntry> entries;
}

/// Счётчики разделов справа. `null` — без счётчика (данных нет).
final class SectionCounts {
  const SectionCounts({
    this.tasks,
    this.overdue = 0,
    this.projects,
    this.planning,
  });

  /// Открытые задачи.
  final int? tasks;

  /// Из них просрочены: вторая строка «N просрочена» у «Задач».
  final int overdue;

  /// Проекты-папки (ADR-018).
  final int? projects;

  /// Задачи со сроком сегодня и дальше.
  final int? planning;
}

/// Строка расширения в «Расширениях»: «Пароли · заперт», «Склад · на
/// связи».
final class ExtensionEntry {
  const ExtensionEntry({
    required this.id,
    required this.title,
    required this.status,
    required this.onTap,
    this.statusColor,
    this.dot = false,
    this.dotColor,
    this.icon,
  });

  final String id;
  final String title;
  final String status;

  /// Цвет состояния; `null` — приглушённый.
  final Color? statusColor;

  /// Точка состояния перед подписью.
  final bool dot;

  /// Цвет точки; `null` — как у подписи.
  final Color? dotColor;

  /// Значок слева; `null` — без значка.
  final IconData? icon;
  final VoidCallback onTap;
}

/// Подпись времени в списках: сегодня — «12:40», вчера — «вчера», на
/// этой неделе — «пн», раньше — «9 нояб.».
String sessionTimeLabel(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return _clock(at);
  if (diff == 1) return 'вчера';
  if (diff < 7) return _weekday(at);
  const months = <String>[
    'янв.',
    'февр.',
    'мар.',
    'апр.',
    'мая',
    'июн.',
    'июл.',
    'авг.',
    'сент.',
    'окт.',
    'нояб.',
    'дек.',
  ];
  return '${at.day} ${months[at.month - 1]}';
}

/// Подпись времени строки сессии под заголовком группы (макет Ж1):
/// «Сегодня» и «Вчера» — «18:20» (день уже в заголовке), «На неделе» —
/// «вт», «Ранее» — «4 нояб», «30 окт», прошлый год — «12.11.25».
/// Закреплённые — как [sessionTimeLabel], но без точки после месяца.
String sessionRowTimeLabel(DateTime at, DateTime now, String group) {
  final local = at.toLocal();
  switch (group) {
    case 'today':
    case 'yesterday':
      return _clock(local);
    case 'week':
      return _weekday(local);
    case 'earlier':
      return _olderDate(local, now.toLocal());
  }
  final label = sessionTimeLabel(local, now.toLocal());
  return label.endsWith('.') ? _olderDate(local, now.toLocal()) : label;
}

/// Дата старой сессии: в этом году — «12 нояб», в другом — «12.11.25»,
/// чтобы сессии разных лет не выглядели одинаково.
String _olderDate(DateTime at, DateTime now) {
  if (at.year == now.year) return _dayMonth(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(at.day)}.${two(at.month)}.${two(at.year % 100)}';
}

String _clock(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

String _weekday(DateTime at) =>
    const <String>['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'][at.weekday - 1];

String _dayMonth(DateTime at) {
  const months = <String>[
    'янв',
    'февр',
    'мар',
    'апр',
    'мая',
    'июн',
    'июл',
    'авг',
    'сент',
    'окт',
    'нояб',
    'дек',
  ];
  return '${at.day} ${months[at.month - 1]}';
}

/// Левая панель (макет «Ж1»): сверху — «Tridot», внизу — поиск по сессиям
/// и «+» (новая сессия); между ними прокручиваются «Мой Связной», разделы
/// со счётчиками, «Расширения», закреплённые сессии и сессии по дням.
/// Сессии — последними: они растут вниз, к поиску и «Новой сессии», а
/// «Расширения» не уезжают под длинный список. У сессии в панели только
/// название — содержимое чата в строке не пересказывается.
///
/// Долгое нажатие на сессию (на компьютере — «⋯» и правая кнопка) — меню
/// «Ж2»: «Переименовать», «Закрепить», «Удалить» ([onSessionAction]).
///
/// На телефоне — содержимое выдвижной панели, на широком экране —
/// постоянная колонка ([wide]) с «Свернуть панель»; там «Вчера», «На
/// неделе» и «Ранее» свёрнуты в заголовки со счётом. Настроек здесь нет:
/// они в «Мой Связной».
final class RelayDrawer extends StatefulWidget {
  const RelayDrawer({
    super.key,
    required this.groups,
    required this.extensions,
    required this.onOpenMyRelay,
    required this.onTasks,
    required this.onProjects,
    required this.onPlanning,
    required this.onOpenSession,
    required this.onNewSession,
    required this.search,
    required this.onOpenHit,
    required this.timeLabel,
    this.onSessionAction,
    this.hiddenSessions = 0,
    this.onShowMoreSessions,
    this.counts = const SectionCounts(),
    this.wide = false,
    this.onCollapse,
    this.searchFocus,
    this.reduceMotion = false,
    this.activeSection,
    this.assistants,
    this.projects = const <ProjectEntry>[],
    this.onOpenProject,
    this.onNewProject,
  });

  /// Проекты-папки: строки под «Проектами» ([onOpenProject]), не больше
  /// [projectsShown]; остальные — на экране «Проекты».
  final List<ProjectEntry> projects;
  final ValueChanged<String>? onOpenProject;

  /// «Новый проект» под проектами; `null` — строки нет.
  final VoidCallback? onNewProject;

  /// Сколько проектов видно в панели.
  static const int projectsShown = 5;

  /// Активные помощники для знаков на карточке «Мой …»; `null` — по
  /// текущему составу.
  final List<Persona>? assistants;

  /// Группы сессий по порядку; пустые не показываются.
  final List<SessionGroupEntry> groups;
  final List<ExtensionEntry> extensions;
  final VoidCallback onOpenMyRelay;
  final VoidCallback onTasks;
  final VoidCallback onProjects;
  final VoidCallback onPlanning;
  final ValueChanged<String> onOpenSession;
  final VoidCallback onNewSession;

  /// Выбрано действие с сессией (id, действие).
  final void Function(String id, SessionAction action)? onSessionAction;

  /// Сколько сессий не вошло в список ([ChatBook.groups]): под группами —
  /// строка «Показать ещё N» ([onShowMoreSessions]), и старые сессии не
  /// пропадают из панели насовсем.
  final int hiddenSessions;
  final VoidCallback? onShowMoreSessions;

  final SectionCounts counts;

  /// Поиск по сессиям ([ChatBook.search]).
  final Future<List<ChatSearchHit>> Function(String query) search;
  final ValueChanged<ChatSearchHit> onOpenHit;
  final String Function(DateTime at) timeLabel;

  final bool wide;

  /// «Свернуть панель» на широком экране.
  final VoidCallback? onCollapse;

  /// Фокус поля поиска: им хозяин ставит курсор по Ctrl K.
  final FocusNode? searchFocus;
  final bool reduceMotion;

  /// Открытый раздел: 'tasks', 'projects', 'planning' или `null`.
  final String? activeSection;

  /// Задержка поиска после ввода.
  static const Duration searchDelay = Duration(milliseconds: 200);

  /// С этого числа сессий в меню «Вчера», «На неделе» и «Ранее» на
  /// компьютере свёрнуты: свежие сессии видны без прокрутки. Меньше —
  /// всё раскрыто (сворачивать нечего).
  static const int foldFrom = 6;

  /// Группы, которые на компьютере сворачиваются в заголовок со счётом.
  static const Set<String> collapsible = <String>{
    'yesterday',
    'week',
    'earlier',
  };

  @override
  State<RelayDrawer> createState() => _RelayDrawerState();
}

final class _RelayDrawerState extends State<RelayDrawer> {
  final TextEditingController _query = TextEditingController();
  FocusNode? _ownFocus;
  bool _searching = false;
  bool _extensionsOpen = true;
  Timer? _debounce;
  int _generation = 0;
  List<ChatSearchHit>? _hits;
  String _hitsFor = '';

  /// Группы, которые пользователь сам раскрыл (`true`) или свернул.
  final Map<String, bool> _folded = <String, bool>{};

  FocusNode get _focus => widget.searchFocus ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _query.addListener(_onQuery);
  }

  @override
  void didUpdateWidget(RelayDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFocus != widget.searchFocus) {
      (oldWidget.searchFocus ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onFocus() {
    // Перерисовка и на потерю фокуса: рамка фокуса у поля поиска.
    if (!mounted) return;
    setState(() {
      if (_focus.hasFocus) _searching = true;
    });
  }

  void _onQuery() {
    final text = _query.text.trim();
    if (text == _hitsFor && _hits != null) return;
    _debounce?.cancel();
    final generation = ++_generation;
    if (text.isEmpty) {
      setState(() {
        _hits = null;
        _hitsFor = '';
      });
      return;
    }
    _debounce = Timer(RelayDrawer.searchDelay, () async {
      final hits = await widget.search(text);
      // Пока искали, запрос сменился: старый ответ не показываем.
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = hits;
        _hitsFor = text;
      });
    });
  }

  void _cancel() {
    _debounce?.cancel();
    _generation++;
    _query.clear();
    _focus.unfocus();
    setState(() {
      _searching = false;
      _hits = null;
      _hitsFor = '';
    });
  }

  bool get _still =>
      widget.reduceMotion ||
      MediaQuery.maybeDisableAnimationsOf(context) == true;

  Duration get _motion =>
      _still ? Duration.zero : const Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    // Выдвижная панель на телефоне: Scaffold не сжимает её под экранную
    // клавиатуру, поэтому отступ снизу — на высоту клавиатуры, и поиск с
    // «Отменой» стоит прямо над ней. Колонка на компьютере — без отступа.
    final inset = widget.wide ? 0.0 : MediaQuery.viewInsetsOf(context).bottom;
    // Клавиатура открыта для поиска: шапка, «Мой Связной», разделы и
    // «Расширения» уступают место сессиям и результатам.
    final roomy = !(_searching && inset > 0);
    final showHits = _searching && _query.text.trim().isNotEmpty;
    final showExtensions = roomy && !showHits && widget.extensions.isNotEmpty;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (roomy) ...<Widget>[
          _TitlePlate(onCollapse: widget.onCollapse),
        ],
        Expanded(
          child: ListView(
            key: const Key('drawer-scroll'),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
            children: <Widget>[
              if (roomy) ...<Widget>[
                // «Мой Связной» и разделы — одной сгруппированной
                // панелью на заливке листа (ADR-027).
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.group),
                  child: Material(
                    color: context.colors.workspace,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _MyRelayCard(
                          onTap: widget.onOpenMyRelay,
                          wide: widget.wide,
                          assistants: widget.assistants,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Divider(color: context.colors.divider),
                        ),
                        _Sections(
                          active: widget.activeSection,
                          counts: widget.counts,
                          wide: widget.wide,
                          onTasks: widget.onTasks,
                          onProjects: widget.onProjects,
                          onPlanning: widget.onPlanning,
                          projects: widget.projects,
                          onOpenProject: widget.onOpenProject,
                          onNewProject: widget.onNewProject,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              // «Расширения» — сразу под разделами, сессии — ниже них.
              if (showExtensions) _buildExtensions(),
              if (showHits)
                ..._buildHits()
              else ...<Widget>[
                ..._buildGroups(afterExtensions: showExtensions),
                if (widget.hiddenSessions > 0 &&
                    widget.onShowMoreSessions != null)
                  _ShowMoreRow(
                    count: widget.hiddenSessions,
                    onTap: widget.onShowMoreSessions!,
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + inset),
          child: _buildBottomRow(context),
        ),
      ],
    );
    return Material(
      key: const Key('app-sidebar'),
      color: context.colors.sidebar,
      child: body,
    );
  }

  /// Группы сессий; [afterExtensions] — над ними «Расширения», и первый
  /// заголовок отбит от них так же, как группы друг от друга.
  List<Widget> _buildGroups({required bool afterExtensions}) {
    final widgets = <Widget>[];
    var first = !afterExtensions;
    final total = widget.groups
        .fold(0, (int n, SessionGroupEntry g) => n + g.entries.length);
    final foldByDefault = total >= RelayDrawer.foldFrom;
    for (final group in widget.groups) {
      if (group.entries.isEmpty) continue;
      final folds = widget.wide && RelayDrawer.collapsible.contains(group.id);
      if (folds) {
        final open = _folded[group.id] ??
            (!foldByDefault || group.entries.any((SessionEntry e) => e.active));
        widgets.add(
          _GroupToggle(
            key: Key('drawer-group-${group.id}'),
            label: group.label,
            count: group.entries.length,
            open: open,
            onTap: () => setState(() => _folded[group.id] = !open),
          ),
        );
        if (!open) continue;
      } else {
        widgets.add(
          _ListHeader(
            group.label,
            key: Key('drawer-group-${group.id}'),
            icon: group.id == 'pinned' ? Icons.push_pin_outlined : null,
            top: first ? 8 : 18,
          ),
        );
      }
      first = false;
      for (final entry in group.entries) {
        widgets.add(
          _SessionRow(
            entry: entry,
            wide: widget.wide,
            reduceMotion: _still,
            onTap: () => widget.onOpenSession(entry.id),
            onAction: widget.onSessionAction == null
                ? null
                : (SessionAction action) =>
                    widget.onSessionAction!(entry.id, action),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _buildExtensions() {
    void toggle() => setState(() => _extensionsOpen = !_extensionsOpen);
    return Column(
      key: const Key('drawer-extensions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 8),
        Semantics(
          header: true,
          button: true,
          expanded: _extensionsOpen,
          label: 'Расширения',
          onTap: toggle,
          excludeSemantics: true,
          child: InkWell(
            key: const Key('drawer-extensions-toggle'),
            onTap: toggle,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Расширения', style: _groupStyle(context)),
                    ),
                    Icon(
                      _extensionsOpen
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 18,
                      color: context.colors.icon,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_extensionsOpen)
          Stack(
            children: <Widget>[
              Positioned(
                left: 19,
                top: 6,
                bottom: 6,
                child: SizedBox(
                  width: 1,
                  child: ColoredBox(color: context.colors.borderSoft),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: AppSpace.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final entry in widget.extensions)
                      _ExtensionRow(entry: entry, wide: widget.wide),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  List<Widget> _buildHits() {
    final hits = _hits;
    if (hits == null) {
      return const <Widget>[_ListHeader('Ищу…', live: true)];
    }
    return <Widget>[
      _ListHeader(
        'Найдено в сессиях · ${hits.length}',
        live: true,
        key: const Key('search-count'),
      ),
      for (final hit in hits)
        _HitRow(
          hit: hit,
          time: widget.timeLabel(hit.at),
          onTap: () {
            final chosen = hit;
            _cancel();
            widget.onOpenHit(chosen);
          },
        ),
    ];
  }

  Widget _buildBottomRow(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final height = (48.0).clamp(20 + 15 * scale * 1.4, 120.0);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          const gap = 8.0;
          final full = constraints.maxWidth;
          // «Новая сессия» — квадратной кнопкой 48 (ADR-027): поиск
          // забирает остальное, его подсказке не тесно.
          final button =
              math.min(AppSize.minTap * scale.clamp(1.0, 1.5), full / 3);
          final field = full - gap - button;
          return Stack(
            children: <Widget>[
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: button,
                child: ExcludeSemantics(
                  excluding: _searching,
                  child: ExcludeFocus(
                    excluding: _searching,
                    child: IgnorePointer(
                      ignoring: _searching,
                      child: AnimatedOpacity(
                        opacity: _searching ? 0 : 1,
                        duration: _motion == Duration.zero
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        child: _NewSessionButton(onTap: widget.onNewSession),
                      ),
                    ),
                  ),
                ),
              ),
              // Вся рамка — цель нажатия (не меньше 44 по высоте), а не
              // только строка текста внутри.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _focus.requestFocus();
                  if (!_searching) setState(() => _searching = true);
                },
                child: AnimatedContainer(
                  key: const Key('session-search-box'),
                  duration: _motion,
                  curve: const Cubic(.2, .8, .2, 1),
                  width: _searching ? full : field,
                  height: height,
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  // Поиск — заливкой листа (ADR-027); рамка 1.5 акцентом —
                  // только в фокусе, чтобы его было видно с клавиатуры.
                  decoration: BoxDecoration(
                    color: context.colors.workspace,
                    borderRadius: BorderRadius.circular(AppRadius.search),
                    border: Border.all(
                      color: _focus.hasFocus
                          ? context.colors.accent
                          : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.search, size: 20, color: context.colors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: <ShortcutActivator, VoidCallback>{
                            const SingleActivator(LogicalKeyboardKey.escape):
                                _cancel,
                          },
                          // Поле во всю высоту рамки: и нажатие, и область
                          // для экранного диктора — не меньше 44.
                          child: TextField(
                            key: const Key('session-search'),
                            controller: _query,
                            focusNode: _focus,
                            expands: true,
                            maxLines: null,
                            keyboardType: TextInputType.text,
                            textAlignVertical: TextAlignVertical.center,
                            onTap: () {
                              if (!_searching) {
                                setState(() => _searching = true);
                              }
                            },
                            textInputAction: TextInputAction.search,
                            style: TextStyle(
                              fontSize: 16,
                              color: context.colors.textStrong,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              // Подсказка целиком: не помещается —
                              // уменьшается, а не режется (ADR-021).
                              // Крупный шрифт — короче: «Поиск по сессиям»
                              // иначе сжимался до 11 px.
                              hint: fitSingleWord(
                                scale > 1.3 ? 'Поиск' : 'Поиск по сессиям',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: context.colors.muted,
                                ),
                              ),
                              semanticCounterText: '',
                              suffixText:
                                  // Подсказка — только если поле не режет
                                  // «Поиск по сессиям».
                                  widget.wide && !_searching && field >= 200
                                      ? 'Ctrl K'
                                      : null,
                              suffixStyle: metaStyle(context),
                            ),
                          ),
                        ),
                      ),
                      // «Отмена» — своей ширины у правого края, поле
                      // забирает остальное (D-Phone-Menu-Search).
                      if (_searching)
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: full * 0.45),
                          child: TextButton(
                            key: const Key('session-search-cancel'),
                            onPressed: _cancel,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(44, 44),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            child: const Text(
                              'Отмена',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// «+» — новая сессия: та же треть строки и высота, что у поиска.
final class _NewSessionButton extends StatelessWidget {
  const _NewSessionButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Новая сессия',
      child: Semantics(
        button: true,
        label: 'Новая сессия',
        onTap: onTap,
        excludeSemantics: true,
        // Тональная кнопка: заливка листа и значок акцентом, а не
        // сплошной блок акцента на треть строки.
        child: Material(
          color: context.colors.workspace,
          borderRadius: BorderRadius.circular(AppRadius.field),
          child: InkWell(
            key: const Key('new-session'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.field),
            child: Center(
              child: Icon(
                Icons.edit_square,
                size: 24,
                color: context.colors.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Знак приложения: три точки цветами помощников — Связной, Лиорио и Нода
/// (ADR-016). Виден в «Настройки → О приложении» (ADR-027).
final class RelayGlyph extends StatelessWidget {
  const RelayGlyph({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          key: const ValueKey<String>('app-glyph'),
          dimension: size,
          child: CustomPaint(
            painter: RelayGlyphPainter(palette: context.colors),
          ),
        ),
      );
}

/// Рисует знак приложения на сетке 24: точки в (5,12), (12,12), (19,12),
/// радиус 3.
final class RelayGlyphPainter extends CustomPainter {
  const RelayGlyphPainter({this.palette = AppPalette.dark});

  /// Палитра темы: точки перекрашиваются со сменой темы.
  final AppPalette palette;

  /// Цвета точек слева направо: Связной, Лиорио, Нода.
  List<Color> get colors => <Color>[palette.sado, palette.liorio, palette.noda];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    for (final (i, color) in colors.indexed) {
      canvas.drawCircle(
        Offset((5 + 7 * i) * k, 12 * k),
        3 * k,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(RelayGlyphPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

/// Шапка панели: знак, название приложения и версия; на компьютере справа —
/// «Свернуть панель».
final class _TitlePlate extends StatelessWidget {
  const _TitlePlate({required this.onCollapse});

  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, onCollapse == null ? 20 : 8, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // Название приложения — шрифтом названия (ADR-021) крупно;
            // знак и версия — в «Настройки → О приложении» (ADR-027).
            Expanded(
              child: Semantics(
                header: true,
                // Узко и крупный шрифт — название уменьшается целиком, а
                // не режется многоточием.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    AppInfo.name,
                    key: const ValueKey<String>('app-name'),
                    maxLines: 1,
                    softWrap: false,
                    style: displayTextStyle.copyWith(
                      fontSize: 26,
                      height: 1.1,
                      color: context.colors.textStrong,
                    ),
                  ),
                ),
              ),
            ),
            if (onCollapse != null)
              IconButton(
                key: const Key('sidebar-collapse'),
                tooltip: 'Свернуть панель',
                onPressed: onCollapse,
                color: context.colors.icon,
                icon: const Icon(Icons.view_sidebar_outlined, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

/// Карточка «Мой Связной»: знаки помощников внахлёст, название, шеврон.
final class _MyRelayCard extends StatelessWidget {
  const _MyRelayCard({
    required this.onTap,
    required this.wide,
    this.assistants,
  });

  final VoidCallback onTap;
  final bool wide;
  final List<Persona>? assistants;

  @override
  Widget build(BuildContext context) {
    final size = wide ? 34.0 : 36.0;
    return Semantics(
      button: true,
      label: AppInfo.hubName,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('drawer-my-relay'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: wide ? 60 : 68),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: wide ? 8 : 12,
              ),
              child: Row(
                children: <Widget>[
                  RelayAvatars(personas: assistants, size: size),
                  const SizedBox(width: 12),
                  Expanded(
                    // «Мой» / «Связной» на узком меню с крупным шрифтом:
                    // слово не рвётся и не режется (ADR-021).
                    child: WholeWordText.rich(
                      TextSpan(
                        text: AppInfo.hubName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: context.colors.textStrong,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

/// Знаки активных помощников внахлёст: в Соло — один Связной, в Дуэте — два,
/// в Трио — три.
final class RelayAvatars extends StatelessWidget {
  const RelayAvatars({
    super.key,
    this.personas,
    this.size = 36,
    this.ring,
  });

  /// Кого показать; `null` — активные по текущему составу
  /// ([PersonaCast.current]).
  final List<Persona>? personas;
  final double size;

  /// Обводка знаков; `null` — цвет карточки.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final shown = personas ?? PersonaCast.current.active;
    final step = size - size / 4;
    return SizedBox(
      key: const ValueKey<String>('relay-avatars'),
      width: shown.isEmpty ? 0 : size + step * (shown.length - 1),
      height: size,
      child: Stack(
        children: <Widget>[
          for (final (i, persona) in shown.indexed)
            Positioned(
              left: step * i,
              child: PersonaMark(
                key: ValueKey<String>('relay-avatar-${persona.id}'),
                persona: persona,
                size: size,
                round: true,
                ring: ring ?? context.colors.workspace,
              ),
            ),
        ],
      ),
    );
  }
}

/// Разделы строками во всю ширину: значок в скруглённом квадрате,
/// название, справа — счётчик.
final class _Sections extends StatelessWidget {
  const _Sections({
    required this.active,
    required this.counts,
    required this.wide,
    required this.onTasks,
    required this.onProjects,
    required this.onPlanning,
    this.projects = const <ProjectEntry>[],
    this.onOpenProject,
    this.onNewProject,
  });

  final String? active;
  final SectionCounts counts;
  final bool wide;
  final VoidCallback onTasks;
  final VoidCallback onProjects;
  final VoidCallback onPlanning;
  final List<ProjectEntry> projects;
  final ValueChanged<String>? onOpenProject;
  final VoidCallback? onNewProject;

  /// Папки под строкой «Проекты»: не больше [RelayDrawer.projectsShown],
  /// затем «Все проекты» (если не вошли). «Новый проект» — кнопка «+» в
  /// строке «Проекты»: панель не становится длиннее.
  List<Widget> _folders() {
    final open = onOpenProject;
    final shown = open == null
        ? const <ProjectEntry>[]
        : projects.take(RelayDrawer.projectsShown).toList();
    final more = open == null ? 0 : projects.length - shown.length;
    return <Widget>[
      for (final project in shown)
        _ProjectRow(
          key: Key('project-${project.id}'),
          icon: Icons.folder_outlined,
          label: project.name,
          projectName: true,
          count: project.sessions,
          selected: project.active,
          wide: wide,
          semantics: 'Проект «${project.name}», '
              '${project.sessions} '
              '${ruPlural(project.sessions, 'сессия', 'сессии', 'сессий')}',
          onTap: () => open!(project.id),
        ),
      if (more > 0)
        _ProjectRow(
          key: const Key('project-all'),
          icon: Icons.more_horiz,
          label: 'Все проекты · ${projects.length}',
          wide: wide,
          semantics: 'Все проекты, ${projects.length}',
          onTap: onProjects,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final overdue = counts.overdue;
    final items = <(String, String, IconData, int?, String?, VoidCallback)>[
      (
        'tasks',
        'Задачи',
        Icons.checklist,
        counts.tasks,
        overdue > 0
            ? '$overdue ${ruPlural(overdue, 'просрочена', 'просрочены', 'просрочено')}'
            : null,
        onTasks,
      ),
      (
        'projects',
        'Проекты',
        Icons.folder_outlined,
        counts.projects,
        null,
        onProjects,
      ),
      (
        'planning',
        'Планирование',
        Icons.calendar_today_outlined,
        counts.planning,
        null,
        onPlanning,
      ),
    ];
    return Semantics(
      container: true,
      label: 'Разделы',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (id, label, icon, count, alert, onTap)
              in items) ...<Widget>[
            // Заливка выбранной строки — по всей строке, вместе с «+».
            _SectionRow(
              id: id,
              label: label,
              icon: icon,
              count: count,
              alert: alert,
              selected: active == id,
              wide: wide,
              onTap: onTap,
              trailing: id == 'projects' && onNewProject != null
                  ? IconButton(
                      key: const Key('project-new'),
                      tooltip: 'Новый проект',
                      onPressed: onNewProject,
                      iconSize: 20,
                      color: context.colors.icon,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                      ),
                      icon: const Icon(Icons.create_new_folder_outlined),
                    )
                  : null,
            ),
            if (id == 'projects') ..._folders(),
          ],
        ],
      ),
    );
  }
}

/// Строка проекта-папки под «Проектами»: с отступом, значок, название и
/// число сессий.
final class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    super.key,
    required this.icon,
    required this.label,
    required this.wide,
    required this.semantics,
    required this.onTap,
    this.count,
    this.selected = false,
    this.projectName = false,
  });

  final IconData icon;
  final String label;

  /// [label] — название проекта: шрифтом названия (ADR-021).
  final bool projectName;
  final int? count;
  final bool selected;
  final bool wide;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: SelectableRow(
        selected: selected,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.fromLTRB(
            56 - AppSpace.selectionInsetH,
            4,
            16 - AppSpace.selectionInsetH,
            4,
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: wide ? 18 : 20, color: context.colors.icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: projectName
                      ? projectNameStyle(
                          fontSize: 16,
                          color: selected
                              ? context.colors.textStrong
                              : context.colors.text,
                        )
                      : TextStyle(
                          fontSize: 14,
                          color: context.colors.text,
                        ),
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: metaNumTextStyle.copyWith(
                    fontSize: 14,
                    color: context.colors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.id,
    required this.label,
    required this.icon,
    required this.count,
    required this.alert,
    required this.selected,
    required this.wide,
    required this.onTap,
    this.trailing,
  });

  final String id;
  final String label;
  final IconData icon;
  final int? count;

  /// Кнопка в конце строки («+» у «Проектов»): внутри заливки выбора.
  final Widget? trailing;

  /// Вторая строка цветом опасности: «1 просрочена».
  final String? alert;
  final bool selected;
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantics = <String>[
      label,
      if (count != null) '$count',
      if (alert != null) alert!,
    ].join(', ');
    // Просрочка — счётчик заметнее (рамка и текст ярче).
    final loud = alert != null;
    final labelStyle = TextStyle(
      fontSize: 16,
      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
      height: 1.35,
      color: context.colors.textStrong,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: SelectableRow(
        inkKey: Key('nav-$id'),
        selected: selected,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSize.rowMin),
          padding: EdgeInsets.only(
            left: 16 - AppSpace.selectionInsetH,
            right: (trailing == null ? 16 : 4) - AppSpace.selectionInsetH,
          ),
          child: Row(
            children: <Widget>[
              IconTile(icon: icon, color: tile(context)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // Одно слово («Планирование») при нехватке места
                    // уменьшается, а не режется многоточием (ADR-021).
                    if (label.contains(' '))
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      )
                    else
                      fitSingleWord(label, style: labelStyle),
                    if (alert != null)
                      Text(
                        alert!,
                        key: Key('nav-$id-alert'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.3,
                          color: context.colors.danger,
                        ),
                      ),
                  ],
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 8),
                // Счётчик — значением 16 приглушённым, без рамки.
                KeyedSubtree(
                  key: Key('nav-$id-count'),
                  child: Text(
                    '$count',
                    maxLines: 1,
                    style: metaNumTextStyle.copyWith(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: loud ? FontWeight.w600 : FontWeight.w400,
                      color:
                          loud ? context.colors.danger : context.colors.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: context.colors.faint,
                ),
              ],
              if (trailing case final Widget trailing) ...<Widget>[
                const SizedBox(width: 4),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Цвет плитки раздела — из проверенного набора палитры.
  Color tile(BuildContext context) => switch (id) {
        'tasks' => context.colors.tileBlue,
        'projects' => context.colors.tileAmber,
        'planning' => context.colors.tileRed,
        _ => context.colors.tileGray,
      };
}

TextStyle _groupStyle(BuildContext context) => TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.33,
      color: context.colors.muted,
    );

final class _ListHeader extends StatelessWidget {
  const _ListHeader(
    this.text, {
    super.key,
    this.live = false,
    this.icon,
    this.top = 8,
  });

  final String text;
  final bool live;
  final IconData? icon;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      liveRegion: live,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, top, 12, 8),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: context.colors.muted),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(text, style: _groupStyle(context))),
          ],
        ),
      ),
    );
  }
}

/// Свёрнутая на компьютере группа: «Вчера 2 ›».
final class _GroupToggle extends StatelessWidget {
  const _GroupToggle({
    super.key,
    required this.label,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        header: true,
        button: true,
        expanded: open,
        label: '$label, $count',
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(label, style: _groupStyle(context))),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: metaNumStyle(context).copyWith(
                      fontSize: 14,
                      color: context.colors.faint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                    size: 16,
                    color: context.colors.icon,
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

/// «Показать ещё N»: сессии сверх лимита панели.
final class _ShowMoreRow extends StatelessWidget {
  const _ShowMoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = 'Показать ещё $count';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        button: true,
        label: '$label ${ruPlural(count, 'сессию', 'сессии', 'сессий')}',
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          key: const Key('sessions-more'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.expand_more,
                    size: 16,
                    color: context.colors.icon,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: metaStyle(context).copyWith(
                        fontSize: 14,
                        color: context.colors.muted,
                      ),
                    ),
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

final class _ExtensionRow extends StatelessWidget {
  const _ExtensionRow({required this.entry, required this.wide});

  final ExtensionEntry entry;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${entry.title}, ${entry.status}',
      onTap: entry.onTap,
      excludeSemantics: true,
      child: InkWell(
        key: Key('drawer-extension-${entry.id}'),
        onTap: entry.onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: wide ? 46 : 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final half = constraints.maxWidth.isFinite
                    ? constraints.maxWidth / 2
                    : double.infinity;
                return Row(
                  children: <Widget>[
                    if (entry.icon != null) ...<Widget>[
                      Icon(entry.icon, size: 18, color: context.colors.icon),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: WholeWordText(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        firstWordOnly: true,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.35,
                          color: context.colors.textStrong,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Состояние прижато к правому краю строки (как в макете «Ж1»)
                    // и занимает не больше половины ширины: длинная подпись
                    // обрезается многоточием, а не сдвигает точку к середине.
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: half),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (entry.dot) ...<Widget>[
                            Container(
                              key: Key('drawer-extension-dot-${entry.id}'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: entry.dotColor ??
                                    entry.statusColor ??
                                    context.colors.muted,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              entry.status,
                              key: Key('drawer-extension-status-${entry.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metaStyle(context).copyWith(
                                fontSize: 14,
                                color:
                                    entry.statusColor ?? context.colors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Строка сессии: знак ответившего, название и время — одной строкой,
/// без пересказа чата. Долгое нажатие и правая кнопка — меню действий; на
/// компьютере при наведении или фокусе справа ещё и «⋯».
final class _SessionRow extends StatefulWidget {
  const _SessionRow({
    required this.entry,
    required this.wide,
    required this.reduceMotion,
    required this.onTap,
    required this.onAction,
  });

  final SessionEntry entry;
  final bool wide;
  final bool reduceMotion;
  final VoidCallback onTap;
  final ValueChanged<SessionAction>? onAction;

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

final class _SessionRowState extends State<_SessionRow> {
  bool _hover = false;
  bool _focused = false;
  bool _held = false;

  SessionEntry get _entry => widget.entry;

  bool get _acts => _entry.canAct && widget.onAction != null;

  /// Фокус строки: после меню он возвращается сюда, а не в начало панели
  /// («⋯», с которого открыли меню, к тому времени уже скрыт).
  final FocusNode _rowFocus = FocusNode(debugLabel: 'session-row');

  @override
  void dispose() {
    _rowFocus.dispose();
    super.dispose();
  }

  void _restoreFocus() {
    if (!mounted) return;
    _rowFocus.requestFocus();
    // Навигатор после закрытия маршрута возвращает фокус сам — на кнопку,
    // которой уже нет; ставим его на строку ещё раз после кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rowFocus.context != null) _rowFocus.requestFocus();
    });
  }

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
      title: _entry.title,
      pinned: _entry.pinned,
      canRename: _entry.canRename,
      canMove: _entry.canMove,
      reduceMotion: widget.reduceMotion,
      liftedRow: SessionRowBody(entry: _entry, wide: widget.wide),
    );
    if (!mounted) return;
    setState(() => _held = false);
    _restoreFocus();
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final label = 'Сессия «${entry.title}»';
    final onAction = widget.onAction;
    final showMore = widget.wide && _acts && (_hover || _focused);
    final radius = SelectableRow.radiusOf(inGroup: false);
    final row = InkWell(
      key: entry.itemKey,
      focusNode: _rowFocus,
      onTap: widget.onTap,
      onLongPress: _acts ? _openMenu : null,
      onSecondaryTap: _acts ? _openMenu : null,
      borderRadius: radius,
      // Контейнер, а не Ink: «поднятая» в меню строка прячется вместе с
      // заливкой.
      child: Container(
        decoration: BoxDecoration(
          color: entry.active ? context.colors.selection : null,
          borderRadius: radius,
        ),
        child: Opacity(
          // Строка «поднята» в меню действий: на месте — пусто.
          opacity: _held ? 0 : 1,
          child:
              SessionRowBody(entry: entry, wide: widget.wide, more: showMore),
        ),
      ),
    );
    // Фокус на строке или на её «⋯»: кнопка видна, пока фокус внутри.
    // С клавиатуры меню открывают Shift+F10 и клавиша меню — и в узкой
    // панели, где «⋯» нет.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (_acts) ...<ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): _openMenu,
          const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
        },
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (bool focus) => setState(() => _focused = focus),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Tooltip(
            message: <String>[
              entry.title,
              if (entry.projectName != null) 'проект «${entry.projectName}»',
              if (entry.unread) 'новое сообщение',
            ].join(', '),
            waitDuration: const Duration(milliseconds: 600),
            child: Stack(
              children: <Widget>[
                Semantics(
                  button: true,
                  selected: entry.active,
                  label: <String>[
                    label,
                    if (entry.projectName != null)
                      'в проекте «${entry.projectName}»',
                    if (entry.pinned) 'закреплена',
                    if (entry.unread) 'новое сообщение',
                  ].join(', '),
                  onTap: widget.onTap,
                  onLongPress: _acts ? _openMenu : null,
                  customSemanticsActions: !_acts || onAction == null
                      ? null
                      : <CustomSemanticsAction, VoidCallback>{
                          if (entry.canRename)
                            const CustomSemanticsAction(label: 'Переименовать'):
                                () => onAction(SessionAction.rename),
                          CustomSemanticsAction(
                            label: entry.pinned ? 'Открепить' : 'Закрепить',
                          ): () => onAction(SessionAction.pin),
                          if (entry.canMove)
                            const CustomSemanticsAction(label: 'В проект'):
                                () => onAction(SessionAction.move),
                          const CustomSemanticsAction(label: 'Удалить'): () =>
                              onAction(SessionAction.delete),
                        },
                  excludeSemantics: true,
                  child: row,
                ),
                if (showMore)
                  Positioned(
                    right: 2,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        key: Key('chat-more-${entry.id}'),
                        tooltip: 'Действия с сессией',
                        onPressed: _openMenu,
                        iconSize: 20,
                        color: context.colors.icon,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          backgroundColor: entry.active
                              ? context.colors.bubble
                              : context.colors.sidebar,
                        ),
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Содержимое строки сессии без жестов: в списке и «поднятой» над меню
/// действий.
final class SessionRowBody extends StatelessWidget {
  const SessionRowBody({
    super.key,
    required this.entry,
    required this.wide,
    this.more = false,
  });

  final SessionEntry entry;
  final bool wide;

  /// Справа — место под «⋯» (время скрыто).
  final bool more;

  @override
  Widget build(BuildContext context) {
    final mark = wide ? 26.0 : 28.0;
    final persona = entry.persona;
    final titleColor =
        entry.muted ? context.colors.muted : context.colors.textStrong;
    final time = Text(
      entry.time,
      maxLines: 1,
      style: metaStyle(context).copyWith(
        fontSize: 14,
        color: context.colors.muted,
      ),
    );
    return ConstrainedBox(
      // Одна строка: высота — наименьшая цель нажатия (на компьютере —
      // высота кнопки «⋯»).
      constraints: BoxConstraints(
        minHeight: wide ? AppSize.button : AppSize.rowMin,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: <Widget>[
            // Тот, кто ответил последним, — тихой точкой его цвета
            // (ADR-027), а не знаком с буквой.
            if (persona != null)
              SizedBox(
                width: mark,
                height: mark,
                child: Center(child: PersonaDot(persona: persona, size: 10)),
              )
            else
              // Ещё никто не отвечал (новая сессия): вместо пустой рамки —
              // тихий знак «новое», ширина колонки та же.
              SizedBox(
                width: mark,
                height: mark,
                child: Icon(
                  Icons.edit_outlined,
                  size: mark * 0.7,
                  color: context.colors.faint,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: WholeWordText(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                firstWordOnly: true,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                  color: titleColor,
                ),
              ),
            ),
            if (entry.unread) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                key: entry.dotKey,
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: context.colors.textStrong,
                  shape: BoxShape.circle,
                ),
              ),
            ],
            // Сессия лежит в проекте-папке: значок в той же строке,
            // название проекта — в подсказке и подписи строки.
            if (entry.projectName != null) ...<Widget>[
              const SizedBox(width: 8),
              Icon(
                Icons.folder_outlined,
                key: Key('chat-project-${entry.id}'),
                size: 14,
                color: context.colors.faint,
              ),
            ],
            const SizedBox(width: 8),
            // «⋯» встаёт на место времени: ширина строки не прыгает.
            Visibility(
              visible: !more,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: time,
            ),
          ],
        ),
      ),
    );
  }
}

final class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.time, required this.onTap});

  final ChatSearchHit hit;
  final String time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final snippet = hit.snippet;
    final start = hit.matchStart.clamp(0, snippet.length);
    final end = hit.matchEnd.clamp(start, snippet.length);
    return Semantics(
      button: true,
      label: hit.projectName == null
          ? '${hit.title}: $snippet'
          : '${hit.title}, проект «${hit.projectName}»: $snippet',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: Key('search-hit-${hit.chatId}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: WholeWordText(
                      hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      firstWordOnly: true,
                      style: TextStyle(color: context.colors.textStrong),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (hit.projectName case final String project) ...<Widget>[
                    Flexible(
                      child: Text(
                        'Проект · $project',
                        key: Key('search-project-${hit.chatId}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaStyle(context).copyWith(
                          color: context.colors.faint,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Время сессии, как в списке сессий (12:40, вчера).
                  Text(time, style: metaNumStyle(context)),
                ],
              ),
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: snippet.substring(0, start)),
                    TextSpan(
                      text: snippet.substring(start, end),
                      style: TextStyle(
                        color: context.colors.mark,
                        backgroundColor: context.colors.markBg,
                      ),
                    ),
                    TextSpan(text: snippet.substring(end)),
                  ],
                ),
                key: Key('search-snippet-${hit.chatId}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: context.colors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
