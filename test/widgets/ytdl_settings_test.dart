// Плитка «Загрузчик видео» в «Настройки → Расширения» (ADR-024, шаг 3):
// включение — только после предупреждения о правилах площадок, затем
// предложение скачать yt-dlp; «Настроить» — скачать, «Обновить» (только
// до версии, закреплённой в приложении), папка загрузок. Нет навыка в
// сборке (Android, macOS, Google Play) — нет и плитки.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/app/extensions/ytdl_kit.dart';
import 'package:local_assistant/app/extensions/ytdl_settings.dart';
import 'package:local_assistant/app/widgets/extensions_section.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_unavailable.dart';
import 'package:path/path.dart' as p;

final List<int> _binary = utf8.encode('yt-dlp');

/// Следующее сообщение [kit] о смене: setFolder шлёт его после записи
/// файла настроек.
Future<void> _changed(YtdlKit kit) {
  final done = Completer<void>();
  void listener() {
    kit.removeListener(listener);
    done.complete();
  }

  kit.addListener(listener);
  return done.future;
}

final class _Downloader implements FileDownloader {
  int calls = 0;

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    calls++;
    await partFile.parent.create(recursive: true);
    await partFile.writeAsBytes(_binary);
    yield DownloadProgress(expectedBytes, expectedBytes);
  }
}

ToolSpec _spec() => ToolSpec(
      id: 'ytdlp',
      title: 'yt-dlp',
      abi: Abi.linuxX64,
      version: '2026.10.26',
      url: 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/'
          'yt-dlp_linux',
      sha256: crypto.sha256.convert(_binary).toString(),
      bytes: _binary.length,
      archive: ToolArchive.none,
      entry: '',
      binaryName: 'yt-dlp',
      binaryBytes: _binary.length,
      license: 'Unlicense / GPLv3+',
      sourceUrl: 'https://github.com/yt-dlp/yt-dlp',
    );

void main() {
  late Directory temp;
  late _Downloader downloader;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ytdl_tile');
    downloader = _Downloader();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  YtdlKit kit() => YtdlKit(
        tool: ToolKit(
          spec: _spec(),
          downloader: downloader,
          dir: p.join(temp.path, 'tools', 'ytdlp'),
          chmod: (String path) async {},
        ),
        settingsPath: p.join(temp.path, 'ytdl.json'),
        defaultRoot: () async => p.join(temp.path, 'Загрузки'),
      );

  Future<List<AppSettings>> pump(
    WidgetTester tester, {
    required bool enabled,
    YtdlKit? ytdl,
    bool registered = true,
    YtdlUnavailableReason? unavailable,
  }) async {
    final changes = <AppSettings>[];
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        ConverterConnector(),
        if (registered) YtdlConnector(),
        if (unavailable != null) YtdlUnavailableConnector(unavailable),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (enabled) YtdlConnector.id},
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
                ytdl: ytdl,
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

  const tile = ValueKey<String>('extension-ytdl');

  testWidgets('нет навыка в сборке — нет и плитки',
      (WidgetTester tester) async {
    await pump(tester, enabled: false, registered: false);
    expect(find.byKey(tile), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('extension-converter')),
      findsOneWidget,
    );
  });

  testWidgets('Android: вместо плитки — приглушённая строка, почему',
      (WidgetTester tester) async {
    await pump(
      tester,
      enabled: false,
      registered: false,
      unavailable: YtdlUnavailableReason.android,
    );
    expect(find.byKey(tile), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('extension-unavailable-ytdl')),
      findsOneWidget,
    );
    expect(
      find.text('Загрузчик видео — только в версиях для Windows и Linux'),
      findsOneWidget,
    );
  });

  testWidgets('сборка для Google Play: ни плитки, ни строки',
      (WidgetTester tester) async {
    await pump(
      tester,
      enabled: false,
      registered: false,
      unavailable: YtdlUnavailableReason.build,
    );
    expect(find.byKey(tile), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('extension-unavailable-ytdl')),
      findsNothing,
    );
  });

  testWidgets('включение: сначала предупреждение; «Отмена» — не включён',
      (WidgetTester tester) async {
    final changes = await pump(tester, enabled: false, ytdl: kit());
    await tester.tap(find.byKey(tile));
    await tester.pumpAndSettle();
    final warning = tester
        .widget<Text>(find.byKey(const ValueKey<String>('ytdl-warning-text')))
        .data!;
    expect(warning, contains('Правила YouTube'));
    expect(warning, contains('только своё'));
    expect(changes, isEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('ytdl-warning-cancel')));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(tester.widget<SwitchListTile>(find.byKey(tile)).value, isFalse);
  });

  testWidgets('«Понятно, включить» — включён и предложение скачать yt-dlp',
      (WidgetTester tester) async {
    final ytdl = kit();
    final changes = await pump(tester, enabled: false, ytdl: ytdl);
    await tester.tap(find.byKey(tile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ytdl-warning-accept')));
    await tester.pumpAndSettle();
    expect(changes.last.enabledExtensions, contains(YtdlConnector.id));
    expect(find.text('Скачать yt-dlp?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('tool-offer-later')));
    await tester.pumpAndSettle();
    expect(downloader.calls, 0);
    expect(ytdl.tool.phase, ToolPhase.notInstalled);
  });

  testWidgets('«Настроить»: скачать, «Обновить» — последняя известная версия',
      (WidgetTester tester) async {
    final ytdl = kit();
    await pump(tester, enabled: true, ytdl: ytdl);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('extension-status-ytdl')),
          )
          .data,
      contains('не скачан'),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('extension-configure-ytdl')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Загрузчик видео: yt-dlp'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('ytdl-folder')))
          .data,
      p.join(temp.path, 'Загрузки', 'Tridot'),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('tool-download')));
      for (var i = 0; i < 500 && !ytdl.tool.isInstalled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(ytdl.tool.isInstalled, isTrue);
    await tester.tap(find.byKey(const ValueKey<String>('tool-update')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('tool-update-note')))
          .data,
      contains('последняя версия, известная приложению'),
    );
    expect(downloader.calls, 1);
  });

  testWidgets('папка загрузок: выбрать и вернуть по умолчанию',
      (WidgetTester tester) async {
    final ytdl = kit();
    final chosen = p.join(temp.path, 'Видео');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YtdlFolderSetting(
            kit: ytdl,
            pickFolder: (String? initial) async => chosen,
          ),
        ),
      ),
    );
    // Ждём сохранения (setFolder сообщает о смене после записи файла), а
    // не время: сколько идёт запись на диск, не задано, под нагрузкой
    // 50 мс может не хватить.
    await tester.runAsync(() async {
      final saved = _changed(ytdl);
      await tester
          .tap(find.byKey(const ValueKey<String>('ytdl-folder-change')));
      await saved;
    });
    await tester.pumpAndSettle();
    expect(await tester.runAsync(ytdl.folder), chosen);
    // Сохранилось для следующего запуска.
    final again = kit();
    await tester.runAsync(again.load);
    expect(again.customFolder, chosen);
    await tester.runAsync(() async {
      final saved = _changed(ytdl);
      await tester.tap(find.byKey(const ValueKey<String>('ytdl-folder-reset')));
      await saved;
    });
    await tester.pumpAndSettle();
    expect(ytdl.customFolder, isNull);
    final reset = kit();
    await tester.runAsync(reset.load);
    expect(reset.customFolder, isNull);
  });
}
