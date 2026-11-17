import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/assistant_theme.dart';
import '../app/layout.dart';
import '../app/widgets/action_card_view.dart';
import '../app/widgets/warehouse_card_view.dart';
import '../core/chats/chat_models.dart';
import '../core/models/assistant_types.dart';
import '../core/personas/persona.dart';
import 'widget_session.dart';

/// Веб-помощник склада: компактный чат по ADR-027 (шкала 16/14/13) —
/// заголовок «Связной», лента, поле ввода и микрофон (только в оболочке
/// Android). Без `package:web`: тесты виджетов идут на VM.
final class WidgetApp extends StatelessWidget {
  const WidgetApp({super.key, required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? _) => MaterialApp(
          title: 'Связной',
          debugShowCheckedModeBanner: false,
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
  final TextEditingController _input = TextEditingController();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
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
            Divider(height: 1, color: colors.divider),
            Expanded(child: _body(context)),
            if (_session.phase == WidgetPhase.ready) _composer(context),
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
      final examples = _session.examples;
      return note(
        examples.isEmpty
            ? 'Спросите склад: где лежит артикул, сколько осталось, что '
                'пришло сегодня.'
            : 'Спросите склад, например: '
                '${examples.map((String e) => '«$e»').join(', ')}.',
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageH,
        AppSpace.s,
        AppSpace.pageH,
        AppSpace.m,
      ),
      itemCount: messages.length + (_session.busy ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index == messages.length) {
          return Padding(
            padding: const EdgeInsets.only(top: AppSpace.toReply),
            child: Text(
              'Связной думает…',
              style: text.bodySmall,
            ),
          );
        }
        final message = messages[index];
        final previous = index == 0 ? null : messages[index - 1];
        final gap = previous == null
            ? 0.0
            : message.fromUser
                ? AppSpace.toUser
                : AppSpace.toReply;
        return Padding(
          padding: EdgeInsets.only(top: gap),
          child: message.fromUser
              ? _UserBubble(message: message)
              : _reply(context, message),
        );
      },
    );
  }

  Widget _reply(BuildContext context, ChatMessage message) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final card = message.card;
    final warehouse = message.warehouse;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SelectableText(
          message.text,
          style: text.bodyLarge?.copyWith(
            color: message.status == AssistantStatus.failed
                ? colors.danger
                : colors.text,
          ),
        ),
        if (warehouse != null) ...<Widget>[
          const SizedBox(height: AppSpace.textToCard),
          WarehouseCardView(
            card: warehouse,
            showSay: false,
            onOpen: _session.openWarehouse,
          ),
        ],
        if (card != null) ...<Widget>[
          const SizedBox(height: AppSpace.textToCard),
          ActionCardView(
            card: card,
            busy: _session.busy,
            onConfirm: () => unawaited(_session.answerCard(card, apply: true)),
            onCancel: () => unawaited(_session.answerCard(card, apply: false)),
            onSettle: () => unawaited(
              _session.settleCard(card, personaId: message.personaId),
            ),
          ),
        ],
      ],
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final voice = _session.voice;
    final hint = _session.listening
        ? (_session.partial.isEmpty ? 'Слушаю…' : _session.partial)
        : _session.voiceNote;
    return Container(
      color: colors.workspace,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.s,
        AppSpace.xs,
        AppSpace.s,
        AppSpace.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xxs,
                0,
                AppSpace.xxs,
                AppSpace.xs,
              ),
              child: Text(
                hint,
                key: const ValueKey<String>('voice-note'),
                style: text.bodySmall,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('widget-input'),
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 500,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  // Enter не снимает фокус: следующий вопрос печатается
                  // сразу, без щелчка по полю.
                  onEditingComplete: () {},
                  style: text.bodyLarge,
                  decoration: const InputDecoration(
                    hintText: 'Спросите склад…',
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
              if (voice.showButton)
                IconButton(
                  key: const ValueKey<String>('widget-mic'),
                  tooltip: _session.listening ? 'Остановить' : 'Сказать',
                  onPressed: _session.busy ? null : _session.startVoice,
                  icon: Icon(
                    _session.listening ? Icons.stop_rounded : Icons.mic_none,
                    color: _session.listening ? colors.accent : colors.icon,
                  ),
                ),
              IconButton(
                key: const ValueKey<String>('widget-send'),
                tooltip: 'Отправить',
                onPressed: _session.busy ? null : _submit,
                icon: Icon(Icons.arrow_upward_rounded, color: colors.icon),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _Header extends StatelessWidget {
  const _Header({required this.session});

  final WidgetSession session;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final (accent, background) = PersonaColors.of(Personas.sado, context);
    final who = session.who;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.m,
        AppSpace.xs,
        AppSpace.xxs,
        AppSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 14,
            backgroundColor: background,
            child: Text(
              'С',
              style: text.labelSmall?.copyWith(color: accent),
            ),
          ),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Связной',
                  style: text.titleMedium?.copyWith(color: colors.textStrong),
                ),
                if (who.isNotEmpty)
                  Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
              ],
            ),
          ),
          if (session.phase == WidgetPhase.ready)
            IconButton(
              key: const ValueKey<String>('widget-new'),
              tooltip: 'Новый чат',
              onPressed: session.busy ? null : session.newChat,
              icon: Icon(Icons.add_comment_outlined, color: colors.icon),
            ),
          IconButton(
            key: const ValueKey<String>('widget-close'),
            tooltip: 'Закрыть',
            onPressed: session.close,
            icon: Icon(Icons.close_rounded, color: colors.icon),
          ),
        ],
      ),
    );
  }
}

final class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.bubble,
            borderRadius: BorderRadius.circular(AppRadius.bubble),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s,
              vertical: AppSpace.xs,
            ),
            child: SelectableText(
              message.text,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: colors.text),
            ),
          ),
        ),
      ),
    );
  }
}
