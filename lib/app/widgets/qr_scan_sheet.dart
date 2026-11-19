import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/connectors/manifest/connection_service.dart';
import '../../core/jobs/extension_forms.dart';
import '../assistant_theme.dart';
import '../jobs/job_picker.dart';
import 'app_dialog.dart';
import 'whole_word_text.dart';

/// Камера есть только на телефоне и Mac: там сканер встроенный
/// (`mobile_scanner`, распознавание на устройстве без сети, ADR-031).
bool get qrScannerAvailable {
  final platform = currentJobPlatform();
  return platform == JobPlatform.android || platform == JobPlatform.macos;
}

/// Годится ли текст из QR: ссылка «Открыть в Tridot» или ссылка входа
/// `https://…#qr=`. Разбор целиком — [ConnectionService.parseQrLink].
bool looksLikeLoginLink(String? text) {
  if (text == null || text.length > 2048) return false;
  try {
    ConnectionService.parseQrLink(text);
    return true;
  } on ConnectionAddressException {
    return false;
  }
}

/// Текст QR-кода на картинке [path] (снимок экрана из «Поделиться»);
/// `null` — кода нет или сканера на этой платформе нет.
Future<String?> decodeQrImage(String path) async {
  if (!qrScannerAvailable) return null;
  final controller = MobileScannerController(autoStart: false);
  try {
    final capture = await controller.analyzeImage(
      path,
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    );
    for (final code in capture?.barcodes ?? const <Barcode>[]) {
      final raw = code.rawValue?.trim();
      if (looksLikeLoginLink(raw)) return raw;
    }
    return null;
  } on Object {
    return null;
  } finally {
    unawaited(controller.dispose());
  }
}

/// Годится ли текст из QR для «Подключить приложение» (ADR-039): ссылка
/// входа ([looksLikeLoginLink]) или адрес приложения `https://…`.
bool looksLikeAppAddress(String? text) {
  if (text == null || text.length > 2048) return false;
  if (looksLikeLoginLink(text)) return true;
  final trimmed = text.trim();
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)) {
    return false;
  }
  try {
    ConnectionService.baseOf(trimmed);
    return true;
  } on ConnectionAddressException {
    return false;
  }
}

/// Шторка «Сканировать QR» (ADR-031): камера, «Из картинки» (снимок
/// экрана с кодом) и честное «нет доступа к камере». Возвращает текст
/// ссылки из кода — только годный ([accept], по умолчанию
/// [looksLikeLoginLink]); `null` — закрыли. Сама ничего не подключает:
/// подтверждение и вход — у вызывающего. [title], [hint] и [notOurs] —
/// тексты шторки; по умолчанию — склада.
Future<String?> showQrScanSheet(
  BuildContext context, {
  String? title,
  String? hint,
  String? notOurs,
  bool Function(String? text)? accept,
}) =>
    showAppSheet<String>(
      context: context,
      builder: (BuildContext context) => QrScanSheet(
        title: title,
        hint: hint,
        notOurs: notOurs,
        accept: accept,
      ),
    );

final class QrScanSheet extends StatefulWidget {
  const QrScanSheet({
    super.key,
    this.title,
    this.hint,
    this.notOurs,
    this.accept,
  });

  /// Заголовок; `null` — «Сканировать QR склада».
  final String? title;

  /// Пояснение над камерой; `null` — где взять QR на складе.
  final String? hint;

  /// Код не тот; `null` — «Это не код склада…».
  final String? notOurs;

  /// Годится ли текст кода; `null` — [looksLikeLoginLink].
  final bool Function(String? text)? accept;

  @override
  State<QrScanSheet> createState() => _QrScanSheetState();
}

final class _QrScanSheetState extends State<QrScanSheet> {
  MobileScannerController? _controller;
  String? _problem;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (qrScannerAvailable) {
      _controller = MobileScannerController(
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  void _found(Iterable<Barcode> codes) {
    if (_done) return;
    for (final code in codes) {
      final raw = code.rawValue?.trim();
      if ((widget.accept ?? looksLikeLoginLink)(raw)) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
    if (codes.isNotEmpty && mounted) {
      setState(
        () => _problem = widget.notOurs ??
            'Это не код склада. Нужен QR со склада: '
                '«Складской помощник» → «Показать QR».',
      );
    }
  }

  Future<void> _fromImage() async {
    final controller = _controller;
    if (controller == null) return;
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Картинки',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
          uniformTypeIdentifiers: <String>['public.image'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    try {
      final capture = await controller.analyzeImage(
        file.path,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        setState(() => _problem = 'На картинке нет QR-кода.');
        return;
      }
      _found(capture.barcodes);
    } on Object {
      if (mounted) {
        setState(() => _problem = 'Картинку не получилось прочитать.');
      }
    }
  }

  Widget _error(BuildContext context, MobileScannerException error) {
    final text = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Нет доступа к камере. Разрешите его в настройках системы для '
            'Tridot — или выберите снимок экрана с кодом.',
      MobileScannerErrorCode.unsupported =>
        'На этом устройстве камера недоступна. Выберите снимок экрана с '
            'кодом или вставьте ссылку.',
      _ => 'Камера не включилась. Закройте окно и попробуйте ещё раз — или '
          'выберите снимок экрана с кодом.',
    };
    return ColoredBox(
      color: context.colors.panel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: WholeWordText(
            text,
            key: const ValueKey<String>('qr-scan-denied'),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.colors.text),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return AppSheet(
      key: const ValueKey<String>('qr-scan-sheet'),
      icon: Icons.qr_code_scanner,
      title: WholeWordText(widget.title ?? 'Сканировать QR склада'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          WholeWordText(
            widget.hint ??
                'На складе: «Складской помощник» → «Показать QR». Наведите '
                    'камеру на код — распознаётся на устройстве, без сети.',
          ),
          const SizedBox(height: 12),
          if (controller != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: MobileScanner(
                  key: const ValueKey<String>('qr-scan-camera'),
                  controller: controller,
                  onDetect: (BarcodeCapture capture) =>
                      _found(capture.barcodes),
                  errorBuilder: _error,
                ),
              ),
            )
          else
            WholeWordText(
              'Камера для QR есть только в Tridot на телефоне и Mac. Здесь '
              'вставьте ссылку кнопкой «Вставить ссылку».',
              key: const ValueKey<String>('qr-scan-unavailable'),
              style: TextStyle(color: context.colors.muted),
            ),
          if (_problem case final String problem)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: WholeWordText(
                problem,
                key: const ValueKey<String>('qr-scan-problem'),
                style: TextStyle(color: context.colors.warning),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        DialogCancel(onPressed: () => Navigator.of(context).pop()),
        if (controller != null)
          TextButton(
            key: const ValueKey<String>('qr-scan-image'),
            onPressed: _fromImage,
            child: const ActionLabel('Из картинки'),
          ),
      ],
    );
  }
}
