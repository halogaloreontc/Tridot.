import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../core/chats/chat_search.dart';
import '../../core/formatting/plural.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../widgets/app_name_text.dart';
import '../widgets/personas_section.dart';
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
    this.preview,
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

  /// Вторая строка: последний ответ помощника одной строкой (уже
  /// очищенный) или нейтральная фраза вместо карточки; `null` — без неё.
  final String? preview;

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

  /// Проект-папка, в которой лежит сессия: маленькая подпись со значком
  /// папки; `null` — вне проектов.
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
    this.statusColor = AssistantColors.muted,
    this.dot = false,
    this.dotColor,
    this.icon,
  });

  final String id;
  final String title;
  final String status;
  final Color statusColor;

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

/// Левая панель (макет «Ж1»): сверху — «Tridot» с версией, внизу — поиск
/// по сессиям и «+» (новая сессия); между ними прокручиваются «Мой
/// Tridot», разделы со счётчиками, закреплённые сессии, сессии по дням и
/// «Расширения». Края прокрутки мягко гаснут.
///
/// Долгое нажатие на сессию (на компьютере — «⋯» и правая кнопка) — меню
/// «Ж2»: «Переименовать», «Закрепить», «Удалить» ([onSessionAction]).
///
/// На телефоне — содержимое выдвижной панели, на широком экране —
/// постоянная колонка ([wide]) с «Свернуть панель»; там «Вчера», «На
/// неделе» и «Ранее» свёрнуты в заголовки со счётом. Настроек здесь нет:
/// они в «Мой Tridot».
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
  /// компьютере свёрнуты: «Расширения» видны без прокрутки. Меньше —
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
    if (_focus.hasFocus && !_searching) setState(() => _searching = true);
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
    // Клавиатура открыта для поиска: шапка, «Мой Tridot» и разделы
    // уступают место результатам.
    final roomy = !(_searching && inset > 0);
    final showHits = _searching && _query.text.trim().isNotEmpty;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (roomy) ...<Widget>[
          _TitlePlate(onCollapse: widget.onCollapse),
          const Divider(
            height: 1,
            thickness: 1,
            color: AssistantColors.divider,
          ),
        ],
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: ListView(
                  key: const Key('drawer-scroll'),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  children: <Widget>[
                    if (roomy) ...<Widget>[
                      _MyRelayCard(
                        onTap: widget.onOpenMyRelay,
                        wide: widget.wide,
                        assistants: widget.assistants,
                      ),
                      const SizedBox(height: 8),
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
                      const Padding(
                        padding: EdgeInsets.fromLTRB(10, 6, 10, 0),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: AssistantColors.divider,
                        ),
                      ),
                    ],
                    if (showHits)
                      ..._buildHits()
                    else ...<Widget>[
                      ..._buildGroups(),
                      if (widget.hiddenSessions > 0 &&
                          widget.onShowMoreSessions != null)
                        _ShowMoreRow(
                          count: widget.hiddenSessions,
                          onTap: widget.onShowMoreSessions!,
                        ),
                      if (widget.extensions.isNotEmpty) _buildExtensions(),
                    ],
                  ],
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 14,
                child: _Fade(key: Key('drawer-fade-top'), down: true),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 24,
                child: _Fade(key: Key('drawer-fade-bottom'), down: false),
              ),
            ],
          ),
        ),
        DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AssistantColors.divider)),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + inset),
            child: _buildBottomRow(context),
          ),
        ),
      ],
    );
    return Material(
      key: const Key('app-sidebar'),
      color: AssistantColors.sidebar,
      child: body,
    );
  }

  List<Widget> _buildGroups() {
    final widgets = <Widget>[];
    var first = true;
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
        const SizedBox(height: 10),
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
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text('Расширения', style: _groupStyle),
                    ),
                    Icon(
                      _extensionsOpen
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 18,
                      color: AssistantColors.icon,
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
              const Positioned(
                left: 19,
                top: 6,
                bottom: 6,
                child: SizedBox(
                  width: 1,
                  child: ColoredBox(color: AssistantColors.borderSoft),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 18),
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
          final field = (full - gap) * 2 / 3;
          final button = full - gap - field;
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
                  decoration: BoxDecoration(
                    color: AssistantColors.raised,
                    border: Border.all(
                      color: _searching
                          ? AssistantColors.borderFocus
                          : AssistantColors.border,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: <Widget>[
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
                            style: const TextStyle(
                              fontSize: 15,
                              color: AssistantColors.textStrong,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText: 'Поиск по сессиям',
                              hintMaxLines: 1,
                              hintStyle: const TextStyle(
                                fontSize: 14,
                                color: AssistantColors.muted,
                                overflow: TextOverflow.ellipsis,
                              ),
                              semanticCounterText: '',
                              suffixText:
                                  // Подсказка — только если поле не режет
                                  // «Поиск по сессиям».
                                  widget.wide && !_searching && field >= 200
                                      ? 'Ctrl K'
                                      : null,
                              suffixStyle: metaTextStyle,
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
                              foregroundColor: AssistantColors.text,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            child: const Text(
                              'Отмена',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
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

/// Мягкий край прокрутки: цвет панели → прозрачный.
final class _Fade extends StatelessWidget {
  const _Fade({super.key, required this.down});

  /// Сверху вниз (верхний край) или снизу вверх (нижний).
  final bool down;

  @override
  Widget build(BuildContext context) {
    final colors = <Color>[
      AssistantColors.sidebar,
      AssistantColors.sidebar.withAlpha(0),
    ];
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: down ? Alignment.topCenter : Alignment.bottomCenter,
            end: down ? Alignment.bottomCenter : Alignment.topCenter,
            colors: colors,
          ),
        ),
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
        child: Material(
          color: AssistantColors.primary,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const Key('new-session'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: const Center(
              child: Icon(
                Icons.add,
                size: 22,
                color: AssistantColors.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Знак приложения: три точки цветами помощников — Связной, Лиорио и Нода
/// (ADR-016).
final class _RelayGlyph extends StatelessWidget {
  const _RelayGlyph();

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
        child: SizedBox.square(
          key: ValueKey<String>('app-glyph'),
          dimension: 22,
          child: CustomPaint(painter: RelayGlyphPainter()),
        ),
      );
}

/// Рисует знак приложения на сетке 24: точки в (5,12), (12,12), (19,12),
/// радиус 3.
final class RelayGlyphPainter extends CustomPainter {
  const RelayGlyphPainter();

  /// Цвета точек слева направо: Связной, Лиорио, Нода.
  static const List<Color> colors = <Color>[
    AssistantColors.sado,
    AssistantColors.liorio,
    AssistantColors.noda,
  ];

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
  bool shouldRepaint(RelayGlyphPainter oldDelegate) => false;
}

/// Шапка панели: знак, название приложения и версия; на компьютере справа —
/// «Свернуть панель».
final class _TitlePlate extends StatelessWidget {
  const _TitlePlate({required this.onCollapse});

  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, onCollapse == null ? 20 : 8, 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const _RelayGlyph(),
            const SizedBox(width: 10),
            // Название сжимается последним: версия — своей ширины рядом.
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Semantics(
                      header: true,
                      // Название приложения — шрифтом названия (ADR-021).
                      child: Text(
                        AppInfo.name,
                        key: const ValueKey<String>('app-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: displayTextStyle.copyWith(
                          fontSize: 23,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Semantics(
                      label: 'Версия ${AppInfo.version}',
                      excludeSemantics: true,
                      child: Text(
                        AppInfo.version,
                        key: const ValueKey<String>('app-version'),
                        maxLines: 1,
                        style: metaTextStyle.copyWith(
                          fontSize: 13,
                          color: AssistantColors.faint,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (onCollapse != null)
              IconButton(
                key: const Key('sidebar-collapse'),
                tooltip: 'Свернуть панель',
                onPressed: onCollapse,
                color: AssistantColors.icon,
                icon: const Icon(Icons.view_sidebar_outlined, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

/// Карточка «Мой Tridot»: знаки помощников внахлёст, название, шеврон.
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
        color: AssistantColors.raised,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AssistantColors.borderSoft),
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          key: const Key('drawer-my-relay'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: wide ? 72 : 88),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: wide ? 10 : 12,
              ),
              child: Row(
                children: <Widget>[
                  RelayAvatars(personas: assistants, size: size),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      appNameSpan(
                        AppInfo.hubName,
                        TextStyle(
                          fontSize: wide ? 16 : 18,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: wide ? 18 : 20,
                    color: AssistantColors.icon,
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
    this.ring = AssistantColors.raised,
  });

  /// Кого показать; `null` — активные по текущему составу
  /// ([PersonaCast.current]).
  final List<Persona>? personas;
  final double size;
  final Color ring;

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
                ring: ring,
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
          for (final (index, (id, label, icon, count, alert, onTap))
              in items.indexed) ...<Widget>[
            if (index > 0) const SizedBox(height: 2),
            if (id == 'projects' && onNewProject != null)
              Row(
                children: <Widget>[
                  Expanded(
                    child: _SectionRow(
                      id: id,
                      label: label,
                      icon: icon,
                      count: count,
                      alert: alert,
                      selected: active == id,
                      wide: wide,
                      onTap: onTap,
                    ),
                  ),
                  IconButton(
                    key: const Key('project-new'),
                    tooltip: 'Новый проект',
                    onPressed: onNewProject,
                    iconSize: 20,
                    color: AssistantColors.icon,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                ],
              )
            else
              _SectionRow(
                id: id,
                label: label,
                icon: icon,
                count: count,
                alert: alert,
                selected: active == id,
                wide: wide,
                onTap: onTap,
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.fromLTRB(28, 4, 10, 4),
          decoration: BoxDecoration(
            color: selected ? AssistantColors.raised : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: wide ? 18 : 20, color: AssistantColors.icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: projectName
                      ? projectNameStyle(
                          fontSize: wide ? 16 : 17,
                          color: AssistantColors.text,
                        )
                      : TextStyle(
                          fontSize: wide ? 14 : 15,
                          color: AssistantColors.text,
                        ),
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: metaTextStyle.copyWith(
                    color: AssistantColors.faint,
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
  });

  final String id;
  final String label;
  final IconData icon;
  final int? count;

  /// Вторая строка цветом опасности: «1 просрочена».
  final String? alert;
  final bool selected;
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final box = wide ? 32.0 : 36.0;
    final semantics = <String>[
      label,
      if (count != null) '$count',
      if (alert != null) alert!,
    ].join(', ');
    // Просрочка — счётчик заметнее (рамка и текст ярче).
    final loud = alert != null;
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: Key('nav-$id'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: BoxConstraints(minHeight: wide ? 50 : 56),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AssistantColors.raised : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: box,
                height: box,
                decoration: BoxDecoration(
                  color: AssistantColors.raised,
                  border: Border.all(color: AssistantColors.borderSoft),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: wide ? 18 : 20,
                  color: AssistantColors.icon,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: wide ? 15 : 16,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                    if (alert != null)
                      Text(
                        alert!,
                        key: Key('nav-$id-alert'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: AssistantColors.danger,
                        ),
                      ),
                  ],
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 10),
                DecoratedBox(
                  key: Key('nav-$id-count'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: loud
                          ? AssistantColors.border
                          : AssistantColors.borderSoft,
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: SizedBox(
                    height: 26,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 28),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          widthFactor: 1,
                          child: MediaQuery.withNoTextScaling(
                            child: Text(
                              '$count',
                              maxLines: 1,
                              style: metaTextStyle.copyWith(
                                fontSize: 13,
                                height: 1.2,
                                fontWeight: FontWeight.w500,
                                color: loud
                                    ? AssistantColors.textStrong
                                    : AssistantColors.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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

const TextStyle _groupStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  height: 1.3,
  letterSpacing: .14,
  color: AssistantColors.muted,
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
        padding: EdgeInsets.fromLTRB(10, top, 10, 6),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: AssistantColors.muted),
              const SizedBox(width: 6),
            ],
            Flexible(child: Text(text, style: _groupStyle)),
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
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(label, style: _groupStyle)),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: metaTextStyle.copyWith(
                      fontSize: 13,
                      color: AssistantColors.faint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    open ? Icons.keyboard_arrow_down : Icons.chevron_right,
                    size: 16,
                    color: AssistantColors.icon,
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
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.expand_more,
                    size: 16,
                    color: AssistantColors.icon,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: metaTextStyle.copyWith(
                        fontSize: 13,
                        color: AssistantColors.muted,
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
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final half = constraints.maxWidth.isFinite
                    ? constraints.maxWidth / 2
                    : double.infinity;
                return Row(
                  children: <Widget>[
                    if (entry.icon != null) ...<Widget>[
                      Icon(entry.icon, size: 18, color: AssistantColors.icon),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: wide ? 15 : 16,
                          height: 1.35,
                          color: AssistantColors.textStrong,
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
                                color: entry.dotColor ?? entry.statusColor,
                              ),
                            ),
                            const SizedBox(width: 7),
                          ],
                          Flexible(
                            child: Text(
                              entry.status,
                              key: Key('drawer-extension-status-${entry.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metaTextStyle.copyWith(
                                fontSize: 13,
                                color: entry.statusColor,
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

/// Строка сессии: знак ответившего, название, время, вторая строка —
/// последний ответ. Долгое нажатие и правая кнопка — меню действий; на
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
    final row = InkWell(
      key: entry.itemKey,
      focusNode: _rowFocus,
      onTap: widget.onTap,
      onLongPress: _acts ? _openMenu : null,
      onSecondaryTap: _acts ? _openMenu : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: entry.active ? AssistantColors.raised : null,
          borderRadius: BorderRadius.circular(12),
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
            message:
                entry.unread ? '${entry.title} — новое сообщение' : entry.title,
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
                    if (entry.preview != null) entry.preview!,
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
                        color: AssistantColors.icon,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          backgroundColor: entry.active
                              ? AssistantColors.raised
                              : AssistantColors.sidebar,
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
        entry.muted ? AssistantColors.muted : AssistantColors.textStrong;
    final time = Text(
      entry.time,
      maxLines: 1,
      style: metaTextStyle.copyWith(
        fontSize: 13,
        color: AssistantColors.faint,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: wide ? 58 : 64),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: wide ? 7 : 8),
        child: Row(
          children: <Widget>[
            if (persona != null)
              PersonaMark(persona: persona, size: mark)
            else
              // Ещё никто не отвечал (новая сессия): вместо пустой рамки —
              // тихий знак «новое», ширина колонки та же.
              SizedBox(
                width: mark,
                height: mark,
                child: Icon(
                  Icons.edit_outlined,
                  size: mark * 0.7,
                  color: AssistantColors.faint,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: wide ? 15 : 16,
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
                          decoration: const BoxDecoration(
                            color: AssistantColors.textStrong,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                      const SizedBox(width: 10),
                      // «⋯» встаёт на место времени: ширина строки не
                      // прыгает.
                      Visibility(
                        visible: !more,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: time,
                      ),
                    ],
                  ),
                  if (entry.preview != null ||
                      entry.projectName != null) ...<Widget>[
                    const SizedBox(height: 1),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          if (entry.projectName != null) ...<InlineSpan>[
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.folder_outlined,
                                  key: Key('chat-project-${entry.id}'),
                                  size: wide ? 13 : 14,
                                  color: AssistantColors.faint,
                                ),
                              ),
                            ),
                            TextSpan(
                              text: entry.projectName,
                              style: const TextStyle(
                                color: AssistantColors.faint,
                              ),
                            ),
                            if (entry.preview != null)
                              const TextSpan(text: ' · '),
                          ],
                          if (entry.preview != null)
                            TextSpan(text: entry.preview),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: wide ? 13 : 14,
                        height: 1.4,
                        color: AssistantColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AssistantColors.textStrong),
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
                        style: metaTextStyle.copyWith(
                          color: AssistantColors.faint,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Время сессии, как в списке сессий (12:40, вчера).
                  Text(time, style: metaTextStyle),
                ],
              ),
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: snippet.substring(0, start)),
                    TextSpan(
                      text: snippet.substring(start, end),
                      style: const TextStyle(
                        color: AssistantColors.mark,
                        backgroundColor: AssistantColors.markBg,
                      ),
                    ),
                    TextSpan(text: snippet.substring(end)),
                  ],
                ),
                key: Key('search-snippet-${hit.chatId}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AssistantColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
