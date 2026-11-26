import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/gen/gen_model.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/skills/table/table_connector.dart';

final class _Model implements GenModel {
  _Model(this.answer);

  final String answer;
  String? question;

  @override
  Future<String> complete({
    required String system,
    required String user,
    String? grammar,
    int maxTokens = 200,
  }) async {
    question = user;
    return answer;
  }
}

const JobFile _csv = JobFile(
  path: 'files/s1/m1-0.csv',
  name: 'поставки.csv',
  attachment: true,
);

Uint8List _deliveries() =>
    File('tools/gen_model/eval/tables/deliveries.csv').readAsBytesSync();

Future<AssistantResponse> _ask(
  String text, {
  GenModel? model,
  List<JobFile> files = const <JobFile>[_csv],
  Uint8List? bytes,
}) {
  final connector = TableConnector(
    read: (JobFile f) async =>
        f.path == _csv.path ? (bytes ?? _deliveries()) : null,
    model: () async => model,
  );
  final match =
      connector.match(Utterance.analyze(text, now: DateTime(2026, 11, 20)));
  expect(match, isNotNull, reason: text);
  final session = AssistantSession()..attachments = files;
  return connector.run(match!, session);
}

void main() {
  test('вопрос к таблице: ответ, что посчитано и сколько строк', () async {
    final model = _Model(
      '{"op":"sum","column":"сумма","filters":[{"column":"поставщик","cmp":"contains","value":"Ромашка"}]}',
    );
    final r = await _ask(
      'по таблице: на какую сумму поставила Ромашка?',
      model: model,
    );
    expect(r.status, AssistantStatus.completed);
    expect(r.message, contains('15 500'));
    expect(
      r.message,
      contains('сумма «сумма», где «поставщик» содержит «Ромашка»'),
    );
    expect(r.message, contains('3 строки'));
    expect(model.question, 'по таблице: на какую сумму поставила Ромашка?');
  });

  test('таблица из прошлого сообщения сессии', () async {
    final connector = TableConnector(
      read: (_) async => _deliveries(),
      model: () async => _Model('{"op":"count","column":null,"filters":[]}'),
    );
    final match = connector.match(
      Utterance.analyze(
        'сколько строк в таблице',
        now: DateTime(2026, 11, 20),
      ),
    )!;
    final session = AssistantSession()
      ..recentAttachments = const <JobFile>[_csv];
    final r = await connector.run(match, session);
    expect(r.message, startsWith('7 — число строк'));
  });

  test('нет таблицы — просьба приложить', () async {
    final r = await _ask(
      'сколько строк в таблице',
      model: _Model('{}'),
      files: const <JobFile>[],
    );
    expect(r.status, AssistantStatus.needsClarification);
    expect(r.message, contains('Приложите таблицу CSV'));
  });

  test('нет модели — подсказка про «Продвинутую»', () async {
    final r = await _ask('сколько строк в таблице');
    expect(r.message, contains('«Продвинутая»'));
  });

  test('модель вернула чужой столбец — «не понял» со списком столбцов',
      () async {
    final r = await _ask(
      'какая средняя цена в таблице',
      model: _Model('{"op":"avg","column":"цена","filters":[]}'),
    );
    expect(r.message, contains('дата, поставщик, товар, количество, сумма'));
  });

  test('не таблица — честно', () async {
    final r = await _ask(
      'сколько строк в таблице',
      model: _Model('{}'),
      bytes: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF]),
    );
    expect(r.message, contains('«поставки.csv»'));
  });

  test('распознавание: только вопрос с указанием на таблицу', () {
    expect(TableConnector.recognize('сколько всего единиц в таблице?'), isTrue);
    expect(TableConnector.recognize('напомни заполнить таблицу'), isFalse);
    expect(TableConnector.recognize('в таблице'), isFalse);
    expect(TableConnector.recognize('таблица умножения на 7?'), isFalse);
  });

  test('числа: разряды и дробь', () {
    expect(TableConnector.formatNumber(31570), '31 570');
    expect(TableConnector.formatNumber(4510.5), '4 510,5');
    expect(TableConnector.formatNumber(75), '75');
    expect(TableConnector.formatNumber(-1234.25), '−1 234,25');
  });
}
