import '../connectors/manifest/connection_slots.dart';
import 'persona_cast.dart';

/// Чья зона навык или подключение (ADR-016): кто отвечает на фразу, если к
/// помощнику не обращались по имени.
///
/// Беседа, задачи, калькулятор, «Данные» и погода — зона главного
/// (Связного).
/// Склад, «Пароли», будущие конвертер, архиватор, загрузчик видео и любое
/// подключение ([ConnectionSlots]) — расширения. Будильник и таймер в
/// «Часах» (ADR-029) — зона оповещений: на них отвечает ведущий оповещений
/// ([PersonaCast.notifier]). Остальные оповещения (напоминания о задачах,
/// просрочки, сигналы склада) — не навык: их ведущий оповещений пишет сам,
/// без фразы пользователя.
abstract final class DutyZones {
  /// Навыки зоны главного.
  static const Set<String> main = <String>{
    'tasks',
    'calc',
    'talk',
    'data',
    // Погода (ADR-030): ведёт Связной.
    'weather',
  };

  /// Навыки-расширения сверх подключений ([ConnectionSlots]).
  static const Set<String> extensions = <String>{
    'warehouse',
    'passwords',
    'converter',
    'archiver',
    'ytdl',
  };

  /// Навыки зоны оповещений.
  static const Set<String> notifications = <String>{'alarm'};

  /// Обязанность, к которой относится навык [connectorId]. Неизвестный
  /// навык (пак, навык вне списка) — зона главного.
  static PersonaDuty dutyOf(String connectorId) {
    if (main.contains(connectorId)) return PersonaDuty.main;
    if (notifications.contains(connectorId)) return PersonaDuty.notifications;
    if (extensions.contains(connectorId) ||
        ConnectionSlots.all.any((slot) => slot.id == connectorId)) {
      return PersonaDuty.extensions;
    }
    return PersonaDuty.main;
  }
}
