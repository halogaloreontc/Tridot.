import 'package:flutter/material.dart';

import '../../core/models/bulk.dart';
import '../../core/replies/reply_template.dart';
import '../assistant_theme.dart';

/// Карточка массовой команды под ответом помощника: цель («→ сб, 7
/// ноября»), галочка у каждой задачи, «Выбрать все / Снять все», кнопка
/// «Перенести (N)» / «Отметить (N)» с живым числом и «Отмена».
///
/// Галочки — не сообщения: вопрос продолжает ждать ответа, и «да» в чате
/// применит изменение к отмеченным задачам. После ответа карточка только
/// показывает итог («Перенесено 4 из 5») и, пока можно, «Отменить».
/// Состояние — в самом [checklist]; родитель перерисовывает карточку после
/// каждого вызова.
final class BulkChecklistCard extends StatelessWidget {
  const BulkChecklistCard({
    super.key,
    required this.checklist,
    required this.onToggle,
    required this.onSetAll,
    required this.onApply,
    required this.onCancel,
    required this.onUndo,
    this.busy = false,
    this.viewportHeight,
  });

  final BulkChecklist checklist;
  final void Function(String taskId, bool checked) onToggle;
  final ValueChanged<bool> onSetAll;
  final VoidCallback onApply;
  final VoidCallback onCancel;
  final VoidCallback onUndo;

  /// Ответ уже готовится: кнопки не нажимаются второй раз.
  final bool busy;

  /// Высота видимой части чата, в котором лежит карточка. По ней, а не по
  /// высоте экрана, считается высота списка: при крупном шрифте на узком
  /// экране чату остаётся мало места.
  final double? viewportHeight;

  /// Высота списка, после которой он прокручивается внутри карточки.
  static const double listMaxHeight = 280;

  /// Меньше этого внутренняя прокрутка не нужна: список показывается
  /// целиком и прокручивается вместе с чатом.
  static const double listMinHeight = 160;

  /// Высота списка с собственной прокруткой или `null` — список целиком.
  /// Список занимает не больше 45 % видимой части чата: остальное место
  /// ловит прокрутку чата, и кнопки под списком всегда можно докрутить.
  /// Если чату совсем тесно (крупный шрифт, узкий экран, открыта
  /// клавиатура), вложенной прокрутки нет вовсе.
  @visibleForTesting
  static double? listHeightFor(double viewport) {
    final height = viewport * .45;
    if (height < listMinHeight) return null;
    return height > listMaxHeight ? listMaxHeight : height;
  }

  double? _listHeight(BuildContext context) =>
      listHeightFor(viewportHeight ?? MediaQuery.sizeOf(context).height);

  static String _tasks(int n) => switch (ReplyTemplate.pluralIndex(n)) {
        0 => 'задача',
        1 => 'задачи',
        _ => 'задач',
      };

  String get _verb => switch (checklist.action) {
        BulkAction.complete => 'Отметить',
        BulkAction.reschedule when checklist.shift != null => 'Сдвинуть',
        BulkAction.reschedule => 'Перенести',
      };

  String get _done => switch (checklist.action) {
        BulkAction.complete => 'Отмечено',
        BulkAction.reschedule when checklist.shift != null => 'Сдвинуто',
        BulkAction.reschedule => 'Перенесено',
      };

  String get _target {
    final label = checklist.targetLabel;
    return switch (checklist.action) {
      BulkAction.complete => 'Отметить выполненными',
      BulkAction.reschedule => '→ ${label ?? 'новый срок'}',
    };
  }

  String? get _result => switch (checklist.state) {
        BulkChecklistState.pending => null,
        BulkChecklistState.applied =>
          '$_done ${checklist.applied} из ${checklist.items.length}',
        BulkChecklistState.undone => 'Отменено — всё вернулось как было',
        BulkChecklistState.cancelled => 'Ничего не изменено',
        BulkChecklistState.expired => 'Вопрос устарел — повторите команду',
      };

  @override
  Widget build(BuildContext context) {
    final pending = checklist.isPending;
    final checked = checklist.checkedCount;
    final total = checklist.items.length;
    final allChecked = checked == total;
    final result = _result;
    // Material, а не DecoratedBox: строкам списка нужен свой фон для
    // отклика на нажатие.
    return Padding(
      key: ValueKey<String>('bulk-card-${checklist.id}'),
      padding: EdgeInsets.zero,
      // Своя группа обхода: Tab идёт по карточке подряд — «Выбрать все»,
      // строки, «Перенести», «Отмена» — и не прыгает в панель задач рядом.
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Material(
          color: context.colors.raised,
          clipBehavior: Clip.antiAlias,
          // Карточка заливкой без рамки (ADR-027).
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      _target,
                      key: const Key('bulk-target'),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium!
                          .copyWith(color: context.colors.textStrong),
                    ),
                    Text(
                      pending
                          ? 'отмечено $checked из $total'
                          : '$total ${_tasks(total)} в списке',
                      key: const Key('bulk-counter'),
                      style: metaStyle(context),
                    ),
                  ],
                ),
              ),
              if (pending && total > 1)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextButton(
                      key: const Key('bulk-select-all'),
                      onPressed: busy ? null : () => onSetAll(!allChecked),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(allChecked ? 'Снять все' : 'Выбрать все'),
                    ),
                  ),
                ),
              // Строки создаются лениво и встают в порядок обхода позже
              // кнопок: своя группа держит их между «Выбрать все» и
              // «Перенести».
              FocusTraversalGroup(
                child: _list(context, enabled: pending && !busy),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                // Основное действие — во всю ширину акцентом, отмена —
                // текстовой кнопкой (ADR-027).
                child: result == null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          FilledButton(
                            key: const Key('bulk-apply'),
                            onPressed: busy || checked == 0 ? null : onApply,
                            style: FilledButton.styleFrom(
                              disabledBackgroundColor: context.colors.bubble,
                              disabledForegroundColor: context.colors.muted,
                              minimumSize: const Size.fromHeight(50),
                            ),
                            child: Text('$_verb ($checked)'),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            key: const Key('bulk-cancel'),
                            onPressed: busy ? null : onCancel,
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
                            child: Text(
                              result,
                              key: const Key('bulk-result'),
                              style: TextStyle(
                                fontSize: 15,
                                color: checklist.state ==
                                        BulkChecklistState.applied
                                    ? context.colors.success
                                    : context.colors.muted,
                              ),
                            ),
                          ),
                          if (checklist.canUndo &&
                              checklist.state == BulkChecklistState.applied)
                            TextButton(
                              key: const Key('bulk-undo'),
                              onPressed: busy ? null : onUndo,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                              ),
                              child: const Text('Отменить'),
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

  Widget _list(BuildContext context, {required bool enabled}) {
    final height = _listHeight(context);
    final list = ListView.builder(
      key: const Key('bulk-list'),
      shrinkWrap: true,
      primary: false,
      physics: height == null ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: checklist.items.length,
      itemBuilder: (BuildContext context, int index) =>
          _item(context, checklist.items[index], enabled: enabled),
    );
    if (height == null) return list;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height),
      child: Scrollbar(child: list),
    );
  }

  Widget _item(BuildContext context, BulkItem item, {required bool enabled}) {
    final due = item.dueLabel;
    return CheckboxListTile(
      key: ValueKey<String>('bulk-item-${item.taskId}'),
      value: item.checked,
      onChanged: enabled
          ? (bool? value) => onToggle(item.taskId, value ?? false)
          : null,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      visualDensity: VisualDensity.compact,
      activeColor: context.colors.textStrong,
      checkColor: context.colors.workspace,
      side: BorderSide(color: context.colors.muted, width: 1.5),
      title: Text(
        item.title,
        style: TextStyle(
          fontSize: 15,
          color: item.checked || !enabled
              ? context.colors.text
              : context.colors.muted,
        ),
      ),
      subtitle: Text(
        due ?? 'без срока',
        style: metaStyle(context),
      ),
    );
  }
}
