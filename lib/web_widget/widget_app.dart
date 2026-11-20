import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../app/shell/quick_actions.dart';
import '../app/shell/session_header.dart';
import '../app/shell/session_hero.dart';
import '../app/widgets/status_cube.dart';
import '../app/widgets/action_card_view.dart';
import '../app/widgets/chat_feed_rhythm.dart';
import '../app/widgets/command_highlight.dart';
import '../app/widgets/composer_shell.dart';
import '../app/widgets/keyboard_safe.dart';
import '../app/widgets/message_row.dart';
import '../app/widgets/warehouse_card_view.dart';
import '../core/chats/chat_models.dart';
import '../core/personas/persona.dart';
import 'widget_session.dart';

/// Веб-помощник склада — чат из тех же частей, что сессия приложения
/// (ADR-038): шапка [SessionHeader], пустой чат [SessionHero], лента
/// [MessageRow] с ритмом [ChatFeedRhythm], поле [ComposerShell]; микрофон —
/// только в оболочке Android. Без `package:web`: тесты виджетов идут на VM.
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
          // не получает.
          home: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              if (!(session.init?.phone ?? false))
                const SingleActivator(LogicalKeyboardKey.escape):
                    session.escape,
            },
            // Фокус внутри дерева с первого кадра: Escape работает сразу
            // после открытия панели, ещё до щелчка в поле.
            child: Focus(
              autofocus: true,
              child: WidgetChat(session: session),
            ),
          ),
        ),
      );
}

final class WidgetChat extends StatefulWidget {
  const WidgetChat({super.key, required this.session});

  final WidgetSession session;

  @override
  State<WidgetChat> createState() => _WidgetChatState();
}

final class _WidgetChatState extends State<WidgetChat> {
  final CommandInputController _input = CommandInputController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  int _seen = 0;

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
    super.dispose();
  }

  void _changed() {
    if (_session.messages.length != _seen) {
      _seen = _session.messages.length;
      // Лента перевёрнута, как в приложении: низ — начало прокрутки.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    if (mounted) setState(() {});
  }

  void _submit() {
    final text = _input.text;
    if (text.trim().isEmpty || _session.busy) return;
    _input.clear();
    unawaited(_session.send(text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Лента — на workspace, как чат Tridot (ADR-027): карточки и поле ввода
    // цвета raised на нём видны и в светлой теме.
    return Scaffold(
      backgroundColor: colors.workspace,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _Header(session: _session),
            Expanded(child: _body(context)),
            if (_session.phase == WidgetPhase.ready) ...<Widget>[
              _examples(),
              _composer(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    Widget note(String message, {Widget? action, bool progress = false}) =>
        Center(
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
                  style: text.bodyMedium?.copyWith(color: colors.muted),
                ),
                if (action != null) ...<Widget>[
                  const SizedBox(height: AppSpace.m),
                  action,
                ],
              ],
            ),
          ),
        );
    switch (_session.phase) {
      case WidgetPhase.waiting:
      case WidgetPhase.connecting:
        return note('Подключаюсь к складу…', progress: true);
      case WidgetPhase.standalone:
        return note(
          'Связной открывается кнопкой помощника в шапке склада — '
          'с вашим входом в склад.',
        );
      case WidgetPhase.loggedOut:
        return note(
          'Вы вышли из склада. Войдите снова — и помощник откроется с вашим '
          'входом.',
        );
      case WidgetPhase.failed:
        return note(
          _session.problem,
          action: FilledButton.tonal(
            onPressed: () => unawaited(_session.retry()),
            child: const Text('Попробовать ещё раз'),
          ),
        );
      case WidgetPhase.ready:
        break;
    }
    final messages = _session.messages;
    if (messages.isEmpty) {
      // Пустой чат — как новая сессия приложения: знак Связного и «Что
      // сделать?», под ним — кто вошёл в склад.
      final who = _session.who;
      return SessionHero(
        persona: Personas.sado,
        note: who.isEmpty ? null : who,
      );
    }
    return _feed(context, messages);
  }

  static final PersonaCast _cast = PersonaCast.of(
    const PersonaSettings(teamMode: TeamMode.solo, emoji: false),
  );

  /// Лента — те же строки и ритм, что в приложении ([MessageRow],
  /// [ChatFeedRhythm]): метки времени группы, имя над ответом, промежутки.
  /// Без задач, вложений и времени у каждого сообщения (в приложении оно
  /// по умолчанию выключено).
  Widget _feed(BuildContext context, List<ChatMessage> messages) {
    final now = _session.now;
    final lastWithCard = lastIndexById(messages, (ChatMessage m) => m.card?.id);
    final rhythm = ChatFeedRhythm();
    final rows = <Widget>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final author = message.fromUser ? null : _cast.find(message.personaId);
      final beat = rhythm.next(
        at: message.timestamp,
        fromUser: message.fromUser,
        authorId: author?.id,
      );
      if (beat.newGroup) {
        rows.add(
          GroupTime(
            key: ValueKey<String>('group-time-${message.id}'),
            label: groupTimeLabel(message.timestamp, now),
            first: rows.isEmpty,
          ),
        );
      }
      final card = _card(message, i, lastWithCard);
      rows.add(
        MessageRow(
          cast: _cast,
          message: message,
          now: now,
          showTime: false,
          showAuthor: beat.showAuthor,
          topGap: beat.topGap,
          checklist: card,
          onOpenTask: (_) {},
          onToggleDone: (_) {},
        ),
      );
      rhythm.placed(hadCard: card != null);
    }
    final thinking = _session.thinking;
    if (thinking != null) {
      final author = _cast.find(thinking.personaId);
      final beat = rhythm.working(authorId: author?.id);
      rows.add(
        MessageRow(
          cast: _cast,
          key: const ValueKey<String>('working-message'),
          message: thinking,
          now: now,
          showTime: false,
          showAuthor: beat.showAuthor,
          topGap: beat.topGap,
          thinking: true,
          onOpenTask: (_) {},
          onToggleDone: (_) {},
        ),
      );
    }
    // Верх ленты гаснет на строку текста, полосы прокрутки нет — как в
    // приложении.
    final topFade = math.max(
      AppSpace.m,
      MediaQuery.textScalerOf(context).scale(16) * 1.4,
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (Rect bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[Colors.transparent, Colors.black],
          stops: <double>[
            0,
            bounds.height <= topFade ? 0 : topFade / bounds.height,
          ],
        ).createShader(bounds),
        child: ListView(
          key: const ValueKey<String>('widget-feed'),
          controller: _scroll,
          reverse: true,
          padding: EdgeInsets.fromLTRB(
            AppSpace.pageH,
            topFade,
            AppSpace.pageH,
            AppSpace.m,
          ),
          children: rows.reversed.toList(),
        ),
      ),
    );
  }

  /// Карточка под ответом: склад — всегда, действие — только под последним
  /// ответом с ней (как в приложении).
  Widget? _card(ChatMessage message, int index, Map<String, int> lastWithCard) {
    final warehouse = message.warehouse;
    if (warehouse != null) {
      return WarehouseCardView(
        card: warehouse,
        showSay: warehouse.say.trim() != message.text.trim(),
        onOpen: _session.openWarehouse,
        onOpenLink: _session.openWarehouseLink,
      );
    }
    final card = message.card;
    if (card == null || lastWithCard[card.id] != index) return null;
    return ActionCardView(
      card: card,
      busy: _session.busy,
      onConfirm: () => unawaited(_session.answerCard(card, apply: true)),
      onCancel: () => unawaited(_session.answerCard(card, apply: false)),
      onSettle: () => unawaited(
        _session.settleCard(card, personaId: message.personaId),
      ),
    );
  }

  /// Примеры вопросов из описания склада — кнопками над полем ввода, как
  /// быстрые действия в новой сессии приложения: нажатие спрашивает.
  Widget _examples() {
    final examples = _session.examples;
    if (_session.messages.isNotEmpty || examples.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xxs),
      child: QuickActionsRow(
        label: 'Примеры вопросов',
        inset: AppSpace.pageH,
        items: <QuickRowItem>[
          for (final example in examples)
            (
              ValueKey<String>('widget-example-$example'),
              (
                example,
                Icons.search_rounded,
                _session.busy
                    ? null
                    : () {
                        _input.clear();
                        unawaited(_session.send(example));
                      },
              ),
            ),
        ],
      ),
    );
  }

  /// Поле ввода приложения ([ComposerShell]) без «+», вложений и
  /// «Диалог / Документ»: у помощника склада их нет. Глагол команды
  /// подсвечивается, как в приложении.
  Widget _composer(BuildContext context) {
    // Помощник пересоздаётся при смене входа: подсветка — от текущего.
    _input.highlighter = _session.controller?.highlight;
    final voice = _session.voice;
    final VoiceButtonMode mode;
    if (!voice.showButton) {
      mode = VoiceButtonMode.hidden;
    } else if (_session.listening) {
      mode = VoiceButtonMode.listening;
    } else {
      mode = VoiceButtonMode.idle;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageH,
        AppSpace.xxs,
        AppSpace.pageH,
        AppSpace.s,
      ),
      child: ComposerShell(
        controller: _input,
        focusNode: _focus,
        sending: _session.busy,
        onSend: _submit,
        hintText: 'Спросите склад…',
        maxLength: 500,
        // Enter не снимает фокус: следующий вопрос печатается сразу, и
        // Escape по-прежнему закрывает панель.
        onEditingComplete: () {},
        voiceMode: mode,
        onVoiceTap: _session.startVoice,
        // Долгое нажатие на пустое поле — голос, только если распознавание
        // есть: иначе оно отняло бы у поля меню «Вставить».
        onVoiceLongPress: voice.available ? _session.startVoice : null,
        onVoiceCancel: _session.cancelVoice,
        voicePartial: _session.listening
            ? (_session.partial.isEmpty ? 'Слушаю…' : _session.partial)
            : null,
        voiceNotice: _session.voiceNote.isEmpty ? null : _session.voiceNote,
        inputKey: const ValueKey<String>('widget-input'),
        sendKey: const ValueKey<String>('widget-send'),
        voiceKey: const ValueKey<String>('widget-mic'),
      ),
    );
  }
}

/// Шапка как у сессии в приложении (ADR-027): название посередине, под
/// ним точка и имя помощника, кубик — пока он думает. Справа «Новый чат» и
/// «Закрыть» вместо «⋯»: рамки вокруг фрейма склад не рисует.
final class _Header extends StatelessWidget {
  const _Header({required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ready = session.phase == WidgetPhase.ready;
    Widget button(String key, String tip, IconData icon, VoidCallback? tap) =>
        IconButton(
          key: ValueKey<String>(key),
          tooltip: tip,
          onPressed: tap,
          style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
          icon: Icon(icon, color: colors.icon),
        );
    return SessionHeader(
      sessionTitle: 'Склад',
      persona: ready ? Personas.sado : null,
      cube: session.busy
          ? const StatusCube(state: CubeState.working, size: 14)
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (ready)
            button(
              'widget-new',
              'Новый чат',
              Icons.add_comment_outlined,
              session.busy ? null : session.newChat,
            ),
          button('widget-close', 'Закрыть', Icons.close_rounded, session.close),
        ],
      ),
    );
  }
}
