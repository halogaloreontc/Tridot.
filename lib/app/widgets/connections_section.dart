import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection_directory.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import 'app_consent_sheet.dart' show appHostLabel;
import 'connection_screen.dart';
import 'connections_host.dart';
import 'grouped.dart';
import 'whole_word_text.dart';

/// Подпись строки подключения: «crm.example · Подключён по паролю».
String connectionRowStatus(ConnectionService service) {
  final base = service.record.baseUri ?? service.fixedBase;
  final status = connectionStatus(service);
  return base == null ? status : '${appHostLabel(base)} · $status';
}

/// Раздел «Подключения» во вкладке «Мой Связной → Помощники», рядом с
/// «Ролями» (ADR-039): склад — как раньше (вход и роль «Кладовщик» —
/// там), приложения из каталога — название, адрес, состояние и
/// переключатель; запись, которая не годится в работу, — с причиной и
/// «Удалить»; приложение с новым описанием шире согласия — «Приложение
/// предлагает изменения». Строка ведёт на экран подключения; внизу —
/// «Подключить приложение».
final class ConnectionsSection extends StatefulWidget {
  const ConnectionsSection({super.key, required this.host});

  final ConnectionsHost host;

  @override
  State<ConnectionsSection> createState() => _ConnectionsSectionState();
}

final class _ConnectionsSectionState extends State<ConnectionsSection> {
  final Set<ConnectionService> _followed = <ConnectionService>{};

  ConnectionsHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _host.apps.addListener(_appsChanged);
    _host.registry.addListener(_changed);
    _follow();
  }

  @override
  void didUpdateWidget(ConnectionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host) {
      oldWidget.host.apps.removeListener(_appsChanged);
      oldWidget.host.registry.removeListener(_changed);
      _unfollow();
      _host.apps.addListener(_appsChanged);
      _host.registry.addListener(_changed);
      _follow();
    }
  }

  @override
  void dispose() {
    _host.apps.removeListener(_appsChanged);
    _host.registry.removeListener(_changed);
    _unfollow();
    super.dispose();
  }

  /// Слушать каждое подключение: состояние и предложения в строке.
  void _follow() {
    final live = _host.apps.services.toSet();
    for (final service in _followed.difference(live).toList()) {
      service.removeListener(_changed);
      _followed.remove(service);
    }
    for (final service in live.difference(_followed)) {
      service.addListener(_changed);
      _followed.add(service);
    }
  }

  void _unfollow() {
    for (final service in _followed) {
      service.removeListener(_changed);
    }
    _followed.clear();
  }

  void _appsChanged() {
    _follow();
    _changed();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _note(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
      );

  Future<void> _removeEntry(DirectoryEntry entry) async {
    if (!await confirmRemoveConnection(context, entry.appId) || !mounted) {
      return;
    }
    final clean = await _host.removeEntry(entry.id);
    if (mounted) {
      _note(
        clean
            ? 'Подключение удалено.'
            : 'Подключение снято, но не всё стёрлось с устройства.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final apps = _host.apps;
    final offers = apps.offers;
    final broken = <DirectoryEntry>[
      for (final entry in apps.entries)
        if (apps.byId(entry.id) == null) entry,
    ];
    return InsetGroup(
      key: const ValueKey<String>('connections-section'),
      header: 'Подключения',
      footer: 'Приложения, у которых Связной спрашивает данные. Новые '
          'приложения — только чтение; склад меняет данные лишь с '
          'разрешения в роли «Кладовщик».',
      children: <Widget>[
        for (final service in apps.known) _knownRow(service),
        for (final service in apps.runtime)
          _appRow(service, offered: offers.containsKey(service.slot.id)),
        for (final entry in broken) _brokenRow(entry),
        GroupedRow(
          key: const ValueKey<String>('connections-add'),
          icon: Icons.add,
          title: 'Подключить приложение',
          accent: true,
          onTap: () => unawaited(_host.addApp(context)),
        ),
      ],
    );
  }

  Widget _knownRow(ConnectionService service) => GroupedRow(
        key: ValueKey<String>('connection-row-${service.slot.id}'),
        icon: Icons.inventory_2_outlined,
        title: service.slot.title,
        subtitle: connectionRowStatus(service),
        chevron: true,
        onTap: () => unawaited(_host.open(context, service)),
      );

  Widget _appRow(ConnectionService service, {required bool offered}) {
    final id = service.slot.id;
    final colors = context.colors;
    final enabled = _host.registry.isEnabled(id) ||
        _host.settings().extensionChoice.enabled.contains(id);
    final row = GroupedRow(
      key: ValueKey<String>('connection-row-$id'),
      icon: Icons.hub_outlined,
      title: service.slot.title,
      subtitle: connectionRowStatus(service),
      trailing: Switch(
        key: ValueKey<String>('connection-toggle-$id'),
        value: enabled,
        onChanged: (bool value) => _host.setEnabled(id, value),
      ),
      onTap: () => unawaited(_host.open(context, service)),
    );
    if (!offered) return row;
    return Column(
      key: ValueKey<String>('connection-offered-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        row,
        InkWell(
          onTap: () => unawaited(_host.open(context, service)),
          child: Padding(
            // С той же линии, что заголовок строки ([GroupedRow]).
            padding: const EdgeInsets.fromLTRB(
              AppSpace.rowH + AppSize.iconTile + AppSpace.s,
              0,
              AppSpace.rowH,
              12,
            ),
            child: WholeWordText(
              'Приложение предлагает изменения — подключить заново',
              key: ValueKey<String>('connection-offer-$id'),
              style: TextStyle(fontSize: 13, color: colors.warning),
            ),
          ),
        ),
      ],
    );
  }

  Widget _brokenRow(DirectoryEntry entry) {
    final colors = context.colors;
    return Padding(
      key: ValueKey<String>('connection-broken-${entry.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(Icons.error_outline, size: 22, color: colors.warning),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                WholeWordText(
                  entry.appId,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge!
                      .copyWith(color: colors.textStrong),
                ),
                const SizedBox(height: 4),
                WholeWordText(
                  '${appHostLabel(entry.base)} · не работает: '
                  '${entry.problem ?? 'описание не загрузилось'}',
                  key: ValueKey<String>('connection-problem-${entry.id}'),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium!
                      .copyWith(color: colors.warning),
                ),
              ],
            ),
          ),
          TextButton(
            key: ValueKey<String>('connection-broken-remove-${entry.id}'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: colors.danger,
            ),
            onPressed: () => unawaited(_removeEntry(entry)),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}
