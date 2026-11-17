import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Что пришло извне (ADR-031): ссылка «Открыть в Tridot», текст из
/// «Поделиться» или снимок экрана с QR (путь к копии во временной папке).
final class IncomingItem {
  const IncomingItem.link(String this.text)
      : kind = IncomingKind.link,
        path = null;

  const IncomingItem.text(String this.text)
      : kind = IncomingKind.text,
        path = null;

  const IncomingItem.image(String this.path)
      : kind = IncomingKind.image,
        text = null;

  final IncomingKind kind;

  /// Текст ссылки — секрет (одноразовый код): не печатать.
  final String? text;
  final String? path;

  static const int maxText = 2048;

  /// Из сообщения канала; чужое и слишком длинное — `null`.
  static IncomingItem? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final text = raw['text'];
    final path = raw['path'];
    switch (kind) {
      case 'link' when text is String && text.length <= maxText:
        return IncomingItem.link(text);
      case 'text' when text is String && text.length <= maxText:
        return IncomingItem.text(text.trim());
      case 'image' when path is String && path.isNotEmpty:
        return IncomingItem.image(path);
    }
    return null;
  }

  @override
  String toString() => 'IncomingItem($kind)';
}

enum IncomingKind { link, text, image }

/// Канал `tridot/incoming` (Android IncomingLinkChannel.kt, Mac
/// ConnectChannels.swift): [initial] — то, с чем приложение запустили,
/// [items] — пришедшее, пока оно открыто. На других платформах — пусто.
final class IncomingLinks {
  IncomingLinks({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('tridot/incoming') {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'incoming') return;
      final item = IncomingItem.fromMap(call.arguments);
      if (item != null) _items.add(item);
    });
  }

  final MethodChannel _channel;
  final StreamController<IncomingItem> _items =
      StreamController<IncomingItem>.broadcast();

  Stream<IncomingItem> get items => _items.stream;

  /// Запуск по ссылке или «Поделиться»: отдаётся один раз.
  Future<IncomingItem?> initial() async {
    try {
      return IncomingItem.fromMap(
        await _channel.invokeMethod<Object?>('initial'),
      );
    } on Object {
      return null;
    }
  }

  /// Удалить копию картинки после разбора.
  static Future<void> forget(IncomingItem item) async {
    final path = item.path;
    if (path == null) return;
    try {
      await File(path).delete();
    } on Object {
      // Временная папка; почистит система.
    }
  }

  Future<void> dispose() => _items.close();
}
