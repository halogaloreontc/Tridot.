// Склонение после числа: «1 день», «2 дня», «5 дней», 11–14 — «дней».
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/formatting/plural.dart';

void main() {
  test('дни', () {
    expect(days(1), '1 день');
    expect(days(2), '2 дня');
    expect(days(4), '4 дня');
    expect(days(5), '5 дней');
    expect(days(11), '11 дней');
    expect(days(14), '14 дней');
    expect(days(21), '21 день');
    expect(days(22), '22 дня');
    expect(days(0), '0 дней');
    expect(days(111), '111 дней');
  });

  test('дела', () {
    expect(deeds(1), '1 дело');
    expect(deeds(3), '3 дела');
    expect(deeds(7), '7 дел');
  });
}
