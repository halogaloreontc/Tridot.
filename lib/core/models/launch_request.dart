/// Открыть страницу или приложение погоды после ответа (ADR-030).
///
/// Только у живого ответа: в историю чата не пишется и после перезапуска
/// ничего не открывает. Адрес берётся из настроек и в тексте ответа не
/// показывается.
final class LaunchRequest {
  const LaunchRequest.url(String this.url)
      : appId = null,
        appLabel = null;

  const LaunchRequest.app(
    String this.appId, {
    this.appLabel,
    String? fallbackUrl,
  }) : url = fallbackUrl;

  /// Страница (у приложения — запасная, если оно не открылось).
  final String? url;

  /// Приложение: имя пакета на Android, id программы на Mac.
  final String? appId;
  final String? appLabel;

  bool get isApp => appId != null;
}
