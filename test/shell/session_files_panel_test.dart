// Правая панель «Файлы сессии» (ADR-028): группы «Артефакты» и
// «Вложения», подписи, открытие, меню, пустое состояние — в обеих темах.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/shell/session_files_panel.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/session_files.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';

import '../support/app_fonts.dart';

final _now = DateTime(2026, 11, 4, 15);

/// Хранилище вложений «на диске» без диска: путь — `/chats/<путь>`,
/// [missing] — каких копий нет.
final class _Store implements AttachmentStore {
  _Store({this.memory = false, this.missing = const <String>{}});

  final bool memory;
  final Set<String> missing;

  @override
  String? pathOf(ChatAttachment attachment) =>
      memory ? null : '/chats/${attachment.path}';

  @override
  bool exists(ChatAttachment attachment) => !missing.contains(attachment.id);

  @override
  Uint8List? bytesOf(ChatAttachment attachment) => null;

  @override
  bool get persistent => !memory;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ChatAttachment _att(String id, String name, DateTime at, int size) =>
    ChatAttachment(
      id: id,
      kind: AttachmentKind.of(name),
      name: name,
      path: 'files/session-1/$id.${AttachmentKind.extensionOf(name)}',
      size: size,
      addedAt: at,
    );

SessionFile _attachment(ChatAttachment a, String messageId) => SessionFile(
      id: 'att:${a.id}',
      source: SessionFileSource.attachment,
      name: a.name,
      kind: a.kind,
      archive: SessionFile.isArchiveName(a.name),
      size: a.size,
      at: a.addedAt,
      messageId: messageId,
      attachment: a,
    );

SessionFile _output(
  String card,
  String path,
  DateTime at, {
  String ext = ExtensionForms.converter,
  String messageId = 'm_out',
}) {
  final name = path.split('/').last;
  return SessionFile(
    id: 'out:$card:0',
    source: SessionFileSource.output,
    name: name,
    kind: AttachmentKind.of(name),
    archive: SessionFile.isArchiveName(name),
    at: at,
    messageId: messageId,
    extensionId: ext,
    absolute: path,
  );
}

final _photo =
    _att('m1-0', 'Дача летом.jpg', DateTime(2026, 11, 3, 18), 849920);
final _report = _att('m2-0', 'Отчёт за ноябрь.pdf', _now, 2516582);

/// Результаты: конвертер сегодня, архив вчера, папка-распаковка.
final _outputs = <SessionFile>[
  _output('j1', '/out/j1/Запись встречи.mp3', DateTime(2026, 11, 4, 14, 5)),
  _output(
    'j2',
    '/out/j2/Фото дачи.zip',
    DateTime(2026, 11, 3, 9),
    ext: ExtensionForms.archiver,
  ),
  _output(
    'j3',
    '/out/j3/Распакованное',
    DateTime(2026, 11, 1, 9),
    ext: ExtensionForms.archiver,
  ),
];

SessionFileStat _stat(String path) => switch (path) {
      '/out/j1/Запись встречи.mp3' => (
          exists: true,
          folder: false,
          size: 2516582,
        ),
      '/out/j2/Фото дачи.zip' => (exists: false, folder: false, size: null),
      _ => (exists: true, folder: true, size: null),
    };

final class _Harness {
  final opened = <(String, String?)>[];
  final revealed = <String>[];
  final shown = <String>[];
  final messages = <String>[];
  var closed = 0;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  ThemeData? theme,
  List<SessionFile>? outputs,
  List<SessionFile>? attachments,
  AttachmentStore? store,
  JobPlatform platform = JobPlatform.linux,
  bool openResult = true,
  Size size = const Size(360, 800),
  SessionFileStatter? stat,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _Harness();
  const channel = MethodChannel('test/session-files');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>;
    h.opened.add((args['path']! as String, args['name'] as String?));
    return openResult;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  final opener = FileOpener(
    platform: platform,
    channel: channel,
    start: (
      String exe,
      List<String> args, {
      bool runInShell = false,
      ProcessStartMode mode = ProcessStartMode.normal,
    }) async {
      if (!openResult) throw const ProcessException('x', <String>[]);
      if (exe == 'xdg-open' && args.single.startsWith('/out/j3') ||
          args.single == '/out' ||
          args.single == '/out/j1' ||
          args.single == '/chats/files/session-1') {
        h.revealed.add(args.single);
      } else {
        h.opened.add((args.single, null));
      }
      return _FakeProcess();
    },
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AssistantTheme.light(),
      home: Scaffold(
        body: SessionFilesPanel(
          outputs: outputs ?? _outputs,
          attachments: attachments ??
              <SessionFile>[
                _attachment(_report, 'm2'),
                _attachment(_photo, 'm1'),
              ],
          store: store ?? _Store(),
          opener: opener,
          now: _now,
          stat: stat ?? _stat,
          onShowInMessage: h.shown.add,
          onMessage: h.messages.add,
          onClose: () => h.closed++,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

String _subtitleOf(WidgetTester tester, String id) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(Key('session-file-$id')),
          matching: find.byType(Text),
        ),
      )
      .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      // Узкая строка делится между частями без «·» (metaLines): сверяем
      // части, а не то, куда пришёлся перенос.
      .map((String t) => t.replaceAll('\n', '\u00A0· '))
      .toList();
  return texts.join(' | ');
}

void main() {
  for (final (label, theme) in <(String, ThemeData Function())>[
    ('светлая', AssistantTheme.light),
    ('тёмная', AssistantTheme.dark),
  ]) {
    group(label, () {
      testWidgets('пусто — подсказка, без групп', (tester) async {
        await _pump(
          tester,
          theme: theme(),
          outputs: const <SessionFile>[],
          attachments: const <SessionFile>[],
        );
        expect(find.text('Файлы сессии'), findsOneWidget);
        expect(find.byKey(const Key('session-files-empty')), findsOneWidget);
        expect(find.text('Здесь пока пусто'), findsOneWidget);
        expect(find.textContaining('конвертер, архиватор'), findsOneWidget);
        expect(find.text('Артефакты'), findsNothing);
        expect(find.text('Вложения'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('группы, подписи, без рамок и градиентов', (tester) async {
        await _pump(tester, theme: theme());
        expect(find.text('Артефакты'), findsOneWidget);
        expect(find.text('Вложения'), findsOneWidget);
        expect(
          _subtitleOf(tester, 'out:j1:0'),
          'Запись встречи.mp3 | Конвертер\u00A0· 2,4\u00A0МБ\u00A0· 14:05',
        );
        expect(
          _subtitleOf(tester, 'out:j3:0'),
          'Распакованное | Архиватор\u00A0· папка\u00A0· 1\u00A0ноября',
        );
        expect(
          _subtitleOf(tester, 'att:m1-0'),
          'Дача летом.jpg | Фото\u00A0· 830\u00A0КБ\u00A0· вчера',
        );
        expect(
          _subtitleOf(tester, 'att:m2-0'),
          'Отчёт за ноябрь.pdf | Документ\u00A0· 2,4\u00A0МБ\u00A0· 15:00',
        );
        // Нет файла на диске.
        expect(
          _subtitleOf(tester, 'out:j2:0'),
          'Фото дачи.zip | Файла больше нет',
        );
        for (final box in tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('session-files-panel')),
            matching: find.byType(DecoratedBox),
          ),
        )) {
          final decoration = box.decoration;
          if (decoration is BoxDecoration) {
            expect(decoration.gradient, isNull);
            expect(decoration.border, isNull);
          }
        }
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('только вложения — без группы «Артефакты»', (tester) async {
    await _pump(tester, outputs: const <SessionFile>[]);
    expect(find.text('Артефакты'), findsNothing);
    expect(find.text('Вложения'), findsOneWidget);
  });

  testWidgets('нажатие открывает файл; у вложения — имя для показа',
      (tester) async {
    final h = await _pump(tester, platform: JobPlatform.android);
    await tester.tap(find.text('Запись встречи.mp3'));
    await tester.pumpAndSettle();
    expect(h.opened.single, ('/out/j1/Запись встречи.mp3', null));
    h.opened.clear();
    await tester.tap(find.text('Отчёт за ноябрь.pdf'));
    await tester.pumpAndSettle();
    expect(
      h.opened.single,
      ('/chats/${_report.path}', 'Отчёт за ноябрь.pdf'),
    );
    // Папку на телефоне открыть нечем — к сообщению.
    h.opened.clear();
    await tester.tap(find.text('Распакованное'));
    await tester.pumpAndSettle();
    expect(h.opened, isEmpty);
    expect(h.shown, <String>['m_out']);
    // Файла нет — тоже к сообщению.
    await tester.tap(find.text('Фото дачи.zip'));
    await tester.pumpAndSettle();
    expect(h.shown, <String>['m_out', 'm_out']);
    expect(h.messages, isEmpty);
  });

  testWidgets('не открылось — «Не удалось открыть файл»', (tester) async {
    final h = await _pump(
      tester,
      platform: JobPlatform.android,
      openResult: false,
    );
    await tester.tap(find.text('Запись встречи.mp3'));
    await tester.pumpAndSettle();
    expect(h.messages, <String>['Не удалось открыть файл']);
  });

  testWidgets('хранилище в памяти: нажатие — сведения о файле', (tester) async {
    final h = await _pump(tester, store: _Store(memory: true));
    await tester.tap(find.text('Дача летом.jpg'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-info')), findsOneWidget);
    expect(h.opened, isEmpty);
  });

  testWidgets('нет копии вложения — «Файла больше нет»', (tester) async {
    final h = await _pump(tester, store: _Store(missing: <String>{'m1-0'}));
    expect(
      _subtitleOf(tester, 'att:m1-0'),
      'Дача летом.jpg | Файла больше нет',
    );
    await tester.tap(find.text('Дача летом.jpg'));
    await tester.pumpAndSettle();
    expect(h.shown, <String>['m1']);
  });

  testWidgets('меню: на компьютере «Показать в папке», у вложения «Сведения»',
      (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const Key('session-file-more-out:j1:0')));
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
    expect(find.text('Показать в сообщении'), findsOneWidget);
    expect(find.text('Показать в папке'), findsOneWidget);
    expect(find.text('Сведения'), findsNothing);
    await tester.tap(find.text('Показать в папке'));
    await tester.pumpAndSettle();
    expect(h.revealed, <String>['/out/j1']);

    await tester.tap(find.byKey(const Key('session-file-more-att:m1-0')));
    await tester.pumpAndSettle();
    expect(find.text('Сведения'), findsOneWidget);
    await tester.tap(find.text('Показать в сообщении'));
    await tester.pumpAndSettle();
    expect(h.shown, <String>['m1']);

    // Долгое нажатие по строке — то же меню.
    await tester.longPress(find.text('Отчёт за ноябрь.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сведения'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-info')), findsOneWidget);
  });

  testWidgets('меню на телефоне — без «Показать в папке»', (tester) async {
    await _pump(tester, platform: JobPlatform.android);
    await tester.tap(find.byKey(const Key('session-file-more-out:j1:0')));
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
    expect(find.text('Показать в папке'), findsNothing);
    expect(find.text('Сведения'), findsNothing);
  });

  testWidgets('закрыть — onClose', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const Key('session-files-close')));
    expect(h.closed, 1);
  });

  testWidgets('диктор: строка — кнопка с подписью, «⋯» отдельно, заголовок',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    final row = find.bySemanticsLabel(
      'Запись встречи.mp3, Конвертер\u00A0· 2,4\u00A0МБ\u00A0· 14:05',
    );
    expect(row, findsOneWidget);
    expect(
      tester.getSemantics(row),
      isSemantics(
        isButton: true,
        hint: 'Открыть',
        hasTapAction: true,
        hasLongPressAction: true,
      ),
    );
    expect(find.byTooltip('Действия: Запись встречи.mp3'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Файлы сессии')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
  });

  testWidgets(
      'узкая панель, крупный шрифт: «·» не висит ни в начале, ни в конце строки',
      (tester) async {
    // Настоящий шрифт: тестовый рисует буквы квадратами, и «Конвертер ·»
    // в нём не помещается в строку даже целиком.
    await tester.runAsync(loadAppFonts);
    for (final (width, scale) in <(double, double)>[(320, 1.3), (360, 2)]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, size: Size(width, 800));
      for (final id in <String>['out:j1:0', 'out:j3:0', 'att:m1-0']) {
        final paragraphs = tester.renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byKey(Key('session-file-$id')),
            matching: find.byType(RichText),
          ),
        );
        for (final paragraph in paragraphs) {
          final text = paragraph.text.toPlainText();
          final painter = TextPainter(
            text: paragraph.text,
            textDirection: TextDirection.ltr,
            textScaler: paragraph.textScaler,
          )..layout(maxWidth: paragraph.constraints.maxWidth);
          addTearDown(painter.dispose);
          for (var i = 0; i < text.length; i++) {
            if (text[i] != '·') continue;
            final line = painter.getLineBoundary(TextPosition(offset: i));
            expect(
              text.substring(line.start, i).trim(),
              isNotEmpty,
              reason: '$width×$scale: «$text»',
            );
            expect(
              text.substring(i + 1, line.end).trim(),
              isNotEmpty,
              reason: '$width×$scale: «$text»',
            );
          }
        }
      }
    }
  });

  testWidgets('цели нажатия не меньше 44, при 2x — без переполнений',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(290, 800));
    expect(tester.takeException(), isNull);
    for (final finder in <Finder>[
      find.byKey(const Key('session-files-close')),
      find.byTooltip('Действия: Запись встречи.mp3'),
      find.byKey(const Key('session-file-out:j1:0')),
    ]) {
      final size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(44));
      expect(size.width, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('файл удалили, пока панель открыта: нажатие — к сообщению',
      (tester) async {
    final deleted = <String>{};
    final h = await _pump(
      tester,
      stat: (String path) => deleted.contains(path)
          ? (exists: false, folder: false, size: null)
          : _stat(path),
    );
    expect(
      _subtitleOf(tester, 'out:j1:0'),
      'Запись встречи.mp3 | Конвертер\u00A0· 2,4\u00A0МБ\u00A0· 14:05',
    );
    // Удалили вне приложения: колонка на компьютере всё это время открыта.
    deleted.add('/out/j1/Запись встречи.mp3');
    await tester.tap(find.text('Запись встречи.mp3'));
    await tester.pumpAndSettle();
    expect(h.opened, isEmpty, reason: 'не запускать программу на пустом пути');
    expect(h.messages, isEmpty);
    expect(h.shown, <String>['m_out']);
    expect(
      _subtitleOf(tester, 'out:j1:0'),
      'Запись встречи.mp3 | Файла больше нет',
    );
  });

  testWidgets('новый список файлов — диск проверяется заново', (tester) async {
    var calls = 0;
    SessionFileStat counting(String path) {
      calls++;
      return _stat(path);
    }

    await _pump(tester, stat: counting);
    final first = calls;
    expect(first, _outputs.length);
    // Та же перестройка с тем же списком — без лишних проверок.
    tester.element(find.byType(SessionFilesPanel)).markNeedsBuild();
    await tester.pump();
    expect(calls, first);
  });

  testWidgets('шрифт 2x: заголовок не растёт без меры, «×» сверху справа',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(290, 800));
    final title = tester.getRect(find.text('Файлы сессии'));
    // Строка не выше 20 × 1,25 × 1,3 (без потолка при 2x было бы 50);
    // тестовый шрифт широкий — заголовок здесь в две строки.
    final lines = (title.height / (20 * 1.25 * 1.3)).round();
    expect(title.height, lessThanOrEqualTo(lines * (20 * 1.25 * 1.3) + 1));
    expect(lines, lessThanOrEqualTo(2));
    final close = tester.getRect(find.byKey(const Key('session-files-close')));
    expect(close.top, lessThanOrEqualTo(title.top));
    expect(close.right, greaterThan(title.right));
  });
}
