import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection_service.dart';
import '../widgets/app_consent_sheet.dart';
import '../widgets/connections_host.dart';
import '../widgets/qr_scan_sheet.dart';
import '../widgets/warehouse_connection_card.dart';

/// Входящая ссылка или QR (`tridot://connect`, `https://…#qr=`, снимок
/// экрана с кодом — ADR-031, ADR-039): куда её вести. Ничего не
/// подключает само.
///
/// - Ссылка на адрес подключённого склада — как раньше: подтверждение с
///   хостом и вход ([connectWarehouseLink]).
/// - Иначе, если есть каталог подключений ([host]), — проба адреса
///   (описание без кода): склад — тот же путь склада; приложение, уже
///   подключённое с этим `app.id` **и** этим хостом, — подтверждение и
///   вход в него; всё остальное — только экран «Подключить приложение» с
///   адресом в поле и согласием. Подключённое приложение ссылка с другого
///   адреса не перенацеливает.
/// - Каталога нет — как раньше: всё идёт складу.
///
/// Возвращает текст тихой строки (итог или почему не годится); `null` —
/// показывать нечего (передумали или открыт экран).
Future<String?> handleIncomingConnect(
  BuildContext context, {
  required String? text,
  required bool image,
  required ConnectionService? warehouse,
  required ValueChanged<bool> onWarehouseEnabled,
  ConnectionsHost? host,
}) async {
  if (text == null || !looksLikeLoginLink(text)) {
    if (host == null) {
      return image
          ? 'На картинке нет QR склада.'
          : 'Через «Поделиться» Tridot принимает только ссылку склада.';
    }
    return image
        ? 'На картинке нет QR подключения.'
        : 'Через «Поделиться» Tridot принимает только ссылку подключения: '
            'склада или приложения.';
  }
  Future<String?> toWarehouse(ConnectionService service) async {
    final result = await connectWarehouseLink(
      context,
      service,
      text,
      onEnabledChanged: onWarehouseEnabled,
    );
    return result?.message;
  }

  if (host == null) {
    if (warehouse == null) {
      return image
          ? 'На картинке нет QR склада.'
          : 'Через «Поделиться» Tridot принимает только ссылку склада.';
    }
    return toWarehouse(warehouse);
  }
  final link = ConnectionService.parseQrLink(text);
  final current = warehouse?.record.baseUri;
  if (warehouse != null && current != null && sameAppHost(current, link.base)) {
    return toWarehouse(warehouse);
  }
  final probe = await host.apps.probe(text);
  if (!context.mounted) return null;
  if (probeIsWarehouse(probe) && warehouse != null) {
    return toWarehouse(warehouse);
  }
  if (probe.existingId case final String id) {
    final service = host.apps.byId(id);
    // Проба сверила app.id и хост: ссылка ведёт туда же, куда подключено.
    if (service != null &&
        sameAppHost(service.fixedBase ?? link.base, link.base)) {
      if (!await confirmAppLink(context, service, link) || !context.mounted) {
        return null;
      }
      final result = await service.connectByLink(text);
      if (result.ok) host.setEnabled(service.slot.id, true);
      return result.message;
    }
  }
  await host.addApp(
    context,
    // В поле — только адрес: код из ссылки не показывается.
    address: link.base.toString(),
    loginLink: text,
    probe: probe,
  );
  return null;
}

/// Тот же хост и порт: склад или приложение по ссылке — то же самое.
bool sameAppHost(Uri a, Uri b) =>
    a.host.toLowerCase() == b.host.toLowerCase() && a.port == b.port;
