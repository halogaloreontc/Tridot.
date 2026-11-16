// Загрузчик веб-помощника (ADR-032). Шаблон Flutter: строки в фигурных
// скобках подставляет `flutter build web`.

// Сервер склада может отдавать `.wasm` не как `application/wasm` (старый
// mime.types Nginx). Загрузчик Flutter компилирует CanvasKit через
// `WebAssembly.compileStreaming`, а тот с чужим типом падает с TypeError —
// и помощник не открывается. Тогда компилируем из ArrayBuffer: чуть
// медленнее, зато без правки сервера (ADR-035). Другие ошибки не глотаем.
(() => {
  const wa = window.WebAssembly;
  if (!wa || typeof wa.compileStreaming !== 'function') return;
  const streaming = wa.compileStreaming;
  wa.compileStreaming = async (source) => {
    const res = await source;
    try {
      return await streaming.call(wa, res.clone());
    } catch (e) {
      if (!(e instanceof TypeError)) throw e;
      return wa.compile(await res.arrayBuffer());
    }
  };
})();

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
