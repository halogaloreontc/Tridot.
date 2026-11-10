import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/connectors/manifest/manifest_format.dart';
import '../assistant_theme.dart';
import 'task_tile.dart';

/// Статус подключения одной строкой: «Подключён: ivanov · под своим
/// логином», «Не подключён».
String connectionStatus(ConnectionService service) {
  final record = service.record;
  final description = service.description;
  String level(String fallback) {
    final name = record.level == ConnectionLevel.staff ? 'staff' : 'shared';
    final label = description?.access[name]?.label ?? '';
    return label.isEmpty ? fallback : label;
  }

  return switch (record.level) {
    ConnectionLevel.none => 'Не подключён',
    ConnectionLevel.shared => 'Подключён ${level('по паролю')}',
    ConnectionLevel.staff => record.login == null
        ? 'Подключён ${level('под своим логином')}'
        : 'Подключён: ${record.login} · ${level('под своим логином')}',
  };
}

/// «05.11.2026 14:05».
String _moment(DateTime? time) {
  if (time == null) return '—';
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Экран «Настройки → Подключения → Склад»: вход по ссылке из окна
/// «Войти на телефоне» или вручную, описание помощника, выход (ADR-011).
///
/// Пароли и ссылка с кодом не хранятся в полях дольше одной попытки:
/// после отправки поля очищаются.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.service,
    required this.onEnabledChanged,
  });

  final ConnectionService service;

  /// Включить подключение после входа и выключить после выхода.
  final ValueChanged<bool> onEnabledChanged;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final TextEditingController _link = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _login = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _staffLogin = TextEditingController();
  final TextEditingController _staffPass = TextEditingController();

  bool _busy = false;
  ConnectionResult? _result;

  /// Где показать итог: под кнопкой, которую нажали (`link`, `manual`,
  /// `staff`, `refresh`), или вверху (`top` — после выхода). На телефоне с
  /// крупным текстом верх экрана далеко от кнопок.
  String _resultAt = 'top';

  ConnectionService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    final base = _service.record.baseUri;
    if (base != null) _address.text = base.toString();
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    for (final controller in <TextEditingController>[
      _link,
      _address,
      _password,
      _login,
      _pass,
      _staffLogin,
      _staffPass,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Сбой хранилища на устройстве: текст без пути и без секретов.
  static const String _storageFailed = 'Не получилось записать данные на '
      'устройстве. Проверьте свободное место и попробуйте ещё раз.';

  /// Итог под кнопкой [at]: его видно там, где нажимали.
  void _show(ConnectionResult result, String at) {
    setState(() {
      _busy = false;
      _result = result;
      _resultAt = at;
    });
  }

  Future<void> _run(
    String at,
    Future<ConnectionResult> Function() action, {
    bool enable = false,
  }) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    ConnectionResult result;
    try {
      result = await action();
    } on ConnectionStorageException catch (error) {
      result = ConnectionResult.failed(error.message);
    } on Object {
      result = const ConnectionResult.failed(_storageFailed);
    } finally {
      // Код из ссылки одноразовый, пароли не держим в полях.
      _link.clear();
      _password.clear();
      _pass.clear();
      _staffPass.clear();
    }
    if (!mounted) return;
    if (result.ok && enable) widget.onEnabledChanged(true);
    _show(result, at);
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        backgroundColor: AssistantColors.raised,
        title: Text('Выйти из «${_service.slot.title}»?'),
        content: const Text(
          'Пароль склада и личный ключ будут удалены с устройства. Адрес '
          'и описание останутся.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('connection-logout-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('connection-logout-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.logout();
    } on ConnectionStorageException catch (error) {
      if (mounted) _show(ConnectionResult.failed(error.message), 'logout');
      return;
    } on Object {
      if (mounted) {
        _show(const ConnectionResult.failed(_storageFailed), 'logout');
      }
      return;
    }
    if (!mounted) return;
    widget.onEnabledChanged(false);
    _show(const ConnectionResult.ok('Вы вышли. Пароль и ключ удалены.'), 'top');
  }

  /// Итог под кнопкой, если нажимали её.
  Widget _message(String at) {
    final result = _result;
    if (result == null || _resultAt != at) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Text(
        result.message,
        key: const ValueKey<String>('connection-message'),
        style: TextStyle(
          color: result.ok ? AssistantColors.success : AssistantColors.danger,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = _service.record;
    final description = _service.description;
    final connected = record.connected;
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.panel,
        title: Text(_service.slot.title),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _status(record),
                  _message('top'),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                  const SectionLabel('Подключить по ссылке'),
                  _linkSection(),
                  const SectionLabel('Ввести вручную'),
                  _manualSection(),
                  if (record.level == ConnectionLevel.shared) ...<Widget>[
                    const SectionLabel('Войти под логином'),
                    _staffSection(),
                  ],
                  const SectionLabel('Описание помощника'),
                  _descriptionSection(record, description),
                  if (connected) ...<Widget>[
                    const SectionLabel('Выход'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('connection-logout'),
                          style: _outlined(AssistantColors.danger),
                          onPressed: _busy ? null : _logout,
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Выйти'),
                        ),
                      ),
                    ),
                  ],
                  // Выйти не вышло: кнопка осталась, итог — под ней.
                  _message('logout'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyle _outlined([Color color = AssistantColors.text]) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(40, 44),
        foregroundColor: color,
        side: const BorderSide(color: AssistantColors.border),
      );

  Widget _status(ConnectionRecord record) {
    final failure = switch (record.failure) {
      ConnectionFailure.offline => 'нет связи с сервером',
      ConnectionFailure.token => 'сервер не принял пароль — подключитесь '
          'заново',
      ConnectionFailure.expired => 'личный ключ устарел — войдите снова',
      ConnectionFailure.server => 'сервер отвечает с ошибками',
      null => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            connectionStatus(_service),
            key: const ValueKey<String>('connection-status'),
            style: const TextStyle(
              color: AssistantColors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (record.baseUri case final Uri base)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text('Адрес: $base', style: technicalTextStyle),
          ),
        if (record.connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: Text(
              'Последний ответ: ${_moment(record.lastOk)}',
              style: technicalTextStyle,
            ),
          ),
        if (record.connected && failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: Text(
              'Сейчас: $failure',
              style: const TextStyle(color: AssistantColors.warning),
            ),
          ),
      ],
    );
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    bool secret = false,
    String? hint,
    TextInputType? keyboard,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        // Подпись над полем, а не в рамке: в рамке на узком экране с
        // крупным текстом «Пароль склада» и «Пароль сотрудника» обрезались
        // до одинакового «Пароль ск…».
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                label,
                key: ValueKey<String>('$key-label'),
                style: const TextStyle(color: AssistantColors.text),
              ),
            ),
            TextField(
              key: ValueKey<String>(key),
              controller: controller,
              obscureText: secret,
              enableSuggestions: !secret,
              autocorrect: false,
              keyboardType: keyboard,
              style: const TextStyle(color: AssistantColors.text),
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      );

  Widget _button(String key, String label, VoidCallback? onPressed) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: ValueKey<String>(key),
            style: _outlined(),
            onPressed: _busy ? null : onPressed,
            child: Text(label),
          ),
        ),
      );

  Widget _linkSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'В складе: «Профиль» → «Войти на телефоне» → «Скопировать '
              'ссылку». Вставьте её сюда. Не сканируйте QR камерой '
              'телефона и не открывайте ссылку в браузере: код одноразовый, '
              'живёт две минуты и сработает только один раз.\n'
              'Кнопка «Скопировать ссылку» есть в складе с версии 1.4.56. '
              'Если её нет — склад старше: подключите его вручную (ниже).',
              style: TextStyle(color: AssistantColors.muted),
            ),
          ),
          _field(
            'connection-link',
            _link,
            'Ссылка входа',
            hint: 'https://…/#qr=…',
            keyboard: TextInputType.url,
          ),
          _button(
            'connection-link-connect',
            'Подключить',
            () => _run(
              'link',
              () => _service.connectByLink(_link.text),
              enable: true,
            ),
          ),
          _message('link'),
        ],
      );

  Widget _manualSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Адрес склада и пароль склада. Логин и пароль сотрудника — '
              'по желанию: без них видны только остатки и ячейки. Пароль '
              'сотрудника не сохраняется — только личный ключ.',
              style: TextStyle(color: AssistantColors.muted),
            ),
          ),
          _field(
            'connection-address',
            _address,
            'Адрес склада',
            hint: 'https://…',
            keyboard: TextInputType.url,
          ),
          _field(
            'connection-password',
            _password,
            'Пароль склада',
            secret: true,
          ),
          _field('connection-login', _login, 'Логин сотрудника'),
          _field('connection-pass', _pass, 'Пароль сотрудника', secret: true),
          _button(
            'connection-manual-connect',
            'Подключить',
            () => _run(
              'manual',
              () => _service.connectManual(
                address: _address.text,
                password: _password.text,
                login: _login.text,
                pass: _pass.text,
              ),
              enable: true,
            ),
          ),
          _message('manual'),
        ],
      );

  Widget _staffSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Приходы видны только под своим логином. Можно и по ссылке '
              'выше.',
              style: TextStyle(color: AssistantColors.muted),
            ),
          ),
          _field('connection-staff-login', _staffLogin, 'Логин сотрудника'),
          _field(
            'connection-staff-pass',
            _staffPass,
            'Пароль сотрудника',
            secret: true,
          ),
          _button(
            'connection-staff-connect',
            'Войти',
            () => _run(
              'staff',
              () => _service.loginStaff(
                login: _staffLogin.text,
                pass: _staffPass.text,
              ),
            ),
          ),
          _message('staff'),
        ],
      );

  Widget _descriptionSection(
    ConnectionRecord record,
    ManifestDescription? description,
  ) {
    final meta = record.manifest;
    final version = description?.version ??
        meta.version ??
        (description == null
            ? '—'
            : 'отпечаток ${description.fingerprint.substring(0, 8)}');
    final examples = <String>[
      for (final command in description?.commands ?? const <ManifestCommand>[])
        if (!command.help && command.examples.isNotEmpty)
          '${command.title}: «${command.examples.first}»',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                description == null
                    ? 'Описания нет'
                    : '${description.appTitle} · команд: '
                        '${description.commands.length}',
                style: const TextStyle(color: AssistantColors.text),
              ),
              Text(
                'Версия описания: $version',
                key: const ValueKey<String>('connection-manifest-version'),
                style: technicalTextStyle,
              ),
              Text(
                record.connected
                    ? 'Проверено: ${_moment(meta.fetchedAt)}'
                    : 'Встроенная копия — до подключения',
                style: technicalTextStyle,
              ),
              // «Наше описание главное» (ADR-012): какое в работе и почему.
              Text(
                'В работе: ${_service.descriptionReason}',
                key: const ValueKey<String>('connection-manifest-origin'),
                style: technicalTextStyle,
              ),
              if (_service.manifestError case final String error)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    key: const ValueKey<String>('connection-manifest-error'),
                    style: const TextStyle(color: AssistantColors.danger),
                  ),
                ),
            ],
          ),
        ),
        if (record.baseUri != null)
          _button(
            'connection-refresh',
            'Обновить описание',
            () => _run('refresh', _service.refreshManifest),
          ),
        _message('refresh'),
        if (examples.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey<String>('connection-examples'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text(
                'Что понимает',
                style: TextStyle(color: AssistantColors.text),
              ),
              children: <Widget>[
                for (final example in examples)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        example,
                        style: const TextStyle(color: AssistantColors.muted),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
