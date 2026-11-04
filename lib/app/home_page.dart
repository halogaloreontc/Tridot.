import 'package:flutter/material.dart';

import '../core/formatting/due_format.dart';
import '../core/models/assistant_types.dart';
import '../core/models/task.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';

/// Ширина, начиная с которой чат и задачи показываются рядом.
const double wideLayoutBreakpoint = 900;

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.assistant,
    required this.tasks,
    this.clock = const SystemClock(),
  });

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final List<_ChatMessage> _messages = <_ChatMessage>[
    const _ChatMessage(
      text: 'Привет! Я веду ваши задачи без интернета. Напишите, что сделать, '
          'а название задачи возьмите в кавычки, например:',
      example: AssistantController.exampleCommand,
      fromUser: false,
    ),
  ];

  List<Task> _tasks = <Task>[];
  Object? _loadError;
  bool _loading = true;
  bool _sending = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _refreshTasks();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Task? get _selectedTask {
    final id = widget.assistant.selectedTaskId;
    if (id == null) return null;
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  Future<void> _refreshTasks() async {
    try {
      final tasks = await widget.tasks.listActive();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loadError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _messages.add(_ChatMessage(text: text, fromUser: true));
      if (preset == null) _input.clear();
    });
    _scrollToEnd();
    final response = await widget.assistant.handle(text);
    if (!mounted) return;
    setState(() {
      _messages.add(
        _ChatMessage(
          text: response.message,
          fromUser: false,
          status: response.status,
          task: response.task,
        ),
      );
      _sending = false;
    });
    _scrollToEnd();
    _inputFocus.requestFocus();
    await _refreshTasks();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// Подставляет шаблон в поле ввода; `|` — место курсора.
  void _insertTemplate(String template) {
    final cursor = template.indexOf('|');
    final text = template.replaceFirst('|', '');
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: cursor < 0 ? text.length : cursor,
      ),
    );
    _inputFocus.requestFocus();
  }

  void _toggleSelection(Task task, {required bool wide}) {
    final selected = widget.assistant.selectedTaskId == task.id;
    setState(() {
      if (selected) {
        widget.assistant.clearSelection();
      } else {
        widget.assistant.selectTask(task.id);
      }
    });
    if (selected || wide) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Выбрана «${task.title}»'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'В чат',
          onPressed: () => setState(() => _tab = 0),
        ),
      ),
    );
  }

  Future<void> _complete(Task task) async {
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    try {
      await widget.tasks.complete(task.id);
      widget.assistant.forgetTask(task.id);
      messenger.showSnackBar(
        SnackBar(content: Text('«${task.title}» — готово')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось завершить задачу: $error')),
      );
    }
    await _refreshTasks();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final wide = constraints.maxWidth >= wideLayoutBreakpoint;
        final chat = _ChatPane(
          messages: _messages,
          scroll: _scroll,
          input: _input,
          inputFocus: _inputFocus,
          sending: _sending,
          selectedTask: _selectedTask,
          now: widget.clock.now(),
          onSend: _send,
          onTemplate: _insertTemplate,
          onClearSelection: () =>
              setState(() => widget.assistant.clearSelection()),
        );
        final tasks = _TasksPane(
          tasks: _tasks,
          loading: _loading,
          error: _loadError,
          selectedId: _selectedTask?.id,
          now: widget.clock.now(),
          showHeader: wide,
          onRetry: _refreshTasks,
          onSelect: (Task task) => _toggleSelection(task, wide: wide),
          onComplete: _complete,
        );

        if (wide) {
          return Scaffold(
            appBar: AppBar(title: const Text('Помощник')),
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  Expanded(child: chat),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 380, child: tasks),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(_tab == 0 ? 'Помощник' : 'Задачи'),
          ),
          body: SafeArea(
            child: IndexedStack(index: _tab, children: <Widget>[chat, tasks]),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (int index) => setState(() => _tab = index),
            destinations: <Widget>[
              const NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Чат',
              ),
              NavigationDestination(
                icon: Badge(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  isLabelVisible: _tasks.isNotEmpty,
                  label: Text('${_tasks.length}'),
                  child: const Icon(Icons.checklist_outlined),
                ),
                selectedIcon: Badge(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  isLabelVisible: _tasks.isNotEmpty,
                  label: Text('${_tasks.length}'),
                  child: const Icon(Icons.checklist),
                ),
                label: 'Задачи',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ чат

final class _ChatMessage {
  const _ChatMessage({
    required this.text,
    required this.fromUser,
    this.status,
    this.task,
    this.example,
  });

  final String text;
  final String? example;
  final bool fromUser;
  final AssistantStatus? status;
  final Task? task;
}

final class _ChatPane extends StatelessWidget {
  const _ChatPane({
    required this.messages,
    required this.scroll,
    required this.input,
    required this.inputFocus,
    required this.sending,
    required this.selectedTask,
    required this.now,
    required this.onSend,
    required this.onTemplate,
    required this.onClearSelection,
  });

  final List<_ChatMessage> messages;
  final ScrollController scroll;
  final TextEditingController input;
  final FocusNode inputFocus;
  final bool sending;
  final Task? selectedTask;
  final DateTime now;
  final Future<void> Function([String? preset]) onSend;
  final void Function(String template) onTemplate;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = selectedTask;
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: messages.length,
            itemBuilder: (BuildContext context, int index) => _Centered(
              child: _MessageBubble(message: messages[index], now: now),
            ),
          ),
        ),
        _Centered(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (selected != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InputChip(
                        key: const Key('selected-task-chip'),
                        avatar: Icon(
                          Icons.push_pin_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        label: Text(
                          'Работаю с «${selected.title}»',
                          overflow: TextOverflow.ellipsis,
                        ),
                        onDeleted: onClearSelection,
                        deleteButtonTooltipMessage: 'Снять выбор',
                      ),
                    ),
                  ),
                _Suggestions(
                  hasSelection: selected != null,
                  onSend: onSend,
                  onTemplate: onTemplate,
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const Key('chat-input'),
                        controller: input,
                        focusNode: inputFocus,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        textCapitalization: TextCapitalization.sentences,
                        onSubmitted: (_) => onSend(),
                        decoration: const InputDecoration(
                          hintText: 'Напишите, что сделать…',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('send'),
                      onPressed: sending ? null : () => onSend(),
                      icon: sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward),
                      tooltip: 'Отправить',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.hasSelection,
    required this.onSend,
    required this.onTemplate,
  });

  final bool hasSelection;
  final Future<void> Function([String? preset]) onSend;
  final void Function(String template) onTemplate;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      ActionChip(
        avatar: const Icon(Icons.add, size: 18),
        label: const Text('Новая задача'),
        onPressed: () => onTemplate('Добавь задачу «|» на завтра'),
      ),
      ActionChip(
        avatar: const Icon(Icons.checklist, size: 18),
        label: const Text('Мои задачи'),
        onPressed: () => onSend('Покажи задачи'),
      ),
      if (hasSelection) ...<Widget>[
        ActionChip(
          avatar: const Icon(Icons.event_outlined, size: 18),
          label: const Text('Перенести'),
          onPressed: () => onTemplate('Перенеси её на завтра в |'),
        ),
        ActionChip(
          avatar: const Icon(Icons.check, size: 18),
          label: const Text('Завершить'),
          onPressed: () => onSend('Заверши её'),
        ),
      ],
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final chip in chips)
            Padding(padding: const EdgeInsets.only(right: 8), child: chip),
        ],
      ),
    );
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.now});

  final _ChatMessage message;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fromUser = message.fromUser;
    final failed = message.status == AssistantStatus.failed;
    final background = fromUser
        ? scheme.primary
        : failed
            ? scheme.errorContainer
            : scheme.surfaceContainerHigh;
    final foreground = fromUser
        ? scheme.onPrimary
        : failed
            ? scheme.onErrorContainer
            : scheme.onSurface;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(fromUser ? 18 : 4),
      bottomRight: Radius.circular(fromUser ? 4 : 18),
    );
    final task = message.task;

    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 520)),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: background, borderRadius: radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (message.status == AssistantStatus.needsClarification)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Уточните',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
            Text(
              message.text,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
            ),
            if (message.example != null) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message.example!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
            if (task != null) ...<Widget>[
              const SizedBox(height: 8),
              _TaskSummary(task: task, now: now),
            ],
          ],
        ),
      ),
    );
  }
}

/// Мини-карточка задачи в ответе помощника.
final class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.task, required this.now});

  final Task task;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = task.status == TaskStatus.done;
    final due = task.dueAt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: done ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  task.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (due != null)
                  Text(
                    formatDue(due, task.duePrecision, now),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ограничивает ширину содержимого на широких экранах.
final class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: child,
      ),
    );
  }
}

// --------------------------------------------------------------- задачи

final class _TasksPane extends StatelessWidget {
  const _TasksPane({
    required this.tasks,
    required this.loading,
    required this.error,
    required this.selectedId,
    required this.now,
    required this.showHeader,
    required this.onRetry,
    required this.onSelect,
    required this.onComplete,
  });

  final List<Task> tasks;
  final bool loading;
  final Object? error;
  final String? selectedId;
  final DateTime now;
  final bool showHeader;
  final VoidCallback onRetry;
  final ValueChanged<Task> onSelect;
  final ValueChanged<Task> onComplete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      body = _Placeholder(
        icon: Icons.error_outline,
        title: 'Не удалось загрузить задачи',
        subtitle: '$error',
        action: FilledButton.tonal(
          onPressed: onRetry,
          child: const Text('Повторить'),
        ),
      );
    } else if (tasks.isEmpty) {
      body = const _Placeholder(
        icon: Icons.check_circle_outline,
        title: 'Задач пока нет',
        subtitle: 'Напишите в чате: Добавь задачу «Позвонить маме» на завтра',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: <Widget>[
          for (final (group, items) in groupTasks(tasks, now)) ...<Widget>[
            _GroupHeader(group: group, count: items.length),
            for (final task in items)
              _TaskTile(
                task: task,
                selected: task.id == selectedId,
                now: now,
                onSelect: () => onSelect(task),
                onComplete: () => onComplete(task),
              ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(
              'Задачи',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(child: body),
      ],
    );
  }
}

final class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.count});

  final TaskGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = group == TaskGroup.overdue
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        '${group.title} · $count',
        style: theme.textTheme.labelLarge?.copyWith(color: color),
      ),
    );
  }
}

final class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.selected,
    required this.now,
    required this.onSelect,
    required this.onComplete,
  });

  final Task task;
  final bool selected;
  final DateTime now;
  final VoidCallback onSelect;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final due = task.dueAt;
    final overdue = isOverdue(task, now);
    return ListTile(
      key: ValueKey<String>('task-${task.id}'),
      selected: selected,
      onTap: onSelect,
      contentPadding: const EdgeInsets.only(left: 4, right: 12),
      leading: IconButton(
        key: ValueKey<String>('complete-${task.id}'),
        tooltip: 'Отметить выполненной',
        icon: Icon(Icons.radio_button_unchecked, color: scheme.outline),
        onPressed: onComplete,
      ),
      title: Text(task.title, style: theme.textTheme.bodyLarge),
      subtitle: due == null
          ? null
          : Text(
              formatDue(due, task.duePrecision, now),
              style: theme.textTheme.bodySmall?.copyWith(
                color: overdue ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
      trailing: selected
          ? Tooltip(
              message: 'С этой задачей работает помощник',
              child: Icon(Icons.push_pin, size: 18, color: scheme.primary),
            )
          : null,
    );
  }
}

final class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
