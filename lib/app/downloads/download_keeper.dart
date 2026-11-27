import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Загрузка моделей в фоне (ADR-046): на Android, пока модель
/// скачивается, служба переднего плана держит процесс и показывает ход в
/// уведомлении. Сама загрузка — прежняя (Dart, с продолжением и
/// проверкой). Где службы нет — ничего не делает.
abstract interface class BackgroundDownloads {
  Future<void> update(String title, int received, int total);
  Future<void> stop();
}

final class AndroidBackgroundDownloads implements BackgroundDownloads {
  const AndroidBackgroundDownloads();

  static const MethodChannel _channel = MethodChannel('tridot/downloads');

  static BackgroundDownloads? current() =>
      Platform.isAndroid ? const AndroidBackgroundDownloads() : null;

  @override
  Future<void> update(String title, int received, int total) async {
    try {
      await _channel.invokeMethod<bool>('update', <String, Object>{
        'title': title,
        'received': received,
        'total': total,
      });
    } on Object {
      // Служба не запустилась — загрузка идёт, пока приложение открыто.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // Нечего останавливать.
    }
  }
}

/// Загрузка одной модели для [DownloadKeeper].
final class KeptDownload {
  const KeptDownload({
    required this.listenable,
    required this.title,
    required this.active,
    required this.received,
    required this.total,
  });

  final Listenable listenable;
  final String title;
  final bool Function() active;
  final int Function() received;
  final int Function() total;
}

/// Следит за загрузками моделей: идёт хоть одна — служба с ходом первой
/// из них, ни одной — служба остановлена. Обновления — не чаще раза в
/// секунду.
final class DownloadKeeper {
  DownloadKeeper(this.downloads, this.service, {DateTime Function()? now})
      : _now = now ?? DateTime.now {
    for (final d in downloads) {
      d.listenable.addListener(_changed);
    }
  }

  final List<KeptDownload> downloads;
  final BackgroundDownloads service;
  final DateTime Function() _now;

  bool _running = false;
  DateTime? _last;

  static const Duration interval = Duration(seconds: 1);

  void _changed() {
    KeptDownload? busy;
    for (final d in downloads) {
      if (d.active()) {
        busy = d;
        break;
      }
    }
    if (busy == null) {
      if (_running) {
        _running = false;
        _last = null;
        unawaited(service.stop());
      }
      return;
    }
    final now = _now();
    final last = _last;
    if (_running && last != null && now.difference(last) < interval) return;
    _running = true;
    _last = now;
    unawaited(service.update(busy.title, busy.received(), busy.total()));
  }

  void dispose() {
    for (final d in downloads) {
      d.listenable.removeListener(_changed);
    }
    if (_running) unawaited(service.stop());
  }
}
