// Склад по описанию: фразы, которые расходятся с образцами `say` только
// порядком слов и уточнениями (период, место, срок рядом с артикулом),
// и фразы после обращения, которые не запрос товара.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/utterance.dart';

import 'fixtures.dart';

void main() {
  final now = DateTime(2026, 11, 2, 16, 30);
  final ManifestConnector connector = warehouseConnector(
    builtIn: builtInManifest(),
  );
  String? command(String text) =>
      connector.match(Utterance.analyze(text, now: now))?.commandId;

  group('приведение к образцу', () {
    const cases = <String, String>{
      // Период у команды без своего периода — не часть запроса.
      'покажи приходы без фото за сегодня': 'warehouse.nophoto',
      'приходы без фото за неделю, склад': 'warehouse.nophoto',
      'склад, приходы за день без фото': 'warehouse.nophoto',
      'без фото приходы есть за день?': 'warehouse.nophoto',
      // «За день» — сегодня.
      'склад, что пришло за день?': 'warehouse.today',
      // Свой период не теряется: не «что пришло» (сегодня).
      'за неделю что пришло': 'warehouse.week',
      // Вопрос после ячейки.
      'ячейка 215-1-1-1 что в ней': 'warehouse.cell',
      'на 215-3 что стоит': 'warehouse.cell',
      '215а, что там?': 'warehouse.cell',
      'в ячейке без места что лежит': 'warehouse.cell',
      'на складе без места что лежит?': 'warehouse.cell',
      'на складе 215а что в ячейке без места': 'warehouse.cell',
      // Артикул впереди и место в конце.
      '120734 остатки на 215а': 'warehouse.count',
      'венских стульев сколько на 215-3?': 'warehouse.count',
      // Срок и срочность рядом с одним артикулом.
      'склад, 120734 срочно к завтрашнему дню где?': 'warehouse.where',
    };
    for (final MapEntry(key: text, value: id) in cases.entries) {
      test(text, () => expect(command(text), id));
    }
  });

  group('не запрос складу', () {
    for (final text in <String>[
      // После обращения — вопрос о состоянии или дело с инфинитивом.
      'здорово! склад работает?',
      'склад, ты жив?',
      'Склад: 64115 переместить в 215-1-2-1',
      // Без обращения и без образца — задачи и беседа.
      'отчёт за неделю',
      'встреча на 215-3',
      'задачи на сегодня',
      // Срок без артикула — по-прежнему не поиск.
      'склад, стулья срочно к завтрашнему дню где?',
    ]) {
      test(text, () => expect(command(text), isNull));
    }
  });
}
