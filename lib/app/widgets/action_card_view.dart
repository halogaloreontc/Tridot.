import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/action_card.dart';
import '../assistant_theme.dart';
import 'whole_word_text.dart';

/// Карточка действия с записью под ответом помощника (ADR-013): что
/// изменится, от чьего имени, до какого времени, кнопки «Подтвердить» и
/// «Отмена». Запись уходит только по «Подтвердить»; кнопки гаснут при
/// первом нажатии и когда выходит срок карточки. После ответа карточка
/// показывает итог, а при неизвестном итоге — «Проверить» (спросить склад,
/// чем кончилось; запись не повторяется).
///
/// Подписи («Что», «Откуда») — здесь, в виджете; значения — отдельными
/// строками текста без разметки, в одну строку с многоточием: название
/// товара с переводом строки или знаком направления текста не может
/// выдать себя за другую строку карточки.
final class ActionCardView extends StatefulWidget {
  const ActionCardView({
    super.key,
    required this.card,
    required this.onConfirm,
    required this.onCancel,
    required this.onSettle,
    this.busy = false,
    this.now = DateTime.now,
  });

  final ActionCard card;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onSettle;

  /// Ответ уже готовится: кнопки не нажимаются.
  final bool busy;

  /// Часы для срока карточки (в тестах — подделка).
  final DateTime Function() now;

  /// Подпись строки по коду.
  static String labelOf(String code) => switch (code) {
        'what' => 'Что',
        'sku' => 'Артикул',
        'qty' => 'Сколько',
        'from' => 'Откуда',
        'to' => 'Куда',
        'entry' => 'Приход',
        'content' => 'Состав',
        'sv' => 'SV',
        'odin_c' => '1С',
        'stage' => 'Итог',
        'who' => 'От имени',
        _ => code,
      };

  /// Пометка по коду.
  static String noteOf(String code) => switch (code) {
        'to_empty' => 'ячейка пустая — точно этот адрес?',
        'unplaced' => 'есть товар без ячейки',
        _ => '',
      };

  @override
  State<ActionCardView> createState() => _ActionCardViewState();
}

class _ActionCardViewState extends State<ActionCardView> {
  Timer? _timer;

  /// Кнопку уже нажали: до ответа она не нажимается второй раз.
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ActionCardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.card, widget.card)) _pressed = false;
    if (!widget.card.isPending) _pressed = false;
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    final card = widget.card;
    if (!card.isPending) return;
    final left = card.deadline.difference(widget.now());
    if (left <= Duration.zero) {
      card.expireIfDue(widget.now());
      return;
    }
    _timer = Timer(left, () {
      if (!mounted) return;
      setState(() => widget.card.expireIfDue(widget.now()));
    });
  }

  void _press(VoidCallback action) {
    if (_pressed) return;
    setState(() => _pressed = true);
    action();
  }

  String get _title => switch (widget.card.kind) {
        ActionKind.move => 'Перемещение',
        ActionKind.post => 'Отметка проведения',
      };

  (String, Color)? get _status {
    final card = widget.card;
    final result = card.result;
    String plus(String text) => result.isEmpty ? text : '$text: $result';
    return switch (card.state) {
      ActionCardState.pending => null,
      ActionCardState.sending => ('Отправляю на склад…', context.colors.muted),
      ActionCardState.applied => (plus('Выполнено'), context.colors.success),
      ActionCardState.cancelled => (
          'Отменено — ничего не изменено',
          context.colors.muted,
        ),
      ActionCardState.expired => (
          'Карточка устарела — нужна новая команда',
          context.colors.muted,
        ),
      ActionCardState.replaced => (
          'Заменена новой карточкой',
          context.colors.muted,
        ),
      ActionCardState.failed => (plus('Не выполнено'), context.colors.danger),
      ActionCardState.unknown => (
          'Итог неизвестен — «Проверить» спросит склад',
          context.colors.warning,
        ),
    };
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final pending = card.isPending;
    final enabled = pending && !widget.busy && !_pressed;
    final status = _status;
    return Padding(
      key: ValueKey<String>('action-card-${card.rid}'),
      padding: EdgeInsets.zero,
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        // Карточка заливкой без рамки (ADR-027).
        child: Material(
          color: context.colors.raised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: <Widget>[
                    Icon(
                      card.kind == ActionKind.move
                          ? Icons.swap_horiz
                          : Icons.fact_check_outlined,
                      size: 22,
                      color: context.colors.icon,
                    ),
                    const SizedBox(width: 10),
                    // Срок — под заголовком: рядом с ним крупное слово
                    // («Перемещение») на узком экране не помещается.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          WholeWordText(
                            _title,
                            key: const Key('action-title'),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium!
                                .copyWith(color: context.colors.textStrong),
                          ),
                          if (pending)
                            Text(
                              'до ${_time(card.deadline)}',
                              key: const Key('action-until'),
                              style: metaStyle(context)
                                  .copyWith(color: context.colors.muted),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // Колонка подписей — по самой длинной подписи при нынешнем
                  // шрифте (не уже 76), но не шире 40 % строки; не влезает —
                  // подпись над значением: «Откуда» не рвётся (ADR-021).
                  final row = constraints.maxWidth - 32;
                  var longest = 0.0;
                  for (final line in card.lines) {
                    longest = math.max(
                      longest,
                      lineWidth(
                        context,
                        ActionCardView.labelOf(line.label),
                        style: _labelStyle(context),
                      ),
                    );
                  }
                  final column = math.max(76.0, longest + 8);
                  final stacked = column > row * .4;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final line in card.lines)
                        _line(line, stacked ? null : column),
                    ],
                  );
                },
              ),
              for (final warn in card.warn)
                if (ActionCardView.noteOf(warn) case final String note
                    when note.isNotEmpty && warn != 'to_empty')
                  _warning(note, ValueKey<String>('action-warn-$warn')),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                // Основное действие — во всю ширину акцентом, отмена —
                // текстовой кнопкой.
                child: status == null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          FilledButton.icon(
                            key: const Key('action-confirm'),
                            onPressed:
                                enabled ? () => _press(widget.onConfirm) : null,
                            style: FilledButton.styleFrom(
                              disabledBackgroundColor: context.colors.bubble,
                              disabledForegroundColor: context.colors.muted,
                              minimumSize: const Size.fromHeight(50),
                            ),
                            icon: const Icon(Icons.check, size: 20),
                            label: const WholeWordText('Подтвердить'),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            key: const Key('action-cancel'),
                            onPressed:
                                enabled ? () => _press(widget.onCancel) : null,
                            style: TextButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            child: const Text('Отмена'),
                          ),
                        ],
                      )
                    : Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Semantics(
                            liveRegion: true,
                            child: WholeWordText(
                              status.$1,
                              key: const Key('action-result'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15, color: status.$2),
                            ),
                          ),
                          if (card.canSettle)
                            TextButton(
                              key: const Key('action-settle'),
                              onPressed: widget.busy ? null : widget.onSettle,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                              ),
                              child: const Text('Проверить'),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Подпись строки — 15 вторичным (ADR-027).
  static TextStyle _labelStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium!
      .copyWith(color: context.colors.muted);

  /// Строка карточки: подпись в колонке шириной [column] слева от
  /// значения, `null` — подпись над значением (узко и крупный шрифт).
  Widget _line(ActionCardLine line, double? column) {
    final note = ActionCardView.noteOf(line.note);
    final label = WholeWordText(
      ActionCardView.labelOf(line.label),
      style: _labelStyle(context),
    );
    final value = Text(
      // Второй раз чистим: значение — одна строка без
      // управляющих знаков, что бы ни пришло.
      ActionCard.cardText(line.value),
      key: ValueKey<String>('action-value-${line.label}'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 17,
        color: context.colors.textStrong,
      ),
    );
    return Padding(
      key: ValueKey<String>('action-line-${line.label}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (column == null) ...<Widget>[
            label,
            value,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: column, child: label),
                Expanded(child: value),
              ],
            ),
          if (note.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: column ?? 0),
              child: _warningText(
                note,
                ValueKey<String>('action-note-${line.label}'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _warning(String text, Key key) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: _warningText(text, key),
      );

  Widget _warningText(String text, Key key) => Row(
        key: key,
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: context.colors.warning,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: context.colors.warning,
              ),
            ),
          ),
        ],
      );
}
