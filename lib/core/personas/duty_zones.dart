import '../connectors/manifest/connection_slots.dart';
import 'persona_cast.dart';

/// Чья зона навык или подключение (ADR-016): кто отвечает на фразу, если к
/// помощнику не обращались по имени.
///
/// Беседа, задачи, калькулятор и «Данные» — зона главного (Садо).
/// Склад, «Пароли», будущие конвертер, архиватор, загрузчик видео и любое
/// подключение ([ConnectionSlots]) — расширения. Оповещения — не навык:
/// их пишет ведущий оповещений ([PersonaCast.notifier]) сам, без фразы
/// пользователя.
abstract final class DutyZones {
  /// Навыки зоны главного.
  static const Set<String> main = <String>{'tasks', 'calc', 'talk', 'data'};

  /// Навыки-расширения сверх подключений ([ConnectionSlots]).
  static const Set<String> extensions = <String>{
    'warehouse',
    'passwords',
    'converter',
    'archiver',
    'ytdl',
  };

  /// Обязанность, к которой относится навык [connectorId]. Неизвестный
  /// навык (пак, навык вне списка) — зона главного.
  static PersonaDuty dutyOf(String connectorId) {
    if (main.contains(connectorId)) return PersonaDuty.main;
    if (extensions.contains(connectorId) ||
        ConnectionSlots.all.any((slot) => slot.id == connectorId)) {
      return PersonaDuty.extensions;
    }
    return PersonaDuty.main;
  }
}
