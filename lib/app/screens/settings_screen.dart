import '../security/app_lock.dart';
import '../security/security_section.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../../core/skills/converter/convert_caps.dart';
import '../../core/voice/voice_recognizer.dart';
import '../assistant_theme.dart';
import '../extensions/tool_kit.dart';
import '../extensions/weather_kit.dart';
import '../extensions/ytdl_kit.dart';
import '../homescreen/home_screen_channel.dart';
import '../homescreen/home_screen_section.dart';
import '../gen/gen_kit.dart';
import '../gen/gen_section.dart';
import '../intent/intent_kit.dart';
import '../intent/intent_section.dart';
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
import '../widgets/app_dialog.dart';

/// Экран «Настройки» (как в iOS, Telegram, Discord): категории
/// сгруппированным списком, каждая — своя страница. Внутри категорий — те
/// же разделы с теми же ключами строк. В оболочке «Д» — вкладка «Мой
/// Связной → Настройки» (без заголовка). Помощники и их роли — во вкладке
/// «Помощники»; здесь — только строка-переход к ней.
class SettingsScreen extends StatefulWidget {
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
    this.intent,
    this.gen,
    this.ffmpeg,
    this.nativeMedia = NativeMediaCaps.none,
    this.ytdl,
    this.weather,
    this.appLock,
    this.notify,
    this.homeScreen,
    this.category,
  });

  /// Сразу одна категория (`interface`, `voice`, `understanding`, …) вместо
  /// списка: переход «Настройки → …» из ответа помощника.
  final String? category;

  /// Виджеты рабочего стола (ADR-034): категория «Виджеты», если они есть
  /// на этом устройстве (Android).
  final HomeScreenPlatform? homeScreen;

  /// Уведомления и будильник (ADR-029): категория «Уведомления», если на
  /// этом устройстве есть системные уведомления.
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

  /// Навыки, подключения и паки; `null` — категории «Расширения» нет.
  final ExtensionRegistry? extensions;

  /// Подключения к приложениям: у их строк в «Подключениях» — статус и
  /// «Настроить».
  final List<ConnectionService> connections;

  /// Навык «Пароли»: статус и «Настроить» в «Расширениях».
  final PasswordsKit? passwords;

  /// Голосовой ввод (ADR-023); `null` — на этой платформе его нет, раздел
  /// только сообщает об этом.
  final VoiceKit? voice;

  /// Модель понимания (ADR-045); `null` — раздела «Понимание фраз» нет.
  final IntentKit? intent;

  /// «Продвинутая» (ADR-046); `null` — раздела нет.
  final GenKit? gen;

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

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Категория настроек: строка на главной странице и её страница.
final class _Category {
  const _Category({
    required this.id,
    required this.icon,
    required this.tile,
    required this.title,
    required this.build,
    this.value,
  });

  final String id;
  final IconData icon;
  final Color tile;
  final String title;
  final String? value;
  final List<Widget> Function(BuildContext context, AppSettings settings) build;
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Настройки для открытых страниц категорий: меняются без возврата
  /// назад.
  late final ValueNotifier<AppSettings> _settings =
      ValueNotifier<AppSettings>(widget.settings);

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _settings.value = widget.settings;
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  void _changed(AppSettings next) {
    _settings.value = next;
    widget.onChanged(next);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: const WholeWordText('Очистить историю сессий?'),
        content: const WholeWordText(
          'Сообщения всех сессий, в том числе сессий задач, будут удалены. '
          'Задачи останутся на месте, проекты — пустыми.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('clear-chat-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('clear-chat-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) widget.onClearChat();
  }

  /// Группы категорий сверху вниз.
  List<List<_Category>> _groups(BuildContext context) {
    final w = widget;
    final colors = context.colors;
    final settings = widget.settings;
    return <List<_Category>>[
      <_Category>[
        _Category(
          id: 'interface',
          icon: Icons.contrast,
          tile: colors.tileViolet,
          title: 'Оформление',
          value: settings.appearance.title,
          build: (context, s) => <Widget>[_interface(context, s)],
        ),
        if (w.notify case final NotifyPlatform platform when platform.supported)
          _Category(
            id: 'notifications',
            icon: Icons.notifications_outlined,
            tile: colors.tileRed,
            title: 'Уведомления',
            build: (context, s) => <Widget>[
              PermissionsSection(
                platform: platform,
                settings: s,
                onChanged: _changed,
              ),
            ],
          ),
        if (w.homeScreen case final HomeScreenPlatform platform
            when platform.supported)
          _Category(
            id: 'widgets',
            icon: Icons.widgets_outlined,
            tile: colors.tileBlue,
            title: 'Виджеты',
            build: (context, s) => <Widget>[
              HomeScreenSection(
                platform: platform,
                settings: s,
                onChanged: _changed,
                voice: w.voice != null &&
                    w.voice!.support != VoiceSupport.unsupported,
              ),
            ],
          ),
      ],
      <_Category>[
        if (w.onOpenAssistants != null)
          _Category(
            id: 'assistants',
            icon: Icons.people_outline,
            tile: colors.tileGreen,
            title: 'Помощники и роли',
            build: (context, s) => const <Widget>[],
          ),
        _Category(
          id: 'voice',
          icon: Icons.mic_none,
          tile: colors.tileRed,
          title: 'Голос',
          build: (context, s) => <Widget>[
            VoiceSettingsSection(
              settings: s,
              onChanged: _changed,
              voice: w.voice,
            ),
          ],
        ),
        if (w.intent != null || w.gen != null)
          _Category(
            id: 'understanding',
            icon: Icons.psychology_outlined,
            tile: colors.tileViolet,
            title: 'Понимание и модели',
            value: settings.genEnabled
                ? 'Продвинутая'
                : settings.intentTier == IntentTier.off
                    ? 'Только правила'
                    : settings.intentTier.title,
            build: (context, s) => <Widget>[
              if (w.intent case final IntentKit kit)
                IntentSettingsSection(
                  settings: s,
                  onChanged: _changed,
                  intent: kit,
                ),
              if (w.gen case final GenKit kit)
                GenSettingsSection(settings: s, onChanged: _changed, gen: kit),
            ],
          ),
      ],
      <_Category>[
        if (w.extensions case final ExtensionRegistry registry)
          _Category(
            id: 'extensions',
            icon: Icons.extension_outlined,
            tile: colors.tileBlue,
            title: 'Расширения',
            build: (context, s) => <Widget>[
              ExtensionsSection(
                registry: registry,
                settings: s,
                onChanged: _changed,
                connections: w.connections,
                passwords: w.passwords,
                ffmpeg: w.ffmpeg,
                nativeMedia: w.nativeMedia,
                ytdl: w.ytdl,
                weather: w.weather,
              ),
            ],
          ),
        if (w.appLock case final AppLockController lock)
          _Category(
            id: 'security',
            icon: Icons.lock_outline,
            tile: colors.tileGray,
            title: 'Защита',
            build: (context, s) => <Widget>[
              SecuritySection(
                settings: s,
                onChanged: _changed,
                lock: lock,
                hasVault: w.passwords != null,
              ),
            ],
          ),
        _Category(
          id: 'data',
          icon: Icons.save_outlined,
          tile: colors.tileBlue,
          title: 'Данные и история',
          build: (context, s) => <Widget>[_data(context)],
        ),
      ],
      <_Category>[
        _Category(
          id: 'about',
          icon: Icons.info_outline,
          tile: colors.tileGray,
          title: 'О приложении',
          value: AppInfo.version,
          build: (context, s) => <Widget>[_about(context)],
        ),
      ],
    ];
  }

  Widget _interface(BuildContext context, AppSettings s) {
    final colors = context.colors;
    return InsetGroup(
      footer: 'Без «Времени у каждого сообщения» время видно над '
          'группой сообщений и в меню сообщения',
      children: <Widget>[
        GroupedRow(
          key: const ValueKey<String>('setting-appearance'),
          icon: Icons.contrast,
          tile: colors.tileViolet,
          title: 'Тема',
          value: s.appearance.title,
          chevron: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => AppearanceScreen(
                settings: s,
                onChanged: _changed,
              ),
            ),
          ),
        ),
        GroupedSwitchRow(
          key: const ValueKey<String>('setting-reduce-motion'),
          // В группе у всех строк плитки: текст начинается с одной линии,
          // разделители — с одного отступа.
          secondary: IconTile(
            icon: Icons.motion_photos_off_outlined,
            color: colors.tileBlue,
          ),
          title: 'Уменьшить анимацию',
          subtitle: 'Кубик и переходы без движения',
          value: s.reduceMotion,
          onChanged: (value) => _changed(s.copyWith(reduceMotion: value)),
        ),
        GroupedSwitchRow(
          key: const ValueKey<String>('setting-timestamps'),
          secondary: IconTile(icon: Icons.schedule, color: colors.tileGray),
          title: 'Время у каждого сообщения',
          value: s.showTimestamps,
          onChanged: (value) => _changed(s.copyWith(showTimestamps: value)),
        ),
      ],
    );
  }

  Widget _data(BuildContext context) {
    final colors = context.colors;
    final count = widget.messageCount;
    final canClear = count > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.onOpenStorage != null)
          InsetGroup(
            header: 'Данные',
            children: <Widget>[
              GroupedRow(
                key: const ValueKey<String>('settings-storage'),
                icon: Icons.save_outlined,
                tile: colors.tileBlue,
                title: 'Данные и резервная копия',
                chevron: true,
                onTap: widget.onOpenStorage,
              ),
            ],
          ),
        InsetGroup(
          header: 'Сессии',
          footer:
              canClear ? 'Сообщений: $count' : 'История пуста — очищать нечего',
          children: <Widget>[
            GroupedRow(
              key: const ValueKey<String>('clear-chat'),
              title: 'Очистить историю сессий',
              destructive: true,
              onTap: canClear ? () => _confirmClear(context) : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _about(BuildContext context) {
    final colors = context.colors;
    return InsetGroup(
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
                padding: EdgeInsets.only(top: 4, right: 12),
                child: RelayGlyph(size: 28),
              ),
              Expanded(
                child: WholeWordText(
                  // Приложение — не помощник: помощники в нём работают
                  // (ADR-009).
                  '${SettingsScreen.applicationName} · приложение с '
                  'помощниками, на устройстве, без интернета',
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
            applicationName: SettingsScreen.applicationName,
          ),
        ),
      ],
    );
  }

  void _open(BuildContext context, _Category category) {
    if (category.id == 'assistants') {
      widget.onOpenAssistants?.call();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _CategoryPage(
          title: category.title,
          settings: _settings,
          sections: category.build,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final only = widget.category;
    if (only != null) {
      final category = _groups(context)
          .expand((List<_Category> g) => g)
          .where((_Category c) => c.id == only)
          .firstOrNull;
      return ColoredBox(
        color: colors.background,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: category?.build(context, widget.settings) ??
                    const <Widget>[],
              ),
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      color: colors.background,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          top: widget.showTitle ? 0 : AppSpace.m,
          bottom: 32,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.showTitle) const LargeTitle('Настройки'),
                for (final group in _groups(context))
                  if (group.isNotEmpty)
                    InsetGroup(
                      children: <Widget>[
                        for (final c in group)
                          GroupedRow(
                            key: ValueKey<String>('settings-cat-${c.id}'),
                            icon: c.icon,
                            tile: c.tile,
                            title: c.title,
                            value: c.value,
                            chevron: true,
                            onTap: () => _open(context, c),
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

/// Страница категории: разделы прежние, настройки — живые.
final class _CategoryPage extends StatelessWidget {
  const _CategoryPage({
    required this.title,
    required this.settings,
    required this.sections,
  });

  final String title;
  final ValueListenable<AppSettings> settings;
  final List<Widget> Function(BuildContext context, AppSettings settings)
      sections;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.background,
        appBar: AppBar(title: WholeWordText(title)),
        body: ValueListenableBuilder<AppSettings>(
          valueListenable: settings,
          builder: (BuildContext context, AppSettings s, _) =>
              SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 32),
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: AppSize.maxSettings),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: sections(context, s),
                ),
              ),
            ),
          ),
        ),
      );
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
