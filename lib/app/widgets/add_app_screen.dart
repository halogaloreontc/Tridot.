import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/connectors/manifest/app_connections.dart';
import '../../core/connectors/manifest/connection_service.dart';
import '../assistant_theme.dart';
import 'app_consent_sheet.dart';
import 'connections_host.dart';
import 'qr_scan_sheet.dart';
import 'task_tile.dart';
import 'whole_word_text.dart';

/// Экран «Подключить приложение» (ADR-039): адрес (вписать, вставить или
/// QR) → проба описания `<адрес>/assistant.json` → шторка согласия
/// ([showAppConsent]) → «Подключить» → подключение включено и открыт его
/// экран для входа. Без «Подключить» ничего не сохраняется.
///
/// Код из ссылки входа в поле не попадает: в поле — только адрес.
final class AddAppScreen extends StatefulWidget {
  const AddAppScreen({
    super.key,
    required this.host,
    this.address,
    this.loginLink,
    this.probe,
    this.autoProbe = false,
  });

  final ConnectionsHost host;

  /// Адрес в поле (без кода).
  final String? address;

  /// Ссылка входа (входящая): после согласия Связной входит по ней.
  final String? loginLink;

  /// Проба уже сделана — сразу шторка согласия.
  final ProbeResult? probe;

  /// Проверить [address] сразу.
  final bool autoProbe;

  @override
  State<AddAppScreen> createState() => _AddAppScreenState();
}

final class _AddAppScreenState extends State<AddAppScreen> {
  final TextEditingController _address = TextEditingController();
  bool _busy = false;
  ProbeResult? _probe;
  String? _error;

  /// Ссылка входа из поля, QR или входящей ссылки: код в поле не
  /// показывается, но после согласия по ней входим.
  String? _link;

  ConnectionsHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _address.text = widget.address ?? '';
    _link = widget.loginLink;
    final probe = widget.probe;
    if (probe != null) {
      _probe = probe;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_decide(probe));
      });
    } else if (widget.autoProbe && _address.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_check());
      });
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  /// Текст из буфера или QR: ссылка входа — адрес в поле, код запомнить.
  void _take(String text) {
    final trimmed = text.trim();
    if (looksLikeLoginLink(trimmed)) {
      _link = trimmed;
      _address.text = ConnectionService.parseQrLink(trimmed).base.toString();
    } else {
      _link = null;
      _address.text = trimmed;
    }
    setState(() {
      _probe = null;
      _error = null;
    });
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text?.trim() ?? '';
    if (text.isNotEmpty && mounted) _take(text);
  }

  Future<void> _scan() async {
    final text = await showQrScanSheet(
      context,
      title: 'Сканировать QR приложения',
      hint: 'Наведите камеру на QR-код с адресом приложения или ссылкой '
          'входа — распознаётся на устройстве, без сети.',
      notOurs: 'Это не адрес приложения. Нужен QR с адресом https://… или '
          'ссылкой входа.',
      accept: looksLikeAppAddress,
    );
    if (text != null && mounted) _take(text);
  }

  Future<void> _check() async {
    final text = _address.text.trim();
    // Код ссылки — только если адрес в поле тот же, что в ссылке.
    final link = _link;
    if (link != null &&
        ConnectionService.parseQrLink(link).base.toString() != text) {
      _link = null;
    }
    setState(() {
      _busy = true;
      _probe = null;
      _error = null;
    });
    final probe = await _host.apps.probe(_link ?? text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _probe = probe;
    });
    await _decide(probe);
  }

  /// Что дальше по пробе: согласие, знакомое или уже подключённое.
  Future<void> _decide(ProbeResult probe) async {
    if (probe.description == null ||
        probe.knownSlot != null ||
        probe.existingId != null) {
      return;
    }
    if (!await showAppConsent(context, probe) || !mounted) return;
    setState(() => _busy = true);
    final ({ConnectionService service, List<String> warnings}) added;
    try {
      added = await _host.apps.add(probe);
    } on AppConnectionException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
      return;
    }
    final service = added.service;
    _host.setEnabled(service.slot.id, true);
    ConnectionResult? result;
    if (_link case final String link) {
      result = await service.connectByLink(link);
      if (result.ok) _host.setEnabled(service.slot.id, true);
    }
    if (!mounted) return;
    await _host.open(context, service, replace: true, initialResult: result);
  }

  Future<void> _openKnown(ProbeResult probe) async {
    final slot = probe.knownSlot!;
    final service = _host.apps.byId(slot.id);
    if (service == null) return;
    await _host.open(context, service, replace: true);
  }

  Future<void> _openExisting(String id) async {
    final service = _host.apps.byId(id);
    if (service == null) return;
    await _host.open(context, service, replace: true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final probe = _probe;
    return Scaffold(
      backgroundColor: colors.workspace,
      appBar: AppBar(
        backgroundColor: colors.workspace,
        title: const Text('Подключить приложение'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: WholeWordText(
                      'Адрес приложения, у которого есть описание для '
                      'помощника (assistant.json). Сначала Связной покажет, '
                      'что оно умеет, — подключится только после '
                      '«Подключить».',
                      style: TextStyle(color: colors.muted),
                    ),
                  ),
                  const SectionLabel('Адрес'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      key: const ValueKey<String>('add-app-address'),
                      controller: _address,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _busy ? null : unawaited(_check()),
                      onChanged: (_) {
                        if (_probe != null || _error != null) {
                          setState(() {
                            _probe = null;
                            _error = null;
                          });
                        }
                      },
                      style: TextStyle(color: colors.text),
                      decoration: const InputDecoration(
                        hintText: 'https://…',
                        isDense: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                    child: Wrap(
                      spacing: 8,
                      children: <Widget>[
                        _textButton(
                          'add-app-paste',
                          Icons.content_paste,
                          'Вставить ссылку',
                          _paste,
                        ),
                        if (qrScannerAvailable)
                          _textButton(
                            'add-app-scan',
                            Icons.qr_code_scanner,
                            'Сканировать QR',
                            _scan,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                        key: const ValueKey<String>('add-app-next'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _busy ? null : () => unawaited(_check()),
                        child: const Text('Дальше'),
                      ),
                    ),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 16, 8, 0),
                      child: LinearProgressIndicator(),
                    ),
                  if (_error case final String error)
                    _note('add-app-error', error, colors.danger),
                  if (probe != null && !_busy) ..._outcome(probe),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _outcome(ProbeResult probe) {
    final colors = context.colors;
    if (probe.knownSlot case final slot?) {
      return <Widget>[
        _note(
          'add-app-known',
          'По этому адресу — ${slot.title.toLowerCase()}. Он подключается '
              'своей строкой в «Подключениях», с прежним входом.',
          colors.text,
        ),
        if (_host.apps.byId(slot.id) != null)
          _action(
            'add-app-open-known',
            'Открыть подключение: ${slot.title}',
            () => unawaited(_openKnown(probe)),
          ),
      ];
    }
    if (probe.existingId case final String id) {
      final service = _host.apps.byId(id);
      return <Widget>[
        _note(
          'add-app-existing',
          'Это приложение уже подключено'
              '${service == null ? '' : ': «${service.slot.title}»'}.',
          colors.text,
        ),
        if (service != null)
          _action(
            'add-app-open-existing',
            'Открыть подключение',
            () => unawaited(_openExisting(id)),
          ),
      ];
    }
    if (probe.description == null) {
      return <Widget>[
        for (final problem in probe.problems)
          _note('add-app-problem', problem, colors.danger),
      ];
    }
    // Описание есть, согласие закрыли «Отменой»: показать ещё раз.
    return <Widget>[
      _note(
        'add-app-ready',
        probe.canAdd
            ? 'Описание получено. Ничего не сохранено.'
            : 'Подключить это приложение нельзя: ${probe.problems.join(' ')}',
        probe.canAdd ? colors.muted : colors.danger,
      ),
      _action(
        'add-app-review',
        'Посмотреть, что оно умеет',
        () => unawaited(_decide(probe)),
      ),
    ];
  }

  Widget _note(String key, String text, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        child: WholeWordText(
          text,
          key: ValueKey<String>(key),
          style: TextStyle(color: color),
        ),
      );

  Widget _action(String key, String label, VoidCallback onPressed) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: ValueKey<String>(key),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: context.colors.accent,
            ),
            onPressed: _busy ? null : onPressed,
            child: Text(label),
          ),
        ),
      );

  Widget _textButton(
    String key,
    IconData icon,
    String label,
    VoidCallback onPressed,
  ) =>
      TextButton.icon(
        key: ValueKey<String>(key),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}
