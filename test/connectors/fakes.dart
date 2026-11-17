import 'package:local_assistant/core/connectors/http_transport.dart';

/// Подделка сети: отвечает заранее заданным ответом и запоминает запросы.
final class FakeHttpTransport implements HttpTransport {
  FakeHttpTransport(this.respond);

  final HttpResponseData Function(HttpRequestData request) respond;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    return respond(request);
  }
}
