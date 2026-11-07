import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import 'task_tile.dart';

/// Раздел «Расширения» в настройках: навыки, подключения и паки.
///
/// Выбор пользователя живёт в [AppSettings] (`disabledExtensions`,
/// `enabledExtensions`); переключатель сообщает новые настройки через
/// [onChanged], а применяет их владелец экрана — сразу, без перезапуска.
class ExtensionsSection extends StatefulWidget {
  const ExtensionsSection({
    super.key,
    required this.registry,
    required this.settings,
    required this.onChanged,
  });

  final ExtensionRegistry registry;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<ExtensionsSection> createState() => _ExtensionsSectionState();
}

class _ExtensionsSectionState extends State<ExtensionsSection> {
  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_changed);
  }

  @override
  void didUpdateWidget(ExtensionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry.removeListener(_changed);
      widget.registry.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.registry.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  ExtensionChoice get _choice => ExtensionChoice(
        disabled: widget.settings.disabledExtensions,
        enabled: widget.settings.enabledExtensions,
      );

  void _toggle(ExtensionInfo info, bool value) {
    final choice = _choice.withEnabled(info, value);
    widget.onChanged(
      widget.settings.copyWith(
        disabledExtensions: choice.disabled,
        enabledExtensions: choice.enabled,
      ),
    );
  }

  Future<void> _addPack() async {
    final added = await showDialog<Pack>(
      context: context,
      builder: (context) => _PackImportDialog(registry: widget.registry),
    );
    if (added == null || !mounted) return;
    _syncForgotten(added.id);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Пак «${added.title}» добавлен.')),
    );
  }

  /// Реестр забыл выбор для [id] (пак удалён или добавлен заново): убираем
  /// его и из настроек, иначе следующее сохранение настроек вернуло бы
  /// выключенный переключатель.
  void _syncForgotten(String id) {
    final settings = widget.settings;
    final registryChoice = widget.registry.choice;
    final staleDisabled = settings.disabledExtensions.contains(id) &&
        !registryChoice.disabled.contains(id);
    final staleEnabled = settings.enabledExtensions.contains(id) &&
        !registryChoice.enabled.contains(id);
    if (!staleDisabled && !staleEnabled) return;
    final choice = _choice.without(id);
    widget.onChanged(
      settings.copyWith(
        disabledExtensions: choice.disabled,
        enabledExtensions: choice.enabled,
      ),
    );
  }

  Future<void> _removePack(ExtensionInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Длинное название при крупном шрифте на узком экране не должно
        // уводить кнопки за край.
        scrollable: true,
        backgroundColor: AssistantColors.raised,
        title: Text('Удалить пак «${info.title}»?'),
        content: const Text(
          'Его записи пропадут. Задачи и история чата останутся.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('pack-remove-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('pack-remove-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    try {
      final removed = await widget.registry.removePack(info.id);
      if (removed && mounted) _syncForgotten(info.id);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            error is PackStoreException
                ? error.message
                : 'Не удалось удалить пак: $error',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = widget.registry;
    final choice = _choice;
    Widget group(ExtensionKind kind, String empty) {
      final items = registry.ofKind(kind);
      return Column(
        key: ValueKey<String>('extensions-${kind.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 2),
            child: Text(
              kind.groupTitle,
              style: const TextStyle(
                color: AssistantColors.textStrong,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Text(empty, style: technicalTextStyle),
            ),
          for (final info in items)
            _ExtensionTile(
              info: info,
              enabled: choice.isEnabled(info),
              onChanged: info.required ? null : (v) => _toggle(info, v),
              onRemove: info.kind == ExtensionKind.pack && !info.builtIn
                  ? () => _removePack(info)
                  : null,
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Расширения'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Настройте ${AppInfo.name} под себя: включайте только нужное. '
            'Изменения применяются сразу, задачи и чат не сбрасываются.',
            style: technicalTextStyle,
          ),
        ),
        group(ExtensionKind.skill, 'Навыков нет'),
        group(ExtensionKind.connector, 'Подключений пока нет'),
        group(ExtensionKind.pack, 'Паков пока нет'),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('pack-add'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(40, 44),
                foregroundColor: AssistantColors.text,
                side: const BorderSide(color: AssistantColors.border),
              ),
              onPressed: _addPack,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Добавить пак'),
            ),
          ),
        ),
      ],
    );
  }
}

/// Строка расширения: название, описание, версия и автор, переключатель.
class _ExtensionTile extends StatelessWidget {
  const _ExtensionTile({
    required this.info,
    required this.enabled,
    required this.onChanged,
    this.onRemove,
  });

  final ExtensionInfo info;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: ValueKey<String>('extension-${info.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      value: enabled,
      onChanged: onChanged,
      title: Text(
        info.title,
        style: const TextStyle(color: AssistantColors.text),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                info.description,
                style: const TextStyle(color: AssistantColors.muted),
              ),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'v${info.version} · ${info.author}',
                style: technicalTextStyle,
              ),
              if (info.builtIn) const _Badge('встроено'),
              if (info.required) const _Badge('всегда включено'),
              if (onRemove != null)
                TextButton(
                  key: ValueKey<String>('extension-remove-${info.id}'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 36),
                    foregroundColor: AssistantColors.danger,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: onRemove,
                  child: const Text('Удалить'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: AssistantColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: technicalTextStyle),
    );
  }
}

/// Диалог «Добавить пак»: вставить JSON, увидеть ошибки, подтвердить
/// замену пака с тем же id.
class _PackImportDialog extends StatefulWidget {
  const _PackImportDialog({required this.registry});

  final ExtensionRegistry registry;

  @override
  State<_PackImportDialog> createState() => _PackImportDialogState();
}

class _PackImportDialogState extends State<_PackImportDialog> {
  final TextEditingController _json = TextEditingController();
  List<String> _errors = const <String>[];
  bool _busy = false;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      await _importOrConfirm();
    } on Object catch (error) {
      // Сбой записи и любая другая ошибка — текстом в диалоге, кнопка
      // снова доступна.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errors = <String>['Не удалось добавить пак: $error'];
      });
    }
  }

  Future<void> _importOrConfirm() async {
    var result = await widget.registry.importPack(_json.text);
    if (result.needsReplaceConfirmation && mounted) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          backgroundColor: AssistantColors.raised,
          title: const Text('Заменить пак?'),
          content: const Text(
            'Пак с таким id уже установлен. Заменить его новой версией?',
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('pack-replace-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            TextButton(
              key: const ValueKey<String>('pack-replace-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Заменить'),
            ),
          ],
        ),
      );
      if (replace ?? false) {
        result = await widget.registry.importPack(_json.text, replace: true);
      }
    }
    if (!mounted) return;
    final pack = result.pack;
    if (pack != null) {
      Navigator.of(context).pop(pack);
      return;
    }
    setState(() {
      _busy = false;
      _errors = result.errors;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AssistantColors.raised,
      title: const Text('Добавить пак'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Вставьте содержимое файла пака (JSON, формат '
                '${PackFormat.format}). Пак — только тексты, он ничего '
                'не выполняет.',
                style: TextStyle(color: AssistantColors.muted),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey<String>('pack-json'),
                controller: _json,
                minLines: 5,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                style: technicalTextStyle.copyWith(
                  color: AssistantColors.text,
                ),
                decoration: const InputDecoration(
                  hintText: '{"format": "assistant-pack/1", …}',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_errors.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Column(
                  key: const ValueKey<String>('pack-errors'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final error in _errors)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          error,
                          style: const TextStyle(
                            color: AssistantColors.danger,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('pack-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          key: const ValueKey<String>('pack-import'),
          onPressed: _busy ? null : _import,
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}
