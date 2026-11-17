import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/build_flags.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../../core/skills/converter/convert_caps.dart';
import '../../core/passwords/vault.dart';
import '../assistant_theme.dart';
import '../extensions/tool_kit.dart';
import '../extensions/tool_screen.dart';
import '../extensions/weather_kit.dart';
import '../extensions/weather_screen.dart';
import '../../core/skills/weather/weather_settings.dart';
import '../extensions/ytdl_kit.dart';
import '../extensions/ytdl_settings.dart';
import '../passwords/passwords_kit.dart';
import '../passwords/passwords_screen.dart';
import 'connection_screen.dart';
import 'grouped.dart';
import 'whole_word_text.dart';
import 'app_dialog.dart';

/// Раздел «Расширения» в настройках: навыки, подключения и паки.
///
/// Выбор пользователя живёт в [AppSettings] (`disabledExtensions`,
/// `enabledExtensions`); переключатель сообщает новые настройки через
/// [onChanged], а применяет их владелец экрана — сразу, без перезапуска.
///
/// У подключения к приложению ([connections], ADR-011) в строке — статус и
/// «Настроить»: экран входа. Расширение, которое входит в роль (ADR-012),
/// работает, пока включена его роль; здесь его можно только выключить
/// явно и снова включить — правило старшинства в
/// [ExtensionRegistry.enabledUnder]. Пока все его роли выключены,
/// переключатель неактивен.
class ExtensionsSection extends StatefulWidget {
  const ExtensionsSection({
    super.key,
    required this.registry,
    required this.settings,
    required this.onChanged,
    this.connections = const <ConnectionService>[],
    this.passwords,
    this.ffmpeg,
    this.nativeMedia = NativeMediaCaps.none,
    this.ytdl,
    this.weather,
  });

  final ExtensionRegistry registry;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final List<ConnectionService> connections;

  /// Навык «Пароли»: статус хранилища и «Настроить» — экран «Пароли».
  final PasswordsKit? passwords;

  /// ffmpeg конвертера (ADR-024): статус и «Настроить» — скачать или
  /// удалить. `null` — платформа без ffmpeg: только картинки.
  final ToolKit? ffmpeg;

  /// Что умеет система телефона или Mac (ADR-026): звук и видео без
  /// ffmpeg. [NativeMediaCaps.none] — только картинки.
  final NativeMediaCaps nativeMedia;

  /// Загрузчик видео (ADR-024, шаг 3): yt-dlp и папка загрузок. `null` —
  /// загрузчика в этой сборке нет (его плитки тоже нет: навык не
  /// зарегистрирован).
  final YtdlKit? ytdl;

  /// Погода (ADR-030): источник, разрешение сети, город. `null` — навык
  /// без настроек (тесты).
  final WeatherKit? weather;

  @override
  State<ExtensionsSection> createState() => _ExtensionsSectionState();
}

class _ExtensionsSectionState extends State<ExtensionsSection> {
  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_changed);
    for (final connection in widget.connections) {
      connection.addListener(_changed);
    }
    widget.passwords?.addListener(_changed);
    widget.ffmpeg?.addListener(_changed);
    widget.ytdl?.tool.addListener(_changed);
    widget.weather?.addListener(_changed);
  }

  @override
  void didUpdateWidget(ExtensionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ytdl != widget.ytdl) {
      oldWidget.ytdl?.tool.removeListener(_changed);
      widget.ytdl?.tool.addListener(_changed);
    }
    if (oldWidget.weather != widget.weather) {
      oldWidget.weather?.removeListener(_changed);
      widget.weather?.addListener(_changed);
    }
    if (oldWidget.ffmpeg != widget.ffmpeg) {
      oldWidget.ffmpeg?.removeListener(_changed);
      widget.ffmpeg?.addListener(_changed);
    }
    if (oldWidget.passwords != widget.passwords) {
      oldWidget.passwords?.removeListener(_changed);
      widget.passwords?.addListener(_changed);
    }
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry.removeListener(_changed);
      widget.registry.addListener(_changed);
    }
    for (final connection in oldWidget.connections) {
      connection.removeListener(_changed);
    }
    for (final connection in widget.connections) {
      connection.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.ffmpeg?.removeListener(_changed);
    widget.ytdl?.tool.removeListener(_changed);
    widget.weather?.removeListener(_changed);
    widget.passwords?.removeListener(_changed);
    widget.registry.removeListener(_changed);
    for (final connection in widget.connections) {
      connection.removeListener(_changed);
    }
    super.dispose();
  }

  ConnectionService? _connection(String id) => widget.connections
      .where((ConnectionService c) => c.slot.id == id)
      .firstOrNull;

  Future<void> _configure(ExtensionInfo info, ConnectionService service) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ConnectionScreen(
            service: service,
            onEnabledChanged: (bool value) {
              if (!mounted) return;
              widget.onChanged(
                connectionChanged(
                  widget.registry,
                  widget.settings,
                  info.id,
                  connected: value,
                ),
              );
            },
          ),
        ),
      );

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Id конвертера.
  static const String _converterId = 'converter';

  /// Статус плитки «Конвертер»: что работает на этой платформе и есть ли
  /// ffmpeg.
  String _converterStatus(bool enabled) {
    final kit = widget.ffmpeg;
    if (kit == null) {
      final native = widget.nativeMedia.targets;
      if (native.isNotEmpty) {
        return 'Картинки; звук и видео — средствами системы: '
            '${ConvertCaps.mediaNames(native)}';
      }
      return 'Только картинки на этой платформе: png, jpeg, webp, bmp, gif '
          '→ png, jpeg';
    }
    if (!enabled) return 'Картинки; звук и видео — с ffmpeg';
    return toolStatus(kit);
  }

  Future<void> _openTool(ToolKit kit, {bool autoStart = false}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              ToolScreen(kit: kit, autoStart: autoStart),
        ),
      );

  /// Id загрузчика видео.
  static const String _ytdlId = 'ytdl';

  /// Статус плитки «Загрузчик видео».
  String _ytdlStatus(bool enabled) {
    final kit = widget.ytdl;
    if (kit == null) return 'Недоступно на этой платформе';
    if (!enabled) return 'Ссылка → видео или звук; нужна программа yt-dlp';
    return toolStatus(kit.tool, copy: ToolCopy.ytdlp);
  }

  Future<void> _openYtdl(YtdlKit kit, {bool autoStart = false}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ToolScreen(
            kit: kit.tool,
            autoStart: autoStart,
            copy: ToolCopy.ytdlp,
            extra: <Widget>[YtdlFolderSetting(kit: kit)],
          ),
        ),
      );

  /// Переключатель загрузчика: включение — только после предупреждения о
  /// правилах площадок, затем предложение скачать yt-dlp.
  ValueChanged<bool>? _ytdlSwitch(ExtensionInfo info) {
    final base = _switch(info);
    if (base == null) return null;
    return (bool value) {
      if (!value) {
        base(false);
        return;
      }
      unawaited(() async {
        final accepted = await showYtdlWarning(context);
        if (!accepted || !mounted) return;
        base(true);
        final kit = widget.ytdl;
        if (kit == null ||
            kit.tool.isInstalled ||
            kit.tool.isBusy ||
            !kit.tool.spec.available) {
          return;
        }
        final yes = await showToolOffer(
          context,
          kit.tool,
          copy: ToolCopy.ytdlp,
        );
        if (yes && mounted) await _openYtdl(kit, autoStart: true);
      }());
    };
  }

  /// Переключатель конвертера: при включении на компьютере без ffmpeg —
  /// предложение его скачать (с размером и источником).
  ValueChanged<bool>? _converterSwitch(ExtensionInfo info) {
    final base = _switch(info);
    if (base == null) return null;
    return (bool value) {
      base(value);
      final kit = widget.ffmpeg;
      if (!value ||
          kit == null ||
          kit.isInstalled ||
          kit.isBusy ||
          !kit.spec.available) {
        return;
      }
      unawaited(() async {
        final yes = await showToolOffer(context, kit);
        if (yes && mounted) await _openTool(kit, autoStart: true);
      }());
    };
  }

  /// Id погоды.
  static const String _weatherId = 'weather';

  /// Статус плитки «Погода»: источник и разрешение сети.
  String _weatherStatus(WeatherKit kit, bool enabled) {
    final s = kit.settings;
    final status = switch (s.source) {
      WeatherSource.none => 'Источник не выбран',
      WeatherSource.openMeteo => !s.networkAllowed
          ? 'Open-Meteo: сеть не разрешена'
          : s.place == null
              ? 'Open-Meteo: город не выбран'
              : 'Open-Meteo: ${s.place!.name}',
      WeatherSource.link =>
        s.link == null ? 'Своя ссылка не задана' : 'Своя ссылка',
      WeatherSource.app =>
        s.app == null ? 'Приложение не выбрано' : 'Приложение: ${s.app!.label}',
    };
    return enabled ? status : 'Выключено. $status';
  }

  Future<void> _openWeather(WeatherKit kit) => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WeatherScreen(kit: kit),
        ),
      );

  /// Переключатель погоды: при включении без источника сразу открывается
  /// экран настройки.
  ValueChanged<bool>? _weatherSwitch(ExtensionInfo info) {
    final base = _switch(info);
    if (base == null) return null;
    return (bool value) {
      base(value);
      final kit = widget.weather;
      if (!value || kit == null || kit.settings.source != WeatherSource.none) {
        return;
      }
      unawaited(_openWeather(kit));
    };
  }

  /// Статус сейфа в плитке «Пароли» (раздел 8).
  String _passwordsStatus(PasswordsKit kit, bool enabled) {
    if (!enabled) {
      return kit.vaultExisted || kit.state != VaultState.notCreated
          ? 'Выключено — данные сохранены и заперты'
          : 'Выключено';
    }
    switch (kit.state) {
      case VaultState.notCreated:
        return kit.vaultExisted
            ? 'Сейф не найден на устройстве — восстановить можно из копии'
            : 'Сейф не создан';
      case VaultState.locked:
      case VaultState.disabled:
        return 'Сейф заперт';
      case VaultState.unlocked:
        final at = kit.vault.lockAt?.toLocal();
        return at == null
            ? 'Сейф открыт'
            : 'Сейф открыт до ${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _openPasswords(PasswordsKit kit) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PasswordsScreen(kit: kit),
        ),
      );

  ExtensionChoice get _choice => widget.settings.extensionChoice;

  void _toggle(ExtensionInfo info, bool value) {
    final choice = widget.registry.choiceWithFor(_choice, info.id, value);
    widget.onChanged(widget.settings.withChoice(choice));
  }

  /// Пояснение у расширения, которое входит в роль: «Входит в роль
  /// «Кладовщик» — включите её в «Ролях»», пока все его роли выключены.
  String? _roleNote(ExtensionInfo info) {
    final roles = widget.registry.rolesOf(info.id);
    if (roles.isEmpty || info.required) return null;
    if (roles.any(_choice.isRoleEnabled)) return null;
    final names = roles.map((RoleInfo r) => '«${r.title}»').join(' или ');
    return 'Входит в роль $names — включите её в «Ролях»';
  }

  /// Переключатель расширения: у обязательного и у расширения с
  /// выключенными ролями — неактивен.
  ValueChanged<bool>? _switch(ExtensionInfo info) {
    if (info.required || _roleNote(info) != null) return null;
    return (bool v) => _toggle(info, v);
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
    widget.onChanged(settings.withChoice(_choice.without(id)));
  }

  Future<void> _removePack(ExtensionInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        // Длинное название при крупном шрифте на узком экране не должно
        // уводить кнопки за край.
        scrollable: true,
        title: WholeWordText('Удалить пак «${info.title}»?'),
        content: const Text(
          'Его записи пропадут. Задачи и история сессий останутся.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('pack-remove-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('pack-remove-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Удалить'),
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
      return InsetGroup(
        key: ValueKey<String>('extensions-${kind.name}'),
        header: kind.groupTitle,
        children: <Widget>[
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                empty,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium!
                    .copyWith(color: context.colors.muted),
              ),
            ),
          for (final info in items)
            if (_connection(info.id) case final ConnectionService service)
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _switch(info),
                status: <String>[
                  if (service.connected)
                    connectionStatus(service)
                  else
                    'Не подключён — сначала подключите',
                  if (_roleNote(info) case final String note) note,
                ].join('. '),
                onConfigure: () => _configure(info, service),
              )
            else if (info.id == PasswordsKit.skillId &&
                widget.passwords != null)
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _switch(info),
                status: _passwordsStatus(
                  widget.passwords!,
                  registry.enabledUnder(choice, info),
                ),
                onConfigure: registry.enabledUnder(choice, info)
                    ? () => _openPasswords(widget.passwords!)
                    : null,
              )
            // В сборке для Google Play загрузчика нет (и коннектор не
            // зарегистрирован): плитка и её код выбрасываются при сборке.
            else if (!kPlayBuild && info.id == _ytdlId)
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _ytdlSwitch(info),
                status: _roleNote(info) ??
                    _ytdlStatus(registry.enabledUnder(choice, info)),
                onConfigure:
                    registry.enabledUnder(choice, info) && widget.ytdl != null
                        ? () => _openYtdl(widget.ytdl!)
                        : null,
              )
            else if (info.id == _weatherId && widget.weather != null)
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _weatherSwitch(info),
                status: _roleNote(info) ??
                    _weatherStatus(
                      widget.weather!,
                      registry.enabledUnder(choice, info),
                    ),
                onConfigure: () => _openWeather(widget.weather!),
              )
            else if (info.id == _converterId)
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _converterSwitch(info),
                status: _roleNote(info) ??
                    _converterStatus(registry.enabledUnder(choice, info)),
                onConfigure:
                    registry.enabledUnder(choice, info) && widget.ffmpeg != null
                        ? () => _openTool(widget.ffmpeg!)
                        : null,
              )
            else
              _ExtensionTile(
                info: info,
                enabled: registry.enabledUnder(choice, info),
                onChanged: _switch(info),
                status: _roleNote(info),
                onRemove: info.kind == ExtensionKind.pack && !info.builtIn
                    ? () => _removePack(info)
                    : null,
              ),
          // Чего нет в этой сборке (загрузчик видео на Android): вместо
          // плитки — приглушённая строка, почему.
          for (final missing in registry.unavailable)
            if (missing.kind == kind && missing.description.isNotEmpty)
              Padding(
                key: ValueKey<String>('extension-unavailable-${missing.id}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  '${missing.title} — ${missing.description}',
                  style: metaStyle(context),
                ),
              ),
          if (kind == ExtensionKind.pack)
            GroupedRow(
              key: const ValueKey<String>('pack-add'),
              icon: Icons.add,
              tile: context.colors.tileViolet,
              accent: true,
              title: 'Добавить пак',
              onTap: _addPack,
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              WholeWordText(
                'Расширения',
                style: Theme.of(context).textTheme.titleMedium!.copyWith(
                      color: context.colors.textStrong,
                    ),
              ),
              const SizedBox(height: 4),
              WholeWordText(
                'Настройте ${AppInfo.name} под себя: включайте только нужное. '
                'Изменения применяются сразу, задачи и сессии не '
                'сбрасываются.',
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: context.colors.muted,
                    ),
              ),
            ],
          ),
        ),
        group(ExtensionKind.skill, 'Навыков нет'),
        group(ExtensionKind.connector, 'Подключений пока нет'),
        group(ExtensionKind.pack, 'Паков пока нет'),
      ],
    );
  }
}

/// Подключение [id] вошло ([connected]) или вышло: новые настройки.
///
/// Вне ролей — как раньше: вход включает подключение, выход выключает.
/// Подключение роли (ADR-012) вход включает (снимает явное выключение и,
/// если все его роли выключены, включает первую), а выход ничего не
/// меняет: роль остаётся включённой, карточка говорит «Склад не
/// подключён», а фразы склада получают подсказку, как подключить.
AppSettings connectionChanged(
  ExtensionRegistry registry,
  AppSettings settings,
  String id, {
  required bool connected,
}) {
  final info = registry.info(id);
  if (info == null) return settings;
  var choice = settings.extensionChoice;
  final roles = registry.rolesOf(id);
  if (roles.isEmpty) {
    return settings.withChoice(choice.withEnabled(info, connected));
  }
  if (!connected) return settings;
  choice = choice.withRoleExtension(info, true);
  if (!roles.any(choice.isRoleEnabled)) {
    final role = roles
            .where((RoleInfo r) => r.connection?.extensionId == id)
            .firstOrNull ??
        roles.first;
    choice = choice.withRole(role, true);
  }
  return settings.withChoice(choice);
}

/// Строка расширения: название, описание, версия и автор, переключатель.
class _ExtensionTile extends StatelessWidget {
  const _ExtensionTile({
    required this.info,
    required this.enabled,
    required this.onChanged,
    this.onRemove,
    this.status,
    this.onConfigure,
  });

  final ExtensionInfo info;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onRemove;

  /// Статус подключения: «Подключён: ivanov · под своим логином».
  final String? status;

  /// «Настроить» — экран подключения.
  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: ValueKey<String>('extension-${info.id}'),
      value: enabled,
      onChanged: onChanged,
      // Название — обычным цветом и у обязательного расширения: его
      // переключатель недоступен, но строка не «выключена».
      title: Text(
        info.title,
        style: TextStyle(color: context.colors.textStrong),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: WholeWordText(info.description),
            ),
          if (status case final String text)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                text,
                key: ValueKey<String>('extension-status-${info.id}'),
                style: TextStyle(color: context.colors.text),
              ),
            ),
          // Без «паспорта» в списке: версия и автор — только у
          // поставленных пользователем паков, «встроено» не пишется,
          // «всегда включено» — тихой подписью, а не значком.
          if (info.required)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Всегда включено',
                key: ValueKey<String>('extension-required-${info.id}'),
                style: metaStyle(context),
              ),
            )
          else if (!info.builtIn)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'v${info.version} · ${info.author}',
                style: metaStyle(context),
              ),
            ),
          if (onConfigure != null || onRemove != null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (onConfigure != null)
                  TextButton(
                    key: ValueKey<String>('extension-configure-${info.id}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(40, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onConfigure,
                    child: const Text('Настроить'),
                  ),
                if (onRemove != null)
                  TextButton(
                    key: ValueKey<String>('extension-remove-${info.id}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(40, 36),
                      foregroundColor: context.colors.danger,
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
        builder: (dialogContext) => AppDialog(
          scrollable: true,
          title: const WholeWordText('Заменить пак?'),
          content: const Text(
            'Пак с таким id уже установлен. Заменить его новой версией?',
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('pack-replace-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const ActionLabel('Отмена'),
            ),
            FilledButton(
              key: const ValueKey<String>('pack-replace-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const ActionLabel('Заменить'),
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
    return AppDialog(
      contentWidth: 520,
      title: const WholeWordText('Добавить пак'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Вставьте содержимое файла пака (JSON, формат '
                '${PackFormat.format}). Пак — только тексты, он ничего '
                'не выполняет.',
                style: TextStyle(color: context.colors.muted),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey<String>('pack-json'),
                controller: _json,
                minLines: 5,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                style: metaStyle(context).copyWith(
                  color: context.colors.text,
                ),
                decoration: const InputDecoration(
                  hintText: '{"format": "assistant-pack/1", …}',
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
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: context.colors.danger,
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
          child: const ActionLabel('Отмена'),
        ),
        FilledButton(
          key: const ValueKey<String>('pack-import'),
          onPressed: _busy ? null : _import,
          child: const ActionLabel('Добавить'),
        ),
      ],
    );
  }
}
