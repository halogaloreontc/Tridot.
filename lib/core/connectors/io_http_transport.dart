import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info.dart';
import 'http_transport.dart';

/// Сеть приложения на `dart:io` `HttpClient`, без новых пакетов (ADR-011).
///
/// Тайм-аут — [HttpRequestData.timeout] на всё: соединение, запрос и
/// ответ; превышение — [TimeoutException]. Тело ответа ограничено
/// [maxBody]: больше — исключение, как обрыв связи. Ни запрос, ни ответ
/// никуда не пишутся: в заголовках бывают пароль и личный ключ.
final class IoHttpTransport implements HttpTransport {
  IoHttpTransport({HttpClient? client})
      : _client = client ?? HttpClient()
          ..userAgent = '${AppInfo.latinName}/1';

  final HttpClient _client;

  /// Предел тела ответа: 2 МБ.
  static const int maxBody = 2 * 1024 * 1024;

  @override
  Future<HttpResponseData> send(HttpRequestData request) =>
      _send(request).timeout(request.timeout);

  Future<HttpResponseData> _send(HttpRequestData data) async {
    _client.connectionTimeout = data.timeout;
    final request = await _client.openUrl(data.method, data.uri);
    request.followRedirects = false;
    data.headers.forEach(request.headers.set);
    final body = data.body;
    if (body != null) request.add(utf8.encode(body));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBody) {
        throw const HttpException('Ответ сервера слишком большой');
      }
    }
    final headers = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return HttpResponseData(
      statusCode: response.statusCode,
      headers: headers,
      body: utf8.decode(bytes, allowMalformed: true),
    );
  }
}
