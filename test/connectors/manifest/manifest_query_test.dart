// Запрос к складу словами пользователя (ManifestQuery): поле без служебных
// слов, вопрос обо всём складе, пересказ словами описания.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_query.dart';

void main() {
  group('clean', () {
    const cases = <String, String>{
      'по 64115': '64115',
      'на 64115': '64115',
      'стул венский на складе': 'стул венский',
      'на складе 64115': '64115',
      'у нас лежат венские стулья': 'венские стулья',
      '64115 лежит': '64115',
      '64115 осталось': '64115',
      '64115, пожалуйста': '64115',
      'артикулу 64115': '64115',
      'по артикулу 64115 на складе': '64115',
      'мне найти стул венский': 'стул венский',
      '64 115': '64115',
      '120 734': '120734',
      'венские стулья в наличии': 'венские стулья',
      'на складе': '',
      // Названия товара не трогаются.
      'стул венский': 'стул венский',
      'полка для обуви': 'полка для обуви',
      'набор на кухню': 'набор на кухню',
      '6 115': '6 115',
    };
    cases.forEach((String input, String expected) {
      test('«$input» → «$expected»', () {
        expect(ManifestQuery.clean(input), expected);
      });
    });
  });

  test('isWholeStock: только общие слова о складе', () {
    for (final whole in <String>[
      'позиций',
      'всего позиций',
      'товаров',
      'всего товара',
      'наименований',
      'разных артикулов',
    ]) {
      expect(ManifestQuery.isWholeStock(whole), isTrue, reason: whole);
    }
    for (final item in <String>[
      'венских стульев',
      'товара 64115',
      'всего',
      '',
      'позиций стульев',
    ]) {
      expect(ManifestQuery.isWholeStock(item), isFalse, reason: item);
    }
  });

  test('paraphrases: словами описания, наличие помечено', () {
    String? first(String text) =>
        ManifestQuery.paraphrases(text).firstOrNull?.text;
    expect(first('есть ли на складе 64115'), 'сколько на складе 64115');
    expect(
      ManifestQuery.paraphrases('а венские стулья есть').first.availability,
      isTrue,
    );
    expect(first('наличие 64115'), 'остаток 64115');
    expect(first('есть в наличии 64115'), 'остаток 64115');
    expect(first('поищи 64115'), 'найди 64115');
    expect(first('где мне найти 64115'), 'где 64115');
    expect(first('в какой ячейке лежит 64115'), 'где лежит 64115');
    expect(first('покажи ячейку 215-1-1-1'), 'ячейка 215-1-1-1');
    expect(first('по чём 64115'), 'почем 64115');
    expect(first('какие поступления сегодня'), 'какие приходы сегодня');
    expect(first('приходы за последнюю неделю'), 'приходы за неделю');
    expect(
      ManifestQuery.paraphrases('наличие 64115').first.availability,
      isFalse,
      reason: '«наличие» — слово склада, не обычной речи',
    );
    expect(ManifestQuery.paraphrases('где лежит 64115'), isEmpty);
  });
}
