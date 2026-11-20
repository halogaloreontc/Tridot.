import 'dart:async';

import '../http_transport.dart';
import 'connection.dart';
import 'manifest_format.dart';

/// Ответ сервера на запрос описания `<адрес>/assistant.json`.
final class ManifestFetched {
  const ManifestFetched(this.description, {this.etag, this.lastModified})
      : error = null,
        rejected = null,
        unchanged = false;

  const ManifestFetched.failed(this.error)
      : description = null,
        etag = null,
        lastModified = null,
        rejected = null,
        unchanged = false;

  /// Описание того же приложения пришло, но проверку не прошло: вход не
  /// останавливается, работаем по прежнему или встроенному.
  const ManifestFetched.rejected(this.rejected)
      : description = null,
        etag = null,
        lastModified = null,
        error = null,
        unchanged = false;

  const ManifestFetched.unchanged()
      : description = null,
        etag = null,
        lastModified = null,
        error = null,
        rejected = null,
        unchanged = true;

  /// Описание сервера, прошедшее проверку формата (выбор —
  /// `DescriptionAuthority`).
  final ManifestDescription? description;
  final String? etag;
  final String? lastModified;

  /// Сервер недоступен или ответил не описанием этого приложения: войти
  /// нельзя.
  final String? error;

  /// Почему описание сервера не прошло проверку.
  final String? rejected;
  final bool unchanged;
}

/// Запрос описания приложения (ADR-011, ADR-043): один путь для входа,
/// обновления описания и «Подключить приложение» без сохранения.
///
/// Защиты — те же везде: адрес — уже проверенный `ConnectionService.baseOf`
/// (https или http своей сети), описание всегда `<адрес>/assistant.json`,
/// переадресаций нет (транспорт их не выполняет, ответ 3xx — ошибка),
/// тело ответа не больше 2 МБ (транспорт), описание — не больше 256 КБ и
/// `api.url` того же источника ([ManifestDescription.parse]).
abstract final class ManifestFetch {
  /// Сколько ждать сервер.
  static const Duration timeout = Duration(seconds: 15);

  /// Описание с [base]. [appIds] — какие `app.id` годятся; `null` — любой
  /// (проба нового приложения). [known] — `etag` и дата прежнего ответа:
  /// «не изменилось» (304). [sameApp] — ответ, не прошедший проверку, всё
  /// же описание этого приложения: тогда [ManifestFetched.rejected], и
  /// вход идёт по прежнему описанию; `null` — такого нет.
  static Future<ManifestFetched> fetch(
    HttpTransport transport,
    Uri base, {
    Set<String>? appIds,
    ManifestMeta? known,
    bool Function(String body)? sameApp,
    Duration wait = timeout,
  }) async {
    final uri = base.resolve('assistant.json');
    final headers = <String, String>{'Accept': 'application/json'};
    if (known?.etag case final String etag) headers['If-None-Match'] = etag;
    if (known?.lastModified case final String date) {
      headers['If-Modified-Since'] = date;
    }
    final HttpResponseData response;
    try {
      response = await transport.send(
        HttpRequestData(
          method: 'GET',
          uri: uri,
          headers: headers,
          timeout: wait,
        ),
      );
    } on TimeoutException {
      return const ManifestFetched.failed('Сервер не ответил вовремя.');
    } on Object {
      return const ManifestFetched.failed(
        'Нет связи с сервером. Проверьте адрес и интернет.',
      );
    }
    if (response.statusCode == 304) return const ManifestFetched.unchanged();
    if (response.statusCode == 404) {
      return const ManifestFetched.failed(
        'По этому адресу нет описания помощника (assistant.json).',
      );
    }
    if (!response.isSuccess) {
      return ManifestFetched.failed(
        'Сервер ответил ошибкой ${response.statusCode}.',
      );
    }
    try {
      final description = ManifestDescription.parse(
        response.body,
        appIds: appIds,
        manifestUri: uri,
      );
      return ManifestFetched(
        description,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
      );
    } on ManifestException catch (error) {
      // Это то приложение, но описание сервера не прошло проверку: если
      // есть встроенное или закреплённое, работаем по нему (ADR-012).
      if (sameApp != null && sameApp(response.body)) {
        return ManifestFetched.rejected(error.message);
      }
      return ManifestFetched.failed('Описание не принято: ${error.message}.');
    }
  }
}
