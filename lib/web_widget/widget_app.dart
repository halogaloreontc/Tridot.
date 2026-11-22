import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../app/shell/relay_drawer.dart';
import '../app/shell/session_header.dart';
import '../app/shell/session_hero.dart';
import '../app/widgets/action_card_view.dart';
import '../app/widgets/chat_feed_rhythm.dart';
import '../app/widgets/command_composer.dart';
import '../app/widgets/command_highlight.dart';
import '../app/widgets/keyboard_safe.dart';
import '../app/widgets/message_row.dart';
import '../app/widgets/network_capsule.dart';
import '../app/widgets/status_cube.dart';
import '../app/widgets/warehouse_card_view.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/formatting/due_format.dart';
import '../core/models/clarification.dart';
import '../core/models/task.dart';
import '../core/personas/persona.dart';
import 'widget_clarify.dart';
import 'widget_protocol.dart';
import 'widget_session.dart';
import 'widget_side.dart';

/// Веб-помощник склада выглядит как приложение Tridot (ADR-039): шапка
/// сессии («Название ▾» и кто отвечает), меню [RelayDrawer] (сессии по
/// дням, проекты, «Мой Связной»), лента [MessageRow], карточки склада и
/// действий, поле [CommandComposer], экраны проекта, задач и «Сегодня». От
/// [WidgetChat.wideFrom] меню стоит колонкой слева, как на компьютере; уже
/// (панель 420, телефон) — открывается кнопкой в шапке, как на телефоне.
/// Без `package:web`: тесты виджетов идут на VM.
final class WidgetApp extends StatelessWidget {
  const WidgetApp({super.key, required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? _) => MaterialApp(
          title: 'Связной',
          debugShowCheckedModeBanner: false,
          // Поле в фокусе — целиком над клавиатурой (ADR-044).
          builder: (BuildContext context, Widget? child) =>
              KeyboardSafeScope(child: child ?? const SizedBox.shrink()),
          theme: AssistantTheme.light(),
          darkTheme: AssistantTheme.dark(),
          themeMode: switch (session.theme) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          // Escape закрывает панель на компьютере (на телефоне — «Назад»
          // оболочки): фокус обычно внутри фрейма, страница склада клавишу
          // не получает. С экрана раздела — сначала в разговор.
          home: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              if (!(session.init?.phone ?? false))
                const SingleActivator(LogicalKeyboardKey.escape):
                    session.escape,
            },
            // Фокус внутри дерева с первого кадра: Escape работает сразу
            // после открытия панели, ещё до щелчка в поле.
            //
            // Без своей семантики: иначе при включённой семантике (main.dart)
            // этот узел — фокусируемый элемент страницы, и браузер отдавал
            // ему фокус, когда поле ввода его теряло. Фокус уходил из ленты
            // (Ctrl+C после выделения не копировал) и из поля (буквы
            // терялись).
            child: Focus(
              autofocus: true,
              includeSemantics: false,
              child: WidgetChat(session: session),
            ),
          ),
        ),
      );
}

final class WidgetChat extends StatefulWidget {
  const WidgetChat({super.key, required this.session});

  final WidgetSession session;

  /// С какой ширины меню — колонкой слева (склад расширяет панель до 760).
  static const double wideFrom = 700;

  /// Ширина колонки меню.
  static const double sideWidth = 300;

  /// С какой ширины справа ещё и «Сегодня» (помощник открыт во всё окно).
  static const double todayFrom = 1100;

  /// Ширина колонки «Сегодня».
  static const double todayWidth = 320;

  /// Колонка ленты и поля — как в приложении.
  static const double columnWidth = 760;

  @override
  State<WidgetChat> createState() => _WidgetChatState();
}

final class _WidgetChatState extends State<WidgetChat> {
  final CommandInputController _input = CommandInputController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  /// Выделение строк ленты: сообщения при копировании — с новой строки.
  final Map<Key, _LineSelectionDelegate> _lines =
      <Key, _LineSelectionDelegate>{};
  Set<Key?> _liveLines = <Key?>{};

  /// Колонка меню на широкой панели; свернуть — кнопкой в её шапке.
  bool _sidebarOpen = true;
  bool _todayOpen = true;
  int _sessionsShown = ChatBook.sessionsLimit;

  /// Позиция в истории команд для ↑/↓; `null` — новая команда.
  int? _cursor;

  WidgetSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => _session.draft = _input.text);
    _session.addListener(_changed);
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    for (final d in _lines.values) {
      d.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _submit() {
    final text = _input.text;
    if (text.trim().isEmpty || _session.busy) return;
    _input.clear();
    _cursor = null;
    unawaited(_session.send(text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
      // Лента перевёрнута: к последнему — это к началу.
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  List<String> get _commands => <String>[
        for (final m in _session.messages)
          if (m.fromUser && m.text.trim().isNotEmpty) m.text,
      ];

  String? _previous() {
    final list = _commands;
    if (list.isEmpty) return null;
    final next = (_cursor ?? list.length) - 1;
    if (next < 0) return null;
    _cursor = next;
    return list[next];
  }

  String? _next() {
    final list = _commands;
    final cursor = _cursor;
    if (cursor == null) return null;
    if (cursor + 1 >= list.length) {
      _cursor = null;
      return '';
    }
    _cursor = cursor + 1;
    return list[cursor + 1];
  }

  void _closeDrawer() {
    final scaffold = _scaffold.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints size) {
        final width = size.maxWidth;
        final ready =
            _session.phase == WidgetPhase.ready && _session.book != null;
        if (!ready) {
          return _waiting(context, wide: width >= WidgetChat.wideFrom);
        }
        final wide = width >= WidgetChat.wideFrom;
        final sidebar = wide && _sidebarOpen;
        final inChat = _session.view == WidgetView.chat;
        final today = inChat && width >= WidgetChat.todayFrom && _todayOpen;
        // Выдвижное меню — как на телефоне: до 360, справа полоса затемнения
        // не уже 30.
        final drawerWidth = math.max(240.0, math.min(360.0, width - 30));
        return Scaffold(
          key: _scaffold,
          backgroundColor: context.colors.background,
          onDrawerChanged: (bool open) {
            if (open) _focus.unfocus();
          },
          drawer: sidebar
              ? null
              : Drawer(
                  key: const ValueKey<String>('widget-drawer'),
                  width: drawerWidth,
                  backgroundColor: context.colors.sidebar,
                  child: SafeArea(
                    child: widgetDrawer(
                      context,
                      _session,
                      wide: false,
                      sessionsShown: _sessionsShown,
                      onShowMore: _showMore,
                      onPicked: _closeDrawer,
                    ),
                  ),
                ),
          body: SafeArea(
            child: Row(
              children: <Widget>[
                if (sidebar) ...<Widget>[
                  SizedBox(
                    width: WidgetChat.sideWidth,
                    child: widgetDrawer(
                      context,
                      _session,
                      wide: true,
                      sessionsShown: _sessionsShown,
                      onShowMore: _showMore,
                      onCollapse: () => setState(() => _sidebarOpen = false),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: _workspace(
                    context,
                    wide: wide,
                    sidebar: sidebar,
                    todayHidden:
                        inChat && width >= WidgetChat.todayFrom && !today,
                  ),
                ),
                if (today) ...<Widget>[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: WidgetChat.todayWidth,
                    child: todayPanel(
                      context,
                      _session,
                      onClose: () => setState(() => _todayOpen = false),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMore() => setState(() => _sessionsShown += ChatBook.sessionsLimit);

  /// До входа: шапка «Связной» и строка состояния по центру.
  Widget _waiting(BuildContext context, {required bool wide}) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final progress = _session.phase == WidgetPhase.waiting ||
        _session.phase == WidgetPhase.connecting;
    final String message = switch (_session.phase) {
      WidgetPhase.waiting || WidgetPhase.connecting => 'Подключаюсь к складу…',
      WidgetPhase.standalone =>
        'Связной открывается кнопкой помощника в шапке склада — '
            'с вашим входом в склад.',
      WidgetPhase.loggedOut =>
        'Вы вышли из склада. Войдите снова — и помощник откроется с вашим '
            'входом.',
      WidgetPhase.failed => _session.problem,
      WidgetPhase.ready => '',
    };
    return Scaffold(
      backgroundColor: colors.workspace,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SessionHeader(
              wide: wide,
              sessionTitle: 'Связной',
              persona: null,
              trailing: _trailing(context, ready: false, close: true),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (progress) ...<Widget>[
                        const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(height: AppSpace.m),
                      ],
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(color: colors.muted),
                      ),
                      if (_session.phase == WidgetPhase.failed) ...<Widget>[
                        const SizedBox(height: AppSpace.m),
                        FilledButton.tonal(
                          onPressed: () => unawaited(_session.retry()),
                          child: const Text('Попробовать ещё раз'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Кнопки справа в шапке: «Показать «Сегодня»», широкая панель, закрыть.
  /// [close] — «✕» в шапке только там, где нет поля: в разговоре выход —
  /// кнопка слева в поле, на месте «+» приложения (один выход на экране).
  Widget _trailing(
    BuildContext context, {
    required bool ready,
    required bool close,
    bool todayHidden = false,
  }) {
    final color = context.colors.text;
    final style = IconButton.styleFrom(minimumSize: const Size(44, 44));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (todayHidden)
          IconButton(
            key: const Key('today-show'),
            tooltip: 'Показать «Сегодня»',
            style: style,
            onPressed: () => setState(() => _todayOpen = true),
            icon: Icon(Icons.view_sidebar_outlined, color: color),
          ),
        if (ready && _session.canWide)
          IconButton(
            key: const ValueKey<String>('widget-wide'),
            tooltip: _session.wide ? 'Узкая панель' : 'Широкая панель',
            style: style,
            onPressed: () => _session.setWide(wide: !_session.wide),
            icon: Icon(
              _session.wide
                  ? Icons.close_fullscreen_rounded
                  : Icons.open_in_full_rounded,
              size: 20,
              color: color,
            ),
          ),
        if (close)
          IconButton(
            key: const ValueKey<String>('widget-close'),
            tooltip: 'Закрыть',
            style: style,
            onPressed: _session.close,
            icon: Icon(Icons.close_rounded, color: color),
          ),
      ],
    );
  }

  Widget _workspace(
    BuildContext context, {
    required bool wide,
    required bool sidebar,
    required bool todayHidden,
  }) {
    final session = _session;
    final book = session.book!;
    final inChat = session.view == WidgetView.chat;
    final current = book.current;
    final Widget? leading = sidebar
        ? null
        : IconButton(
            key: const ValueKey<String>('widget-menu'),
            tooltip: 'Меню',
            onPressed: wide
                ? () => setState(() => _sidebarOpen = true)
                : () => _scaffold.currentState?.openDrawer(),
            style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
            icon: Icon(Icons.menu, color: context.colors.text),
          );
    final taskTitle = current.kind == ChatKind.task
        ? session.taskList
            .where((Task t) => t.id == current.taskId)
            .firstOrNull
            ?.title
        : null;
    final canAct = current.messageCount > 0;
    final Widget? title = switch (session.view) {
      WidgetView.chat => null,
      WidgetView.project => _SectionTitle(
          book.project(session.projectId)?.name ?? 'Проект',
        ),
      WidgetView.today => const _SectionTitle('Мой Связной'),
      // У задач, проектов и планирования — крупный заголовок на самом
      // экране, как в приложении.
      _ => const SizedBox.shrink(),
    };
    return Material(
      color: inChat ? context.colors.workspace : context.colors.background,
      child: Column(
        children: <Widget>[
          SessionHeader(
            wide: wide || title != null,
            leading: leading,
            title: title,
            sessionTitle: ChatBook.titleOf(current, taskTitle: taskTitle),
            persona: Personas.sado,
            onSessionAction: canAct
                ? (SessionAction action) => unawaited(
                      sessionAction(context, session, current.id, action),
                    )
                : null,
            pinned: current.pinned,
            canRename: current.isSession,
            canMove: current.isSession,
            projectName: book.projectOf(current.id)?.name,
            cube: inChat && session.busy
                ? const StatusCube(state: CubeState.working, size: 14)
                : null,
            trailing: _trailing(
              context,
              ready: true,
              close: !inChat,
              todayHidden: todayHidden,
            ),
          ),
          Divider(color: context.colors.divider),
          if (inChat && session.reminders.isNotEmpty)
            _Reminders(session: session),
          Expanded(
            child: inChat ? _chat(context) : widgetScreen(context, session),
          ),
          if (inChat) _composer(context),
        ],
      ),
    );
  }

  /// Колонка ленты и поля не шире, чем в приложении.
  Widget _column({
    required AlignmentGeometry alignment,
    required Widget child,
  }) =>
      Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: WidgetChat.columnWidth),
          child: child,
        ),
      );

  Widget _chat(BuildContext context) {
    final session = _session;
    final book = session.book!;
    final current = book.current;
    final messages = session.messages;
    final now = session.now;
    if (messages.isEmpty && !session.busy) {
      final overdue =
          activeTasks(session).where((Task t) => isOverdue(t, now)).length;
      final examples = session.examples;
      return SessionHero(
        persona: Personas.sado,
        notifier: Personas.sado,
        projectName: book.projectOf(current.id)?.name,
        overdue: overdue,
        onOverdue: () => session.show(WidgetView.today),
        note: <String>[
          if (session.who.isNotEmpty) session.who,
          examples.isEmpty
              ? 'Спросите склад: где лежит артикул, сколько осталось, что '
                  'пришло сегодня.'
              : 'Спросите склад, например: '
                  '${examples.take(3).map((String e) => '«$e»').join(', ')}.',
          if (!session.synced)
            'Сессии хранятся только в этом браузере: склад пока не хранит '
                'записи помощника.',
        ].join('\n'),
      );
    }
    final cast = PersonaCast.current;
    final rows = <Widget>[];
    // Карточка действия — под последним ответом с ней.
    final lastWithCard = <String, int>{};
    for (var i = 0; i < messages.length; i++) {
      final card = messages[i].card;
      if (card != null) lastWithCard[card.id] = i;
    }
    // Ритм ленты (ADR-027) — как в приложении: [ChatFeedRhythm] ставит
    // метку времени над группой, имя помощника и промежутки.
    final rhythm = ChatFeedRhythm();
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final at = message.timestamp;
      final author = message.fromUser ? null : cast.find(message.personaId);
      final beat = rhythm.next(
        at: at,
        fromUser: message.fromUser,
        authorId: author?.id,
      );
      if (beat.newGroup) {
        rows.add(
          ChatGroupTime(
            key: ValueKey<String>('group-time-${message.id}'),
            label: groupTimeLabel(at, now),
            first: rows.isEmpty,
          ),
        );
      }
      final card = _card(message, i, lastWithCard) ?? _clarify(message);
      rows.add(
        MessageRow(
          key: ValueKey<String>('msg-${message.id}'),
          cast: cast,
          message: message,
          now: now,
          showTime: false,
          showAuthor: beat.showAuthor,
          topGap: beat.topGap,
          checklist: card,
          onOpenTask: (Task task) => unawaited(session.openTask(task.id)),
          onToggleDone: (Task task) => toggleDone(session, task),
          selectable: false,
        ),
      );
      rhythm.placed(hadCard: card != null);
    }
    if (session.busy) {
      // Строка «думает» — голосом того, кто ответит
      // ([WidgetSession.thinking]); без помощника — от имени Связного.
      final thinking = session.thinking ??
          ChatMessage(
            id: 'working',
            author: ChatAuthor.persona,
            text: 'Связной думает…',
            timestamp: now,
            personaId: Personas.sado.id,
          );
      final beat = rhythm.working(
        authorId: cast.find(thinking.personaId)?.id,
      );
      rows.add(
        MessageRow(
          key: const Key('working-message'),
          cast: cast,
          message: thinking,
          now: now,
          showTime: false,
          showAuthor: beat.showAuthor,
          topGap: beat.topGap,
          thinking: true,
          selectable: false,
          onOpenTask: (_) {},
          onToggleDone: (_) {},
        ),
      );
    }
    _pruneLines(<Key?>{for (final row in rows) row.key});
    return _column(
      alignment: Alignment.topCenter,
      // Одно выделение на всю ленту: через сообщения и абзацы, копирование —
      // само Flutter (Ctrl+C, меню), а не поле `<textarea>` браузера на
      // каждом сообщении (см. [MessageRow.selectable]).
      child: SelectionArea(
        key: const Key('chat-selection'),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            key: const Key('chat-list'),
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpace.pageH,
              AppSpace.m,
              AppSpace.pageH,
              AppSpace.m,
            ),
            children: <Widget>[
              for (final Widget row in rows.reversed)
                SelectionContainer(
                  delegate: _lineFor(row.key),
                  child: row,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Строки ушли из ленты (другая сессия) — их выделение освобождается
  /// после кадра, когда старые строки уже сняты.
  void _pruneLines(Set<Key?> live) {
    _liveLines = live;
    if (_lines.keys.every(live.contains)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Ключи последней постройки: за кадр лента могла собраться не раз.
      final now = _liveLines;
      final gone = <Key>[
        for (final key in _lines.keys)
          if (!now.contains(key)) key,
      ];
      for (final key in gone) {
        _lines.remove(key)?.dispose();
      }
    });
  }

  /// Выделение строки ленты — своё на каждую (по ключу строки), чтобы не
  /// терять его при перестройке.
  _LineSelectionDelegate _lineFor(Key? key) =>
      _lines.putIfAbsent(key ?? const Key('row'), _LineSelectionDelegate.new);

  /// Карточка под ответом: склад (строки, «Открыть в складе») или действие
  /// (подтвердить, отменить, проверить).
  Widget? _card(ChatMessage message, int index, Map<String, int> lastWithCard) {
    final session = _session;
    final warehouse = message.warehouse;
    if (warehouse != null) {
      return WarehouseCardView(
        key: ValueKey<String>('warehouse-${message.id}'),
        card: warehouse,
        showSay: warehouse.say.trim() != message.text.trim(),
        onOpen: session.openWarehouse,
        onOpenLink: session.openWarehouseLink,
      );
    }
    final card = message.card;
    if (card == null || lastWithCard[card.id] != index) return null;
    return ActionCardView(
      card: card,
      busy: session.busy,
      now: DateTime.now,
      onConfirm: () => unawaited(session.answerCard(card, apply: true)),
      onCancel: () => unawaited(session.answerCard(card, apply: false)),
      onSettle: () => unawaited(
        session.settleCard(card, personaId: message.personaId),
      ),
    );
  }

  /// Кнопки вопроса, пока он ждёт ответа (только в памяти: после
  /// перезагрузки остаётся текст).
  Widget? _clarify(ChatMessage message) {
    final session = _session;
    final clarification = message.clarification;
    if (clarification == null ||
        !identical(session.pendingClarification, clarification)) {
      return null;
    }
    return WidgetClarifyButtons(
      key: ValueKey<String>('clarify-${message.id}'),
      clarification: clarification,
      enabled: !session.busy,
      onChoose: (ClarifyOption option) => unawaited(session.choose(option)),
    );
  }

  Widget _composer(BuildContext context) {
    final session = _session;
    // Помощник пересоздаётся при смене входа: подсветка — от текущего.
    _input.highlighter = session.controller?.highlight;
    final voice = session.voice;
    final mode = !voice.showButton
        ? VoiceButtonMode.hidden
        : session.listening
            ? VoiceButtonMode.listening
            : voice.available
                ? VoiceButtonMode.idle
                : VoiceButtonMode.off;
    return _column(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(AppSpace.pageH, 4, AppSpace.pageH, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Нет сети — капсула над полем (ADR-040).
            NetworkCapsule(status: session.network),
            CommandComposer(
              controller: _input,
              focusNode: _focus,
              sending: session.busy,
              mode: AssistantViewMode.dialogue,
              onModeChanged: (_) {},
              modes: false,
              plus: false,
              // Выход — на месте «+» приложения, того же вида; «✕» в шапке
              // разговора нет.
              leading: ComposerRoundButton(
                key: const ValueKey<String>('widget-exit'),
                icon: Icons.arrow_back_rounded,
                tooltip: 'Закрыть помощника',
                semanticsLabel: 'Закрыть помощника',
                onTap: session.close,
              ),
              hint: 'Спросите склад…',
              inputKey: const ValueKey<String>('widget-input'),
              sendKey: const ValueKey<String>('widget-send'),
              maxLength: 500,
              onSend: _submit,
              onCommand: (_) {},
              previousCommand: _previous,
              nextCommand: _next,
              voiceMode: mode,
              voicePartial: session.listening ? session.partial : null,
              voiceNotice: session.listening ? null : session.voiceNote,
              onVoiceTap: session.startVoice,
              // Долгое нажатие на пустое поле — голос, только если
              // распознавание есть: иначе оно отняло бы меню «Вставить».
              onVoiceLongPress: voice.available ? session.startVoice : null,
              onVoiceCancel: session.cancelVoice,
              // Enter не снимает фокус: Escape по-прежнему закрывает панель.
              onEditingComplete: () {},
            ),
          ],
        ),
      ),
    );
  }
}

/// Заголовок раздела в шапке.
final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Text(
          title,
          key: const Key('section-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: context.colors.textStrong,
          ),
        ),
      );
}

/// Напоминания при открытии: склад и свои задачи — карточкой над лентой, с
/// кнопками действий.
final class _Reminders extends StatelessWidget {
  const _Reminders({required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final list = session.reminders;
    final first = list.first;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: WidgetChat.columnWidth),
        child: Container(
          key: const ValueKey<String>('widget-reminders'),
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(
            AppSpace.pageH,
            AppSpace.xs,
            AppSpace.pageH,
            0,
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpace.m,
            AppSpace.xs,
            AppSpace.xxs,
            AppSpace.xs,
          ),
          decoration: BoxDecoration(
            color: colors.raised,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.notifications_active_outlined,
                    size: 18,
                    color:
                        first.level == 'warn' ? colors.danger : colors.accent,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      'Напоминание: ${first.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.titleSmall?.copyWith(color: colors.textStrong),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('reminder-close'),
                    tooltip: 'Убрать',
                    visualDensity: VisualDensity.compact,
                    icon:
                        Icon(Icons.close_rounded, size: 18, color: colors.icon),
                    onPressed: () => session.dismissReminder(first),
                  ),
                ],
              ),
              if (first.text.isNotEmpty)
                Text(first.text, style: text.bodySmall),
              if (first.actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xxs),
                  child: Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xxs,
                    children: <Widget>[
                      for (final action in first.actions)
                        ActionChip(
                          key: ValueKey<String>('reminder-${action.id}'),
                          label: Text(action.label),
                          onPressed: session.busy
                              ? null
                              : () => unawaited(_run(context, first, action)),
                        ),
                    ],
                  ),
                ),
              if (list.length > 1)
                TextButton(
                  key: const ValueKey<String>('reminder-more'),
                  onPressed: () => session.dismissReminder(first),
                  child: Text(
                    'ещё ${list.length - 1} ${_plural(list.length - 1)} ›',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _plural(int n) {
    final ten = n % 10;
    final hundred = n % 100;
    if (ten == 1 && hundred != 11) return 'напоминание';
    if (ten >= 2 && ten <= 4 && (hundred < 12 || hundred > 14)) {
      return 'напоминания';
    }
    return 'напоминаний';
  }

  Future<void> _run(
    BuildContext context,
    WidgetSignal signal,
    SignalAction action,
  ) async {
    DateTime? date;
    if (action.dateLabel != null) {
      final now = DateTime.now();
      date = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: now.subtract(const Duration(days: 1)),
        lastDate: DateTime(now.year + 2),
        helpText: action.dateLabel,
      );
      if (date == null) return;
    }
    await session.runReminder(signal, action, date: date);
  }
}

/// Строка ленты (сообщение, метка времени) при выделении: её тексты — имя
/// помощника и сообщение — с новой строки, и если выделение идёт дальше
/// вниз по ленте — перевод строки в конце. Обычный `SelectionArea` склеивал
/// сообщения: «лежит 64115СвязнойСклад пока…».
final class _LineSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[
      for (final Selectable selectable in selectables)
        if (selectable.getSelectedContent()?.plainText case final String text
            when text.isNotEmpty)
          text,
    ];
    if (parts.isEmpty) return null;
    final text = parts.join('\n');
    return SelectedContent(plainText: goesOn ? '$text\n' : text);
  }

  /// Где сейчас края выделения (в координатах экрана); `null` — край
  /// задан не мышью (слово, всё, сброс).
  Offset? _start;
  Offset? _end;

  /// Выделено всё (Ctrl+A): каждая строка — с новой.
  bool _all = false;

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    switch (event) {
      case SelectionEdgeUpdateEvent(:final type, :final globalPosition):
        if (type == SelectionEventType.startEdgeUpdate) {
          _start = globalPosition;
        } else {
          _end = globalPosition;
        }
        _all = false;
      case SelectAllSelectionEvent():
        _all = true;
        _start = _end = null;
      default:
        _all = false;
        _start = _end = null;
    }
    return super.dispatchSelectionEvent(event);
  }

  /// Выделение продолжается ниже этой строки: дальний край — под ней.
  bool get goesOn {
    if (value.status != SelectionStatus.uncollapsed) return false;
    if (_all) return true;
    final start = _start;
    final end = _end;
    if (start == null || end == null) return false;
    final far = end.dy >= start.dy ? end : start;
    final local = MatrixUtils.transformPoint(
      Matrix4.inverted(getTransformTo(null)),
      far,
    );
    return local.dy > containerSize.height;
  }
}
