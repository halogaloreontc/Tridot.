import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Граф импортов веб-помощника (ADR-032): `flutter build web` собирает
/// всё, что импортирует `lib/web_widget/main.dart`. Плагины без веба и
/// `dart:ffi` в нём не нужны и ломали бы сборку или работу; `dart:io` в
/// вебе — заглушки, которые бросают ошибку только при вызове: можно лишь в
/// файлах из [ioStubOk], код которых помощник не вызывает.
const Set<String> forbidden = <String>{
  'dart:ffi',
  'package:path_provider',
  'package:file_selector',
  'package:mobile_scanner',
  'package:record',
  'package:tridot_lame',
  'package:ffi',
  // Модель понимания в приложении (ADR-045): у помощника — onnxruntime-web.
  'package:onnxruntime_v2',
};

/// Файлы, которые тянут `dart:io`, а помощник их файловый код не вызывает:
/// паки (помощник — `PackStore.memory`), вложения и хранилище чатов
/// (модели сообщений), размещение файлов задач расширений. Новый файл
/// здесь — повод вынести его файловую часть отдельно, как
/// `connection_store_io.dart`.
const Set<String> ioStubOk = <String>{
  'lib/core/extensions/pack_store.dart',
  'lib/core/chats/attachments.dart',
  'lib/core/chats/chat_store.dart',
  'lib/core/jobs/job_placement.dart',
};

/// Путь коннектора склада и сам помощник — без `dart:io` вовсе.
const List<String> ioFree = <String>[
  'lib/web_widget/',
  'lib/core/connectors/manifest/connection.dart',
  'lib/core/connectors/manifest/connection_service.dart',
  'lib/core/connectors/manifest/manifest_connector.dart',
  'lib/core/connectors/http_transport.dart',
  // Запасной слой понимания (ADR-045): ядро без файлов — их часть в
  // intent_io.dart.
  'lib/core/intent/intent_fallback.dart',
  'lib/core/intent/intent_memory.dart',
  'lib/core/intent/intent_pack.dart',
  'lib/core/intent/intent_tokenizer.dart',
  'lib/core/intent/intent_http.dart',
];

/// Только браузер (`package:web`, `dart:js_interop`): эти файлы
/// импортирует лишь точка входа помощника `main.dart`, ни тесты на VM, ни
/// приложение. `intent_web.dart` — onnxruntime-web модели понимания
/// (ADR-045, шаг 4).
const Set<String> browserOnly = <String>{
  'lib/web_widget/browser_host.dart',
  'lib/web_widget/fetch_transport.dart',
  'lib/web_widget/intent_web.dart',
};

bool _browserImport(String dep) =>
    dep == 'dart:js_interop' ||
    dep == 'dart:js_interop_unsafe' ||
    dep == 'dart:html' ||
    dep == 'dart:js_util' ||
    dep.startsWith('package:web/');

final RegExp _import = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

Map<String, Set<String>> graph(String entry) {
  final out = <String, Set<String>>{};
  final queue = <String>[entry];
  while (queue.isNotEmpty) {
    final file = queue.removeLast();
    if (out.containsKey(file)) continue;
    final deps = <String>{};
    out[file] = deps;
    for (final m in _import.allMatches(File(file).readAsStringSync())) {
      final target = m.group(1)!;
      if (target.startsWith('dart:') || target.startsWith('package:')) {
        if (target.startsWith('package:local_assistant/')) {
          final path =
              'lib/${target.substring('package:local_assistant/'.length)}';
          deps.add(path);
          queue.add(path);
        } else {
          deps.add(target);
        }
        continue;
      }
      final path = Uri.parse(file).resolve(target).path;
      deps.add(path);
      queue.add(path);
    }
  }
  return out;
}

void main() {
  final files = graph('lib/web_widget/main.dart');

  test('нет плагинов без веба и dart:ffi', () {
    final bad = <String>[
      for (final MapEntry(:key, :value) in files.entries)
        for (final dep in value)
          if (forbidden.any((String f) => dep == f || dep.startsWith('$f/')))
            '$key → $dep',
    ];
    expect(bad, isEmpty);
  });

  test('dart:io — только в известных заглушках', () {
    final io = <String>{
      for (final MapEntry(:key, :value) in files.entries)
        if (value.contains('dart:io')) key,
    };
    expect(io.difference(ioStubOk), isEmpty);
    for (final path in io) {
      expect(
        ioFree.any((String p) => path.startsWith(p)),
        isFalse,
        reason: path,
      );
    }
  });

  test('путь коннектора склада в графе помощника', () {
    for (final path in ioFree.skip(1)) {
      expect(files.containsKey(path), isTrue, reason: path);
    }
    expect(
      files
          .containsKey('lib/core/connectors/manifest/connection_store_io.dart'),
      isFalse,
    );
    expect(files.containsKey('lib/core/intent/intent_http.dart'), isTrue);
    expect(files.containsKey('lib/web_widget/intent_web.dart'), isTrue);
    // Модель приложения и файлы пакета — не в помощнике (ADR-045).
    expect(files.containsKey('lib/core/intent/intent_io.dart'), isFalse);
    expect(
      files.keys.where((String f) => f.startsWith('lib/app/intent/')),
      isEmpty,
    );
  });

  test('браузерные файлы — только у точки входа помощника', () {
    final browser = <String>{
      for (final MapEntry(:key, :value) in files.entries)
        if (value.any(_browserImport)) key,
    };
    expect(browser.difference(browserOnly), isEmpty);
    // Их импортирует только main.dart помощника.
    for (final MapEntry(:key, :value) in files.entries) {
      if (key == 'lib/web_widget/main.dart') continue;
      expect(value.intersection(browserOnly), isEmpty, reason: key);
    }
    // Ни приложение, ни тесты на VM их не тянут.
    final app = graph('lib/main.dart');
    expect(app.keys.toSet().intersection(browserOnly), isEmpty);
    expect(
      app.keys.where((String f) => f.startsWith('lib/web_widget/')),
      isEmpty,
    );
    final tests = Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));
    for (final file in tests) {
      final text = file.readAsStringSync();
      for (final name in browserOnly) {
        expect(
          text.contains(name.substring('lib/'.length)) &&
              !file.path.endsWith('web_graph_test.dart'),
          isFalse,
          reason: '${file.path} → $name',
        );
      }
    }
  });
}
