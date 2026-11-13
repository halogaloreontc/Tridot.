import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/extensions/extension_registry.dart';
import '../../core/settings/app_settings.dart';
import '../assistant_theme.dart';
import 'connection_screen.dart';
import 'extensions_section.dart' show connectionChanged;
import 'task_tile.dart';

/// Раздел «Роли» в настройках, над «Расширениями» (ADR-012): карточка на
/// роль — название, описание, что входит, переключатель, а у роли с
/// подключением — статус и «Подключить склад». Кто отвечает на фразы
/// навыков роли, задают обязанности помощников (ADR-016), а не роль.
///
/// Выбор живёт в [AppSettings] (`enabled_roles`, `disabled_roles`);
/// применяет его владелец экрана — сразу, без перезапуска.
/// Выключенная роль прячет свои навыки и кнопки, но подключение и секреты
/// остаются: включённая снова роль работает без нового входа.
class RolesSection extends StatefulWidget {
  const RolesSection({
    super.key,
    required this.registry,
    required this.settings,
    required this.onChanged,
    this.connections = const <ConnectionService>[],
  });

  final ExtensionRegistry registry;
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final List<ConnectionService> connections;

  @override
  State<RolesSection> createState() => _RolesSectionState();
}

class _RolesSectionState extends State<RolesSection> {
  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_changed);
    for (final connection in widget.connections) {
      connection.addListener(_changed);
    }
  }

  @override
  void didUpdateWidget(RolesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    widget.registry.removeListener(_changed);
    for (final connection in widget.connections) {
      connection.removeListener(_changed);
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  ExtensionChoice get _choice => widget.settings.extensionChoice;

  void _set(ExtensionChoice choice) =>
      widget.onChanged(widget.settings.withChoice(choice));

  ConnectionService? _connection(String id) => widget.connections
      .where((ConnectionService c) => c.slot.id == id)
      .firstOrNull;

  Future<void> _connect(ConnectionService service) =>
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
                  service.slot.id,
                  connected: value,
                ),
              );
            },
          ),
        ),
      );

  /// «Задачи, Калькулятор, Беседа»: только расширения этой сборки, под
  /// теми же названиями, что в «Расширениях» и в «что умеешь».
  String _includes(RoleInfo role) => <String>[
        for (final id in role.extensions)
          if (widget.registry.info(id) != null) widget.registry.skillTitle(id),
      ].join(', ');

  /// Роль включена, а её навык выключен в «Расширениях»: сказать прямо,
  /// иначе карточка выглядит рабочей, а кнопки и ответы пропали.
  String? _switchedOff(RoleInfo role) {
    final off = widget.registry.switchedOff(role, _choice);
    if (off.isEmpty) return null;
    final names = off.map((ExtensionInfo e) => '«${e.title}»').join(', ');
    return off.length == 1
        ? 'Навык $names выключен в «Расширениях» — роль им не пользуется: '
            'его кнопок и ответов нет. Включите его там.'
        : 'Навыки $names выключены в «Расширениях» — роль ими не '
            'пользуется: их кнопок и ответов нет. Включите их там.';
  }

  /// «Разрешить действия» (ADR-013): перемещение и отметка проведения от
  /// имени логина подключения. Выключено по умолчанию; включается
  /// диалогом, только под своим логином и при включённой роли; любая
  /// смена входа снимает разрешение.
  Widget _actionsSwitch(
    RoleInfo role,
    ConnectionService service, {
    required bool on,
  }) {
    final record = service.record;
    final login = record.login;
    final staff = service.connected &&
        record.level == ConnectionLevel.staff &&
        login != null &&
        login.isNotEmpty;
    final allowed = _choice.roleActions[role.id];
    final value = staff &&
        allowed != null &&
        allowed.toLowerCase() == login.toLowerCase();
    final String subtitle;
    if (value) {
      subtitle = 'Действия от имени $login. Каждое — только после '
          '«Подтвердить» на карточке.';
    } else if (!on) {
      subtitle = 'Сначала включите роль.';
    } else if (!staff) {
      subtitle = 'Нужен вход под своим логином: «Настроить» → войти по '
          'ссылке или логином.';
    } else {
      subtitle = 'Перемещать товар между ячейками и отмечать проведение '
          'прихода — после «Подтвердить» на каждой карточке.';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SwitchListTile(
        key: ValueKey<String>('role-actions-${role.id}'),
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: on && staff
            ? (bool next) async {
                if (!next) {
                  _set(_choice.withActions(role.id, null));
                  return;
                }
                final yes = await _confirmActions(login);
                if (yes && mounted) _set(_choice.withActions(role.id, login));
              }
            : null,
        title: const Text(
          'Разрешить действия',
          style: TextStyle(color: AssistantColors.textStrong),
        ),
        subtitle: Text(
          subtitle,
          key: ValueKey<String>('role-actions-note-${role.id}'),
          style: const TextStyle(color: AssistantColors.muted),
        ),
      ),
    );
  }

  Future<bool> _confirmActions(String login) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const Key('role-actions-dialog'),
        title: const Text('Разрешить действия?'),
        content: Text(
          'Помощник сможет перемещать товар и отмечать проведение от имени '
          '$login, с правами этой учётной записи. Каждое действие — только '
          'после «Подтвердить».',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('role-actions-no'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('role-actions-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final roles = widget.registry.roles;
    return Column(
      key: const ValueKey<String>('roles-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Роли'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Роль — набор навыков и кнопок для сферы работы. Включайте '
            'одну или несколько; подключения и пароли при выключении '
            'остаются.',
            style: technicalTextStyle,
          ),
        ),
        for (final role in roles) _card(role),
      ],
    );
  }

  Widget _card(RoleInfo role) {
    final choice = _choice;
    final on = choice.isRoleEnabled(role);
    final link = role.connection;
    final service = link == null ? null : _connection(link.extensionId);
    return Container(
      key: ValueKey<String>('role-card-${role.id}'),
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: on ? AssistantColors.border : AssistantColors.borderSoft,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: ValueKey<String>('role-${role.id}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            value: on,
            onChanged: (bool value) => _set(choice.withRole(role, value)),
            title: Text(
              role.title,
              style: const TextStyle(
                color: AssistantColors.textStrong,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                role.description,
                style: const TextStyle(color: AssistantColors.muted),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Входит: ${_includes(role)}',
                  key: ValueKey<String>('role-includes-${role.id}'),
                  style: technicalTextStyle,
                ),
                if (role.chips.isNotEmpty)
                  Text(
                    'Кнопки: ${role.chips.map((RoleChip c) => '«${c.label}»').join(', ')}',
                    style: technicalTextStyle,
                  ),
                if (on)
                  if (_switchedOff(role) case final String note)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        note,
                        key: ValueKey<String>('role-off-${role.id}'),
                        style: const TextStyle(color: AssistantColors.warning),
                      ),
                    ),
                if (link != null && service != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    service.connected
                        ? connectionStatus(service)
                        : link.notConnectedLabel,
                    key: ValueKey<String>('role-status-${role.id}'),
                    style: TextStyle(
                      color: service.connected
                          ? AssistantColors.text
                          : AssistantColors.warning,
                    ),
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    key: ValueKey<String>('role-connect-${role.id}'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(40, 44),
                      foregroundColor: AssistantColors.text,
                      side: const BorderSide(color: AssistantColors.border),
                    ),
                    onPressed: () => _connect(service),
                    icon: Icon(
                      service.connected ? Icons.tune : Icons.link,
                      size: 18,
                    ),
                    label: Text(
                      service.connected ? 'Настроить' : link.connectLabel,
                    ),
                  ),
                  if (role.actionHint != null)
                    _actionsSwitch(role, service, on: on),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
