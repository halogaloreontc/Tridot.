import 'package:flutter/material.dart';

import '../core/models/task.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/task_service.dart';

final class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.assistant, required this.tasks});

  final AssistantController assistant;
  final TaskService tasks;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  final List<_ChatMessage> _messages = <_ChatMessage>[
    const _ChatMessage(
      text: 'Я готов к первому сценарию. Создайте задачу, например: '
          '${AssistantController.exampleCommand}',
      fromUser: false,
    ),
  ];
  List<Task> _tasks = <Task>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _refreshTasks();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _refreshTasks() async {
    final tasks = await widget.tasks.listActive();
    if (!mounted) return;
    setState(() => _tasks = tasks);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _messages.add(_ChatMessage(text: text, fromUser: true));
      _input.clear();
    });
    final response = await widget.assistant.handle(text);
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage(text: response.message, fromUser: false));
      _sending = false;
    });
    await _refreshTasks();
  }

  void _selectTask(Task task) {
    widget.assistant.selectTask(task.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Выбрана задача «${task.title}»'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Личный помощник'),
            Text(
              'Локальный прототип · без языковой модели',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (constraints.maxWidth >= 900) {
              return Row(
                children: <Widget>[
                  Expanded(child: _buildConversation()),
                  const SizedBox(width: 16),
                  SizedBox(width: 360, child: _buildTasks()),
                ],
              );
            }
            return Column(
              children: <Widget>[
                Expanded(child: _buildConversation()),
                SizedBox(height: 210, child: _buildTasks()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildConversation() {
    return Card(
      margin: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _messages.length,
              itemBuilder: (BuildContext context, int index) =>
                  _MessageBubble(message: _messages[index]),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Напишите команду…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  tooltip: 'Отправить',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTasks() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(
              'Активные задачи',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: _tasks.isEmpty
                ? const Center(child: Text('Пока пусто'))
                : ListView.separated(
                    itemCount: _tasks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final task = _tasks[index];
                      return ListTile(
                        leading: const Icon(Icons.radio_button_unchecked),
                        title: Text(task.title),
                        subtitle: Text(_taskDetails(task)),
                        onTap: () => _selectTask(task),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _taskDetails(Task task) {
    final due = task.dueAt;
    if (due == null) return 'Без срока · нажмите, чтобы выбрать';
    final day =
        '${due.day.toString().padLeft(2, '0')}.${due.month.toString().padLeft(2, '0')}';
    if (task.duePrecision == DuePrecision.date) {
      return '$day · нажмите, чтобы выбрать';
    }
    final time =
        '${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
    return '$day, $time · нажмите, чтобы выбрать';
  }
}

final class _ChatMessage {
  const _ChatMessage({required this.text, required this.fromUser});

  final String text;
  final bool fromUser;
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment:
          message.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: message.fromUser
              ? scheme.primary
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: message.fromUser ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
