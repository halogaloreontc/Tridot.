import '../security/app_lock.dart';
import '../security/security_section.dart';
import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../../core/skills/converter/convert_caps.dart';
import '../assistant_theme.dart';
import '../extensions/tool_kit.dart';
import '../extensions/weather_kit.dart';
import '../extensions/ytdl_kit.dart';
import '../passwords/passwords_kit.dart';
import '../shell/relay_drawer.dart';
import '../voice/voice_kit.dart';
import '../voice/voice_views.dart';
import '../widgets/extensions_section.dart';
import '../layout.dart';
import '../notify/notify_channel.dart';
import '../notify/notify_views.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';

/// Экран «Настройки»: поведение интерфейса, голос, защита, расширения,
/// история сессий, данные, о приложении. В оболочке «Д» — вкладка
/// «Мой Связной → Настройки» (без заголовка). Помощники и их роли — во
/// вкладке «Помощники»; здесь — только строка-переход к ней.
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
    this.onOpenAssistants,
    this.onOpenStorage,
    this.voice,
    this.ffmpeg,
    this.nativeMedia = NativeMediaCaps.none,
    this.ytdl,
    this.weather,
    this.appLock,
    this.notify,
  });

  /// Уведомления и будильник (ADR-029): группа «Разрешения», если на этом
  /// устройстве есть системные уведомления.
  final NotifyPlatform? notify;

  /// Заголовок «Настройки» над экраном.
  final bool showTitle;

  /// «Помощники и роли» → вкладка «Помощники»; `null` — строки нет.
  final VoidCallback? onOpenAssistants;

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

  /// Звук и видео средствами системы (телефон, Mac; ADR-026).
  final NativeMediaCaps nativeMedia;

  /// Загрузчик видео: «Настроить» в плитке «Загрузчик видео».
  final YtdlKit? ytdl;

  /// Погода (ADR-030): «Расширения → Погода → Настроить».
  final WeatherKit? weather;

  /// Вход в приложение по отпечатку / Face ID (ADR-025); `null` — раздела
  /// «Защита» нет.
  final AppLockController? appLock;

  static const applicationName = AppInfo.name;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const WholeWordText('Очистить историю сессий?'),
        content: const WholeWordText(
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
              foregroundColor: context.colors.danger,
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
    // Приветствия-сообщения больше нет: очищать есть что с первого.
    final canClear = messageCount > 0;
    final colors = context.colors;

    return ColoredBox(
      color: colors.background,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: showTitle ? 0 : AppSpace.m, bottom: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (showTitle) const LargeTitle('Настройки'),
                InsetGroup(
                  header: 'Интерфейс',
                  footer: 'Без «Времени у каждого сообщения» время видно над '
                      'группой сообщений и в меню сообщения',
                  children: <Widget>[
                    GroupedRow(
                      key: const ValueKey<String>('setting-appearance'),
                      icon: Icons.contrast,
                      tile: colors.tileViolet,
                      title: 'Оформление',
                      value: settings.appearance.title,
                      chevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) => AppearanceScreen(
                            settings: settings,
                            onChanged: onChanged,
                          ),
                        ),
                      ),
                    ),
                    GroupedSwitchRow(
                      key: const ValueKey<String>('setting-reduce-motion'),
                      // В группе у всех строк плитки: текст начинается с
                      // одной линии, разделители — с одного отступа.
                      secondary: IconTile(
                        icon: Icons.motion_photos_off_outlined,
                        color: colors.tileBlue,
                      ),
                      title: 'Уменьшить анимацию',
                      subtitle: 'Кубик и переходы без движения',
                      value: settings.reduceMotion,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(reduceMotion: value)),
                    ),
                    GroupedSwitchRow(
                      key: const ValueKey<String>('setting-timestamps'),
                      secondary: IconTile(
                        icon: Icons.schedule,
                        color: colors.tileGray,
                      ),
                      title: 'Время у каждого сообщения',
                      value: settings.showTimestamps,
                      onChanged: (value) =>
                          onChanged(settings.copyWith(showTimestamps: value)),
                    ),
                  ],
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
                if (onOpenAssistants != null)
                  InsetGroup(
                    header: 'Помощники',
                    children: <Widget>[
                      GroupedRow(
                        key: const ValueKey<String>('settings-assistants'),
                        icon: Icons.people_outline,
                        tile: colors.tileGreen,
                        title: 'Помощники и роли',
                        chevron: true,
                        onTap: onOpenAssistants,
                      ),
                    ],
                  ),
                if (notify case final NotifyPlatform platform
                    when platform.supported)
                  PermissionsSection(
                    platform: platform,
                    settings: settings,
                    onChanged: onChanged,
                  ),
                if (extensions case final ExtensionRegistry registry)
                  ExtensionsSection(
                    registry: registry,
                    settings: settings,
                    onChanged: onChanged,
                    connections: connections,
                    passwords: passwords,
                    ffmpeg: ffmpeg,
                    nativeMedia: nativeMedia,
                    ytdl: ytdl,
                    weather: weather,
                  ),
                if (onOpenStorage != null)
                  InsetGroup(
                    header: 'Данные',
                    children: <Widget>[
                      GroupedRow(
                        key: const ValueKey<String>('settings-storage'),
                        icon: Icons.save_outlined,
                        tile: colors.tileBlue,
                        title: 'Данные и резервная копия',
                        chevron: true,
                        onTap: onOpenStorage,
                      ),
                    ],
                  ),
                InsetGroup(
                  header: 'Сессии',
                  footer: canClear
                      ? 'Сообщений: $messageCount'
                      : 'История пуста — очищать нечего',
                  children: <Widget>[
                    GroupedRow(
                      key: const ValueKey<String>('clear-chat'),
                      title: 'Очистить историю сессий',
                      destructive: true,
                      onTap: canClear ? () => _confirmClear(context) : null,
                    ),
                  ],
                ),
                InsetGroup(
                  header: 'О приложении',
                  footer: 'Версия ${AppInfo.version}',
                  footerKey: const ValueKey<String>('app-version'),
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.rowH,
                        vertical: AppSpace.rowV,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 12),
                            child: RelayGlyph(size: 28),
                          ),
                          Expanded(
                            child: WholeWordText(
                              // Приложение — не помощник: помощники в нём работают
                              // (ADR-009).
                              '$applicationName · приложение с помощниками, '
                              'локально, без интернета и языковой модели',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge!
                                  .copyWith(color: colors.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                    GroupedRow(
                      key: const ValueKey<String>('licenses'),
                      icon: Icons.description_outlined,
                      tile: colors.tileGray,
                      title: 'Лицензии',
                      chevron: true,
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: applicationName,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «Настройки → Оформление»: как в системе, светлое или тёмное. Список с
/// галочкой, а не сегменты: на 320 px и шрифте 200 % слова не рвутся.
class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  late AppAppearance _value = widget.settings.appearance;

  void _choose(AppAppearance value) {
    if (value == _value) return;
    setState(() => _value = value);
    widget.onChanged(widget.settings.copyWith(appearance: value));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const WholeWordText('Оформление')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Material(
              color: colors.workspace,
              child: Column(
                children: <Widget>[
                  for (final (i, option) in AppAppearance.values.indexed) ...[
                    if (i > 0) const Divider(indent: 16),
                    Semantics(
                      selected: option == _value,
                      inMutuallyExclusiveGroup: true,
                      child: ListTile(
                        key: ValueKey<String>('appearance-${option.id}'),
                        title: WholeWordText(
                          option.title,
                          style: text.bodyLarge!.copyWith(
                            color: colors.textStrong,
                          ),
                        ),
                        trailing: option == _value
                            ? Icon(Icons.check, color: colors.accent)
                            : null,
                        onTap: () => _choose(option),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: WholeWordText(
              'Как в системе — тема меняется вместе с телефоном',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
