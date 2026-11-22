import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/connectors/manifest/connection_slots.dart';
import 'browser_host.dart';
import 'fetch_transport.dart';
import 'intent_web.dart';
import 'widget_app.dart';
import 'widget_session.dart';

/// Версия выпуска веб-помощника: её задаёт `tool/widget_release`
/// (`--dart-define=SVYAZNOY_WEB_VERSION=…`). Сборка без выпуска — `dev`:
/// новых версий на складе не ищет.
const String widgetVersion =
    String.fromEnvironment('SVYAZNOY_WEB_VERSION', defaultValue: 'dev');

/// Веб-помощник «Связной» на складе (ADR-032): своя точка входа сборки
/// `flutter build web -t lib/web_widget/main.dart`. Только то, что
/// работает в браузере: описание склада и ответы — из общего кода
/// «Tridot», сеть — `fetch`, история — `localStorage`, ключ — в памяти.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Экранный диктор: в CanvasKit семантика иначе включается только по
  // особой кнопке.
  SemanticsBinding.instance.ensureSemantics();
  String? builtIn;
  try {
    builtIn = await rootBundle.loadString(
      ConnectionSlots.warehouse.builtInAsset!,
    );
  } on Object {
    builtIn = null;
  }
  final network = BrowserNetwork();
  final fetch = FetchTransport();
  final session = WidgetSession(
    host: BrowserHost(),
    transport: fetch,
    storage: BrowserStorage(),
    builtInManifest: builtIn,
    version: widgetVersion,
    connectivity: network.changes,
    online: network.online,
    // Модель понимания (ADR-045, шаг 4): пакет `web` со склада,
    // onnxruntime-web из сборки помощника.
    intentFetcher: fetch,
    intentRuntime: OrtWebRuntime.open,
    intentPrepare: OrtWebRuntime.prepare,
    intentHasher: webSha256,
    saveFile: downloadText,
  );
  runApp(WidgetApp(session: session));
  session.start();
}
