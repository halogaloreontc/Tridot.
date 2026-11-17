import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'widget_protocol.dart';
import 'widget_session.dart';
import 'widget_storage.dart';

/// `localStorage` браузера. Недоступен (запрещён, приватный режим) —
/// исключение при записи: история живёт до закрытия страницы.
final class BrowserStorage implements KeyValueStorage {
  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void write(String key, String value) =>
      web.window.localStorage.setItem(key, value);

  @override
  void remove(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } on Object {
      // Нечего удалять.
    }
  }
}

/// Связь со страницей склада через `postMessage` (ADR-032). Сообщение
/// принимается, только если оно с того же адреса (`origin`) и от окна
/// родителя; отправляется только родителю и только на свой адрес.
final class BrowserHost implements HostChannel {
  BrowserHost() {
    web.window.addEventListener('message', _listener);
  }

  late final JSFunction _listener = ((web.MessageEvent event) {
    if (event.origin != _origin) return;
    final source = event.source;
    if (source == null || !source.strictEquals(web.window.parent).toDart) {
      return;
    }
    final parsed = HostEvent.parse(event.data.dartify());
    if (parsed != null) _events.add(parsed);
  }).toJS;

  final StreamController<HostEvent> _events =
      StreamController<HostEvent>.broadcast();

  String get _origin => web.window.location.origin;

  @override
  Stream<HostEvent> get events => _events.stream;

  @override
  bool get embedded {
    final parent = web.window.parent;
    if (parent == null || parent.strictEquals(web.window).toDart) return false;
    try {
      // Чужой адрес у родителя — чтение его адреса бросает исключение.
      return parent.location.origin == _origin;
    } on Object {
      return false;
    }
  }

  @override
  void post(Map<String, Object?> message) {
    final parent = web.window.parent;
    if (parent == null) return;
    parent.postMessage(message.jsify(), _origin.toJS);
  }
}
