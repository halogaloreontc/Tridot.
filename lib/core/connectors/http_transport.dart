/// HTTP-запрос коннектора. Тело — уже сериализованная строка (обычно JSON).
final class HttpRequestData {
  const HttpRequestData({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.timeout = const Duration(seconds: 10),
  });

  /// `GET`, `POST` и т. д.
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  /// Сколько ждать ответа. Коннектор не должен вешать диалог.
  final Duration timeout;
}

/// Ответ сервера.
final class HttpResponseData {
  const HttpResponseData({
    required this.statusCode,
    this.headers = const <String, String>{},
    this.body = '',
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Единственный путь коннектора в сеть (ADR-004).
///
/// Коннектор получает транспорт через конструктор и не создаёт сетевые
/// клиенты сам: в тестах подставляется подделка, а приложение решает, какую
/// реализацию дать и разрешена ли сеть вообще. Реализация бросает исключение
/// при обрыве связи или превышении [HttpRequestData.timeout]; ответ
/// с кодом 4xx/5xx — не исключение, а [HttpResponseData].
abstract interface class HttpTransport {
  Future<HttpResponseData> send(HttpRequestData request);
}
