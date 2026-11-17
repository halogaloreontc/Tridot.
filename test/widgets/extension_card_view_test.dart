// Карточка-форма расширения: все состояния, неактивная «Запустить», нет
// «Открыть папку» на телефоне.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/jobs/job_hub.dart';
import 'package:local_assistant/app/widgets/extension_card_view.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';

ExtensionCard _card({
  CardState state = CardState.form,
  List<JobFile> files = const <JobFile>[],
  String action = ExtensionForms.zip,
}) =>
    ExtensionCard(
      id: 'j1_0',
      extensionId: ExtensionForms.archiver,
      updatedAt: DateTime(2026),
      state: state,
      values: <String, Object?>{
        'action': action,
        if (files.isNotEmpty) 'files': files,
      },
    );

void main() {
  final progress = ValueNotifier<JobTick?>(null);
  final log = <String>[];

  Future<void> pump(
    WidgetTester tester,
    ExtensionCard card, {
    JobPlatform platform = JobPlatform.linux,
    bool canReveal = true,
    List<JobFile> sessionFiles = const <JobFile>[],
    Set<String> tools = const <String>{},
    bool enabled = true,
    bool temporary = false,
    double? width,
    double textScale = 1,
  }) async {
    log.clear();
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width ?? 800,
                child: ExtensionCardView(
                  card: card,
                  platform: platform,
                  progress: progress,
                  canReveal: canReveal,
                  sessionFiles: sessionFiles,
                  enabled: enabled,
                  temporary: temporary,
                  tools: tools,
                  onAddFiles: () => log.add('files'),
                  onAddFolder: () => log.add('folder'),
                  onAddSessionFile: (JobFile f) => log.add('session:${f.name}'),
                  onRemoveFile: (JobFile f) => log.add('remove:${f.name}'),
                  onChoice: (String c, String v) => log.add('$c=$v'),
                  onText: (String c, String v) => log.add('text:$c=$v'),
                  onRun: () => log.add('run'),
                  onCancel: () => log.add('cancel'),
                  onOpen: (String path) => log.add('open:$path'),
                  onReveal: (String path) => log.add('reveal:$path'),
                  onRetry: () => log.add('retry'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyleButton runButton(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(find.byKey(const Key('ext-card-run')));

  Finder select(String code) => find.descendant(
        of: find.byKey(ValueKey<String>('ext-card-select-$code')),
        matching: find.byType(DropdownButton<String>),
      );

  /// Открывает выпадающий список поля [code].
  Future<void> open(WidgetTester tester, String code) async {
    await tester.tap(select(code));
    await tester.pumpAndSettle();
  }

  /// Вариант [value] в открытом списке (последний — в меню, а не в кнопке).
  Finder item(String value) =>
      find.byKey(ValueKey<String>('ext-card-choice-$value')).last;

  /// Нажатие по варианту меню: по его InkWell (подпись — WholeWordText,
  /// своя раскладка без проверки касаний).
  Finder tapTarget(String value) =>
      find.ancestor(of: item(value), matching: find.byType(InkWell)).first;

  /// Выбирает [value] в поле [code].
  Future<void> choose(WidgetTester tester, String code, String value) async {
    await open(tester, code);
    await tester.tap(tapTarget(value));
    await tester.pumpAndSettle();
  }

  testWidgets('форма без файлов: «Запустить» неактивна, подсказка', (
    WidgetTester tester,
  ) async {
    await pump(tester, _card());
    expect(find.text('Архиватор'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-files-empty')), findsOneWidget);
    // Пустое поле уже говорит «Выберите файлы или папку»: под кнопкой
    // та же причина второй раз не пишется.
    expect(find.text('Добавьте файлы'), findsNothing);
    expect(find.byKey(const Key('ext-card-blocker')), findsNothing);
    expect(runButton(tester).onPressed, isNull);
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.tap(find.byKey(const Key('ext-card-pick-folder')));
    // Действие — выпадающим списком; «Распаковать» без .zip видно, но не
    // выбирается, причина — второй строкой.
    await open(tester, 'action');
    expect(
      tester.widget<DropdownMenuItem<String>>(item('extract')).enabled,
      isFalse,
    );
    expect(find.text('Нужен ровно один файл .zip'), findsWidgets);
    await tester.tap(tapTarget('zip'));
    await tester.pumpAndSettle();
    await choose(tester, 'level', 'store');
    expect(log, <String>['files', 'folder', 'action=zip', 'level=store']);
  });

  testWidgets('сжатие — только у «Создать архив»', (
    WidgetTester tester,
  ) async {
    await pump(tester, _card());
    expect(find.text('Сжатие'), findsOneWidget);
    await pump(tester, _card(action: ExtensionForms.extract));
    expect(find.text('Сжатие'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('ext-card-select-level')),
      findsNothing,
    );
  });

  testWidgets('форма с файлом: «Запустить», убрать файл, из сессии', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      _card(files: <JobFile>[const JobFile(path: '/a.txt', name: 'a.txt')]),
      sessionFiles: <JobFile>[
        const JobFile(
          path: 'files/s/1.zip',
          name: 'фото.zip',
          attachment: true,
        ),
      ],
    );
    expect(find.text('a.txt'), findsOneWidget);
    expect(runButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('ext-card-run')));
    await tester.tap(find.byKey(const Key('ext-card-file-remove-0')));
    await tester.tap(find.byKey(const Key('ext-card-session-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('фото.zip').last);
    await tester.pumpAndSettle();
    expect(log, <String>['run', 'remove:a.txt', 'session:фото.zip']);
  });

  testWidgets('«Распаковать» без .zip — причина под выбором', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      _card(
        files: <JobFile>[const JobFile(path: '/a.txt', name: 'a.txt')],
        action: ExtensionForms.extract,
      ),
    );
    expect(find.byKey(const Key('ext-card-choice-reason')), findsOneWidget);
    // Причина под выбранным вариантом — один раз, без повтора под кнопкой.
    expect(find.text('Нужен ровно один файл .zip'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-blocker')), findsNothing);
    expect(runButton(tester).onPressed, isNull);
  });

  testWidgets('выключенное расширение: карточка есть, «Запустить» — нет', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      _card(files: <JobFile>[const JobFile(path: '/a.txt', name: 'a.txt')]),
      enabled: false,
    );
    expect(runButton(tester).onPressed, isNull);
    expect(
      find.text(ExtensionForms.offReason(ExtensionForms.archiver)),
      findsOneWidget,
    );
    expect(
      ExtensionForms.offReason(ExtensionForms.archiver),
      'Архиватор выключен — включите в «Настройки → Расширения»',
    );
  });

  testWidgets('на телефоне нет «Выбрать папку»', (WidgetTester tester) async {
    await pump(tester, _card(), platform: JobPlatform.android);
    expect(find.byKey(const Key('ext-card-pick-folder')), findsNothing);
    expect(find.text('Выберите файлы'), findsOneWidget);
  });

  testWidgets('идёт: стадия, процент, «Отмена»', (WidgetTester tester) async {
    progress.value = (value: 0.42, stage: 'Сжатие');
    await pump(tester, _card(state: CardState.running));
    expect(find.text('Сжатие: 42%'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-progress')), findsOneWidget);
    progress.value = (value: null, stage: 'Распаковка');
    await tester.pump();
    expect(find.text('Распаковка…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ext-card-cancel')));
    expect(log, <String>['cancel']);
    progress.value = null;
  });

  testWidgets('полоса прогресса видна: заливка и дорожка разного цвета', (
    WidgetTester tester,
  ) async {
    progress.value = (value: 0.42, stage: 'Сжатие');
    await pump(tester, _card(state: CardState.running));
    final finder = find.byKey(const Key('ext-card-progress'));
    final bar = tester.widget<LinearProgressIndicator>(finder);
    final theme = ProgressIndicatorTheme.of(tester.element(finder));
    // Цвета, которыми полоса рисуется: свои у виджета или из темы.
    final fill = bar.color ?? theme.color;
    final track = bar.backgroundColor ?? theme.linearTrackColor;
    // Акцент на мягкой дорожке (ADR-027).
    expect(fill, AppPalette.dark.accent);
    expect(track, AppPalette.dark.bubble);
    expect(fill, isNot(track));
    expect(bar.minHeight ?? theme.linearMinHeight, 4);
    progress.value = null;
  });

  testWidgets('готово: «Открыть» и «Открыть папку» на компьютере', (
    WidgetTester tester,
  ) async {
    final card = _card(state: CardState.done)
      ..outputs = <String>['/tmp/нет/Архив.zip'];
    await pump(tester, card);
    expect(find.text('Готово: Архив.zip'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ext-card-open')));
    await tester.tap(find.byKey(const Key('ext-card-reveal')));
    expect(
      log,
      <String>['open:/tmp/нет/Архив.zip', 'reveal:/tmp/нет/Архив.zip'],
    );
  });

  testWidgets('готово на телефоне: «Открыть папку» скрыта', (
    WidgetTester tester,
  ) async {
    final card = _card(state: CardState.done)
      ..outputs = <String>['/tmp/нет/Архив.zip'];
    await pump(tester, card, platform: JobPlatform.android, canReveal: false);
    expect(find.byKey(const Key('ext-card-open')), findsOneWidget);
    expect(find.byKey(const Key('ext-card-reveal')), findsNothing);
  });

  testWidgets('содержимое архива и «ещё N»', (WidgetTester tester) async {
    final card = _card(state: CardState.done, action: ExtensionForms.list)
      ..listing = <String>['a.txt · 3 Б', 'b/']
      ..listingMore = 7;
    await pump(tester, card);
    expect(find.text('a.txt · 3 Б'), findsOneWidget);
    expect(find.text('и ещё 7'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-open')), findsNothing);
  });

  testWidgets('ошибка, отмена, прервано — текст и «Повторить»', (
    WidgetTester tester,
  ) async {
    final failed = _card(state: CardState.failed)
      ..errorCode = JobCodes.password;
    await pump(tester, failed);
    expect(find.text('ZIP с паролем пока не поддерживается'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ext-card-retry')));
    expect(log, <String>['retry']);
    await pump(tester, _card(state: CardState.cancelled));
    expect(find.text('Отменено'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-retry')), findsOneWidget);
    await pump(tester, _card(state: CardState.interrupted));
    expect(find.byKey(const Key('ext-card-interrupted')), findsOneWidget);
    expect(find.byKey(const Key('ext-card-retry')), findsOneWidget);
  });

  testWidgets('неизвестное расширение — только для чтения', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      ExtensionCard(id: 'j9', extensionId: 'future', updatedAt: DateTime(2026)),
    );
    expect(find.byKey(const Key('ext-card-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('ext-card-run')), findsNothing);
  });

  group('конвертер', () {
    ExtensionCard converter(String file, {String? target}) => ExtensionCard(
          id: 'j2_0',
          extensionId: ExtensionForms.converter,
          updatedAt: DateTime(2026),
          values: <String, Object?>{
            'file': <JobFile>[JobFile(path: '/tmp/$file', name: file)],
            if (target != null) 'target': target,
          },
        );

    testWidgets('пустая форма: один файл, без «Выбрать папку»', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        ExtensionCard(
          id: 'j2_0',
          extensionId: ExtensionForms.converter,
          updatedAt: DateTime(2026),
        ),
      );
      expect(find.text('Конвертер'), findsOneWidget);
      expect(find.text('Выбрать файл'), findsOneWidget);
      expect(find.byKey(const Key('ext-card-pick-folder')), findsNothing);
      expect(find.text('Выберите файл'), findsWidgets);
      expect(runButton(tester).onPressed, isNull);
    });

    testWidgets('картинка на телефоне: png, «Запустить» активна', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        converter('кот.jpg', target: 'png'),
        platform: JobPlatform.android,
      );
      expect(find.text('PNG'), findsOneWidget);
      expect(runButton(tester).onPressed, isNotNull);
      await open(tester, 'target');
      expect(item('png'), findsOneWidget);
      expect(find.text('JPEG (пережать)'), findsWidgets);
      await tester.tap(tapTarget('jpeg'));
      await tester.pumpAndSettle();
      expect(log, <String>['target=jpeg']);
    });

    testWidgets('видео на телефоне: варианты есть, причина видна честно', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        converter('клип.mp4', target: 'mp3'),
        platform: JobPlatform.android,
      );
      expect(
        find.byKey(const Key('ext-card-choice-reason')),
        findsOneWidget,
      );
      expect(
        find.textContaining('На телефоне — только картинки'),
        findsWidgets,
      );
      expect(runButton(tester).onPressed, isNull);
      await open(tester, 'target');
      expect(item('frame-jpeg'), findsOneWidget);
      expect(
        tester.widget<DropdownMenuItem<String>>(item('frame-jpeg')).enabled,
        isFalse,
      );
      // WebM и MOV на телефоне не делаются вовсе — их нет в списке.
      expect(
        find.byKey(const ValueKey<String>('ext-card-choice-webm')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('ext-card-choice-mov')),
        findsNothing,
      );
    });

    testWidgets('WebM на телефоне, выбранный фразой, — виден с причиной', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        converter('клип.mp4', target: 'webm'),
        platform: JobPlatform.android,
      );
      expect(find.text('WebM'), findsOneWidget);
      expect(find.textContaining('WebM не делается'), findsOneWidget);
      expect(runButton(tester).onPressed, isNull);
    });

    testWidgets('видео на компьютере: без ffmpeg — где скачать, с ним — можно',
        (
      WidgetTester tester,
    ) async {
      await pump(tester, converter('клип.mkv', target: 'mp4'));
      expect(find.textContaining('Нужен ffmpeg'), findsWidgets);
      expect(runButton(tester).onPressed, isNull);
      await pump(
        tester,
        converter('клип.mkv', target: 'mp4'),
        tools: const <String>{'ffmpeg'},
      );
      expect(find.textContaining('Нужен ffmpeg'), findsNothing);
      expect(runButton(tester).onPressed, isNotNull);
    });

    testWidgets('качество — только у подходящей цели', (
      WidgetTester tester,
    ) async {
      ExtensionCard card(String target, [Map<String, String>? extra]) =>
          converter('клип.mkv', target: target)..values.addAll(extra ?? {});
      await pump(
        tester,
        card('mp3', <String, String>{'audio_kbps': '320'}),
        tools: const <String>{'ffmpeg'},
      );
      expect(find.text('Качество звука'), findsOneWidget);
      expect(find.text('320 кбит/с — наилучшее'), findsOneWidget);
      expect(find.text('Размер видео'), findsNothing);
      await choose(tester, 'audio_kbps', '128');
      expect(log, <String>['audio_kbps=128']);

      await pump(tester, card('mp4'), tools: const <String>{'ffmpeg'});
      expect(find.text('Размер видео'), findsOneWidget);
      expect(find.text('Качество видео'), findsOneWidget);
      expect(find.text('Качество звука'), findsNothing);
      await choose(tester, 'video_res', '720');
      expect(log, <String>['video_res=720']);

      await pump(tester, card('wav'), tools: const <String>{'ffmpeg'});
      expect(find.text('Качество звука'), findsNothing);
      expect(find.text('Размер видео'), findsNothing);

      await pump(tester, card('frame-jpeg'), tools: const <String>{'ffmpeg'});
      expect(find.text('Качество JPEG'), findsOneWidget);
      expect(find.text('Размер картинки'), findsNothing);

      // У картинки: качество JPEG и размер.
      await pump(tester, converter('кот.png', target: 'jpeg'));
      expect(find.text('Качество JPEG'), findsOneWidget);
      expect(find.text('Размер картинки'), findsOneWidget);
    });

    testWidgets('прежнее значение не из списка — пусто, а не падение', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        converter('клип.mkv', target: 'mp3')
          ..values['audio_kbps'] = '999'
          ..values['video_res'] = '720',
        tools: const <String>{'ffmpeg'},
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Качество звука'), findsOneWidget);
      // Необязательное поле без значения запуск не держит.
      expect(runButton(tester).onPressed, isNotNull);
    });

    testWidgets('занят — список не открывается', (WidgetTester tester) async {
      log.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: ExtensionCardView(
              card: converter('кот.jpg', target: 'png'),
              platform: JobPlatform.linux,
              progress: progress,
              busy: true,
              onChoice: (String c, String v) => log.add('$c=$v'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<DropdownButton<String>>(select('target')).onChanged,
        isNull,
      );
    });
  });

  group('загрузчик видео', () {
    ExtensionCard ytdl({
      String? url,
      CardState state = CardState.form,
      String? outputDir,
    }) =>
        ExtensionCard(
          id: 'j2_0',
          extensionId: ExtensionForms.ytdl,
          updatedAt: DateTime(2026),
          state: state,
          outputDir: outputDir,
          values: <String, Object?>{
            if (url != null) 'url': url,
            'format': 'video720',
          },
        );

    testWidgets('поле ссылки, «Скачать» — только с yt-dlp и ссылкой', (
      WidgetTester tester,
    ) async {
      await pump(tester, ytdl());
      expect(find.text('Загрузчик видео'), findsOneWidget);
      expect(find.text('Скачать'), findsOneWidget);
      expect(find.byKey(const Key('ext-card-url')), findsOneWidget);
      expect(runButton(tester).onPressed, isNull);
      expect(find.textContaining('Нужен yt-dlp'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('ext-card-url')),
        'https://example.com/v/1',
      );
      expect(log, contains('text:url=https://example.com/v/1'));
      await pump(
        tester,
        ytdl(url: 'https://example.com/v/1'),
        tools: const <String>{'ytdlp'},
      );
      expect(runButton(tester).onPressed, isNotNull);
      await open(tester, 'format');
      expect(item('audio'), findsOneWidget);
    });

    testWidgets('готово без пути файла — «Открыть папку»', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        ytdl(state: CardState.done, outputDir: '/home/u/Загрузки/Tridot'),
      );
      await tester.tap(find.byKey(const Key('ext-card-open-dir')));
      expect(log, contains('open:/home/u/Загрузки/Tridot'));
      await pump(
        tester,
        ytdl(state: CardState.done, outputDir: '/d'),
        canReveal: false,
        platform: JobPlatform.android,
      );
      expect(find.byKey(const Key('ext-card-open-dir')), findsNothing);
    });

    testWidgets('ошибка сети — понятный текст без ссылки', (
      WidgetTester tester,
    ) async {
      final card = ytdl(url: 'https://example.com/v/1', state: CardState.failed)
        ..errorCode = JobCodes.network;
      await pump(tester, card);
      expect(find.textContaining('нет сети'), findsOneWidget);
      expect(find.textContaining('example.com'), findsNothing);
    });
  });

  testWidgets('готово во временной папке — предупреждение', (
    WidgetTester tester,
  ) async {
    final card = _card(state: CardState.done)
      ..outputs = <String>['/tmp/tridot-jobs/j1_0/out/a.zip']
      ..outputDir = '/tmp/tridot-jobs/j1_0/out';
    await pump(tester, card, temporary: true);
    expect(
      find.text('Результат во временной папке и удалится при выходе'),
      findsOneWidget,
    );
    await pump(tester, card);
    expect(find.byKey(const Key('ext-card-temporary')), findsNothing);
  });

  testWidgets('узкий экран, крупный шрифт: подписи вариантов переносятся', (
    WidgetTester tester,
  ) async {
    final card = ExtensionCard(
      id: 'j2_0',
      extensionId: ExtensionForms.ytdl,
      updatedAt: DateTime(2026),
      values: <String, Object?>{'url': 'https://example.com/v/1'},
    );
    await pump(
      tester,
      card,
      width: 288,
      textScale: 2,
      tools: const <String>{'ytdlp', 'ffmpeg'},
    );
    expect(tester.takeException(), isNull);
    await open(tester, 'format');
    expect(tester.takeException(), isNull);
    for (final format in <String>['video1080', 'video720', 'video480']) {
      final label = find.descendant(
        of: item(format),
        matching: find.byType(Text),
      );
      final text = tester.widget<Text>(label.first);
      expect(text.maxLines, isNull, reason: format);
      // Подпись не обрезана в одну строку: её высота — больше строки.
      expect(
        tester.getSize(label.first).height,
        greaterThan(30),
        reason: format,
      );
    }
  });

  testWidgets('конвертер без файла: вместо пустого «Во что» — подсказка', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      ExtensionCard(
        id: 'j1_0',
        extensionId: ExtensionForms.converter,
        updatedAt: DateTime(2026),
      ),
    );
    expect(find.text('Во что'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-empty-target')), findsOneWidget);
    expect(find.text('Сначала выберите файл'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });
}
