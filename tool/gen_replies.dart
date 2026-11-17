// Копирует каталоги ответов assets/replies/*.json в
// lib/core/replies/builtin_replies.g.dart: ядро на чистом Dart читает их без
// Flutter и без файловой системы устройства. Тест
// test/replies/reply_catalog_test.dart сверяет копию с файлами.
//
// Запуск из корня проекта после правки каталога:
//   dart run tool/gen_replies.dart
import 'dart:io';

import 'package:local_assistant/core/replies/reply_catalog.dart';

const String output = 'lib/core/replies/builtin_replies.g.dart';

void main() {
  File(output).writeAsStringSync(generate());
  stdout.writeln('Записано: $output');
}

/// Текст файла с копией каталогов в порядке [ReplyStyles.builtIn].
String generate() {
  final buffer = StringBuffer()
    ..writeln(
      '// Сгенерировано tool/gen_replies.dart из assets/replies/*.json.',
    )
    ..writeln('// Не править вручную: правьте JSON и запустите генератор.')
    ..writeln()
    ..writeln('/// Тексты встроенных каталогов ответов по id стиля.')
    ..writeln(
      'const Map<String, String> builtInReplyCatalogs = <String, String>{',
    );
  for (final style in ReplyStyles.builtIn) {
    final text = File('assets/replies/$style.json').readAsStringSync();
    if (text.contains("'''")) {
      throw StateError('В $style.json есть три апострофа подряд');
    }
    buffer
      ..writeln("  '$style': r'''")
      ..write(text)
      ..writeln("''',");
  }
  buffer.writeln('};');
  return buffer.toString();
}
