import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chats/chat_projects.dart';
import '../../core/formatting/plural.dart';
import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';

/// Название и описание проекта из окна «Новый проект» / «Описание».
typedef ProjectDraft = ({String name, String? description});

/// Окно «Новый проект» (или правка: [name], [description] заданы):
/// название (обязательно) и описание. `null` — «Отмена».
Future<ProjectDraft?> showProjectDialog(
  BuildContext context, {
  String title = 'Новый проект',
  String action = 'Создать',
  String name = '',
  String? description,
}) {
  return showDialog<ProjectDraft>(
    context: context,
    builder: (BuildContext context) => _ProjectDialog(
      title: title,
      action: action,
      name: name,
      description: description ?? '',
    ),
  );
}

final class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({
    required this.title,
    required this.action,
    required this.name,
    required this.description,
  });

  final String title;
  final String action;
  final String name;
  final String description;

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

final class _ProjectDialogState extends State<_ProjectDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late final TextEditingController _description =
      TextEditingController(text: widget.description);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String? get _cleanName => ChatProject.cleanName(_name.text);

  void _save() {
    final name = _cleanName;
    if (name == null) return;
    Navigator.of(context).pop<ProjectDraft>(
      (
        name: name,
        description: ChatProject.cleanDescription(_description.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AssistantColors.raised,
      scrollable: true,
      title: WholeWordText(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('project-name-field'),
            controller: _name,
            autofocus: true,
            maxLength: ChatProject.nameLimit,
            maxLines: 1,
            textInputAction: TextInputAction.next,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.deny(RegExp('[\n\r]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('project-description-field'),
            controller: _description,
            maxLength: ChatProject.descriptionLimit,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Описание (необязательно)',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('project-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('project-save'),
          onPressed: _cleanName == null ? null : _save,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

/// Выбор в листе «В проект…».
sealed class ProjectMove {
  const ProjectMove();
}

/// Перенести в проект [projectId].
final class MoveToProject extends ProjectMove {
  const MoveToProject(this.projectId);

  final String projectId;
}

/// Вынести из проекта.
final class MoveOutOfProject extends ProjectMove {
  const MoveOutOfProject();
}

/// Создать проект и перенести в него.
final class MoveToNewProject extends ProjectMove {
  const MoveToNewProject();
}

/// Лист «В проект…»: проекты-папки ([projects]; тот, где сессия уже
/// лежит, — с галочкой), «Новый проект…» и «Убрать из проекта» (если
/// сессия в проекте, [currentProjectId]). `null` — закрыли без выбора.
Future<ProjectMove?> showMoveToProjectSheet(
  BuildContext context, {
  required List<ChatProject> projects,
  String? currentProjectId,
}) {
  return showModalBottomSheet<ProjectMove>(
    context: context,
    backgroundColor: AssistantColors.raised,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          key: const Key('move-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'В проект',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AssistantColors.textStrong,
                ),
              ),
            ),
            for (final project in projects)
              ListTile(
                key: Key('move-to-${project.id}'),
                leading: const Icon(
                  Icons.folder_outlined,
                  color: AssistantColors.icon,
                ),
                title: Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: projectNameStyle(),
                ),
                trailing: project.id == currentProjectId
                    ? const Icon(Icons.check, color: AssistantColors.icon)
                    : null,
                onTap: () => Navigator.of(context).pop<ProjectMove>(
                  MoveToProject(project.id),
                ),
              ),
            ListTile(
              key: const Key('move-new-project'),
              leading: const Icon(
                Icons.create_new_folder_outlined,
                color: AssistantColors.icon,
              ),
              title: const WholeWordText('Новый проект…'),
              onTap: () => Navigator.of(context)
                  .pop<ProjectMove>(const MoveToNewProject()),
            ),
            if (currentProjectId != null)
              ListTile(
                key: const Key('move-out'),
                leading: const Icon(
                  Icons.folder_off_outlined,
                  color: AssistantColors.icon,
                ),
                title: const WholeWordText('Убрать из проекта'),
                onTap: () => Navigator.of(context)
                    .pop<ProjectMove>(const MoveOutOfProject()),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Что сделать с сессиями удаляемого проекта.
enum ProjectDeleteChoice {
  /// Вынести из проекта (по умолчанию): сессии остаются в «Сессиях».
  moveOut,

  /// Удалить вместе с проектом насовсем.
  deleteSessions,
}

/// «Удалить проект «…»?». Пустой проект ([sessions] = 0) — простое
/// подтверждение (результат — [ProjectDeleteChoice.moveOut]); иначе —
/// выбор: вынести сессии или удалить их вместе с проектом. `null` —
/// «Отмена».
Future<ProjectDeleteChoice?> showDeleteProjectDialog(
  BuildContext context, {
  required String name,
  required int sessions,
}) {
  final count = '$sessions ${ruPlural(sessions, 'сессия', 'сессии', 'сессий')}';
  return showDialog<ProjectDeleteChoice>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      backgroundColor: AssistantColors.raised,
      scrollable: true,
      title: const WholeWordText('Удалить проект?'),
      content: Text(
        sessions == 0
            ? 'Удалить проект «$name»? В нём нет сессий.'
            : 'В проекте «$name» — $count. Их можно вынести из проекта '
                'или удалить вместе с ним. Удаление нельзя отменить.',
        key: const Key('project-delete-text'),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('project-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        if (sessions > 0)
          TextButton(
            key: const Key('project-delete-with-sessions'),
            onPressed: () =>
                Navigator.of(context).pop(ProjectDeleteChoice.deleteSessions),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            child: Text('Удалить вместе с сессиями ($sessions)'),
          ),
        if (sessions > 0)
          FilledButton(
            key: const Key('project-delete-move-out'),
            autofocus: true,
            onPressed: () =>
                Navigator.of(context).pop(ProjectDeleteChoice.moveOut),
            child: const Text('Вынести сессии из проекта'),
          )
        else
          TextButton(
            key: const Key('project-delete-confirm'),
            onPressed: () =>
                Navigator.of(context).pop(ProjectDeleteChoice.moveOut),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            child: const Text('Удалить'),
          ),
      ],
    ),
  );
}

/// «Связать с меткой»: метка задач без «#» ([current] — нынешняя).
/// Возвращает запись с меткой (`tag == null` — снять связь) или `null` —
/// «Отмена».
Future<({String? tag})?> showProjectTagDialog(
  BuildContext context, {
  String? current,
  List<String> suggestions = const <String>[],
}) {
  return showDialog<({String? tag})>(
    context: context,
    builder: (BuildContext context) =>
        _TagDialog(current: current, suggestions: suggestions),
  );
}

final class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.current, required this.suggestions});

  final String? current;
  final List<String> suggestions;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

final class _TagDialogState extends State<_TagDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid =>
      _text.text.trim().isEmpty || ChatProject.normalizeTag(_text.text) != null;

  void _save() {
    if (!_valid) return;
    Navigator.of(context).pop<({String? tag})>(
      (tag: ChatProject.normalizeTag(_text.text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AssistantColors.raised,
      scrollable: true,
      title: const WholeWordText('Метка задач'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Задачи с этой меткой видны в проекте, а новая задача из его '
            'сессий получает её, если в команде нет своей метки.',
            style: metaTextStyle,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('project-tag-field'),
            controller: _text,
            autofocus: true,
            maxLines: 1,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              prefixText: '#',
              labelText: 'Метка',
              helperText: 'Одно слово. Пусто — без метки',
              errorText: _valid ? null : 'Метка — одно слово без пробелов',
            ),
          ),
          if (widget.suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final tag in widget.suggestions)
                  ActionChip(
                    key: Key('project-tag-suggestion-$tag'),
                    label: Text('#$tag'),
                    onPressed: () => setState(() => _text.text = tag),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('project-tag-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('project-tag-save'),
          onPressed: _valid ? _save : null,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
