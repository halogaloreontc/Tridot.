import 'package:flutter/material.dart';

import '../../core/models/task.dart';
import '../../core/storage/storage_info.dart';
import '../assistant_theme.dart';
import '../widgets/task_tile.dart';

/// Размер в байтах по-русски: «512 Б», «12,4 КБ», «3,0 МБ».
String formatBytes(int bytes) {
  const kilo = 1024;
  const mega = kilo * 1024;
  final value = bytes < 0 ? 0 : bytes;
  String oneDecimal(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
  if (value < kilo) return '$value Б';
  if (value < mega) {
    final kb = value / kilo;
    // 1023,96 КБ округлилось бы до «1024,0 КБ» — показываем уже мегабайты.
    if (kb.toStringAsFixed(1) != '1024.0') return '${oneDecimal(kb)} КБ';
  }
  return '${oneDecimal(value / mega)} МБ';
}

/// Текст ошибки без технических префиксов вроде «Bad state:».
String _errorText(Object error) => switch (error) {
      StateError(:final message) => message,
      UnsupportedError(:final message?) => message,
      ArgumentError(:final message?) => '$message',
      _ => '$error',
    };

/// Экран «Хранилище»: где лежат данные, резервная копия и архив
/// выполненных задач.
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.info,
    required this.activeCount,
    required this.completed,
    required this.now,
    required this.onReopen,
    this.chatCount = 0,
  });

  final StorageInfo info;
  final int activeCount;

  /// Сколько чатов с сообщениями (главный и чаты задач).
  final int chatCount;

  /// Выполненные задачи, новые первыми.
  final List<Task> completed;
  final DateTime now;

  /// Вернуть выполненную задачу в работу.
  final Future<void> Function(Task) onReopen;

  static const pageSize = 20;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  late Future<int?> _size;
  bool _backingUp = false;
  int _visible = StorageScreen.pageSize;
  final Set<String> _reopening = <String>{};

  @override
  void initState() {
    super.initState();
    _size = widget.info.sizeBytes();
  }

  @override
  void didUpdateWidget(StorageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.info, widget.info)) {
      _size = widget.info.sizeBytes();
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _backup() async {
    setState(() => _backingUp = true);
    String message;
    try {
      final path = await widget.info.backup();
      message = 'Копия сохранена: $path';
    } on Object catch (error) {
      message = 'Не удалось: ${_errorText(error)}';
    }
    if (!mounted) return;
    setState(() {
      _backingUp = false;
      _size = widget.info.sizeBytes();
    });
    _showMessage(message);
  }

  Future<void> _reopen(Task task) async {
    if (!_reopening.add(task.id)) return;
    String message;
    try {
      await widget.onReopen(task);
      message = '«${task.title}» снова в работе';
    } on Object catch (error) {
      message = 'Не удалось: ${_errorText(error)}';
    }
    _reopening.remove(task.id);
    if (!mounted) return;
    _showMessage(message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    final location = info.location;
    final completed = widget.completed;
    final shown = completed.take(_visible).toList();
    final hidden = completed.length - shown.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Хранилище',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: AssistantColors.textStrong,
                ),
              ),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AssistantColors.panel,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AssistantColors.borderSoft),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _InfoRow(
                        label: 'Где',
                        child: Text(
                          info.label,
                          style: const TextStyle(color: AssistantColors.text),
                        ),
                      ),
                      _InfoRow(
                        label: 'Файл',
                        child: location == null
                            ? const Text(
                                'только в памяти',
                                style: TextStyle(color: AssistantColors.muted),
                              )
                            : SelectableText(
                                location,
                                key: const ValueKey<String>('storage-location'),
                                style: technicalTextStyle.copyWith(
                                  color: AssistantColors.text,
                                ),
                              ),
                      ),
                      _InfoRow(
                        label: 'Размер',
                        child: FutureBuilder<int?>(
                          future: _size,
                          builder: (context, snapshot) {
                            final bytes =
                                snapshot.hasError ? null : snapshot.data;
                            return Text(
                              bytes == null ? '—' : formatBytes(bytes),
                              key: const ValueKey<String>('storage-size'),
                              style: const TextStyle(
                                color: AssistantColors.text,
                              ),
                            );
                          },
                        ),
                      ),
                      _InfoRow(
                        label: 'Задачи',
                        child: Text(
                          'активных: ${widget.activeCount} · '
                          'выполненных: ${completed.length}',
                          key: const ValueKey<String>('storage-counts'),
                          style: const TextStyle(color: AssistantColors.text),
                        ),
                      ),
                      _InfoRow(
                        label: 'Чаты',
                        child: Text(
                          '${widget.chatCount} · '
                          '${info.chatsLocation ?? 'только в памяти'}',
                          key: const ValueKey<String>('storage-chats'),
                          style: const TextStyle(color: AssistantColors.text),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('storage-backup'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(40, 44),
                            foregroundColor: AssistantColors.textStrong,
                            side: const BorderSide(
                              color: AssistantColors.border,
                            ),
                          ),
                          onPressed:
                              info.canBackup && !_backingUp ? _backup : null,
                          icon: _backingUp
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AssistantColors.muted,
                                  ),
                                )
                              : const Icon(Icons.save_outlined, size: 18),
                          label: Text(
                            _backingUp
                                ? 'Создаём копию…'
                                : 'Создать резервную копию',
                          ),
                        ),
                      ),
                      if (!info.canBackup)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'Для хранилища в памяти копия недоступна',
                            style: technicalTextStyle,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SectionLabel('Архив выполненных · ${completed.length}'),
              if (completed.isEmpty)
                const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'Выполненных задач пока нет',
                  hint: 'Завершённые задачи появятся здесь',
                )
              else ...<Widget>[
                for (final task in shown)
                  TaskTile(
                    key: ValueKey<String>('archive-${task.id}'),
                    task: task,
                    now: widget.now,
                    onToggleDone: () => _reopen(task),
                  ),
                if (hidden > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey<String>('archive-more'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(40, 44),
                          foregroundColor: AssistantColors.text,
                        ),
                        onPressed: () => setState(
                          () => _visible += StorageScreen.pageSize,
                        ),
                        child: Text('Показать ещё · $hidden'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: technicalTextStyle),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }
}
