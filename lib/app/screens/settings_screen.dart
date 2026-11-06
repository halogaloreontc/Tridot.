import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../widgets/extensions_section.dart';
import '../widgets/personas_section.dart';
import '../widgets/task_tile.dart';

/// Экран «Настройки»: поведение интерфейса, помощники, расширения,
/// история чата, о приложении.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onClearChat,
    required this.messageCount,
    this.extensions,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final VoidCallback onClearChat;

  /// Сообщений в чате; приветствие помощника тоже считается.
  final int messageCount;

  /// Навыки, подключения и паки; `null` — раздел «Расширения» не показан.
  final ExtensionRegistry? extensions;

  static const applicationName = AppInfo.name;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AssistantColors.raised,
        title: const Text('Очистить историю чата?'),
        content: const Text(
          'Сообщения будут удалены. Задачи останутся на месте.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('clear-chat-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('clear-chat-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) onClearChat();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canClear = messageCount > 1;
    const switchTitle = TextStyle(color: AssistantColors.text);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Настройки',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: AssistantColors.textStrong,
                ),
              ),
              const SectionLabel('Интерфейс'),
              SwitchListTile(
                key: const ValueKey<String>('setting-reduce-motion'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: const Text('Уменьшить анимацию', style: switchTitle),
                subtitle: const Text(
                  'Кубик и переходы без движения',
                  style: technicalTextStyle,
                ),
                value: settings.reduceMotion,
                onChanged: (value) =>
                    onChanged(settings.copyWith(reduceMotion: value)),
              ),
              SwitchListTile(
                key: const ValueKey<String>('setting-timestamps'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: const Text('Время под сообщениями', style: switchTitle),
                value: settings.showTimestamps,
                onChanged: (value) =>
                    onChanged(settings.copyWith(showTimestamps: value)),
              ),
              PersonasSection(
                settings: settings,
                onChanged: onChanged,
                registry: extensions,
              ),
              if (extensions case final ExtensionRegistry registry)
                ExtensionsSection(
                  registry: registry,
                  settings: settings,
                  onChanged: onChanged,
                ),
              const SectionLabel('Чат'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const ValueKey<String>('clear-chat'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(40, 44),
                        foregroundColor: AssistantColors.danger,
                        side: const BorderSide(color: AssistantColors.border),
                      ),
                      onPressed: canClear ? () => _confirmClear(context) : null,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Очистить историю чата'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      canClear
                          ? 'Сообщений: $messageCount'
                          : 'История пуста — очищать нечего',
                      style: technicalTextStyle,
                    ),
                  ],
                ),
              ),
              const SectionLabel('О приложении'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '$applicationName · личный помощник, локально, без интернета '
                      'и языковой модели',
                      style: TextStyle(color: AssistantColors.text),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const ValueKey<String>('licenses'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 44),
                        foregroundColor: AssistantColors.text,
                      ),
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: applicationName,
                      ),
                      child: const Text('Лицензии'),
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
}
