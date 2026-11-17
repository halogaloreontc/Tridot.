// Плитка «Конвертер» в «Настройки → Расширения» (ADR-024, шаг 2): на
// платформе без ffmpeg — «только картинки»; на компьютере — статус ffmpeg,
// «Настроить» → экран загрузки; включение предлагает скачать ffmpeg с
// размером и источником.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/app/widgets/extensions_section.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:path/path.dart' as p;

final List<int> _archive = utf8.encode('ffmpeg');

final class _Downloader implements FileDownloader {
  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    await partFile.parent.create(recursive: true);
    // Разреженный файл нужного размера: место на диске не тратится.
    final file = partFile.openSync(mode: FileMode.write)
      ..truncateSync(expectedBytes);
    file.closeSync();
    yield DownloadProgress(expectedBytes, expectedBytes);
  }
}

ToolSpec _spec() => ToolSpec(
      id: 'ffmpeg',
      title: 'ffmpeg',
      abi: Abi.linuxX64,
      version: 'v1',
      url: 'https://github.com/x/y/releases/download/t/ff.tar.xz',
      sha256: crypto.sha256.convert(_archive).toString(),
      bytes: 170 * 1024 * 1024,
      archive: ToolArchive.tarXz,
      entry: 'ff/bin/ffmpeg',
      binaryName: 'ffmpeg',
      binaryBytes: 134 * 1024 * 1024,
      license: 'LGPL-3.0',
      sourceUrl: 'https://github.com/x/y',
    );

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('converter_tile'));
  tearDown(() => temp.deleteSync(recursive: true));

  ToolKit kit() => ToolKit(
        spec: _spec(),
        downloader: _Downloader(),
        dir: p.join(temp.path, 'ffmpeg'),
        // Размер в спецификации — как у настоящей сборки: архив не
        // читаем, его сумма считается совпавшей.
        hasher: (File f) async => f.path.endsWith('.part')
            ? crypto.sha256.convert(_archive).toString()
            : crypto.sha256.convert(f.readAsBytesSync()).toString(),
        extractor: (ToolSpec s, String a, String d, String t) async {
          final file = File(p.join(d, s.entry));
          await file.parent.create(recursive: true);
          await file.writeAsString('программа');
        },
        chmod: (String path) async {},
      );

  Future<List<AppSettings>> pump(
    WidgetTester tester, {
    required bool enabled,
    ToolKit? ffmpeg,
    NativeMediaCaps nativeMedia = NativeMediaCaps.none,
  }) async {
    final changes = <AppSettings>[];
    final registry = ExtensionRegistry(
      connectors: <Connector>[ConverterConnector()],
      choice: ExtensionChoice(
        enabled: <String>{if (enabled) ConverterConnector.id},
      ),
    );
    var settings = const AppSettings().withChoice(registry.choice);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                SingleChildScrollView(
              child: ExtensionsSection(
                registry: registry,
                settings: settings,
                ffmpeg: ffmpeg,
                nativeMedia: nativeMedia,
                onChanged: (AppSettings value) {
                  changes.add(value);
                  registry.apply(value.extensionChoice);
                  setState(() => settings = value);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return changes;
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(
        find.byKey(const ValueKey<String>('extension-status-converter')),
      )
      .data!;

  testWidgets('без ffmpeg на платформе — только картинки, без «Настроить»',
      (WidgetTester tester) async {
    await pump(tester, enabled: true);
    expect(status(tester), contains('Только картинки'));
    expect(
      find.byKey(const ValueKey<String>('extension-configure-converter')),
      findsNothing,
    );
  });

  testWidgets(
      'телефон или Mac с системными кодировщиками — не «только '
      'картинки», а что делает система', (WidgetTester tester) async {
    await pump(
      tester,
      enabled: true,
      nativeMedia: const NativeMediaCaps(
        targets: <String>{
          'mp3',
          'm4a',
          'wav',
          'mp4',
          'frame-jpeg',
          'frame-png',
        },
      ),
    );
    expect(status(tester), isNot(contains('Только картинки')));
    expect(
      status(tester),
      'Картинки; звук и видео — средствами системы: mp3, m4a, wav, mp4, кадр',
    );
  });

  testWidgets('«Настроить» → «Скачать» → ffmpeg установлен',
      (WidgetTester tester) async {
    final ffmpeg = kit();
    await pump(tester, enabled: true, ffmpeg: ffmpeg);
    expect(status(tester), contains('не скачан'));
    await tester.tap(
      find.byKey(const ValueKey<String>('extension-configure-converter')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('~170 МБ'), findsWidgets);
    expect(find.textContaining('LGPL'), findsWidgets);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('tool-download')));
      for (var i = 0; i < 100 && !ffmpeg.isInstalled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(ffmpeg.isInstalled, isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('tool-status')))
          .data,
      contains('установлен'),
    );
    expect(find.byKey(const ValueKey<String>('tool-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tool-download')), findsNothing);
  });

  testWidgets('включение предлагает скачать ffmpeg; «Позже» — без загрузки',
      (WidgetTester tester) async {
    final ffmpeg = kit();
    final changes = await pump(tester, enabled: false, ffmpeg: ffmpeg);
    await tester.tap(find.byKey(const ValueKey<String>('extension-converter')));
    await tester.pumpAndSettle();
    expect(changes.last.enabledExtensions, contains(ConverterConnector.id));
    expect(find.text('Скачать ffmpeg?'), findsOneWidget);
    expect(find.textContaining('~170 МБ'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey<String>('tool-offer-later')));
    await tester.pumpAndSettle();
    expect(ffmpeg.phase, ToolPhase.notInstalled);
    expect(find.text('Скачать ffmpeg?'), findsNothing);
  });
}
