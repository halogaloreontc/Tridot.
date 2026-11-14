import '../security/app_lock.dart';
import '../security/security_section.dart';
import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import '../extensions/tool_kit.dart';
import '../extensions/ytdl_kit.dart';
import '../passwords/passwords_kit.dart';
import '../voice/voice_kit.dart';
import '../voice/voice_views.dart';
import '../widgets/extensions_section.dart';
import '../widgets/personas_section.dart';
import '../widgets/roles_section.dart';
import '../widgets/task_tile.dart';
import '../widgets/whole_word_text.dart';

/// Экран «Настройки»: поведение интерфейса, помощники, роли, расширения,
/// история сессий, данные, о приложении. В оболочке «Д» — вкладка
/// «Мой Tridot → Настройки» (без заголовка, помощники — своей вкладкой).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onClearChat,
    required this.messageCount,
    this.extensions,
    this.connections = const <ConnectionService>[],
    this.passwords,
    this.showTitle = true,
    this.includePersonas = true,
    this.onOpenStorage,
    this.voice,
    this.ffmpeg,
    this.ytdl,
    this.appLock,
  });

  /// Заголовок «Настройки» над экраном.
  final bool showTitle;

  /// Раздел «Помощники» на этом экране (иначе он своей вкладкой).
  final bool includePersonas;

  /// «Данные и резервная копия»; `null` — строки нет.
  final VoidCallback? onOpenStorage;

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final VoidCallback onClearChat;

  /// Сообщений во всех сессиях; приветствие помощника тоже считается.
  final int messageCount;

  /// Навыки, подключения и паки; `null` — раздел «Расширения» не показан.
  final ExtensionRegistry? extensions;

  /// Подключения к приложениям: у их строк в «Подключениях» — статус и
  /// «Настроить».
  final List<ConnectionService> connections;

  /// Навык «Пароли»: статус и «Настроить» в «Расширениях».
  final PasswordsKit? passwords;

  /// Голосовой ввод (ADR-023); `null` — на этой платформе его нет, раздел
  /// только сообщает об этом.
  final VoiceKit? voice;

  /// ffmpeg конвертера: «Настроить» в плитке «Конвертер».
  final ToolKit? ffmpeg;

  /// Загрузчик видео: «Настроить» в плитке «Загрузчик видео».
  final YtdlKit? ytdl;

  /// Вход в приложение по отпечатку / Face ID (ADR-025); `null` — раздела
  /// «Защита» нет.
  final AppLockController? appLock;

  static const applicationName = AppInfo.name;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AssistantColors.raised,
        title: const WholeWordText('Очистить историю сессий?'),
        content: const Text(
          'Сообщения всех сессий, в том числе сессий задач, будут удалены. '
          'Задачи останутся на месте, проекты — пустыми.',
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
    // Приветствия-сообщения больше нет: очищать есть что с первого.
    final canClear = messageCount > 0;
    const switchTitle = TextStyle(color: AssistantColors.text);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (showTitle)
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
                title: const WholeWordText(
                  'Уменьшить анимацию',
                  style: switchTitle,
                ),
                subtitle: const WholeWordText(
                  'Кубик и переходы без движения',
                  style: metaTextStyle,
                ),
                value: settings.reduceMotion,
                onChanged: (value) =>
                    onChanged(settings.copyWith(reduceMotion: value)),
              ),
              SwitchListTile(
                key: const ValueKey<String>('setting-timestamps'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: const WholeWordText(
                  'Время под сообщениями',
                  style: switchTitle,
                ),
                value: settings.showTimestamps,
                onChanged: (value) =>
                    onChanged(settings.copyWith(showTimestamps: value)),
              ),
              VoiceSettingsSection(
                settings: settings,
                onChanged: onChanged,
                voice: voice,
              ),
              if (appLock case final AppLockController lock)
                SecuritySection(
                  settings: settings,
                  onChanged: onChanged,
                  lock: lock,
                  hasVault: passwords != null,
                ),
              if (includePersonas)
                PersonasSection(
                  settings: settings,
                  onChanged: onChanged,
                  registry: extensions,
                ),
              if (extensions case final ExtensionRegistry registry
                  when registry.roles.isNotEmpty)
                RolesSection(
                  registry: registry,
                  settings: settings,
                  onChanged: onChanged,
                  connections: connections,
                ),
              if (extensions case final ExtensionRegistry registry)
                ExtensionsSection(
                  registry: registry,
                  settings: settings,
                  onChanged: onChanged,
                  connections: connections,
                  passwords: passwords,
                  ffmpeg: ffmpeg,
                  ytdl: ytdl,
                ),
              const SectionLabel('Сессии'),
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
                      label: const Text('Очистить историю сессий'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      canClear
                          ? 'Сообщений: $messageCount'
                          : 'История пуста — очищать нечего',
                      style: metaTextStyle,
                    ),
                  ],
                ),
              ),
              if (onOpenStorage != null) ...<Widget>[
                const SectionLabel('Данные'),
                ListTile(
                  key: const ValueKey<String>('settings-storage'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  minTileHeight: 48,
                  leading: const Icon(Icons.save_outlined),
                  title: const WholeWordText(
                    'Данные и резервная копия',
                    style: switchTitle,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onOpenStorage,
                ),
              ],
              const SectionLabel('О приложении'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      // Приложение — не помощник: помощники в нём работают
                      // (ADR-009).
                      '$applicationName · приложение с помощниками, локально, '
                      'без интернета и языковой модели',
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
