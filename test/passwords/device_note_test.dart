import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';

void main() {
  const p = PasswordsPlatform.android;

  test('один способ — «без него», два — «без них»', () {
    expect(p.deviceNote(pin: true), contains('без него'));
    expect(p.deviceNote(bio: true), contains('без него'));
    expect(p.deviceNote(pin: true, bio: true), contains('без них'));
  });

  test('остался только код восстановления — так и сказано', () {
    final note = p.deviceNote(codeOnly: true);
    expect(note, contains('только кодом восстановления'));
    expect(note, isNot(contains('открывается сам')));
  });
}
