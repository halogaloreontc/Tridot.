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
      ActionCardState.sending => ('Отправляю на склад…', AssistantColors.muted),
      ActionCardState.applied => (plus('Выполнено'), AssistantColors.success),
      ActionCardState.cancelled => (
          'Отменено — ничего не изменено',
          AssistantColors.muted,
        ),
      ActionCardState.expired => (
          'Карточка устарела — нужна новая команда',
          AssistantColors.muted,
        ),
      ActionCardState.replaced => (
          'Заменена новой карточкой',
          AssistantColors.muted,
        ),
      ActionCardState.failed => (plus('Не выполнено'), AssistantColors.danger),
      ActionCardState.unknown => (
          'Итог неизвестен — «Проверить» спросит склад',
          AssistantColors.warning,
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
      padding: const EdgeInsets.only(top: 8),
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Material(
          color: AssistantColors.raised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color:
                  pending ? AssistantColors.border : AssistantColors.borderSoft,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(
                  children: <Widget>[
                    Icon(
                      card.kind == ActionKind.move
                          ? Icons.swap_horiz
                          : Icons.fact_check_outlined,
                      size: 18,
                      color: AssistantColors.textStrong,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: WholeWordText(
                        _title,
                        key: const Key('action-title'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                    ),
                    if (pending)
                      Text(
                        'до ${_time(card.deadline)}',
                        key: const Key('action-until'),
                        style: metaTextStyle,
                      ),
                  ],
                ),
              ),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // Колонка подписей — по самой длинной подписи при нынешнем
                  // шрифте (не уже 76), но не шире 40 % строки; не влезает —
                  // подпись над значением: «Откуда» не рвётся (ADR-021).
                  final row = constraints.maxWidth - 28;
                  var longest = 0.0;
                  for (final line in card.lines) {
                    longest = math.max(
                      longest,
                      lineWidth(
                        context,
                        ActionCardView.labelOf(line.label),
                        style: metaTextStyle,
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
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: status == null
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton.icon(
                            key: const Key('action-confirm'),
                            onPressed:
                                enabled ? () => _press(widget.onConfirm) : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: AssistantColors.textStrong,
                              foregroundColor: AssistantColors.workspace,
                              disabledBackgroundColor: AssistantColors.bubble,
                              disabledForegroundColor: AssistantColors.muted,
                              minimumSize: const Size(0, 40),
                            ),
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('Подтвердить'),
                          ),
                          OutlinedButton(
                            key: const Key('action-cancel'),
                            onPressed:
                                enabled ? () => _press(widget.onCancel) : null,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AssistantColors.text,
                              side: const BorderSide(
                                color: AssistantColors.border,
                              ),
                              minimumSize: const Size(0, 40),
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
                            child: Text(
                              status.$1,
                              key: const Key('action-result'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: status.$2),
                            ),
                          ),
                          if (card.canSettle)
                            OutlinedButton(
                              key: const Key('action-settle'),
                              onPressed: widget.busy ? null : widget.onSettle,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AssistantColors.text,
                                side: const BorderSide(
                                  color: AssistantColors.border,
                                ),
                                minimumSize: const Size(0, 40),
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

  /// Строка карточки: подпись в колонке шириной [column] слева от
  /// значения, `null` — подпись над значением (узко и крупный шрифт).
  Widget _line(ActionCardLine line, double? column) {
    final note = ActionCardView.noteOf(line.note);
    final label = WholeWordText(
      ActionCardView.labelOf(line.label),
      style: metaTextStyle,
    );
    final value = Text(
      // Второй раз чистим: значение — одна строка без
      // управляющих знаков, что бы ни пришло.
      ActionCard.cardText(line.value),
      key: ValueKey<String>('action-value-${line.label}'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        color: AssistantColors.text,
      ),
    );
    return Padding(
      key: ValueKey<String>('action-line-${line.label}'),
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 3),
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
        padding: const EdgeInsets.fromLTRB(14, 3, 14, 0),
        child: _warningText(text, key),
      );

  Widget _warningText(String text, Key key) => Row(
        key: key,
        children: <Widget>[
          const Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: AssistantColors.warning,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                color: AssistantColors.warning,
              ),
            ),
          ),
        ],
      );
}
