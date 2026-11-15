// Загрузчик веб-помощника (ADR-032). Шаблон Flutter: строки в фигурных
// скобках подставляет `flutter build web`.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // CanvasKit — из архива выпуска, а не с gstatic (сборка с
    // --no-web-resources-cdn); путь — от папки этой версии.
    canvasKitBaseUrl: 'canvaskit/',
    // Запасных шрифтов в архиве нет, а за чужими помощник не ходит:
    // знак, которого нет в шрифтах (эмодзи), покажется пустым
    // прямоугольником. Эмодзи в ответах помощника выключены.
    fontFallbackBaseUrl: 'assets/fallback-fonts/',
  },
  // Своего service worker у помощника нет: кэш — по неизменным папкам
  // версий на складе.
});
