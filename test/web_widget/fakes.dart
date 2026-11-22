import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/web_widget/widget_protocol.dart';
import 'package:local_assistant/web_widget/widget_session.dart';

/// Заведомо поддельные ключи: настоящих секретов в тестах нет.
const String webSid = 'fake-web-sid-0000000001';
const String webSid2 = 'fake-web-sid-0000000002';

/// Встроенная копия описания склада — та же, что в сборке помощника.
String builtInSource() =>
    File('assets/connectors/depotdesk.assistant.json').readAsStringSync();

/// Склад DepotDesk по сценарию: ответы по `?action=`, запросы
/// запоминаются; `assistant/current.json` — [installed].
final class FakeWarehouse implements HttpTransport {
  final Map<String, List<(int, Object?)>> script =
      <String, List<(int, Object?)>>{};
  final List<HttpRequestData> requests = <HttpRequestData>[];
  String manifest = builtInSource();
  String? installed;

  /// `assistant/intent/web/current.json` — указатель на модель понимания
  /// (ADR-045, шаг 4); `null` — склад модель не ставил (404).
  String? intentPointer;

  /// Медленная связь: каждый ответ — через столько.
  Duration delay = Duration.zero;

  /// Нет сети: `fetch` браузера отклоняется (TypeError «Failed to fetch»),
  /// склад запросов не видит.
  bool offline = false;

  /// Ответ `ask_me` по умолчанию, когда сценарий пуст.
  Map<String, Object?> me = <String, Object?>{
    'ok': true,
    'login': 'ivanov',
    'name': 'Иван Петров',
    'roleLabel': 'Кладовщик',
    'perms': <String>['moves'],
    'actions': true,
  };

  /// Склад 1.4.74 с личным хранилищем: `ask_me.store` и ответы `my_*` по
  /// умолчанию (пустое хранилище, записи принимаются).
  void withStore({bool signals = false}) {
    me = <String, Object?>{
      ...me,
      'store': <String, Object?>{'v': 1, 'on': true, 'signals': signals},
    };
    myOk = true;
  }

  bool myOk = false;
  int _rev = 0;

  /// Тела запросов действия [action].
  List<Map<String, Object?>> bodies(String action) => <Map<String, Object?>>[
        for (final r in requests)
          if (r.uri.queryParameters['action'] == action)
            Map<String, Object?>.from(jsonDecode(r.body ?? '{}') as Map),
      ];

  Map<String, Object?> _myDefault(String action, String? body) {
    final json = body == null || body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(body) as Map);
    switch (action) {
      case 'my_sync':
        return <String, Object?>{
          'ok': true,
          'epoch': 'e1',
          'rev': _rev,
          'mark': 'mk',
          'full': json['since'] == 0,
          'items': <Object?>[],
          'gone': <Object?>[],
          'next': _rev,
          'more': false,
        };
      case 'my_put':
        final obj = json['obj']! as Map;
        return <String, Object?>{
          'ok': true,
          'obj': <String, Object?>{
            ...Map<String, Object?>.from(obj),
            'rev': ++_rev,
          },
          'rev': _rev,
        };
      case 'my_patch':
      case 'my_chat_new':
        return <String, Object?>{
          'ok': true,
          'obj': <String, Object?>{'id': json['id'], 'rev': ++_rev},
          'rev': _rev,
        };
      case 'my_chat_append':
        return <String, Object?>{'ok': true, 'u': ++_rev, 'rev': _rev};
      case 'my_signals':
        return <String, Object?>{'ok': true, 'items': <Object?>[]};
    }
    return <String, Object?>{'ok': true};
  }

  void on(String action, int status, Object? json) =>
      (script[action] ??= <(int, Object?)>[]).add((status, json));

  List<String> get actions => <String>[
        for (final r in requests)
          if (r.uri.path.endsWith('api.php'))
            r.uri.queryParameters['action'] ?? '',
      ];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    if (offline) throw StateError('Failed to fetch');
    requests.add(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final path = request.uri.path;
    if (path.endsWith('assistant/intent/web/current.json')) {
      final pointer = intentPointer;
      return pointer == null
          ? const HttpResponseData(statusCode: 404)
          : HttpResponseData(statusCode: 200, body: pointer);
    }
    if (path.endsWith('assistant/current.json')) {
      final v = installed;
      return v == null
          ? const HttpResponseData(statusCode: 404)
          : HttpResponseData(
              statusCode: 200,
              body: jsonEncode(<String, Object?>{'version': v}),
            );
    }
    if (path.endsWith('assistant.json')) {
      return HttpResponseData(statusCode: 200, body: manifest);
    }
    final action = request.uri.queryParameters['action'] ?? '';
    final queue = script[action];
    if (queue == null || queue.isEmpty) {
      if (action == 'ask_me') {
        return HttpResponseData(statusCode: 200, body: jsonEncode(me));
      }
      if (myOk && action.startsWith('my_')) {
        return HttpResponseData(
          statusCode: 200,
          body: jsonEncode(_myDefault(action, request.body)),
        );
      }
      return HttpResponseData(
        statusCode: 400,
        body: jsonEncode(<String, Object?>{'error': 'Неизвестное действие'}),
      );
    }
    final (status, json) = queue.removeAt(0);
    return HttpResponseData(statusCode: status, body: jsonEncode(json));
  }
}

/// Страница склада: сообщения помощника копятся в [sent], свои —
/// [emit].
final class FakeHost implements HostChannel {
  FakeHost({this.embedded = true});

  final StreamController<HostEvent> _events =
      StreamController<HostEvent>.broadcast();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  @override
  final bool embedded;

  @override
  Stream<HostEvent> get events => _events.stream;

  @override
  void post(Map<String, Object?> message) => sent.add(message);

  void emit(Map<String, Object?> data) {
    final event = HostEvent.parse(data);
    if (event == null) throw ArgumentError('Не сообщение договора: $data');
    _events.add(event);
  }

  List<String> get types =>
      <String>[for (final m in sent) m['type']! as String];
}

/// Дождаться, пока помощник обработает сообщения и ответы склада.
Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> initMessage({
  String sid = webSid,
  String device = 'phone',
  Map<String, Object?> voice = const <String, Object?>{
    'available': false,
    'reason': 'web',
  },
}) =>
    <String, Object?>{
      'svz': 1,
      'type': 'init',
      'base': 'https://warehouse.example/',
      'sid': sid,
      'login': 'ivanov',
      'name': 'Иван Петров',
      'roleLabel': 'Кладовщик',
      'theme': 'light',
      'device': device,
      'voice': voice,
    };
