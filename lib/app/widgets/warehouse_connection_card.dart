import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/connectors/manifest/connection.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../assistant_theme.dart';
import 'app_dialog.dart';
import 'connection_screen.dart';
import 'qr_scan_sheet.dart';
import 'whole_word_text.dart';

/// Права склада по-человечески: `moves` → «перемещать товар».
String warehouseRightTitle(String right) => switch (right) {
      'moves' => 'перемещать товар',
      'post' => 'отмечать проведение',
      'price' => 'ставить цены',
      'links' => 'настраивать помощника',
      'users' => 'управлять сотрудниками',
      _ => right,
    };

/// Что видно о правах входа одной строкой: «Можно всё», «Можно:
/// перемещать товар, отмечать проведение», «Только спрашивать».
String warehouseRightsSummary(ConnectionMe me) {
  // `all` склад шлёт и когда роль не прочиталась — роль называем, только
  // если склад её назвал.
  if (me.all) {
    return me.role.isEmpty ? 'Можно всё.' : 'Можно всё: роль «${me.role}».';
  }
  if (me.can.isNotEmpty) {
    return 'Через помощника можно: ${me.can.map(_lowerFirst).join(', ')}.';
  }
  final perms = me.perms;
  if (perms == null) return 'Права склад не назвал.';
  final known = <String>[
    for (final p in perms)
      if (const <String>{'moves', 'post', 'price'}.contains(p))
        warehouseRightTitle(p),
  ];
  return known.isEmpty
      ? 'Через помощника — только спрашивать.'
      : 'Права роли: ${known.join(', ')}.';
}

/// «Переносить товар» → «переносить товар»: название права из середины
/// фразы. Аббревиатуру («QR-код») не трогаем.
String _lowerFirst(String text) {
  if (text.length < 2) return text.toLowerCase();
  final second = text[1];
  if (second.toUpperCase() == second && second.toLowerCase() != second) {
    return text;
  }
  return '${text[0].toLowerCase()}${text.substring(1)}';
}

/// Хост для показа: дефис неразрывный (U+2011) — адрес, который человек
/// сверяет, не переносится по дефису.
String warehouseHostLabel(Uri uri) => uri.host.replaceAll('-', '\u2011');

/// Подтверждение перед входом по ссылке или QR (ADR-031): склад —
/// по хосту из ссылки, сам код не показывается. [current] — нынешнее
/// подключение: новый вход его заменит, и это сказано прямо (другой склад —
/// отдельно). `true` — подключать.
Future<bool> confirmWarehouseLink(
  BuildContext context,
  QrLink link, {
  ConnectionRecord? current,
}) async {
  final host = warehouseHostLabel(link.base);
  final old = current != null && current.connected ? current.baseUri : null;
  final other = old != null && old.host.toLowerCase() != link.base.host;
  final colors = context.colors;
  final yes = await showAppSheet<bool>(
    context: context,
    builder: (BuildContext context) => AppSheet(
      key: const ValueKey<String>('warehouse-link-confirm'),
      icon: Icons.link,
      title: const WholeWordText('Подключить склад?'),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            host,
            key: const ValueKey<String>('warehouse-link-host'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textStrong,
            ),
          ),
          const SizedBox(height: 8),
          const WholeWordText(
            'Связной войдёт на этот склад под логином, который показал '
            'код, и получит его права. Ключ хранится на этом устройстве; '
            'отключить его можно здесь («Выйти») или на складе.',
          ),
          if (old != null) ...<Widget>[
            const SizedBox(height: 8),
            WholeWordText(
              other
                  ? 'Это другой склад: заменит подключение к '
                      '${warehouseHostLabel(old)}, прежний ключ будет снят.'
                  : 'Заменит нынешнее подключение к '
                      '${warehouseHostLabel(old)}: прежний ключ будет снят.',
              key: const ValueKey<String>('warehouse-link-replace'),
              style: TextStyle(
                fontSize: 14,
                color: other ? colors.warning : colors.text,
                fontWeight: other ? FontWeight.w600 : null,
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        DialogCancel(onPressed: () => Navigator.of(context).pop(false)),
        FilledButton(
          key: const ValueKey<String>('warehouse-link-yes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const ActionLabel('Подключить'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// Вход по ссылке [text] после подтверждения: разбор строгий
/// ([ConnectionService.parseQrLink]); ссылка не похожа — текст ошибки.
/// `null` — передумали.
Future<ConnectionResult?> connectWarehouseLink(
  BuildContext context,
  ConnectionService service,
  String text, {
  ValueChanged<bool>? onEnabledChanged,
}) async {
  final QrLink link;
  try {
    link = ConnectionService.parseQrLink(text);
  } on ConnectionAddressException catch (error) {
    return ConnectionResult.failed(error.message);
  }
  if (!context.mounted) return null;
  if (!await confirmWarehouseLink(context, link, current: service.record)) {
    return null;
  }
  final result = await service.connectByLink(text);
  if (result.ok) onEnabledChanged?.call(true);
  return result;
}

/// Карточка подключения склада в «Мой Связной → Помощники → Роли →
/// Кладовщик» (ADR-031, оформление — ADR-027 и компактная поправка):
/// состояние, кто вошёл, права, сигналы; «Сканировать QR», «Вставить
/// ссылку», «Вручную…», «Обновить права», «Выйти».
final class WarehouseConnectionCard extends StatefulWidget {
  const WarehouseConnectionCard({
    super.key,
    required this.service,
    required this.onEnabledChanged,
    this.signal,
    this.showActionsOff = true,
  });

  final ConnectionService service;

  /// Строка «Изменения через помощника выключены на складе»: не нужна,
  /// когда ниже стоит переключатель действий с тем же текстом.
  final bool showActionsOff;

  /// Включить подключение после входа и выключить после выхода.
  final ValueChanged<bool> onEnabledChanged;

  /// Строка сигналов склада («Сегодня 3 прихода · проверено в 14:05»);
  /// `null` — сигналов нет.
  final String? signal;

  @override
  State<WarehouseConnectionCard> createState() =>
      _WarehouseConnectionCardState();
}

final class _WarehouseConnectionCardState
    extends State<WarehouseConnectionCard> {
  bool _busy = false;
  ConnectionResult? _result;

  ConnectionService get _service => widget.service;

  static const String _storageFailed = 'Не получилось записать данные на '
      'устройстве. Проверьте свободное место и попробуйте ещё раз.';

  Future<void> _run(Future<ConnectionResult?> Function() action) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    ConnectionResult? result;
    try {
      result = await action();
    } on ConnectionStorageException catch (error) {
      result = ConnectionResult.failed(error.message);
    } on Object {
      result = const ConnectionResult.failed(_storageFailed);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  Future<void> _scan() async {
    final text = await showQrScanSheet(context);
    if (text != null && mounted) await _connectText(text);
  }

  Future<void> _paste() async {
    final text = await _askLink();
    if (text != null && mounted) await _connectText(text);
  }

  /// Разбор, подтверждение с хостом, затем вход — индикатор только на
  /// время запроса.
  Future<void> _connectText(String text) async {
    final QrLink link;
    try {
      link = ConnectionService.parseQrLink(text);
    } on ConnectionAddressException catch (error) {
      setState(() => _result = ConnectionResult.failed(error.message));
      return;
    }
    if (!await confirmWarehouseLink(context, link, current: _service.record) ||
        !mounted) {
      return;
    }
    await _run(() async {
      final result = await _service.connectByLink(text);
      if (result.ok) widget.onEnabledChanged(true);
      return result;
    });
  }

  /// Окно «Вставить ссылку»: поле с кнопкой «Из буфера». Текст не
  /// сохраняется.
  Future<String?> _askLink() async {
    final text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _LinkDialog(),
    );
    return text == null || text.trim().isEmpty ? null : text.trim();
  }

  Future<void> _manual() => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ConnectionScreen(
            service: _service,
            onEnabledChanged: widget.onEnabledChanged,
          ),
        ),
      );

  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AppDialog(
        key: const ValueKey<String>('warehouse-logout-dialog'),
        icon: Icons.logout,
        title: const WholeWordText('Выйти со склада?'),
        content: const Text(
          'Ключ будет снят на складе и удалён с устройства. Адрес '
          'склада останется — войти снова можно по новому QR.',
        ),
        actions: <Widget>[
          DialogCancel(onPressed: () => Navigator.of(context).pop(false)),
          DialogDanger(
            key: const ValueKey<String>('warehouse-logout-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const ActionLabel('Выйти'),
          ),
        ],
      ),
    );
    if (!(yes ?? false) || !mounted) return;
    await _run(() async {
      await _service.logout();
      widget.onEnabledChanged(false);
      return const ConnectionResult.ok('Вы вышли. Ключ удалён.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final record = _service.record;
    final colors = context.colors;
    final connected = record.connected;
    final (Color dot, String state) = switch ((connected, record.failure)) {
      (false, _) => (colors.faint, 'Не подключён'),
      (true, ConnectionFailure.offline) => (colors.warning, 'Нет связи'),
      (true, ConnectionFailure.token) => (
          colors.danger,
          'Склад не принял вход',
        ),
      (true, ConnectionFailure.expired) => (colors.warning, 'Ключ устарел'),
      (true, ConnectionFailure.server) => (
          colors.warning,
          'Склад отвечает с ошибками',
        ),
      (true, null) => (colors.success, 'Подключён'),
    };
    final me = record.me;
    final who = <String>[
      if (me.name.isNotEmpty)
        '${me.name}${record.login == null ? '' : ' (${record.login})'}'
      else if (record.login case final String login)
        login,
      if (me.role.isNotEmpty) me.role,
    ].join(' · ');
    final meta = metaStyle(context);
    final base = record.baseUri;
    return Container(
      key: const ValueKey<String>('warehouse-connection-card'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: colors.raised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: WholeWordText(
                  base == null ? state : '$state · ${base.host}',
                  key: const ValueKey<String>('warehouse-card-state'),
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.textStrong,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (connected) ...<Widget>[
            const SizedBox(height: 4),
            WholeWordText(
              record.level == ConnectionLevel.staff
                  ? 'Вошли: ${who.isEmpty ? 'сотрудник' : who}'
                  : 'По паролю склада, без логина: видны остатки и ячейки.',
              key: const ValueKey<String>('warehouse-card-who'),
              style: TextStyle(fontSize: 14, color: colors.text),
            ),
            if (record.level == ConnectionLevel.staff) ...<Widget>[
              WholeWordText(
                warehouseRightsSummary(me),
                key: const ValueKey<String>('warehouse-card-rights'),
                style: meta,
              ),
              if (me.actions == false && widget.showActionsOff)
                WholeWordText(
                  'Изменения через помощника выключены на складе.',
                  style: TextStyle(fontSize: 13, color: colors.warning),
                ),
              WholeWordText(
                record.assistKey
                    ? 'Ключ только для помощника: склад целиком им не '
                        'открыть.'
                    : 'Ключ сотрудника полный: склад без обновления '
                        '«Подключить Связного» выдал ключ на всё приложение.',
                key: const ValueKey<String>('warehouse-card-key'),
                style: meta,
              ),
            ],
            if (widget.signal case final String signal)
              WholeWordText(
                signal,
                key: const ValueKey<String>('warehouse-card-signal'),
                style: meta,
              ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: WholeWordText(
                'На складе: «Складской помощник» (значок робота) → '
                '«Показать QR». Отсканируйте код или нажмите на складе '
                '«Открыть в Tridot» — Связной войдёт под вашим логином с '
                'вашими правами.',
                style: meta,
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_result case final ConnectionResult result)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: WholeWordText(
                result.message,
                key: const ValueKey<String>('warehouse-card-message'),
                style: TextStyle(
                  fontSize: 13,
                  color: result.ok ? colors.success : colors.danger,
                ),
              ),
            ),
          const SizedBox(height: 4),
          if (connected) _connectedActions(record) else _firstActions(),
        ],
      ),
    );
  }

  /// Не подключён: главное действие — во всю ширину («Сканировать QR»,
  /// без камеры — «Вставить ссылку»), остальное — одной строкой.
  Widget _firstActions() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 4),
          if (qrScannerAvailable)
            _primary(
              'warehouse-scan',
              Icons.qr_code_scanner,
              'Сканировать QR',
              _scan,
            )
          else
            _primary(
              'warehouse-paste',
              Icons.content_paste,
              'Вставить ссылку',
              _paste,
            ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              if (qrScannerAvailable)
                _button(
                  'warehouse-paste',
                  Icons.content_paste,
                  'Вставить ссылку',
                  _paste,
                ),
              _button('warehouse-manual', Icons.tune, 'Вручную…', _manual),
            ],
          ),
        ],
      );

  /// Подключён: «Новый QR» (если есть камера), «Выйти» и «⋯» — вставить
  /// ссылку, обновить права, подробнее. Одной строкой и на телефоне.
  Widget _connectedActions(ConnectionRecord record) {
    final colors = context.colors;
    final staff = record.level == ConnectionLevel.staff;
    return Row(
      children: <Widget>[
        if (qrScannerAvailable)
          _button('warehouse-scan', Icons.qr_code_scanner, 'Новый QR', _scan),
        const Spacer(),
        _button(
          'warehouse-logout',
          Icons.logout,
          'Выйти',
          _logout,
          color: colors.danger,
        ),
        PopupMenuButton<String>(
          key: const ValueKey<String>('warehouse-more'),
          enabled: !_busy,
          tooltip: 'Ещё',
          icon: const Icon(Icons.more_horiz),
          onSelected: (String value) => switch (value) {
            'paste' => _paste(),
            'refresh' => _run(_service.refreshMe),
            _ => _manual(),
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(
              key: ValueKey<String>('warehouse-paste'),
              value: 'paste',
              child: Text('Вставить ссылку'),
            ),
            if (staff)
              const PopupMenuItem<String>(
                key: ValueKey<String>('warehouse-refresh-me'),
                value: 'refresh',
                child: Text('Обновить права'),
              ),
            const PopupMenuItem<String>(
              key: ValueKey<String>('warehouse-manual'),
              value: 'manual',
              child: Text('Подробнее…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _primary(
    String key,
    IconData icon,
    String label,
    VoidCallback onPressed,
  ) =>
      FilledButton.tonalIcon(
        key: ValueKey<String>(key),
        style: FilledButton.styleFrom(minimumSize: const Size(44, 44)),
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  Widget _button(
    String key,
    IconData icon,
    String label,
    VoidCallback onPressed, {
    Color? color,
  }) =>
      TextButton.icon(
        key: ValueKey<String>(key),
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: color,
        ),
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}

/// Окно «Ссылка склада»: своё поле ввода, живёт столько же, сколько окно.
final class _LinkDialog extends StatefulWidget {
  const _LinkDialog();

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

final class _LinkDialogState extends State<_LinkDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
        key: const ValueKey<String>('warehouse-paste-dialog'),
        scrollable: true,
        title: const WholeWordText('Ссылка склада'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const WholeWordText(
              'На складе: «Складской помощник» → «Подключить Связного» → '
              '«Показать QR» → «Скопировать ссылку». Подходит и ссылка из '
              '«Войти на телефоне».',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey<String>('warehouse-paste-clip'),
                onPressed: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  final copied = clip?.text?.trim() ?? '';
                  if (copied.isNotEmpty && mounted) _controller.text = copied;
                },
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('Из буфера'),
              ),
            ),
            TextField(
              key: const ValueKey<String>('warehouse-paste-field'),
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'tridot://connect?…',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          DialogCancel(onPressed: () => Navigator.of(context).pop()),
          FilledButton(
            key: const ValueKey<String>('warehouse-paste-ok'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const ActionLabel('Дальше'),
          ),
        ],
      );
}
