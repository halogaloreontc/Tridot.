import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/gen/gen_kit.dart';
import 'package:local_assistant/app/gen/gen_section.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:path/path.dart' as p;

import 'gen_fakes.dart';

final class _Transport implements HttpTransport {
  String? body;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    final b = body;
    return b == null
        ? const HttpResponseData(statusCode: 404)
        : HttpResponseData(statusCode: 200, body: b);
  }
}

final class _Rig {
  _Rig(this.kit, this.transport, this.downloader);

  final GenKit kit;
  final _Transport transport;
  final PartsDownloader downloader;
  AppSettings settings = const AppSettings();

  void publish() {
    transport.body = publishGen(
      downloader,
      '1.0.0',
      List<int>.generate(3000, (i) => i % 251),
    );
  }
}

Future<_Rig> _rig(WidgetTester tester, {int? ram = 16000}) async {
  final temp = Directory.systemTemp.createTempSync('gen_section_test');
  addTearDown(() => temp.deleteSync(recursive: true));
  final transport = _Transport();
  final downloader = PartsDownloader();
  final kit = GenKit(
    transport: transport,
    downloader: downloader,
    root: p.join(temp.path, 'gen'),
    opener: (_) async => null,
    ram: () async => ram,
    hasher: (File f) async =>
        crypto.sha256.convert(await f.readAsBytes()).toString(),
  );
  addTearDown(kit.dispose);
  await tester.runAsync(kit.refresh);
  return _Rig(kit, transport, downloader);
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.light(),
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => Scaffold(
          body: SingleChildScrollView(
            child: GenSettingsSection(
              settings: rig.settings,
              gen: rig.kit,
              onChanged: (AppSettings next) {
                setState(() => rig.settings = next);
                unawaited(rig.kit.apply(next));
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 4000 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets('включить: подтверждение с размером и Wi‑Fi, загрузка, готово',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish();
    await _pump(tester, rig);
    expect(find.text('Продвинутая'), findsOneWidget);
    expect(find.textContaining('скачивается по выбору'), findsOneWidget);
    expect(find.byKey(const Key('gen-delete')), findsNothing);

    await tester.tap(find.byKey(const Key('setting-gen')));
    await tester.pumpAndSettle();
    expect(find.text('Скачать «Продвинутую»?'), findsOneWidget);
    expect(find.textContaining('лучше скачивать по Wi‑Fi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gen-download-confirm')));
    await tester.pump();
    expect(rig.settings.genEnabled, isTrue);
    await _until(tester, () => rig.kit.installed != null && !rig.kit.isBusy);
    await tester.pump();
    expect(find.textContaining('Включена'), findsOneWidget);
    expect(find.byKey(const Key('gen-delete')), findsOneWidget);
    expect(find.byKey(const Key('gen-check')), findsOneWidget);
  });

  testWidgets('«Отмена» в подтверждении — ничего не скачивается',
      (tester) async {
    final rig = await _rig(tester);
    rig.publish();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const Key('setting-gen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gen-download-cancel')));
    await tester.pumpAndSettle();
    expect(rig.settings.genEnabled, isFalse);
    expect(rig.downloader.calls, 0);
  });

  testWidgets('мало памяти — переключатель недоступен, причина в подписи',
      (tester) async {
    final rig = await _rig(tester, ram: 5900);
    await _pump(tester, rig);
    expect(
      find.textContaining('Нужно от 8 ГБ памяти, на этом устройстве 5.8 ГБ'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('setting-gen')));
    await tester.pumpAndSettle();
    expect(find.text('Скачать «Продвинутую»?'), findsNothing);
    expect(rig.settings.genEnabled, isFalse);
  });

  testWidgets('удалить: подтверждение, выключено', (tester) async {
    final rig = await _rig(tester);
    rig.publish();
    await tester.runAsync(rig.kit.install);
    rig.settings = const AppSettings(genEnabled: true);
    await _pump(tester, rig);
    await tester.tap(find.byKey(const Key('gen-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gen-delete-confirm')));
    await _until(tester, () => rig.kit.installed == null);
    await tester.pump();
    expect(rig.settings.genEnabled, isFalse);
    expect(find.byKey(const Key('gen-delete')), findsNothing);
  });
}
