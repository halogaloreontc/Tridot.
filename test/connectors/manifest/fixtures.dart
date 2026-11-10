import 'dart:io';

import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';

/// Описание склада сейчас (до 1.4.56): копия halowarekeep/assistant.json.
const String currentManifestPath = 'test/fixtures/assistant/halowarekeep.json';

/// Описание склада 1.4.56: `version`, `auth.qr`, `auth.logout`.
const String patchedManifestPath =
    'test/fixtures/assistant/halowarekeep-1.4.56.json';

/// Описание склада 1.4.57: действия с записью (`actions[]`, ADR-013).
/// Встроенная копия `assets/connectors/halowarekeep.assistant.json`.
const String actionsManifestPath =
    'test/fixtures/assistant/halowarekeep-1.4.57.json';

String manifestSource([String path = currentManifestPath]) =>
    File(path).readAsStringSync();

ManifestDescription manifest([String path = currentManifestPath]) =>
    ManifestDescription.parse(
      manifestSource(path),
      appId: ConnectionSlots.warehouse.appId,
    );

/// Встроенная копия 1.4.57 с действиями.
ManifestDescription builtInManifest([String path = actionsManifestPath]) =>
    ManifestDescription.parse(
      manifestSource(path),
      appId: ConnectionSlots.warehouse.appId,
      builtIn: true,
    );

/// Адрес тестового склада. Только `.example`: сеть в тестах не нужна.
final Uri warehouseBase = Uri.parse('https://warehouse.example/');

/// Подключённое состояние без секретов.
ConnectionRecord connectedRecord({
  ConnectionLevel level = ConnectionLevel.staff,
  String? login = 'ivanov',
}) =>
    ConnectionRecord(
      appId: ConnectionSlots.warehouse.appId,
      baseUri: warehouseBase,
      login: login,
      level: level,
    );

/// Коннектор склада по описанию [path]: для корпуса, маршрутизации и
/// тестов `run`. [transport] по умолчанию бросает: `match` в сеть не ходит.
ManifestConnector warehouseConnector({
  String path = currentManifestPath,
  HttpTransport? transport,
  SecretStore? secrets,
  ConnectionRecord? record,
  ManifestDescription? builtIn,
}) =>
    ManifestConnector(
      slot: ConnectionSlots.warehouse,
      description: manifest(path),
      transport: transport ?? const OfflineTransport(),
      secrets: secrets ?? InMemorySecretStore(),
      record: record,
      builtIn: builtIn,
    );

/// Транспорт без сети: `match` в сеть не ходит, `run` с ним падает.
final class OfflineTransport implements HttpTransport {
  const OfflineTransport();

  @override
  Future<HttpResponseData> send(HttpRequestData request) =>
      throw StateError('разбор фраз не ходит в сеть');
}
