import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/connectors/http_transport.dart';

/// [HttpTransport] веб-помощника поверх `fetch` браузера (ADR-032).
///
/// Помощник и склад — на одном адресе: CORS не нужен, cookie склада не
/// уходят (`credentials: omit`) — вход только ключом помощника в
/// заголовке. Тайм-аут — `AbortController`: запрос действительно
/// обрывается, а не висит в фоне. Переадресация — ошибка: ключ не уходит
/// на чужой адрес.
final class FetchTransport implements HttpTransport {
  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    final headers = web.Headers();
    request.headers.forEach((String k, String v) => headers.set(k, v));
    final abort = web.AbortController();
    final timer = Timer(request.timeout, () => abort.abort());
    try {
      final response = await web.window
          .fetch(
            request.uri.toString().toJS,
            web.RequestInit(
              method: request.method,
              headers: headers,
              body: request.body?.toJS,
              credentials: 'omit',
              cache: 'no-store',
              redirect: 'error',
              signal: abort.signal,
            ),
          )
          .toDart;
      final body = (await response.text().toDart).toDart;
      final out = <String, String>{};
      for (final name in const <String>[
        'etag',
        'last-modified',
        'content-type',
        'retry-after',
      ]) {
        final value = response.headers.get(name);
        if (value != null) out[name] = value;
      }
      return HttpResponseData(
        statusCode: response.status,
        headers: out,
        body: body,
      );
    } on Object {
      if (abort.signal.aborted) {
        throw TimeoutException('Склад не ответил вовремя', request.timeout);
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }
}
