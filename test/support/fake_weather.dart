// Подделки для погоды (ADR-030): транспорт, который записывает запросы и
// отвечает файлами из test/fixtures/weather. Настоящей сети в тестах нет.
import 'dart:io';

import 'package:local_assistant/core/connectors/http_transport.dart';

String weatherFixture(String name) =>
    File('test/fixtures/weather/$name').readAsStringSync();

/// Ответ подделки: код и тело или исключение.
final class FakeReply {
  const FakeReply(this.status, [this.body = '{}']) : error = null;

  const FakeReply.error(Object this.error)
      : status = 0,
        body = '';

  FakeReply.fixture(String name, {this.status = 200})
      : body = weatherFixture(name),
        error = null;

  final int status;
  final String body;
  final Object? error;
}

/// Транспорт, который записывает каждый запрос и отвечает [respond].
final class RecordingTransport implements HttpTransport {
  RecordingTransport(this.respond);

  /// Ответ по запросу; по умолчанию — Казань.
  factory RecordingTransport.kazan() => RecordingTransport((Uri uri) {
        if (uri.host == 'geocoding-api.open-meteo.com') {
          final name = uri.queryParameters['name'];
          return switch (name) {
            'Казань' => FakeReply.fixture('geocode_kazan.json'),
            'Москва' => FakeReply.fixture('geocode_moskva.json'),
            'Москве' || 'Москв' => FakeReply.fixture('geocode_moskve.json'),
            _ => FakeReply.fixture('geocode_empty.json'),
          };
        }
        return FakeReply.fixture('forecast_kazan.json');
      });

  final FakeReply Function(Uri uri) respond;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  List<Uri> get uris => <Uri>[for (final r in requests) r.uri];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    final reply = respond(request.uri);
    if (reply.error case final Object error) throw error;
    return HttpResponseData(statusCode: reply.status, body: reply.body);
  }
}

/// Ошибки транспорта, как у IoHttpTransport.
final Object socketError = const SocketException('нет сети');
