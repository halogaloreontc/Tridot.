// Название «Хранилище» зарезервировано за будущим «Хранилищем контекста»
// (docs/PLANS.md): навык «Пароли» в интерфейсе зовётся «Сейф», экран места
// данных — «Данные». Тест сканирует строковые литералы слоя приложения:
// ни одна подпись, кнопка или сообщение не говорит «хранилище».
// Комментарии и разбор ввода («хранилище паролей» по-прежнему понимается,
// lib/core/skills/passwords/passwords_phrases.dart) сюда не входят.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Литералы в одинарных или двойных кавычках, где есть «хранилищ».
final RegExp _literal = RegExp(
  r"'[^'\n]*[Хх]ранилищ[^'\n]*'" r'|"[^"\n]*[Хх]ранилищ[^"\n]*"',
);

/// Строки [source] (без комментариев), где литерал говорит «хранилище».
List<String> storageLiterals(String source) => <String>[
      for (final line in source.split('\n'))
        if (!line.trimLeft().startsWith('//'))
          for (final m in _literal.allMatches(_dropTrailingComment(line)))
            m.group(0)!,
    ];

/// Хвост `// …` после кода: только если перед ним нет открытой кавычки.
String _dropTrailingComment(String line) {
  final at = line.indexOf(' //');
  if (at < 0) return line;
  final head = line.substring(0, at);
  final quotes = "'".allMatches(head).length + '"'.allMatches(head).length;
  return quotes.isEven ? head : line;
}

void main() {
  test('правило ловит литерал и не ловит комментарий или «сейф»', () {
    expect(storageLiterals("  text: 'Хранилище заперто.',"), hasLength(1));
    expect(storageLiterals('  text: "открыть хранилище",'), hasLength(1));
    expect(storageLiterals('  /// Экран «Хранилище» — старое имя.'), isEmpty);
    expect(storageLiterals('  f(); // хранилище запирается'), isEmpty);
    expect(storageLiterals("  text: 'Сейф заперт.',"), isEmpty);
    expect(storageLiterals("  text: 'Данные только в памяти',"), isEmpty);
  });

  test('интерфейс не называет сейф и данные «хранилищем»', () {
    final files = <File>[
      ...Directory('lib/app')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart')),
      File('lib/core/storage/storage_info.dart'),
    ];
    expect(files.length, greaterThan(10));
    final found = <String>[
      for (final file in files)
        for (final literal in storageLiterals(file.readAsStringSync()))
          '${file.path}: $literal',
    ];
    expect(found, isEmpty);
  });
}
