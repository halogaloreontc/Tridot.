import 'dart:async';

import 'http_transport.dart';

/// [HttpTransport], который сообщает, доходят ли запросы до сервера: для
/// капсулы «Нет сети» над полем ввода (ADR-040).
///
/// Любой ответ сервера (и 4xx, и 5xx) — связь есть: [onReachable]. Обрыв
/// (исключение транспорта, у `fetch` — статус 0) — [onUnreachable].
/// Превышение тайм-аута связь не опровергает: склад бывает медленным, —
/// ни то ни другое. Сам запрос и ответ не меняются.
final class WatchedTransport implements HttpTransport {
  WatchedTransport(
    this.inner, {
    required this.onReachable,
    required this.onUnreachable,
  });

  final HttpTransport inner;
  final void Function() onReachable;
  final void Function() onUnreachable;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    final HttpResponseData response;
    try {
      response = await inner.send(request);
    } on TimeoutException {
      rethrow;
    } on Object {
      onUnreachable();
      rethrow;
    }
    if (response.statusCode == 0) {
      onUnreachable();
    } else {
      onReachable();
    }
    return response;
  }
}
