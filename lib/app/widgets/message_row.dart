/// Строка ленты чата и её части (ADR-027): общие у ленты приложения и у
/// веб-виджета. Вложения сюда приходят готовым виджетом — файл не тянет
/// `dart:io` и выбор файлов.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/chats/chat_models.dart';
import '../../core/models/assistant_types.dart';
import '../../core/models/task.dart';
import '../../core/personas/persona_cast.dart';
import '../../core/scenario/command_spans.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import 'chat_feed_rhythm.dart';
import 'command_highlight.dart';
import 'message_copy_button.dart';
import 'persona_mark.dart';
import 'task_tile.dart';
import 'whole_word_text.dart';

/// Метка времени над группой сообщений: «Сегодня, 14:05» по центру,
/// без линий (ADR-027). Появляется при смене дня или после паузы больше
/// 15 минут.
final class ChatGroupTime extends StatelessWidget {
  const ChatGroupTime({super.key, required this.label, required this.first});

  final String label;

  /// Самая верхняя метка ленты: сверху отступ меньше.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: first ? AppSpace.xs : AppSpace.timeLabel,
        bottom: AppSpace.timeLabel,
      ),
      child: Center(
        child: WholeWordText(
          label,
          textAlign: TextAlign.center,
          style: metaStyle(context).copyWith(color: context.colors.muted),
        ),
      ),
    );
  }
}

/// Ссылка на другой чат под сообщением: текстовая кнопка цветом акцента
/// со стрелкой, без рамки (ADR-027). Текст переносится: при узком экране
/// и крупном шрифте подпись не обрезается.
final class ChatLinkChip extends StatelessWidget {
  const ChatLinkChip({
    super.key,
    required this.label,
    required this.origin,
    required this.onTap,
  });

  final String label;

  /// Ссылка назад, в чат, где создана задача (иначе — в чат задачи).
  final bool origin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.accent;
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.minTap),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (origin) ...<Widget>[
                  Icon(Icons.arrow_back, size: 18, color: accent),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: WholeWordText(
                    label,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium!
                        .copyWith(color: accent, fontWeight: FontWeight.w500),
                  ),
                ),
                if (!origin) ...<Widget>[
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_forward, size: 18, color: accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Абзацы ответа: «\n\n» — промежуток [AppSpace.paragraph] вместо пустой
/// строки, «\n» остаётся переносом. Текст тот же — выделяется и
/// копируется целиком.
TextSpan _paragraphs(String text, TextStyle style) {
  final parts = text.split('\n\n');
  return TextSpan(
    style: style,
    children: <InlineSpan>[
      TextSpan(text: parts.first),
      for (final part in parts.skip(1)) ...<InlineSpan>[
        const TextSpan(text: '\n'),
        // Пустая строка высотой с промежуток абзацев.
        const TextSpan(
          text: '\n',
          style: TextStyle(fontSize: AppSpace.paragraph, height: 1),
        ),
        TextSpan(text: part),
      ],
    ],
  );
}

/// Строка ленты: пузырь пользователя или ответ помощника с именем,
/// пометкой «Ошибка»/«Уточните», карточкой, задачей и ссылкой под ним.
final class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.cast,
    required this.message,
    required this.now,
    required this.showTime,
    required this.onOpenTask,
    required this.onToggleDone,
    this.showAuthor = true,
    this.topGap = 0,
    this.thinking = false,
    this.reduceMotion = false,
    this.task,
    this.highlighted = false,
    this.selectedId,
    this.checklist,
    this.linkLabel,
    this.linkKey,
    this.onOpenLink,
    this.attachmentsView,
    this.commandSpans = const <CommandSpan>[],
    this.selectable = true,
  });

  /// Свой `SelectableText` у каждого сообщения (приложение). `false` — простой
  /// текст: выделяет общий `SelectionArea` ленты (веб-помощник, ADR-042).
  final bool selectable;

  final ChatMessage message;

  /// Распознанные части команды пользователя (ADR-021); в ленте они —
  /// обычный текст (ADR-027).
  final List<CommandSpan> commandSpans;

  /// Превью вложений над текстом (ADR-019). Строит вызывающий: так строка
  /// не тянет `dart:io` и годится веб-виджету, где вложений нет.
  final Widget? attachmentsView;

  /// Состав помощников: старые ответы `rio`/`noda` подписаны текущими
  /// именами.
  final PersonaCast cast;

  /// Ссылка на другой чат под сообщением: подпись, ключ и действие.
  final String? linkLabel;
  final Key? linkKey;
  final VoidCallback? onOpenLink;

  /// Карточка массовой команды под текстом ответа.
  final Widget? checklist;
  final Task? task;
  final DateTime now;
  final bool showTime;

  /// Имя помощника над ответом: только при смене автора или после паузы.
  final bool showAuthor;

  /// Промежуток над сообщением — ритм ленты ([AppSpace]).
  final double topGap;

  /// Ответ ещё готовится: строка приглушённым текстом.
  final bool thinking;
  final bool reduceMotion;
  final bool highlighted;
  final String? selectedId;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;

  /// Время сообщения — в меню выделения текста («Отправлено в 14:05»).
  Widget _menu(BuildContext context, EditableTextState state) {
    final time = chatTimeLabel(message.timestamp);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: <ContextMenuButtonItem>[
        ...state.contextMenuButtonItems,
        ContextMenuButtonItem(
          label: message.fromUser ? 'Отправлено в $time' : 'Ответ в $time',
          onPressed: () => state.hideToolbar(),
        ),
      ],
    );
  }

  Widget _text(BuildContext context) {
    final fromUser = message.fromUser;
    // Тире не начинает строку (длина та же — отметки команд на месте).
    final text = bindDashes(message.text);
    final body = Theme.of(context).textTheme.bodyLarge!;
    if (thinking) {
      return Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodyMedium!
            .copyWith(color: context.colors.muted),
      );
    }
    if (!selectable) {
      if (fromUser && commandSpans.isNotEmpty) {
        return Text.rich(
          highlightedCommand(
            text,
            CommandSpans.normalize(commandSpans, text.length),
            body.copyWith(color: context.colors.textStrong),
            colors: context.colors,
            mode: CommandSpanMode.plain,
          ),
        );
      }
      final plain = body.copyWith(
        color: fromUser ? context.colors.textStrong : context.colors.text,
      );
      return !fromUser && text.contains('\n\n')
          ? Text.rich(_paragraphs(text, plain))
          : Text(text, style: plain);
    }
    if (fromUser && commandSpans.isNotEmpty) {
      return SelectableText.rich(
        highlightedCommand(
          text,
          CommandSpans.normalize(commandSpans, text.length),
          body.copyWith(color: context.colors.textStrong),
          colors: context.colors,
          // В ленте команда — обычный текст (ADR-027).
          mode: CommandSpanMode.plain,
        ),
        contextMenuBuilder: _menu,
      );
    }
    final style = body.copyWith(
      color: fromUser ? context.colors.textStrong : context.colors.text,
    );
    if (!fromUser && text.contains('\n\n')) {
      return SelectableText.rich(
        _paragraphs(text, style),
        contextMenuBuilder: _menu,
      );
    }
    return SelectableText(
      text,
      style: style,
      contextMenuBuilder: _menu,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fromUser = message.fromUser;
    final status = message.status;
    final label = switch (status) {
      AssistantStatus.needsClarification => 'Уточните',
      AssistantStatus.failed => 'Ошибка',
      _ => null,
    };
    final labelColor = status == AssistantStatus.failed
        ? context.colors.danger
        : context.colors.warning;
    final current = task;
    final author = fromUser ? null : cast.find(message.personaId);
    final hasText = message.text.isNotEmpty || message.attachments.isEmpty;
    final Widget? textBlock;
    if (!hasText) {
      textBlock = null;
    } else if (fromUser) {
      // Пузырь: заливка без рамки и без «хвоста»; найденный поиском или
      // выбранный в истории — рамкой акцента.
      textBlock = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.colors.bubble,
          border: highlighted
              ? Border.all(color: context.colors.accent, width: 1.5)
              : null,
          borderRadius: BorderRadius.circular(AppRadius.bubble),
        ),
        child: _text(context),
      );
    } else if (highlighted) {
      // Найденный ответ — мягкой заливкой акцента, которая гаснет.
      textBlock = TweenAnimationBuilder<double>(
        key: ValueKey<String>('reply-hit-${message.id}'),
        tween: Tween<double>(begin: 1, end: reduceMotion ? 1 : 0),
        duration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 1200),
        curve: const Interval(.5, 1, curve: Curves.easeOut),
        builder: (BuildContext context, double t, Widget? child) =>
            DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.accent.withValues(alpha: .12 * t),
            borderRadius: BorderRadius.circular(AppRadius.inner),
          ),
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: _text(context),
        ),
      );
    } else {
      // Ответ — обычные абзацы: без фона, рамки, полосы и отступа.
      textBlock = _text(context);
    }
    final copyable = !thinking &&
        message.text.trim().isNotEmpty &&
        message.secureCard == null;
    final content = Column(
      crossAxisAlignment:
          fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (author != null && showAuthor)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.nameToText),
            child: Row(
              key: ValueKey<String>('author-name-${author.id}'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                PersonaDot(persona: author),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    author.russianName,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle(context).copyWith(
                      fontWeight: FontWeight.w600,
                      color: PersonaColors.of(author, context).$1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label,
              style: metaStyle(context).copyWith(color: labelColor),
            ),
          ),
        if (attachmentsView case final Widget view)
          Padding(
            padding: EdgeInsets.only(
              bottom: message.text.isEmpty ? 0 : 8,
            ),
            child: view,
          ),
        if (textBlock != null) textBlock,
        if (checklist != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.textToCard),
            child: checklist!,
          ),
        if (current != null)
          Container(
            key: ValueKey<String>('message-task-${current.id}'),
            margin: const EdgeInsets.only(top: AppSpace.textToCard),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: context.colors.raised,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: TaskTile(
                task: current,
                now: now,
                dense: true,
                highlightSelected: false,
                selected: current.id == selectedId,
                onTap: () => onOpenTask(current),
                onToggleDone: () => onToggleDone(current),
              ),
            ),
          ),
        if (linkLabel != null && onOpenLink != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ChatLinkChip(
              key: linkKey,
              label: linkLabel!,
              origin: linkKey == const Key('chat-origin-link'),
              onTap: onOpenLink!,
            ),
          ),
        // Под ответом — «Копировать» (как у чатов с ассистентом): весь текст
        // одним нажатием. Не у строки «думает» и не у карточки паролей.
        if (!fromUser && copyable)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xxs),
            child: Transform.translate(
              // Значок — вровень с текстом, а не с краем цели нажатия.
              offset: const Offset(-15, 0),
              child: MessageCopyButton(text: message.text),
            ),
          ),
        if (showTime)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xxs),
            child: Text(
              chatTimeLabel(message.timestamp),
              style:
                  metaNumStyle(context).copyWith(color: context.colors.muted),
            ),
          ),
      ],
    );
    // Ответ — колонкой чтения не шире 640 от левого края; пузырь — не
    // шире 78 % колонки и 460, у правого края.
    return Padding(
      padding: EdgeInsets.only(top: topGap),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final max = fromUser
              ? math.min(
                  constraints.maxWidth * AppSize.maxBubbleFactor,
                  AppSize.maxBubble,
                )
              : AppSize.maxReading;
          final Widget body = fromUser
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: max),
                      child: copyable
                          ? HoverCopy(text: message.text, child: content)
                          : content,
                    ),
                  ],
                )
              : content;
          final row = Align(
            alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
            child: fromUser
                ? body
                : ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: max),
                    child: body,
                  ),
          );
          // У ответа — ключ автора на всей строке, даже когда имя не
          // повторяется: по нему видно, чей это ответ.
          return author == null
              ? row
              : KeyedSubtree(
                  key: ValueKey<String>('message-author-${author.id}'),
                  child: row,
                );
        },
      ),
    );
  }
}

/// «14:05» — прежнее имя [chatTimeLabel].
String clockLabel(DateTime value) => chatTimeLabel(value);
