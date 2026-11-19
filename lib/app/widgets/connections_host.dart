import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectors/manifest/app_connections.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import 'add_app_screen.dart';
import 'connection_screen.dart';
import 'extensions_section.dart' show connectionChanged;

/// Что экранам подключений нужно от владельца (ADR-039): каталог
/// подключений, реестр расширений и настройки. Один на `HomePage`: им
/// пользуются список «Подключения», «Подключить приложение», меню и
/// входящие ссылки.
///
/// Включено ли приложение — выбор в настройках ([ExtensionChoice]),
/// сохраняется так же, как другие переключатели расширений.
final class ConnectionsHost {
  ConnectionsHost({
    required this.apps,
    required this.registry,
    required this.settings,
    required this.onChanged,
  });

  final AppConnections apps;
  final ExtensionRegistry registry;

  /// Настройки сейчас (а не на момент создания).
  final AppSettings Function() settings;
  final ValueChanged<AppSettings> onChanged;

  /// Включить или выключить подключение [id]. Реестр ещё не пересобран
  /// (ход диалога не кончился) — выбор всё равно сохраняется: реестр
  /// возьмёт его после пересборки.
  void setEnabled(String id, bool value) {
    final current = settings();
    if (registry.info(id) != null) {
      onChanged(connectionChanged(registry, current, id, connected: value));
      return;
    }
    final c = current.extensionChoice;
    onChanged(
      current.withChoice(
        ExtensionChoice(
          disabled: <String>{...c.disabled}..remove(id),
          enabled: value
              ? <String>{...c.enabled, id}
              : (<String>{...c.enabled}..remove(id)),
          disabledRoles: c.disabledRoles,
          enabledRoles: c.enabledRoles,
          roleOwners: c.roleOwners,
          roleActions: c.roleActions,
        ),
      ),
    );
  }

  /// Удаляет приложение [service] из каталога (выход, секреты, файлы) и
  /// его след в выборе расширений. `false` — что-то не стёрлось.
  Future<bool> remove(ConnectionService service) async {
    final id = service.slot.id;
    final clean = await apps.remove(id);
    final current = settings();
    onChanged(current.withChoice(current.extensionChoice.without(id)));
    return clean;
  }

  /// Удаляет запись каталога [id], у которой нет подключения (профиль не
  /// прошёл проверку).
  Future<bool> removeEntry(String id) async {
    final clean = await apps.remove(id);
    final current = settings();
    onChanged(current.withChoice(current.extensionChoice.without(id)));
    return clean;
  }

  /// Экран подключения [service]: у приложения из каталога — «Удалить» и
  /// «Подключить заново». [replace] — вместо текущего экрана.
  Future<void> open(
    BuildContext context,
    ConnectionService service, {
    bool replace = false,
    ConnectionResult? initialResult,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final runtime = service.slot.runtime;
    final route = MaterialPageRoute<void>(
      builder: (BuildContext screen) => ConnectionScreen(
        service: service,
        initialResult: initialResult,
        onEnabledChanged: (bool value) => setEnabled(service.slot.id, value),
        onRemove: runtime
            ? () async {
                final clean = await remove(service);
                if (!clean) {
                  messenger?.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Подключение снято, но не всё стёрлось с '
                        'устройства — проверьте свободное место и права на '
                        'папку.',
                      ),
                    ),
                  );
                }
                return clean;
              }
            : null,
        // Кнопка видна, только пока приложение предлагает изменения.
        onReconnect:
            runtime ? () => unawaited(_reconnect(screen, service)) : null,
      ),
    );
    final navigator = Navigator.of(context);
    return replace ? navigator.pushReplacement(route) : navigator.push(route);
  }

  /// «Подключить заново»: подтверждение, удаление и новое согласие по
  /// тому же адресу.
  Future<void> _reconnect(
    BuildContext context,
    ConnectionService service,
  ) async {
    if (!await confirmRemoveConnection(context, service.slot.title) ||
        !context.mounted) {
      return;
    }
    final base = service.fixedBase ?? service.record.baseUri;
    await remove(service);
    if (!context.mounted) return;
    await addApp(
      context,
      address: base?.toString(),
      replace: true,
      autoProbe: base != null,
    );
  }

  /// Экран «Подключить приложение». [address] — адрес в поле (без кода
  /// входа); [loginLink] — ссылка входа, которой войти сразу после
  /// согласия; [probe] — проба уже сделана (входящая ссылка).
  Future<void> addApp(
    BuildContext context, {
    String? address,
    String? loginLink,
    ProbeResult? probe,
    bool replace = false,
    bool autoProbe = false,
  }) {
    final route = MaterialPageRoute<void>(
      builder: (BuildContext context) => AddAppScreen(
        host: this,
        address: address,
        loginLink: loginLink,
        probe: probe,
        autoProbe: autoProbe,
      ),
    );
    final navigator = Navigator.of(context);
    return replace ? navigator.pushReplacement(route) : navigator.push(route);
  }
}
