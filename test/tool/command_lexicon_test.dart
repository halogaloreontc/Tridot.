// Словарь команд для исправления опечаток (TypoFix) собран из корпуса:
// после правки корпуса — dart run tool/gen_lexicon.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/scenario/command_lexicon.g.dart';

import '../../tool/gen_lexicon.dart' as gen;

void main() {
  test('command_lexicon.g.dart совпадает с корпусом', () {
    expect(
      File(gen.output).readAsStringSync(),
      gen.generate(),
      reason: 'запустите dart run tool/gen_lexicon.dart',
    );
  });

  test('в словаре нет опечаток частых слов и названий из корпуса', () {
    for (final typo in <String>['пеернеси', 'дабавь', 'завра', 'калбасу']) {
      expect(commandLexicon.containsKey(typo), isFalse, reason: typo);
    }
    for (final word in <String>['добавь', 'завтра', 'будильник', 'сколько']) {
      expect(commandLexicon.containsKey(word), isTrue, reason: word);
    }
  });

  test('настоящие слова рядом с командами в словарь не мешают', () {
    for (final word in <String>['выключи', 'наполни', 'записи']) {
      expect(Utterance.isRealWord(word), isTrue, reason: word);
    }
  });
}
