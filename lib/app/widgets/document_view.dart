import 'package:flutter/material.dart';

import '../assistant_theme.dart';

final class DocumentView extends StatelessWidget {
  const DocumentView({
    super.key,
    required this.titleController,
    required this.bodyController,
    required this.liveAnswerKey,
    required this.answer,
  });

  final TextEditingController titleController;
  final TextEditingController bodyController;
  final GlobalKey liveAnswerKey;
  final String answer;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 72, 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Tasks → Документ задачи', style: technicalTextStyle),
          TextField(
            controller: titleController,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const _FormattingToolbar(),
          TextField(
            key: const Key('document-editor'),
            controller: bodyController,
            minLines: 8,
            maxLines: null,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Свободный текст документа…',
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const Text(
            'Демо · изменения документа не сохраняются',
            key: Key('demo-save-status'),
            style: technicalTextStyle,
          ),
          const SizedBox(height: 28),
          Row(
            key: liveAnswerKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: Text(answer)),
            ],
          ),
        ],
      ),
    );
  }
}

final class _FormattingToolbar extends StatelessWidget {
  const _FormattingToolbar();

  @override
  Widget build(BuildContext context) {
    const items = <(String, IconData)>[
      ('Заголовок — пока не реализован', Icons.title),
      ('Жирный — пока не реализован', Icons.format_bold),
      ('Курсив — пока не реализован', Icons.format_italic),
      ('Список — пока не реализован', Icons.format_list_bulleted),
      ('Чекбокс — пока не реализован', Icons.check_box_outlined),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F1C),
        border: Border.all(color: const Color(0xFF363B36)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: items
            .map(
              (item) => IconButton(
                onPressed: null,
                tooltip: item.$1,
                icon: Icon(item.$2),
              ),
            )
            .toList(),
      ),
    );
  }
}
