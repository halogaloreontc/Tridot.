import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../core/chats/chat_search.dart';
import '../../core/personas/persona.dart';
import '../assistant_theme.dart';
import '../widgets/personas_section.dart';

/// Строка «Недавних сессий» в меню.
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
  });

  final String id;
  final String title;

  /// «12:40», «вчера», «пн», «9 нояб.».
  final String time;
  final Key itemKey;
  final Key dotKey;

  /// Открыта сейчас.
  final bool active;

  /// Пришло сообщение, пока сессия была закрыта.
  final bool unread;

  /// Приглушённая (выполненная задача).
  final bool muted;
}

/// Строка расширения в дереве «Расширения»: «Пароли · заперт»,
/// «Склад · на связи».
final class ExtensionEntry {
  const ExtensionEntry({
    required this.id,
    required this.title,
    required this.status,
    required this.onTap,
    this.statusColor = AssistantColors.muted,
    this.dot = false,
  });

  final String id;
  final String title;
  final String status;
  final Color statusColor;

  /// Точка состояния перед подписью (подключения).
  final bool dot;
  final VoidCallback onTap;
}

/// Подпись времени в списках: сегодня — «12:40», вчера — «вчера», на
/// этой неделе — «пн», раньше — «9 нояб.».
String sessionTimeLabel(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) {
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
  }
  if (diff == 1) return 'вчера';
  if (diff < 7) {
    const week = <String>['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
    return week[at.weekday - 1];
  }
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

/// Левая панель (макет «Д»): шапка «Связной» с версией, «Мой Связной»,
/// разделы, расширения, недавние сессии, внизу — поиск по сессиям и «+»
/// (новая сессия).
///
/// На телефоне — содержимое выдвижной панели, на широком экране —
/// постоянная колонка ([wide]) с «Свернуть панель». Настроек здесь нет:
/// они в «Мой Связной».
final class RelayDrawer extends StatefulWidget {
  const RelayDrawer({
    super.key,
    required this.sessions,
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
    this.wide = false,
    this.onCollapse,
    this.searchFocus,
    this.reduceMotion = false,
    this.activeSection,
  });

  final List<SessionEntry> sessions;
  final List<ExtensionEntry> extensions;
  final VoidCallback onOpenMyRelay;
  final VoidCallback onTasks;
  final VoidCallback onProjects;
  final VoidCallback onPlanning;
  final ValueChanged<String> onOpenSession;
  final VoidCallback onNewSession;

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

  Duration get _motion => widget.reduceMotion ||
          MediaQuery.maybeDisableAnimationsOf(context) == true
      ? Duration.zero
      : const Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    // Выдвижная панель на телефоне: Scaffold не сжимает её под экранную
    // клавиатуру, поэтому отступ снизу — на высоту клавиатуры, и поиск с
    // «Отменой» стоит прямо над ней. Колонка на компьютере — без отступа.
    final inset = widget.wide ? 0.0 : MediaQuery.viewInsetsOf(context).bottom;
    // Клавиатура открыта для поиска: шапка, «Мой Связной» и разделы
    // уступают место результатам.
    final roomy = !(_searching && inset > 0);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (roomy) ...<Widget>[
          _TitlePlate(onCollapse: widget.onCollapse),
          _MyRelayCard(onTap: widget.onOpenMyRelay, wide: widget.wide),
          const SizedBox(height: 8),
          _Sections(
            active: widget.activeSection,
            onTasks: widget.onTasks,
            onProjects: widget.onProjects,
            onPlanning: widget.onPlanning,
          ),
          const SizedBox(height: 4),
        ],
        Expanded(
          child: ListView(
            key: const Key('drawer-scroll'),
            padding: EdgeInsets.zero,
            children: <Widget>[
              if (widget.extensions.isNotEmpty && roomy) _buildExtensions(),
              if (_searching && _query.text.trim().isNotEmpty)
                ..._buildHits()
              else
                ..._buildSessions(),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildBottomRow(context),
      ],
    );
    return Material(
      key: const Key('app-sidebar'),
      color: AssistantColors.sidebar,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + inset),
        child: body,
      ),
    );
  }

  Widget _buildExtensions() {
    return Column(
      key: const Key('drawer-extensions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          header: true,
          button: true,
          expanded: _extensionsOpen,
          label: 'Расширения',
          onTap: () => setState(() => _extensionsOpen = !_extensionsOpen),
          excludeSemantics: true,
          child: InkWell(
            key: const Key('drawer-extensions-toggle'),
            onTap: () => setState(() => _extensionsOpen = !_extensionsOpen),
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Icon(
                      _extensionsOpen
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: AssistantColors.muted,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Расширения', style: technicalTextStyle),
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
                left: 14,
                top: 2,
                bottom: 2,
                child: SizedBox(
                  width: 1,
                  child: ColoredBox(color: AssistantColors.border),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final entry in widget.extensions)
                      _ExtensionRow(entry: entry),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  List<Widget> _buildSessions() => <Widget>[
        const _ListHeader('Недавние сессии'),
        for (final entry in widget.sessions)
          _SessionRow(
            entry: entry,
            onTap: () => widget.onOpenSession(entry.id),
          ),
      ];

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
                              suffixStyle: technicalTextStyle,
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

/// Шапка панели: «Связной» и версия; на компьютере справа — «Свернуть
/// панель».
final class _TitlePlate extends StatelessWidget {
  const _TitlePlate({required this.onCollapse});

  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: Semantics(
                header: true,
                child: const Text(
                  AppInfo.name,
                  key: ValueKey<String>('app-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AssistantColors.textStrong,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              label: 'Версия ${AppInfo.version}',
              excludeSemantics: true,
              child: const Text(
                AppInfo.version,
                key: ValueKey<String>('app-version'),
                maxLines: 1,
                style: technicalTextStyle,
              ),
            ),
            const Spacer(),
            if (onCollapse != null)
              IconButton(
                key: const Key('sidebar-collapse'),
                tooltip: 'Свернуть панель',
                onPressed: onCollapse,
                icon: const Icon(Icons.keyboard_double_arrow_left),
              ),
          ],
        ),
      ),
    );
  }
}

/// Карточка «Мой Связной»: знаки Л и Н внахлёст, название, шеврон.
final class _MyRelayCard extends StatelessWidget {
  const _MyRelayCard({required this.onTap, required this.wide});

  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final size = wide ? 32.0 : 36.0;
    return Semantics(
      button: true,
      label: 'Мой Связной',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: AssistantColors.raised,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AssistantColors.borderSoft),
          borderRadius: BorderRadius.circular(wide ? 14 : 16),
        ),
        child: InkWell(
          key: const Key('drawer-my-relay'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(wide ? 14 : 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: wide ? 72 : 80),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: <Widget>[
                  RelayAvatars(size: size),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Мой Связной',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: wide ? 16 : 17,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
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

/// Знаки Лиорио и Ноды внахлёст.
final class RelayAvatars extends StatelessWidget {
  const RelayAvatars({
    super.key,
    this.size = 36,
    this.ring = AssistantColors.raised,
  });

  final double size;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 2 - size / 4,
      height: size,
      child: Stack(
        children: <Widget>[
          PersonaMark(
            persona: Personas.liorio,
            size: size,
            round: true,
            ring: ring,
          ),
          Positioned(
            left: size - size / 4,
            child: PersonaMark(
              persona: Personas.noda,
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

final class _Sections extends StatelessWidget {
  const _Sections({
    required this.active,
    required this.onTasks,
    required this.onProjects,
    required this.onPlanning,
  });

  final String? active;
  final VoidCallback onTasks;
  final VoidCallback onProjects;
  final VoidCallback onPlanning;

  @override
  Widget build(BuildContext context) {
    final items = <(String, String, IconData, VoidCallback)>[
      ('tasks', 'Задачи', Icons.task_alt, onTasks),
      ('projects', 'Проекты', Icons.tag, onProjects),
      ('planning', 'Планирование', Icons.calendar_today_outlined, onPlanning),
    ];
    return Semantics(
      container: true,
      label: 'Разделы',
      child: Row(
        children: <Widget>[
          for (final (index, (id, label, icon, onTap)) in items.indexed) ...[
            if (index > 0) const SizedBox(width: 6),
            Expanded(
              child: Semantics(
                button: true,
                selected: active == id,
                label: label,
                onTap: onTap,
                excludeSemantics: true,
                child: InkWell(
                  key: Key('nav-$id'),
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: active == id ? AssistantColors.raised : null,
                      border: Border.all(color: AssistantColors.divider),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(icon, size: 18),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: AssistantColors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _ListHeader extends StatelessWidget {
  const _ListHeader(this.text, {super.key, this.live = false});

  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      liveRegion: live,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
        child: Text(text, style: technicalTextStyle),
      ),
    );
  }
}

final class _ExtensionRow extends StatelessWidget {
  const _ExtensionRow({required this.entry});

  final ExtensionEntry entry;

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
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AssistantColors.text),
                  ),
                ),
                const SizedBox(width: 12),
                if (entry.dot) ...<Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: entry.statusColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    entry.status,
                    key: Key('drawer-extension-status-${entry.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: technicalTextStyle.copyWith(
                      color: entry.statusColor,
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

final class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.entry, required this.onTap});

  final SessionEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = entry.active
        ? AssistantColors.textStrong
        : entry.muted
            ? AssistantColors.muted
            : AssistantColors.text;
    final label = 'Сессия «${entry.title}»';
    return Tooltip(
      message: entry.unread ? '${entry.title} — новое сообщение' : entry.title,
      child: Semantics(
        button: true,
        selected: entry.active,
        label: entry.unread ? '$label, новое сообщение' : label,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          key: entry.itemKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: entry.active ? AssistantColors.raised : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color),
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
                const SizedBox(width: 12),
                Text(entry.time, style: technicalTextStyle),
              ],
            ),
          ),
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
      label: '${hit.title}: $snippet',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: Key('search-hit-${hit.chatId}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  // Время сессии, как в «Недавних сессиях» (12:40, вчера).
                  Text(time, style: technicalTextStyle),
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
