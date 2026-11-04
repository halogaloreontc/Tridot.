import 'package:flutter/material.dart';

import '../core/models/assistant_types.dart';
import '../core/models/task.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/task_service.dart';
import 'assistant_theme.dart';
import 'widgets/command_composer.dart';
import 'widgets/document_view.dart';
import 'widgets/history_rail.dart';
import 'widgets/status_cube.dart';

final class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.assistant, required this.tasks});

  final AssistantController assistant;
  final TaskService tasks;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _documentTitle = TextEditingController(
    text: 'Позвонить клиенту',
  );
  final TextEditingController _documentBody = TextEditingController(
    text: 'Уточнить статус документов и согласовать следующий звонок.',
  );
  final ScrollController _messagesScroll = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _contentStackKey = GlobalKey();
  final GlobalKey _liveAnswerKey = GlobalKey();
  final List<_ChatMessage> _messages = <_ChatMessage>[
    _ChatMessage(
      text: 'Я готов к первому сценарию. Создайте задачу, например: '
          '«Добавь задачу “Позвонить клиенту” на завтра в 11:00».',
      fromUser: false,
      timestamp: DateTime.now(),
    ),
  ];
  List<Task> _tasks = <Task>[];
  bool _sending = false;
  AssistantViewMode _mode = AssistantViewMode.dialogue;
  AssistantStatus _status = AssistantStatus.noAction;
  double? _cubeTop;

  @override
  void initState() {
    super.initState();
    _refreshTasks();
  }

  @override
  void dispose() {
    _input.dispose();
    _documentTitle.dispose();
    _documentBody.dispose();
    _messagesScroll.dispose();
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
      _status = AssistantStatus.noAction;
      _messages.add(
        _ChatMessage(
          text: text,
          fromUser: true,
          timestamp: DateTime.now(),
        ),
      );
      _input.clear();
    });
    _afterMessageUpdate();
    final response = await widget.assistant.handle(text);
    if (!mounted) return;
    setState(() {
      _status = response.status;
      _messages.add(
        _ChatMessage(
          text: response.message,
          fromUser: false,
          timestamp: DateTime.now(),
        ),
      );
      _sending = false;
      final task = response.task;
      if (task != null) _openDocument(task, changeMode: false);
    });
    _afterMessageUpdate();
    await _refreshTasks();
  }

  void _afterMessageUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_messagesScroll.hasClients) {
        _messagesScroll.jumpTo(0);
      }
      _updateCubePosition();
    });
  }

  void _updateCubePosition() {
    final answer = _liveAnswerKey.currentContext?.findRenderObject();
    final stack = _contentStackKey.currentContext?.findRenderObject();
    if (answer is! RenderBox || stack is! RenderBox || !answer.hasSize) return;
    final top = answer.localToGlobal(Offset.zero, ancestor: stack).dy;
    if (_cubeTop == top || !mounted) return;
    setState(() => _cubeTop = top);
  }

  void _setMode(AssistantViewMode mode) {
    setState(() => _mode = mode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCubePosition());
  }

  void _openDocument(Task task, {bool changeMode = true}) {
    _documentTitle.text = task.title;
    _documentBody.text = task.description;
    if (changeMode) _mode = AssistantViewMode.document;
  }

  void _selectTask(Task task) {
    widget.assistant.selectTask(task.id);
    setState(() => _openDocument(task));
    if (_scaffoldKey.currentState?.isEndDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCubePosition());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: Drawer(child: SafeArea(child: _buildTasks())),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Row(
              children: <Widget>[
                _buildSidebar(constraints.maxWidth),
                Expanded(child: _buildWorkspace(constraints.maxWidth)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebar(double width) {
    final compact = width < 700;
    final sidebarWidth = compact ? 64.0 : (width < 1100 ? 240.0 : 336.0);
    return Container(
      key: const Key('app-sidebar'),
      width: sidebarWidth,
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 16),
          _navItem(Icons.grid_view, 'Dashboard', compact),
          _navItem(Icons.square_outlined, 'Projects', compact, enabled: false),
          _navItem(Icons.task_alt, 'Tasks', compact, active: true),
          _navItem(
            Icons.calendar_today_outlined,
            'Planning',
            compact,
            enabled: false,
          ),
          _navItem(
            Icons.folder_outlined,
            'File management',
            compact,
            enabled: false,
          ),
          const Spacer(),
          _navItem(
            Icons.settings_outlined,
            'Настройки',
            compact,
            enabled: false,
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                const Icon(Icons.storage_outlined, size: 18),
                if (!compact) ...<Widget>[
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Локальный диск', style: TextStyle(fontSize: 12)),
                        Text(
                          'JSON · на этом устройстве',
                          style: technicalTextStyle,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(
    IconData icon,
    String label,
    bool compact, {
    bool active = false,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Tooltip(
        message: enabled ? label : '$label · позже',
        child: InkWell(
          onTap: enabled ? () {} : null,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: active ? const Color(0xFF202420) : Colors.transparent,
              border: Border.all(
                color: active ? const Color(0xFF414741) : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 17),
                if (!compact) ...<Widget>[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(double width) {
    return ColoredBox(
      color: const Color(0xFF151715),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child:
                        Text('Рабочее пространство', style: technicalTextStyle),
                  ),
                  IconButton(
                    key: const Key('tasks-toggle'),
                    onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                    tooltip: 'Задачи',
                    icon: const Icon(Icons.checklist),
                  ),
                ],
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: Stack(
              key: _contentStackKey,
              children: <Widget>[
                Positioned.fill(
                  child: _mode == AssistantViewMode.dialogue
                      ? _buildDialogue(width)
                      : DocumentView(
                          titleController: _documentTitle,
                          bodyController: _documentBody,
                          liveAnswerKey: _liveAnswerKey,
                          answer: _latestAnswer,
                        ),
                ),
                AnimatedPositioned(
                  left: 12.4,
                  top: _cubeTop ?? 0,
                  duration: MediaQuery.of(context).disableAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  child: StatusCube(status: _status, moving: _sending),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = _mode == AssistantViewMode.document
                  ? (constraints.maxWidth < 384 ? constraints.maxWidth : 384.0)
                  : (constraints.maxWidth < 768 ? constraints.maxWidth : 768.0);
              return Align(
                alignment: _mode == AssistantViewMode.document
                    ? Alignment.centerLeft
                    : Alignment.center,
                child: AnimatedContainer(
                  duration: MediaQuery.of(context).disableAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                  width: width,
                  padding: const EdgeInsets.all(16),
                  child: CommandComposer(
                    controller: _input,
                    sending: _sending,
                    mode: _mode,
                    onModeChanged: _setMode,
                    onSend: _send,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDialogue(double width) {
    return Row(
      children: <Widget>[
        Expanded(
          child: ListView(
            controller: _messagesScroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(56.8, 20, 20, 20),
            children: _messageWidgets().reversed.toList(),
          ),
        ),
        HistoryRail(entries: _historyEntries()),
        if (width >= 1200) SizedBox(width: 320, child: _buildTasks()),
      ],
    );
  }

  List<Widget> _messageWidgets() {
    final widgets = <Widget>[];
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      final latest = index == _messages.length - 1 && !message.fromUser;
      widgets.add(
        _MessageView(
          key: latest ? _liveAnswerKey : null,
          message: message,
          latest: latest,
        ),
      );
    }
    if (_sending) {
      widgets.add(
        _MessageView(
          key: _liveAnswerKey,
          message: _ChatMessage(
            text: 'Команда обрабатывается локально…',
            fromUser: false,
            timestamp: DateTime.now(),
          ),
          latest: true,
        ),
      );
    }
    return widgets;
  }

  String get _latestAnswer {
    for (final message in _messages.reversed) {
      if (!message.fromUser) return message.text;
    }
    return '';
  }

  List<HistoryEntry> _historyEntries() {
    final entries = <HistoryEntry>[];
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      final messages = <String>[message.text];
      if (message.fromUser &&
          index + 1 < _messages.length &&
          !_messages[index + 1].fromUser) {
        messages.add(_messages[index + 1].text);
      }
      entries.add(
        HistoryEntry(
          messages: messages,
          timestamp: _formatTimestamp(message.timestamp),
        ),
      );
    }
    return entries;
  }

  Widget _buildTasks() {
    return Material(
      color: const Color(0xFF101210),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 8),
            child: Text('Задачи', style: TextStyle(fontSize: 22)),
          ),
          Expanded(
            child: _tasks.isEmpty
                ? const Center(child: Text('Пока пусто'))
                : ListView.separated(
                    itemCount: _tasks.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (context, index) {
                      final task = _tasks[index];
                      return ListTile(
                        leading: const Icon(Icons.radio_button_unchecked),
                        title: Text(task.title),
                        subtitle: Text(
                          _taskDetails(task),
                          style: technicalTextStyle,
                        ),
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
    if (due == null) return 'Без срока';
    return '${_formatTimestamp(due)} · нажмите, чтобы открыть';
  }

  static String _formatTimestamp(DateTime value) {
    final date = '${value.day.toString().padLeft(2, '0')}.'
        '${value.month.toString().padLeft(2, '0')}.${value.year}';
    final time = '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
    return '$date · $time';
  }
}

final class _ChatMessage {
  const _ChatMessage({
    required this.text,
    required this.fromUser,
    required this.timestamp,
  });

  final String text;
  final bool fromUser;
  final DateTime timestamp;
}

final class _MessageView extends StatelessWidget {
  const _MessageView({
    super.key,
    required this.message,
    required this.latest,
  });

  final _ChatMessage message;
  final bool latest;

  @override
  Widget build(BuildContext context) {
    final timestamp = _HomePageState._formatTimestamp(message.timestamp);
    return Align(
      alignment:
          message.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: message.fromUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: message.fromUser
                  ? const EdgeInsets.symmetric(horizontal: 14, vertical: 9)
                  : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: message.fromUser
                    ? const Color(0xFF292D29)
                    : Colors.transparent,
                border: message.fromUser
                    ? Border.all(color: const Color(0xFF3B403B), width: .5)
                    : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(message.text),
            ),
            const SizedBox(height: 4),
            Text(timestamp, style: technicalTextStyle),
          ],
        ),
      ),
    );
  }
}
