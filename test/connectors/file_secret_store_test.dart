import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/file_secret_store.dart';

void main() {
  test('секреты переживают перезапуск, удаляются, файл — только владельца',
      () async {
    final dir = await Directory.systemTemp.createTemp('secrets');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/assistant/secrets.json';
    final store = FileSecretStore(path);
    expect(await store.read('warehouse.token'), isNull);
    await store.write('warehouse.token', 'fake-token-not-real');
    await store.write('warehouse.sid', 'fake-sid-not-real');

    final again = FileSecretStore(path);
    expect(await again.read('warehouse.token'), 'fake-token-not-real');
    await again.delete('warehouse.sid');
    expect(await FileSecretStore(path).read('warehouse.sid'), isNull);
    if (Platform.isLinux || Platform.isMacOS) {
      final mode = (await File(path).stat()).mode & 0x1ff;
      expect(mode, 0x180, reason: 'права 600');
    }
  });

  test('битый файл — секретов нет, запуск не падает', () async {
    final dir = await Directory.systemTemp.createTemp('secrets');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/secrets.json';
    File(path).writeAsStringSync('{не json');
    expect(await FileSecretStore(path).read('warehouse.token'), isNull);
  });
}
