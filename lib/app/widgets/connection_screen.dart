import 'package:flutter/material.dart';

import '../../core/connectors/manifest/app_profile.dart';
import '../../core/connectors/manifest/connection.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../../core/connectors/manifest/connection_texts.dart';
import '../../core/connectors/manifest/manifest_format.dart';
import '../assistant_theme.dart';
import 'task_tile.dart';
import 'whole_word_text.dart';
import 'app_dialog.dart';

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

  // Род — по профилю приложения (ADR-043): «Касса подключена». Склад и
  // несклоняемые имена — «подключён», как раньше.
  final profile = service.slot.profile;
  final on =
      switch (profile != null && profile.declinable ? profile.gender : null) {
    AppGender.f => 'Подключена',
    AppGender.n => 'Подключено',
    AppGender.pl => 'Подключены',
    _ => 'Подключён',
  };
  final off = 'Не ${on.toLowerCase()}';
  return switch (record.level) {
    ConnectionLevel.none => off,
    ConnectionLevel.shared => '$on ${level('по паролю')}',
    ConnectionLevel.staff => record.login == null
        ? '$on ${level('под своим логином')}'
        : '$on: ${record.login} · ${level('под своим логином')}',
  };
}

/// Подтверждение «Удалить подключение» к [title] (ADR-043). `true` —
/// удалить.
Future<bool> confirmRemoveConnection(BuildContext context, String title) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AppDialog(
      key: const ValueKey<String>('connection-remove-dialog'),
      icon: Icons.delete_outline,
      title: WholeWordText('Удалить «$title»?'),
      content: const WholeWordText(
        'Связной выйдет из приложения и удалит с устройства пароль, ключи, '
        'адрес и описание. Отменить нельзя — подключить снова можно с '
        'новым согласием.',
      ),
      actions: <Widget>[
        DialogCancel(onPressed: () => Navigator.of(context).pop(false)),
        DialogDanger(
          key: const ValueKey<String>('connection-remove-yes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const ActionLabel('Удалить'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// «05.11.2026 14:05».
String _moment(DateTime? time) {
  if (time == null) return '—';
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Экран «Подробнее» карточки склада (ADR-031): вход по ссылке из окна
/// «Войти на телефоне» или вручную, описание помощника, выход (ADR-011).
///
/// Пароли и ссылка с кодом не хранятся в полях дольше одной попытки:
/// после отправки поля очищаются.
///
/// Тот же экран — у приложения из каталога подключений (ADR-043): тексты
/// с его именем ([ConnectionService.texts]), вход — каким умеет описание
/// (ссылка, пароль, логин), адрес закреплён; «Удалить» и «Подключить
/// заново», если приложение предлагает изменения. У склада всё прежнее.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.service,
    required this.onEnabledChanged,
    this.onRemove,
    this.onReconnect,
    this.initialResult,
  });

  final ConnectionService service;

  /// Включить подключение после входа и выключить после выхода.
  final ValueChanged<bool> onEnabledChanged;

  /// «Удалить подключение» (после подтверждения): `true` — с устройства
  /// стёрлось всё. `null` — кнопки нет (склад).
  final Future<bool> Function()? onRemove;

  /// «Подключить заново» у приложения, которое предлагает изменения:
  /// удалить и подключить по тому же адресу с новым согласием. `null` —
  /// кнопки нет.
  final VoidCallback? onReconnect;

  /// Итог, с которым экран открылся (вход по ссылке сразу после
  /// подключения).
  final ConnectionResult? initialResult;

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

  ConnectionTexts get _texts => _service.texts;

  /// Приложение из каталога (не слот из кода).
  bool get _runtime => _service.slot.runtime;

  /// Вход по ссылке: склад — всегда (встроенный вход), приложение — если
  /// его описание умеет.
  bool get _canLink =>
      !_runtime ||
      _service.description?.qr != null ||
      _service.anchor?.qr != null;

  /// Вход под логином сотрудника: склад — всегда, приложение — если
  /// описание умеет выдать личный ключ.
  bool get _canStaff =>
      !_runtime ||
      _service.description?.credentials['sid']?.get != null ||
      _service.anchor?.credentials['sid']?.get != null;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    final base = _service.record.baseUri ?? _service.fixedBase;
    if (base != null) _address.text = base.toString();
    _result = widget.initialResult;
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
    // Итог под кнопкой: на узком экране и крупном шрифте он может уйти за
    // нижний край — докручиваем до него.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _messageKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 150),
      );
    });
  }

  final GlobalKey _messageKey = GlobalKey();

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
      builder: (dialogContext) => AppDialog(
        scrollable: true,
        title: WholeWordText('Выйти из «${_service.slot.title}»?'),
        content: Text(_texts.logoutBody),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('connection-logout-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('connection-logout-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const ActionLabel('Выйти'),
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
      key: _messageKey,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Text(
        result.message,
        key: const ValueKey<String>('connection-message'),
        style: TextStyle(
          color: result.ok ? context.colors.success : context.colors.danger,
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
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
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
                  if (_service.offered case final String offered)
                    if (_runtime) _offer(offered),
                  if (_canLink) ...<Widget>[
                    const SectionLabel('Подключить по ссылке'),
                    _linkSection(),
                  ],
                  const SectionLabel('Ввести вручную'),
                  _manualSection(),
                  if (record.level == ConnectionLevel.shared &&
                      _canStaff) ...<Widget>[
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
                          style: _outlined(context, context.colors.danger),
                          onPressed: _busy ? null : _logout,
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Выйти'),
                        ),
                      ),
                    ),
                  ],
                  // Выйти не вышло: кнопка осталась, итог — под ней.
                  _message('logout'),
                  if (widget.onRemove != null) ...<Widget>[
                    const SectionLabel('Удалить подключение'),
                    _removeSection(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyle _outlined(BuildContext context, [Color? color]) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: color ?? context.colors.accent,
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
            style: TextStyle(
              color: context.colors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (record.baseUri case final Uri base)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text('Адрес: $base', style: metaStyle(context)),
          ),
        if (record.connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              'Последний ответ: ${_moment(record.lastOk)}',
              style: metaStyle(context),
            ),
          ),
        if (record.connected && failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              'Сейчас: $failure',
              style: TextStyle(color: context.colors.warning),
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
    bool readOnly = false,
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
                style: TextStyle(color: context.colors.text),
              ),
            ),
            TextField(
              key: ValueKey<String>(key),
              controller: controller,
              obscureText: secret,
              readOnly: readOnly,
              enableSuggestions: !secret,
              autocorrect: false,
              keyboardType: keyboard,
              style: TextStyle(color: context.colors.text),
              decoration: InputDecoration(
                hintText: hint,
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
            style: _outlined(context),
            onPressed: _busy ? null : onPressed,
            child: Text(label),
          ),
        ),
      );

  Widget _linkSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              _texts.linkHint,
              style: TextStyle(color: context.colors.muted),
            ),
          ),
          _field(
            'connection-link',
            _link,
            'Ссылка входа',
            hint: 'tridot://connect?… или https://…/#qr=…',
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
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              _texts.manualHint(staff: _canStaff),
              style: TextStyle(color: context.colors.muted),
            ),
          ),
          _field(
            'connection-address',
            _address,
            _texts.addressLabel,
            hint: 'https://…',
            keyboard: TextInputType.url,
            // Адрес приложения из каталога закреплён (ADR-043).
            readOnly: _service.fixedBase != null,
          ),
          _field(
            'connection-password',
            _password,
            _texts.passwordLabel(
              (_service.description ?? _service.anchor)
                  ?.credentials['token']
                  ?.label,
            ),
            secret: true,
          ),
          if (_canStaff) ...<Widget>[
            _field('connection-login', _login, 'Логин сотрудника'),
            _field(
              'connection-pass',
              _pass,
              'Пароль сотрудника',
              secret: true,
            ),
          ],
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
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              _texts.staffHint,
              style: TextStyle(color: context.colors.muted),
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

  /// Приложение предлагает изменения, которые без нового согласия не
  /// приняты (ADR-043): что именно и «Подключить заново».
  Widget _offer(String offered) => Padding(
        key: const ValueKey<String>('connection-offer'),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            WholeWordText(
              'Приложение предлагает изменения — подключить заново',
              style: TextStyle(
                color: context.colors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: WholeWordText(
                'В новом описании: $offered. Пока в работе прежнее — то, на '
                'что вы согласились. Чтобы принять новое, подключите '
                'приложение заново: снова покажем, что оно умеет.',
                style: metaStyle(context),
              ),
            ),
            if (widget.onReconnect case final VoidCallback reconnect)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const ValueKey<String>('connection-reconnect'),
                    style: _outlined(context),
                    onPressed: _busy ? null : reconnect,
                    child: const Text('Подключить заново'),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _removeSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: WholeWordText(
              'Выход на сервере, затем с устройства удаляются пароль, ключи, '
              'адрес и описание. Подключить снова можно через «Подключить '
              'приложение».',
              style: TextStyle(color: context.colors.muted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('connection-remove'),
                style: _outlined(context, context.colors.danger),
                onPressed: _busy ? null : _remove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Удалить'),
              ),
            ),
          ),
          _message('remove'),
        ],
      );

  Future<void> _remove() async {
    final remove = widget.onRemove;
    if (remove == null) return;
    if (!await confirmRemoveConnection(context, _service.slot.title) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    bool clean;
    try {
      clean = await remove();
    } on Object {
      clean = false;
    }
    if (!mounted) return;
    widget.onEnabledChanged(false);
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      // Итог (не всё стёрлось) показывает тот, кто удалял.
      navigator.pop();
    } else {
      _show(
        ConnectionResult.ok(
          clean ? 'Подключение удалено.' : 'Подключение снято.',
        ),
        'remove',
      );
    }
  }

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
                style: TextStyle(color: context.colors.text),
              ),
              Text(
                'Версия описания: $version',
                key: const ValueKey<String>('connection-manifest-version'),
                style: metaStyle(context),
              ),
              Text(
                record.connected
                    ? 'Проверено: ${_moment(meta.fetchedAt)}'
                    : _texts.beforeConnect,
                style: metaStyle(context),
              ),
              // «Наше описание главное» (ADR-012): какое в работе и почему.
              Text(
                'В работе: ${_service.descriptionReason}',
                key: const ValueKey<String>('connection-manifest-origin'),
                style: metaStyle(context),
              ),
              if (_service.manifestError case final String error)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    key: const ValueKey<String>('connection-manifest-error'),
                    style: TextStyle(color: context.colors.danger),
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
              title: Text(
                'Что понимает',
                style: TextStyle(color: context.colors.text),
              ),
              children: <Widget>[
                for (final example in examples)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        example,
                        style: TextStyle(color: context.colors.muted),
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
