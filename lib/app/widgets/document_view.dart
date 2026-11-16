import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import 'task_notes.dart';

/// Состояние сохранения документа.
enum DocumentSaveState {
  saved,
  dirty,
  saving,
  failed,

  /// Заметки сохранены, но пустое название — нет.
  titleRequired,
}

/// Документ задачи: название, проект и описание с простой разметкой.
/// Хозяин отвечает за загрузку, автосохранение и обработку ошибок.
final class DocumentView extends StatelessWidget {
  const DocumentView({
    super.key,
    required this.task,
    required this.now,
    required this.titleController,
    required this.projectController,
    required this.bodyController,
    required this.bodyFocus,
    required this.saveState,
    required this.savedAt,
    required this.onSaveNow,
    required this.onReopen,
    required this.onOpenTasks,
    this.topInset = 0,
    this.scrollController,
    this.onToggleItem,
  });

  final Task? task;
  final DateTime now;
  final TextEditingController titleController;
  final TextEditingController projectController;
  final TextEditingController bodyController;
  final FocusNode bodyFocus;
  final DocumentSaveState saveState;
  final DateTime? savedAt;
  final VoidCallback onSaveNow;
  final VoidCallback onReopen;
  final VoidCallback onOpenTasks;

  /// Добавка к отступу сверху (по умолчанию 0).
  final double topInset;

  /// Прокрутка документа.
  final ScrollController? scrollController;

  /// Отметить пункт чек-листа задачи; `null` — пункты только для показа.
  final ValueChanged<int>? onToggleItem;

  @override
  Widget build(BuildContext context) {
    final current = task;
    if (current == null) {
      return ListView(
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(20, 20 + topInset, 20, 24),
        children: <Widget>[
          Text('Задачи → Документ', style: metaStyle(context)),
          const SizedBox(height: 32),
          Icon(
            Icons.description_outlined,
            size: 32,
            color: context.colors.muted,
          ),
          const SizedBox(height: 12),
          const Text(
            'Документ открывается для выбранной задачи.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Выберите задачу в списке или создайте её командой в сессии.',
            textAlign: TextAlign.center,
            style: metaStyle(context),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: onOpenTasks,
              icon: const Icon(Icons.checklist),
              label: const Text('Открыть список задач'),
            ),
          ),
        ],
      );
    }

    final done = current.status == TaskStatus.done;
    final due = current.dueAt;
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(20, 20 + topInset, 20, 24),
      children: <Widget>[
        Text(
          [
            'Задачи',
            if (current.project != null) '#${current.project}',
            if (due != null) formatDue(due, current.duePrecision, now),
          ].join(' → '),
          style: metaStyle(context),
        ),
        if (done)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: context.colors.raised,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.check_circle,
                  size: 18,
                  color: context.colors.success,
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text('Задача выполнена')),
                TextButton(
                  onPressed: onReopen,
                  child: const Text('Вернуть в работу'),
                ),
              ],
            ),
          ),
        TextField(
          key: const Key('document-title'),
          controller: titleController,
          style: Theme.of(context).textTheme.titleLarge,
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            labelText: 'Название задачи',
            floatingLabelBehavior: FloatingLabelBehavior.never,
            contentPadding: EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        // Проект — первая метка задачи (ADR-018): очистка поля убирает
        // только её, остальные метки остаются.
        Tooltip(
          message: 'Проект — первая метка задачи. Очистка убирает только её',
          waitDuration: const Duration(milliseconds: 600),
          child: TextField(
            key: const Key('document-project'),
            controller: projectController,
            style: metaStyle(context).copyWith(color: context.colors.text),
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              prefixText: '#',
              labelText: 'Проект — первая метка задачи',
              floatingLabelBehavior: FloatingLabelBehavior.never,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        // Пункты и заметки, записанные из чата (ADR-033).
        TaskNotesSection(task: current, now: now, onToggleItem: onToggleItem),
        _FormattingToolbar(controller: bodyController, focus: bodyFocus),
        TextField(
          key: const Key('document-editor'),
          controller: bodyController,
          focusNode: bodyFocus,
          minLines: 8,
          maxLines: null,
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            labelText: 'Заметки, шаги, ссылки…',
            floatingLabelBehavior: FloatingLabelBehavior.never,
            contentPadding: EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _saveLabel(),
                key: const Key('document-save-status'),
                style: metaStyle(context).copyWith(
                  color: saveState == DocumentSaveState.failed ||
                          saveState == DocumentSaveState.titleRequired
                      ? context.colors.danger
                      : null,
                ),
              ),
            ),
            if (saveState == DocumentSaveState.dirty ||
                saveState == DocumentSaveState.failed)
              TextButton(
                key: const Key('document-save'),
                onPressed: onSaveNow,
                child: const Text('Сохранить'),
              ),
          ],
        ),
      ],
    );
  }

  String _saveLabel() => switch (saveState) {
        DocumentSaveState.saved => savedAt == null
            ? 'Сохранено на этом устройстве'
            : 'Сохранено · ${formatTime(savedAt!)}',
        DocumentSaveState.dirty => 'Есть несохранённые изменения',
        DocumentSaveState.saving => 'Сохраняю…',
        DocumentSaveState.failed => 'Не удалось сохранить',
        DocumentSaveState.titleRequired =>
          'Заметки сохранены · у задачи должно быть название',
      };
}

/// Простая разметка в тексте: заголовок, жирный, курсив, список, чекбокс.
final class _FormattingToolbar extends StatelessWidget {
  const _FormattingToolbar({required this.controller, required this.focus});

  final TextEditingController controller;
  final FocusNode focus;

  @override
  Widget build(BuildContext context) {
    final actions = <(String, IconData, VoidCallback)>[
      ('Заголовок', Icons.title, () => _prefixLine('# ')),
      ('Жирный', Icons.format_bold, () => _wrap('**')),
      ('Курсив', Icons.format_italic, () => _wrap('_')),
      ('Список', Icons.format_list_bulleted, () => _prefixLine('- ')),
      ('Чекбокс', Icons.check_box_outlined, () => _prefixLine('- [ ] ')),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.colors.raised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        children: <Widget>[
          for (final (label, icon, action) in actions)
            IconButton(
              key: Key('format-$label'),
              tooltip: label,
              onPressed: action,
              icon: Icon(icon, size: 18),
            ),
        ],
      ),
    );
  }

  TextSelection get _selection {
    final selection = controller.selection;
    return selection.isValid
        ? selection
        : TextSelection.collapsed(offset: controller.text.length);
  }

  /// Оборачивает выделение маркерами; без выделения ставит курсор внутрь.
  void _wrap(String marker) {
    final text = controller.text;
    final selection = _selection;
    final selected = text.substring(selection.start, selection.end);
    final replaced = '$marker$selected$marker';
    controller.value = TextEditingValue(
      text: text.replaceRange(selection.start, selection.end, replaced),
      selection: selected.isEmpty
          ? TextSelection.collapsed(offset: selection.start + marker.length)
          : TextSelection(
              baseOffset: selection.start,
              extentOffset: selection.start + replaced.length,
            ),
    );
    focus.requestFocus();
  }

  /// Ставит префикс в начало текущей строки (или убирает, если он уже есть).
  void _prefixLine(String prefix) {
    final text = controller.text;
    final selection = _selection;
    final lineStart = selection.start == 0
        ? 0
        : text.lastIndexOf('\n', selection.start - 1) + 1;
    final hasPrefix = text.startsWith(prefix, lineStart);
    final updated = hasPrefix
        ? text.replaceRange(lineStart, lineStart + prefix.length, '')
        : text.replaceRange(lineStart, lineStart, prefix);
    final shift = hasPrefix ? -prefix.length : prefix.length;
    final caret = (selection.end + shift).clamp(lineStart, updated.length);
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: caret),
    );
    focus.requestFocus();
  }
}
