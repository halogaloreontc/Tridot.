import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/gen/gen_model.dart';
import 'package:local_assistant/core/gen/table_ask.dart';
import 'package:local_assistant/core/gen/table_data.dart';
import 'package:local_assistant/core/gen/table_query.dart';

TableData _table(String name) => TableData.fromCsv(
      File('tools/gen_model/eval/tables/$name.csv').readAsBytesSync(),
    )!;

bool _ok(TableAnswer? a, Object want) {
  if (a == null) return false;
  if (want is String) {
    final v = a.values;
    return v != null &&
        v.length == 1 &&
        v.single.toLowerCase() == want.toLowerCase();
  }
  final got = a.value ??
      (a.values?.length == 1 ? TableQuery.number(a.values!.single) : null);
  return got != null && (got - (want as num)).abs() < 0.01;
}

final class _Model implements GenModel {
  _Model(this.answer);

  final String answer;
  String? lastGrammar;
  String? lastSystem;

  @override
  Future<String> complete({
    required String system,
    required String user,
    String? grammar,
    int maxTokens = 200,
  }) async {
    lastSystem = system;
    lastGrammar = grammar;
    return answer;
  }
}

void main() {
  test('эталонные запросы дают ответы пробы (та же, что tools/gen_model)', () {
    final gold = jsonDecode(File('test/gen/table_gold.json').readAsStringSync())
        as List<Object?>;
    expect(gold, hasLength(24));
    for (final g in gold.cast<Map<String, Object?>>()) {
      final table = _table(g['table']! as String);
      final q = TableQuery.parse(jsonEncode(g['query']), table);
      expect(q, isNotNull, reason: '${g['id']}');
      expect(_ok(q!.run(table), g['answer']!), isTrue, reason: '${g['id']}');
    }
  });

  test('чужой столбец, операция или сравнение — запрос отвергнут', () {
    final t = _table('stock');
    expect(
      TableQuery.parse('{"op":"sum","column":"вес","filters":[]}', t),
      isNull,
    );
    expect(
      TableQuery.parse('{"op":"drop","column":"цена","filters":[]}', t),
      isNull,
    );
    expect(
      TableQuery.parse(
        '{"op":"sum","column":"цена","filters":[{"column":"цена","cmp":"like","value":1}]}',
        t,
      ),
      isNull,
    );
    expect(
      TableQuery.parse('{"op":"sum","column":null,"filters":[]}', t),
      isNull,
    );
    expect(TableQuery.parse('не json', t), isNull);
  });

  test('CSV в Windows-1251 и через точку с запятой', () {
    final text = 'товар;цена\nМолоко;89\nКефир;75\n';
    const cp = {
      'т': 0xF2,
      'о': 0xEE,
      'в': 0xE2,
      'а': 0xE0,
      'р': 0xF0,
      'ц': 0xF6,
      'е': 0xE5,
      'н': 0xED,
      'М': 0xCC,
      'л': 0xEB,
      'к': 0xEA,
      'К': 0xCA,
      'ф': 0xF4,
      'и': 0xE8,
    };
    final bytes = Uint8List.fromList(
      [for (final c in text.split('')) cp[c] ?? c.codeUnitAt(0)],
    );
    final t = TableData.fromCsv(bytes)!;
    expect(t.columns, ['товар', 'цена']);
    expect(t.rows.last, ['Кефир', '75']);
  });

  test('ask: грамматика со столбцами, ответ считает код', () async {
    final t = _table('deliveries');
    final model = _Model(
      '{"op": "sum", "column": "сумма", "filters": [{"column": "поставщик", "cmp": "contains", "value": "Ромашка"}]}',
    );
    final a = await TableAsk.ask(model, t, 'на какую сумму поставила Ромашка?');
    expect(a!.value, 15500);
    expect(a.matched, 3);
    expect(model.lastGrammar, contains(r'"\"поставщик\""'));
    expect(
      model.lastSystem,
      contains('Столбцы: дата,поставщик,товар,количество,сумма'),
    );
  });

  test('образец строк для модели проходит SecretGuard', () {
    final t = TableData([
      'логин',
      'заметка',
    ], [
      ['ivan', 'пароль: CANARY-Qx7!pass'],
    ]);
    expect(TableAsk.system(t), isNot(contains('CANARY-Qx7!pass')));
  });
}
